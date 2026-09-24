//! Plugin Lifecycle Management
//!
//! Handles async plugin loading, initialization, and state management.

use crate::audio::commands::{AudioCommand, EngineStatus};
use crate::audio::devices::DevicePath;
use crate::audio::devices::ParamInfo;
use crate::audio::devices::ParamType;
use crate::audio::ipc::{
    InstanceId, PluginCommand, PluginParameterInfo, PluginResponse, ProcessManager, SharedMemory,
    REQUEST_TIMEOUT,
};
use crossbeam::channel::Sender;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tracing::{error, info, warn};

/// Maps a plugin's reported parameter metadata to the engine's `ParamInfo`.
///
/// Stepped parameters with 2 values become `Bool`, 3-64 become `Enum` (using the
/// plugin-provided step labels), and everything else stays `Float`.
pub fn plugin_param_to_info(p: &PluginParameterInfo) -> ParamInfo {
    let step_count = if p.is_stepped {
        ((p.max - p.min).round() as i64 + 1).max(0)
    } else {
        0
    };

    let (param_type, enum_values) = match step_count {
        2 => (ParamType::Bool, Vec::new()),
        3..=64 => (ParamType::Enum, p.step_labels.clone()),
        _ => (ParamType::Float, Vec::new()),
    };

    ParamInfo {
        id: p.id,
        name: p.name.clone(),
        unit: p.unit.clone(),
        min: p.min,
        max: p.max,
        default: p.default,
        is_automation_safe: p.is_automation_safe,
        param_type,
        syncable: true,
        enum_values,
        is_hidden: p.is_hidden,
        is_read_only: p.is_read_only,
        is_bypass: p.is_bypass,
        module: p.module.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::ipc::SharedMemoryLayout;

    #[test]
    fn plugin_load_exposes_shared_memory_only_when_ready() {
        let load = PluginLoad::new();
        assert!(load.shared_memory().is_none());
        assert!(!load.is_ready());

        let shm = SharedMemory::new("sonara_test_plugin_load", SharedMemoryLayout::new(64))
            .expect("shared memory");
        load.set_ready(Arc::new(shm));
        assert!(load.is_ready());
        assert!(load.shared_memory().is_some());

        load.set_failed("crashed".to_string());
        assert!(load.is_failed());
        assert!(load.shared_memory().is_none());
        assert_eq!(load.error().as_deref(), Some("crashed"));
    }

    fn base_info() -> PluginParameterInfo {
        PluginParameterInfo {
            id: 0,
            name: "Test".to_string(),
            unit: String::new(),
            min: 0.0,
            max: 1.0,
            default: 0.0,
            is_automation_safe: true,
            is_stepped: false,
            is_hidden: false,
            is_read_only: false,
            is_bypass: false,
            module: String::new(),
            step_labels: Vec::new(),
        }
    }

    #[test]
    fn two_steps_maps_to_bool() {
        let mut p = base_info();
        p.is_stepped = true;
        p.min = 0.0;
        p.max = 1.0;

        let info = plugin_param_to_info(&p);

        assert_eq!(info.param_type, ParamType::Bool);
        assert!(info.enum_values.is_empty());
    }

    #[test]
    fn five_steps_with_labels_maps_to_enum() {
        let mut p = base_info();
        p.is_stepped = true;
        p.min = 0.0;
        p.max = 4.0;
        p.step_labels = vec![
            "A".to_string(),
            "B".to_string(),
            "C".to_string(),
            "D".to_string(),
            "E".to_string(),
        ];

        let info = plugin_param_to_info(&p);

        assert_eq!(info.param_type, ParamType::Enum);
        assert_eq!(info.enum_values, p.step_labels);
    }

    #[test]
    fn two_hundred_steps_maps_to_float() {
        let mut p = base_info();
        p.is_stepped = true;
        p.min = 0.0;
        p.max = 199.0;

        let info = plugin_param_to_info(&p);

        assert_eq!(info.param_type, ParamType::Float);
        assert!(info.enum_values.is_empty());
    }

    #[test]
    fn flags_and_module_are_copied() {
        let mut p = base_info();
        p.is_hidden = true;
        p.is_read_only = true;
        p.is_bypass = true;
        p.module = "Early/Size".to_string();

        let info = plugin_param_to_info(&p);

        assert!(info.is_hidden);
        assert!(info.is_read_only);
        assert!(info.is_bypass);
        assert_eq!(info.module, "Early/Size");
    }
}

const LOADING: u8 = 0;
const READY: u8 = 1;
const FAILED: u8 = 2;

/// Load state of a subprocess plugin, shared by the loading thread, the command thread and the
/// audio thread.
///
/// The audio thread only reads an atomic and a set-once pointer, so it never waits on the loading
/// thread. The failure message sits behind a mutex that only non-audio threads touch.
pub struct PluginLoad {
    state: AtomicU8,
    shared_memory: OnceLock<Arc<SharedMemory>>,
    error: Mutex<Option<String>>,
}

impl PluginLoad {
    pub fn new() -> Self {
        Self {
            state: AtomicU8::new(LOADING),
            shared_memory: OnceLock::new(),
            error: Mutex::new(None),
        }
    }

    /// The plugin's shared memory once it is ready, else None. Lock-free.
    pub fn shared_memory(&self) -> Option<&SharedMemory> {
        if self.state.load(Ordering::Acquire) == READY {
            self.shared_memory.get().map(|shm| shm.as_ref())
        } else {
            None
        }
    }

    pub fn is_ready(&self) -> bool {
        self.state.load(Ordering::Acquire) == READY
    }

    pub fn is_failed(&self) -> bool {
        self.state.load(Ordering::Acquire) == FAILED
    }

    /// The failure message, if loading failed or the subprocess died.
    pub fn error(&self) -> Option<String> {
        self.error
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn set_ready(&self, shared_memory: Arc<SharedMemory>) {
        let _ = self.shared_memory.set(shared_memory);
        self.state.store(READY, Ordering::Release);
    }

    /// Mark the plugin failed. The audio thread passes audio through from its next block.
    pub fn set_failed(&self, error: String) {
        *self
            .error
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(error);
        self.state.store(FAILED, Ordering::Release);
    }
}

/// Spawn background thread to load plugin subprocess
pub fn spawn_loading_thread(
    process_manager: Arc<ProcessManager>,
    instance_id: InstanceId,
    plugin_path: PathBuf,
    plugin_id: String,
    sample_rate: f32,
    max_buffer_size: usize,
    load: Arc<PluginLoad>,
    param_cache: Arc<Mutex<Vec<ParamInfo>>>,
    channel_id: usize,
    device_path: DevicePath,
    command_tx: Option<Sender<AudioCommand>>,
    status_tx: Option<Sender<EngineStatus>>,
) {
    std::thread::spawn(move || {
        info!("🔄 Background thread: Loading plugin subprocess...");

        let send_state = |state: String| {
            if let Some(ref tx) = status_tx {
                let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                    channel_id,
                    device_path,
                    state,
                });
            }
        };
        send_state("loading".to_string());

        // Blocking, but on this background thread
        let connection = match process_manager.spawn_instance(
            instance_id,
            &ProcessManager::individual_host_key(instance_id),
            plugin_path,
            plugin_id.clone(),
            sample_rate,
            max_buffer_size,
        ) {
            Ok(connection) => connection,
            Err(e) => {
                load.set_failed(e.clone());
                error!("❌ Failed to spawn plugin subprocess: {}", e);
                send_state(format!("failed:{}", e));
                return;
            }
        };

        info!("🔄 Activating plugin: {}", plugin_id);
        match connection.request(PluginCommand::Activate, Duration::from_secs(5)) {
            Ok(PluginResponse::ActivateResult { success: true, .. }) => {
                info!("✅ Plugin activated successfully");
            }
            Ok(PluginResponse::ActivateResult { error, .. }) => {
                error!(
                    "❌ Failed to activate plugin: {}",
                    error.unwrap_or_default()
                );
            }
            Ok(resp) => error!("❌ Unexpected response to Activate: {:?}", resp),
            Err(e) => {
                error!("❌ Failed to activate plugin: {}", e);
                warn!("Plugin will run in pass-through mode");
            }
        }

        info!("🔄 Querying plugin parameters...");
        let params: Vec<ParamInfo> =
            match connection.request(PluginCommand::GetParameterInfo, REQUEST_TIMEOUT) {
                Ok(PluginResponse::ParameterInfo { params }) => {
                    info!("✅ Plugin has {} parameters", params.len());
                    params.iter().map(plugin_param_to_info).collect()
                }
                Ok(resp) => {
                    error!("❌ Unexpected response to GetParameterInfo: {:?}", resp);
                    Vec::new()
                }
                Err(e) => {
                    error!("❌ Failed to query plugin parameters: {}", e);
                    Vec::new()
                }
            };

        if let Err(e) = connection.send(PluginCommand::StartProcessing) {
            error!("❌ Failed to send StartProcessing command: {}", e);
        }

        let param_count = params.len();
        *param_cache.lock().unwrap() = params;
        load.set_ready(Arc::clone(connection.shared_memory()));

        info!(
            "✅ Plugin fully loaded and activated: {} (instance {}, host pid {}, {} params)",
            plugin_id,
            instance_id,
            connection.host_pid(),
            param_count
        );
        send_state("ready".to_string());

        // Notify that device is ready (triggers parameter re-send)
        if let Some(ref cmd_tx) = command_tx {
            let _ = cmd_tx.send(AudioCommand::DeviceReady {
                channel_id,
                device_path,
            });
            info!(
                "📤 Sent DeviceReady notification for channel {} position {}",
                channel_id, device_path
            );
        }
    });
}
