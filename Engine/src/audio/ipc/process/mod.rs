//! Plugin Process Manager
//!
//! Spawns plugin host processes and routes messages to the plugin instances inside them.
//!
//! Each host process has one control socket (a Unix socketpair) and a reader thread. Requests
//! carry a `request_id`; the reader thread completes the waiting request when the matching
//! response arrives. Unsolicited events go to a per-instance channel that the command thread
//! drains. Writes are serialized by a mutex that is only held while a frame is written, so a
//! slow request never blocks other senders.

mod connection;
mod crash;
mod launch;
mod process;
mod routing;

pub use connection::InstanceConnection;
pub use crash::{HostCrash, HostExit};
pub use launch::{
    plugin_log_dir, prune_plugin_logs, HostLaunch, HOST_WAIT_ENV, HOST_WRAPPER_ENV,
    PLUGIN_LOGS_KEPT,
};
pub use process::PluginProcess;

use crossbeam::channel::{self, Sender};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tracing::{info, warn};

use crate::audio::ipc::hosting::{HostAssignment, HostingPolicy};
use crate::audio::ipc::protocol::{
    InstanceId, PluginCommand, PluginEvent, PluginFormat, PluginResponse, SharedMemoryLayout,
};
use crate::audio::ipc::shared_memory::SharedMemory;

/// Default wait for a blocking request's reply. A host that hasn't answered in this long is
/// counted as unresponsive and killed by the command thread (Phase 4).
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// Wait for `Initialize`: loading a plugin can read large sample libraries.
const INITIALIZE_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a shared host gets to drop one of its instances (`Unload`).
const UNLOAD_TIMEOUT: Duration = Duration::from_secs(2);

/// Lock a mutex, recovering it if a panicking thread held it.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Plugin process manager: host key → host process, instance id → instance.
pub struct ProcessManager {
    hosts: Mutex<HashMap<String, Arc<PluginProcess>>>,
    instances: Mutex<HashMap<InstanceId, InstanceConnection>>,
    next_instance_id: AtomicU32,
    /// How instances are grouped into host processes (Phase 5).
    hosting: Mutex<HostingPolicy>,
    /// How hosts are launched (debugger wrapper, wait for a debugger), read from the env once.
    launch: HostLaunch,
}

impl ProcessManager {
    /// Create a new process manager
    pub fn new() -> Self {
        Self {
            hosts: Mutex::new(HashMap::new()),
            instances: Mutex::new(HashMap::new()),
            next_instance_id: AtomicU32::new(1),
            hosting: Mutex::new(HostingPolicy::default()),
            launch: HostLaunch::from_env(),
        }
    }

