//! Latency compensation upkeep (spec 042 part D): replan when the graph or a device's latency
//! changes, and install each channel's delays and rings.
//!
//! Every poll builds a `LatencySignature` under the lock and compares it with the last one, so
//! routing edits, added or removed devices and plugins whose latency changed are all picked up
//! without hooking each command. Rings are allocated outside the lock and swapped in under it.
//! A channel whose rings still fit keeps them, so its delay history (and its audio) carries on
//! across a replan that didn't touch it.

use std::collections::HashSet;
use std::sync::Mutex;

use tracing::{info, warn};

use super::CommandWorker;
use crate::audio::channel::ChannelLatency;
use crate::audio::dsp::block_delay::StereoBlockDelay;
use crate::audio::mixing::latency::{plan, LatencyPlan, LatencySignature};
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;

/// What the installed plan was built from.
#[derive(Default)]
pub(super) struct LatencyStatus {
    signature: LatencySignature,
    sample_rate: f32,
    output_frames: u32,
    over_limit: HashSet<ChannelId>,
}

impl CommandWorker {
    /// Replan and install the compensation if the signature or the rate changed since the last
    /// call. Runs every device poll and after a rate change.
    pub(super) fn refresh_latency(&mut self) {
        refresh(&self.state, &mut self.latency, self.max_buffer_size);
    }
}

/// `refresh_latency` over the shared state. Returns the new plan if it replanned.
fn refresh(
    state: &Mutex<EngineState>,
    status: &mut LatencyStatus,
    max_block: usize,
) -> Option<LatencyPlan> {
    let lock = || {
        state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    };
    let (signature, sample_rate) = {
        let mut state = lock();
        let rate = state.device_sample_rate;
        let signature = LatencySignature::build(&state.channels);
        if signature == status.signature && rate == status.sample_rate {
            return None;
        }
        // Something changed: let containers resize their branch delays, which can change what
        // they report, then read the graph again.
        for channel in state.channels.values_mut() {
            for device in channel.devices.iter_mut() {
                device.update_latency(rate);
            }
        }
        (LatencySignature::build(&state.channels), rate)
    };

    let plan = plan(&signature, sample_rate.max(1.0) as u32);
    let mut latencies: Vec<(ChannelId, ChannelLatency)> = plan
        .channels
        .iter()
        .zip(&signature.channels)
        .map(|(channel_plan, channel_signature)| {
            (
                channel_plan.id,
                channel_plan.to_latency(channel_signature, max_block),
            )
        })
        .collect();
    install(&mut lock(), &plan, &mut latencies, max_block);
    // `latencies` now holds the replaced state and the unused new rings
    drop(latencies);

    report(status, &plan);
    *status = LatencyStatus {
        signature,
        sample_rate,
        output_frames: plan.output_frames,
        over_limit: plan.over_limit.iter().copied().collect(),
    };
    Some(plan)
}

/// Log a change of the output latency, and warn once for each channel that newly went over the
/// limit (REQ-017).
fn report(previous: &LatencyStatus, plan: &LatencyPlan) {
    if plan.output_frames != previous.output_frames {
        info!(
            "Latency compensation: {} frames before output",
            plan.output_frames
        );
    }
    for id in &plan.over_limit {
        if !previous.over_limit.contains(id) {
            warn!("Channel {id}: plugin latency exceeds 1 s; compensation is capped at 1 s");
        }
    }
}

/// Under the lock: swap each channel's new `ChannelLatency` in, leaving the old one in
/// `latencies` to drop after unlocking. Rings that still fit are moved over instead of replaced.
fn install(
    state: &mut EngineState,
    plan: &LatencyPlan,
    latencies: &mut [(ChannelId, ChannelLatency)],
    max_block: usize,
) {
    for (id, latency) in latencies.iter_mut() {
        let Some(channel) = state.channels.get_mut(id) else {
            continue;
        };
        let old = &mut channel.latency;
        let needed = latency
            .send_delays
            .iter()
            .copied()
            .chain([latency.route_delay, latency.hw_delay])
            .max()
            .unwrap_or(0) as usize;
        keep_ring(&mut old.post, &mut latency.post, needed, max_block);
        keep_ring(&mut old.pre, &mut latency.pre, needed, max_block);
        std::mem::swap(old, latency);
    }
    state.output_latency_frames = plan.output_frames;
    state.latency_over_limit = plan.over_limit.len() as u32;
}

