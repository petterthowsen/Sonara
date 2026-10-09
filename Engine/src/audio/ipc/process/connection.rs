//! A plugin instance's handle onto its host process.

use crossbeam::channel::Receiver;
use std::sync::Arc;
use std::time::Duration;

use super::crash::HostCrash;
use super::process::PluginProcess;
use crate::audio::ipc::protocol::{InstanceId, PluginCommand, PluginEvent, PluginResponse};
use crate::audio::ipc::shared_memory::{HostSharedMemory, SharedMemory};

/// Connection to one plugin instance: its host process, event channel and shared memory.
/// Cheap to clone; every clone talks to the same instance.
#[derive(Clone)]
pub struct InstanceConnection {
    pub(super) instance_id: InstanceId,
    pub(super) host: Arc<PluginProcess>,
    pub(super) events: Receiver<PluginEvent>,
    pub(super) shared_memory: Arc<SharedMemory>,
    pub(super) host_shared: Arc<HostSharedMemory>,
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

    /// True when a blocking request timed out and the host hasn't answered since.
    pub fn is_hung(&self) -> bool {
        self.host.is_hung()
    }

    /// Why this host stopped, or None while it is running.
    pub fn crash_info(&self) -> Option<HostCrash> {
        self.host.crash_info()
    }

    /// True when the host runs under a debugger or wrapper: don't kill it for being slow.
    pub fn is_debugging(&self) -> bool {
        self.host.is_debugging()
    }

    /// Kill the host process (hung host handling).
    pub fn kill_host(&self) {
        self.host.kill()
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
