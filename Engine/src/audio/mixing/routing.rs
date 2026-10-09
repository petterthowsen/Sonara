//! Routing: sends, route targets, pan, pre-fader copies, parked device chains, aux sources and
//! extra outputs.

use std::collections::{HashMap, VecDeque};

use crossbeam::channel::Sender;

use crate::audio::channel::{fader_gain, Channel};
use crate::audio::commands::EngineStatus;
use crate::audio::devices::container::ChainStep;
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

/// Apply the channel's pan matrix to its own buffers.
pub(super) fn apply_pan(channel: &mut Channel, frames: usize) {
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
        let gain = fader_gain(send.amount_db) * target.get_gain();
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
    if !channel.mix.is_route_target || channel.mute {
        return;
    }
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

/// Complete a channel after its device chain finished: route targets apply their pan (silenced
/// ones are cleared), then the channel routes onward.
pub(super) fn route_finished(
    channel_map: &mut HashMap<ChannelId, Channel>,
    id: ChannelId,
    frames: usize,
) {
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
    use crate::audio::devices::{
        AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
    };
    use crate::audio::mixing::mix_and_output;
    use crate::audio::mixing::test_support::*;
    use crate::audio::state::EngineState;
    use crossbeam::channel::unbounded;
    use std::sync::atomic::{AtomicUsize, Ordering};
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

    /// Device that writes 0.4 to the main out and 0.8 to extra bus 0, counting its blocks.
    #[derive(Default)]
    struct TestAuxDevice {
        calls: Arc<AtomicUsize>,
    }

    impl AudioDevice for TestAuxDevice {
        fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            self.calls.fetch_add(1, Ordering::Relaxed);
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

        let gain = fader_gain(-6.0);
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
}
