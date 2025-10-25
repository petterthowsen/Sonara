//! Main event loop for plugin host subprocess
//!
//! Handles command processing, audio processing, GUI callbacks, and timers
//! in a non-blocking event loop on the main thread.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::thread;
use std::time::Duration;
use tracing::{error, info, warn};

use clack_extensions::params::{PluginParams, ParamInfoBuffer};
use clack_extensions::timer::PluginTimer;
use clack_host::events::io::{InputEvents, OutputEvents};

use crate::plugin_host::protocol::{PluginCommand, PluginResponse};
use crate::plugin_host::state::{PluginState, has_audio_to_process, process_audio, process_output_events};
use crate::plugin_host::commands::process_command;

/// Main plugin host event loop
///
/// This runs on the main thread and handles both commands and GUI callbacks.
/// We use non-blocking I/O to process commands while continuously calling
/// the plugin's main thread callback for GUI responsiveness.
pub fn run_plugin_host(
    mut stream: TcpStream,
    unix_socket_fd: i32,
) -> Result<(), Box<dyn std::error::Error>> {
    // Set socket to non-blocking mode
    stream.set_nonblocking(true)?;

    let mut plugin_state: Option<PluginState> = None;

    // Channel for unsolicited responses (GUI resize, parameter changes, etc.)
    let (unsolicited_tx, unsolicited_rx) = std::sync::mpsc::channel::<PluginResponse>();

    info!("📡 Listening for commands (non-blocking)...");

    // Main event loop: process commands + GUI callbacks + audio processing
    let mut line_buffer = String::new();
    let mut byte_buffer = [0u8; 1];

    loop {
        // Try to read commands as fast as possible (prioritize command reading)
        // Read in a tight loop until WouldBlock to minimize latency
        let mut command_received = false;
        loop {
            match stream.read(&mut byte_buffer) {
                Ok(0) => {
                    // Connection closed
                    info!("Control socket closed, shutting down");
                    return Ok(());
                }
                Ok(1) => {
                    let ch = byte_buffer[0] as char;
                    if ch == '\n' {
                        // Complete line received, process it
                        let line = line_buffer.trim();

                        if !line.is_empty() {
                            info!("📨 Raw data received ({} bytes): '{}'", line.len(), line);

                            // Parse command (JSON-encoded)
                            let cmd: PluginCommand = match serde_json::from_str(line) {
                                Ok(c) => c,
                                Err(e) => {
                                    warn!("Failed to parse command '{}': {}", line, e);
                                    line_buffer.clear();
                                    continue;
                                }
                            };

                            // Check for shutdown BEFORE logging to avoid IO safety issues
                            if matches!(cmd, PluginCommand::Shutdown) {
                                // Exit immediately using libc::_exit without any logging or drops
                                // The OS will clean up all file descriptors and resources
                                unsafe {
                                    libc::_exit(0);
                                }
                            }

                            info!("📥 Received command: {:?}", cmd);

                            // Process command
                            let response =
                                process_command(cmd, &mut plugin_state, unix_socket_fd, &unsolicited_tx);

                            if let Some(resp) = response {
                                info!("📤 Sending response: {:?}", resp);
                                let resp_json = serde_json::to_string(&resp)?;
                                info!("📤 Response JSON: {}", resp_json);

                                // Try to send response, but treat broken pipe as normal shutdown
                                if let Err(e) = writeln!(stream, "{}", resp_json) {
                                    if e.kind() == std::io::ErrorKind::BrokenPipe
                                        || e.kind() == std::io::ErrorKind::ConnectionReset
                                    {
                                        info!(
                                            "Parent closed connection while sending response, shutting down"
                                        );
                                        unsafe {
                                            libc::_exit(0);
                                        }
                                    }
                                    return Err(Box::new(e));
                                }
                                if let Err(e) = stream.flush() {
                                    if e.kind() == std::io::ErrorKind::BrokenPipe
                                        || e.kind() == std::io::ErrorKind::ConnectionReset
                                    {
                                        info!(
                                            "Parent closed connection while flushing response, shutting down"
                                        );
                                        unsafe {
                                            libc::_exit(0);
                                        }
                                    }
                                    return Err(Box::new(e));
                                }
                                info!("📤 Response sent and flushed");
                            }

                            command_received = true;
                        }

                        // Clear buffer for next command
                        line_buffer.clear();
                        // Continue reading to check for more commands
                    } else {
                        // Accumulate characters
                        line_buffer.push(ch);
                    }
                }
                Ok(_) => unreachable!("read returned >1 for single byte buffer"),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // No more data available right now, exit read loop
                    break;
                }
                Err(e)
                    if e.kind() == std::io::ErrorKind::BrokenPipe
                        || e.kind() == std::io::ErrorKind::ConnectionReset =>
                {
                    // Parent process closed the connection, this is a normal shutdown
                    info!("Control socket closed by parent ({}), shutting down", e);
                    unsafe {
                        libc::_exit(0);
                    }
                }
                Err(e) => {
                    error!("Socket read error: {}", e);
                    return Err(Box::new(e));
                }
            }
        }

        // Process audio, GUI callbacks, and timers (separate from command handling)
        let mut processed_audio = false;
        if let Some(ref mut state) = plugin_state {
            // Process audio if plugin is activated and processing
            // Keep processing in a loop until input buffer is empty
            if state.activated && state.processing {
                // Process audio multiple times to keep up with real-time
                // Process aggressively to minimize latency
                for _ in 0..8 {
                    // Process up to 8 chunks per iteration
                    if has_audio_to_process(state) {
                        process_audio(state);
                        processed_audio = true;
                    } else {
                        break;
                    }
                }
            }

            // Process timers - check which ones need to fire
            let triggered_timers = state.shared.tick_timers();
            if !triggered_timers.is_empty() {
                // Get timer extension and fire callbacks
                let mut handle = state.instance.plugin_handle();
                if let Some(timer_ext) = handle.get_extension::<PluginTimer>() {
                    for timer_id in triggered_timers {
                        timer_ext.on_timer(&mut handle, timer_id);
                    }
                }
            }

            // Process GUI callbacks if plugin is open
            // This is the critical call that keeps plugin GUIs responsive
            if state.gui_open {
                state.instance.call_on_main_thread_callback();

                // Poll for parameter changes from the GUI even when not processing audio
                // This is critical: GUI parameter changes are only visible through output events,
                // but we only collect output events during process() or flush() calls
                let mut handle = state.instance.plugin_handle();
                if let Some(params_ext) = handle.get_extension::<PluginParams>() {
                    let input_events = InputEvents::empty();
                    let mut output_events =
                        OutputEvents::from_buffer(&mut state.output_event_buffer);

                    // Flush with empty input to collect any pending output events from GUI
                    params_ext.flush(&mut handle, &input_events, &mut output_events);

                    // Process the collected output events
                    process_output_events(state);
                    state.output_event_buffer.clear();
                }
            }

            // Send pending parameter changes back to main process
            if !state.pending_param_changes.is_empty() {
                // Get parameter extension to map CLAP IDs to sequential param_ids
                let mut handle = state.instance.plugin_handle();
                if let Some(params_ext) = handle.get_extension::<PluginParams>() {
                    let param_count = params_ext.count(&mut handle);

                    // Process each pending change
                    for (_placeholder_id, clap_id, denormalized_value) in
                        state.pending_param_changes.drain(..)
                    {
                        // Find sequential param_id by iterating through parameters
                        let mut param_id_opt = None;
                        let mut param_info_opt = None;

                        for i in 0..param_count {
                            let mut buffer = ParamInfoBuffer::new();
                            if let Some(info) = params_ext.get_info(&mut handle, i, &mut buffer) {
                                if info.id == clap_id {
                                    param_id_opt = Some(i);
                                    param_info_opt = Some((info.min_value, info.max_value));
                                    break;
                                }
                            }
                        }

                        if let (Some(param_id), Some((min_val, max_val))) =
                            (param_id_opt, param_info_opt)
                        {
                            // Normalize value from plugin's range to 0.0-1.0
                            let range = max_val - min_val;
                            let normalized = if range.abs() > f64::EPSILON {
                                ((denormalized_value - min_val) / range).clamp(0.0, 1.0) as f32
                            } else {
                                0.5
                            };

                            // Send ParameterValueChanged response
                            let resp = PluginResponse::ParameterValueChanged {
                                param_id,
                                value: normalized,
                            };

                            if let Ok(resp_json) = serde_json::to_string(&resp) {
                                if let Err(e) = writeln!(stream, "{}", resp_json) {
                                    if e.kind() == std::io::ErrorKind::BrokenPipe
                                        || e.kind() == std::io::ErrorKind::ConnectionReset
                                    {
                                        info!("Parent closed connection while sending parameter change, shutting down");
                                        unsafe {
                                            libc::_exit(0);
                                        }
                                    }
                                    warn!("Failed to send parameter change: {}", e);
                                } else if let Err(e) = stream.flush() {
                                    if e.kind() == std::io::ErrorKind::BrokenPipe
                                        || e.kind() == std::io::ErrorKind::ConnectionReset
                                    {
                                        info!("Parent closed connection while flushing parameter change, shutting down");
                                        unsafe {
                                            libc::_exit(0);
                                        }
                                    }
                                    warn!("Failed to flush parameter change: {}", e);
                                } else {
                                    info!(
                                        "📤 Sent ParameterValueChanged: param_id={}, value={:.4}",
                                        param_id, normalized
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }

        // Check for unsolicited responses (GUI resize requests, etc.)
        while let Ok(resp) = unsolicited_rx.try_recv() {
            match resp {
                PluginResponse::GuiResizeRequest { width, height } => {
                    info!("📤 Sending GuiResizeRequest: {}x{}", width, height);
                }
                _ => {
                    info!("📤 Sending unsolicited response: {:?}", resp);
                }
            }

            if let Ok(resp_json) = serde_json::to_string(&resp) {
                if let Err(e) = writeln!(stream, "{}", resp_json) {
                    if e.kind() == std::io::ErrorKind::BrokenPipe
                        || e.kind() == std::io::ErrorKind::ConnectionReset
                    {
                        info!(
                            "Parent closed connection while sending unsolicited response, shutting down"
                        );
                        unsafe {
                            libc::_exit(0);
                        }
                    }
                    warn!("Failed to send unsolicited response: {}", e);
                } else if let Err(e) = stream.flush() {
                    if e.kind() == std::io::ErrorKind::BrokenPipe
                        || e.kind() == std::io::ErrorKind::ConnectionReset
                    {
                        info!(
                            "Parent closed connection while flushing unsolicited response, shutting down"
                        );
                        unsafe {
                            libc::_exit(0);
                        }
                    }
                    warn!("Failed to flush unsolicited response: {}", e);
                }
            }
        }

        // Only sleep if we didn't process audio and no command was received
        // This keeps latency low for audio processing
        if !processed_audio && !command_received {
            thread::sleep(Duration::from_millis(1)); // Short sleep (1ms) to avoid busy-waiting
        }
        // If we processed audio or a command, loop immediately
    }

    // Cleanup
    #[allow(unreachable_code)]
    {
        info!("Cleaning up plugin host...");
        Ok(())
    }
}
