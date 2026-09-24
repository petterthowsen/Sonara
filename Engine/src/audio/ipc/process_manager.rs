//! Plugin Process Manager
//!
//! Spawns plugin host processes and routes messages to the plugin instances inside them.
//!
//! Each host process has one control socket (a Unix socketpair) and a reader thread. Requests
//! carry a `request_id`; the reader thread completes the waiting request when the matching
//! response arrives. Unsolicited events go to a per-instance channel that the command thread
//! drains. Writes are serialized by a mutex that is only held while a frame is written, so a
//! slow request never blocks other senders.

use crossbeam::channel::{self, Receiver, RecvTimeoutError, Sender};
use std::collections::HashMap;
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{debug, error, info, warn};

use super::protocol::{
    HostMessage, HostRequest, InstanceId, PluginCommand, PluginEvent, PluginResponse, RequestId,
    SharedMemoryLayout, NO_REPLY,
};
use super::shared_memory::{HostSharedMemory, SharedMemory};
use super::wire;

/// Default wait for a blocking request's reply.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// Wait for `Initialize`: loading a plugin can read large sample libraries.
const INITIALIZE_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a host gets to exit after `Shutdown` before it is killed.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(1);

/// The control socket's descriptor number in the host process.
const HOST_SOCKET_FD: i32 = 3;

/// The host doorbell region's descriptor number in the host process.
const HOST_SHARED_MEMORY_FD: i32 = 4;

