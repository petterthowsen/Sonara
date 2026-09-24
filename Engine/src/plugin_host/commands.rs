//! Command processing for plugin host
//!
//! Handles all commands received from the main engine via IPC,
//! including initialization, activation, parameter management, and GUI operations.

use std::os::fd::{IntoRawFd, OwnedFd};
use tracing::{error, info, warn};

use clack_extensions::gui::{GuiSize, PluginGui};
use clack_extensions::params::{ParamInfoBuffer, ParamInfoFlags, PluginParams};
use clack_host::events::event_types::{NoteOffEvent, ParamValueEvent};
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
use clack_host::events::{Pckn, UnknownEvent};
use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_host::utils::Cookie;

use crate::audio::ipc::{
    HostMessage, InstanceId, PluginCommand, PluginParameterInfo, PluginResponse, SharedMemory,
    SharedMemoryLayout,
};

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
                Ok(shm) => shm,
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

            // Allocate audio buffers (stereo)
            let input_buffers = vec![vec![0.0; max_buffer_size]; 2];
            let output_buffers = vec![vec![0.0; max_buffer_size]; 2];

            // Store plugin state
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
                audio_processor: None,
                shared_memory: Some(shared_memory),
                input_buffers,
                output_buffers,
                output_event_buffer: EventBuffer::new(),
                pending_param_changes: Vec::new(),
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

        PluginCommand::Activate => {
            if let Some(ref mut state) = plugin_state {
                if state.activated {
                    return Some(PluginResponse::ActivateResult {
                        success: true,
                        error: None,
                    });
                }

                info!(
                    "Activating plugin (sample_rate={}, max_buffer_size={})",
                    state.sample_rate, state.max_buffer_size
                );

                // Activate plugin with audio configuration
                let config = PluginAudioConfiguration {
                    sample_rate: state.sample_rate as f64,
                    min_frames_count: 1,
                    max_frames_count: state.max_buffer_size as u32,
                };

                match state.instance.activate(|_, _| (), config) {
                    Ok(processor) => {
                        // Start processing
                        match processor.start_processing() {
                            Ok(started_processor) => {
                                // Store the processor so we can use it for audio processing
                                state.audio_processor =
                                    Some(PluginAudioProcessorEnum::Started(started_processor));
                                state.activated = true;
                                state.processing = true;
                                info!("✅ Plugin activated and processing started");
                                Some(PluginResponse::ActivateResult {
                                    success: true,
                                    error: None,
                                })
                            }
                            Err(e) => {
                                error!("Failed to start processing: {:?}", e);
                                Some(PluginResponse::ActivateResult {
                                    success: false,
                                    error: Some(format!("Failed to start processing: {:?}", e)),
                                })
                            }
                        }
                    }
                    Err(e) => {
                        error!("Failed to activate plugin: {:?}", e);
                        Some(PluginResponse::ActivateResult {
                            success: false,
                            error: Some(format!("{:?}", e)),
                        })
                    }
                }
            } else {
                Some(PluginResponse::ActivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                })
            }
        }

        PluginCommand::Deactivate => {
            if let Some(ref mut state) = plugin_state {
                if !state.activated {
                    return Some(PluginResponse::DeactivateResult {
                        success: true,
                        error: None,
                    });
                }

                info!("Deactivating plugin");

                // Stop processing and deactivate properly
                if let Some(processor) = state.audio_processor.take() {
                    let stopped = match processor {
                        PluginAudioProcessorEnum::Started(started) => started.stop_processing(),
                        _ => {
                            warn!("Plugin processor in invalid state");
                            return Some(PluginResponse::DeactivateResult {
                                success: false,
                                error: Some("Plugin processor in invalid state".to_string()),
                            });
                        }
                    };

                    // Deactivate the plugin
                    state.instance.deactivate(stopped);
                    state.activated = false;
                    state.processing = false;

                    info!("✅ Plugin deactivated successfully");
                    Some(PluginResponse::DeactivateResult {
                        success: true,
                        error: None,
                    })
                } else {
                    // No processor to deactivate
                    state.activated = false;
                    state.processing = false;
                    Some(PluginResponse::DeactivateResult {
                        success: true,
                        error: None,
                    })
                }
            } else {
                Some(PluginResponse::DeactivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                })
            }
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
            if let Some(ref mut state) = plugin_state {
                // Send "all notes off" MIDI messages (CC 123) to ensure voices stop
                // Many plugins require explicit note-off messages, not just reset()
                if let Some(ref mut processor) = state.audio_processor {
                    if let PluginAudioProcessorEnum::Started(ref mut started_processor) = processor
                    {
                        // Send note-off for all possible MIDI notes (0-127) on all channels (0-15)
                        let mut note_off_events = Vec::new();
                        for channel in 0..16u16 {
                            for note in 0..128u16 {
                                let event = NoteOffEvent::new(
                                    0, // sample offset
                                    Pckn::new(0u16, channel, note, note as u32),
                                    0.0, // velocity
                                );
                                note_off_events.push(event);
                            }
                        }

                        // Convert to event references
                        let event_refs: Vec<&UnknownEvent> =
                            note_off_events.iter().map(|e| e.as_unknown()).collect();

                        // Process these note-offs through the plugin
                        let input_events = InputEvents::from_buffer(&event_refs);
                        let mut output_events =
                            OutputEvents::from_buffer(&mut state.output_event_buffer);

                        // Create empty audio buffers for this reset pass
                        for buf in &mut state.input_buffers {
                            buf.fill(0.0);
                        }
                        for buf in &mut state.output_buffers {
                            buf.fill(0.0);
                        }

                        let mut input_ports = AudioPorts::with_capacity(2, 1);
                        let mut output_ports = AudioPorts::with_capacity(2, 1);

                        let input_audio = input_ports.with_input_buffers([AudioPortBuffer {
                            latency: 0,
                            channels: AudioPortBufferType::f32_input_only(
                                state
                                    .input_buffers
                                    .iter_mut()
                                    .map(|b| InputChannel::constant(&mut b[..64])),
                            ),
                        }]);

                        let mut output_audio =
                            output_ports.with_output_buffers([AudioPortBuffer {
                                latency: 0,
                                channels: AudioPortBufferType::f32_output_only(
                                    state.output_buffers.iter_mut().map(|b| &mut b[..64]),
                                ),
                            }]);

                        // Process to deliver all note-offs
                        let _ = started_processor.process(
                            &input_audio,
                            &mut output_audio,
                            &input_events,
                            &mut output_events,
                            None,
                            None,
                        );

                        // Now call reset() to clear internal state
                        started_processor.reset();
                        info!("Plugin reset: sent all-notes-off and called reset()");
                    }
                }

                // Clear MIDI event queue to prevent any queued events from playing
                if let Some(ref mut shm) = state.shared_memory {
                    let mut midi_queue = shm.midi_queue();
                    midi_queue.clear();
                    info!("MIDI queue cleared during reset");
                }
            }
            Some(PluginResponse::ResetComplete)
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
                    state.param_map = Some(ParamMap::build(&mut state.instance));
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
            info!(
                "Queuing parameter change: {} = {} (denormalized: {:.2})",
                param_id, value, denormalized
            );

            // Reported back to the engine by the event loop
            state
                .pending_param_changes
                .push((entry.clap_id, denormalized));

            // Flush right away so the change applies even while audio isn't running
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
