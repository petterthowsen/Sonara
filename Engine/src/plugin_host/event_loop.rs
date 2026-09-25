//! Main event loop for the plugin host subprocess.
//!
//! A reader thread decodes requests from the control socket and hands them to the main thread,
//! which handles commands, GUI callbacks and timers and is the only thread that writes to the
//! socket. Audio runs on its own thread (`audio_thread.rs`), which owns every instance's processor
//! and shared block.
//!
//! One host process can hold several plugin instances (hosting modes, Phase 5); every request
//! names the instance it is for.

use std::collections::HashMap;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tracing::{debug, error, info, warn};

use clack_extensions::params::PluginParams;
use clack_extensions::timer::PluginTimer;
use clack_host::events::event_types::ParamValueEvent;
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};

use crate::audio::ipc::{
    wire, HostMessage, HostRequest, HostSharedMemory, InstanceId, PluginCommand, PluginEvent,
};
use crate::plugin_host::audio_thread::{self, AudioThreadHandle};
use crate::plugin_host::commands::process_command;
use crate::plugin_host::logging;
use crate::plugin_host::state::PluginState;

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
        if matches!(msg, HostMessage::Log { .. }) {
            // A warning here would be forwarded and fail again.
            debug!("Failed to forward a log line: {}", e);
        } else {
            warn!("Failed to send {:?}: {}", msg, e);
        }
    }
}

