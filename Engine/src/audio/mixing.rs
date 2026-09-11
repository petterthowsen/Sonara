use crossbeam::channel::Sender;
use std::collections::HashMap;

use super::commands::{EngineState, EngineStatus};
use super::devices::clap_host::{ClapDeviceAdapter, SubprocessClapAdapter};
use super::devices::SfizzDevice;
use super::render_scratch::RenderScratch;
use super::types::*;

/// Peak level below which a channel is treated as silent and not routed.
const ROUTING_SILENCE_THRESHOLD: f32 = 0.0001;

/// Most routing passes per buffer, which bounds bus nesting depth.
const MAX_ROUTING_PASSES: usize = 10;

/// Convert a fader or send level in dB to linear gain (-60 dB and below is silence).
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

    /// Samples of gain smoothing that settle a fader to its target (the 5 ms smoothing constant
    /// is 240 samples at 48 kHz, so this leaves well under 1e-6 of the step).
    const GAIN_SETTLE_SAMPLES: usize = 4096;

    fn warm_gain(channel: &mut Channel) {
        for _ in 0..GAIN_SETTLE_SAMPLES {
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
        warm_gain(&mut master);

        let mut bus = Channel::new(2, "Bus".to_string(), buffer_size, sample_rate);
        bus.output_channel_id = Some(1);
        bus.volume_db = 0.0;
        bus.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut bus);

        let mut source = Channel::new(3, "Source".to_string(), buffer_size, sample_rate);
        source.output_channel_id = None;
        source.volume_db = 0.0;
        source.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut source);
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
        mix_and_output(&mut state, &mut output, 2, buffer_size, &status_tx);

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
        warm_gain(&mut master);

        let mut bus = Channel::new(2, "Bus".to_string(), buffer_size, sample_rate);
        bus.output_channel_id = Some(1);
        bus.volume_db = 0.0;
        bus.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut bus);

        let mut source = Channel::new(3, "Source".to_string(), buffer_size, sample_rate);
        source.output_channel_id = None;
        source.volume_db = -60.0;
        source.pan_mode = PanMode::StereoBalance;
        warm_gain(&mut source);
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
        mix_and_output(&mut state, &mut output, 2, buffer_size, &status_tx);

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

    /// Build master (0 dB) → bus (-6 dB) ← track (-6 dB, 0.5 input). Faders stay at their
    /// initial values, so gain smoothing has nothing to converge.
    fn track_bus_master_state(buffer_size: usize) -> EngineState {
        let sample_rate = 48_000.0;
        let mut state = EngineState::default();
        state.device_sample_rate = sample_rate;

        let mut master = Channel::new(1, "Master".to_string(), buffer_size, sample_rate);
        master.output_channel_id = Some(1000);
        master.pan_mode = PanMode::StereoBalance;

        let mut bus = Channel::new(2, "Bus".to_string(), buffer_size, sample_rate);
        bus.output_channel_id = Some(1);
        bus.pan_mode = PanMode::StereoBalance;

        let mut track = Channel::new(3, "Track".to_string(), buffer_size, sample_rate);
        track.output_channel_id = Some(2);
        track.pan_mode = PanMode::StereoBalance;
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.5);

        state.channels.insert(1, master);
        state.channels.insert(2, bus);
        state.channels.insert(3, track);
        state
    }

    #[test]
    fn track_routes_through_bus_to_master() {
        let buffer_size = 4;
        let mut state = track_bus_master_state(buffer_size);

        let (status_tx, _status_rx) = unbounded();
        let mut output = vec![0.0f32; buffer_size * 2];
        mix_and_output(&mut state, &mut output, 2, buffer_size, &status_tx);

        // Track fader in pass 2, then the bus fader while routing into the bus
        let expected = 0.5 * db_to_gain(-6.0) * db_to_gain(-6.0);
        assert!((state.channels[&2].buffer_left[0] - expected).abs() < 1e-5);
        assert!((state.channels[&1].buffer_left[0] - expected).abs() < 1e-5);
        assert!((output[0] - expected).abs() < 1e-5);
        assert!((output[1] - expected).abs() < 1e-5);
    }

    #[test]
    fn muted_track_is_not_routed() {
        let buffer_size = 4;
        let mut state = track_bus_master_state(buffer_size);
        state.channels.get_mut(&3).unwrap().mute = true;

        let (status_tx, _status_rx) = unbounded();
        let mut output = vec![1.0f32; buffer_size * 2];
        mix_and_output(&mut state, &mut output, 2, buffer_size, &status_tx);

        assert!(output.iter().all(|sample| sample.abs() < 1e-6));
    }
}

