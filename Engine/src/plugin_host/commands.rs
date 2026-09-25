//! Command processing for plugin host
//!
//! Handles all commands received from the main engine via IPC,
//! including initialization, activation, parameter management, and GUI operations.

use std::os::fd::{IntoRawFd, OwnedFd};
use std::sync::Arc;
use tracing::{error, info, warn};

use clack_extensions::gui::{GuiSize, PluginGui};
use clack_extensions::latency::PluginLatency;
use clack_extensions::params::{ParamInfoBuffer, ParamInfoFlags, PluginParams};
use clack_extensions::state::PluginState as ClapState;
use clack_host::events::event_types::ParamValueEvent;
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
use clack_host::events::Pckn;
use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_host::utils::Cookie;

use crate::audio::ipc::{
    HostMessage, InstanceId, PluginCommand, PluginParameterInfo, PluginResponse, SharedMemory,
    SharedMemoryLayout,
};

use crate::plugin_host::audio_thread::AudioThreadHandle;
use crate::plugin_host::operations::{
    close_plugin_gui, has_plugin_gui, load_plugin, open_plugin_gui,
};
use crate::plugin_host::state::{ParamMap, PluginState};

/// Process a command for `instance_id` and return the response, if it has one. `fds` are the
/// file descriptors that came with the command.
pub fn process_command(
    cmd: PluginCommand,
    instance_id: InstanceId,
    fds: Vec<OwnedFd>,
    plugin_state: &mut Option<PluginState>,
    event_tx: &std::sync::mpsc::Sender<HostMessage>,
    audio: &AudioThreadHandle,
) -> Option<PluginResponse> {
    match cmd {
        PluginCommand::Initialize {
            plugin_path,
            plugin_id,
            sample_rate,
            max_buffer_size,
        } => {
            if let Some(state) = plugin_state {
                // One instance per host until hosting modes land (Phase 5)
                return Some(PluginResponse::InitializeError {
                    error: format!(
                        "This host already holds instance {}; it can't load instance {}",
                        state.instance_id, instance_id
                    ),
                });
            }
            info!(
                "Initializing plugin: {} from {:?} as instance {}",
                plugin_id, plugin_path, instance_id
            );

            // The instance's shared memory comes with the command
            let Some(shm_fd) = fds.into_iter().next() else {
                return Some(PluginResponse::InitializeError {
                    error: "Initialize came without a shared memory descriptor".to_string(),
                });
            };
            let layout = SharedMemoryLayout::new(max_buffer_size);
            let shared_memory = match SharedMemory::from_fd(shm_fd.into_raw_fd(), layout) {
                Ok(shm) => Arc::new(shm),
                Err(e) => {
                    error!("Failed to map shared memory: {}", e);
                    return Some(PluginResponse::InitializeError {
                        error: format!("Failed to map shared memory: {}", e),
                    });
                }
            };

            info!("Step 1: Loading plugin from disk...");
            let (bundle, instance, shared) = match load_plugin(
                &plugin_path,
                &plugin_id,
                sample_rate,
                max_buffer_size,
                instance_id,
                event_tx.clone(),
            ) {
                Ok(result) => {
                    info!("Step 2: Plugin loaded successfully");
                    result
                }
                Err(e) => {
                    error!("Failed to load plugin: {}", e);
                    return Some(PluginResponse::InitializeError { error: e });
                }
            };

            info!("Step 3: Preparing plugin state...");
            // Get plugin metadata
            let device_name = plugin_id.clone();
            let device_vendor = "Unknown".to_string();
            let device_version = "1.0".to_string();
            let category = "effect".to_string();

            // Store plugin state (audio buffers live on the audio thread)
            *plugin_state = Some(PluginState {
                instance_id,
                bundle,
                instance,
                shared,
                gui_open: false,
                activated: false,
                processing: false,
                sample_rate,
                max_buffer_size,
                shared_memory,
                latency_frames: 0,
                param_map: None,
            });

            info!("Step 4: ✅ Plugin state stored, sending InitializeSuccess response");
            Some(PluginResponse::InitializeSuccess {
                device_name,
                device_vendor,
                device_version,
                category,
            })
        }

        PluginCommand::OpenGui { window_handle } => {
            info!(
                "📥 Received OpenGui command (window_handle: {:?})",
                window_handle
            );
            if let Some(ref mut state) = plugin_state {
                if state.gui_open {
                    info!("GUI already open, returning GuiOpened");
                    // Query current size for consistency
                    let mut handle = state.instance.plugin_handle();
                    if let Some(gui_ext) = handle.get_extension::<PluginGui>() {
                        let size = gui_ext.get_size(&mut handle).unwrap_or(GuiSize {
                            width: 800,
                            height: 600,
                        });
                        let is_resizable = gui_ext.can_resize(&mut handle);
                        return Some(PluginResponse::GuiOpened {
                            width: size.width,
                            height: size.height,
                            is_resizable,
                        });
                    }
                    return Some(PluginResponse::GuiOpened {
                        width: 800,
                        height: 600,
                        is_resizable: true,
                    });
                }

                info!("Attempting to open GUI...");
                match open_plugin_gui(&mut state.instance, window_handle) {
                    Ok((width, height, is_resizable)) => {
                        state.gui_open = true;
                        info!("✅ GUI opened successfully, returning GuiOpened response with size {}x{} (resizable: {})", width, height, is_resizable);
                        Some(PluginResponse::GuiOpened {
                            width,
                            height,
                            is_resizable,
                        })
                    }
                    Err(e) => {
                        warn!("❌ Failed to open GUI: {}", e);
                        Some(PluginResponse::GuiError { error: e })
                    }
                }
            } else {
                warn!("❌ Cannot open GUI: Plugin not initialized");
                Some(PluginResponse::GuiError {
                    error: "Plugin not initialized".to_string(),
                })
            }
        }

        PluginCommand::CloseGui => {
            if let Some(ref mut state) = plugin_state {
                if !state.gui_open {
                    return Some(PluginResponse::GuiClosed);
                }

                match close_plugin_gui(&mut state.instance) {
                    Ok(()) => {
                        state.gui_open = false;
                        info!("GUI closed successfully");
                        Some(PluginResponse::GuiClosed)
                    }
                    Err(e) => Some(PluginResponse::GuiError { error: e }),
                }
            } else {
                Some(PluginResponse::GuiError {
                    error: "Plugin not initialized".to_string(),
                })
            }
        }

        PluginCommand::HasGui => {
            let supported = if let Some(ref mut state) = plugin_state {
                has_plugin_gui(&mut state.instance)
            } else {
                false
            };
            Some(PluginResponse::HasGuiResponse { supported })
        }

        PluginCommand::Shutdown => {
            // Handled in main loop
            None
        }

        PluginCommand::Activate { sample_rate } => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(PluginResponse::ActivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                    latency_frames: 0,
                });
            };

            // Already active at this rate: nothing to do.
            if state.activated && (state.sample_rate - sample_rate).abs() < f32::EPSILON {
                return Some(PluginResponse::ActivateResult {
                    success: true,
                    error: None,
                    latency_frames: state.latency_frames,
                });
            }
            // Re-activation at a new rate (Phase 7's sample-rate change path) deactivates first.
            if state.activated {
                deactivate_plugin(state, audio);
            }
            state.sample_rate = sample_rate;

            info!(
                "Activating plugin (sample_rate={}, max_buffer_size={})",
                state.sample_rate, state.max_buffer_size
            );

            let config = PluginAudioConfiguration {
                sample_rate: state.sample_rate as f64,
                min_frames_count: 1,
                max_frames_count: state.max_buffer_size as u32,
            };

            let stopped = match state.instance.activate(|_, _| (), config) {
                Ok(stopped) => stopped,
                Err(e) => {
                    error!("Failed to activate plugin: {:?}", e);
                    return Some(PluginResponse::ActivateResult {
                        success: false,
                        error: Some(format!("{:?}", e)),
                        latency_frames: 0,
                    });
                }
            };
            let started = match stopped.start_processing() {
                Ok(started) => started,
                Err(e) => {
                    error!("Failed to start processing: {:?}", e);
                    return Some(PluginResponse::ActivateResult {
                        success: false,
                        error: Some(format!("Failed to start processing: {:?}", e)),
                        latency_frames: 0,
                    });
                }
            };

            let param_map = Some(Arc::clone(state.param_map()));
            if let Err(e) = audio.set_processor(
                PluginAudioProcessorEnum::Started(started),
                Arc::clone(&state.shared_memory),
                param_map,
            ) {
                error!("Failed to hand the processor to the audio thread: {}", e);
                return Some(PluginResponse::ActivateResult {
                    success: false,
                    error: Some(e),
                    latency_frames: 0,
                });
            }

            let latency = query_latency(state);
            state.latency_frames = latency;
            state.activated = true;
            state.processing = true;
            info!(
                "✅ Plugin activated and processing started (latency {} frames)",
                latency
            );
            Some(PluginResponse::ActivateResult {
                success: true,
                error: None,
                latency_frames: latency,
            })
        }

        PluginCommand::Deactivate => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(PluginResponse::DeactivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                });
            };
            if !state.activated {
                return Some(PluginResponse::DeactivateResult {
                    success: true,
                    error: None,
                });
            }

            info!("Deactivating plugin");
            deactivate_plugin(state, audio);
            info!("✅ Plugin deactivated successfully");
            Some(PluginResponse::DeactivateResult {
                success: true,
                error: None,
            })
        }

        PluginCommand::StartProcessing => {
            if let Some(ref mut state) = plugin_state {
                if !state.activated {
                    return Some(PluginResponse::Error {
                        command: "StartProcessing".to_string(),
                        error: "Plugin not activated".to_string(),
                    });
                }

                // Processing is started in activate() for now
                state.processing = true;
                info!("✅ Plugin processing started");
                Some(PluginResponse::ProcessingStarted)
            } else {
                Some(PluginResponse::Error {
                    command: "StartProcessing".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }

        PluginCommand::StopProcessing => {
            if let Some(ref mut state) = plugin_state {
                if state.processing {
                    // Processing will be stopped in deactivate() for now
                    state.processing = false;
                    info!("Plugin processing stopped");
                }
                Some(PluginResponse::ProcessingStopped)
            } else {
                Some(PluginResponse::Error {
                    command: "StopProcessing".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }

        PluginCommand::Reset => {
            // `reset()` belongs on the audio thread: hand it over and clear any queued events.
            if plugin_state.is_some() {
                audio.reset();
            }
            Some(PluginResponse::ResetComplete)
        }

        PluginCommand::SaveState => {
            let Some(state) = plugin_state else {
                return Some(PluginResponse::Error {
                    command: "SaveState".to_string(),
                    error: "Plugin not initialized".to_string(),
                });
            };
            // Clear before saving: a `mark_dirty` during or after the save is a newer change
            // than this blob and must be reported again.
            state.shared.clear_state_dirty();
            let mut handle = state.instance.plugin_handle();
            let Some(state_ext) = handle.get_extension::<ClapState>() else {
                return Some(PluginResponse::Error {
                    command: "SaveState".to_string(),
                    error: "Plugin has no state extension".to_string(),
                });
            };
            let mut buffer = Vec::new();
            match state_ext.save(&mut handle, &mut buffer) {
                Ok(()) => {
                    info!("Saved {} bytes of plugin state", buffer.len());
                    Some(PluginResponse::StateSaved { state: buffer })
                }
                Err(e) => Some(PluginResponse::Error {
                    command: "SaveState".to_string(),
                    error: format!("Plugin failed to save its state: {}", e),
                }),
            }
        }

        PluginCommand::LoadState { state: bytes } => {
            let Some(state) = plugin_state else {
                return Some(PluginResponse::Error {
                    command: "LoadState".to_string(),
                    error: "Plugin not initialized".to_string(),
                });
            };
            let mut handle = state.instance.plugin_handle();
            let Some(state_ext) = handle.get_extension::<ClapState>() else {
                return Some(PluginResponse::StateLoadResult {
                    success: false,
                    error: Some("Plugin has no state extension".to_string()),
                });
            };
            let mut reader = std::io::Cursor::new(bytes);
            match state_ext.load(&mut handle, &mut reader) {
                Ok(()) => {
                    info!("Restored plugin state");
                    Some(PluginResponse::StateLoadResult {
                        success: true,
                        error: None,
                    })
                }
                Err(e) => Some(PluginResponse::StateLoadResult {
                    success: false,
                    error: Some(format!("Plugin failed to load its state: {}", e)),
                }),
            }
        }

        PluginCommand::GetParameterInfo => {
            if let Some(ref mut state) = plugin_state {
                // Get plugin handle to query parameters
                let mut handle = state.instance.plugin_handle();

                // Try to get the params extension
                let params_ext: Option<PluginParams> = handle.get_extension();

                if let Some(params) = params_ext {
                    let param_count = params.count(&mut handle);
                    let mut param_infos = Vec::with_capacity(param_count as usize);

                    // Query each parameter
                    for i in 0..param_count {
                        let mut buffer = ParamInfoBuffer::new();

                        if let Some(clap_info) = params.get_info(&mut handle, i, &mut buffer) {
                            let name = std::str::from_utf8(clap_info.name)
                                .unwrap_or("Unknown")
                                .trim_end_matches('\0')
                                .to_string();
                            let module = std::str::from_utf8(clap_info.module)
                                .unwrap_or("")
                                .trim_end_matches('\0')
                                .to_string();

                            let is_stepped = clap_info.flags.contains(ParamInfoFlags::IS_STEPPED);
                            let min = clap_info.min_value;
                            let max = clap_info.max_value;
                            let param_id = clap_info.id;

                            let step_labels = if is_stepped {
                                let step_count = (max - min).round() as i64 + 1;
                                if step_count > 0 && step_count <= 64 {
                                    let mut labels = Vec::with_capacity(step_count as usize);
                                    for step in 0..step_count {
                                        let value = min + step as f64;
                                        let mut text_buffer =
                                            [std::mem::MaybeUninit::<u8>::uninit(); 256];
                                        let label = params
                                            .value_to_text(
                                                &mut handle,
                                                param_id,
                                                value,
                                                &mut text_buffer,
                                            )
                                            .ok()
                                            .and_then(|bytes| std::str::from_utf8(bytes).ok())
                                            .map(|s| s.to_string())
                                            .unwrap_or_else(|| (value.round() as i64).to_string());
                                        labels.push(label);
                                    }
                                    labels
                                } else {
                                    Vec::new()
                                }
                            } else {
                                Vec::new()
                            };

                            let param_info = PluginParameterInfo {
                                id: i, // Use sequential index as ID
                                name,
                                unit: String::new(), // CLAP doesn't expose units separately
                                min: clap_info.min_value as f32,
                                max: clap_info.max_value as f32,
                                default: clap_info.default_value as f32,
                                is_automation_safe: clap_info
                                    .flags
                                    .contains(ParamInfoFlags::IS_AUTOMATABLE),
                                is_stepped,
                                is_hidden: clap_info.flags.contains(ParamInfoFlags::IS_HIDDEN),
                                is_read_only: clap_info.flags.contains(ParamInfoFlags::IS_READONLY),
                                is_bypass: clap_info.flags.contains(ParamInfoFlags::IS_BYPASS),
                                module,
                                step_labels,
                            };

                            param_infos.push(param_info);
                        }
                    }

                    info!("✅ Queried {} parameters from plugin", param_infos.len());
                    // Rebuild the map and publish it to the audio thread.
                    state.param_map = Some(Arc::new(ParamMap::build(&mut state.instance)));
                    audio.set_param_map(Arc::clone(state.param_map.as_ref().expect("built above")));
                    Some(PluginResponse::ParameterInfo {
                        params: param_infos,
                    })
                } else {
                    info!("Plugin does not support params extension");
                    Some(PluginResponse::ParameterInfo { params: Vec::new() })
                }
            } else {
                Some(PluginResponse::Error {
                    command: "GetParameterInfo".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }

        PluginCommand::GetParameter { param_id } => {
            let Some(ref mut state) = plugin_state else {
                return Some(PluginResponse::Error {
                    command: "GetParameter".to_string(),
                    error: "Plugin not initialized".to_string(),
                });
            };
            let Some(entry) = state.param_map().get(param_id) else {
                return Some(PluginResponse::Error {
                    command: "GetParameter".to_string(),
                    error: format!("Parameter {} not found", param_id),
                });
            };
            let mut handle = state.instance.plugin_handle();
            let value = handle
                .get_extension::<PluginParams>()
                .and_then(|params| params.get_value(&mut handle, entry.clap_id));
            match value {
                Some(value) => Some(PluginResponse::ParameterValue {
                    param_id,
                    value: entry.normalize(value),
                }),
                None => Some(PluginResponse::Error {
                    command: "GetParameter".to_string(),
                    error: format!("Failed to get value for parameter {}", param_id),
                }),
            }
        }

        PluginCommand::SetParameter { param_id, value } => {
            let Some(ref mut state) = plugin_state else {
                return Some(PluginResponse::Error {
                    command: "SetParameter".to_string(),
                    error: "Plugin not initialized".to_string(),
                });
            };
            let Some(entry) = state.param_map().get(param_id) else {
                return Some(PluginResponse::Error {
                    command: "SetParameter".to_string(),
                    error: format!("Parameter {} not found", param_id),
                });
            };
            let denormalized = entry.denormalize(value);

            if state.activated {
                // While the plugin is processing, the audio thread applies the change as an
                // input event, which keeps it ordered with the audio it affects.
                info!(
                    "Queuing parameter change for the audio thread: {} = {} (denormalized: {:.2})",
                    param_id, value, denormalized
                );
                audio.set_parameter(entry.clap_id, denormalized);
            } else {
                // Not processing: apply it directly so edits take effect while stopped.
                info!(
                    "Applying parameter change: {} = {} (denormalized: {:.2})",
                    param_id, value, denormalized
                );
                let mut handle = state.instance.plugin_handle();
                let Some(params) = handle.get_extension::<PluginParams>() else {
                    return Some(PluginResponse::Error {
                        command: "SetParameter".to_string(),
                        error: "Plugin does not support params extension".to_string(),
                    });
                };
                let mut input_events = EventBuffer::new();
                input_events.push(&ParamValueEvent::new(
                    0, // Sample offset
                    entry.clap_id,
                    Pckn::new(0u16, 0u16, 0u16, 0u32),
                    denormalized,
                    Cookie::empty(),
                ));
                let mut output_events = EventBuffer::new();
                params.flush(
                    &mut handle,
                    &InputEvents::from_buffer(&input_events),
                    &mut OutputEvents::from_buffer(&mut output_events),
                );
            }

            // Echo the engine's own value back so Godot's control follows the model.
            let _ = event_tx.send(HostMessage::Event {
                instance_id,
                event: crate::audio::ipc::PluginEvent::ParameterValueChanged { param_id, value },
            });

            None // No response needed (fire-and-forget)
        }

        _ => {
            // TODO: Implement remaining commands
            warn!("Command not yet implemented: {:?}", cmd);
            Some(PluginResponse::Error {
                command: format!("{:?}", cmd),
                error: "Not implemented".to_string(),
            })
        }
    }
}

/// Stop processing on the audio thread and deactivate the instance on the main thread.
fn deactivate_plugin(state: &mut PluginState, audio: &AudioThreadHandle) {
    if let Some(stopped) = audio.take_processor() {
        state.instance.deactivate(stopped);
    } else if state.instance.is_active() {
        // No processor to hand back (the audio thread wasn't holding one): deactivate directly.
        if let Err(e) = state.instance.try_deactivate() {
            warn!("Failed to deactivate plugin instance: {:?}", e);
        }
    }
    state.activated = false;
    state.processing = false;
}

/// The plugin's reported latency at the current sample rate, 0 when it has no latency extension.
fn query_latency(state: &mut PluginState) -> u32 {
    let mut handle = state.instance.plugin_handle();
    let Some(latency) = handle.get_extension::<PluginLatency>() else {
        return 0;
    };
    latency.get(&mut handle)
}
