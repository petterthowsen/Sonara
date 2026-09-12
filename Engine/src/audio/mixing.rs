use crossbeam::channel::Sender;
use std::collections::HashMap;

use super::commands::{EngineState, EngineStatus};
use super::devices::clap_host::{ClapDeviceAdapter, SubprocessClapAdapter};
use super::devices::{AudioDevice, SfizzDevice};
use super::render_scratch::RenderScratch;
use super::types::*;

/// Master channel ID. Master never routes to another channel and is never silenced by solo.
const MASTER_CHANNEL_ID: ChannelId = 1;

/// Convert a fader or send level in dB to linear gain (-60 dB and below is silence).
fn db_to_gain(db: f32) -> f32 {
    if db <= -60.0 {
        0.0
    } else {
        10.0_f32.powf(db / 20.0)
    }
}

/// True if the channel is silenced by its own mute or by another channel's solo.
///
/// Route targets (buses and master) stay audible when something else is soloed so
/// instrument/audio sources still reach the mix through their output and sends.
fn is_silenced(channel: &Channel, has_solo: bool) -> bool {
    channel.mute || (has_solo && !channel.solo && !channel.mix.is_route_target)
}

/// The channel this channel routes its output into, if any (master never routes onward).
fn output_target(channel: &Channel) -> Option<ChannelId> {
    if channel.id == MASTER_CHANNEL_ID {
        None
    } else {
        channel.output_channel_id
    }
}

/// True if `source_id` can mix into `target_id`: another existing channel, not a hardware output.
fn is_valid_route(
    channels: &HashMap<ChannelId, Channel>,
    source_id: ChannelId,
    target_id: ChannelId,
) -> bool {
    target_id != 0
        && target_id != source_id
        && target_id < 1000
        && channels.contains_key(&target_id)
}

/// Add `gain`-scaled audio into a channel's buffers.
fn add_scaled(target: &mut Channel, left: &[f32], right: &[f32], frames: usize, gain: f32) {
    for i in 0..frames {
        target.buffer_left[i] += left[i] * gain;
        target.buffer_right[i] += right[i] * gain;
    }
}

/// Apply the channel's pan matrix to its own buffers.
fn apply_pan(channel: &mut Channel, frames: usize) {
    let pan = channel.get_pan_coefficients();
    for i in 0..frames {
        let left_in = channel.buffer_left[i];
        let right_in = channel.buffer_right[i];
        channel.buffer_left[i] = left_in * pan.left_to_left + right_in * pan.right_to_left;
        channel.buffer_right[i] = left_in * pan.left_to_right + right_in * pan.right_to_right;
    }
}

/// Reset per-buffer routing state, count each channel's route and send inputs, and mark route
/// targets. Master is always a target so its devices run after everything has mixed in.
fn count_route_inputs(channel_map: &mut HashMap<ChannelId, Channel>, channel_ids: &[ChannelId]) {
    for channel in channel_map.values_mut() {
        channel.mix.pending_inputs = 0;
        channel.mix.done = false;
    }

    for &id in channel_ids {
        let Some(source) = channel_map.get_mut(&id) else {
            continue;
        };
        // Move the sends out (no allocation) so targets can be borrowed mutably
        let sends = std::mem::take(&mut source.send_channels);
        let output = output_target(source);

        let targets = output
            .into_iter()
            .chain(sends.iter().map(|send| send.target_channel_id));
        for target_id in targets {
            if !is_valid_route(channel_map, id, target_id) {
                continue;
            }
            if let Some(target) = channel_map.get_mut(&target_id) {
                target.mix.pending_inputs += 1;
            }
        }

        if let Some(source) = channel_map.get_mut(&id) {
            source.send_channels = sends;
        }
    }

    for channel in channel_map.values_mut() {
        channel.mix.is_route_target =
            channel.id == MASTER_CHANNEL_ID || channel.mix.pending_inputs > 0;
    }
}

