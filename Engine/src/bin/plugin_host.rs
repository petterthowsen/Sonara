//! Plugin Host Subprocess
//!
//! This is a separate executable that loads and hosts a single CLAP plugin.
//! It communicates with the main Sonara engine via IPC (Unix sockets + shared memory).
//!
//! **Responsibilities:**
//! - Load CLAP plugin library
//! - Initialize and activate plugin
//! - Process audio from shared memory ring buffers
//! - Handle MIDI events from shared queue
//! - Manage plugin GUI and event loop
//! - Respond to commands from engine
//!
//! **Benefits:**
//! - Crash isolation: Plugin crash doesn't kill DAW
//! - GUI isolation: Each plugin has its own event loop
//! - Resource management: Can restart individual plugins
//! - Security: Sandboxing between plugins and engine

use std::net::TcpStream;
use tracing::{error, info};

// Import the modular plugin_host modules
use engine::plugin_host::event_loop::run_plugin_host;
use engine::plugin_host::install_x11_error_handler;

fn main() {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter("plugin_host=debug,engine=debug")
        .with_target(false)
        .with_thread_ids(true)
        .init();

    info!("🔌 Plugin Host Subprocess starting...");

    // Install X11 error handler BEFORE any X11 operations
    // This prevents the default X11 error handler from terminating the process
    // when plugins trigger X11 errors (e.g., accessing destroyed windows)
    install_x11_error_handler();

    // Parse command line arguments
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        error!("Usage: plugin_host <control_socket_port> <unix_socket_fd>");
        std::process::exit(1);
    }

    let port: u16 = args[1].parse().expect("Invalid port number");
    let unix_socket_fd: i32 = args[2].parse().expect("Invalid Unix socket FD");

    // Connect to control socket
    let socket_addr = format!("127.0.0.1:{}", port);
    info!("Connecting to control socket: {}", socket_addr);

    let stream = match TcpStream::connect(&socket_addr) {
        Ok(s) => {
            info!("✅ Connected to control socket");
            s
        }
        Err(e) => {
            error!("Failed to connect to control socket: {}", e);
            std::process::exit(1);
        }
    };

    // Run plugin host event loop
    if let Err(e) = run_plugin_host(stream, unix_socket_fd) {
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
