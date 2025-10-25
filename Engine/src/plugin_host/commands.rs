//! Command processing for plugin host
//!
//! Handles all commands received from the main engine via IPC,
//! including initialization, activation, parameter management, and GUI operations.

use tracing::{error, info, warn};

use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_host::events::event_types::{NoteOffEvent, ParamValueEvent};
use clack_host::events::{Pckn, UnknownEvent};
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
use clack_host::utils::Cookie;
use clack_extensions::gui::{PluginGui, GuiSize};
use clack_extensions::params::{PluginParams, ParamInfoBuffer};

use crate::audio::ipc::{SharedMemory, SharedMemoryLayout};

use crate::plugin_host::protocol::{PluginCommand, PluginResponse, PluginParameterInfo};
use crate::plugin_host::state::PluginState;
use crate::plugin_host::operations::{load_plugin, open_plugin_gui, close_plugin_gui, has_plugin_gui};
use crate::plugin_host::ipc_utils::recv_fd_from_socket_raw;

/// Process a command and return response
pub fn process_command(
    cmd: PluginCommand,
    plugin_state: &mut Option<PluginState>,
    unix_socket_fd: i32,
    unsolicited_tx: &std::sync::mpsc::Sender<PluginResponse>,
) -> Option<PluginResponse> {
    match cmd {
        PluginCommand::Initialize {
            plugin_path,
            plugin_id,
            sample_rate,
            max_buffer_size,
            shm_name,
        } => {
            info!("Initializing plugin: {} from {:?}", plugin_id, plugin_path);
            info!("Shared memory name: {}", shm_name);

            info!("Step 1: Loading plugin from disk...");
            let (bundle, instance, shared) = match load_plugin(
                &plugin_path,
                &plugin_id,
                sample_rate,
                max_buffer_size,
                unsolicited_tx.clone(),
            ) {
                Ok(result) => {
                    info!("Step 2: Plugin loaded successfully, now creating shared memory...");
                    result
                }
                Err(e) => {
                    error!("Failed to load plugin: {}", e);
                    return Some(PluginResponse::InitializeError { error: e });
                }
            };

            // Create shared memory layout
            info!(
                "Step 3: Creating shared memory layout (max_buffer_size={})",
                max_buffer_size
            );
            let layout = SharedMemoryLayout::new(max_buffer_size);

            // Receive shared memory FD from parent process via Unix socket
            info!(
                "Step 4: Receiving shared memory FD from Unix socket (FD={})",
                unix_socket_fd
            );

            // Call recv_fd_from_socket_raw directly with the raw FD to avoid UnixStream ownership issues
            info!("Step 4.5: About to call recv_fd_from_socket_raw...");
            let shared_memory = match recv_fd_from_socket_raw(unix_socket_fd) {
                Ok(shm_fd) => {
                    info!(
                        "Step 5: Received shared memory FD={} (after dup), mapping it...",
                        shm_fd
                    );

                    // CRITICAL: Close the Unix socket FD immediately after receiving the shared memory FD
                    // This prevents IO Safety violations when the subprocess exits
                    unsafe {
                        libc::close(unix_socket_fd);
                    }
                    info!(
                        "Step 5.5: Closed Unix socket FD={} (no longer needed)",
                        unix_socket_fd
                    );

                    match SharedMemory::from_fd(shm_fd, layout) {
                        Ok(shm) => {
                            info!(
                                "Step 6: ✅ Shared memory mapped successfully from FD={}!",
                                shm_fd
                            );
                            Some(shm)
                        }
                        Err(e) => {
                            error!("Step 6: ❌ Failed to map shared memory from FD={}: {}. Continuing without shared memory.", shm_fd, e);
                            None
                        }
                    }
                }
                Err(e) => {
                    error!(
                        "Step 5: ❌ Failed to receive shared memory FD: {}. Continuing without shared memory.",
                        e
                    );
                    // Close Unix socket even on error
                    unsafe {
                        libc::close(unix_socket_fd);
                    }
                    None
                }
            };

            info!("Step 6: Preparing plugin state...");
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
                bundle,
                instance,
                shared,
                gui_open: false,
                activated: false,
                processing: false,
                sample_rate,
                max_buffer_size,
                audio_processor: None,
                shared_memory,
                input_buffers,
                output_buffers,
                output_event_buffer: EventBuffer::new(),
                pending_param_changes: Vec::new(),
            });

            info!("Step 7: ✅ Plugin state stored, sending InitializeSuccess response");
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

                        let mut output_audio = output_ports.with_output_buffers([AudioPortBuffer {
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

                            let param_info = PluginParameterInfo {
                                id: i, // Use sequential index as ID
                                name,
                                unit: String::new(), // CLAP doesn't expose units separately
                                min: clap_info.min_value as f32,
                                max: clap_info.max_value as f32,
                                default: clap_info.default_value as f32,
                                is_automation_safe: clap_info
                                    .flags
                                    .contains(clack_extensions::params::ParamInfoFlags::IS_AUTOMATABLE),
                            };

                            param_infos.push(param_info);
                        }
                    }

                    info!("✅ Queried {} parameters from plugin", param_infos.len());
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
            if let Some(ref mut state) = plugin_state {
                // Get plugin handle
                let mut handle = state.instance.plugin_handle();

                // Try to get the params extension
                let params_ext: Option<PluginParams> = handle.get_extension();

                if let Some(params) = params_ext {
                    // First, get parameter info to get the CLAP ID
                    let mut buffer = ParamInfoBuffer::new();

                    if let Some(clap_info) = params.get_info(&mut handle, param_id, &mut buffer) {
                        let clap_id = clap_info.id;

                        // Get the current value
                        if let Some(value) = params.get_value(&mut handle, clap_id) {
                            // Normalize value to 0.0-1.0 range
                            let normalized = ((value - clap_info.min_value)
                                / (clap_info.max_value - clap_info.min_value))
                                as f32;

                            Some(PluginResponse::ParameterValue {
                                param_id,
                                value: normalized.clamp(0.0, 1.0),
                            })
                        } else {
                            Some(PluginResponse::Error {
                                command: "GetParameter".to_string(),
                                error: format!("Failed to get value for parameter {}", param_id),
                            })
                        }
                    } else {
                        Some(PluginResponse::Error {
                            command: "GetParameter".to_string(),
                            error: format!("Parameter {} not found", param_id),
                        })
                    }
                } else {
                    Some(PluginResponse::Error {
                        command: "GetParameter".to_string(),
                        error: "Plugin does not support params extension".to_string(),
                    })
                }
            } else {
                Some(PluginResponse::Error {
                    command: "GetParameter".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }

        PluginCommand::SetParameter { param_id, value } => {
            if let Some(ref mut state) = plugin_state {
                // Get plugin handle
                let mut handle = state.instance.plugin_handle();

                // Try to get the params extension
                let params_ext: Option<PluginParams> = handle.get_extension();

                if let Some(params) = params_ext {
                    // Get parameter info to denormalize the value
                    let mut buffer = ParamInfoBuffer::new();

                    if let Some(clap_info) = params.get_info(&mut handle, param_id, &mut buffer) {
                        let clap_id = clap_info.id;

                        // Denormalize from 0.0-1.0 to actual parameter range
                        let denormalized = clap_info.min_value
                            + (value as f64 * (clap_info.max_value - clap_info.min_value));

                        info!(
                            "Queuing parameter change: {} = {} (denormalized: {:.2})",
                            param_id, value, denormalized
                        );

                        // Queue the parameter change to be applied in the next flush/process call
                        state
                            .pending_param_changes
                            .push((param_id, clap_id, denormalized));

                        // Immediately flush to the plugin if not processing
                        // This ensures parameter changes are applied even when audio isn't running
                        let mut input_events = EventBuffer::new();
                        let event = ParamValueEvent::new(
                            0, // Sample offset
                            clap_id,
                            Pckn::new(0u16, 0u16, 0u16, 0u32),
                            denormalized,
                            Cookie::empty(),
                        );
                        input_events.push(&event);

                        let mut output_events = EventBuffer::new();
                        let input_events_view = InputEvents::from_buffer(&input_events);
                        let mut output_events_view = OutputEvents::from_buffer(&mut output_events);

                        // Use flush to immediately apply parameter change
                        params.flush(&mut handle, &input_events_view, &mut output_events_view);

                        None // No response needed (fire-and-forget)
                    } else {
                        Some(PluginResponse::Error {
                            command: "SetParameter".to_string(),
                            error: format!("Parameter {} not found", param_id),
                        })
                    }
                } else {
                    Some(PluginResponse::Error {
                        command: "SetParameter".to_string(),
                        error: "Plugin does not support params extension".to_string(),
                    })
                }
            } else {
                Some(PluginResponse::Error {
                    command: "SetParameter".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
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
