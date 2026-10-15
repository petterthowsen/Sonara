//! The Sonara audio engine binary: logging, audio engine, window manager, file service and the
//! OSC server that Godot talks to. All the code lives in the `engine` library crate.

use anyhow::Result;
use engine::audio::engine::STATUS_CHANNEL_CAPACITY;
use engine::audio::io::audio_file_service::AudioFileService;
use engine::audio::{devices::container::SERIAL_PLUGIN_DISPATCH, ipc, AudioEngine};
use engine::osc::OscServer;
use engine::{build_info, cli, logging, window_manager::WindowManager};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use tracing::{info, warn};

// Counts audio-thread (de)allocations; see `audio/rt_debug.rs`. Must live in the binary.
#[cfg(feature = "rt-debug")]
#[global_allocator]
static ALLOCATOR: assert_no_alloc::AllocDisabler = assert_no_alloc::AllocDisabler;

/// Delete old plugin host logs (each host writes its own) and warn when hosts run under a debugger.
fn prune_plugin_logs() {
    let dir = ipc::plugin_log_dir();
    match ipc::prune_plugin_logs(&dir, ipc::PLUGIN_LOGS_KEPT) {
        Ok(0) => {}
        Ok(n) => info!("Removed {} old plugin host logs from {}", n, dir.display()),
        Err(e) => warn!("Can't prune plugin host logs in {}: {}", dir.display(), e),
    }
    let launch = ipc::HostLaunch::from_env();
    if launch.is_debugging() {
        warn!(
            "Plugin hosts run in debug mode (wrapper {:?}, wait for debugger: {}): hung hosts are not killed",
            launch.wrapper, launch.wait_for_debugger
        );
    }
}

/// Ask the kernel to send SIGTERM when the process that started us dies, so an engine the UI
/// launched can't outlive a crashed or SIGKILLed UI (spec 046 REQ-011, ADR 0022). SIGTERM reaches
/// the `ctrlc` handler, which restores PipeWire's forced quantum.
///
/// The kernel ties the signal to the parent *thread* that forked us, not the parent process, so
/// the launcher must spawn from a thread that lives as long as the UI (Godot's main thread).
///
/// Returns true when the parent is already gone: it died before the call, and the signal will
/// never come.
#[cfg(target_os = "linux")]
fn watch_parent(parent_pid: i32) -> bool {
    // SAFETY: plain syscalls with integer arguments.
    unsafe {
        libc::prctl(
            libc::PR_SET_PDEATHSIG,
            libc::SIGTERM as libc::c_ulong,
            0,
            0,
            0,
        );
        libc::getppid() != parent_pid
    }
}

#[cfg(not(target_os = "linux"))]
fn watch_parent(_parent_pid: i32) -> bool {
    false
}

fn main() -> Result<()> {
    // Before any audio, OSC or log setup: `--version` must print and exit without side effects.
    let args = cli::parse(std::env::args().skip(1));
    if args.print_version {
        println!("{} ({})", build_info::VERSION, build_info::COMMIT);
        return Ok(());
    }
    let parent_gone = args.parent_pid.is_some_and(watch_parent);

    // Every log of this run, including the plugin hosts' (they inherit the variable), goes to one
    // directory. Set before any thread starts.
    let log_dir = args
        .log_dir
        .clone()
        .unwrap_or_else(logging::default_log_dir);
    std::env::set_var(logging::LOG_DIR_ENV, &log_dir);

    // The status channel comes first: the log forwarder and the engine both send into it.
    let (status_tx, status_rx) = crossbeam::channel::bounded(STATUS_CHANNEL_CAPACITY);
    let log_writers = logging::init(&status_tx, &log_dir)?;
    info!(
        "Sonara engine {} ({}), protocol {}",
        build_info::VERSION,
        build_info::COMMIT,
        build_info::PROTOCOL
    );
    info!("Logging to {}", log_dir.display());
    for arg in &args.unknown {
        warn!(
            "Ignoring unknown or malformed command-line argument: {}",
            arg
        );
    }
    if parent_gone {
        warn!("The parent process is already gone; exiting");
        return Ok(());
    }

    if std::env::var("SONARA_SERIAL_PLUGIN_DISPATCH").is_ok_and(|v| v == "1") {
        SERIAL_PLUGIN_DISPATCH.store(true, Ordering::Relaxed);
        info!("SONARA_SERIAL_PLUGIN_DISPATCH=1: plugins process one after another");
    }
    info!("Starting DAW Audio Engine...");
    // Before the stream starts: cpal promotes the callback thread and sets a one-period soft
    // RLIMIT_RTTIME, and an overrun must cost an xrun, not the process.
    engine::audio::realtime::ignore_cpu_time_signal();
    prune_plugin_logs();

    let engine = AudioEngine::with_status_channel(status_tx, status_rx)?;
    info!("Audio engine initialized");

    // Give PipeWire's forced quantum and rate back on Ctrl+C / SIGTERM (spec 041 REQ-009).
    let forced_clock = engine.forced_clock();
    let handler_clock = forced_clock.clone();
    if let Err(e) = ctrlc::set_handler(move || {
        info!("Termination signal received; restoring PipeWire's settings and exiting");
        handler_clock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .restore();
        std::process::exit(0);
    }) {
        warn!("Can't install the termination handler: {}", e);
    }
    let command_tx = engine.command_sender();
    let status_rx = engine.status_receiver();

    // Window manager for plugin GUIs
    let mut window_manager = WindowManager::new();
    info!("Window manager initialized");

    let device_sample_rate = engine.device_sample_rate().max(1);
    let audio_file_service = Arc::new(Mutex::new(AudioFileService::new(4, device_sample_rate)?));
    info!("AudioFileService initialized with 4 workers at {device_sample_rate} Hz");

    let osc_server = OscServer::new(7000, audio_file_service)?;
    info!("OSC server ready on port 7000 (receives from Godot)");
    info!("OSC client sends to port 7001 (Godot listens)");
    info!("DAW Audio Engine is running. Press Ctrl+C to exit.");

    // Blocks until the server stops.
    let result = osc_server.run(command_tx, status_rx, log_writers, &mut window_manager);
    forced_clock
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .restore();
    result
}
