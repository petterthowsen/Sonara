//! One plugin host process: its control socket, requests, hung and crash detection, shutdown.

use crossbeam::channel::{self, RecvTimeoutError};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Child;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{debug, info, warn};

use super::crash::HostCrash;
use super::lock;
use super::routing::Routing;
use crate::audio::ipc::protocol::{
    HostRequest, InstanceId, PluginCommand, PluginResponse, RequestId, NO_REPLY,
};
use crate::audio::ipc::shared_memory::HostSharedMemory;
use crate::audio::ipc::wire;

/// How long a host gets to exit after `Shutdown` before it is killed.
pub(super) const SHUTDOWN_GRACE: Duration = Duration::from_secs(1);

/// How long the watcher waits for a killed host to be reaped before giving up on it.
pub(super) const KILL_REAP_GRACE: Duration = Duration::from_millis(500);

/// How long `crash_info` waits for the watcher to record the exit status.
pub(super) const CRASH_STATUS_GRACE: Duration = Duration::from_millis(250);

/// Request timeout while a host runs under a debugger or wrapper: it may sit at a breakpoint, or
/// run tens of times slower under valgrind. Long, but still bounded.
pub(super) const DEBUG_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

/// One plugin host process and its control socket.
pub struct PluginProcess {
    /// Process ID
    pub pid: u32,
    pub(super) host_key: String,
    /// The child handle, shared with the watcher thread that reaps it.
    pub(super) child: Arc<Mutex<Option<Child>>>,
    /// Write side of the control socket. Held only while a frame is written.
    pub(super) writer: Mutex<UnixStream>,
    pub(super) routing: Arc<Routing>,
    pub(super) next_request_id: AtomicU32,
    /// One doorbell word shared with this host, used by the per-block audio handshake and by
    /// every instance that will share this host in later phases.
    pub(super) host_shared: Arc<HostSharedMemory>,
    /// Runs under a debugger or wrapper: no hung detection, long request timeouts.
    pub(super) debugging: bool,
    /// The host's log file, when its name is known.
    pub(super) log_path: Option<PathBuf>,
    /// The wrapper program the host runs under, if any.
    pub(super) wrapper: Option<String>,
}

impl PluginProcess {
    pub(super) fn next_request_id(&self) -> RequestId {
        loop {
            let id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
            if id != NO_REPLY {
                return id;
            }
        }
    }

    pub(super) fn write(&self, request: &HostRequest, fds: &[i32]) -> Result<(), String> {
        if !self.routing.connected.load(Ordering::Acquire) {
            return Err(format!("Plugin host {} is not running", self.host_key));
        }
        let writer = lock(&self.writer);
        wire::send_frame(&writer, request, fds)
            .map_err(|e| format!("Failed to send to plugin host {}: {}", self.host_key, e))
    }

    /// Send a command and wait up to `timeout` for its reply.
    pub(super) fn request_with_fds(
        &self,
        instance_id: InstanceId,
        command: PluginCommand,
        fds: &[i32],
        timeout: Duration,
    ) -> Result<PluginResponse, String> {
        let timeout = if self.debugging {
            timeout.max(DEBUG_REQUEST_TIMEOUT)
        } else {
            timeout
        };
        let request_id = self.next_request_id();
        let (tx, rx) = channel::bounded(1);
        lock(&self.routing.pending).insert(request_id, tx);

        let request = HostRequest {
            instance_id,
            request_id,
            command,
        };
        if let Err(e) = self.write(&request, fds) {
            lock(&self.routing.pending).remove(&request_id);
            return Err(e);
        }

        match rx.recv_timeout(timeout) {
            Ok(response) => Ok(response),
            Err(RecvTimeoutError::Timeout) => {
                lock(&self.routing.pending).remove(&request_id);
                self.record_timeout(&request.command);
                Err(format!(
                    "Plugin host {} didn't answer {:?} within {:.1}s",
                    self.host_key,
                    request.command,
                    timeout.as_secs_f32()
                ))
            }
            Err(RecvTimeoutError::Disconnected) => Err(format!(
                "Plugin host {} exited before answering {:?}",
                self.host_key, request.command
            )),
        }
    }

    /// A request timed out. A host that lets a request time out is unresponsive: the command
    /// thread kills it on its next tick and treats it as crashed. Not while another instance is
    /// loading in it, though (its main thread is busy, not stuck), nor under a debugger (it may
    /// be stopped on purpose). An `Initialize` that times out itself always counts, unless
    /// debugging.
    pub(super) fn record_timeout(&self, command: &PluginCommand) {
        if self.debugging {
            return;
        }
        let initializing = matches!(command, PluginCommand::Initialize { .. });
        let loading_other = self.routing.initializing.load(Ordering::Acquire) > 0;
        if initializing || !loading_other {
            self.routing.hung.store(true, Ordering::Release);
        }
    }