/// Lock a mutex, recovering it if a panicking thread held it.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `dup2` `fd` onto `target` in a freshly forked child, clearing close-on-exec so the descriptor
/// survives `exec`. A no-op when the numbers already match.
fn move_fd_to(fd: RawFd, target: RawFd) -> std::io::Result<()> {
    if fd != target {
        if unsafe { libc::dup2(fd, target) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        unsafe { libc::close(fd) };
    }
    let flags = unsafe { libc::fcntl(target, libc::F_GETFD) };
    if flags >= 0 {
        unsafe { libc::fcntl(target, libc::F_SETFD, flags & !libc::FD_CLOEXEC) };
    }
    Ok(())
}

/// State shared between a host's `PluginProcess` and its reader thread.
struct Routing {
    /// Requests waiting for a reply, by request id.
    pending: Mutex<HashMap<RequestId, Sender<PluginResponse>>>,
    /// Where each instance's unsolicited events go.
    events: Mutex<HashMap<InstanceId, Sender<PluginEvent>>>,
    /// False once the control socket has closed.
    connected: AtomicBool,
}

impl Routing {
    fn dispatch(&self, host: &str, msg: HostMessage) {
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
    fn disconnect(&self) {
        self.connected.store(false, Ordering::Release);
        lock(&self.pending).clear();
        lock(&self.events).clear();
    }
}

/// Reader thread: decode frames until the host closes the socket.
fn run_reader(socket: UnixStream, routing: Arc<Routing>, host: String) {
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

/// One plugin host process and its control socket.
pub struct PluginProcess {
    /// Process ID
    pub pid: u32,
    host_key: String,
    child: Mutex<Option<Child>>,
    /// Write side of the control socket. Held only while a frame is written.
    writer: Mutex<UnixStream>,
    routing: Arc<Routing>,
    next_request_id: AtomicU32,
    /// One doorbell word shared with this host, used by the per-block audio handshake and by
    /// every instance that will share this host in later phases.
    host_shared: Arc<HostSharedMemory>,
}

impl PluginProcess {
    /// Spawn a `plugin_host` process and start its reader thread.
    fn spawn(host_key: String) -> Result<Self, String> {
        let plugin_host_path = ProcessManager::plugin_host_path()?;

        let (engine_socket, host_socket) = UnixStream::pair()
            .map_err(|e| format!("Failed to create control socketpair: {}", e))?;
        let host_socket_fd = host_socket.as_raw_fd();

        let host_shared = Arc::new(HostSharedMemory::new(&format!(
            "sonara_host_{}",
            host_key.replace(['/', '-'], "_")
        ))?);
        let host_shared_fd = host_shared.as_raw_fd();

        use std::os::unix::process::CommandExt;
        let child = unsafe {
            Command::new(&plugin_host_path)
                .arg(HOST_SOCKET_FD.to_string())
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .pre_exec(move || {
                    // Move both descriptors to their well-known numbers. dup2 clears
                    // close-on-exec on the new descriptor, except when both are equal.
                    move_fd_to(host_socket_fd, HOST_SOCKET_FD)?;
                    move_fd_to(host_shared_fd, HOST_SHARED_MEMORY_FD)?;
                    Ok(())
                })
                .spawn()
                .map_err(|e| {
                    format!(
                        "Failed to spawn plugin_host at {}: {}",
                        plugin_host_path.display(),
                        e
                    )
                })?
        };
        drop(host_socket);

        let pid = child.id();
        info!("Plugin host {} spawned: PID={}", host_key, pid);
        Self::connect(host_key, pid, Some(child), engine_socket, host_shared)
    }

    /// Start the reader thread for a host connected through `engine_socket`.
    fn connect(
        host_key: String,
        pid: u32,
        child: Option<Child>,
        engine_socket: UnixStream,
        host_shared: Arc<HostSharedMemory>,
    ) -> Result<Self, String> {
        let routing = Arc::new(Routing {
            pending: Mutex::new(HashMap::new()),
            events: Mutex::new(HashMap::new()),
            connected: AtomicBool::new(true),
        });
        let reader_socket = engine_socket
            .try_clone()
            .map_err(|e| format!("Failed to clone control socket: {}", e))?;
        let reader_routing = Arc::clone(&routing);
        let reader_host = format!("{} (pid {})", host_key, pid);
        thread::Builder::new()
            .name(format!("plugin-ipc-{}", pid))
            .spawn(move || run_reader(reader_socket, reader_routing, reader_host))
            .map_err(|e| format!("Failed to start plugin host reader thread: {}", e))?;

        Ok(Self {
            pid,
            host_key,
            child: Mutex::new(child),
            writer: Mutex::new(engine_socket),
            routing,
            next_request_id: AtomicU32::new(1),
            host_shared,
        })
    }

    fn next_request_id(&self) -> RequestId {
        loop {
            let id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
            if id != NO_REPLY {
                return id;
            }
        }
    }

    fn write(&self, request: &HostRequest, fds: &[i32]) -> Result<(), String> {
        if !self.routing.connected.load(Ordering::Acquire) {
            return Err(format!("Plugin host {} is not running", self.host_key));
        }
        let writer = lock(&self.writer);
        wire::send_frame(&writer, request, fds)
            .map_err(|e| format!("Failed to send to plugin host {}: {}", self.host_key, e))
    }

    /// Send a command and wait up to `timeout` for its reply.
    fn request_with_fds(
        &self,
        instance_id: InstanceId,
        command: PluginCommand,
        fds: &[i32],
        timeout: Duration,
    ) -> Result<PluginResponse, String> {
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

    /// Send a command without waiting for a reply.
    fn send(&self, instance_id: InstanceId, command: PluginCommand) -> Result<(), String> {
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
        match lock(&self.child).as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            None => false,
        }
    }

    /// Ask the host to exit, then kill it if it hasn't within `SHUTDOWN_GRACE`.
    pub fn shutdown(&self) {
        info!("Shutting down plugin host {}", self.host_key);
        if self.routing.connected.load(Ordering::Acquire) {
            if let Err(e) = self.send(0, PluginCommand::Shutdown) {
                warn!("{}", e);
            }
        }
        let _ = lock(&self.writer).shutdown(std::net::Shutdown::Write);

        let Some(mut child) = lock(&self.child).take() else {
            return;
        };
        let deadline = Instant::now() + SHUTDOWN_GRACE;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    info!("Plugin host {} exited: {}", self.host_key, status);
                    return;
                }
                Ok(None) if Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(10));
                }
                Ok(None) => {
                    warn!(
                        "Plugin host {} didn't exit within {:?}; killing it",
                        self.host_key, SHUTDOWN_GRACE
                    );
                    let _ = child.kill();
                    let _ = child.wait();
                    return;
                }
                Err(e) => {
                    error!("Error waiting for plugin host {}: {}", self.host_key, e);
                    return;
                }
            }
        }
    }
}

