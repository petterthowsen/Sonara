//! Mixing: fader and pan, routing in dependency order, and the master output.

pub mod latency;
pub mod midi_send;
mod pool;
mod routing;
pub mod sidechain;
mod solo;
#[cfg(test)]
pub(crate) mod test_support;

use std::collections::{HashMap, VecDeque};
use std::time::Instant;

use crossbeam::channel::Sender;

use super::channel::{elapsed_ns, Channel};
use super::commands::EngineStatus;
use super::devices::container::{self, ChainStep};
use super::render_scratch::RenderScratch;
use super::rt_debug;
use super::state::EngineState;
use super::types::*;

pub use pool::ChannelPool;

use routing::{
    begin_finish, chain_start, copy_pre_fader, count_route_inputs, drain_parked, mark_aux_sources,
    process_aux_sources, route_finished, runs_on_finish,
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
/// the command thread (`CommandWorker::poll_devices`), not here. Data streams are drained with
/// up to [`DATA_FRAMES_PER_BLOCK`] polls per device, one frame per data type: a `ModulatedDevice`
/// answers for its own `modulation` stream and its wrapped device's streams (`spectrum`,
/// `dynamics`) in the same block, and a stream that answers every poll (`note_state`) must not
/// mask the others or spin the drain.
/// Data frames forwarded per device per block (one per data type).
const DATA_FRAMES_PER_BLOCK: usize = 4;

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
        // Every due stream, one frame per data type per block (see `forward_device_events`).
        let mut seen: [([u8; 16], usize); DATA_FRAMES_PER_BLOCK] =
            [([0; 16], 0); DATA_FRAMES_PER_BLOCK];
        let mut seen_count = 0usize;
        for _ in 0..DATA_FRAMES_PER_BLOCK {
            let data = rt_debug::section("poll_device_data", || device.poll_device_data());
            let Some((data_type, data)) = data else { break };
            let name = data_type.as_bytes();
            if name.len() <= 16 {
                let duplicate = seen[..seen_count]
                    .iter()
                    .any(|(stored, len)| name.len() == *len && name == &stored[..*len]);
                if duplicate {
                    // The same stream answered twice: it emits one frame per poll, so
                    // everything due was drained.
                    break;
                }
                let (stored, len) = &mut seen[seen_count];
                stored[..name.len()].copy_from_slice(name);
                *len = name.len();
                seen_count += 1;
            }
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
/// order (route targets run their devices and pan once, after all their inputs), hardware
/// output (every channel routed to a hardware pair, master included). Uses only preallocated
/// buffers.
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
        sc_taps,
        perf_timing,
        device_sample_rate,
        pool,
        midi_sends,
        ..
    } = state;
    let timing = *perf_timing;
    let RenderScratch {
        channel_ids,
        parked,
        ready,
        jobs,
        job_parks,
        midi_forward,
        midi_forward_cc,
        ..
    } = render_scratch;
    let mut pooled = PooledPass {
        pool: pool.as_ref().filter(|pool| pool.threads() > 0),
        jobs,
        job_parks,
    };

    // Cross-channel MIDI first: a send's targets must have their notes before they render.
    midi_send::forward(
        channel_map,
        midi_sends,
        midi_forward,
        midi_forward_cc,
        frames,
    );

    let has_solo = channel_map.values().any(|c| c.solo);
    for channel in channel_map.values_mut() {
        channel.mix.timing = timing;
    }
    channel_ids.clear();
    channel_ids.extend(channel_map.keys().copied());
    // HashMap order differs per instance; sort so summation order is deterministic. In place,
    // no allocation.
    channel_ids.sort_unstable();

    count_route_inputs(channel_map, channel_ids);
    assign_solo_roles(channel_map, channel_ids, has_solo);
    mark_aux_sources(channel_map, channel_ids);

    // Aux source pass: generate extra device buses into child channel buffers before
    // those children run their own device chains. Route-target parents skip the
    // normal pre-pass so remaining FX wait until children mix back in.
    process_aux_sources(channel_map, channel_ids, frames, status_tx);

    device_prepass(
        channel_map,
        channel_ids,
        parked,
        &mut pooled,
        frames,
        status_tx,
    );

    // Pre-fader sends take the device output before the fader. Route targets copy theirs in
    // the routing pass, once their inputs have mixed in and their devices have run.
    for channel in channel_map.values_mut() {
        if !channel.mix.is_route_target {
            copy_pre_fader(channel, frames);
        }
    }

    apply_fader_and_pan(channel_map, frames);

    route_in_dependency_order(
        channel_map,
        channel_ids,
        parked,
        ready,
        &mut pooled,
        frames,
        status_tx,
    );

    write_hardware_outputs(channel_map, data, channels);

    midi_send::clear_dispatched(channel_map, midi_sends);

    // The sidechain taps read the final post-fader buffers (spec 036 D8); the next callback
    // feeds them before its device passes run.
    sc_taps.snapshot(channel_map, frames);

    if timing && *device_sample_rate > 0.0 {
        let block_ns = (frames as f64 * 1e9 / *device_sample_rate as f64) as u64;
        for channel in channel_map.values_mut() {
            channel.mix.timer.end_block(block_ns);
        }
    }
}

