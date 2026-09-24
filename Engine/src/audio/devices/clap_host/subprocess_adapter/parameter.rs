//! Plugin Parameter Management
//!
//! Handles parameter queries and caching for subprocess plugins.

use crate::audio::devices::{ParamId, ParamInfo, ParamValue};
use crate::audio::ipc::{InstanceId, PluginCommand, ProcessManager};
use std::sync::{Arc, Mutex};
use tracing::error;

/// Get cached parameter list
pub fn get_parameters(param_cache: &Arc<Mutex<Vec<ParamInfo>>>) -> Vec<ParamInfo> {
    param_cache.lock().unwrap().clone()
}

/// Send a parameter value to the instance (fire-and-forget). False if it isn't loaded or the
/// send failed, so the caller can queue the value.
pub fn set_parameter_value(
    process_manager: &Arc<ProcessManager>,
    instance_id: InstanceId,
    param_id: ParamId,
    value: ParamValue,
) -> bool {
    let Some(connection) = process_manager.instance(instance_id) else {
        return false;
    };
    match connection.send(PluginCommand::SetParameter { param_id, value }) {
        Ok(()) => true,
        Err(e) => {
            error!("Failed to send set_parameter command: {}", e);
            false
        }
    }
}