impl Drop for PluginProcess {
    fn drop(&mut self) {
        if let Some(mut child) = lock(&self.child).take() {
            if matches!(child.try_wait(), Ok(None)) {
                warn!("Force killing plugin host {} in Drop", self.host_key);
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

/// Connection to one plugin instance: its host process, event channel and shared memory.
/// Cheap to clone; every clone talks to the same instance.
#[derive(Clone)]
pub struct InstanceConnection {
    instance_id: InstanceId,
    host: Arc<PluginProcess>,
    events: Receiver<PluginEvent>,
    shared_memory: Arc<SharedMemory>,
    host_shared: Arc<HostSharedMemory>,
}

impl InstanceConnection {
    /// Send a command and wait up to `timeout` for the reply.
    pub fn request(
        &self,
        command: PluginCommand,
        timeout: Duration,
    ) -> Result<PluginResponse, String> {
        self.host
            .request_with_fds(self.instance_id, command, &[], timeout)
    }

    /// Send a command without waiting. Errors the host reports are logged.
    pub fn send(&self, command: PluginCommand) -> Result<(), String> {
        self.host.send(self.instance_id, command)
    }

    /// Next unsolicited event from the instance, if any. Never blocks.
    pub fn try_event(&self) -> Option<PluginEvent> {
        self.events.try_recv().ok()
    }

    pub fn is_alive(&self) -> bool {
        self.host.is_alive()
    }

    pub fn shared_memory(&self) -> &Arc<SharedMemory> {
        &self.shared_memory
    }

    /// The host process's doorbell word, shared by every instance in that host.
    pub fn host_shared(&self) -> &Arc<HostSharedMemory> {
        &self.host_shared
    }

    pub fn host_pid(&self) -> u32 {
        self.host.pid
    }
}

/// Plugin process manager: host key → host process, instance id → instance.
pub struct ProcessManager {
    hosts: Mutex<HashMap<String, Arc<PluginProcess>>>,
    instances: Mutex<HashMap<InstanceId, InstanceConnection>>,
    next_instance_id: AtomicU32,
}

impl ProcessManager {
    /// Create a new process manager
    pub fn new() -> Self {
        Self {
            hosts: Mutex::new(HashMap::new()),
            instances: Mutex::new(HashMap::new()),
            next_instance_id: AtomicU32::new(1),
        }
    }

    /// Allocate an id for a new plugin instance.
    pub fn allocate_instance_id(&self) -> InstanceId {
        self.next_instance_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Host key that gives an instance a host process of its own ("Individually" hosting).
    pub fn individual_host_key(instance_id: InstanceId) -> String {
        format!("instance-{}", instance_id)
    }

    /// Locate the `plugin_host` binary, which must sit next to the running engine executable.
    /// Fails with an actionable message when it is missing (e.g. only `engine` was built).
    fn plugin_host_path() -> Result<PathBuf, String> {
        let exe_path = std::env::current_exe()
            .map_err(|e| format!("Failed to get current exe path: {}", e))?;
        let exe_dir = exe_path.parent().ok_or_else(|| {
            format!(
                "Engine executable has no parent dir: {}",
                exe_path.display()
            )
        })?;
        let plugin_host_path = exe_dir.join("plugin_host");

        if !plugin_host_path.is_file() {
            return Err(format!(
                "plugin_host binary not found at {}. Build all engine binaries with the same \
                 profile as the engine (e.g. `cargo build --release` in Engine/), or launch via \
                 Engine/run_release.sh",
                plugin_host_path.display()
            ));
        }

        Ok(plugin_host_path)
    }

    /// The live host for `host_key`, spawning one if there is none.
    fn host_for(&self, host_key: &str) -> Result<Arc<PluginProcess>, String> {
        let mut hosts = lock(&self.hosts);
        if let Some(host) = hosts.get(host_key) {
            if host.is_alive() {
                return Ok(Arc::clone(host));
            }
            warn!("Plugin host {} is dead; spawning a new one", host_key);
        }
        let host = Arc::new(PluginProcess::spawn(host_key.to_string())?);
        hosts.insert(host_key.to_string(), Arc::clone(&host));
        Ok(host)
    }

    /// Load a plugin as instance `instance_id` in the host process for `host_key`. Blocks until
    /// the plugin is loaded; call it off the audio and command threads.
    pub fn spawn_instance(
        &self,
        instance_id: InstanceId,
        host_key: &str,
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
    ) -> Result<InstanceConnection, String> {
        info!(
            "Loading plugin {} as instance {} in host {}",
            plugin_id, instance_id, host_key
        );
        let host = self.host_for(host_key)?;
        let connection_host_shared = Arc::clone(host.host_shared());

        let layout = SharedMemoryLayout::new(max_buffer_size);
        let shm_name = format!("sonara_plugin_{}_{}", host.pid, instance_id);
        let shared_memory = Arc::new(
            SharedMemory::new(&shm_name, layout)
                .map_err(|e| format!("Failed to create shared memory: {}", e))?,
        );

        let (events_tx, events_rx) = channel::unbounded();
        lock(&host.routing.events).insert(instance_id, events_tx);

        let result = host.request_with_fds(
            instance_id,
            PluginCommand::Initialize {
                plugin_path,
                plugin_id: plugin_id.clone(),
                sample_rate,
                max_buffer_size,
            },
            &[shared_memory.as_raw_fd()],
            INITIALIZE_TIMEOUT,
        );
        let error = match result {
            Ok(PluginResponse::InitializeSuccess { .. }) => None,
            Ok(PluginResponse::InitializeError { error }) => {
                Some(format!("Plugin initialization failed: {}", error))
            }
            Ok(other) => Some(format!("Unexpected response to Initialize: {:?}", other)),
            Err(e) => Some(e),
        };
        if let Some(error) = error {
            lock(&host.routing.events).remove(&instance_id);
            self.release_host_if_unused(&host);
            return Err(error);
        }

        info!(
            "Plugin {} initialized as instance {} (host pid {})",
            plugin_id, instance_id, host.pid
        );
        let connection = InstanceConnection {
            instance_id,
            host,
            events: events_rx,
            shared_memory,
            host_shared: Arc::clone(&connection_host_shared),
        };
        lock(&self.instances).insert(instance_id, connection.clone());
        Ok(connection)
    }

    /// The connection to a loaded instance.
    pub fn instance(&self, instance_id: InstanceId) -> Option<InstanceConnection> {
        lock(&self.instances).get(&instance_id).cloned()
    }

    /// Forget an instance and shut its host down if no other instance uses it.
    pub fn shutdown_instance(&self, instance_id: InstanceId) {
        let Some(connection) = lock(&self.instances).remove(&instance_id) else {
            return;
        };
        lock(&connection.host.routing.events).remove(&instance_id);
        self.release_host_if_unused(&connection.host);
    }

    /// Shut `host` down if no instance lives in it. An instance counts from the moment its event
    /// route is registered, so one that is still loading keeps the host alive.
    fn release_host_if_unused(&self, host: &Arc<PluginProcess>) {
        if host.is_alive() && !lock(&host.routing.events).is_empty() {
            return;
        }
        {
            let mut hosts = lock(&self.hosts);
            if hosts
                .get(&host.host_key)
                .is_some_and(|registered| Arc::ptr_eq(registered, host))
            {
                hosts.remove(&host.host_key);
            }
        }
        host.shutdown();
    }

    /// Shutdown all plugin processes
    pub fn shutdown_all(&self) {
        lock(&self.instances).clear();
        let hosts: Vec<_> = lock(&self.hosts).drain().map(|(_, host)| host).collect();
        for host in hosts {
            host.shutdown();
        }
    }
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A host process stood in for by the test: returns the engine side and the host's socket.
    fn fake_host() -> (PluginProcess, UnixStream) {
        let (engine_socket, host_socket) = UnixStream::pair().unwrap();
        let host_shared =
            Arc::new(HostSharedMemory::new("sonara_test_fake_host").expect("doorbell"));
        let process =
            PluginProcess::connect("test".to_string(), 0, None, engine_socket, host_shared)
                .unwrap();
        (process, host_socket)
    }

    fn recv_request(host: &UnixStream) -> HostRequest {
        wire::recv_frame::<HostRequest>(host).unwrap().unwrap().0
    }

    fn reply(host: &UnixStream, request: &HostRequest, response: PluginResponse) {
        let msg = HostMessage::Response {
            instance_id: request.instance_id,
            request_id: request.request_id,
            response,
        };
        wire::send_frame(host, &msg, &[]).unwrap();
    }

    #[test]
    fn responses_complete_their_own_request_even_out_of_order() {
        let (process, host) = fake_host();
        let process = Arc::new(process);

        let first = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::HasGui, &[], REQUEST_TIMEOUT)
            })
        };
        let a = recv_request(&host);
        let second = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::GetParameterInfo, &[], REQUEST_TIMEOUT)
            })
        };
        let b = recv_request(&host);
        assert_ne!(a.request_id, b.request_id);

        // Answer the second request first
        reply(
            &host,
            &b,
            PluginResponse::ParameterInfo { params: Vec::new() },
        );
        reply(
            &host,
            &a,
            PluginResponse::HasGuiResponse { supported: true },
        );

        assert!(matches!(
            first.join().unwrap(),
            Ok(PluginResponse::HasGuiResponse { supported: true })
        ));
        assert!(matches!(
            second.join().unwrap(),
            Ok(PluginResponse::ParameterInfo { .. })
        ));
    }

    #[test]
    fn timeout_then_late_reply_is_dropped() {
        let (process, host) = fake_host();
        let result =
            process.request_with_fds(1, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.unwrap_err().contains("didn't answer"));

        // The late reply must not complete the next request
        let late = recv_request(&host);
        reply(
            &host,
            &late,
            PluginResponse::HasGuiResponse { supported: true },
        );

        let process = Arc::new(process);
        let next = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::CloseGui, &[], REQUEST_TIMEOUT)
            })
        };
        let request = recv_request(&host);
        reply(&host, &request, PluginResponse::GuiClosed);
        assert!(matches!(
            next.join().unwrap(),
            Ok(PluginResponse::GuiClosed)
        ));
    }

    #[test]
    fn events_go_to_their_instance() {
        let (process, host) = fake_host();
        let (tx1, rx1) = channel::unbounded();
        let (tx2, rx2) = channel::unbounded();
        lock(&process.routing.events).insert(1, tx1);
        lock(&process.routing.events).insert(2, tx2);

        let event = HostMessage::Event {
            instance_id: 2,
            event: PluginEvent::GuiResizeRequest {
                width: 640,
                height: 480,
            },
        };
        wire::send_frame(&host, &event, &[]).unwrap();

        let received = rx2.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            received,
            PluginEvent::GuiResizeRequest {
                width: 640,
                height: 480
            }
        ));
        assert!(rx1.try_recv().is_err());
    }

    #[test]
    fn host_exit_fails_pending_requests_and_later_sends() {
        let (process, host) = fake_host();
        let process = Arc::new(process);
        let waiting = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::HasGui, &[], REQUEST_TIMEOUT)
            })
        };
        recv_request(&host);
        let started = Instant::now();
        drop(host);

        assert!(waiting.join().unwrap().unwrap_err().contains("exited"));
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(!process.is_alive());
        assert!(process.send(1, PluginCommand::Reset).is_err());
    }
}
