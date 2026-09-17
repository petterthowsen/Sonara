use crossbeam::channel::Sender;
use std::collections::HashMap;

use super::commands::{EngineState, EngineStatus};
use super::devices::clap_host::{ClapDeviceAdapter, SubprocessClapAdapter};
use super::devices::{container, AudioDevice, DevicePath, SfizzDevice};
use super::render_scratch::{RenderScratch, SoloRole};
use super::types::*;

/// Master channel ID. Master never routes to another channel and is never silenced by solo.
const MASTER_CHANNEL_ID: ChannelId = 1;

/// Max hops when walking output chains so a routing cycle cannot spin forever.
const SOLO_WALK_LIMIT: usize = 64;

/// Convert a fader or send level in dB to linear gain (-60 dB and below is silence).
fn db_to_gain(db: f32) -> f32 {
    if db <= -60.0 {
        0.0
    } else {
        10.0_f32.powf(db / 20.0)
    }
}

/// True if this channel contributes no audio this buffer (muted or excluded by solo).
fn is_silenced(channel: &Channel) -> bool {
    channel.mix.solo_role == SoloRole::Silent
}

/// Walk `start_id`'s output chain and return true if `target_id` is on it (including itself).
fn output_reaches(
    channel_map: &HashMap<ChannelId, Channel>,
    mut id: ChannelId,
    target_id: ChannelId,
) -> bool {
    for _ in 0..SOLO_WALK_LIMIT {
        if id == target_id {
            return true;
        }
        let Some(channel) = channel_map.get(&id) else {
            return false;
        };
        let Some(next) = output_target(channel) else {
            return false;
        };
        if next == id {
            return false;
        }
        id = next;
    }
    false
}

/// True if this channel or anything it routes into is soloed.
fn output_reaches_soloed(channel_map: &HashMap<ChannelId, Channel>, mut id: ChannelId) -> bool {
    for _ in 0..SOLO_WALK_LIMIT {
        let Some(channel) = channel_map.get(&id) else {
            return false;
        };
        if channel.solo {
            return true;
        }
        let Some(next) = output_target(channel) else {
            return false;
        };
        if next == id {
            return false;
        }
        id = next;
    }
    false
}

/// True if an unmuted send from `source` reaches `target_id` (the send target or its output chain).
fn send_reaches(
    channel_map: &HashMap<ChannelId, Channel>,
    source: &Channel,
    target_id: ChannelId,
) -> bool {
    source.send_channels.iter().any(|send| {
        !send.muted
            && is_valid_route(channel_map, source.id, send.target_channel_id)
            && output_reaches(channel_map, send.target_channel_id, target_id)
    })
}

/// True if `source` has an unmuted send whose target is soloed or routes into a soloed bus.
fn send_reaches_soloed(channel_map: &HashMap<ChannelId, Channel>, source: &Channel) -> bool {
    source.send_channels.iter().any(|send| {
        !send.muted
            && is_valid_route(channel_map, source.id, send.target_channel_id)
            && output_reaches_soloed(channel_map, send.target_channel_id)
    })
}

/// True if a fully-audible (group or self-solo) source routes its output through `target_id`.
fn group_output_reaches(channel_map: &HashMap<ChannelId, Channel>, target_id: ChannelId) -> bool {
    channel_map.values().any(|source| {
        !source.mute
            && output_reaches_soloed(channel_map, source.id)
            && output_reaches(channel_map, source.id, target_id)
    })
}

/// True if a fully-audible source sends into `target_id` or a bus that routes there.
fn group_send_reaches(channel_map: &HashMap<ChannelId, Channel>, target_id: ChannelId) -> bool {
    channel_map.values().any(|source| {
        !source.mute
            && output_reaches_soloed(channel_map, source.id)
            && send_reaches(channel_map, source, target_id)
    })
}

/// Decide how this channel participates when solo is active.
///
/// Sources that route into a soloed bus stay fully audible (group solo). Sources that only send
/// to a soloed bus keep those sends and mute their dry output. Buses stay open when a soloed
/// source reaches them by route or send, so nested buses and FX returns still reach master.
fn solo_role(channel_map: &HashMap<ChannelId, Channel>, id: ChannelId, has_solo: bool) -> SoloRole {
    let Some(channel) = channel_map.get(&id) else {
        return SoloRole::Silent;
    };
    if channel.mute {
        return SoloRole::Silent;
    }
    if !has_solo {
        return SoloRole::Full;
    }
    if channel.mix.is_route_target {
        if group_output_reaches(channel_map, id) || group_send_reaches(channel_map, id) {
            SoloRole::Full
        } else {
            SoloRole::Silent
        }
    } else if output_reaches_soloed(channel_map, id) {
        SoloRole::Full
    } else if send_reaches_soloed(channel_map, channel) {
        SoloRole::SendOnly
    } else {
        SoloRole::Silent
    }
}

