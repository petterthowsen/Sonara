//! Plugin Lifecycle Management
//!
//! Handles async plugin loading, initialization, and state management.

use crate::audio::commands::{AudioCommand, EngineStatus};
use crate::audio::devices::ParamInfo;
use crate::audio::ipc::{PluginCommand, PluginResponse, ProcessManager, SharedMemory};
use crate::audio::devices::ParamType;
use crossbeam::channel::Sender;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tracing::{error, info, warn};

/// Loading state for async plugin initialization
#[derive(Clone)]
pub enum LoadingState {
    /// Plugin is being loaded in background thread
    Loading,
    /// Plugin loaded and ready
    Ready(Arc<SharedMemory>),
    /// Plugin failed to load
    Failed(String),
}

/// Spawn background thread to load plugin subprocess
pub fn spawn_loading_thread(
    process_manager: Arc<ProcessManager>,
    process_key: String,
    plugin_path: PathBuf,
    plugin_id: String,
    sample_rate: f32,
    max_buffer_size: usize,
    loading_state: Arc<Mutex<LoadingState>>,
    param_cache: Arc<Mutex<Vec<ParamInfo>>>,
    channel_id: usize,
    device_position: usize,
    command_tx: Option<Sender<AudioCommand>>,
    status_tx: Option<Sender<EngineStatus>>,
) {
    std::thread::spawn(move || {
        info!("🔄 Background thread: Loading plugin subprocess...");

        // Send loading state
        if let Some(ref tx) = status_tx {
            let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                channel_id,
                device_position,
                state: "loading".to_string(),
            });
        }

        // Spawn plugin subprocess (blocking, but on background thread!)
        let result = process_manager.spawn_plugin(
            process_key.clone(),
            plugin_path,
            plugin_id.clone(),
            sample_rate,
            max_buffer_size,
        );

        match result {
            Ok(_) => {
                // Get shared memory reference and activate plugin
                if let Some(process) = process_manager.get_process(&process_key) {
                    // Get shared memory first (quick operation)
                    let shared_memory = {
                        let process_guard = process.lock().unwrap();
                        Arc::clone(process_guard.shared_memory())
                    };

                    // Brief delay to let subprocess return to event loop after InitializeSuccess
                    // This ensures the subprocess is ready to receive the next command
                    std::thread::sleep(std::time::Duration::from_millis(100));

                    // Now send activation commands (in separate critical section)
                    let param_info_cache = {
                        info!("🔄 Activating plugin: {}", plugin_id);

                        let mut process_guard = process.lock().unwrap();

                        // Send Activate command
                        info!("📤 Sending Activate command...");
                        if let Err(e) = process_guard.send_command(PluginCommand::Activate) {
                            error!("❌ Failed to send Activate command: {}", e);
                        } else {
                            info!("📥 Waiting for Activate response (with timeout)...");

                            // Set a timeout on the socket to avoid blocking forever
                            let _ = process_guard
                                .set_read_timeout(Some(std::time::Duration::from_secs(5)));

                            match process_guard.recv_response() {
                                Ok(PluginResponse::ActivateResult { success, error }) => {
                                    if success {
                                        info!("✅ Plugin activated successfully");
                                    } else {
                                        error!(
                                            "❌ Failed to activate plugin: {}",
                                            error.unwrap_or_default()
                                        );
                                    }
                                }
                                Ok(resp) => {
                                    error!("❌ Unexpected response to Activate: {:?}", resp);
                                }
                                Err(e) => {
                                    error!("❌ Failed to receive Activate response (timeout or error): {}", e);
                                    warn!("Plugin will run in pass-through mode");
                                }
                            }
                        }

                        // Query parameter info BEFORE starting processing to avoid response buffering issues
                        info!("🔄 Querying plugin parameters...");
                        let param_info_cache = if let Err(e) =
                            process_guard.send_command(PluginCommand::GetParameterInfo)
                        {
                            error!("❌ Failed to send GetParameterInfo command: {}", e);
                            Vec::new()
                        } else {
                            match process_guard.recv_response() {
                                Ok(PluginResponse::ParameterInfo { params }) => {
                                    info!("✅ Plugin has {} parameters", params.len());

                                    // Convert to ParamInfo format
                                    params
                                        .iter()
                                        .map(|p| ParamInfo {
                                            id: p.id,
                                            name: p.name.clone(),
                                            unit: p.unit.clone(),
                                            min: p.min,
                                            max: p.max,
                                            default: p.default,
                                            is_automation_safe: p.is_automation_safe,
                                            param_type: ParamType::Float,
                                            syncable: true,
                                            enum_values: Vec::new(),
                                        })
                                        .collect()
                                }
                                Ok(resp) => {
                                    error!(
                                        "❌ Unexpected response to GetParameterInfo: {:?}",
                                        resp
                                    );
                                    Vec::new()
                                }
                                Err(e) => {
                                    error!("❌ Failed to receive GetParameterInfo response: {}", e);
                                    Vec::new()
                                }
                            }
                        };

                        // Now start processing (after querying parameters)
                        info!("🔄 Starting audio processing...");
                        if let Err(e) = process_guard.send_command(PluginCommand::StartProcessing) {
                            error!("❌ Failed to send StartProcessing command: {}", e);
                        } else {
                            // Don't wait for ProcessingStarted response - it's fire-and-forget
                            info!("✅ StartProcessing command sent");
                        }

                        param_info_cache
                    };

                    // Update parameter cache
                    {
                        let mut cache = param_cache.lock().unwrap();
                        *cache = param_info_cache.clone();
                    }

                    // Update state to Ready
                    {
                        let mut state = loading_state.lock().unwrap();
                        *state = LoadingState::Ready(shared_memory);
                    }

                    info!(
                        "✅ Plugin subprocess fully loaded and activated: {} ({} params)",
                        plugin_id,
                        param_info_cache.len()
                    );

                    // Send ready state
                    if let Some(ref tx) = status_tx {
                        let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                            channel_id,
                            device_position,
                            state: "ready".to_string(),
                        });
                    }

                    // Notify that device is ready (triggers parameter re-send)
                    if let Some(ref cmd_tx) = command_tx {
                        let _ = cmd_tx.send(AudioCommand::DeviceReady {
                            channel_id,
                            device_position,
                        });
                        info!(
                            "📤 Sent DeviceReady notification for channel {} position {}",
                            channel_id, device_position
                        );
                    }
                } else {
                    let error_msg = "Failed to get process handle".to_string();
                    let mut state = loading_state.lock().unwrap();
                    *state = LoadingState::Failed(error_msg.clone());
                    error!("❌ Failed to get process handle for {}", plugin_id);

                    // Send failed state
                    if let Some(ref tx) = status_tx {
                        let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                            channel_id,
                            device_position,
                            state: format!("failed:{}", error_msg),
                        });
                    }
                }
            }
            Err(e) => {
                let mut state = loading_state.lock().unwrap();
                *state = LoadingState::Failed(e.clone());
                error!("❌ Failed to spawn plugin subprocess: {}", e);

                // Send failed state
                if let Some(ref tx) = status_tx {
                    let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                        channel_id,
                        device_position,
                        state: format!("failed:{}", e),
                    });
                }
            }
        }
    });
}
