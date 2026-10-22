//! Routing: sends, route targets, pan, pre-fader copies, parked device chains, aux sources and
//! extra outputs.

use std::collections::{HashMap, VecDeque};
use std::time::Instant;

use crossbeam::channel::Sender;

use crate::audio::channel::{elapsed_ns, fader_gain, Channel};
use crate::audio::commands::EngineStatus;
use crate::audio::devices::container::ChainStep;
use crate::audio::dsp::block_delay::StereoBlockDelay;
use crate::audio::dsp::interleave::deinterleave_stereo;
use crate::audio::render_scratch::SoloRole;
use crate::audio::types::*;

use super::solo::is_silenced;
use super::{forward_device_events, MASTER_CHANNEL_ID};

/// The channel this channel routes its output into, if any (master never routes onward).
pub(super) fn output_target(channel: &Channel) -> Option<ChannelId> {
    if channel.id == MASTER_CHANNEL_ID {
        None
    } else {
        channel.output_channel_id
    }
}

/// The Stage return this channel feeds its reflections to (spec 051): set while the channel is
/// a stage source. Master never feeds the stage.
pub(super) fn stage_target(channel: &Channel) -> Option<ChannelId> {
    if channel.id == MASTER_CHANNEL_ID || channel.stage.is_none() {
        None
    } else {
        channel.stage_feed
    }
}

