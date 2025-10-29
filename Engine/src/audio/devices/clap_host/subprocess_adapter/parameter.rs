//! Plugin Parameter Management
//!
//! Handles parameter queries and caching for subprocess plugins.

use crate::audio::devices::{ParamId, ParamInfo, ParamValue};
use crate::audio::ipc::{PluginCommand, PluginResponse, ProcessManager};
use std::sync::{Arc, Mutex};
use tracing::{error, warn};

/// Get parameter value from subprocess (with timeout to avoid blocking)
pub fn get_parameter_value(
    process_manager: &Arc<ProcessManager>,
    process_key: &str,
    param_id: ParamId,
) -> Option<ParamValue> {
    let process_arc = process_manager.get_process(process_key)?;

    // Use try_lock to avoid blocking (this might be called from audio thread)
    let mut process_guard = match process_arc.try_lock() {
        Ok(guard) => guard,
        Err(_) => {
            warn!("Could not get lock to query parameter - process busy");
            return None;
        }
    };

    // Send command
    if let Err(e) = process_guard.send_command(PluginCommand::GetParameter { param_id }) {
        error!("Failed to send GetParameter command: {}", e);
        return None;
    }

    // Receive response (with timeout to avoid blocking)
    let _ = process_guard.set_read_timeout(Some(std::time::Duration::from_millis(100)));
    match process_guard.recv_response() {
        Ok(PluginResponse::ParameterValue { param_id: _, value }) => Some(value),
        Ok(resp) => {
            warn!("Unexpected response to GetParameter: {:?}", resp);
            None
        }
        Err(e) => {
            warn!("Failed to receive GetParameter response: {}", e);
            None
        }
    }
}

/// Get cached parameter list
pub fn get_parameters(param_cache: &Arc<Mutex<Vec<ParamInfo>>>) -> Vec<ParamInfo> {
    param_cache.lock().unwrap().clone()
}

/// Send parameter value to subprocess (fire-and-forget, audio-thread safe)
pub fn set_parameter_value(
    process_manager: &Arc<ProcessManager>,
    process_key: &str,
    param_id: ParamId,
    value: ParamValue,
) {
    let process_arc = match process_manager.get_process(process_key) {
        Some(p) => p,
        None => {
            warn!("Plugin process not found for set_parameter");
            return;
        }
    };

    let cmd = PluginCommand::SetParameter { param_id, value };

    // Use try_lock to avoid blocking if process is busy
    match process_arc.try_lock() {
        Ok(mut process_guard) => {
            if let Err(e) = process_guard.send_command(cmd) {
                error!("Failed to send set_parameter command: {}", e);
            }
            // Don't wait for response - this would block the audio thread!
        }
        Err(_) => {
            // Process is busy, skip parameter update (better than blocking)
            warn!("Skipping parameter update - process is busy");
        }
    };
}