/// The worker pool for one buffer, with its preallocated job lists.
struct PooledPass<'a> {
    /// `None` when there are no workers: chains run on the callback thread as before.
    pool: Option<&'a ChannelPool>,
    jobs: &'a mut Vec<usize>,
    job_parks: &'a mut VecDeque<usize>,
}

impl PooledPass<'_> {
    /// Run the chains of the channels in `ids` that `runs` accepts on the pool, then forward
    /// their device events in `ids` order. False, with nothing run, when there are no workers or
    /// fewer than 2 such chains: the caller takes the single-thread path.
    fn run(
        &mut self,
        channel_map: &mut HashMap<ChannelId, Channel>,
        ids: &[ChannelId],
        runs: impl Fn(&Channel) -> bool,
        frames: usize,
        status_tx: &Sender<EngineStatus>,
    ) -> bool {
        let Some(pool) = self.pool else {
            return false;
        };
        self.jobs.clear();
        for id in ids {
            if let Some(channel) = channel_map.get_mut(id).filter(|c| runs(c)) {
                self.jobs.push(channel as *mut Channel as usize);
            }
        }
        if self.jobs.len() < 2 {
            return false;
        }
        // The map isn't touched until `run_jobs` returns (see `PoolShared`).
        pool.run_jobs(self.jobs, self.job_parks, frames);
        for id in ids {
            if let Some(channel) = channel_map.get_mut(id).filter(|c| runs(c)) {
                forward_device_events(channel, status_tx);
            }
        }
        true
    }
}