/// True if `source_id` can mix into `target_id`: another existing channel, not a hardware output.
pub(super) fn is_valid_route(
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
pub(super) fn add_scaled(
    target: &mut Channel,
    left: &[f32],
    right: &[f32],
    frames: usize,
    gain: f32,
) {
    for i in 0..frames {
        target.buffer_left[i] += left[i] * gain;
        target.buffer_right[i] += right[i] * gain;
    }
}

/// Add `gain` times `ring`'s block, `delay` samples late, into a channel's buffers.
fn add_delayed(
    target: &mut Channel,
    ring: &StereoBlockDelay,
    delay: usize,
    frames: usize,
    gain: f32,
) {
    ring.add_delayed(
        delay,
        gain,
        frames,
        &mut target.buffer_left,
        &mut target.buffer_right,
    );
}

/// Reset per-buffer routing state, count each channel's route and send inputs, and mark route
/// targets. Master is always a target so its devices run after everything has mixed in.
pub(super) fn count_route_inputs(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
) {
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
        let stage = stage_target(source);

        // A send at -inf is no edge, so a route can close a loop through it. A stage source's
        // reflections are a third kind of edge, into the Stage return.
        let targets = output.into_iter().chain(stage).chain(
            sends
                .iter()
                .filter(|send| send.is_live())
                .map(|send| send.target_channel_id),
        );
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

/// Mix a finished channel into its output, send and stage targets and release their pending
/// inputs.
///
/// Routed audio isn't scaled by the target's fader: that applies after the target's devices
/// (`route_finished`). The source's pan was already applied.
/// Pre-fader sends reapply the source's pan so stereo matches the source. Targets that already
/// finished (only possible in a routing cycle) receive nothing.
pub(super) fn route_channel(
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
    let stage = stage_target(source);
    let has_pre_fader_copy = source.mix.has_pre_fader_copy;
    let pan = source.get_pan_coefficients();

    // Move the source's buffers out (no allocation) so targets can be borrowed mutably
    let sends = std::mem::take(&mut source.send_channels);
    let left = std::mem::take(&mut source.buffer_left);
    let right = std::mem::take(&mut source.buffer_right);
    let pre_left = std::mem::take(&mut source.mix.pre_fader_left);
    let pre_right = std::mem::take(&mut source.mix.pre_fader_right);
    let stage_left = std::mem::take(&mut source.mix.stage_left);
    let stage_right = std::mem::take(&mut source.mix.stage_right);
    // Edge delays and their rings (spec 042 D), moved out like the buffers. An edge whose delay
    // is 0, or whose ring is missing, takes the plain path.
    let route_delay = source.latency.route_delay as usize;
    let send_delays = std::mem::take(&mut source.latency.send_delays);
    let post_ring = source.latency.post.take();
    let pre_ring = source.latency.pre.take();
    let stage_delay = source.latency.stage_delay as usize;
    let stage_ring = source.latency.stage.take();

    if let Some(target_id) = output.filter(|&id| is_valid_route(channel_map, source_id, id)) {
        if let Some(target) = channel_map.get_mut(&target_id) {
            target.mix.pending_inputs = target.mix.pending_inputs.saturating_sub(1);
            if audible && (!send_only || target.mix.solo_down) && !target.mix.done {
                // The target's fader applies after its devices, in `route_finished`.
                match post_ring.as_ref().filter(|_| route_delay > 0) {
                    Some(ring) => add_delayed(target, ring, route_delay, frames, 1.0),
                    None => add_scaled(target, &left, &right, frames, 1.0),
                }
            }
        }
    }

    // The reflections go to the Stage return like a send, at unity: the source's fader already
    // set their level, and its direct sound went to the route above.
    if let Some(target_id) = stage.filter(|&id| is_valid_route(channel_map, source_id, id)) {
        if let Some(target) = channel_map.get_mut(&target_id) {
            target.mix.pending_inputs = target.mix.pending_inputs.saturating_sub(1);
            if audible && (!send_only || target.mix.solo_down) && !target.mix.done {
                match stage_ring.as_ref().filter(|_| stage_delay > 0) {
                    Some(ring) => add_delayed(target, ring, stage_delay, frames, 1.0),
                    None => add_scaled(target, &stage_left, &stage_right, frames, 1.0),
                }
            }
        }
    }

    for (send_index, send) in sends.iter().enumerate() {
        let delay = send_delays.get(send_index).copied().unwrap_or(0) as usize;
        // Not counted as an input (`count_route_inputs`), so nothing to release either.
        if !send.is_live() || !is_valid_route(channel_map, source_id, send.target_channel_id) {
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
        let gain = fader_gain(send.amount_db);

        if !send.pre_fader {
            match post_ring.as_ref().filter(|_| delay > 0) {
                Some(ring) => add_delayed(target, ring, delay, frames, gain),
                None => add_scaled(target, &left, &right, frames, gain),
            }
        } else if has_pre_fader_copy {
            // A delayed send reads the pre-fader ring instead of the copy; the pan applies as usual.
            let ring = pre_ring.as_ref().filter(|_| delay > 0);
            for i in 0..frames {
                let (left_in, right_in) = match ring {
                    Some(ring) => ring.sample(delay, frames, i),
                    None => (pre_left[i], pre_right[i]),
                };
                target.buffer_left[i] +=
                    (left_in * pan.left_to_left + right_in * pan.right_to_left) * gain;
                target.buffer_right[i] +=
                    (left_in * pan.left_to_right + right_in * pan.right_to_right) * gain;
            }
        }
    }

    if let Some(source) = channel_map.get_mut(&source_id) {
        source.send_channels = sends;
        source.latency.send_delays = send_delays;
        source.latency.post = post_ring;
        source.latency.pre = pre_ring;
        source.latency.stage = stage_ring;
        source.buffer_left = left;
        source.buffer_right = right;
        source.mix.pre_fader_left = pre_left;
        source.mix.pre_fader_right = pre_right;
        source.mix.stage_left = stage_left;
        source.mix.stage_right = stage_right;
    }
}

/// Copy the channel's buffer for its pre-fader sends, if it has any. Call after its devices run.
///
/// Route targets apply their fader after their devices, so their copy is pre-fader and pre-pan.
pub(super) fn copy_pre_fader(channel: &mut Channel, frames: usize) {
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

/// Device index where the mixer begins this channel's chain this buffer. An aux source already
/// ran its first device in the aux pass (its returns may route elsewhere, e.g. Layer slots to a
/// bus), so only its remaining FX run in the later passes.
pub(super) fn chain_start(channel: &Channel) -> usize {
    if channel.mix.has_aux_source {
        channel.aux_source_index() + 1
    } else {
        0
    }
}

/// A channel finishing in the routing pass runs its device chain: route targets that aren't
/// muted.
pub(super) fn runs_on_finish(channel: &Channel) -> bool {
    channel.mix.is_route_target && !channel.mute
}

/// Start finishing a channel whose inputs have all mixed in: mark it done and begin its device
/// chain. A chain that parks at a plugin goes into `parked`; drain it before `route_finished`.
///
/// Route targets run their devices even without input, so reverb and delay tails keep ringing
/// (device sleep keeps idle chains cheap).
pub(super) fn begin_finish(
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
    if !runs_on_finish(channel) {
        return;
    }
    match channel.begin_device_chain(chain_start(channel), frames) {
        ChainStep::Parked => parked.push_back(id),
        ChainStep::Done { .. } => forward_device_events(channel, status_tx),
    }
}

/// Push this block into the channel's latency rings (spec 042 D), once per block so their
/// history stays continuous: the final post-fader buffers into `post`, and the pre-fader copy
/// into `pre` (silence in blocks with no copy, such as every send muted).
fn write_latency_rings(channel: &mut Channel, frames: usize) {
    if let Some(post) = channel.latency.post.as_mut() {
        post.write(&channel.buffer_left, &channel.buffer_right, frames);
    }
    if let Some(pre) = channel.latency.pre.as_mut() {
        let mix = &mut channel.mix;
        if !mix.has_pre_fader_copy {
            mix.pre_fader_left[..frames].fill(0.0);
            mix.pre_fader_right[..frames].fill(0.0);
        }
        pre.write(&mix.pre_fader_left, &mix.pre_fader_right, frames);
    }
    if let Some(stage) = channel.latency.stage.as_mut() {
        stage.write(&channel.mix.stage_left, &channel.mix.stage_right, frames);
    }
}

/// Complete a channel after its device chain finished: route targets apply their fader and pan
/// (silenced ones are cleared), then the channel routes onward.
pub(super) fn route_finished(
    channel_map: &mut HashMap<ChannelId, Channel>,
    id: ChannelId,
    frames: usize,
) {
    let Some(channel) = channel_map.get_mut(&id) else {
        return;
    };
    let started = channel.mix.timing.then(Instant::now);
    if channel.mix.is_route_target {
        copy_pre_fader(channel, frames);
        if !channel.mute {
            super::fader_and_pan(channel, frames);
        }
        if is_silenced(channel) {
            channel.clear_buffers();
        }
        // A stage source that others route into places itself in the room once its inputs
        // have mixed in and its fader has applied (the stage pass skips route targets).
        if channel.stage.is_some() {
            channel.render_stage(frames);
        }
    }
    write_latency_rings(channel, frames);
    route_channel(channel_map, id, frames);
    if let (Some(started), Some(channel)) = (started, channel_map.get_mut(&id)) {
        channel.mix.timer.add(elapsed_ns(started));
    }
}

/// Finish the parked device chains, waiting on each channel's plugin in the order they parked.
/// A chain that parks again at a later plugin goes to the back of the queue.
///
/// Waiting in park order rather than on whichever plugin finishes first: each host has its own
/// doorbell, and plugins begun together finish at about the same time.
pub(super) fn drain_parked(
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

/// Mark channels whose aux-source device (the first that isn't a note effect) writes extra
/// buses into nested child channels.
pub(super) fn mark_aux_sources(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
) {
    for &id in channel_ids {
        if let Some(channel) = channel_map.get_mut(&id) {
            channel.mix.has_aux_source = channel.extra_out_targets.iter().any(|&t| t > 0);
        }
    }
}

/// Process aux-source devices and copy extra stereo buses into mapped child channels.
pub(super) fn process_aux_sources(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    frames: usize,
    status_tx: &Sender<EngineStatus>,
) {
    for &id in channel_ids {
        {
            let Some(channel) = channel_map.get_mut(&id) else {
                continue;
            };
            if !channel.mix.has_aux_source {
                continue;
            }
            channel.process_aux_source(frames);
            forward_device_events(channel, status_tx);
            copy_extra_outs_to_targets(channel_map, id, frames);
        }
    }
}

/// Deinterleave extra-out buses from `source_id` into mapped child channel buffers.
pub(super) fn copy_extra_outs_to_targets(
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
pub(super) fn deinterleave_extra(extra: &[f32], target: &mut Channel, frames: usize) {
    let frames = frames
        .min(target.buffer_left.len())
        .min(target.buffer_right.len())
        .min(extra.len() / 2);
    deinterleave_stereo(
        &extra[..frames * 2],
        &mut target.buffer_left[..frames],
        &mut target.buffer_right[..frames],
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::channel::fader_gain;
    use crate::audio::channel::{Channel, Send};
    use crate::audio::devices::container;
    use crate::audio::devices::AudioDevice;
    use crate::audio::mixing::mix_and_output;
    use crate::audio::mixing::test_support::*;
    use crate::audio::state::EngineState;
    use crossbeam::channel::unbounded;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;

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
            false,
            |_, _| {},
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
        let expected = 0.5 * fader_gain(-6.0) * fader_gain(-6.0);
        assert!((state.channels[&2].buffer_left[0] - expected).abs() < 1e-5);
        assert!((state.channels[&1].buffer_left[0] - expected).abs() < 1e-5);
        assert!((output[0] - expected).abs() < 1e-5);
        assert!((output[1] - expected).abs() < 1e-5);
    }

    #[test]
    fn muted_track_is_not_routed() {
        let mut state = track_bus_master_state();
        state.channels.get_mut(&3).unwrap().mute = true;
        let output = mix(&mut state);

        assert!(output.iter().all(|sample| sample.abs() < 1e-6));
    }

    #[test]
    fn disabled_track_is_silent_and_skips_its_devices() {
        let mut state = track_bus_master_state();
        let calls = add_test_device(state.channels.get_mut(&3).unwrap(), 0.25);
        state.channels.get_mut(&3).unwrap().enabled = false;
        let output = mix(&mut state);

        assert_eq!(calls.load(Ordering::Relaxed), 0);
        assert!(output.iter().all(|sample| sample.abs() < 1e-6));
    }

    #[test]
    fn routed_bus_devices_run_without_input() {
        // A silent track still routed into the bus: its reverb tail must keep ringing
        let mut state = track_bus_master_state();
        state.channels.get_mut(&3).unwrap().clear_buffers();
        let calls = add_test_device(state.channels.get_mut(&2).unwrap(), 0.25);
        let output = mix(&mut state);

        // The bus's -6 dB fader scales its device output, not the (silent) input
        let expected = 0.25 * fader_gain(-6.0);
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert!((output[0] - expected).abs() < 1e-5);
        assert!((output[1] - expected).abs() < 1e-5);
    }

    #[test]
    fn bus_fader_scales_device_output_not_device_input() {
        // The device adds 0.25 to its input. The fader belongs after it: applying it before the
        // chain (the bug) would give 0.5 * g * g + 0.25 instead.
        let mut state = track_bus_master_state();
        add_test_device(state.channels.get_mut(&2).unwrap(), 0.25);
        let output = mix(&mut state);

        let g = fader_gain(-6.0);
        let expected = (0.5 * g + 0.25) * g;
        assert!((state.channels[&2].buffer_left[0] - expected).abs() < 1e-5);
        assert!((output[0] - expected).abs() < 1e-5);
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

        let gain = fader_gain(-6.0);
        let expected = 0.5 * gain * gain * gain + 0.5 * gain * gain;
        assert_eq!(calls.load(Ordering::Relaxed), 1);
        assert!((output[0] - expected).abs() < 1e-5);
    }

    #[test]
    fn send_at_minus_inf_is_no_edge() {
        // Track 5 → bus 4 → bus 2 → master, and bus 2 sends back to bus 4 at -inf. Counted as an
        // edge that would be a cycle broken at 2 (lowest id), cutting the real 4 → 2 route.
        let mut back = test_channel(2, Some(1), 0.0);
        back.send_channels.push(Send {
            target_channel_id: 4,
            amount_db: -60.0,
            pre_fader: false,
            muted: false,
        });
        let mut state = state_with(vec![
            test_channel(1, Some(1000), 0.0),
            back,
            test_channel(4, Some(2), 0.0),
            source_track(5, 4),
        ]);
        let output = mix(&mut state);

        assert!(
            (output[0] - 0.5).abs() < 1e-4,
            "route through 4 → 2 survives, got {}",
            output[0]
        );

        // Turned up, the send is an edge again (the engine then breaks the cycle as before).
        state.channels.get_mut(&2).unwrap().send_channels[0].amount_db = -59.0;
        let mut ids: Vec<ChannelId> = state.channels.keys().copied().collect();
        ids.sort_unstable();
        count_route_inputs(&mut state.channels, &ids);
        assert_eq!(state.channels[&4].mix.pending_inputs, 2);
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

    #[test]
    fn extra_out_feeds_child_before_child_devices() {
        let mut parent = test_channel(2, Some(1), 0.0);
        parent.devices.push(Box::new(TestAuxDevice::default()));
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

    #[test]
    fn aux_source_whose_returns_route_elsewhere_runs_once() {
        // Layer-style source on 2 whose only return (3) routes to bus 4, not back to 2, so 2
        // isn't a route target. Its first device must still run exactly once per block.
        let mut parent = test_channel(2, Some(1), 0.0);
        let source = TestAuxDevice::default();
        let source_calls = Arc::clone(&source.calls);
        parent.devices.push(Box::new(source));
        let parent_fx = add_test_device(&mut parent, 0.0);
        parent.set_aux_out(0, 3);
        let child = test_channel(3, Some(4), 0.0);
        let bus = test_channel(4, Some(1), 0.0);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), parent, child, bus]);
        mix(&mut state);

        assert_eq!(
            source_calls.load(Ordering::Relaxed),
            1,
            "aux source ran twice"
        );
        assert_eq!(
            parent_fx.load(Ordering::Relaxed),
            1,
            "parent FX after the source ran"
        );
        assert!((state.channels[&3].buffer_left[0] - 0.8).abs() < 1e-4);
        assert!(
            state.channels[&4].buffer_left[0] > 0.7,
            "bus should receive the return, got {}",
            state.channels[&4].buffer_left[0]
        );
    }

    #[test]
    fn aux_source_after_leading_note_effects() {
        // [note effect, Layer-style source]: the source behind the note effect still feeds its
        // return, and runs once.
        use crate::audio::devices::note_fx::routing::test_devices::Shift;
        let mut parent = test_channel(2, Some(1), 0.0);
        let source = TestAuxDevice::default();
        let source_calls = Arc::clone(&source.calls);
        parent.devices.push(Box::new(Shift::new(12)));
        parent.devices.push(Box::new(source));
        parent.set_aux_out(0, 3);
        assert_eq!(parent.aux_source_index(), 1);
        let child = test_channel(3, Some(2), 0.0);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), parent, child]);
        mix(&mut state);

        assert_eq!(source_calls.load(Ordering::Relaxed), 1);
        assert!((state.channels[&3].buffer_left[0] - 0.8).abs() < 1e-4);
    }

    #[test]
    fn channel_timer_excludes_parked_wait() {
        // Track 2 parks at its plugin; track 3's plugin then takes 20 ms to begin, while track 2
        // waits. That wait is track 3's work, not track 2's.
        let cost = std::time::Duration::from_millis(20);
        let log = AsyncLog::default();
        let mut parked = source_track(2, 1);
        parked.devices.push(Box::new(FakePlugin::new(2, 1.0, &log)));
        let mut slow = source_track(3, 1);
        let mut plugin = FakePlugin::new(3, 1.0, &log);
        plugin.begin_cost = cost;
        slow.devices.push(Box::new(plugin));
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), parked, slow]);
        state.perf_timing = true;
        mix_master(&mut state);

        assert_eq!(
            log.lock().unwrap()[..2],
            [AsyncEvent::Begin(2), AsyncEvent::Begin(3)],
            "track 3 began while track 2 was parked"
        );
        let channel_ns = |id: ChannelId| state.channels[&id].mix.timer.total_ns;
        let cost_ns = cost.as_nanos() as u64;
        assert!(channel_ns(3) >= cost_ns, "track 3: {} ns", channel_ns(3));
        assert!(channel_ns(2) < cost_ns / 2, "track 2: {} ns", channel_ns(2));
        let device = |id: ChannelId| state.channels[&id].device_timers[0];
        assert!(device(3).total_ns >= cost_ns);
        assert!(device(2).total_ns < cost_ns / 2);
        assert_eq!((device(2).blocks, device(3).blocks), (1, 1));
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

    /// Fill `ids` with the same test signal each block: sample `k` of block `block`.
    fn feed(state: &mut EngineState, ids: &[ChannelId], block: usize) {
        for &id in ids {
            let channel = state.channels.get_mut(&id).unwrap();
            for i in 0..BUFFER_SIZE {
                let k = block * BUFFER_SIZE + i;
                let x = ((k * 37) % 101) as f32 / 200.0 + 0.1;
                channel.buffer_left[i] = x;
                channel.buffer_right[i] = x * 0.5;
            }
        }
    }

    /// Run `blocks` blocks, feeding `sources`, and return every block's mixed output.
    fn run_blocks(state: &mut EngineState, sources: &[ChannelId], blocks: usize) -> Vec<Vec<f32>> {
        (0..blocks)
            .map(|block| {
                feed(state, sources, block);
                mix(state)
            })
            .collect()
    }

    /// Two copies of one signal meet at master: channel 3 through a `delay`-frame device, channel
    /// 4 through a polarity inverter with no latency, each into master by `connect`. Returns the
    /// output blocks after installing the compensation (or not).
    fn parallel_paths(
        delay: usize,
        compensate: bool,
        connect: impl Fn(&mut Channel),
    ) -> Vec<Vec<f32>> {
        let mut slow = test_channel(3, Some(1), 0.0);
        slow.devices.push(Box::new(LatencyDevice::new(delay, 1.0)));
        let mut fast = test_channel(4, None, 0.0);
        fast.devices.push(Box::new(LatencyDevice::new(0, -1.0)));
        connect(&mut fast);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), slow, fast]);
        if compensate {
            install_latency(&mut state);
        }
        run_blocks(&mut state, &[3, 4], 12)
    }

    fn peak(blocks: &[Vec<f32>]) -> f32 {
        blocks
            .iter()
            .flatten()
            .fold(0.0f32, |peak, sample| peak.max(sample.abs()))
    }

    #[test]
    fn parallel_paths_null_at_master() {
        // Delays shorter and longer than the 4-frame block, for the route and both send kinds
        let connections: [(&str, fn(&mut Channel)); 3] = [
            ("route", |c| c.output_channel_id = Some(1)),
            ("post send", |c| c.send_channels.push(send_to(1, false))),
            ("pre send", |c| c.send_channels.push(send_to(1, true))),
        ];
        for (name, connect) in connections {
            for delay in [3, 6, 13] {
                let uncompensated = parallel_paths(delay, false, connect);
                assert!(
                    peak(&uncompensated) > 0.1,
                    "{name} {delay}: paths already null"
                );

                let blocks = parallel_paths(delay, true, connect);
                // Past the delay's warm-up the two paths cancel, up to the fader smoothing's
                // residue (a pre-fader send skips the fader the other path goes through)
                let settled = delay / BUFFER_SIZE + 2;
                assert!(
                    peak(&blocks[settled..]) < 1e-4,
                    "{name} {delay}: {:?}",
                    &blocks[settled..]
                );
            }
        }
    }

    #[test]
    fn parallel_paths_null_at_hardware_pair() {
        // Channel 3 (delayed) and 4 (inverted) both write straight to pair 1000
        let mut slow = test_channel(3, Some(1000), 0.0);
        slow.devices.push(Box::new(LatencyDevice::new(6, 1.0)));
        let mut fast = test_channel(4, Some(1000), 0.0);
        fast.devices.push(Box::new(LatencyDevice::new(0, -1.0)));
        let mut state = state_with(vec![test_channel(1, Some(1001), 0.0), slow, fast]);
        let plan = install_latency(&mut state);
        assert_eq!(plan.output_frames, 6);
        assert_eq!(state.channels[&4].latency.hw_delay, 6);
        assert!(state.channels[&3].latency.post.is_none());
        let blocks = run_blocks(&mut state, &[3, 4], 12);
        assert!(peak(&blocks[3..]) < 1e-6, "{:?}", &blocks[3..]);
    }

    #[test]
    fn zero_latency_project_unchanged() {
        // Routes, a bus, and pre and post sends, no device reporting latency
        let build = || {
            let mut a = test_channel(3, Some(2), -3.0);
            a.send_channels.push(send_to(5, true));
            a.send_channels.push(send_to(5, false));
            a.pan = 0.4;
            let mut b = test_channel(4, Some(1), -6.0);
            b.send_channels.push(send_to(2, true));
            let mut state = state_with(vec![
                test_channel(1, Some(1000), 0.0),
                test_channel(2, Some(1), 0.0),
                a,
                b,
                test_channel(5, Some(1), -2.0),
            ]);
            add_test_device(state.channels.get_mut(&2).unwrap(), 0.1);
            state
        };
        let mut plain = build();
        let mut planned = build();
        let plan = install_latency(&mut planned);
        assert!(plan.channels.iter().all(|c| c.max_delay() == 0));
        assert!(planned
            .channels
            .values()
            .all(|c| c.latency.post.is_none() && c.latency.pre.is_none()));

        let expected = run_blocks(&mut plain, &[3, 4], 6);
        let actual = run_blocks(&mut planned, &[3, 4], 6);
        assert!(peak(&expected) > 0.1);
        for (e, a) in expected.iter().flatten().zip(actual.iter().flatten()) {
            assert_eq!(e.to_bits(), a.to_bits());
        }
    }

    // Virtual Stage (spec 051): the stage pass and the stage edge.

    use crate::audio::channel::PanMode;
    use crate::audio::dsp::test_util::white_noise;
    use crate::audio::stage::source::StageSource;
    use crate::audio::stage::tail::StageTail;
    use crate::audio::stage::RoomModel;

    /// Frames per block in the stage tests (the shared fixtures use 4).
    const BLOCK: usize = 256;

    fn block_channel(id: ChannelId, output: Option<ChannelId>) -> Channel {
        let mut channel = Channel::new(id, format!("Channel {id}"), BLOCK, SAMPLE_RATE);
        channel.output_channel_id = output;
        channel.volume_db = 0.0;
        channel.pan_mode = PanMode::StereoBalance;
        for _ in 0..GAIN_SETTLE_SAMPLES {
            let _ = channel.get_smoothed_gain();
        }
        channel
    }

    /// A stage source feeding `feed` (if any), with the default placement.
    fn stage_source(id: ChannelId, output: Option<ChannelId>, feed: Option<ChannelId>) -> Channel {
        let mut channel = block_channel(id, output);
        channel.pan_mode = PanMode::Stage;
        channel.stage = Some(Box::new(StageSource::new(SAMPLE_RATE, BLOCK)));
        channel.stage_feed = feed;
        channel
    }

    /// A Stage return with its tail.
    fn stage_return(id: ChannelId, output: Option<ChannelId>, room: &RoomModel) -> Channel {
        let mut channel = block_channel(id, output);
        let mut tail = StageTail::new(SAMPLE_RATE, BLOCK);
        tail.configure(room);
        channel.stage_tail = Some(Box::new(tail));
        channel
    }

    fn stage_state(channels: Vec<Channel>, room: RoomModel) -> EngineState {
        let mut state = state_with(channels);
        state.stage.room = room;
        for channel in state.channels.values_mut() {
            if let Some(source) = channel.stage.as_mut() {
                source.set_room(room);
            }
        }
        state
    }

    /// Mix one block of `BLOCK` frames; `input` (mono) is written to every stage source first
    /// because the stage pass overwrites their buffers.
    fn stage_block(state: &mut EngineState, sources: &[ChannelId], input: &[f32]) {
        // The callback clears every buffer before a block; the mix adds into them.
        for channel in state.channels.values_mut() {
            channel.clear_buffers();
        }
        for id in sources {
            let channel = state.channels.get_mut(id).unwrap();
            channel.buffer_left[..BLOCK].copy_from_slice(input);
            channel.buffer_right[..BLOCK].copy_from_slice(input);
        }
        let (status_tx, _status_rx) = unbounded();
        let mut output = vec![0.0f32; BLOCK * 2];
        mix_and_output(state, &mut output, 2, BLOCK, &status_tx);
    }

    fn block_peak(channel: &Channel) -> f32 {
        channel.buffer_left[..BLOCK]
            .iter()
            .chain(&channel.buffer_right[..BLOCK])
            .fold(0.0f32, |m, s| m.max(s.abs()))
    }

    #[test]
    fn stage_source_direct_follows_route() {
        let room = RoomModel::default();
        let build = |bus_muted: bool| {
            let mut bus = block_channel(2, Some(1));
            bus.mute = bus_muted;
            stage_state(
                vec![
                    block_channel(1, Some(1000)),
                    bus,
                    stage_source(3, Some(2), None),
                ],
                room,
            )
        };
        let noise = white_noise(BLOCK, 0.5, 11);

        let mut state = build(false);
        for _ in 0..4 {
            stage_block(&mut state, &[3], &noise);
        }
        let bus = block_peak(&state.channels[&2]);
        let master = block_peak(&state.channels[&1]);
        assert!(bus > 0.05, "the bus received no direct sound: {bus}");
        assert!(
            (master - bus).abs() < 1e-5,
            "master should carry what the bus does: {master} vs {bus}"
        );

        // With the bus muted nothing reaches master: the source doesn't route there directly.
        let mut state = build(true);
        for _ in 0..4 {
            stage_block(&mut state, &[3], &noise);
        }
        assert_eq!(block_peak(&state.channels[&1]), 0.0);
    }

    #[test]
    fn stage_return_receives_reflections() {
        let room = RoomModel::default();
        let noise = white_noise(BLOCK, 0.5, 5);
        let build = |has_room: bool, feed: Option<ChannelId>| {
            let mut source = stage_source(3, Some(1), feed);
            source.stage_params.has_room = has_room;
            stage_state(
                vec![
                    block_channel(1, Some(1000)),
                    stage_return(2, Some(1), &room),
                    source,
                ],
                room,
            )
        };
        let run = |state: &mut EngineState| {
            let mut peak = 0.0f32;
            for _ in 0..20 {
                stage_block(state, &[3], &noise);
                peak = peak.max(block_peak(&state.channels[&2]));
            }
            peak
        };

        let with_room = run(&mut build(false, Some(2)));
        assert!(
            with_room > 0.01,
            "the return got no reflections: {with_room}"
        );
        // Has room: the direct sound alone, nothing for the return.
        assert_eq!(run(&mut build(true, Some(2))), 0.0);
        // No stage edge: the return stays empty too.
        assert_eq!(run(&mut build(false, None)), 0.0);
    }

    #[test]
    fn stage_return_orders_after_its_sources() {
        // The return is ready only once every source fed it, whichever side of it the
        // channel ids fall on.
        let room = RoomModel::default();
        let noise = white_noise(BLOCK, 0.5, 9);
        let mut state = stage_state(
            vec![
                block_channel(1, Some(1000)),
                stage_source(2, Some(1), Some(9)),
                stage_return(9, Some(1), &room),
            ],
            room,
        );
        let mut peak = 0.0f32;
        for _ in 0..20 {
            stage_block(&mut state, &[2], &noise);
            peak = peak.max(block_peak(&state.channels[&9]));
            assert!(state.channels[&9].mix.done);
        }
        assert!(peak > 0.01, "{peak}");
    }

    #[test]
    fn stage_source_that_is_a_route_target_places_itself_after_its_inputs() {
        // A stage source that another channel routes into (a group) renders in the routing
        // pass, after the fader: its direct sound still reaches master.
        let room = RoomModel::default();
        let noise = white_noise(BLOCK, 0.5, 3);
        let mut state = stage_state(
            vec![
                block_channel(1, Some(1000)),
                stage_source(2, Some(1), None),
                block_channel(3, Some(2)),
            ],
            room,
        );
        assert!(state.channels[&2].stage.is_some());
        for _ in 0..4 {
            stage_block(&mut state, &[3], &noise);
        }
        assert!(state.channels[&2].mix.is_route_target);
        let master = block_peak(&state.channels[&1]);
        assert!(master > 0.05, "{master}");
        // It was placed (panned into the room), not just passed through: at the default
        // placement the level is the distance law and a centered constant-power pan, so it
        // differs from the input.
        let input_peak = noise.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!((master - input_peak).abs() > 0.01);
    }

    /// The Stage return's left buffer after each of 12 blocks. `sources` are (id, solo, mute).
    fn return_blocks(sources: &[(ChannelId, bool, bool)], fed: &[ChannelId]) -> Vec<Vec<f32>> {
        let room = RoomModel::default();
        let noise = white_noise(BLOCK, 0.5, 21);
        let mut channels = vec![
            block_channel(1, Some(1000)),
            stage_return(2, Some(1), &room),
        ];
        for &(id, solo, mute) in sources {
            let mut source = stage_source(id, Some(1), Some(2));
            // Different spots, so each source's reflections differ.
            source.stage_params.x = 4.0 + id as f32;
            source.solo = solo;
            source.mute = mute;
            channels.push(source);
        }
        let mut state = stage_state(channels, room);
        (0..12)
            .map(|_| {
                stage_block(&mut state, fed, &noise);
                state.channels[&2].buffer_left[..BLOCK].to_vec()
            })
            .collect()
    }

    #[test]
    fn solo_keeps_soloed_source_room_only() {
        // Source 3 soloed, 4 not: the return carries source 3's room and nothing of 4's.
        let both = return_blocks(&[(3, true, false), (4, false, false)], &[3, 4]);
        let alone = return_blocks(&[(3, true, false)], &[3]);
        let peak = alone.iter().flatten().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.01, "the soloed source's room is silent: {peak}");
        assert_eq!(both, alone);
        // Without the solo both rooms play, so the return differs.
        let unsoloed = return_blocks(&[(3, false, false), (4, false, false)], &[3, 4]);
        assert_ne!(unsoloed, alone);
    }

    #[test]
    fn solo_on_the_return_keeps_every_source_room() {
        // Soloing the Stage return itself keeps what feeds it, as for a soloed bus.
        let room = RoomModel::default();
        let noise = white_noise(BLOCK, 0.5, 4);
        let mut ret = stage_return(2, Some(1), &room);
        ret.solo = true;
        let mut state = stage_state(
            vec![
                block_channel(1, Some(1000)),
                ret,
                stage_source(3, Some(1), Some(2)),
            ],
            room,
        );
        let mut peak = 0.0f32;
        for _ in 0..12 {
            stage_block(&mut state, &[3], &noise);
            peak = peak.max(block_peak(&state.channels[&2]));
        }
        assert!(peak > 0.01, "{peak}");
    }

    #[test]
    fn muted_source_feeds_no_room() {
        let muted = return_blocks(&[(3, false, false), (4, false, true)], &[3, 4]);
        let alone = return_blocks(&[(3, false, false)], &[3]);
        let peak = alone.iter().flatten().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.01, "{peak}");
        assert_eq!(muted, alone);
    }

    use crate::audio::mixing::latency::{plan, LatencySignature};

    #[test]
    fn stage_edge_aligns_with_plugin_latency() {
        // Source 3 sits behind a device that delays by 300 frames, source 4 doesn't. Both feed
        // the Stage return from the same spot with the same input, so compensation must make
        // source 4 arrive 300 frames late. The reference gives both sources the device: the
        // same sound, aligned by construction.
        const DELAY: usize = 300;
        let room = RoomModel::default();
        let run = |plain_source_has_device: bool| {
            let mut channels = vec![
                block_channel(1, Some(1000)),
                stage_return(2, Some(1), &room),
            ];
            for id in [3, 4] {
                let mut source = stage_source(id, Some(1), Some(2));
                if id == 3 || plain_source_has_device {
                    source
                        .devices
                        .push(Box::new(LatencyDevice::new(DELAY, 1.0)));
                }
                channels.push(source);
            }
            let mut state = stage_state(channels, room);
            // `install_latency` sizes its rings for the 4-frame fixtures; these blocks are larger.
            let signature = LatencySignature::build(&state.channels);
            let plan = plan(&signature, SAMPLE_RATE as u32);
            for (sig, channel_plan) in signature.channels.iter().zip(&plan.channels) {
                let channel = state.channels.get_mut(&sig.id).unwrap();
                channel.latency = channel_plan.to_latency(sig, BLOCK);
            }
            let source_plan = plan.channel(4).unwrap();
            let burst = white_noise(BLOCK, 0.5, 8);
            let silence = vec![0.0f32; BLOCK];
            // Let the room crossfade that starts with the first block finish, so the sources
            // are time-invariant when the burst arrives.
            for _ in 0..24 {
                stage_block(&mut state, &[3, 4], &silence);
            }
            let mut returns = Vec::new();
            let mut masters = Vec::new();
            for block in 0..10 {
                let input = if block == 0 { &burst } else { &silence };
                stage_block(&mut state, &[3, 4], input);
                returns.push(state.channels[&2].buffer_left[..BLOCK].to_vec());
                masters.push(state.channels[&1].buffer_left[..BLOCK].to_vec());
            }
            (source_plan.stage_delay, returns, masters)
        };
        let (aligned_delay, returns, masters) = run(false);
        let (reference_delay, reference_returns, reference_masters) = run(true);
        assert_eq!(aligned_delay as usize, DELAY);
        assert_eq!(reference_delay, 0);
        let peak = reference_returns
            .iter()
            .flatten()
            .fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.01, "the reference return is silent: {peak}");
        for (name, actual, expected) in [
            ("return", &returns, &reference_returns),
            ("master", &masters, &reference_masters),
        ] {
            for (i, (a, e)) in actual
                .iter()
                .flatten()
                .zip(expected.iter().flatten())
                .enumerate()
            {
                assert!((a - e).abs() < 1e-4, "{name} frame {i}: {a} vs {e}");
            }
        }
    }

    #[test]
    fn stage_return_rings_out() {
        let room = RoomModel {
            decay_s: 0.6,
            ..RoomModel::default()
        };
        let mut state = stage_state(
            vec![
                block_channel(1, Some(1000)),
                stage_return(2, Some(1), &room),
                stage_source(3, Some(1), Some(2)),
            ],
            room,
        );
        let noise = white_noise(BLOCK, 0.5, 21);
        let silence = vec![0.0f32; BLOCK];
        // Half a second of sound, then the source falls silent.
        for _ in 0..(0.5 * SAMPLE_RATE) as usize / BLOCK {
            stage_block(&mut state, &[3], &noise);
        }
        // The return must keep producing signal (above -120 dB) for the room's decay time
        // after that.
        let mut elapsed = 0.0f32;
        let mut last_audible = 0.0f32;
        while elapsed < room.decay_s {
            stage_block(&mut state, &[3], &silence);
            elapsed += BLOCK as f32 / SAMPLE_RATE;
            if block_peak(&state.channels[&2]) > 1e-6 {
                last_audible = elapsed;
            }
        }
        assert!(
            last_audible >= room.decay_s,
            "the return went quiet {last_audible} s after the source stopped (decay {} s)",
            room.decay_s
        );
    }
}
