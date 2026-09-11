//! Blocking round-trips to a plugin subprocess that don't borrow the adapter.

use super::gui;
use crate::audio::ipc::{PluginCommand, PluginResponse, ProcessManager};
use std::sync::Arc;

/// Handle to one plugin subprocess for blocking IPC (GUI, activation).
///
/// It holds no reference to the adapter, so the command thread can take one under the engine
/// state lock, release the lock, and then wait on the subprocess without stalling audio.
#[derive(Clone)]
pub struct PluginIpcHandle {
    process_manager: Arc<ProcessManager>,
    process_key: String,
    device_name: String,
}

impl PluginIpcHandle {
    /// Create a handle for the subprocess registered under `process_key`.
    pub(super) fn new(
        process_manager: Arc<ProcessManager>,
        process_key: String,
        device_name: String,
    ) -> Self {
        Self {
            process_manager,
            process_key,
            device_name,
        }
    }

    /// Send a command and wait for the subprocess's response.
    fn send_command(&self, cmd: PluginCommand) -> Result<PluginResponse, String> {
        let process = self
            .process_manager
            .get_process(&self.process_key)
            .ok_or_else(|| "Plugin process not found".to_string())?;
        let mut process = process.lock().unwrap();
        process.send_command(cmd)?;
        process.recv_response()
    }

    /// Activate the plugin and start processing.
    pub fn activate(&self) -> Result<(), String> {
        match self.send_command(PluginCommand::Activate)? {
            PluginResponse::ActivateResult { success: true, .. } => {
                self.send_command(PluginCommand::StartProcessing)?;
                Ok(())
            }
            PluginResponse::ActivateResult { error, .. } => {
                Err(error.unwrap_or_else(|| "Activation failed".to_string()))
            }
            _ => Err("Unexpected response".to_string()),
        }
    }

    /// Stop processing and deactivate the plugin.
    pub fn deactivate(&self) -> Result<(), String> {
        self.send_command(PluginCommand::StopProcessing)?;
        match self.send_command(PluginCommand::Deactivate)? {
            PluginResponse::DeactivateResult { success: true, .. } => Ok(()),
            PluginResponse::DeactivateResult { error, .. } => {
                Err(error.unwrap_or_else(|| "Deactivation failed".to_string()))
            }
            _ => Err("Unexpected response".to_string()),
        }
    }

    /// Open the plugin GUI, embedded in `window_handle` when given.
    /// Returns (width, height, is_resizable).
    pub fn open_gui(&self, window_handle: Option<u64>) -> Result<(u32, u32, bool), String> {
        gui::open_gui(
            &self.process_manager,
            &self.process_key,
            &self.device_name,
            window_handle,
        )
    }

    /// Close the plugin GUI.
    pub fn close_gui(&self) -> Result<(), String> {
        gui::close_gui(&self.process_manager, &self.process_key, &self.device_name)
    }
}
