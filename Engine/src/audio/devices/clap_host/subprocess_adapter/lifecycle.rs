//! Plugin Lifecycle Management
//!
//! Handles async plugin loading, initialization, and state management.

use super::parameter;
use crate::audio::commands::{AudioCommand, EngineStatus};
use crate::audio::devices::DevicePath;
use crate::audio::devices::ParamInfo;
use crate::audio::devices::ParamType;
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::ipc::{
    HostAssignment, HostSharedMemory, InstanceId, PluginCommand, PluginParameterInfo,
    PluginResponse, ProcessManager, SharedMemory, REQUEST_TIMEOUT,
};
use crossbeam::channel::Sender;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};
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
        assert!(load.shared().is_none());
        assert!(!load.is_ready());
        assert_eq!(load.latency_frames(), 0);

        let shm = SharedMemory::new("sonara_test_plugin_load", SharedMemoryLayout::new(64))
            .expect("shared memory");
        let doorbell = HostSharedMemory::new("sonara_test_plugin_load_doorbell").expect("doorbell");
        load.set_ready(Arc::new(shm), Arc::new(doorbell));
        assert!(load.is_ready());
        assert!(load.shared_memory().is_some());
        assert!(load.shared().is_some());

        load.set_latency_frames(128);
        assert_eq!(load.latency_frames(), 128);

        load.set_failed("crashed".to_string());
        assert!(load.is_failed());
        assert!(load.shared().is_none());
        assert_eq!(load.error().as_deref(), Some("crashed"));
    }

    #[test]
    fn plugin_load_crashed_state_passes_audio_through() {
        let load = PluginLoad::new();
        let shm = SharedMemory::new("sonara_test_plugin_crash", SharedMemoryLayout::new(64))
            .expect("shared memory");
        let doorbell =
            HostSharedMemory::new("sonara_test_plugin_crash_doorbell").expect("doorbell");
        load.set_ready(Arc::new(shm), Arc::new(doorbell));
        assert!(load.is_ready());

        load.set_crashed("killed by signal 11 (SIGSEGV)".to_string());

        assert!(load.is_crashed());
        assert!(!load.is_ready());
        assert!(!load.is_failed());
        // The audio thread must not touch the crashed host's block.
        assert!(load.shared().is_none());
        assert_eq!(
            load.error().as_deref(),
            Some("killed by signal 11 (SIGSEGV)")
        );
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
/// The host process died (or stopped responding) after the plugin was loaded. Distinct from
/// `FAILED` (loading never finished) because a crashed device can be reloaded.
const CRASHED: u8 = 3;

/// Everything the audio thread needs to run the per-block handshake with one plugin instance:
/// its shared block and its host's doorbell.
pub struct PluginShared {
    pub memory: Arc<SharedMemory>,
    pub doorbell: Arc<HostSharedMemory>,
}

/// Load state of a subprocess plugin, shared by the loading thread, the command thread and the
/// audio thread.
///
/// The audio thread only reads an atomic and a set-once pointer, so it never waits on the loading
/// thread. The failure message sits behind a mutex that only non-audio threads touch.
pub struct PluginLoad {
    state: AtomicU8,
    shared: OnceLock<PluginShared>,
    error: Mutex<Option<String>>,
    /// Frames the plugin reported at activation, for latency compensation (Phase 8).
    latency_frames: AtomicU32,
    /// The host process the instance was loaded into (0 until ready). Kept after a crash, so
    /// Reload can find every device that shared the dead host.
    host_pid: AtomicU32,
}

impl PluginLoad {
    pub fn new() -> Self {
        Self {
            state: AtomicU8::new(LOADING),
            shared: OnceLock::new(),
            error: Mutex::new(None),
            latency_frames: AtomicU32::new(0),
            host_pid: AtomicU32::new(0),
        }
    }

    /// The instance's block and doorbell once it is ready, else None. Lock-free.
    pub fn shared(&self) -> Option<&PluginShared> {
        if self.state.load(Ordering::Acquire) == READY {
            self.shared.get()
        } else {
            None
        }
    }

    /// The instance's shared block once it is ready, else None.
    #[allow(dead_code)] // used by tests; the adapter reads the whole `PluginShared`
    pub fn shared_memory(&self) -> Option<&SharedMemory> {
        self.shared().map(|shared| shared.memory.as_ref())
    }

    pub fn is_ready(&self) -> bool {
        self.state.load(Ordering::Acquire) == READY
    }

    #[allow(dead_code)] // Phase 4 reports the crashed state to the UI
    pub fn is_failed(&self) -> bool {
        self.state.load(Ordering::Acquire) == FAILED
    }

    /// True once the host process died. The audio thread passes audio through, and the device
    /// UI offers a reload.
    pub fn is_crashed(&self) -> bool {
        self.state.load(Ordering::Acquire) == CRASHED
    }

    /// True before the plugin has become ready, i.e. nothing can be sent to it yet.
    pub fn is_loading(&self) -> bool {
        self.state.load(Ordering::Acquire) == LOADING
    }

    /// The failure message, if loading failed or the subprocess died.
    #[allow(dead_code)] // Phase 4 sends the reason with the crashed state
    pub fn error(&self) -> Option<String> {
        self.error
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// Frame latency the plugin reported at activation.
    #[allow(dead_code)] // read through `AudioDevice::latency_frames`; Phase 8 compensates
    pub fn latency_frames(&self) -> u32 {
        self.latency_frames.load(Ordering::Relaxed)
    }

    pub fn set_latency_frames(&self, frames: u32) {
        self.latency_frames.store(frames, Ordering::Relaxed);
    }

    /// The host process the instance was loaded into, 0 before it was.
    pub fn host_pid(&self) -> u32 {
        self.host_pid.load(Ordering::Relaxed)
    }

    pub fn set_host_pid(&self, pid: u32) {
        self.host_pid.store(pid, Ordering::Relaxed);
    }

    pub(crate) fn set_ready(&self, memory: Arc<SharedMemory>, doorbell: Arc<HostSharedMemory>) {
        let _ = self.shared.set(PluginShared { memory, doorbell });
        self.state.store(READY, Ordering::Release);
    }

    /// Mark the plugin failed. The audio thread passes audio through from its next block.
    pub fn set_failed(&self, error: String) {
        self.set_error(error, FAILED);
    }

    /// Mark the plugin crashed: its host process died. The audio thread passes audio through
    /// from its next block and the device UI can reload it.
    pub fn set_crashed(&self, error: String) {
        self.set_error(error, CRASHED);
    }

    fn set_error(&self, error: String, state: u8) {
        *self
            .error
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(error);
        self.state.store(state, Ordering::Release);
    }
}

/// Everything a background plugin load or reload needs. Built by the adapter at construction,
/// and again when a crashed device is reloaded (Phase 4) with the saved state and parameter
/// values restored.
pub struct PluginLoadRequest {
    pub process_manager: Arc<ProcessManager>,
    pub instance_id: InstanceId,
    /// The host process to load into, chosen by the hosting policy.
    pub host: HostAssignment,
    pub plugin_path: PathBuf,
    pub plugin_id: String,
    pub sample_rate: f32,
    pub max_buffer_size: usize,
    pub load: Arc<PluginLoad>,
    pub param_cache: Arc<Mutex<Vec<ParamInfo>>>,
    pub channel_id: usize,
    pub device_path: DevicePath,
    pub command_tx: Option<Sender<AudioCommand>>,
    pub status_tx: Option<Sender<EngineStatus>>,
    /// Plugin state saved before the host died, restored right after Initialize.
    pub restore_state: Option<Vec<u8>>,
    /// Parameter values to re-send after activation, for plugins without a state extension.
    pub restore_params: Vec<(ParamId, ParamValue)>,
    /// Shut the previous instance's host down first (a reload, not a first load).
    pub replace_existing: bool,
    /// Cleared when the adapter is dropped. A load in flight then stops and cleans up instead of
    /// leaving an orphan host behind.
    pub alive: Arc<AtomicBool>,
}

impl PluginLoadRequest {
    /// Load the plugin on a background thread, so the command thread is never blocked.
    pub fn spawn(self) {
        std::thread::spawn(move || run_load(self));
    }
}

/// Load (or reload) one plugin instance and publish it to the audio thread.
fn run_load(request: PluginLoadRequest) {
    let PluginLoadRequest {
        process_manager,
        instance_id,
        host,
        plugin_path,
        plugin_id,
        sample_rate,
        max_buffer_size,
        load,
        param_cache,
        channel_id,
        device_path,
        command_tx,
        status_tx,
        restore_state,
        restore_params,
        replace_existing,
        alive,
    } = request;

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

    if replace_existing {
        // Drop the old instance binding: after a crash its host is usually already gone; when
        // moving to another host, a shared old host only unloads this instance.
        process_manager.shutdown_instance(instance_id);
    }
    if !alive.load(Ordering::Acquire) {
        // The device was removed while this reload was starting: nothing to load.
        info!("Plugin load abandoned: the device was removed");
        return;
    }

    // Blocking, but on this background thread
    let connection = match process_manager.spawn_instance(
        instance_id,
        &host.key,
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

    if !alive.load(Ordering::Acquire) {
        // Dropping the adapter during the spawn may have run before the instance was registered;
        // shut the fresh host down rather than leave it running with no device behind it.
        info!("Plugin load abandoned after spawn: the device was removed");
        process_manager.shutdown_instance(instance_id);
        return;
    }

    // Restore the plugin's own state before activation, so presets and non-parameter state are
    // in place when the plugin starts processing.
    let mut state_restored = false;
    if let Some(state) = restore_state {
        let state_len = state.len();
        match connection.request(PluginCommand::LoadState { state }, REQUEST_TIMEOUT) {
            Ok(PluginResponse::StateLoadResult { success: true, .. }) => {
                info!("✅ Restored {} bytes of plugin state", state_len);
                state_restored = true;
            }
            Ok(PluginResponse::StateLoadResult { error, .. }) => {
                warn!(
                    "Plugin didn't restore its state ({}); re-sending parameters instead",
                    error.unwrap_or_default()
                );
            }
            Ok(resp) => warn!("Unexpected response to LoadState: {:?}", resp),
            Err(e) => warn!("Failed to restore plugin state: {}", e),
        }
    }

    info!("🔄 Activating plugin: {}", plugin_id);
    let mut latency_frames = 0;
    match connection.request(
        PluginCommand::Activate { sample_rate },
        Duration::from_secs(5),
    ) {
        Ok(PluginResponse::ActivateResult {
            success: true,
            latency_frames: latency,
            ..
        }) => {
            latency_frames = latency;
            info!(
                "✅ Plugin activated successfully (latency {} frames)",
                latency
            );
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

    // Without a restored blob (no state extension, or LoadState failed), fall back to the
    // engine's cached parameter values. With one, the blob is authoritative: the cache can miss
    // changes the plugin made without reporting them (a preset loaded in its GUI), and re-sending
    // it would overwrite the restored values.
    if !state_restored {
        for (param_id, value) in &restore_params {
            parameter::set_parameter_value(&process_manager, instance_id, *param_id, *value);
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

    // Read the restored values back so the engine's cache and Godot show what the plugin has.
    let mut restored_values = Vec::new();
    if state_restored {
        for param in &params {
            match connection.request(
                PluginCommand::GetParameter { param_id: param.id },
                REQUEST_TIMEOUT,
            ) {
                Ok(PluginResponse::ParameterValue { param_id, value }) => {
                    restored_values.push((param_id, value))
                }
                Ok(resp) => warn!(
                    "Unexpected response reading parameter {}: {:?}",
                    param.id, resp
                ),
                Err(e) => {
                    warn!("Could not read restored parameter values: {}", e);
                    break;
                }
            }
        }
    }

    if let Err(e) = connection.send(PluginCommand::StartProcessing) {
        error!("❌ Failed to send StartProcessing command: {}", e);
    }

    let param_count = params.len();
    *param_cache.lock().unwrap() = params;
    load.set_latency_frames(latency_frames);
    load.set_host_pid(connection.host_pid());
    load.set_ready(
        Arc::clone(connection.shared_memory()),
        Arc::clone(connection.host_shared()),
    );

    info!(
        "✅ Plugin fully loaded and activated: {} (instance {}, host {} pid {}, {} params)",
        plugin_id,
        instance_id,
        host.key,
        connection.host_pid(),
        param_count
    );
    send_state("ready".to_string());
    if let Some(ref tx) = status_tx {
        let _ = tx.send(EngineStatus::PluginHost {
            channel_id,
            device_path,
            mode: host.mode.name().to_string(),
            host_key: host.key.clone(),
            pid: connection.host_pid(),
        });
    }

    // Notify that device is ready (triggers parameter re-send)
    if let Some(ref cmd_tx) = command_tx {
        let _ = cmd_tx.send(AudioCommand::DeviceReady {
            channel_id,
            device_path,
            restored_values,
        });
        info!(
            "📤 Sent DeviceReady notification for channel {} position {}",
            channel_id, device_path
        );
    }
}
