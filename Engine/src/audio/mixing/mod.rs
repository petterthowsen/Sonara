//! Mixing: fader and pan, routing in dependency order, and the master output.

mod routing;
mod solo;
#[cfg(test)]
mod test_support;

use std::collections::{HashMap, VecDeque};

use crossbeam::channel::Sender;

use super::channel::Channel;
use super::commands::EngineStatus;
use super::devices::container::{self, ChainStep};
use super::render_scratch::RenderScratch;
use super::rt_debug;
use super::state::EngineState;
use super::types::*;

use routing::{
    begin_finish, copy_pre_fader, count_route_inputs, drain_parked, mark_aux_sources,
    process_aux_sources, route_finished,
};
use solo::{assign_solo_roles, is_silenced};

/// Master channel ID. Master never routes to another channel and is never silenced by solo.
const MASTER_CHANNEL_ID: ChannelId = 1;

/// Max hops when walking output chains so a routing cycle cannot spin forever.
const SOLO_WALK_LIMIT: usize = 64;

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

    device_prepass(channel_map, channel_ids, parked, frames, status_tx);

    // Pre-fader sends take the device output before the fader. Route targets copy theirs in
    // the routing pass, once their inputs have mixed in and their devices have run.
    for channel in channel_map.values_mut() {
        if !channel.mix.is_route_target {
            copy_pre_fader(channel, frames);
        }
    }

    apply_fader_and_pan(channel_map, frames);

    route_in_dependency_order(channel_map, channel_ids, parked, ready, frames, status_tx);

    write_master_output(channel_map, data, channels);
}

/// First pass: begin and finish the device chains of channels nothing routes into.
///
/// Reads: `mix.is_route_target`, `mix.has_aux_source`. Writes: channel buffers and device
/// state through the chains, `parked`, and the device events sent on `status_tx`.
fn device_prepass(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    parked: &mut VecDeque<ChannelId>,
    frames: usize,
    status_tx: &Sender<EngineStatus>,
) {
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
        // An aux source already ran its first device in the aux pass (its returns may route
        // elsewhere, e.g. Layer slots to a bus), so only its remaining FX run here.
        let start = if channel.mix.has_aux_source {
            channel.aux_source_index() + 1
        } else {
            0
        };
        match channel.begin_device_chain(start, frames) {
            ChainStep::Parked => parked.push_back(id),
            ChainStep::Done { .. } => forward_device_events(channel, status_tx),
        }
    }
    drain_parked(channel_map, parked, frames, status_tx);
}

/// Second pass: apply each channel's smoothed fader gain and pan to its own buffer.
///
/// Reads: `mix.solo_role`, pan and fader settings. Writes: channel buffers and the gain
/// smoothing state.
fn apply_fader_and_pan(channel_map: &mut HashMap<ChannelId, Channel>, frames: usize) {
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
}

/// Third pass: finish channels in dependency order, mixing each into its route and sends.
///
/// Reads and writes the whole `mix` scratch of every channel (`pending_inputs`, `done`) plus
/// buffers and device state; `ready` and `parked` are preallocated scratch.
fn route_in_dependency_order(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    parked: &mut VecDeque<ChannelId>,
    ready: &mut Vec<ChannelId>,
    frames: usize,
    status_tx: &Sender<EngineStatus>,
) {
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
    use crate::audio::mixing::test_support::*;
    use crate::audio::state::EngineState;
    use crossbeam::channel::unbounded;

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
}