    /// Send a command without waiting for a reply.
    pub(super) fn send(
        &self,
        instance_id: InstanceId,
        command: PluginCommand,
    ) -> Result<(), String> {
        self.write(
            &HostRequest {
                instance_id,
                request_id: NO_REPLY,
                command,
            },
            &[],
        )
    }

    /// This host's doorbell word, shared with every instance that runs in it.
    pub fn host_shared(&self) -> &Arc<HostSharedMemory> {
        &self.host_shared
    }

    /// False once the control socket has closed or the process has exited.
    pub fn is_alive(&self) -> bool {
        if !self.routing.connected.load(Ordering::Acquire) {
            return false;
        }
        if lock(&self.routing.exit).is_some() {
            return false;
        }
        // No child handle means an in-process stand-in (tests): trust the socket.
        match lock(&self.child).as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            None => true,
        }
    }

    /// True when a blocking request timed out and the host hasn't answered since.
    pub fn is_hung(&self) -> bool {
        self.routing.hung.load(Ordering::Acquire)
    }

    /// True when the host runs under a debugger or wrapper (no hung detection).
    pub fn is_debugging(&self) -> bool {
        self.debugging
    }

    /// Why this host stopped, or None while it is still running. Waits briefly for the watcher
    /// to record the exit status, so a crash report has the signal or exit code.
    pub fn crash_info(&self) -> Option<HostCrash> {
        let deadline = Instant::now() + CRASH_STATUS_GRACE;
        loop {
            if lock(&self.routing.exit).is_some() {
                return Some(self.routing.crash(self));
            }
            // `is_alive` also reaps the child itself (`try_wait`), so it can see an exit before the
            // watcher has stored it in `routing.exit`: a dead child counts as suspicious too, and
            // the loop then waits for the watcher.
            let suspicious = !self.is_alive() || self.is_hung();
            if !suspicious || Instant::now() >= deadline {
                if suspicious {
                    return Some(self.routing.crash(self));
                }
                return None;
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    /// Kill the host process now, for a host that stopped responding. The watcher reaps it.
    pub fn kill(&self) {
        warn!("Killing plugin host {} (pid {})", self.host_key, self.pid);
        if let Some(child) = lock(&self.child).as_mut() {
            if let Err(e) = child.kill() {
                warn!("Failed to kill plugin host {}: {}", self.host_key, e);
            }
        }
        // The socket reader sees the close and fails pending requests; the watcher records the
        // exit status. Nothing here waits, so the command thread isn't held up.
        let _ = lock(&self.writer).shutdown(std::net::Shutdown::Both);
    }

    /// Ask the host to exit, then kill it if it hasn't within `SHUTDOWN_GRACE`. The watcher
    /// thread reaps the process; this waits for it to record the exit status.
    pub fn shutdown(&self) {
        info!("Shutting down plugin host {}", self.host_key);
        if self.routing.connected.load(Ordering::Acquire) {
            if let Err(e) = self.send(0, PluginCommand::Shutdown) {
                warn!("{}", e);
            }
        }
        let _ = lock(&self.writer).shutdown(std::net::Shutdown::Write);

        let deadline = Instant::now() + SHUTDOWN_GRACE;
        while lock(&self.routing.exit).is_none()
            && lock(&self.child).is_some()
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(10));
        }
        if lock(&self.routing.exit).is_some() || lock(&self.child).is_none() {
            debug!("Plugin host {} exited", self.host_key);
            return;
        }

        warn!(
            "Plugin host {} didn't exit within {:?}; killing it",
            self.host_key, SHUTDOWN_GRACE
        );
        if let Some(child) = lock(&self.child).as_mut() {
            let _ = child.kill();
        }
        let deadline = Instant::now() + KILL_REAP_GRACE;
        while lock(&self.routing.exit).is_none() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for PluginProcess {
    fn drop(&mut self) {
        // Kill without waiting for the grace period: Drop runs when the host is being thrown
        // away anyway (device removed, engine shutting down). The watcher reaps it.
        let alive = self.is_alive();
        if alive {
            warn!("Force killing plugin host {} in Drop", self.host_key);
            if let Some(child) = lock(&self.child).as_mut() {
                let _ = child.kill();
            }
        }
    }
}
