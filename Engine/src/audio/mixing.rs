use crossbeam::channel::Sender;
use std::collections::{HashMap, VecDeque};

use super::commands::{EngineState, EngineStatus};
use super::devices::clap_host::ClapDeviceAdapter;
use super::devices::container::{self, ChainStep};
use super::devices::AudioDevice;
use super::render_scratch::{RenderScratch, SoloRole};
use super::rt_debug;
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

/// True if `source` has a route or unmuted send into a channel for which `pred` holds.
fn any_output(
    channel_map: &HashMap<ChannelId, Channel>,
    source: &Channel,
    pred: impl Fn(&Channel) -> bool,
) -> bool {
    let target_holds = |target_id: ChannelId| {
        is_valid_route(channel_map, source.id, target_id)
            && channel_map.get(&target_id).is_some_and(&pred)
    };
    output_target(source).is_some_and(|id| target_holds(id))
        || source
            .send_channels
            .iter()
            .any(|send| !send.muted && target_holds(send.target_channel_id))
}

/// Mark the unmuted targets of `source`'s route and unmuted sends as carrying soloed audio.
/// Returns true if any target changed.
fn spread_solo_up(channel_map: &mut HashMap<ChannelId, Channel>, source_id: ChannelId) -> bool {
    let Some(source) = channel_map.get_mut(&source_id) else {
        return false;
    };
    // Move the sends out (no allocation) so targets can be borrowed mutably
    let sends = std::mem::take(&mut source.send_channels);
    let output = output_target(source);
    let targets = output.into_iter().chain(
        sends
            .iter()
            .filter(|send| !send.muted)
            .map(|send| send.target_channel_id),
    );
    let mut changed = false;
    for target_id in targets {
        if !is_valid_route(channel_map, source_id, target_id) {
            continue;
        }
        if let Some(target) = channel_map.get_mut(&target_id) {
            if !target.mute && !target.mix.solo_up {
                target.mix.solo_up = true;
                changed = true;
            }
        }
    }
    if let Some(source) = channel_map.get_mut(&source_id) {
        source.send_channels = sends;
    }
    changed
}

