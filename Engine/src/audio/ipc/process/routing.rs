//! What a host's reader thread routes: replies to waiting requests and events to their instance.

use crossbeam::channel::Sender;
use std::collections::{HashMap, VecDeque};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use tracing::{debug, error, info, warn};

use super::crash::{HostCrash, HostExit};
use super::lock;
use super::process::PluginProcess;
use crate::audio::ipc::protocol::{
    HostMessage, InstanceId, LogLevel, PluginEvent, PluginResponse, RequestId, NO_REPLY,
};
use crate::audio::ipc::wire;

/// State shared between a host's `PluginProcess` and its reader thread.
pub(super) struct Routing {
    /// Requests waiting for a reply, by request id.
    pub(super) pending: Mutex<HashMap<RequestId, Sender<PluginResponse>>>,
    /// Where each instance's unsolicited events go.
    pub(super) events: Mutex<HashMap<InstanceId, Sender<PluginEvent>>>,
    /// False once the control socket has closed.
    pub(super) connected: AtomicBool,
    /// Set by the watcher thread once the host process has been reaped.
    pub(super) exit: Mutex<Option<HostExit>>,
    /// Last lines of the host's stderr, oldest first.
    pub(super) stderr_tail: Mutex<VecDeque<String>>,
    /// Set when a blocking request timed out. The command thread kills a hung host (Phase 4).
    pub(super) hung: AtomicBool,
    /// `Initialize` requests in flight. Loading a plugin can keep a shared host's main thread
    /// busy for many seconds, so while one runs, other requests timing out don't mean the host
    /// is hung.
    pub(super) initializing: AtomicU32,
}

impl Routing {
    pub(super) fn dispatch(&self, host: &str, msg: HostMessage) {
        match msg {
            HostMessage::Response {
                instance_id,
                request_id,
                response,
            } => {
                let waiter = lock(&self.pending).remove(&request_id);
                match waiter {
                    Some(tx) => {
                        let _ = tx.send(response);
                    }
                    None if request_id == NO_REPLY => {
                        if let PluginResponse::Error { command, error } = response {
                            warn!(
                                "Plugin host {} instance {}: {} failed: {}",
                                host, instance_id, command, error
                            );
                        }
                    }
                    None => debug!(
                        "Plugin host {} instance {}: dropping late response to request {}: {:?}",
                        host, instance_id, request_id, response
                    ),
                }
            }
            HostMessage::Log {
                instance_id,
                plugin,
                level,
                message,
            } => {
                // Logged again here so the line reaches the engine log and, through the log
                // forwarder, Godot's `/log`. The host's own log file has the full context.
                let source = match (instance_id, plugin.is_empty()) {
                    (0, _) => format!("Plugin host {}", host),
                    (id, true) => format!("Plugin instance {} (host {})", id, host),
                    (id, false) => format!("Plugin {} (instance {}, host {})", plugin, id, host),
                };
                match level {
                    LogLevel::Warn => warn!("{}: {}", source, message),
                    LogLevel::Error => error!("{}: {}", source, message),
                }
            }
            HostMessage::Event { instance_id, event } => {
                let events = lock(&self.events);
                match events.get(&instance_id) {
                    Some(tx) => {
                        let _ = tx.send(event);
                    }
                    None => debug!(
                        "Plugin host {}: event for unknown instance {}: {:?}",
                        host, instance_id, event
                    ),
                }
            }
        }
    }

    /// The socket closed: fail every waiting request and disconnect the event channels.
    pub(super) fn disconnect(&self) {
        self.connected.store(false, Ordering::Release);
        lock(&self.pending).clear();
        lock(&self.events).clear();
    }

    /// Why the host stopped, as far as the watcher has seen.
    pub(super) fn crash(&self, process: &PluginProcess) -> HostCrash {
        HostCrash {
            host_key: process.host_key.clone(),
            pid: process.pid,
            exit: *lock(&self.exit),
            stderr_tail: lock(&self.stderr_tail).iter().cloned().collect(),
            log_path: process.log_path.clone(),
            wrapper: process.wrapper.clone(),
        }
    }
}

/// Reader thread: decode frames until the host closes the socket.
pub(super) fn run_reader(socket: UnixStream, routing: Arc<Routing>, host: String) {
    loop {
        match wire::recv_frame::<HostMessage>(&socket) {
            Ok(Some((msg, _fds))) => routing.dispatch(&host, msg),
            Ok(None) => {
                info!("Plugin host {} closed its control socket", host);
                break;
            }
            Err(e) => {
                error!("Plugin host {} control socket failed: {}", host, e);
                break;
            }
        }
    }
    routing.disconnect();
}
