//! Main event loop for plugin host subprocess
//!
//! A reader thread decodes requests from the control socket and hands them to the main thread,
//! which handles commands, audio processing, GUI callbacks and timers in one loop and is the
//! only thread that writes to the socket. (Phase 3 moves audio onto its own thread.)

use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::thread;
use std::time::Duration;
use tracing::{error, info, warn};

use clack_extensions::params::PluginParams;
use clack_extensions::timer::PluginTimer;
use clack_host::events::io::{InputEvents, OutputEvents};

use crate::audio::ipc::{
    wire, HostMessage, HostRequest, PluginCommand, PluginEvent, PluginResponse,
};
use crate::plugin_host::commands::process_command;
use crate::plugin_host::state::{
    has_audio_to_process, process_audio, process_output_events, PluginState,
};

/// What the reader thread hands to the main loop.
enum Incoming {
    Request(HostRequest, Vec<OwnedFd>),
    /// The engine closed the control socket (or it failed): time to exit.
    Closed,
}

/// Reader thread: decode requests until the socket closes.
fn read_requests(socket: UnixStream, tx: Sender<Incoming>) {
    loop {
        match wire::recv_frame::<HostRequest>(&socket) {
            Ok(Some((request, fds))) => {
                if tx.send(Incoming::Request(request, fds)).is_err() {
                    return;
                }
            }
            Ok(None) => {
                info!("Control socket closed, shutting down");
                break;
            }
            Err(e) => {
                error!("Control socket read failed: {}", e);
                break;
            }
        }
    }
    let _ = tx.send(Incoming::Closed);
}

/// Send a message to the engine. Exits the process if the engine has gone away.
fn send(socket: &UnixStream, msg: &HostMessage) {
    if let Err(e) = wire::send_frame(socket, msg, &[]) {
        if matches!(
            e.kind(),
            std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset
        ) {
            info!("Engine closed the control socket, shutting down");
            // SAFETY: exits without running destructors; the OS reclaims everything
            unsafe { libc::_exit(0) };
        }
        warn!("Failed to send {:?}: {}", msg, e);
    }
}

/// Handle one request. Returns false when the host should exit.
fn handle_incoming(
    incoming: Incoming,
    socket: &UnixStream,
    plugin_state: &mut Option<PluginState>,
    event_tx: &Sender<HostMessage>,
) -> bool {
    let (request, fds) = match incoming {
        Incoming::Request(request, fds) => (request, fds),
        Incoming::Closed => return false,
    };
    let HostRequest {
        instance_id,
        request_id,
        command,
    } = request;

    if matches!(command, PluginCommand::Shutdown) {
        // Exit immediately without any logging or drops; the OS cleans up
        // SAFETY: see above
        unsafe { libc::_exit(0) };
    }

    info!(
        "📥 Received command for instance {}: {:?}",
        instance_id, command
    );

    let response = match plugin_state {
        Some(state)
            if state.instance_id != instance_id
                && !matches!(command, PluginCommand::Initialize { .. }) =>
        {
            Some(PluginResponse::Error {
                command: format!("{:?}", command),
                error: format!(
                    "Unknown instance {} (this host holds instance {})",
                    instance_id, state.instance_id
                ),
            })
        }
        _ => process_command(command, instance_id, fds, plugin_state, event_tx),
    };

    if let Some(response) = response {
        info!("📤 Sending response: {:?}", response);
        send(
            socket,
            &HostMessage::Response {
                instance_id,
                request_id,
                response,
            },
        );
    }
    true
}

/// Main plugin host event loop
///
/// Runs on the main thread (CLAP's main thread) until the engine closes the control socket.
pub fn run_plugin_host(socket: UnixStream) -> Result<(), Box<dyn std::error::Error>> {
    let (incoming_tx, incoming_rx): (Sender<Incoming>, Receiver<Incoming>) = mpsc::channel();
    let reader_socket = socket.try_clone()?;
    thread::Builder::new()
        .name("ipc-reader".to_string())
        .spawn(move || read_requests(reader_socket, incoming_tx))?;

    let mut plugin_state: Option<PluginState> = None;

    // Unsolicited messages from plugin callbacks (GUI resize requests)
    let (event_tx, event_rx) = mpsc::channel::<HostMessage>();

    info!("📡 Listening for commands...");

    loop {
        // Handle every request that has arrived
        let mut command_received = false;
        loop {
            match incoming_rx.try_recv() {
                Ok(incoming) => {
                    if !handle_incoming(incoming, &socket, &mut plugin_state, &event_tx) {
                        return Ok(());
                    }
                    command_received = true;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return Ok(()),
            }
        }

        // Process audio, GUI callbacks, and timers (separate from command handling)
        let mut processed_audio = false;
        if let Some(ref mut state) = plugin_state {
            // Process audio if plugin is activated and processing
            // Keep processing in a loop until input buffer is empty
            if state.activated && state.processing {
                // Process up to 8 chunks per iteration to keep up with real-time
                for _ in 0..8 {
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

            // Parameter list or ranges changed: rebuild the map on next use
            if state.shared.take_params_rescanned() {
                state.param_map = None;
            }

            // Process GUI callbacks if plugin is open
            // This is the critical call that keeps plugin GUIs responsive
            if state.gui_open {
                state.instance.call_on_main_thread_callback();
            }

            // GUI parameter changes are only visible through output events, which only come
            // from process() or flush(). Flush while the GUI is open, or when the plugin asks.
            if state.shared.take_flush_requested() || state.gui_open {
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

            // Report parameter changes to the engine, by the engine's parameter index
            if !state.pending_param_changes.is_empty() {
                let changes = std::mem::take(&mut state.pending_param_changes);
                for &(clap_id, value) in &changes {
                    let Some((param_id, entry)) = state.param_map().find(clap_id) else {
                        continue;
                    };
                    let normalized = entry.normalize(value);
                    send(
                        &socket,
                        &HostMessage::Event {
                            instance_id: state.instance_id,
                            event: PluginEvent::ParameterValueChanged {
                                param_id,
                                value: normalized,
                            },
                        },
                    );
                    info!(
                        "📤 Sent ParameterValueChanged: param_id={}, value={:.4}",
                        param_id, normalized
                    );
                }
                // Keep the allocation for the next round
                state.pending_param_changes = changes;
                state.pending_param_changes.clear();
            }
        }

        // Forward unsolicited messages from plugin callbacks (GUI resize requests, etc.)
        while let Ok(msg) = event_rx.try_recv() {
            info!("📤 Sending event: {:?}", msg);
            send(&socket, &msg);
        }

        // Idle: wait briefly for the next request instead of spinning
        if !processed_audio && !command_received {
            match incoming_rx.recv_timeout(Duration::from_millis(1)) {
                Ok(incoming) => {
                    if !handle_incoming(incoming, &socket, &mut plugin_state, &event_tx) {
                        return Ok(());
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return Ok(()),
            }
        }
    }
}