/// If the new plan wants a ring and the old one reaches `needed` frames back, swap them so the
/// old ring (and its history) stays installed and the new allocation is dropped instead.
fn keep_ring(
    old: &mut Option<StereoBlockDelay>,
    new: &mut Option<StereoBlockDelay>,
    needed: usize,
    max_block: usize,
) {
    if new.is_some()
        && old
            .as_ref()
            .is_some_and(|ring| ring.max_delay(max_block) >= needed)
    {
        std::mem::swap(old, new);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::channel::Channel;
    use crate::audio::mixing::test_support::LatencyDevice;
    use crate::audio::types::HARDWARE_OUTPUT_BASE;

    const BLOCK: usize = 64;

    /// Master to the first hardware pair, and tracks 2 and 3 into master.
    fn state() -> Mutex<EngineState> {
        let mut state = EngineState::default();
        state.device_sample_rate = 48_000.0;
        for (id, output) in [(1, HARDWARE_OUTPUT_BASE), (2, 1), (3, 1)] {
            let mut channel = Channel::new(id, format!("ch{id}"), BLOCK, 48_000.0);
            channel.output_channel_id = Some(output);
            state.channels.insert(id, channel);
        }
        Mutex::new(state)
    }

    fn add_latency(state: &Mutex<EngineState>, id: ChannelId, frames: usize) {
        let mut state = state.lock().unwrap();
        let channel = state.channels.get_mut(&id).unwrap();
        channel
            .devices
            .push(Box::new(LatencyDevice::new(frames, 1.0)));
    }

    #[test]
    fn adding_a_latency_device_replans_in_one_refresh() {
        let state = state();
        let mut status = LatencyStatus::default();
        assert!(refresh(&state, &mut status, BLOCK).is_some());
        assert!(
            refresh(&state, &mut status, BLOCK).is_none(),
            "nothing changed"
        );
        assert_eq!(state.lock().unwrap().channels[&3].latency.route_delay, 0);

        add_latency(&state, 2, 300);
        assert!(refresh(&state, &mut status, BLOCK).is_some());
        let state = state.lock().unwrap();
        assert_eq!(state.channels[&2].latency.out_frames, 300);
        assert_eq!(state.channels[&3].latency.route_delay, 300);
        assert!(state.channels[&3].latency.post.is_some());
        assert!(state.channels[&2].latency.post.is_none());
        assert_eq!(state.channels[&1].latency.out_frames, 300);
        assert_eq!(state.output_latency_frames, 300);
        assert_eq!(state.latency_over_limit, 0);
    }

    #[test]
    fn a_replan_keeps_rings_that_still_fit() {
        let state = state();
        let mut status = LatencyStatus::default();
        add_latency(&state, 2, 300);
        refresh(&state, &mut status, BLOCK);
        {
            let mut state = state.lock().unwrap();
            let ring = state
                .channels
                .get_mut(&3)
                .unwrap()
                .latency
                .post
                .as_mut()
                .unwrap();
            ring.write(&[0.5; BLOCK], &[0.25; BLOCK], BLOCK);
        }

        // A new channel elsewhere changes the signature but not track 3's delay
        {
            let mut state = state.lock().unwrap();
            let mut channel = Channel::new(4, "ch4".into(), BLOCK, 48_000.0);
            channel.output_channel_id = Some(1);
            state.channels.insert(4, channel);
        }
        assert!(refresh(&state, &mut status, BLOCK).is_some());
        let state = state.lock().unwrap();
        let ring = state.channels[&3].latency.post.as_ref().unwrap();
        assert_eq!(ring.sample(0, BLOCK, 0), (0.5, 0.25), "history kept");
        assert_eq!(state.channels[&4].latency.route_delay, 300);
    }

    #[test]
    fn over_limit_latency_is_capped_and_counted() {
        let state = state();
        let mut status = LatencyStatus::default();
        add_latency(&state, 2, 60_000);
        refresh(&state, &mut status, BLOCK);
        let state = state.lock().unwrap();
        assert_eq!(state.latency_over_limit, 1);
        assert_eq!(state.channels[&2].latency.out_frames, 48_000);
        assert_eq!(state.channels[&3].latency.route_delay, 48_000);
    }

    #[test]
    fn a_rate_change_replans() {
        let state = state();
        let mut status = LatencyStatus::default();
        add_latency(&state, 2, 60_000);
        refresh(&state, &mut status, BLOCK);
        state.lock().unwrap().device_sample_rate = 96_000.0;
        assert!(refresh(&state, &mut status, BLOCK).is_some());
        let state = state.lock().unwrap();
        assert_eq!(state.latency_over_limit, 0);
        assert_eq!(state.channels[&3].latency.route_delay, 60_000);
    }

    /// A plugin's `LatencyChanged` only updates what the adapter reports; the next refresh must
    /// replan from it.
    #[test]
    fn a_device_latency_change_replans() {
        let state = state();
        let mut status = LatencyStatus::default();
        add_latency(&state, 2, 100);
        refresh(&state, &mut status, BLOCK);
        assert_eq!(state.lock().unwrap().channels[&3].latency.route_delay, 100);

        {
            let mut state = state.lock().unwrap();
            let device = state.channels.get_mut(&2).unwrap().devices[0]
                .as_any_mut()
                .downcast_mut::<LatencyDevice>()
                .unwrap();
            device.delay = 2048;
        }
        assert!(refresh(&state, &mut status, BLOCK).is_some());
        let state = state.lock().unwrap();
        assert_eq!(state.channels[&3].latency.route_delay, 2048);
        assert_eq!(state.output_latency_frames, 2048);
    }
}