/// Set each channel's solo flags and role for this buffer.
///
/// A route or send stays in the mix when its source carries soloed audio (`solo_up`) or its
/// target leads to a soloed channel (`solo_down`). So soloing a bus keeps what feeds it, even
/// through another bus's send, and soloing a channel keeps everything downstream of it.
/// Both flags spread one hop per sweep until nothing changes; no allocation.
fn assign_solo_roles(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    has_solo: bool,
) {
    for &id in channel_ids {
        let up = has_solo
            && channel_map
                .get(&id)
                .is_some_and(|c| !c.mute && output_reaches_soloed(channel_map, id));
        if let Some(channel) = channel_map.get_mut(&id) {
            channel.mix.solo_up = up;
            channel.mix.solo_down = has_solo && !channel.mute && channel.solo;
        }
    }

    if has_solo {
        // Each sweep settles at least one more hop, so the channel count bounds the sweeps
        for _ in 0..=channel_ids.len() {
            let mut changed = false;
            for &id in channel_ids {
                let Some(channel) = channel_map.get(&id) else {
                    continue;
                };
                if channel.mute {
                    continue;
                }
                let push_up = channel.mix.solo_up;
                let down =
                    !channel.mix.solo_down && any_output(channel_map, channel, |t| t.mix.solo_down);
                if down {
                    channel_map.get_mut(&id).unwrap().mix.solo_down = true;
                    changed = true;
                }
                if push_up {
                    changed |= spread_solo_up(channel_map, id);
                }
            }
            if !changed {
                break;
            }
        }
    }

    for &id in channel_ids {
        let Some(channel) = channel_map.get(&id) else {
            continue;
        };
        let role = if channel.mute {
            SoloRole::Silent
        } else if !has_solo || id == MASTER_CHANNEL_ID || channel.mix.solo_up {
            SoloRole::Full
        } else if any_output(channel_map, channel, |t| t.mix.solo_down) {
            SoloRole::SendOnly
        } else {
            SoloRole::Silent
        };
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
        && target_id < HARDWARE_OUTPUT_BASE
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
    let audible = frames > 0 && role != SoloRole::Silent;
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
            if audible && (!send_only || target.mix.solo_down) && !target.mix.done {
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
        let send_allowed = audible && !send.muted && (!send_only || target.mix.solo_down);
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

/// Copy the channel's buffer for its pre-fader sends, if it has any. Call after its devices run.
///
/// Route targets have their fader applied as inputs mix in, so their copy is post-fader and
/// pre-pan.
fn copy_pre_fader(channel: &mut Channel, frames: usize) {
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

/// Start finishing a channel whose inputs have all mixed in: mark it done and begin its device
/// chain. A chain that parks at a plugin goes into `parked`; drain it before `route_finished`.
///
/// Route targets run their devices even without input, so reverb and delay tails keep ringing
/// (device sleep keeps idle chains cheap).
fn begin_finish(
    channel_map: &mut HashMap<ChannelId, Channel>,
    id: ChannelId,
    frames: usize,
    parked: &mut VecDeque<ChannelId>,
    status_tx: &Sender<EngineStatus>,
) {
    let Some(channel) = channel_map.get_mut(&id) else {
        return;
    };
    channel.mix.done = true;
    if !channel.mix.is_route_target || channel.mute {
        return;
    }
    let start = if channel.mix.has_aux_source { 1 } else { 0 };
    match channel.begin_device_chain(start, frames) {
        ChainStep::Parked => parked.push_back(id),
        ChainStep::Done { .. } => forward_device_events(channel, status_tx),
    }
}

/// Complete a channel after its device chain finished: route targets apply their pan (silenced
/// ones are cleared), then the channel routes onward.
fn route_finished(channel_map: &mut HashMap<ChannelId, Channel>, id: ChannelId, frames: usize) {
    let Some(channel) = channel_map.get_mut(&id) else {
        return;
    };
    if channel.mix.is_route_target {
        copy_pre_fader(channel, frames);
        if !channel.mute {
            apply_pan(channel, frames);
        }
        if is_silenced(channel) {
            channel.clear_buffers();
        }
    }
    route_channel(channel_map, id, frames);
}

/// Finish the parked device chains, waiting on each channel's plugin in the order they parked.
/// A chain that parks again at a later plugin goes to the back of the queue.
///
/// Waiting in park order rather than on whichever plugin finishes first: each host has its own
/// doorbell, and plugins begun together finish at about the same time.
fn drain_parked(
    channel_map: &mut HashMap<ChannelId, Channel>,
    parked: &mut VecDeque<ChannelId>,
    frames: usize,
    status_tx: &Sender<EngineStatus>,
) {
    while let Some(id) = parked.pop_front() {
        let Some(channel) = channel_map.get_mut(&id) else {
            continue;
        };
        match channel.resume_device_chain(frames) {
            ChainStep::Parked => parked.push_back(id),
            ChainStep::Done { .. } => forward_device_events(channel, status_tx),
        }
    }
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
            channel.process_aux_source(frames);
            forward_device_events(channel, status_tx);
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

/// Send a channel's device events to Godot: sleep changes and device data streams.
///
/// Uses `try_send` on the bounded status channel: when it's full the event is dropped rather
/// than blocking the callback. Plugin parameter changes and SFZ parameter lists are forwarded by
/// the command thread (`CommandWorker::poll_devices`), not here.
fn forward_device_events(channel: &mut Channel, status_tx: &Sender<EngineStatus>) {
    let channel_id = channel.id;

    rt_debug::section("sleep status sends", || {
        for (device_path, is_sleeping) in channel.sleep_changes.drain(..) {
            let _ = status_tx.try_send(EngineStatus::DeviceSleepStatus {
                channel_id,
                device_path,
                is_sleeping,
            });
        }
    });

    container::visit_devices_mut(&mut channel.devices, &mut |device_path, device| {
        if let Some(clap_adapter) = device.as_any_mut().downcast_mut::<ClapDeviceAdapter>() {
            for (param_id, value) in clap_adapter.take_pending_param_changes() {
                let _ = status_tx.try_send(EngineStatus::PluginParameterValueChanged {
                    channel_id,
                    device_path: *device_path,
                    param_id,
                    value,
                });
            }
        }

        let data = rt_debug::section("poll_device_data", || device.poll_device_data());
        if let Some((data_type, data)) = data {
            let _ = status_tx.try_send(EngineStatus::DeviceData {
                channel_id,
                device_path: *device_path,
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
    let RenderScratch {
        channel_ids,
        parked,
        ready,
        ..
    } = render_scratch;

    let has_solo = channel_map.values().any(|c| c.solo);
    channel_ids.clear();
    channel_ids.extend(channel_map.keys().copied());

    count_route_inputs(channel_map, channel_ids);
    assign_solo_roles(channel_map, channel_ids, has_solo);
    mark_aux_sources(channel_map, channel_ids);

    // Aux source pass: generate extra device buses into child channel buffers before
    // those children run their own device chains. Route-target parents skip the
    // normal pre-pass so remaining FX wait until children mix back in.
    process_aux_sources(channel_map, channel_ids, frames, status_tx);

    // First pass: process device chains (instruments and effects) before the fader.
    // Route targets are skipped; they run in the routing pass after their inputs mix in.
    // Every chain starts first; a chain that reaches a plugin parks there while the plugin
    // processes in its host, so plugins on different channels (and hosts) run in parallel and
    // built-in-only chains run on this thread meanwhile. Then the parked chains are finished.
    parked.clear();
    for &id in channel_ids.iter() {
        let Some(channel) = channel_map.get_mut(&id) else {
            continue;
        };
        if channel.mix.is_route_target {
            continue;
        }
        match channel.begin_device_chain(0, frames) {
            ChainStep::Parked => parked.push_back(id),
            ChainStep::Done { .. } => forward_device_events(channel, status_tx),
        }
    }
    drain_parked(channel_map, parked, frames, status_tx);

    // Pre-fader sends take the device output before the fader. Route targets copy theirs in
    // the routing pass, once their inputs have mixed in and their devices have run.
    for channel in channel_map.values_mut() {
        if !channel.mix.is_route_target {
            copy_pre_fader(channel, frames);
        }
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
    // Each sweep batches the channels that are ready: their chains begin together (so plugins on
    // parallel buses process at the same time), then drain, then pan and route in list order.
    // Channels ready in one sweep can't feed each other: a feed would keep the target pending.
    let mut remaining = channel_ids.len();
    while remaining > 0 {
        ready.clear();
        ready.extend(channel_ids.iter().copied().filter(|id| {
            channel_map
                .get(id)
                .is_some_and(|c| !c.mix.done && c.mix.pending_inputs == 0)
        }));

        if ready.is_empty() {
            // Routing cycle: break it at the first unfinished channel
            let unfinished = channel_ids
                .iter()
                .copied()
                .find(|id| channel_map.get(id).is_some_and(|c| !c.mix.done));
            let Some(id) = unfinished else {
                break;
            };
            ready.push(id);
        }

        parked.clear();
        for &id in ready.iter() {
            begin_finish(channel_map, id, frames, parked, status_tx);
        }
        drain_parked(channel_map, parked, frames, status_tx);
        for &id in ready.iter() {
            route_finished(channel_map, id, frames);
        }
        remaining = remaining.saturating_sub(ready.len());
    }

    write_master_output(channel_map, data, channels);
}

/// Write master (ID 1) to its hardware output pair: 1000 is outputs 1/2, 1001 is 3/4, …
/// Master's fader was applied when channels mixed into it, so its buffer goes out as is. The
/// buffer is cleared first: CPAL reuses it, and channels master doesn't write must be silent.
/// A pair the device doesn't have plays on 1/2 (the command thread warns about it).
fn write_master_output(
    channel_map: &HashMap<ChannelId, Channel>,
    data: &mut [f32],
    channels: usize,
) {
    data.fill(0.0);
    if channels == 0 {
        return;
    }
    let Some(master) = channel_map.get(&MASTER_CHANNEL_ID) else {
        return;
    };
    let Some(output_id) = master
        .output_channel_id
        .filter(|&id| id >= HARDWARE_OUTPUT_BASE)
    else {
        return;
    };
    let pairs = (channels / 2).max(1);
    let pair = output_id - HARDWARE_OUTPUT_BASE;
    let first = if pair < pairs { pair * 2 } else { 0 };

    let frames = (data.len() / channels)
        .min(master.buffer_left.len())
        .min(master.buffer_right.len());
    for frame_idx in 0..frames {
        let left = master.buffer_left[frame_idx].clamp(-1.0, 1.0);
        let right = master.buffer_right[frame_idx].clamp(-1.0, 1.0);
        let base = frame_idx * channels;
        if channels >= 2 {
            data[base + first] = left;
            data[base + first + 1] = right;
        } else {
            data[base] = (left + right) * 0.5; // Mono mix
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

    /// Mix one buffer into a device with `channels` outputs, starting from stale samples.
    fn mix_to_device(state: &mut EngineState, channels: usize) -> Vec<f32> {
        let (status_tx, _status_rx) = unbounded();
        let mut output = vec![9.0f32; BUFFER_SIZE * channels];
        mix_and_output(state, &mut output, channels, BUFFER_SIZE, &status_tx);
        output
    }

    /// Master (0 dB) routed to `output`, fed 0.5 left / 0.25 right by a 0 dB track.
    fn master_to(output: ChannelId) -> EngineState {
        let mut track = test_channel(2, Some(1), 0.0);
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.25);
        state_with(vec![test_channel(1, Some(output), 0.0), track])
    }

    #[test]
    fn master_plays_on_its_output_pair_and_other_channels_are_silent() {
        // 1001 = outputs 3/4 of a 6-channel device.
        let output = mix_to_device(&mut master_to(1001), 6);
        for frame in output.chunks(6) {
            assert!((frame[2] - 0.5).abs() < 1e-4, "{:?}", frame);
            assert!((frame[3] - 0.25).abs() < 1e-4, "{:?}", frame);
            for &i in &[0, 1, 4, 5] {
                assert_eq!(frame[i], 0.0, "channel {} must be cleared: {:?}", i, frame);
            }
        }
    }

    #[test]
    fn missing_output_pair_falls_back_to_the_first() {
        // 1002 = outputs 5/6, which a stereo device doesn't have.
        let output = mix_to_device(&mut master_to(1002), 2);
        assert!((output[0] - 0.5).abs() < 1e-4);
        assert!((output[1] - 0.25).abs() < 1e-4);
    }

    #[test]
    fn master_without_a_hardware_output_leaves_silence() {
        // CPAL reuses its buffer, so not writing it would replay old samples.
        let output = mix_to_device(&mut master_to(0), 2);
        assert!(output.iter().all(|&sample| sample == 0.0), "{:?}", output);
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

    /// What the fake plugins did, in order.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum AsyncEvent {
        Begin(ChannelId),
        Finish(ChannelId),
    }

    type AsyncLog = Arc<std::sync::Mutex<Vec<AsyncEvent>>>;

    /// Stand-in for a subprocess plugin: begins blocks asynchronously, logs `Begin`/`Finish`,
    /// and outputs its input times `gain`. Disabled, it passes dry input like the adapter. With
    /// `sleep_on_silence`, it goes to sleep after a block without activity.
    struct FakePlugin {
        id: ChannelId,
        gain: f32,
        log: AsyncLog,
        enabled: bool,
        sleeping: bool,
        sleep_on_silence: bool,
    }

    impl FakePlugin {
        fn new(id: ChannelId, gain: f32, log: &AsyncLog) -> Self {
            Self {
                id,
                gain,
                log: Arc::clone(log),
                enabled: true,
                sleeping: false,
                sleep_on_silence: false,
            }
        }
    }

    impl AudioDevice for FakePlugin {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            assert!(self.begin_block(inputs, sample_count));
            self.finish_block(inputs, outputs, sample_count);
        }
        fn begin_block(&mut self, _inputs: &[f32], _sample_count: usize) -> bool {
            self.log.lock().unwrap().push(AsyncEvent::Begin(self.id));
            true
        }
        fn finish_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            self.log.lock().unwrap().push(AsyncEvent::Finish(self.id));
            let gain = if self.enabled { self.gain } else { 1.0 };
            for i in 0..sample_count * 2 {
                outputs[i] = inputs[i] * gain;
            }
        }
        fn is_sleeping(&self) -> bool {
            self.sleeping
        }
        fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
            let sleeping = self.sleep_on_silence && !has_audio_activity;
            let changed = sleeping != self.sleeping;
            self.sleeping = sleeping;
            changed
        }
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.fake_plugin"
        }
        fn device_name(&self) -> &str {
            "Fake Plugin"
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
        fn is_enabled(&self) -> bool {
            self.enabled
        }
        fn set_enabled(&mut self, enabled: bool) {
            self.enabled = enabled;
        }
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    /// 0 dB track routed to master, fed 0.5 left / 0.25 right.
    fn source_track(id: ChannelId, output: ChannelId) -> Channel {
        let mut track = test_channel(id, Some(output), 0.0);
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.25);
        track
    }

    /// Index of the first `Finish` in the log.
    fn first_finish(log: &AsyncLog) -> usize {
        let log = log.lock().unwrap();
        log.iter()
            .position(|e| matches!(e, AsyncEvent::Finish(_)))
            .expect("no plugin finished")
    }

    /// True if `event` appears in the log before index `limit`.
    fn logged_before(log: &AsyncLog, event: AsyncEvent, limit: usize) -> bool {
        log.lock().unwrap()[..limit].contains(&event)
    }

    /// The given devices run serially over the `source_track` input, as interleaved stereo.
    fn serial_output(mut devices: Vec<Box<dyn AudioDevice>>) -> Vec<f32> {
        let mut buf_a: Vec<f32> = (0..BUFFER_SIZE).flat_map(|_| [0.5f32, 0.25]).collect();
        let mut buf_b = vec![0.0f32; BUFFER_SIZE * 2];
        let in_b = container::process_serial_chain(
            &mut devices,
            &mut buf_a,
            &mut buf_b,
            BUFFER_SIZE,
            true,
            |_, _| {},
        );
        if in_b {
            buf_b
        } else {
            buf_a
        }
    }

    /// Mix one buffer and return master's interleaved buffer, before the output clamp.
    fn mix_master(state: &mut EngineState) -> Vec<f32> {
        mix(state);
        let master = &state.channels[&1];
        (0..BUFFER_SIZE)
            .flat_map(|i| [master.buffer_left[i], master.buffer_right[i]])
            .collect()
    }

    fn assert_close(actual: &[f32], expected: &[f32]) {
        assert_eq!(actual.len(), expected.len());
        for (i, (a, e)) in actual.iter().zip(expected).enumerate() {
            assert!(
                (a - e).abs() < 1e-4,
                "sample {i}: {a} != {e} ({actual:?} vs {expected:?})"
            );
        }
    }

    #[test]
    fn plugins_on_separate_channels_all_begin_before_any_finishes() {
        let log = AsyncLog::default();
        let mut channels = vec![test_channel(1, Some(1000), 0.0)];
        for id in 2..5 {
            let mut track = source_track(id, 1);
            track.devices.push(Box::new(FakePlugin::new(id, 1.0, &log)));
            channels.push(track);
        }
        let mut state = state_with(channels);
        let output = mix_master(&mut state);

        let finish = first_finish(&log);
        for id in 2..5 {
            assert!(
                logged_before(&log, AsyncEvent::Begin(id), finish),
                "{:?}",
                log
            );
        }
        assert_eq!(log.lock().unwrap().len(), 6);
        assert!(
            (output[0] - 1.5).abs() < 1e-4,
            "three tracks sum on master: {output:?}"
        );
    }

    #[test]
    fn a_chain_parked_at_plugins_matches_the_serial_chain() {
        let log = AsyncLog::default();
        let chains: [fn(&AsyncLog) -> Vec<Box<dyn AudioDevice>>; 2] = [
            |log| {
                vec![
                    Box::new(FakePlugin::new(1, 2.0, log)),
                    Box::new(TestDevice {
                        level: 0.1,
                        calls: Arc::default(),
                    }),
                    Box::new(FakePlugin::new(2, 3.0, log)),
                ]
            },
            |log| {
                vec![
                    Box::new(TestDevice {
                        level: 0.1,
                        calls: Arc::default(),
                    }),
                    Box::new(FakePlugin::new(1, 2.0, log)),
                    Box::new(TestDevice {
                        level: -0.05,
                        calls: Arc::default(),
                    }),
                    Box::new(FakePlugin::new(2, 3.0, log)),
                ]
            },
        ];
        for make in chains {
            let expected = serial_output(make(&log));
            let mut track = source_track(2, 1);
            track.devices = make(&log);
            let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), track]);
            assert_close(&mix_master(&mut state), &expected);
        }
    }

    #[test]
    fn a_plugin_at_the_end_of_a_chain_begins_alongside_one_at_the_start() {
        let log = AsyncLog::default();
        let mut late = source_track(2, 1);
        add_test_device(&mut late, 0.1);
        add_test_device(&mut late, 0.1);
        late.devices.push(Box::new(FakePlugin::new(2, 1.0, &log)));
        let mut early = source_track(3, 1);
        early.devices.push(Box::new(FakePlugin::new(3, 1.0, &log)));
        add_test_device(&mut early, 0.1);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), late, early]);
        mix(&mut state);

        let finish = first_finish(&log);
        assert!(
            logged_before(&log, AsyncEvent::Begin(2), finish),
            "{:?}",
            log
        );
        assert!(
            logged_before(&log, AsyncEvent::Begin(3), finish),
            "{:?}",
            log
        );
    }

    #[test]
    fn sleeping_and_disabled_plugins_match_the_serial_chain() {
        let log = AsyncLog::default();
        let make = |log: &AsyncLog| -> Vec<Box<dyn AudioDevice>> {
            let mut disabled = FakePlugin::new(1, 2.0, log);
            disabled.enabled = false;
            let mut asleep = FakePlugin::new(2, 3.0, log);
            asleep.sleeping = true;
            vec![
                Box::new(disabled),
                Box::new(TestDevice {
                    level: 0.1,
                    calls: Arc::default(),
                }),
                Box::new(asleep),
                Box::new(FakePlugin::new(3, 0.5, log)),
            ]
        };
        let expected = serial_output(make(&log));
        let mut track = source_track(2, 1);
        track.devices = make(&log);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), track]);
        assert_close(&mix_master(&mut state), &expected);

        // A plugin that falls asleep after a silent block reports it, with its chain index.
        let mut silent = test_channel(2, Some(1), 0.0);
        silent.devices.push(Box::new(TestDevice {
            level: 0.0,
            calls: Arc::default(),
        }));
        let mut dozing = FakePlugin::new(4, 1.0, &log);
        dozing.sleep_on_silence = true;
        silent.devices.push(Box::new(dozing));
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), silent]);
        let (status_tx, status_rx) = unbounded();
        let mut output = vec![0.0f32; BUFFER_SIZE * 2];
        mix_and_output(&mut state, &mut output, 2, BUFFER_SIZE, &status_tx);
        let sleeps: Vec<_> = status_rx
            .try_iter()
            .filter_map(|status| match status {
                EngineStatus::DeviceSleepStatus {
                    channel_id,
                    device_path,
                    is_sleeping,
                } => Some((channel_id, device_path, is_sleeping)),
                _ => None,
            })
            .collect();
        assert_eq!(
            sleeps,
            vec![(2, crate::audio::devices::DevicePath::root(1), true)]
        );
    }

    #[test]
    fn plugins_on_parallel_send_buses_begin_together_and_reach_master() {
        let log = AsyncLog::default();
        let mut source = source_track(4, 1);
        for bus in [2, 3] {
            source.send_channels.push(Send {
                target_channel_id: bus,
                amount_db: 0.0,
                pre_fader: false,
                muted: false,
            });
        }
        let mut buses = Vec::new();
        for (id, gain) in [(2, 2.0), (3, 3.0)] {
            let mut bus = test_channel(id, Some(1), 0.0);
            bus.devices.push(Box::new(FakePlugin::new(id, gain, &log)));
            buses.push(bus);
        }
        let mut channels = vec![test_channel(1, Some(1000), 0.0), source];
        channels.extend(buses);
        let mut state = state_with(channels);
        let output = mix_master(&mut state);

        let finish = first_finish(&log);
        assert!(
            logged_before(&log, AsyncEvent::Begin(2), finish),
            "{:?}",
            log
        );
        assert!(
            logged_before(&log, AsyncEvent::Begin(3), finish),
            "{:?}",
            log
        );
        // Dry 0.5 + bus 2 (0.5 × 2) + bus 3 (0.5 × 3).
        assert!((output[0] - 3.0).abs() < 1e-4, "{output:?}");
        assert!((output[1] - 1.5).abs() < 1e-4, "{output:?}");
    }

    /// Post-fader send from `source` into `target` at 0 dB.
    fn send_to(target_channel_id: ChannelId, pre_fader: bool) -> Send {
        Send {
            target_channel_id,
            amount_db: 0.0,
            pre_fader,
            muted: false,
        }
    }

    #[test]
    fn pre_fader_send_carries_instrument_output() {
        // The instrument's device generates the signal; its buffer is empty before devices run
        let mut instrument = test_channel(3, Some(1), -60.0);
        add_test_device(&mut instrument, 0.25);
        instrument.send_channels.push(send_to(2, true));
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(2, Some(1), 0.0),
            instrument,
        ]);
        let output = mix(&mut state);

        assert!((state.channels[&2].buffer_left[0] - 0.25).abs() < 1e-4);
        assert!((output[0] - 0.25).abs() < 1e-3, "{output:?}");
    }

    #[test]
    fn bus_pre_fader_send_carries_bus_device_output() {
        // Track → bus 2 (device adds 0.1, pre-fader send to bus 4) → master
        let mut track = test_channel(3, Some(2), 0.0);
        track.buffer_left.fill(0.2);
        track.buffer_right.fill(0.2);
        let mut bus = test_channel(2, Some(1), 0.0);
        add_test_device(&mut bus, 0.1);
        bus.send_channels.push(send_to(4, true));
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            bus,
            track,
            test_channel(4, Some(1), 0.0),
        ]);
        let output = mix(&mut state);

        assert!((state.channels[&4].buffer_left[0] - 0.3).abs() < 1e-4);
        assert!((output[0] - 0.6).abs() < 1e-4, "{output:?}");
    }

    #[test]
    fn bus_sends_to_another_bus() {
        // Track → bus 2 → master, and bus 2 sends post-fader into bus 4 → master
        let mut track = test_channel(3, Some(2), 0.0);
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.5);
        let mut bus = test_channel(2, Some(1), 0.0);
        bus.send_channels.push(send_to(4, false));
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            test_channel(4, Some(1), 0.0),
            bus,
            track,
        ]);
        let output = mix(&mut state);

        assert!((state.channels[&2].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((state.channels[&4].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((output[0] - 1.0).abs() < 1e-4, "{output:?}");
    }

    #[test]
    fn bus_send_to_bus_runs_target_devices_once() {
        let mut track = test_channel(3, Some(2), 0.0);
        track.buffer_left.fill(0.5);
        track.buffer_right.fill(0.5);
        let mut bus = test_channel(2, Some(1), 0.0);
        bus.send_channels.push(send_to(4, false));
        let mut fx = test_channel(4, Some(1), 0.0);
        let fx_calls = add_test_device(&mut fx, 0.0);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), fx, bus, track]);
        mix(&mut state);

        assert_eq!(fx_calls.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn soloed_reverb_keeps_instrument_sending_into_it() {
        // Drums (instrument device) → master, sending into Reverb; soloing Reverb must keep the
        // drums running so the send carries signal, while the dry drums are muted
        let mut drums = test_channel(3, Some(1), 0.0);
        let drum_calls = add_test_device(&mut drums, 0.25);
        drums.send_channels.push(send_to(2, false));
        let mut reverb = test_channel(2, Some(1), 0.0);
        reverb.solo = true;
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), reverb, drums]);
        let output = mix(&mut state);

        assert_eq!(drum_calls.load(Ordering::Relaxed), 1);
        assert!((state.channels[&2].buffer_left[0] - 0.25).abs() < 1e-4);
        assert!((output[0] - 0.25).abs() < 1e-4, "{output:?}");
    }

    #[test]
    fn soloed_reverb_keeps_pre_fader_send_from_instrument() {
        let mut drums = test_channel(3, Some(1), -60.0);
        add_test_device(&mut drums, 0.25);
        drums.send_channels.push(send_to(2, true));
        let mut reverb = test_channel(2, Some(1), 0.0);
        reverb.solo = true;
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), reverb, drums]);
        let output = mix(&mut state);

        assert!((output[0] - 0.25).abs() < 1e-3, "{output:?}");
    }

    #[test]
    fn soloed_reverb_keeps_group_bus_sending_into_it() {
        // Drums → Drum Bus → master; Drum Bus sends into Reverb. Soloing Reverb plays only the
        // reverb return: the drums feed the bus, whose dry output is muted but whose send stays
        let mut drums = test_channel(3, Some(2), 0.0);
        drums.buffer_left.fill(0.5);
        drums.buffer_right.fill(0.5);
        let mut drum_bus = test_channel(2, Some(1), 0.0);
        drum_bus.send_channels.push(send_to(4, false));
        let mut reverb = test_channel(4, Some(1), 0.0);
        reverb.solo = true;
        let mut other = test_channel(5, Some(1), 0.0);
        other.buffer_left.fill(0.9);
        other.buffer_right.fill(0.9);
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            drum_bus,
            drums,
            reverb,
            other,
        ]);
        let output = mix(&mut state);

        assert!((state.channels[&4].buffer_left[0] - 0.5).abs() < 1e-4);
        assert!((output[0] - 0.5).abs() < 1e-4, "{output:?}");
    }
}
