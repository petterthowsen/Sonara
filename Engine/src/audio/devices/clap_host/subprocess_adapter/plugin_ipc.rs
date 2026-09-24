//! Blocking round-trips to a plugin instance that don't borrow the adapter.

use super::gui;
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::ipc::{
    InstanceConnection, InstanceId, PluginCommand, PluginEvent, PluginResponse, ProcessManager,
    REQUEST_TIMEOUT,
};
use std::sync::Arc;
use tracing::warn;

/// Handle to one plugin instance for blocking IPC (GUI, activation).
///
/// It holds no reference to the adapter, so the command thread can take one under the engine
/// state lock, release the lock, and then wait on the host without stalling audio. Requests
/// don't lock the host process either: several can be in flight at once.
#[derive(Clone)]
pub struct PluginIpcHandle {
    process_manager: Arc<ProcessManager>,
    instance_id: InstanceId,
    device_name: String,
    sample_rate: f32,
}

impl PluginIpcHandle {
    /// Create a handle for instance `instance_id`.
    pub(super) fn new(
        process_manager: Arc<ProcessManager>,
        instance_id: InstanceId,
        device_name: String,
        sample_rate: f32,
    ) -> Self {
        Self {
            process_manager,
            instance_id,
            device_name,
            sample_rate,
        }
    }

    fn connection(&self) -> Result<InstanceConnection, String> {
        self.process_manager
            .instance(self.instance_id)
            .ok_or_else(|| format!("Plugin instance {} not found", self.instance_id))
    }

    /// Send a command and wait for the instance's response.
    fn request(&self, cmd: PluginCommand) -> Result<PluginResponse, String> {
        self.connection()?.request(cmd, REQUEST_TIMEOUT)
    }

    /// Activate the plugin and start processing. Returns the plugin's latency in frames.
    pub fn activate(&self) -> Result<u32, String> {
        match self.request(PluginCommand::Activate {
            sample_rate: self.sample_rate,
        })? {
            PluginResponse::ActivateResult {
                success: true,
                latency_frames,
                ..
            } => {
                self.request(PluginCommand::StartProcessing)?;
                Ok(latency_frames)
            }
            PluginResponse::ActivateResult { error, .. } => {
                Err(error.unwrap_or_else(|| "Activation failed".to_string()))
            }
            other => Err(format!("Unexpected response to Activate: {:?}", other)),
        }
    }

    /// Stop processing and deactivate the plugin.
    pub fn deactivate(&self) -> Result<(), String> {
        self.request(PluginCommand::StopProcessing)?;
        match self.request(PluginCommand::Deactivate)? {
            PluginResponse::DeactivateResult { success: true, .. } => Ok(()),
            PluginResponse::DeactivateResult { error, .. } => {
                Err(error.unwrap_or_else(|| "Deactivation failed".to_string()))
            }
            other => Err(format!("Unexpected response to Deactivate: {:?}", other)),
        }
    }

    /// Open the plugin GUI, embedded in `window_handle` when given.
    /// Returns (width, height, is_resizable).
    pub fn open_gui(&self, window_handle: Option<u64>) -> Result<(u32, u32, bool), String> {
        gui::open_gui(&self.connection()?, &self.device_name, window_handle)
    }

    /// Close the plugin GUI.
    pub fn close_gui(&self) -> Result<(), String> {
        gui::close_gui(&self.connection()?, &self.device_name)
    }

    /// Whether the plugin has a GUI. False if the instance isn't loaded.
    pub fn has_gui(&self) -> bool {
        self.connection()
            .map(|connection| gui::has_gui(&connection))
            .unwrap_or(false)
    }

    /// Plugin name, for logs.
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// Move the events the instance has sent (parameter changes from its GUI or modulation, GUI
    /// resize requests) into `out`. Never blocks.
    pub fn poll_events(&self, out: &mut Vec<PluginEvent>) {
        let Ok(connection) = self.connection() else {
            return;
        };
        while let Some(event) = connection.try_event() {
            out.push(event);
        }
    }

    /// Send parameter writes (fire-and-forget).
    pub fn set_parameters(&self, writes: &[(ParamId, ParamValue)]) {
        let Ok(connection) = self.connection() else {
            return;
        };
        for &(param_id, value) in writes {
            if let Err(e) = connection.send(PluginCommand::SetParameter { param_id, value }) {
                warn!(
                    "Failed to send parameter {} to {}: {}",
                    param_id, self.device_name, e
                );
                return;
            }
        }
    }

    /// False once the host process has exited (or the instance is no longer registered).
    pub fn is_alive(&self) -> bool {
        self.connection()
            .map(|connection| connection.is_alive())
            .unwrap_or(false)
    }
}