/// Handle one request. Returns false when the host should exit.
fn handle_incoming(
    incoming: Incoming,
    socket: &UnixStream,
    instances: &mut HashMap<InstanceId, PluginState>,
    event_tx: &Sender<HostMessage>,
    audio: &AudioThreadHandle,
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
        audio.shutdown();
        // Exit immediately without any logging or drops; the OS cleans up
        // SAFETY: see above
        unsafe { libc::_exit(0) };
    }

    // Log everything done for this command under the instance's span, so each line names the
    // plugin. A new instance gets a provisional span from its plugin id until it has loaded.
    let span = match (instances.get(&instance_id), &command) {
        (Some(state), _) => state.span.clone(),
        (None, PluginCommand::Initialize { plugin_id, .. }) => {
            logging::instance_span(instance_id, plugin_id)
        }
        (None, _) => logging::instance_span(instance_id, ""),
    };
    let _entered = span.enter();

    info!(
        "📥 Received command for instance {}: {:?}",
        instance_id, command
    );

    // The instance's slot: None for an unknown instance, which every command but Initialize
    // answers with "not initialized". Unload leaves it None.
    let mut slot = instances.remove(&instance_id);
    let response = process_command(command, instance_id, fds, &mut slot, event_tx, audio);
    if let Some(state) = slot {
        instances.insert(instance_id, state);
    }

    if let Some(response) = response {
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

/// Run the main-thread work the plugin requires: timers, `on_main_thread` and `params.flush`.
///
/// Audio is on its own thread, so a slow plugin GUI never delays a block.
fn service_plugin_side(
    socket: &UnixStream,
    state: &mut PluginState,
    audio: &AudioThreadHandle,
    flush_events: &mut EventBuffer,
) {
    // Process timers - check which ones need to fire
    let triggered_timers = state.shared.tick_timers();
    if !triggered_timers.is_empty() {
        let mut handle = state.instance.plugin_handle();
        if let Some(timer_ext) = handle.get_extension::<PluginTimer>() {
            for timer_id in triggered_timers {
                timer_ext.on_timer(&mut handle, timer_id);
            }
        }
    }

    // Process GUI callbacks if plugin is open
    if state.gui_open {
        state.instance.call_on_main_thread_callback();
    }

    // GUI parameter changes are only visible through output events, which only come from
    // process() or flush(). CLAP forbids flush concurrently with process(), and requires it on
    // the audio thread while the plugin is active, so an active plugin is flushed there, between
    // blocks, when it asks. nih-plug aborts on a concurrent flush (its event queue is borrowed
    // by process()). An inactive plugin is flushed here, also while its GUI is open.
    let flush_requested = state.shared.take_flush_requested();
    let changes: Vec<(u32, f32)> = if state.activated {
        if !flush_requested {
            return;
        }
        audio.flush(state.instance_id)
    } else if flush_requested || state.gui_open {
        flush_events.clear();
        {
            let mut handle = state.instance.plugin_handle();
            if let Some(params_ext) = handle.get_extension::<PluginParams>() {
                let input_events = InputEvents::empty();
                let mut output_events = OutputEvents::from_buffer(flush_events);
                params_ext.flush(&mut handle, &input_events, &mut output_events);
            }
        }
        let param_map = Arc::clone(state.param_map());
        flush_events
            .iter()
            .filter_map(|event| {
                let param_event = event.as_event::<ParamValueEvent>()?;
                let (param_id, entry) = param_map.find(param_event.param_id()?)?;
                Some((param_id, entry.normalize(param_event.value())))
            })
            .collect()
    } else {
        return;
    };

    for (param_id, value) in changes {
        send(
            socket,
            &HostMessage::Event {
                instance_id: state.instance_id,
                event: PluginEvent::ParameterValueChanged { param_id, value },
            },
        );
    }
}

/// Main plugin host event loop.
///
/// Runs on the main thread (CLAP's main thread) until the engine closes the control socket. Audio
/// runs on a second thread that owns the plugin's audio processor and the shared block.
///
/// `log_rx` carries the WARN and ERROR lines `logging::init` forwards to the engine.
pub fn run_plugin_host(
    socket: UnixStream,
    doorbell: Arc<HostSharedMemory>,
    log_rx: Receiver<HostMessage>,
) -> Result<(), Box<dyn std::error::Error>> {
    let (incoming_tx, incoming_rx): (Sender<Incoming>, Receiver<Incoming>) = mpsc::channel();
    let reader_socket = socket.try_clone()?;
    thread::Builder::new()
        .name("ipc-reader".to_string())
        .spawn(move || read_requests(reader_socket, incoming_tx))?;

    let mut instances: HashMap<InstanceId, PluginState> = HashMap::new();

    // Unsolicited messages from plugin callbacks (GUI resize requests)
    let (event_tx, event_rx) = mpsc::channel::<HostMessage>();

    // Audio thread: owns the processor and the instance's shared block.
    let audio = audio_thread::spawn(doorbell.clone())?;

    let mut flush_events = EventBuffer::new();

    info!("📡 Listening for commands...");

    loop {
        // Handle every request that has arrived
        loop {
            match incoming_rx.try_recv() {
                Ok(incoming) => {
                    if !handle_incoming(incoming, &socket, &mut instances, &event_tx, &audio) {
                        return Ok(());
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return Ok(()),
            }
        }

        for state in instances.values_mut() {
            // Parameter list or ranges changed: rebuild the map and publish it to the audio
            // thread.
            if state.shared.take_params_rescanned() {
                state.param_map = None;
                let map = Arc::clone(state.param_map());
                audio.set_param_map(state.instance_id, map);
                info!(
                    "Parameter map of instance {} rebuilt after rescan",
                    state.instance_id
                );
            }

            // Plugin-required main-thread work (timers, GUI callbacks, parameter flush).
            let span = state.span.clone();
            let _entered = span.enter();
            service_plugin_side(&socket, state, &audio, &mut flush_events);
        }

        // Forward unsolicited messages from plugin callbacks (GUI resize requests, etc.)
        while let Ok(msg) = event_rx.try_recv() {
            info!("📤 Sending event: {:?}", msg);
            send(&socket, &msg);
        }

        // Forward warnings and errors to the engine (rate-limited by the logging layer). Not
        // logged again here: that would forward the forwarding.
        while let Ok(msg) = log_rx.try_recv() {
            send(&socket, &msg);
        }

        // Idle: wait briefly for the next request instead of spinning. Audio runs on its own
        // thread, so this loop only wakes for commands and timers.
        match incoming_rx.recv_timeout(Duration::from_millis(1)) {
            Ok(incoming) => {
                if !handle_incoming(incoming, &socket, &mut instances, &event_tx, &audio) {
                    return Ok(());
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Ok(()),
        }
    }
}