/// True if the channel is silenced by its own mute or by another channel's solo.
fn is_silenced(channel: &Channel, has_solo: bool) -> bool {
    channel.mute || (has_solo && !channel.solo)
}

/// True if any channel routes its output or a send to `id`.
fn is_route_target(channels: &HashMap<ChannelId, Channel>, id: ChannelId) -> bool {
    channels.values().any(|channel| {
        channel.output_channel_id == Some(id)
            || channel
                .send_channels
                .iter()
                .any(|send| send.target_channel_id == id)
    })
}

/// Largest absolute sample value in a buffer.
fn peak_level(buffer: &[f32]) -> f32 {
    buffer
        .iter()
        .fold(0.0, |peak, sample| peak.max(sample.abs()))
}

/// Send a channel's device events to Godot: sleep changes, plugin parameter changes, new SFZ
/// parameter lists and device data streams.
fn forward_device_events(
    channel: &mut Channel,
    sleep_changes: Vec<(usize, bool)>,
    status_tx: &Sender<EngineStatus>,
) {
    let channel_id = channel.id;

    for (device_position, is_sleeping) in sleep_changes {
        let _ = status_tx.send(EngineStatus::DeviceSleepStatus {
            channel_id,
            device_position,
            is_sleeping,
        });
    }

    for (device_position, device) in channel.devices.iter_mut().enumerate() {
        if let Some(clap_adapter) = device.as_any_mut().downcast_mut::<ClapDeviceAdapter>() {
            // In-process plugin: parameter changes from its GUI or modulation
            for (param_id, value) in clap_adapter.take_pending_param_changes() {
                let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                    channel_id,
                    device_position,
                    param_id,
                    value,
                });
            }
        } else if let Some(subprocess_adapter) =
            device.as_any_mut().downcast_mut::<SubprocessClapAdapter>()
        {
            // Subprocess plugin: unsolicited ParameterValueChanged messages
            if let Some(changes) = subprocess_adapter.poll_parameter_changes() {
                for (param_id, value) in changes {
                    let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                        channel_id,
                        device_position,
                        param_id,
                        value,
                    });
                }
            }
        } else if let Some(sfizz_device) = device.as_any_mut().downcast_mut::<SfizzDevice>() {
            // A new SFZ was loaded, so its parameter list changed
            if sfizz_device.take_parameters_changed() {
                let params = device.parameters();
                if !params.is_empty() {
                    let _ = status_tx.send(EngineStatus::PluginParameterCount {
                        channel_id,
                        device_position,
                        count: params.len(),
                    });
                    for param in params.iter() {
                        let _ = status_tx.send(EngineStatus::PluginParameterInfo {
                            channel_id,
                            device_position,
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

        // Device data streams (spectrum, oscilloscope, etc.)
        if let Some((data_type, data)) = device.poll_device_data() {
            let _ = status_tx.try_send(EngineStatus::DeviceData {
                channel_id,
                device_position,
                data_type,
                data,
            });
        }
    }
}

/// Mix channels and output to the audio device.
///
/// Passes: device pre-pass (non-bus channels), fader and pan, sends, hierarchical routing (buses
/// run their devices and pan there), master output. Uses only preallocated buffers.
pub fn mix_and_output(
    state: &mut EngineState,
    data: &mut [f32],
    channels: usize,
    frames: usize,
    status_tx: &Sender<EngineStatus>,
) {
    let EngineState {
        channels: channel_map,
        render_scratch,
        ..
    } = state;
    let RenderScratch {
        channel_ids,
        mix_ops,
        ..
    } = render_scratch;

    let has_solo = channel_map.values().any(|c| c.solo);
    channel_ids.clear();
    channel_ids.extend(channel_map.keys().copied());

    // Reset per-buffer mix state, find buses, and copy pre-fader audio for pre-fader sends.
    // NOTE: the copy is taken before device processing, as it always has been.
    for &id in channel_ids.iter() {
        let is_target = is_route_target(channel_map, id);
        let Some(channel) = channel_map.get_mut(&id) else {
            continue;
        };
        let mix = &mut channel.mix;
        mix.is_route_target = is_target;
        mix.pending_bus = false;
        mix.bus_destination = false;
        mix.has_send_input = false;
        mix.routed = id == 1; // Master never routes further
        mix.has_pre_fader_copy = frames > 0
            && channel
                .send_channels
                .iter()
                .any(|send| send.pre_fader && !send.muted);
        if mix.has_pre_fader_copy {
            mix.pre_fader_left[..frames].copy_from_slice(&channel.buffer_left[..frames]);
            mix.pre_fader_right[..frames].copy_from_slice(&channel.buffer_right[..frames]);
        }
    }

    // First pass: process device chains (instruments and effects) before the fader.
    // Buses are skipped here; they run in the routing pass after receiving audio.
    for channel in channel_map.values_mut() {
        if channel.mix.is_route_target {
            continue;
        }
        let sleep_changes = channel.process_device_chain(frames);
        forward_device_events(channel, sleep_changes, status_tx);
    }

    // Second pass: apply each channel's smoothed fader gain and pan to its own buffer, making it
    // "post-fader" for metering. Buses have no local audio yet; they pan in the routing pass.
    for channel in channel_map.values_mut() {
        if is_silenced(channel, has_solo) {
            channel.clear_buffers();
            continue;
        }

        let pan = channel.get_pan_coefficients();
        for i in 0..frames {
            let smoothed_gain = channel.get_smoothed_gain();
            let left_in = channel.buffer_left[i] * smoothed_gain;
            let right_in = channel.buffer_right[i] * smoothed_gain;

            // Apply 4-coefficient pan matrix
            channel.buffer_left[i] = left_in * pan.left_to_left + right_in * pan.right_to_left;
            channel.buffer_right[i] = left_in * pan.left_to_right + right_in * pan.right_to_right;
        }
    }

    // Third pass: accumulate sends into each target's send buffer, then mix them in so they are
    // processed like regular bus inputs
    if frames > 0 {
        for &source_id in channel_ids.iter() {
            let Some(source) = channel_map.get_mut(&source_id) else {
                continue;
            };
            if source.send_channels.is_empty() || is_silenced(source, has_solo) {
                continue;
            }

            // Move the source's buffers out (no allocation) so targets can be borrowed mutably
            let sends = std::mem::take(&mut source.send_channels);
            let left = std::mem::take(&mut source.buffer_left);
            let right = std::mem::take(&mut source.buffer_right);
            let pre_left = std::mem::take(&mut source.mix.pre_fader_left);
            let pre_right = std::mem::take(&mut source.mix.pre_fader_right);
            let has_pre_fader_copy = source.mix.has_pre_fader_copy;
            let pan = source.get_pan_coefficients();

            for send in &sends {
                let target_id = send.target_channel_id;
                if send.muted || target_id == 0 || target_id == source_id || target_id >= 1000 {
                    continue;
                }
                let send_gain = db_to_gain(send.amount_db);
                if send_gain <= 0.0 {
                    continue;
                }
                let Some(target) = channel_map.get_mut(&target_id) else {
                    continue;
                };

                let mix = &mut target.mix;
                if !mix.has_send_input {
                    mix.send_left[..frames].fill(0.0);
                    mix.send_right[..frames].fill(0.0);
                    mix.has_send_input = true;
                }

                if send.pre_fader {
                    // Pre-fader sends reapply the source's pan so stereo matches the source
                    if has_pre_fader_copy {
                        for i in 0..frames {
                            let left_in = pre_left[i];
                            let right_in = pre_right[i];
                            let panned_left =
                                left_in * pan.left_to_left + right_in * pan.right_to_left;
                            let panned_right =
                                left_in * pan.left_to_right + right_in * pan.right_to_right;
                            mix.send_left[i] += panned_left * send_gain;
                            mix.send_right[i] += panned_right * send_gain;
                        }
                    }
                } else {
                    for i in 0..frames {
                        mix.send_left[i] += left[i] * send_gain;
                        mix.send_right[i] += right[i] * send_gain;
                    }
                }

                mix.pending_bus = true;
            }

            if let Some(source) = channel_map.get_mut(&source_id) {
                source.send_channels = sends;
                source.buffer_left = left;
                source.buffer_right = right;
                source.mix.pre_fader_left = pre_left;
                source.mix.pre_fader_right = pre_right;
            }
        }

        // Send returns are scaled by the destination channel's fader
        for channel in channel_map.values_mut() {
            if !channel.mix.has_send_input || channel.mute {
                continue;
            }
            let dest_gain = channel.get_gain();
            for i in 0..frames {
                channel.buffer_left[i] += channel.mix.send_left[i] * dest_gain;
                channel.buffer_right[i] += channel.mix.send_right[i] * dest_gain;
            }
        }
    }

    // Fourth pass: hierarchical routing (Track → Bus → Master). Each pass routes channels into
    // their outputs; buses that received audio then run their devices and pan and route their
    // processed audio in the next pass.
    for routing_pass in 0..MAX_ROUTING_PASSES {
        mix_ops.clear();

        for &id in channel_ids.iter() {
            let Some(channel) = channel_map.get(&id) else {
                continue;
            };
            if channel.mix.routed {
                continue;
            }
            // Buses fed by sends must process their devices before routing onward
            if routing_pass == 0 && channel.mix.pending_bus {
                continue;
            }
            if is_silenced(channel, has_solo) {
                continue;
            }

            let peak = peak_level(&channel.buffer_left[..frames])
                .max(peak_level(&channel.buffer_right[..frames]));
            if peak < ROUTING_SILENCE_THRESHOLD {
                continue;
            }

            // Only mix into other channels (ID < 1000), not hardware outputs (ID >= 1000)
            if let Some(output_id) = channel.output_channel_id {
                if output_id != id && output_id < 1000 && channel_map.contains_key(&output_id) {
                    mix_ops.push((id, output_id));
                }
            }
        }

        // Snapshot each routed source before mixing, so a channel that is both a source and a
        // destination in this pass routes the audio it had when the pass started
        for &(source_id, output_id) in mix_ops.iter() {
            if let Some(source) = channel_map.get_mut(&source_id) {
                source.mix.routed = true;
                source.mix.route_left[..frames].copy_from_slice(&source.buffer_left[..frames]);
                source.mix.route_right[..frames].copy_from_slice(&source.buffer_right[..frames]);
            }
            if let Some(destination) = channel_map.get_mut(&output_id) {
                destination.mix.bus_destination = true;
            }
        }

        // Buses that received sends are processed in the first pass
        if routing_pass == 0 {
            for channel in channel_map.values_mut() {
                if channel.mix.pending_bus {
                    channel.mix.pending_bus = false;
                    channel.mix.bus_destination = true;
                }
            }
        }

        let has_bus_destinations = channel_map.values().any(|c| c.mix.bus_destination);
        if mix_ops.is_empty() && !has_bus_destinations {
            break;
        }

        // Mix routed audio into destinations with only the destination's fader gain; the
        // source's pan was applied in pass 2 and buses pan below
        for &(source_id, output_id) in mix_ops.iter() {
            let Some(source) = channel_map.get_mut(&source_id) else {
                continue;
            };
            let route_left = std::mem::take(&mut source.mix.route_left);
            let route_right = std::mem::take(&mut source.mix.route_right);

            if let Some(destination) = channel_map.get_mut(&output_id) {
                let dest_gain = destination.get_gain();
                for i in 0..frames {
                    destination.buffer_left[i] += route_left[i] * dest_gain;
                    destination.buffer_right[i] += route_right[i] * dest_gain;
                }
            }

            if let Some(source) = channel_map.get_mut(&source_id) {
                source.mix.route_left = route_left;
                source.mix.route_right = route_right;
            }
        }

        // Buses that received audio run their effect chain and pan the accumulated mix
        for channel in channel_map.values_mut() {
            if !channel.mix.bus_destination {
                continue;
            }
            channel.mix.bus_destination = false;
            if channel.mute {
                continue;
            }

            let sleep_changes = channel.process_device_chain(frames);
            forward_device_events(channel, sleep_changes, status_tx);

            let pan = channel.get_pan_coefficients();
            for i in 0..frames {
                let left_in = channel.buffer_left[i];
                let right_in = channel.buffer_right[i];
                channel.buffer_left[i] = left_in * pan.left_to_left + right_in * pan.right_to_left;
                channel.buffer_right[i] =
                    left_in * pan.left_to_right + right_in * pan.right_to_right;
            }

            // Let the bus route its processed audio in the next pass
            channel.mix.routed = false;
        }
    }

    // Output the master channel (ID 1) to the audio hardware
    // Master should route to an output device (ID >= 1000)
    // NOTE: Currently we only support outputting to the default device (ID 1000, the one running this stream)
    // In the future, we can support routing to other devices (ID 1001+) by managing multiple streams
    if let Some(master) = channel_map.get(&1) {
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