/// First pass: begin and finish the device chains of channels nothing routes into.
///
/// Reads: `mix.is_route_target`, `mix.has_aux_source`. Writes: channel buffers and device
/// state through the chains, `parked`, and the device events sent on `status_tx`.
fn device_prepass(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    parked: &mut VecDeque<ChannelId>,
    pooled: &mut PooledPass,
    frames: usize,
    status_tx: &Sender<EngineStatus>,
) {
    // Route targets are skipped; they run in the routing pass after their inputs mix in.
    let runs = |channel: &Channel| !channel.mix.is_route_target;
    if pooled.run(channel_map, channel_ids, runs, frames, status_tx) {
        return;
    }
    // First pass: process device chains (instruments and effects) before the fader.
    // Every chain starts first; a chain that reaches a plugin parks there while the plugin
    // processes in its host, so plugins on different channels (and hosts) run in parallel and
    // built-in-only chains run on this thread meanwhile. Then the parked chains are finished.
    parked.clear();
    for &id in channel_ids.iter() {
        let Some(channel) = channel_map.get_mut(&id).filter(|c| runs(c)) else {
            continue;
        };
        match channel.begin_device_chain(chain_start(channel), frames) {
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
    // "post-fader" for metering. Route targets (buses, master) fade and pan in the routing pass, after their devices.
    // Silent channels are cleared. Send-only sources keep their buffer for sends to a soloed bus.
    for channel in channel_map.values_mut() {
        let started = channel.mix.timing.then(Instant::now);
        if is_silenced(channel) {
            channel.clear_buffers();
        } else if !channel.mix.is_route_target {
            // Route targets apply their fader after their devices (`route_finished`).
            fader_and_pan(channel, frames);
        }
        if let Some(started) = started {
            channel.mix.timer.add(elapsed_ns(started));
        }
    }
}

/// Apply the smoothed fader gain and the pan matrix to one channel's buffer.
fn fader_and_pan(channel: &mut Channel, frames: usize) {
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

/// Third pass: finish channels in dependency order, mixing each into its route and sends.
///
/// Reads and writes the whole `mix` scratch of every channel (`pending_inputs`, `done`) plus
/// buffers and device state; `ready` and `parked` are preallocated scratch.
fn route_in_dependency_order(
    channel_map: &mut HashMap<ChannelId, Channel>,
    channel_ids: &[ChannelId],
    parked: &mut VecDeque<ChannelId>,
    ready: &mut Vec<ChannelId>,
    pooled: &mut PooledPass,
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

        if pooled.pool.is_some() {
            for &id in ready.iter() {
                if let Some(channel) = channel_map.get_mut(&id) {
                    channel.mix.done = true;
                }
            }
        }
        if !pooled.run(channel_map, ready, runs_on_finish, frames, status_tx) {
            parked.clear();
            for &id in ready.iter() {
                begin_finish(channel_map, id, frames, parked, status_tx);
            }
            drain_parked(channel_map, parked, frames, status_tx);
        }
        for &id in ready.iter() {
            route_finished(channel_map, id, frames);
        }
        remaining = remaining.saturating_sub(ready.len());
    }
}

/// Write every channel routed to a hardware output to its pair: 1000 is outputs 1/2, 1001 is
/// 3/4, and so on. Any channel may route straight to a pair (a reference track that skips
/// master's effects); channels routing into another channel mix there instead, as usual.
///
/// The audio is post-fader and post-pan (master's fader was applied while its inputs mixed in),
/// and channels sharing a pair accumulate. The buffer is cleared first: CPAL reuses it, and
/// pairs nothing writes must be silent. A pair the device doesn't have plays on 1/2 (the
/// command thread warns about it).
fn write_hardware_outputs(
    channel_map: &HashMap<ChannelId, Channel>,
    data: &mut [f32],
    channels: usize,
) {
    data.fill(0.0);
    if channels == 0 {
        return;
    }
    let pairs = (channels / 2).max(1);
    let data_frames = data.len() / channels;

    for channel in channel_map.values() {
        let Some(output_id) = channel
            .output_channel_id
            .filter(|&id| id >= HARDWARE_OUTPUT_BASE)
        else {
            continue;
        };
        let pair = output_id - HARDWARE_OUTPUT_BASE;
        let first = if pair < pairs { pair * 2 } else { 0 };
        let frames = data_frames
            .min(channel.buffer_left.len())
            .min(channel.buffer_right.len());
        let delay = channel.latency.hw_delay as usize;
        let ring = channel.latency.post.as_ref().filter(|_| delay > 0);
        for frame_idx in 0..frames {
            // A delayed write reads the post ring `route_finished` filled this block
            let (left, right) = match ring {
                Some(ring) => ring.sample(delay, frames, frame_idx),
                None => (
                    channel.buffer_left[frame_idx],
                    channel.buffer_right[frame_idx],
                ),
            };
            let left = left.clamp(-1.0, 1.0);
            let right = right.clamp(-1.0, 1.0);
            let base = frame_idx * channels;
            if channels >= 2 {
                data[base + first] = (data[base + first] + left).clamp(-1.0, 1.0);
                data[base + first + 1] = (data[base + first + 1] + right).clamp(-1.0, 1.0);
            } else {
                data[base] = (data[base] + (left + right) * 0.5).clamp(-1.0, 1.0);
                // Mono mix
            }
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
    fn timing_off_records_nothing() {
        use crate::audio::channel::{ChannelTimer, DeviceTimer};

        let mut track = test_channel(2, Some(1), 0.0);
        add_test_device(&mut track, 0.1);
        let mut state = state_with(vec![test_channel(1, Some(1000), 0.0), track]);

        mix(&mut state);
        for channel in state.channels.values() {
            assert_eq!(
                channel.mix.timer,
                ChannelTimer::default(),
                "channel {}",
                channel.id
            );
            assert!(channel
                .device_timers
                .iter()
                .all(|t| *t == DeviceTimer::default()));
        }

        // Switched on, the same block is counted once per channel and once for the device.
        state.perf_timing = true;
        mix(&mut state);
        for channel in state.channels.values() {
            assert_eq!(channel.mix.timer.blocks, 1, "channel {}", channel.id);
            assert_eq!(channel.mix.timer.current_ns, 0, "block closed");
        }
        assert_eq!(state.channels[&2].device_timers[0].blocks, 1);
        assert_eq!(
            state.channels[&1].device_timers[0].blocks, 0,
            "master has no device"
        );
    }

    #[test]
    fn channel_ids_are_sorted() {
        let channels = [40, 7, 2, 1, 300, 15, 9, 1000, 63, 5]
            .iter()
            .map(|&id| test_channel(id, Some(1), 0.0))
            .collect();
        let mut state = state_with(channels);
        mix(&mut state);
        let ids = &state.render_scratch.channel_ids;
        assert_eq!(ids.len(), 10);
        assert!(ids.windows(2).all(|w| w[0] < w[1]), "{:?}", ids);
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
    fn channel_routed_to_hardware_bypasses_master() {
        // A reference track straight to outputs 3/4 while master's device colors 1/2.
        let mut reference = test_channel(2, Some(1001), 0.0);
        reference.buffer_left.fill(0.5);
        reference.buffer_right.fill(0.25);
        let mut master = test_channel(1, Some(1000), 0.0);
        add_test_device(&mut master, 0.25);
        let output = mix_to_device(&mut state_with(vec![master, reference]), 4);
        for frame in output.chunks(4) {
            // Master: silent input plus its device's level, on 1/2.
            assert!((frame[0] - 0.25).abs() < 1e-4, "{:?}", frame);
            assert!((frame[1] - 0.25).abs() < 1e-4, "{:?}", frame);
            // Reference: untouched by master's device, on 3/4.
            assert!((frame[2] - 0.5).abs() < 1e-4, "{:?}", frame);
            assert!((frame[3] - 0.25).abs() < 1e-4, "{:?}", frame);
        }
    }

    #[test]
    fn channels_on_the_same_hardware_pair_accumulate() {
        let mut first = test_channel(2, Some(1000), 0.0);
        first.buffer_left.fill(0.25);
        first.buffer_right.fill(0.25);
        let mut second = test_channel(3, Some(1000), 0.0);
        second.buffer_left.fill(0.5);
        let output = mix_to_device(&mut state_with(vec![first, second]), 2);
        assert!((output[0] - 0.75).abs() < 1e-4, "{:?}", output);
        assert!((output[1] - 0.25).abs() < 1e-4, "{:?}", output);
    }

    #[test]
    fn solo_elsewhere_leaves_a_direct_output_channel_playing() {
        // A reference channel keeps playing when another channel is soloed: it does not
        // reach master, so solo would otherwise silence it.
        let mut reference = test_channel(2, Some(1000), 0.0);
        reference.buffer_left.fill(0.5);
        reference.buffer_right.fill(0.25);
        let mut soloed = test_channel(3, Some(1), 0.0);
        soloed.solo = true;
        let master = test_channel(1, Some(1000), 0.0);
        let output = mix_to_device(&mut state_with(vec![master, reference, soloed]), 2);
        assert!((output[0] - 0.5).abs() < 1e-4, "{:?}", output);
    }
    #[test]
    fn master_without_a_hardware_output_leaves_silence() {
        // CPAL reuses its buffer, so not writing it would replay old samples.
        let output = mix_to_device(&mut master_to(0), 2);
        assert!(output.iter().all(|&sample| sample == 0.0), "{:?}", output);
    }

    #[test]
    fn every_due_data_stream_is_drained_each_block() {
        use crate::audio::devices::{create_effect, DevicePath};
        use crate::audio::dsp::test_util::{stereo, white_noise};
        use crate::audio::modulation::{wrap_at_path, ModulatorKind};

        /// A channel with one (optionally modulated) EQ subscribed to `spectrum`, driven for
        /// `frames` in 512-frame blocks with `forward_device_events` after each block, as the
        /// mixer does. Returns the `(spectrum, modulation)` frame counts.
        fn run(frames: usize, with_modulator: bool) -> (usize, usize) {
            let (tx, rx) = unbounded();
            let mut channel = test_channel(2, Some(1000), 0.0);
            channel
                .devices
                .push(create_effect("sonara.builtin.eq", SAMPLE_RATE, 4_096).expect("eq"));
            if with_modulator {
                wrap_at_path(&mut channel.devices, &DevicePath::root(0), SAMPLE_RATE)
                    .expect("wrap");
                channel.devices[0]
                    .as_modulated_mut()
                    .expect("wrapped")
                    .add_modulator(0, ModulatorKind::Lfo)
                    .expect("modulator");
                channel.devices[0]
                    .subscribe_data("modulation")
                    .expect("modulation");
            }
            channel.devices[0]
                .subscribe_data("spectrum")
                .expect("spectrum");

            let input = stereo(&white_noise(frames, 0.3, 7));
            let (mut spectrum, mut modulation) = (0usize, 0usize);
            for block in input.chunks(512 * 2) {
                let mut out = vec![0.0; block.len()];
                channel.devices[0].process_block(block, &mut out, block.len() / 2);
                forward_device_events(&mut channel, &tx);
                while let Ok(status) = rx.try_recv() {
                    if let EngineStatus::DeviceData { data_type, .. } = status {
                        match data_type.as_str() {
                            "spectrum" => spectrum += 1,
                            "modulation" => modulation += 1,
                            _ => {}
                        }
                    }
                }
            }
            (spectrum, modulation)
        }

        // 20 blocks of 512 frames at 48 kHz: the EQ emits a frame every 800 frames (every
        // other block), the wrapper every 2400 (every fifth), so blocks 10 and 20 have both
        // due and a single poll per block drops one of the two.
        let frames = 512 * 20;
        let (baseline, _) = run(frames, false);
        let (spectrum, modulation) = run(frames, true);
        assert!(
            baseline >= 5,
            "expected several spectrum frames, got {baseline}"
        );
        assert_eq!(
            spectrum, baseline,
            "the wrapped EQ's spectrum stream lost frames to the modulation stream: \
             {spectrum} vs {baseline} (modulation frames: {modulation})"
        );
        assert!(
            modulation >= 3,
            "the wrapper's modulation stream starved: {modulation}"
        );
    }
}
