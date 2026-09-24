//! Blocking round-trips to a plugin subprocess that don't borrow the adapter.

use super::gui;
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::ipc::{PluginCommand, PluginResponse, ProcessManager};
use std::sync::Arc;
use tracing::warn;

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

    /// Plugin name, for logs.
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// Read the parameter changes the plugin has reported (its GUI or internal modulation) as
    /// `(param_id, normalized_value)`. Returns nothing if another request holds the process.
    pub fn poll_parameter_changes(&self, out: &mut Vec<(u32, f32)>) {
        let Some(process) = self.process_manager.get_process(&self.process_key) else {
            return;
        };
        let Ok(mut process) = process.try_lock() else {
            return;
        };
        while let Ok(response) = process.try_recv_response() {
            if let PluginResponse::ParameterValueChanged { param_id, value } = response {
                out.push((param_id, value));
            }
        }
    }

    /// Send parameter writes (fire-and-forget). Waits for the process if a request holds it.
    pub fn set_parameters(&self, writes: &[(ParamId, ParamValue)]) {
        let Some(process) = self.process_manager.get_process(&self.process_key) else {
            return;
        };
        let mut process = process
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for &(param_id, value) in writes {
            if let Err(e) = process.send_command(PluginCommand::SetParameter { param_id, value }) {
                warn!(
                    "Failed to send parameter {} to {}: {}",
                    param_id, self.device_name, e
                );
                return;
            }
        }
    }

    /// False once the subprocess has exited (or is no longer registered). True when another
    /// request holds the process, since it can't be checked without waiting.
    pub fn is_alive(&self) -> bool {
        let Some(process) = self.process_manager.get_process(&self.process_key) else {
            return false;
        };
        let alive = match process.try_lock() {
            Ok(mut process) => process.is_alive(),
            Err(_) => true,
        };
        alive
    }
}