/// Store each channel's solo role for this buffer. Must run after `count_route_inputs`.
fn assign_solo_roles(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    has_solo: bool,
) {
    for &id in channel_ids {
        let role = solo_role(channel_map, id, has_solo);
        if let Some(channel) = channel_map.get_mut(&id) {
            channel.mix.solo_role = role;
        }
    }
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
) {
    let Some(source) = channel_map.get_mut(&source_id) else {
        return;
    };
    let role = source.mix.solo_role;
    let route_output = frames > 0 && role == SoloRole::Full;
    let allow_sends = frames > 0 && role != SoloRole::Silent;
    let send_only = role == SoloRole::SendOnly;
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
            if route_output && !target.mix.done {
                let gain = target.get_gain();
                add_scaled(target, &left, &right, frames, gain);
            }
        }
    }

    for send in &sends {
        if !is_valid_route(channel_map, source_id, send.target_channel_id) {
            continue;
        }
        let send_allowed = allow_sends
            && !send.muted
            && (!send_only || output_reaches_soloed(channel_map, send.target_channel_id));
        let Some(target) = channel_map.get_mut(&send.target_channel_id) else {
            continue;
        };
        target.mix.pending_inputs = target.mix.pending_inputs.saturating_sub(1);
        if !send_allowed || target.mix.done {
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
    status_tx: &Sender<EngineStatus>,
) {
    let Some(channel) = channel_map.get_mut(&id) else {
        return;
    };
    channel.mix.done = true;

    if channel.mix.is_route_target {
        if !channel.mute {
            let sleep_changes = if channel.mix.has_aux_source {
                channel.process_device_chain_from(1, frames)
            } else {
                channel.process_device_chain(frames)
            };
            forward_device_events(channel, sleep_changes, status_tx);
            apply_pan(channel, frames);
        }
        if is_silenced(channel) {
            channel.clear_buffers();
        }
    }

    route_channel(channel_map, id, frames);
}

/// Mark channels whose first device writes extra buses into nested child channels.
fn mark_aux_sources(channel_map: &mut HashMap<ChannelId, Channel>, channel_ids: &[ChannelId]) {
    for &id in channel_ids {
        if let Some(channel) = channel_map.get_mut(&id) {
            channel.mix.has_aux_source = channel.extra_out_targets.iter().any(|&t| t > 0);
        }
    }
}

/// Process aux-source devices and copy extra stereo buses into mapped child channels.
fn process_aux_sources(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    frames: usize,
    status_tx: &Sender<EngineStatus>,
) {
    for &id in channel_ids {
        let mut did_process = false;
        {
            let Some(channel) = channel_map.get_mut(&id) else {
                continue;
            };
            if !channel.mix.has_aux_source {
                continue;
            }
            let sleep_changes = channel.process_aux_source(frames);
            forward_device_events(channel, sleep_changes, status_tx);
            did_process = true;
        }
        if did_process {
            copy_extra_outs_to_targets(channel_map, id, frames);
        }
    }
}

/// Deinterleave extra-out buses from `source_id` into mapped child channel buffers.
fn copy_extra_outs_to_targets(
    channel_map: &mut HashMap<ChannelId, Channel>,
    source_id: ChannelId,
    frames: usize,
) {
    let Some(source) = channel_map.get_mut(&source_id) else {
        return;
    };
    let targets = std::mem::take(&mut source.extra_out_targets);
    let extras = std::mem::take(&mut source.extra_out_buffers);
    let interleaved = frames.saturating_mul(2);

    for (i, &target_id) in targets.iter().enumerate() {
        if target_id == 0 || target_id == source_id {
            continue;
        }
        let Some(extra) = extras.get(i) else {
            continue;
        };
        let Some(target) = channel_map.get_mut(&target_id) else {
            continue;
        };
        let n = interleaved.min(extra.len());
        deinterleave_extra(extra, target, n / 2);
    }

    if let Some(source) = channel_map.get_mut(&source_id) {
        source.extra_out_targets = targets;
        source.extra_out_buffers = extras;
    }
}

/// Copy interleaved stereo `extra` into `target`'s L/R buffers (overwriting, not mixing).
fn deinterleave_extra(extra: &[f32], target: &mut Channel, frames: usize) {
    let frames = frames
        .min(target.buffer_left.len())
        .min(target.buffer_right.len());
    for i in 0..frames {
        let idx = i * 2;
        if idx + 1 >= extra.len() {
            break;
        }
        target.buffer_left[i] = extra[idx];
        target.buffer_right[i] = extra[idx + 1];
    }
}

/// Send a channel's device events to Godot: sleep changes, plugin parameter changes, new SFZ
/// parameter lists and device data streams.
fn forward_device_events(
    channel: &mut Channel,
    sleep_changes: Vec<(DevicePath, bool)>,
    status_tx: &Sender<EngineStatus>,
) {
    let channel_id = channel.id;

    for (device_path, is_sleeping) in sleep_changes {
        let _ = status_tx.send(EngineStatus::DeviceSleepStatus {
            channel_id,
            device_path,
            is_sleeping,
        });
    }

    container::visit_devices_mut(&mut channel.devices, &mut |device_path, device| {
        if let Some(clap_adapter) = device.as_any_mut().downcast_mut::<ClapDeviceAdapter>() {
            for (param_id, value) in clap_adapter.take_pending_param_changes() {
                let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                    channel_id,
                    device_path: device_path.clone(),
                    param_id,
                    value,
                });
            }
        } else if let Some(subprocess_adapter) =
            device.as_any_mut().downcast_mut::<SubprocessClapAdapter>()
        {
            if let Some(changes) = subprocess_adapter.poll_parameter_changes() {
                for (param_id, value) in changes {
                    let _ = status_tx.send(EngineStatus::PluginParameterValueChanged {
                        channel_id,
                        device_path: device_path.clone(),
                        param_id,
                        value,
                    });
                }
            }
        } else if let Some(sfizz_device) = device.as_any_mut().downcast_mut::<SfizzDevice>() {
            if sfizz_device.take_parameters_changed() {
                let params = sfizz_device.parameters();
                if !params.is_empty() {
                    let _ = status_tx.send(EngineStatus::PluginParameterCount {
                        channel_id,
                        device_path: device_path.clone(),
                        count: params.len(),
                    });
                    for param in params.iter() {
                        let _ = status_tx.send(EngineStatus::PluginParameterInfo {
                            channel_id,
                            device_path: device_path.clone(),
                            param_id: param.id,
                            name: param.name.clone(),
                            min: param.min,
                            max: param.max,
                            default: param.default,
                            group: sfizz_device.parameter_group(param.id).to_string(),
                            param_type: param.param_type,
                            is_hidden: false,
                            is_read_only: false,
                            is_bypass: false,
                            module: String::new(),
                            enum_values: param.enum_values.clone(),
                        });
                    }
                }
            }
        }

        if let Some((data_type, data)) = device.poll_device_data() {
            let _ = status_tx.try_send(EngineStatus::DeviceData {
                channel_id,
                device_path: device_path.clone(),
                data_type,
                data,
            });
        }
    });
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
    assign_solo_roles(channel_map, channel_ids, has_solo);
    mark_aux_sources(channel_map, channel_ids);

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

    // Aux source pass: generate extra device buses into child channel buffers before
    // those children run their own device chains. Route-target parents skip the
    // normal pre-pass so remaining FX wait until children mix back in.
    process_aux_sources(channel_map, channel_ids, frames, status_tx);

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
    // Silent channels are cleared. Send-only sources keep their buffer for sends to a soloed bus.
    for channel in channel_map.values_mut() {
        if is_silenced(channel) {
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
                finish_channel(channel_map, id, frames, status_tx);
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
            finish_channel(channel_map, id, frames, status_tx);
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
    fn missing_master_is_created_and_receives_routed_audio() {
        let mut source = test_channel(2, Some(1), 0.0);
        source.buffer_left.fill(0.5);
        source.buffer_right.fill(0.5);
        let mut state = state_with(vec![source]);
        state.ensure_master_channel(BUFFER_SIZE);
        let output = mix(&mut state);

        assert!(state.channels.contains_key(&1));
        assert_eq!(state.channels[&1].output_channel_id, Some(1000));
        assert!(
            state.channels[&1].buffer_left[0].abs() > 0.2,
            "master should receive routed audio, got {}",
            state.channels[&1].buffer_left[0]
        );
        assert!(output[0].abs() > 0.2);
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
    fn soloed_group_bus_keeps_feeders_and_mutes_others() {
        let mut other = test_channel(4, Some(1), 0.0);
        other.buffer_left.fill(0.9);
        other.buffer_right.fill(0.9);
        let mut state = track_bus_master_state();
        state.channels.insert(4, other);
        state.channels.get_mut(&2).unwrap().solo = true;
        let output = mix(&mut state);

        let expected = 0.5 * db_to_gain(-6.0) * db_to_gain(-6.0);
        assert!(state.channels[&4].buffer_left[0].abs() < 1e-6);
        assert!((output[0] - expected).abs() < 1e-5);
    }

    #[test]
    fn soloed_group_bus_includes_nested_feeders() {
        let mut track = test_channel(3, Some(4), -6.0);
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.5);
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(1), -6.0),
            test_channel(4, Some(2), -6.0),
            track,
        ]);
        state.channels.get_mut(&2).unwrap().solo = true;
        let output = mix(&mut state);

        let expected = 0.5 * db_to_gain(-6.0) * db_to_gain(-6.0) * db_to_gain(-6.0);
        assert!((output[0] - expected).abs() < 1e-5);
    }

    #[test]
    fn soloed_send_bus_mutes_dry_and_keeps_send() {
        let mut source = test_channel(3, Some(1), 0.0);
        source.buffer_left.fill(0.5);
        source.buffer_right.fill(0.5);
        source.send_channels.push(Send {
            target_channel_id: 2,
            amount_db: 0.0,
            pre_fader: false,
            muted: false,
        });
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(1), 0.0),
            source,
        ]);
        state.channels.get_mut(&2).unwrap().solo = true;
        let output = mix(&mut state);

        assert!((state.channels[&2].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((output[0] - 0.5).abs() < 1e-4);
    }

    #[test]
    fn soloed_send_bus_drops_unrelated_sends() {
        let mut source = test_channel(3, Some(1), 0.0);
        source.buffer_left.fill(0.5);
        source.buffer_right.fill(0.5);
        source.send_channels.push(Send {
            target_channel_id: 2,
            amount_db: 0.0,
            pre_fader: false,
            muted: false,
        });
        source.send_channels.push(Send {
            target_channel_id: 4,
            amount_db: 0.0,
            pre_fader: false,
            muted: false,
        });
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(1), 0.0),
            source,
            test_channel(4, Some(1), 0.0),
        ]);
        state.channels.get_mut(&2).unwrap().solo = true;
        mix(&mut state);

        assert!((state.channels[&2].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!(state.channels[&4].buffer_left[0].abs() < 1e-6);
    }

    #[test]
    fn soloed_group_bus_keeps_member_sends() {
        let mut track = test_channel(3, Some(2), 0.0);
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.5);
        track.send_channels.push(Send {
            target_channel_id: 4,
            amount_db: 0.0,
            pre_fader: false,
            muted: false,
        });
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(1), 0.0),
            track,
            test_channel(4, Some(1), 0.0),
        ]);
        state.channels.get_mut(&2).unwrap().solo = true;
        let output = mix(&mut state);

        assert!((state.channels[&2].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((state.channels[&4].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((output[0] - 1.0).abs() < 1e-4);
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

    /// Device that writes 0.4 to the main out and 0.8 to extra bus 0.
    struct TestAuxDevice;

    impl AudioDevice for TestAuxDevice {
        fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            let n = (sample_count * 2).min(outputs.len());
            outputs[..n].fill(0.4);
        }
        fn extra_output_bus_count(&self) -> usize {
            1
        }
        fn process_block_with_extra(
            &mut self,
            inputs: &[f32],
            outputs: &mut [f32],
            extra_outs: &mut [Vec<f32>],
            sample_count: usize,
        ) {
            self.process_block(inputs, outputs, sample_count);
            if let Some(extra) = extra_outs.first_mut() {
                let n = (sample_count * 2).min(extra.len());
                extra[..n].fill(0.8);
            }
        }
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.aux"
        }
        fn device_name(&self) -> &str {
            "Aux"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Instrument
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

    #[test]
    fn extra_out_feeds_child_before_child_devices() {
        let mut parent = test_channel(2, Some(1), 0.0);
        parent.devices.push(Box::new(TestAuxDevice));
        parent.set_aux_out(0, 3);
        let mut child = test_channel(3, Some(2), 0.0);
        let child_fx = add_test_device(&mut child, 0.1);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), parent, child]);
        mix(&mut state);

        assert_eq!(child_fx.load(Ordering::Relaxed), 1);
        // Child fader 0 dB: aux 0.8 + fx 0.1, then routes into parent (0 dB).
        assert!((state.channels[&3].buffer_left[0] - 0.9).abs() < 1e-4);
        assert!(
            state.channels[&2].buffer_left[0] > 0.8,
            "parent should mix child extra-out, got {}",
            state.channels[&2].buffer_left[0]
        );
    }
}