/// Mix a finished channel into its output and send targets and release their pending inputs.
///
/// Routed audio is scaled by the target's fader; the source's pan was already applied.
/// Pre-fader sends reapply the source's pan so stereo matches the source. Targets that already
/// finished (only possible in a routing cycle) receive nothing.
fn route_channel(
    channel_map: &mut HashMap<ChannelId, Channel>,
    source_id: ChannelId,
    frames: usize,
    has_solo: bool,
) {
    let Some(source) = channel_map.get_mut(&source_id) else {
        return;
    };
    let audible = frames > 0 && !is_silenced(source, has_solo);
    let output = output_target(source);
    let has_pre_fader_copy = source.mix.has_pre_fader_copy;
    let pan = source.get_pan_coefficients();

    // Move the source's buffers out (no allocation) so targets can be borrowed mutably
    let sends = std::mem::take(&mut source.send_channels);
    let left = std::mem::take(&mut source.buffer_left);
    let right = std::mem::take(&mut source.buffer_right);
    let pre_left = std::mem::take(&mut source.mix.pre_fader_left);
    let pre_right = std::mem::take(&mut source.mix.pre_fader_right);

    if let Some(target_id) = output.filter(|&id| is_valid_route(channel_map, source_id, id)) {
        if let Some(target) = channel_map.get_mut(&target_id) {
            target.mix.pending_inputs = target.mix.pending_inputs.saturating_sub(1);
            if audible && !target.mix.done {
                let gain = target.get_gain();
                add_scaled(target, &left, &right, frames, gain);
            }
        }
    }

    for send in &sends {
        if !is_valid_route(channel_map, source_id, send.target_channel_id) {
            continue;
        }
        let Some(target) = channel_map.get_mut(&send.target_channel_id) else {
            continue;
        };
        target.mix.pending_inputs = target.mix.pending_inputs.saturating_sub(1);
        if !audible || send.muted || target.mix.done {
            continue;
        }
        let gain = db_to_gain(send.amount_db) * target.get_gain();
        if gain <= 0.0 {
            continue;
        }

        if !send.pre_fader {
            add_scaled(target, &left, &right, frames, gain);
        } else if has_pre_fader_copy {
            for i in 0..frames {
                let left_in = pre_left[i];
                let right_in = pre_right[i];
                target.buffer_left[i] +=
                    (left_in * pan.left_to_left + right_in * pan.right_to_left) * gain;
                target.buffer_right[i] +=
                    (left_in * pan.left_to_right + right_in * pan.right_to_right) * gain;
            }
        }
    }

    if let Some(source) = channel_map.get_mut(&source_id) {
        source.send_channels = sends;
        source.buffer_left = left;
        source.buffer_right = right;
        source.mix.pre_fader_left = pre_left;
        source.mix.pre_fader_right = pre_right;
    }
}

