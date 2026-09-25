//! Plugin Host Subprocess
//!
//! A separate executable that hosts CLAP plugins for the Sonara engine. One process can hold
//! several plugin instances (hosting modes). It talks to the engine over a Unix socketpair plus
//! shared memory.
//!
//! **Responsibilities:**
//! - Load CLAP plugin libraries and create instances
//! - Activate them and process the blocks the engine publishes in shared memory
//! - Manage plugin GUIs, timers and main-thread callbacks
//! - Respond to commands from the engine
//!
//! **Usage:**
//! ```text
//! plugin_host <control_socket_fd> [--host-key KEY] [--log-dir DIR]
//! plugin_host --probe <path.clap> [--id PLUGIN_ID] [--rate HZ] [--block FRAMES]
//! ```
//! The first form is how the engine starts it. `--probe` loads one plugin standalone and prints
//! what it reports, without the engine or Godot (`plugin_host/probe.rs`).
//!
//! `SONARA_PLUGIN_HOST_WAIT=1` makes the host print its pid and wait for a debugger to attach
//! before it reads any command.

use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tracing::{error, info, warn};

use engine::audio::ipc::HostSharedMemory;
use engine::plugin_host::event_loop::run_plugin_host;
use engine::plugin_host::install_x11_error_handler;
use engine::plugin_host::{logging, probe};

/// Env var that makes the host wait for a debugger before it starts.
const WAIT_ENV: &str = "SONARA_PLUGIN_HOST_WAIT";

/// Command-line options for hosting (not probe) mode.
struct HostArgs {
    socket_fd: i32,
    host_key: String,
    log_dir: Option<PathBuf>,
}

fn usage() -> ! {
    eprintln!(
        "Usage:\n  plugin_host <control_socket_fd> [--host-key KEY] [--log-dir DIR]\n  \
         plugin_host --probe <path.clap> [--id PLUGIN_ID] [--rate HZ] [--block FRAMES]"
    );
    std::process::exit(2);
}

fn parse_host_args(args: &[String]) -> HostArgs {
    let Some(socket_fd) = args.first().and_then(|fd| fd.parse().ok()) else {
        usage();
    };
    let mut parsed = HostArgs {
        socket_fd,
        host_key: "host".to_string(),
        log_dir: None,
    };
    let mut rest = args[1..].iter();
    while let Some(arg) = rest.next() {
        let value = rest.next().unwrap_or_else(|| usage());
        match arg.as_str() {
            "--host-key" => parsed.host_key = value.clone(),
            "--log-dir" => parsed.log_dir = Some(PathBuf::from(value)),
            _ => usage(),
        }
    }
    parsed
}

fn parse_probe_args(args: &[String]) -> probe::ProbeOptions {
    let Some(path) = args.first() else { usage() };
    let mut options = probe::ProbeOptions::new(PathBuf::from(path));
    let mut rest = args[1..].iter();
    while let Some(arg) = rest.next() {
        let value = rest.next().unwrap_or_else(|| usage());
        match arg.as_str() {
            "--id" => options.plugin_id = Some(value.clone()),
            "--rate" => options.sample_rate = value.parse().unwrap_or_else(|_| usage()),
            "--block" => options.block_frames = value.parse().unwrap_or_else(|_| usage()),
            _ => usage(),
        }
    }
    options
}

/// Print the pid and block until a debugger attaches (`TracerPid` in `/proc/self/status`).
/// Allows any process to attach, since Yama's default `ptrace_scope` only lets a parent do it.
///
/// Exits if the engine closes the control socket meanwhile: the host isn't reading it yet, so
/// nothing else would notice, and it would outlive the engine.
fn wait_for_debugger(host_key: &str, socket_fd: i32) {
    unsafe {
        libc::prctl(libc::PR_SET_PTRACER, libc::PR_SET_PTRACER_ANY, 0, 0, 0);
    }
    let pid = std::process::id();
    warn!(
        "Plugin host {} (pid {}) is waiting for a debugger: gdb -p {}",
        host_key, pid, pid
    );
    loop {
        let traced = std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|status| {
                status
                    .lines()
                    .find_map(|line| line.strip_prefix("TracerPid:"))
                    .map(|value| value.trim() != "0")
            })
            .unwrap_or(false);
        if traced {
            info!("Debugger attached, continuing");
            return;
        }
        // Wait up to 100 ms for the engine to hang up (requests may be queued; those only
        // make the socket readable, which is fine).
        let mut fds = [libc::pollfd {
            fd: socket_fd,
            events: libc::POLLRDHUP,
            revents: 0,
        }];
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, 100) };
        if ready > 0 && fds[0].revents & (libc::POLLRDHUP | libc::POLLHUP | libc::POLLERR) != 0 {
            info!("Engine closed the control socket while waiting for a debugger; exiting");
            unsafe { libc::_exit(0) };
        }
        if ready < 0 {
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

/// Take ownership of descriptor `fd` passed by the engine and set close-on-exec on it again, so
/// processes a plugin spawns don't inherit it. Exits when it isn't open.
fn claim_fd(fd: i32, what: &str) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags < 0 {
            error!("{} FD {} is not open", what, fd);
            std::process::exit(1);
        }
        libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.first().map(String::as_str) == Some("--probe") {
        let options = parse_probe_args(&args[1..]);
        tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_env(logging::LOG_FILTER_ENV)
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
            )
            .with_writer(std::io::stderr)
            .init();
        install_x11_error_handler();
        let code = probe::run(&options);
        std::process::exit(code);
    }

    let host_args = parse_host_args(&args);
    let (log_rx, log_path) = logging::init(&host_args.host_key, host_args.log_dir.as_deref());

    info!(
        "🔌 Plugin host {} starting (pid {})",
        host_args.host_key,
        std::process::id()
    );
    if let Some(path) = &log_path {
        info!("Logging to {}", path.display());
    }

    // Install X11 error handler BEFORE any X11 operations
    // This prevents the default X11 error handler from terminating the process
    // when plugins trigger X11 errors (e.g., accessing destroyed windows)
    install_x11_error_handler();

    // The engine cleared close-on-exec so the descriptor survived exec.
    let socket_fd = host_args.socket_fd;
    claim_fd(socket_fd, "Control socket");

    if std::env::var(WAIT_ENV).is_ok_and(|value| !value.is_empty() && value != "0") {
        wait_for_debugger(&host_args.host_key, socket_fd);
    }
    // SAFETY: the engine passes us this descriptor and nothing else in this process owns it
    let socket = unsafe { UnixStream::from_raw_fd(socket_fd) };
    info!("✅ Using control socket FD {}", socket_fd);

    // The host doorbell region (one word the engine and this host ring at each other) arrives as
    // descriptor 4.
    const DOORBELL_FD: i32 = 4;
    claim_fd(DOORBELL_FD, "Doorbell");
    // SAFETY: same contract as the socket descriptor.
    let doorbell = unsafe { HostSharedMemory::from_fd(DOORBELL_FD) }.unwrap_or_else(|e| {
        error!("Failed to map host doorbell: {}", e);
        std::process::exit(1);
    });
    info!("✅ Using doorbell FD {}", DOORBELL_FD);

    // Run plugin host event loop
    if let Err(e) = run_plugin_host(socket, Arc::new(doorbell), log_rx) {
        error!("Plugin host error: {}", e);
        // Use libc::_exit to avoid IO safety checks during error cleanup
        unsafe {
            libc::_exit(1);
        }
    }

    info!("Plugin host subprocess exiting");
    // Normal exit also uses _exit to avoid IO safety checks
    unsafe {
        libc::_exit(0);
    }
}
