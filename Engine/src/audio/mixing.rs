use crossbeam::channel::Sender;
use std::collections::{HashMap, HashSet};
use tracing::info;

use super::commands::{EngineState, EngineStatus};
use super::types::*;

fn db_to_gain(db: f32) -> f32 {
    if db <= -60.0 {
        0.0
    } else {
        10.0_f32.powf(db / 20.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::commands::EngineState;
    use crate::audio::types::{Channel, PanMode, Send};
    use crossbeam::channel::unbounded;

    fn warm_gain(channel: &mut Channel, iterations: usize) {
        for _ in 0..iterations {
            let _ = channel.get_smoothed_gain();
        }
    }

    #[test]
    fn post_fader_send_routes_signal_to_bus() {
        let buffer_size = 4;
        let sample_rate = 48_000.0;
        let mut state = EngineState::default();
        state.device_sample_rate = sample_rate;

        let mut master = Channel::new(1, "Master".to_string(), buffer_size, sample_rate);
        master.output_channel_id = Some(1000);
        master.volume_db = 0.0;
        master.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut master, 256);

        let mut bus = Channel::new(2, "Bus".to_string(), buffer_size, sample_rate);
        bus.output_channel_id = Some(1);
        bus.volume_db = 0.0;
        bus.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut bus, 256);

        let mut source = Channel::new(3, "Source".to_string(), buffer_size, sample_rate);
        source.output_channel_id = None;
        source.volume_db = 0.0;
        source.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut source, 256);
        source.buffer_left.fill(0.5);
        source.buffer_right.fill(0.5);
        source.send_channels.push(Send {
            target_channel_id: 2,
            amount_db: 0.0,
            pre_fader: false,
            muted: false,
        });

        state.channels.insert(1, master);
        state.channels.insert(2, bus);
        state.channels.insert(3, source);

        let (status_tx, _status_rx) = unbounded();
        let mut output = vec![0.0f32; buffer_size * 2];
        mix_and_output(&mut state, &mut output, 2, &status_tx);

        let bus = state.channels.get(&2).unwrap();
        assert!((bus.buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((bus.buffer_right[0] - 0.5).abs() < 1e-4);

        let master = state.channels.get(&1).unwrap();
        assert!((master.buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((master.buffer_right[0] - 0.5).abs() < 1e-4);

        assert!((output[0] - 0.5).abs() < 1e-4);
        assert!((output[1] - 0.5).abs() < 1e-4);
    }

    #[test]
    fn pre_fader_send_bypasses_channel_fader() {
        let buffer_size = 4;
        let sample_rate = 48_000.0;
        let mut state = EngineState::default();
        state.device_sample_rate = sample_rate;

        let mut master = Channel::new(1, "Master".to_string(), buffer_size, sample_rate);
        master.output_channel_id = Some(1000);
        master.volume_db = 0.0;
        master.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut master, 256);

        let mut bus = Channel::new(2, "Bus".to_string(), buffer_size, sample_rate);
        bus.output_channel_id = Some(1);
        bus.volume_db = 0.0;
        bus.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut bus, 256);

        let mut source = Channel::new(3, "Source".to_string(), buffer_size, sample_rate);
        source.output_channel_id = None;
        source.volume_db = -60.0;
        source.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut source, 512);
        source.buffer_left.fill(0.5);
        source.buffer_right.fill(0.5);
        source.send_channels.push(Send {
            target_channel_id: 2,
            amount_db: 0.0,
            pre_fader: true,
            muted: false,
        });

        state.channels.insert(1, master);
        state.channels.insert(2, bus);
        state.channels.insert(3, source);

        let (status_tx, _status_rx) = unbounded();
        let mut output = vec![0.0f32; buffer_size * 2];
        mix_and_output(&mut state, &mut output, 2, &status_tx);

        let bus = state.channels.get(&2).unwrap();
        assert!((bus.buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((bus.buffer_right[0] - 0.5).abs() < 1e-4);

        let master = state.channels.get(&1).unwrap();
        assert!((master.buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((master.buffer_right[0] - 0.5).abs() < 1e-4);

        let source = state.channels.get(&3).unwrap();
        assert!(source.buffer_left[0].abs() < 1e-3);
        assert!(source.buffer_right[0].abs() < 1e-3);

        assert!((output[0] - 0.5).abs() < 1e-4);
        assert!((output[1] - 0.5).abs() < 1e-4);
    }
}

/// Mix channels and output to audio device
pub fn mix_and_output(
    state: &mut EngineState,
    data: &mut [f32],
    channels: usize,
    status_tx: &Sender<EngineStatus>,
) {
    // Check if any channel has solo
    let has_solo = state.channels.values().any(|c| c.solo);

    static mut DEBUG_FRAME_COUNT: u32 = 0;
    unsafe {
        DEBUG_FRAME_COUNT += 1;
        if DEBUG_FRAME_COUNT == 10 || DEBUG_FRAME_COUNT % 100 == 0 {
            // Log frame 10 and every 100 frames
            let mut ids: Vec<_> = state.channels.keys().copied().collect();
            ids.sort();
            info!(
                "Channels in mix_and_output (frame {}): {} channels = {:?}",
                DEBUG_FRAME_COUNT,
                state.channels.len(),
                ids
            );

            // Log channel details
            for (&id, ch) in &state.channels {
                let peak_left = ch.buffer_left.iter().map(|s| s.abs()).fold(0.0, f32::max);
                let peak_right = ch.buffer_right.iter().map(|s| s.abs()).fold(0.0, f32::max);
                info!(
                    "  Channel {}: vol={:.2}dB pan={:.2} route_to={:?} peak_L={:.6} peak_R={:.6}",
                    id, ch.volume_db, ch.pan, ch.output_channel_id, peak_left, peak_right
                );
            }
        }
    }

    // First pass: Process device chains (instruments and effects)
    // Process effects BEFORE applying fader so fader is applied to final output
    // IMPORTANT: Skip bus channels here - they'll be processed in Phase 4 after receiving routed audio
    let sample_count = state
        .channels
        .values()
        .next()
        .map(|c| c.buffer_left.len())
        .unwrap_or(0);

    // Cache pre-fader audio for channels that have pre-fader sends so we can tap the signal before fader
    let mut pre_fader_sources: HashMap<ChannelId, (Vec<f32>, Vec<f32>)> = HashMap::new();
    if sample_count > 0 {
        for (&id, channel) in state.channels.iter() {
            if channel
                .send_channels
                .iter()
                .any(|send| send.pre_fader && !send.muted)
            {
                pre_fader_sources.insert(
                    id,
                    (channel.buffer_left.clone(), channel.buffer_right.clone()),
                );
            }
        }
    }

    // Identify bus channels (channels that other channels route TO or receive sends)
    let mut bus_channel_ids: HashSet<ChannelId> = HashSet::new();
    for channel in state.channels.values() {
        if let Some(output_id) = channel.output_channel_id {
            if output_id < 1000 {
                // Only channels, not devices
                bus_channel_ids.insert(output_id);
            }
        }
        for send in &channel.send_channels {
            if send.target_channel_id < 1000 {
                bus_channel_ids.insert(send.target_channel_id);
            }
        }
    }

    for channel in state.channels.values_mut() {
        // Skip bus channels - they'll be processed in Phase 4 after receiving routed audio
        if bus_channel_ids.contains(&channel.id) {
            continue;
        }
        channel.process_device_chain(sample_count);

        // Check for pending parameter changes from CLAP plugins (GUI/modulation changes)
        // Note: Bus channels will have their parameters checked in Phase 4
        for (device_pos, device) in channel.devices.iter_mut().enumerate() {
            // Try to downcast to ClapDeviceAdapter (in-process)
            if let Some(clap_adapter) = device
                .as_any_mut()
                .downcast_mut::<super::devices::clap_host::ClapDeviceAdapter>(
            ) {
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
            else if let Some(subprocess_adapter) =
                device
                    .as_any_mut()
                    .downcast_mut::<super::devices::clap_host::SubprocessClapAdapter>()
            {
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
            // Also check SfizzDevice for parameter list changes (after loading new SFZ)
            else if let Some(sfizz_device) = device
                .as_any_mut()
                .downcast_mut::<super::devices::SfizzDevice>()
            {
                if sfizz_device.take_parameters_changed() {
                    info!("🎹 SFZ parameters changed! Sending parameter list for channel {} device {}",
                        channel.id, device_pos);

                    // Parameters changed (new SFZ loaded), send updated parameter list to Godot
                    let params = device.parameters();

                    info!("📋 Sending {} parameters to Godot", params.len());

                    if !params.is_empty() {
                        // Send parameter count
                        let _ = status_tx.send(EngineStatus::PluginParameterCount {
                            channel_id: channel.id,
                            device_position: device_pos,
                            count: params.len(),
                        });

                        // Send parameter info for each parameter
                        for param in params.iter() {
                            info!(
                                "  Param {}: {} (range {:.2}-{:.2}, default {:.2})",
                                param.id, param.name, param.min, param.max, param.default
                            );
                            let _ = status_tx.send(EngineStatus::PluginParameterInfo {
                                channel_id: channel.id,
                                device_position: device_pos,
                                param_id: param.id,
                                name: param.name.clone(),
                                min: param.min,
                                max: param.max,
                                default: param.default,
                            });
                        }
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
                info!(
                    "Skipping channel {} (mute={}, solo={}, has_solo={})",
                    channel.id, channel.mute, channel.solo, has_solo
                );
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

    // Collect send contributions before hierarchical routing so they are processed like regular bus inputs
    let mut send_accum: HashMap<ChannelId, (Vec<f32>, Vec<f32>)> = HashMap::new();
    let mut pending_bus_processing: HashSet<ChannelId> = HashSet::new();

    static mut SEND_DEBUG_COUNT: u32 = 0;
    let should_log_sends = unsafe {
        SEND_DEBUG_COUNT += 1;
        SEND_DEBUG_COUNT <= 5 || SEND_DEBUG_COUNT % 100 == 0
    };

    if sample_count > 0 {
        for (&source_id, channel) in state.channels.iter() {
            if channel.send_channels.is_empty() {
                continue;
            }
            if channel.mute || (has_solo && !channel.solo) {
                continue;
            }

            for send in &channel.send_channels {
                if send.muted {
                    continue;
                }
                if send.target_channel_id == 0
                    || send.target_channel_id == source_id
                    || send.target_channel_id >= 1000
                {
                    continue;
                }
                if !state.channels.contains_key(&send.target_channel_id) {
                    continue;
                }

                let send_gain = db_to_gain(send.amount_db);
                if send_gain <= 0.0 {
                    continue;
                }

                let entry = send_accum
                    .entry(send.target_channel_id)
                    .or_insert_with(|| (vec![0.0; sample_count], vec![0.0; sample_count]));

                let buffer_len = channel
                    .buffer_left
                    .len()
                    .min(channel.buffer_right.len())
                    .min(sample_count);
                if buffer_len == 0 {
                    continue;
                }

                if should_log_sends {
                    let source_peak_l = channel.buffer_left.iter().take(buffer_len).map(|s| s.abs()).fold(0.0, f32::max);
                    let source_peak_r = channel.buffer_right.iter().take(buffer_len).map(|s| s.abs()).fold(0.0, f32::max);
                    info!("🔊 SEND: Ch{} → Ch{} (gain={:.2}dB={:.4}x, peak_L={:.6}, peak_R={:.6})",
                        source_id, send.target_channel_id, send.amount_db, send_gain, source_peak_l, source_peak_r);
                }

                if send.pre_fader {
                    if let Some((pre_left, pre_right)) = pre_fader_sources.get(&source_id) {
                        let pan = channel.get_pan_coefficients();
                        for i in 0..buffer_len {
                            let left_in = pre_left[i];
                            let right_in = pre_right[i];
                            let panned_left =
                                left_in * pan.left_to_left + right_in * pan.right_to_left;
                            let panned_right =
                                left_in * pan.left_to_right + right_in * pan.right_to_right;
                            entry.0[i] += panned_left * send_gain;
                            entry.1[i] += panned_right * send_gain;
                        }
                    }
                } else {
                    for i in 0..buffer_len {
                        entry.0[i] += channel.buffer_left[i] * send_gain;
                        entry.1[i] += channel.buffer_right[i] * send_gain;
                    }
                }

                pending_bus_processing.insert(send.target_channel_id);
            }
        }
    }

    for (target_id, (send_left, send_right)) in send_accum.into_iter() {
        if let Some(target_ch) = state.channels.get_mut(&target_id) {
            if target_ch.mute || (has_solo && !target_ch.solo) {
                if should_log_sends {
                    info!("🔇 SEND target {} is muted or not soloed, skipping", target_id);
                }
                continue;
            }

            let dest_gain = target_ch.get_gain();
            let len = target_ch
                .buffer_left
                .len()
                .min(target_ch.buffer_right.len())
                .min(sample_count);

            let (pre_mix_peak_l, pre_mix_peak_r, post_mix_peak_l, post_mix_peak_r) = if should_log_sends {
                let pre_l = target_ch.buffer_left.iter().take(len).map(|s| s.abs()).fold(0.0, f32::max);
                let pre_r = target_ch.buffer_right.iter().take(len).map(|s| s.abs()).fold(0.0, f32::max);
                
                for i in 0..len {
                    target_ch.buffer_left[i] += send_left[i] * dest_gain;
                    target_ch.buffer_right[i] += send_right[i] * dest_gain;
                }
                
                let post_l = target_ch.buffer_left.iter().take(len).map(|s| s.abs()).fold(0.0, f32::max);
                let post_r = target_ch.buffer_right.iter().take(len).map(|s| s.abs()).fold(0.0, f32::max);
                (pre_l, pre_r, post_l, post_r)
            } else {
                for i in 0..len {
                    target_ch.buffer_left[i] += send_left[i] * dest_gain;
                    target_ch.buffer_right[i] += send_right[i] * dest_gain;
                }
                (0.0, 0.0, 0.0, 0.0)
            };
            
            if should_log_sends {
                info!("📥 SEND mixed into Ch{}: dest_gain={:.4}, pre=({:.6},{:.6}), post=({:.6},{:.6}), routes_to={:?}",
                    target_id, dest_gain, pre_mix_peak_l, pre_mix_peak_r, post_mix_peak_l, post_mix_peak_r, target_ch.output_channel_id);
            }
        }
    }

    // Third pass: Mix channels into their destinations with hierarchical routing support
    // We need multiple passes to handle: Track → Bus → Master
    // Use a buffer copy strategy to track which channels have been processed
    let mut channel_buffers: HashMap<ChannelId, (Vec<f32>, Vec<f32>)> = HashMap::new();

    // Collect initial channel buffers
    for (&id, channel) in &state.channels {
        if id < 1000 {
            channel_buffers.insert(
                id,
                (channel.buffer_left.clone(), channel.buffer_right.clone()),
            );
        }
    }

    // Track which channels are buses (received routed audio in current pass)
    let mut bus_destinations: HashSet<ChannelId> = HashSet::new();

    // Single pass routing: collect operations in dependency order
    // Track which channels have been processed to avoid re-routing the same audio
    let mut processed_channels: HashSet<ChannelId> = HashSet::new();
    processed_channels.insert(1); // Master never routes further

    // Multi-pass routing: up to 10 passes to handle arbitrary nesting
    static mut ROUTING_DEBUG_COUNT: u32 = 0;
    let should_log_routing = unsafe {
        ROUTING_DEBUG_COUNT += 1;
        ROUTING_DEBUG_COUNT <= 5 || ROUTING_DEBUG_COUNT % 100 == 0
    };

    for routing_pass in 0..10 {
        let mut mix_operations: Vec<(ChannelId, ChannelId, Vec<f32>, Vec<f32>)> = Vec::new();

        if should_log_routing {
            info!("🔄 Routing pass {}: processed_channels={:?}", routing_pass, processed_channels);
        }

        // First, mark buses that need device processing (from sends) - they shouldn't route PRE-device audio
        let buses_needing_processing: HashSet<ChannelId> = if routing_pass == 0 {
            pending_bus_processing.iter().copied().collect()
        } else {
            HashSet::new()
        };

        for (&id, channel) in &state.channels {
            // Skip if already processed (routed to another channel)
            if processed_channels.contains(&id) {
                continue;
            }

            // Skip buses that need to process devices first (they'll route POST-device audio later)
            if buses_needing_processing.contains(&id) {
                if should_log_routing {
                    info!("⏸️  Skipping Ch{} in routing pass {} - needs device processing first", id, routing_pass);
                }
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
                continue; // No audio to route
            }

            // If this channel routes to another channel (not a device), prepare mix operation
            if let Some(output_id) = channel.output_channel_id {
                // Only mix into other channels (ID < 1000), not devices (ID >= 1000)
                if output_id != id && output_id < 1000 && state.channels.contains_key(&output_id) {
                    if should_log_routing {
                        info!("📤 Routing pass {}: Ch{} → Ch{} (peak={:.6})", routing_pass, id, output_id, peak);
                    }
                    mix_operations.push((id, output_id, buf_left, buf_right));
                    processed_channels.insert(id); // Mark as processed
                    bus_destinations.insert(output_id); // Track that this channel received routed audio
                }
            }
        }

        for channel_id in pending_bus_processing.drain() {
            if should_log_routing {
                info!("➕ Adding Ch{} to bus_destinations from pending_bus_processing", channel_id);
            }
            bus_destinations.insert(channel_id);
        }

        if should_log_routing {
            info!("🔄 Pass {}: {} mix ops, {} bus dests", routing_pass, mix_operations.len(), bus_destinations.len());
        }

        if mix_operations.is_empty() && bus_destinations.is_empty() {
            if should_log_routing {
                info!("✅ Routing complete after {} passes", routing_pass);
            }
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
            }
        }

        // Fourth pass: After mixing audio INTO buses, apply bus pan and effects
        // Bus pan is applied to the received routed audio (which already has source pan applied)
        // This allows buses to further pan the mixed signal before routing to their output
        let buses_to_process: Vec<ChannelId> = bus_destinations.iter().copied().collect();
        
        if should_log_routing && !buses_to_process.is_empty() {
            info!("🎛️  Processing {} buses: {:?}", buses_to_process.len(), buses_to_process);
        }
        
        for bus_id in buses_to_process {
            if let Some(bus_ch) = state.channels.get_mut(&bus_id) {
                // Skip if muted or solo-excluded
                if bus_ch.mute || (has_solo && !bus_ch.solo) {
                    if should_log_routing {
                        info!("⏭️  Skipping bus {} (muted or not soloed)", bus_id);
                    }
                    continue;
                }

                if should_log_routing {
                    let pre_l = bus_ch.buffer_left.iter().take(sample_count).map(|s| s.abs()).fold(0.0, f32::max);
                    let pre_r = bus_ch.buffer_right.iter().take(sample_count).map(|s| s.abs()).fold(0.0, f32::max);
                    info!("🎚️  Bus {} PRE-device: peak=({:.6},{:.6}), devices={}, routes_to={:?}",
                        bus_id, pre_l, pre_r, bus_ch.devices.len(), bus_ch.output_channel_id);
                }

                // Process the bus's effect chain on the accumulated routed audio
                // Effects (like delay) should process the mixed audio
                bus_ch.process_device_chain(sample_count);

                if should_log_routing {
                    let post_device_peak_l = bus_ch.buffer_left.iter().take(sample_count).map(|s| s.abs()).fold(0.0, f32::max);
                    let post_device_peak_r = bus_ch.buffer_right.iter().take(sample_count).map(|s| s.abs()).fold(0.0, f32::max);
                    info!("🎛️  Bus {} POST-device: peak=({:.6},{:.6})",
                        bus_id, post_device_peak_l, post_device_peak_r);
                }

                // Check for pending parameter changes from CLAP plugins on buses
                for (device_pos, device) in bus_ch.devices.iter_mut().enumerate() {
                    if let Some(clap_adapter) = device
                        .as_any_mut()
                        .downcast_mut::<super::devices::clap_host::ClapDeviceAdapter>(
                    ) {
                        let pending_changes = clap_adapter.take_pending_param_changes();
                        for (param_id, value) in pending_changes {
                            let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                                channel_id: bus_id,
                                device_position: device_pos,
                                param_id,
                                value,
                            });
                        }
                    } else if let Some(subprocess_adapter) =
                        device
                            .as_any_mut()
                            .downcast_mut::<super::devices::clap_host::SubprocessClapAdapter>()
                    {
                        if let Some(pending_changes) = subprocess_adapter.poll_parameter_changes() {
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
                }

                // Apply the bus's pan to the received audio
                // This is separate from source panning - it pans the entire bus mix
                let pan = bus_ch.get_pan_coefficients();
                for i in 0..bus_ch.buffer_left.len() {
                    let left_in = bus_ch.buffer_left[i];
                    let right_in = bus_ch.buffer_right[i];

                    // Apply 4-coefficient pan matrix to bus's mixed audio
                    bus_ch.buffer_left[i] =
                        left_in * pan.left_to_left + right_in * pan.right_to_left;
                    bus_ch.buffer_right[i] =
                        left_in * pan.left_to_right + right_in * pan.right_to_right;
                }

                // Update channel_buffers with the post-effect, post-pan audio so it routes correctly next pass
                channel_buffers.insert(
                    bus_id,
                    (bus_ch.buffer_left.clone(), bus_ch.buffer_right.clone()),
                );

                // CRITICAL: Remove from processed_channels so the bus can route its POST-device audio in the next pass
                // This allows buses to route their processed output (e.g., reverb) to master/other buses
                processed_channels.remove(&bus_id);
                
                if should_log_routing {
                    info!("🔄 Bus {} processed devices, will route POST-device audio in next pass", bus_id);
                }
            }
        }

        // Clear bus_destinations for next iteration
        bus_destinations.clear();
    }

    // After all routing passes, sync channel_buffers back to state.channels for accurate peak metering
    // This ensures peaks reflect post-effect, post-pan levels
    for (&id, channel) in state.channels.iter_mut() {
        if id < 1000 {
            // Skip device outputs
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