    /// Allocate an id for a new plugin instance.
    pub fn allocate_instance_id(&self) -> InstanceId {
        self.next_instance_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Replace the hosting policy. Instances already loaded keep their host until they are moved
    /// (the command thread compares each one's assignment with `assign_host`).
    pub fn set_hosting_policy(&self, policy: HostingPolicy) {
        *lock(&self.hosting) = policy;
    }

    /// The host an instance of `plugin_id` from `vendor` belongs in under the current policy.
    pub fn assign_host(
        &self,
        plugin_id: &str,
        vendor: &str,
        instance_id: InstanceId,
    ) -> HostAssignment {
        lock(&self.hosting).assign(plugin_id, vendor, instance_id)
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

    /// The live host for `host_key`, spawning one if there is none, with `instance_id`'s event
    /// route registered. Registering under the hosts lock keeps `release_host_if_unused` from
    /// shutting the host down between finding it and claiming it.
    fn host_for(
        &self,
        host_key: &str,
        instance_id: InstanceId,
        events: Sender<PluginEvent>,
    ) -> Result<Arc<PluginProcess>, String> {
        let mut hosts = lock(&self.hosts);
        let host = match hosts.get(host_key) {
            Some(host) if host.is_alive() => Arc::clone(host),
            existing => {
                if existing.is_some() {
                    warn!("Plugin host {} is dead; spawning a new one", host_key);
                }
                let host = Arc::new(PluginProcess::spawn(host_key.to_string(), &self.launch)?);
                hosts.insert(host_key.to_string(), Arc::clone(&host));
                host
            }
        };
        lock(&host.routing.events).insert(instance_id, events);
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
        format: PluginFormat,
    ) -> Result<InstanceConnection, String> {
        info!(
            "Loading plugin {} as instance {} in host {}",
            plugin_id, instance_id, host_key
        );
        let (events_tx, events_rx) = channel::unbounded();
        let host = self.host_for(host_key, instance_id, events_tx)?;
        let connection_host_shared = Arc::clone(host.host_shared());

        let layout = SharedMemoryLayout::new(max_buffer_size);
        let shm_name = format!("sonara_plugin_{}_{}", host.pid, instance_id);
        let shared_memory = match SharedMemory::new(&shm_name, layout) {
            Ok(shm) => Arc::new(shm),
            Err(e) => {
                lock(&host.routing.events).remove(&instance_id);
                self.release_host_if_unused(&host);
                return Err(format!("Failed to create shared memory: {}", e));
            }
        };

        host.routing.initializing.fetch_add(1, Ordering::AcqRel);
        let result = host.request_with_fds(
            instance_id,
            PluginCommand::Initialize {
                plugin_path,
                plugin_id: plugin_id.clone(),
                sample_rate,
                max_buffer_size,
                format,
            },
            &[shared_memory.as_raw_fd()],
            INITIALIZE_TIMEOUT,
        );
        host.routing.initializing.fetch_sub(1, Ordering::AcqRel);
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

    /// Forget an instance. A host other instances still use only unloads this one; otherwise the
    /// host shuts down. Blocking; call it off the audio thread and without the state lock.
    pub fn shutdown_instance(&self, instance_id: InstanceId) {
        let Some(connection) = lock(&self.instances).remove(&instance_id) else {
            return;
        };
        let host = &connection.host;
        let shared = {
            let mut events = lock(&host.routing.events);
            events.remove(&instance_id);
            !events.is_empty()
        };
        if shared && host.is_alive() {
            info!(
                "Unloading instance {} from shared plugin host {}",
                instance_id, host.host_key
            );
            match host.request_with_fds(instance_id, PluginCommand::Unload, &[], UNLOAD_TIMEOUT) {
                Ok(PluginResponse::Unloaded) => {}
                Ok(other) => warn!(
                    "Plugin host {} answered Unload of instance {} with {:?}",
                    host.host_key, instance_id, other
                ),
                Err(e) => warn!("{}", e),
            }
            return;
        }
        self.release_host_if_unused(host);
    }

    /// Shut `host` down if no instance lives in it. An instance counts from the moment its event
    /// route is registered, so one that is still loading keeps the host alive.
    fn release_host_if_unused(&self, host: &Arc<PluginProcess>) {
        {
            // Under the hosts lock, so `host_for` can't hand the host to a new instance while
            // it is being released.
            let mut hosts = lock(&self.hosts);
            if host.is_alive() && !lock(&host.routing.events).is_empty() {
                return;
            }
            if hosts
                .get(&host.host_key)
                .is_some_and(|registered| Arc::ptr_eq(registered, host))
            {
                hosts.remove(&host.host_key);
            }
        }
        host.shutdown();
    }
}

/// A host key made safe for a memfd name.
fn sanitize_name(key: &str) -> String {
    key.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::audio::ipc::protocol::*;
    use crate::audio::ipc::shared_memory::{HostSharedMemory, SharedMemory};
    use crate::audio::ipc::wire;

    use crossbeam::channel;
    use std::os::unix::net::UnixStream;
    use std::path::PathBuf;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

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

    #[test]
    fn request_timeout_marks_the_host_hung() {
        let (process, _host) = fake_host();
        assert!(!process.is_hung());
        let result =
            process.request_with_fds(1, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.unwrap_err().contains("didn't answer"));
        assert!(process.is_hung());
    }

    /// Loading a plugin can keep a shared host's main thread busy for many seconds; another
    /// instance's request timing out meanwhile doesn't make the host hung.
    #[test]
    fn a_timeout_while_another_instance_initializes_is_not_a_hang() {
        let (process, _host) = fake_host();
        process.routing.initializing.fetch_add(1, Ordering::AcqRel);
        let result =
            process.request_with_fds(2, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.unwrap_err().contains("didn't answer"));
        assert!(!process.is_hung());

        process.routing.initializing.fetch_sub(1, Ordering::AcqRel);
        let result =
            process.request_with_fds(2, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.is_err());
        assert!(process.is_hung());
    }

    /// Register `instance_id` as living in `process`, as `spawn_instance` would.
    fn register_instance(manager: &ProcessManager, process: &Arc<PluginProcess>, id: InstanceId) {
        let (tx, rx) = channel::unbounded();
        lock(&process.routing.events).insert(id, tx);
        let shared_memory = Arc::new(
            SharedMemory::new(
                &format!("sonara_test_shared_host_{}", id),
                SharedMemoryLayout::new(64),
            )
            .unwrap(),
        );
        lock(&manager.instances).insert(
            id,
            InstanceConnection {
                instance_id: id,
                host: Arc::clone(process),
                events: rx,
                shared_memory,
                host_shared: Arc::clone(process.host_shared()),
            },
        );
    }

    /// Removing one instance of a shared host unloads just that instance; removing the last one
    /// shuts the host down.
    #[test]
    fn a_shared_host_outlives_all_but_its_last_instance() {
        let manager = ProcessManager::new();
        let (process, host) = fake_host();
        let process = Arc::new(process);
        lock(&manager.hosts).insert(process.host_key.clone(), Arc::clone(&process));
        register_instance(&manager, &process, 1);
        register_instance(&manager, &process, 2);

        let responder = thread::spawn(move || {
            let request = recv_request(&host);
            assert!(matches!(request.command, PluginCommand::Unload));
            assert_eq!(request.instance_id, 1);
            reply(&host, &request, PluginResponse::Unloaded);
            host
        });
        manager.shutdown_instance(1);
        let host = responder.join().unwrap();
        assert!(manager.instance(1).is_none());
        assert!(manager.instance(2).is_some());
        assert!(
            lock(&manager.hosts).contains_key(&process.host_key),
            "host still in use"
        );

        manager.shutdown_instance(2);
        assert!(
            lock(&manager.hosts).is_empty(),
            "last instance releases the host"
        );
        let request = recv_request(&host);
        assert!(matches!(request.command, PluginCommand::Shutdown));
    }

    /// A host under a debugger may sit at a breakpoint: a timed-out request doesn't mark it hung.
    #[test]
    fn a_debugged_host_is_never_marked_hung() {
        let (mut process, _host) = fake_host();
        process.debugging = true;
        process.record_timeout(&PluginCommand::HasGui);
        process.record_timeout(&PluginCommand::Initialize {
            plugin_path: PathBuf::from("/x.clap"),
            plugin_id: "x".to_string(),
            sample_rate: 48_000.0,
            max_buffer_size: 64,
            format: Default::default(),
        });
        assert!(!process.is_hung());

        process.debugging = false;
        process.record_timeout(&PluginCommand::HasGui);
        assert!(process.is_hung());
    }

    #[test]
    fn forwarded_host_log_lines_are_not_routed_as_events() {
        let (process, host) = fake_host();
        let (tx, rx) = channel::unbounded();
        lock(&process.routing.events).insert(3, tx);
        let log = HostMessage::Log {
            instance_id: 3,
            plugin: "Test".to_string(),
            level: LogLevel::Warn,
            message: "careful".to_string(),
        };
        wire::send_frame(&host, &log, &[]).unwrap();
        // Follow with an event so we know the log line was dispatched first.
        let event = HostMessage::Event {
            instance_id: 3,
            event: PluginEvent::StateDirty,
        };
        wire::send_frame(&host, &event, &[]).unwrap();
        let received = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(received, PluginEvent::StateDirty));
        assert!(rx.try_recv().is_err());
    }
}
