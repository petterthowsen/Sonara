//! Plugin Parameter Management
//!
//! Handles parameter queries and caching for subprocess plugins.

use crate::audio::devices::{ParamId, ParamInfo, ParamValue};
use crate::audio::ipc::{PluginCommand, ProcessManager};
use std::sync::{Arc, Mutex};
use tracing::error;

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
) -> bool {
    let process_arc = match process_manager.get_process(process_key) {
        Some(p) => p,
        None => {
            return false;
        }
    };

    let cmd = PluginCommand::SetParameter { param_id, value };

    let send_result = {
        // Use try_lock to avoid blocking if process is busy
        match process_arc.try_lock() {
            Ok(mut process_guard) => {
                if let Err(e) = process_guard.send_command(cmd) {
                    error!("Failed to send set_parameter command: {}", e);
                    false
                } else {
                    true
                }
            }
            Err(_) => false,
        }
    };

    send_result
}
