use std::collections::{HashMap, HashSet};
use crossbeam::channel::Sender;
use tracing::info;

use super::types::*;
use super::commands::{EngineState, EngineStatus};

/// Mix channels and output to audio device
pub fn mix_and_output(state: &mut EngineState, data: &mut [f32], channels: usize, status_tx: &Sender<EngineStatus>) {
    // Check if any channel has solo
    let has_solo = state.channels.values().any(|c| c.solo);

    static mut DEBUG_FRAME_COUNT: u32 = 0;
    unsafe {
        DEBUG_FRAME_COUNT += 1;
        if DEBUG_FRAME_COUNT == 10 || DEBUG_FRAME_COUNT % 100 == 0 {  // Log frame 10 and every 100 frames
            let mut ids: Vec<_> = state.channels.keys().copied().collect();
            ids.sort();
            info!("Channels in mix_and_output (frame {}): {} channels = {:?}", DEBUG_FRAME_COUNT, state.channels.len(), ids);

            // Log channel details
            for (&id, ch) in &state.channels {
                let peak_left = ch.buffer_left.iter().map(|s| s.abs()).fold(0.0, f32::max);
                let peak_right = ch.buffer_right.iter().map(|s| s.abs()).fold(0.0, f32::max);
                info!("  Channel {}: vol={:.2}dB pan={:.2} route_to={:?} peak_L={:.6} peak_R={:.6}",
                    id, ch.volume_db, ch.pan, ch.output_channel_id, peak_left, peak_right);
            }
        }
    }

    // First pass: Process device chains (instruments and effects)
    // Process effects BEFORE applying fader so fader is applied to final output
    let sample_count = state.channels.values().next().map(|c| c.buffer_left.len()).unwrap_or(0);
    for channel in state.channels.values_mut() {
        channel.process_device_chain(sample_count);
        
        // Check for pending parameter changes from CLAP plugins (GUI/modulation changes)
        for (device_pos, device) in channel.devices.iter_mut().enumerate() {
            // Try to downcast to ClapDeviceAdapter (in-process)
            if let Some(clap_adapter) = device.as_any_mut().downcast_mut::<super::devices::clap_host::ClapDeviceAdapter>() {
                let pending_changes = clap_adapter.take_pending_param_changes();
                for (param_id, value) in pending_changes {
                    let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                        channel_id: channel.id,
                        device_position: device_pos,
                        param_id,
                        value,
                    });
                }
            }
            // Also check SubprocessClapAdapter (subprocess-based plugins)
            else if let Some(subprocess_adapter) = device.as_any_mut().downcast_mut::<super::devices::clap_host::SubprocessClapAdapter>() {
                // Poll for unsolicited ParameterValueChanged messages from subprocess
                if let Some(pending_changes) = subprocess_adapter.poll_parameter_changes() {
                    for (param_id, value) in pending_changes {
                        let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                            channel_id: channel.id,
                            device_position: device_pos,
                            param_id,
                            value,
                        });
                    }
                }
            }
        }
    }

    // Second pass: Apply each channel's fader (gain/pan) to its own buffer
    // This makes the buffer content "post-fader" for accurate peak metering
    // Use per-sample smoothing to prevent clicks when changing volume
    // NOTE: Buses don't have local audio, so pan applied here does nothing.
    // Buses will apply pan in pass 4 after they receive routed audio.
    for channel in state.channels.values_mut() {
        // Skip if muted or (solo exists and this channel isn't soloed)
        if channel.mute || (has_solo && !channel.solo) {
            if channel.id >= 2 && channel.id < 1000 {
                info!("Skipping channel {} (mute={}, solo={}, has_solo={})",
                    channel.id, channel.mute, channel.solo, has_solo);
            }
            channel.clear_buffers();
            continue;
        }

        let pan = channel.get_pan_coefficients();

        // Apply smoothed gain and pan per-sample to prevent clicks/pops
        for i in 0..channel.buffer_left.len() {
            let smoothed_gain = channel.get_smoothed_gain();
            let left_in = channel.buffer_left[i] * smoothed_gain;
            let right_in = channel.buffer_right[i] * smoothed_gain;

            // Apply 4-coefficient pan matrix
            channel.buffer_left[i] = left_in * pan.left_to_left + right_in * pan.right_to_left;
            channel.buffer_right[i] = left_in * pan.left_to_right + right_in * pan.right_to_right;
        }
    }

    // Third pass: Mix channels into their destinations with hierarchical routing support
    // We need multiple passes to handle: Track → Bus → Master
    // Use a buffer copy strategy to track which channels have been processed
    let mut channel_buffers: HashMap<ChannelId, (Vec<f32>, Vec<f32>)> = HashMap::new();

    // Collect initial channel buffers
    for (&id, channel) in &state.channels {
        if id < 1000 {
            channel_buffers.insert(id, (channel.buffer_left.clone(), channel.buffer_right.clone()));
        }
    }

    // Track which channels are buses (received routed audio in current pass)
    let mut bus_destinations: HashSet<ChannelId> = HashSet::new();

    // Single pass routing: collect operations in dependency order
    // Track which channels have been processed to avoid re-routing the same audio
    let mut processed_channels: HashSet<ChannelId> = HashSet::new();
    processed_channels.insert(1);  // Master never routes further

    // Multi-pass routing: up to 10 passes to handle arbitrary nesting
    for routing_pass in 0..10 {
        let mut mix_operations: Vec<(ChannelId, ChannelId, Vec<f32>, Vec<f32>)> = Vec::new();

        for (&id, channel) in &state.channels {
            // Skip if already processed (routed to another channel)
            if processed_channels.contains(&id) {
                continue;
            }

            // Skip muted/non-soloed channels (already cleared above)
            if channel.mute || (has_solo && !channel.solo) {
                continue;
            }

            // Get current buffer state from our tracking
            let (buf_left, buf_right) = if let Some((bl, br)) = channel_buffers.get(&id) {
                (bl.clone(), br.clone())
            } else {
                continue;
            };

            // Check if this buffer has any audio to route (check BOTH channels)
            let peak_left = buf_left.iter().map(|s| s.abs()).fold(0.0, f32::max);
            let peak_right = buf_right.iter().map(|s| s.abs()).fold(0.0, f32::max);
            let peak = peak_left.max(peak_right);
            if peak < 0.0001 {
                continue;  // No audio to route
            }

            // If this channel routes to another channel (not a device), prepare mix operation
            if let Some(output_id) = channel.output_channel_id {
                // Only mix into other channels (ID < 1000), not devices (ID >= 1000)
                if output_id != id && output_id < 1000 && state.channels.contains_key(&output_id) {
                    info!("Routing pass {}: Channel {} → {} (peak: {:.6})", routing_pass, id, output_id, peak);
                    mix_operations.push((id, output_id, buf_left, buf_right));
                    processed_channels.insert(id);  // Mark as processed
                    bus_destinations.insert(output_id);  // Track that this channel received routed audio
                }
            }
        }

        // If no more operations, we're done
        if mix_operations.is_empty() {
            break;
        }

        // Apply mix operations
        for (src_id, output_id, buffer_left, buffer_right) in mix_operations {
            // The routed audio already has the source channel's gain applied (from pass 2)
            // We only apply the destination channel's GAIN during mixing into it
            // Do NOT apply pan during routing - pan was already applied in pass 2 for source channels
            // and buses don't have local audio so their pan in pass 2 was meaningless (will redo in pass 4)

            let dest_gain = if let Some(output_ch) = state.channels.get(&output_id) {
                output_ch.get_gain()
            } else {
                continue;
            };

            if src_id >= 2 {
                info!("Routing pass {}: {} → {} with dest_gain={:.6}",
                    routing_pass, src_id, output_id, dest_gain);
            }

            // Mix into the channel's buffer, applying destination's fader (gain)
            if let Some((dest_left, dest_right)) = channel_buffers.get_mut(&output_id) {
                for i in 0..buffer_left.len().min(dest_left.len()) {
                    dest_left[i] += buffer_left[i] * dest_gain;
                    dest_right[i] += buffer_right[i] * dest_gain;
                }
            }

            // Also update the actual channel state so peak meters and output are correct
            if let Some(output_ch) = state.channels.get_mut(&output_id) {
                for i in 0..buffer_left.len().min(output_ch.buffer_left.len()) {
                    output_ch.buffer_left[i] += buffer_left[i] * dest_gain;
                    output_ch.buffer_right[i] += buffer_right[i] * dest_gain;
                }
                let peak_after = output_ch.buffer_left.iter().map(|s| s.abs()).fold(0.0, f32::max);
                info!("Mix applied pass {}: {} → {} (peak after: {:.6})", routing_pass, src_id, output_id, peak_after);
            }
        }

        // Fourth pass: After mixing audio INTO buses, apply bus pan and effects
        // Bus pan is applied to the received routed audio (which already has source pan applied)
        // This allows buses to further pan the mixed signal before routing to their output
        let buses_to_process: Vec<ChannelId> = bus_destinations.iter().copied().collect();
        for bus_id in buses_to_process {
            if let Some(bus_ch) = state.channels.get_mut(&bus_id) {
                // Skip if muted or solo-excluded
                if bus_ch.mute || (has_solo && !bus_ch.solo) {
                    continue;
                }

                // Process the bus's effect chain on the accumulated routed audio
                // Effects (like delay) should process the mixed audio
                bus_ch.process_device_chain(sample_count);
                
                // Check for pending parameter changes from CLAP plugins on buses
                for (device_pos, device) in bus_ch.devices.iter_mut().enumerate() {
                    if let Some(clap_adapter) = device.as_any_mut().downcast_mut::<super::devices::clap_host::ClapDeviceAdapter>() {
                        let pending_changes = clap_adapter.take_pending_param_changes();
                        for (param_id, value) in pending_changes {
                            let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                                channel_id: bus_id,
                                device_position: device_pos,
                                param_id,
                                value,
                            });
                        }
                    }
                }

                // Apply the bus's pan to the received audio
                // This is separate from source panning - it pans the entire bus mix
                let pan = bus_ch.get_pan_coefficients();
                for i in 0..bus_ch.buffer_left.len() {
                    let left_in = bus_ch.buffer_left[i];
                    let right_in = bus_ch.buffer_right[i];

                    // Apply 4-coefficient pan matrix to bus's mixed audio
                    bus_ch.buffer_left[i] = left_in * pan.left_to_left + right_in * pan.right_to_left;
                    bus_ch.buffer_right[i] = left_in * pan.left_to_right + right_in * pan.right_to_right;
                }

                // Update channel_buffers with the post-effect, post-pan audio so it routes correctly next pass
                channel_buffers.insert(bus_id, (bus_ch.buffer_left.clone(), bus_ch.buffer_right.clone()));
            }
        }

        // Clear bus_destinations for next iteration
        bus_destinations.clear();
    }

    // After all routing passes, sync channel_buffers back to state.channels for accurate peak metering
    // This ensures peaks reflect post-effect, post-pan levels
    for (&id, channel) in state.channels.iter_mut() {
        if id < 1000 {  // Skip device outputs
            if let Some((buf_left, buf_right)) = channel_buffers.get(&id) {
                channel.buffer_left.copy_from_slice(buf_left);
                channel.buffer_right.copy_from_slice(buf_right);
            }
        }
    }

    // Output the master channel (ID 1) to the audio hardware
    // Master should route to an output device (ID >= 1000)
    // NOTE: Currently we only support outputting to the default device (ID 1000, the one running this stream)
    // In the future, we can support routing to other devices (ID 1001+) by managing multiple streams
    if let Some(master) = state.channels.get(&1) {
        // Check if master routes to a device (ID >= 1000)
        if let Some(output_device_id) = master.output_channel_id {
            if output_device_id >= 1000 {
                // Master routes to an output device - output it to the hardware
                // NOTE: Master's volume/pan are applied when OTHER channels mix INTO master (above)
                // When outputting master to device, we output the buffer directly without additional gain
                // (Master fader controls the level of everything mixed into it, not an additional output stage)
                let frames = data.len() / channels;

                for frame_idx in 0..frames {
                    if frame_idx < master.buffer_left.len() {
                        let left = master.buffer_left[frame_idx].clamp(-1.0, 1.0);
                        let right = master.buffer_right[frame_idx].clamp(-1.0, 1.0);

                        let output_idx = frame_idx * channels;
                        if channels >= 2 {
                            data[output_idx] = left;
                            data[output_idx + 1] = right;
                        } else {
                            data[output_idx] = (left + right) * 0.5; // Mono mix
                        }
                    }
                }
            }
            // If master routes to another channel (ID < 1000), it's already been mixed above
        }
    }
}