/// Finish a channel once all its inputs have mixed in, then route it onward.
///
/// Route targets run their devices even without input, so reverb and delay tails keep ringing
/// (device sleep keeps idle chains cheap), then apply their pan. Silenced targets are cleared.
fn finish_channel(
    channel_map: &mut HashMap<ChannelId, Channel>,
    id: ChannelId,
    frames: usize,
    has_solo: bool,
    status_tx: &Sender<EngineStatus>,
) {
    let Some(channel) = channel_map.get_mut(&id) else {
        return;
    };
    channel.mix.done = true;

    if channel.mix.is_route_target {
        if !channel.mute {
            let sleep_changes = channel.process_device_chain(frames);
            forward_device_events(channel, sleep_changes, status_tx);
            apply_pan(channel, frames);
        }
        if is_silenced(channel, has_solo) {
            channel.clear_buffers();
        }
    }

    route_channel(channel_map, id, frames, has_solo);
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
                let params = sfizz_device.parameters();
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
                            group: sfizz_device.parameter_group(param.id).to_string(),
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
/// Passes: device pre-pass (channels nothing routes into), fader and pan, routing in dependency
/// order (route targets run their devices and pan once, after all their inputs), master output.
/// Uses only preallocated buffers.
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
    let RenderScratch { channel_ids, .. } = render_scratch;

    let has_solo = channel_map.values().any(|c| c.solo);
    channel_ids.clear();
    channel_ids.extend(channel_map.keys().copied());

    count_route_inputs(channel_map, channel_ids);

    // Copy pre-fader audio for pre-fader sends.
    // NOTE: the copy is taken before device processing, as it always has been.
    for channel in channel_map.values_mut() {
        let mix = &mut channel.mix;
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
    // Route targets are skipped; they run in the routing pass after their inputs mix in.
    for channel in channel_map.values_mut() {
        if channel.mix.is_route_target {
            continue;
        }
        let sleep_changes = channel.process_device_chain(frames);
        forward_device_events(channel, sleep_changes, status_tx);
    }

    // Second pass: apply each channel's smoothed fader gain and pan to its own buffer, making it
    // "post-fader" for metering. Buses have no local audio yet; they pan in the routing pass.
    // Solo only silences source channels; buses stay open so routed audio still reaches master.
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

    // Third pass: routing in dependency order (Track → Bus → Master). A channel finishes once
    // every route and send into it has mixed in, so each channel processes exactly once.
    let mut remaining = channel_ids.len();
    while remaining > 0 {
        let mut progressed = false;
        for &id in channel_ids.iter() {
            let ready = channel_map
                .get(&id)
                .is_some_and(|c| !c.mix.done && c.mix.pending_inputs == 0);
            if ready {
                finish_channel(channel_map, id, frames, has_solo, status_tx);
                remaining -= 1;
                progressed = true;
            }
        }

        if !progressed {
            // Routing cycle: break it at the first unfinished channel
            let unfinished = channel_ids
                .iter()
                .copied()
                .find(|id| channel_map.get(id).is_some_and(|c| !c.mix.done));
            let Some(id) = unfinished else {
                break;
            };
            finish_channel(channel_map, id, frames, has_solo, status_tx);
            remaining -= 1;
        }
    }

    // Output the master channel (ID 1) to the audio hardware
    // Master should route to an output device (ID >= 1000)
    // NOTE: Currently we only support outputting to the default device (ID 1000, the one running this stream)
    // In the future, we can support routing to other devices (ID 1001+) by managing multiple streams
    if let Some(master) = channel_map.get(&MASTER_CHANNEL_ID) {
        // Check if master routes to a device (ID >= 1000)
        if let Some(output_device_id) = master.output_channel_id {
            if output_device_id >= 1000 {
                // Master's fader is applied when other channels mix into it, so its buffer is
                // output directly without additional gain
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
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::commands::EngineState;
    use crate::audio::devices::{
        AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
    };
    use crate::audio::types::{Channel, PanMode, Send};
    use crossbeam::channel::unbounded;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    const SAMPLE_RATE: f32 = 48_000.0;
    const BUFFER_SIZE: usize = 4;

    /// Samples of gain smoothing that settle a fader to its target (the 5 ms smoothing constant
    /// is 240 samples at 48 kHz, so this leaves well under 1e-6 of the step).
    const GAIN_SETTLE_SAMPLES: usize = 4096;

    /// Effect that adds a constant level to its input and counts how often it runs.
    struct TestDevice {
        level: f32,
        calls: Arc<AtomicUsize>,
    }

    impl AudioDevice for TestDevice {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            self.calls.fetch_add(1, Ordering::Relaxed);
            for i in 0..sample_count * 2 {
                outputs[i] = inputs[i] + self.level;
            }
        }
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.device"
        }
        fn device_name(&self) -> &str {
            "Test Device"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Effect
        }
        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    /// Add a `TestDevice` to a channel and return its call counter.
    fn add_test_device(channel: &mut Channel, level: f32) -> Arc<AtomicUsize> {
        let calls = Arc::new(AtomicUsize::new(0));
        channel.devices.push(Box::new(TestDevice {
            level,
            calls: calls.clone(),
        }));
        calls
    }

    /// Channel with balance pan and a settled fader.
    fn test_channel(id: ChannelId, output: Option<ChannelId>, volume_db: f32) -> Channel {
        let mut channel = Channel::new(id, format!("Channel {id}"), BUFFER_SIZE, SAMPLE_RATE);
        channel.output_channel_id = output;
        channel.volume_db = volume_db;
        channel.pan_mode = PanMode::StereoBalance;
        for _ in 0..GAIN_SETTLE_SAMPLES {
            let _ = channel.get_smoothed_gain();
        }
        channel
    }

    /// Engine state holding the given channels.
    fn state_with(channels: Vec<Channel>) -> EngineState {
        let mut state = EngineState::default();
        state.device_sample_rate = SAMPLE_RATE;
        for channel in channels {
            state.channels.insert(channel.id, channel);
        }
        state
    }

    /// Mix one buffer and return the interleaved stereo output.
    fn mix(state: &mut EngineState) -> Vec<f32> {
        let (status_tx, _status_rx) = unbounded();
        let mut output = vec![0.0f32; BUFFER_SIZE * 2];
        mix_and_output(state, &mut output, 2, BUFFER_SIZE, &status_tx);
        output
    }

    /// Master (0 dB) and a bus (0 dB) fed by a 0.5 source with its only output being a send.
    fn send_state(source_db: f32, pre_fader: bool) -> EngineState {
        let mut source = test_channel(3, None, source_db);
        source.buffer_left.fill(0.5);
        source.buffer_right.fill(0.5);
        source.send_channels.push(Send {
            target_channel_id: 2,
            amount_db: 0.0,
            pre_fader,
            muted: false,
        });
        state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(1), 0.0),
            source,
        ])
    }

    /// Master (0 dB) → bus (-6 dB) ← track (-6 dB, 0.5 input).
    fn track_bus_master_state() -> EngineState {
        let mut track = test_channel(3, Some(2), -6.0);
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.5);
        state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(1), -6.0),
            track,
        ])
    }

    #[test]
    fn post_fader_send_routes_signal_to_bus() {
        let mut state = send_state(0.0, false);
        let output = mix(&mut state);

        assert!((state.channels[&2].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((state.channels[&2].buffer_right[0] - 0.5).abs() < 1e-4);
        assert!((state.channels[&1].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((output[0] - 0.5).abs() < 1e-4);
        assert!((output[1] - 0.5).abs() < 1e-4);
    }

    #[test]
    fn pre_fader_send_bypasses_channel_fader() {
        let mut state = send_state(-60.0, true);
        let output = mix(&mut state);

        assert!((state.channels[&2].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((state.channels[&1].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!(state.channels[&3].buffer_left[0].abs() < 1e-3);
        assert!((output[0] - 0.5).abs() < 1e-4);
        assert!((output[1] - 0.5).abs() < 1e-4);
    }

    #[test]
    fn track_routes_through_bus_to_master() {
        let mut state = track_bus_master_state();
        let output = mix(&mut state);

        // Track fader in pass 2, then the bus fader while routing into the bus
        let expected = 0.5 * db_to_gain(-6.0) * db_to_gain(-6.0);
        assert!((state.channels[&2].buffer_left[0] - expected).abs() < 1e-5);
        assert!((state.channels[&1].buffer_left[0] - expected).abs() < 1e-5);
        assert!((output[0] - expected).abs() < 1e-5);
        assert!((output[1] - expected).abs() < 1e-5);
    }

    #[test]
    fn soloed_track_still_routes_through_unsoloed_bus() {
        let mut state = track_bus_master_state();
        state.channels.get_mut(&3).unwrap().solo = true;
        let output = mix(&mut state);

        let expected = 0.5 * db_to_gain(-6.0) * db_to_gain(-6.0);
        assert!((state.channels[&2].buffer_left[0] - expected).abs() < 1e-5);
        assert!((state.channels[&1].buffer_left[0] - expected).abs() < 1e-5);
        assert!((output[0] - expected).abs() < 1e-5);
        assert!((output[1] - expected).abs() < 1e-5);
    }

    #[test]
    fn soloed_track_silences_other_sources_not_buses() {
        let mut other = test_channel(4, Some(1), 0.0);
        other.buffer_left.fill(0.9);
        other.buffer_right.fill(0.9);
        let mut state = track_bus_master_state();
        state.channels.insert(4, other);
        state.channels.get_mut(&3).unwrap().solo = true;
        let output = mix(&mut state);

        let expected = 0.5 * db_to_gain(-6.0) * db_to_gain(-6.0);
        assert!(state.channels[&4].buffer_left[0].abs() < 1e-6);
        assert!((output[0] - expected).abs() < 1e-5);
    }

    #[test]
    fn muted_track_is_not_routed() {
        let mut state = track_bus_master_state();
        state.channels.get_mut(&3).unwrap().mute = true;
        let output = mix(&mut state);

        assert!(output.iter().all(|sample| sample.abs() < 1e-6));
    }

    #[test]
    fn routed_bus_devices_run_without_input() {
        // A silent track still routed into the bus: its reverb tail must keep ringing
        let mut state = track_bus_master_state();
        state.channels.get_mut(&3).unwrap().clear_buffers();
        let calls = add_test_device(state.channels.get_mut(&2).unwrap(), 0.25);
        let output = mix(&mut state);

        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert!((output[0] - 0.25).abs() < 1e-5);
        assert!((output[1] - 0.25).abs() < 1e-5);
    }

    #[test]
    fn bus_fed_at_two_depths_processes_once() {
        // Track 3 → bus 4 → bus 2 → master, and track 5 → bus 2 directly
        let mut deep_track = test_channel(3, Some(4), -6.0);
        deep_track.buffer_left.fill(0.5);
        deep_track.buffer_right.fill(0.5);
        let mut direct_track = test_channel(5, Some(2), -6.0);
        direct_track.buffer_left.fill(0.5);
        direct_track.buffer_right.fill(0.5);
        let mut bus = test_channel(2, Some(1), -6.0);
        let calls = add_test_device(&mut bus, 0.0);

        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            bus,
            deep_track,
            test_channel(4, Some(2), -6.0),
            direct_track,
        ]);
        let output = mix(&mut state);

        let gain = db_to_gain(-6.0);
        let expected = 0.5 * gain * gain * gain + 0.5 * gain * gain;
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert!((output[0] - expected).abs() < 1e-5);
    }

    #[test]
    fn routing_cycle_still_finishes() {
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(4), 0.0),
            test_channel(4, Some(2), 0.0),
        ]);
        let calls = add_test_device(state.channels.get_mut(&2).unwrap(), 0.0);
        mix(&mut state);

        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert!(state.channels.values().all(|c| c.mix.done));
    }
}
