//! The Sonara audio engine binary: logging, audio engine, window manager, file service and the
//! OSC server that Godot talks to. All the code lives in the `engine` library crate.

use anyhow::Result;
use engine::audio::engine::STATUS_CHANNEL_CAPACITY;
use engine::audio::io::audio_file_service::AudioFileService;
use engine::audio::{devices::container::SERIAL_PLUGIN_DISPATCH, ipc, AudioEngine};
use engine::osc::OscServer;
use engine::{logging, window_manager::WindowManager};
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

fn main() -> Result<()> {
    // The status channel comes first: the log forwarder and the engine both send into it.
    let (status_tx, status_rx) = crossbeam::channel::bounded(STATUS_CHANNEL_CAPACITY);
    let log_writers = logging::init(&status_tx)?;

    if std::env::var("SONARA_SERIAL_PLUGIN_DISPATCH").is_ok_and(|v| v == "1") {
        SERIAL_PLUGIN_DISPATCH.store(true, Ordering::Relaxed);
        info!("SONARA_SERIAL_PLUGIN_DISPATCH=1: plugins process one after another");
    }
    info!("Starting DAW Audio Engine...");
    prune_plugin_logs();

    let engine = AudioEngine::with_status_channel(status_tx, status_rx)?;
    info!("Audio engine initialized");
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
    osc_server.run(command_tx, status_rx, log_writers, &mut window_manager)?;
    Ok(())
}
