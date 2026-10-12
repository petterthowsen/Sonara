//! The 500 ms perf report (spec 042): the channel and device timers the audio callback fills
//! while a perf subscriber is listening, collected and reset under the state lock.

use std::time::{Duration, Instant};

use super::CommandWorker;
use crate::audio::channel::MAX_TIMED_DEVICES;
use crate::audio::commands::EngineStatus;
use crate::audio::state::EngineState;

/// How often `ChannelPerf` and `EnginePerf` are sent while subscribed.
const PERF_REPORT_INTERVAL: Duration = Duration::from_millis(500);

impl CommandWorker {
    /// Send the perf statuses when the interval is up and a subscriber is listening.
    ///
    /// The timers are taken under the state lock into a reused Vec; the statuses are sent after
    /// the lock is released, like every other status.
    pub(super) fn report_perf(&mut self) {
        let now = Instant::now();
        if now.duration_since(self.perf_since) < PERF_REPORT_INTERVAL {
            return;
        }
        self.perf_since = now;
        let mut statuses = std::mem::take(&mut self.perf_statuses);
        {
            let mut state = self.lock_state();
            collect_perf(&mut state, &mut statuses);
        }
        for status in statuses.drain(..) {
            self.send_status(status);
        }
        self.perf_statuses = statuses;
    }
}

/// Take every channel's timers and push a `ChannelPerf` for each channel that ran, then one
/// `EnginePerf`. Pushes nothing while nobody is subscribed. A removed channel is no longer in
/// the map, so it drops out of the reports.
fn collect_perf(state: &mut EngineState, out: &mut Vec<EngineStatus>) {
    if state.perf_subscribers == 0 {
        return;
    }
    for (&channel_id, channel) in state.channels.iter_mut() {
        let timer = channel.mix.timer.take();
        let timed = channel.devices.len().min(MAX_TIMED_DEVICES);
        // Always take the device timers, even when the channel didn't run, so none go stale.
        let mut devices = Vec::with_capacity(timed);
        let block_ns = timer.block_ns as f32;
        let mean_block_ns = if timer.blocks > 0 {
            block_ns / timer.blocks as f32
        } else {
            0.0
        };
        for device in channel.device_timers.iter_mut().take(timed) {
            let device = device.take();
            let avg = if timer.block_ns > 0 {
                device.total_ns as f32 / block_ns
            } else {
                0.0
            };
            let peak = if mean_block_ns > 0.0 {
                device.peak_ns as f32 / mean_block_ns
            } else {
                0.0
            };
            devices.push((avg, peak));
        }
        if timer.blocks == 0 {
            continue;
        }
        out.push(EngineStatus::ChannelPerf {
            channel_id,
            load_avg: timer.load_avg(),
            load_peak: timer.peak_load,
            out_latency_frames: channel.latency.out_frames,
            devices,
        });
    }
    // The callback thread counts as the first processing thread.
    let (processing_threads, threads_realtime) = match &state.pool {
        Some(pool) => (pool.threads() as u32 + 1, pool.realtime_summary()),
        None => (1, "none"),
    };
    out.push(EngineStatus::EnginePerf {
        processing_threads,
        threads_realtime: threads_realtime.to_string(),
        output_latency_frames: state.output_latency_frames,
        over_limit_channels: state.latency_over_limit,
        sample_rate: state.device_sample_rate as u32,
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::channel::Channel;
    use crate::audio::devices::create_effect;

    fn state_with_channels(ids: &[usize]) -> EngineState {
        let mut state = EngineState::default();
        for &id in ids {
            let mut channel = Channel::new(id, format!("ch{id}"), 64, 48_000.0);
            channel.mix.timer.current_ns = 100_000;
            channel.mix.timer.end_block(1_000_000);
            state.channels.insert(id, channel);
        }
        state
    }

    fn channel_ids(out: &[EngineStatus]) -> Vec<usize> {
        let mut ids: Vec<usize> = out
            .iter()
            .filter_map(|s| match s {
                EngineStatus::ChannelPerf { channel_id, .. } => Some(*channel_id),
                _ => None,
            })
            .collect();
        ids.sort();
        ids
    }

    #[test]
    fn perf_report_drops_removed_channels() {
        let mut state = state_with_channels(&[2, 3]);
        let mut out = Vec::new();

        // Nobody subscribed: nothing is sent, and the timers are left alone.
        collect_perf(&mut state, &mut out);
        assert!(out.is_empty());
        assert_eq!(state.channels[&2].mix.timer.blocks, 1);

        state.set_perf_subscription(true);
        assert_eq!(
            state.channels[&2].mix.timer.blocks, 0,
            "subscribing starts from clean timers"
        );
        for id in [2, 3] {
            let channel = state.channels.get_mut(&id).unwrap();
            channel.mix.timer.current_ns = 100_000;
            channel.mix.timer.end_block(1_000_000);
        }
        state.channels.remove(&3);

        collect_perf(&mut state, &mut out);
        assert_eq!(channel_ids(&out), vec![2]);
        assert!(matches!(
            out.last(),
            Some(EngineStatus::EnginePerf {
                sample_rate: 48_000,
                ..
            })
        ));
        match &out[0] {
            EngineStatus::ChannelPerf {
                load_avg,
                load_peak,
                ..
            } => {
                assert!((load_avg - 0.1).abs() < 1e-6);
                assert!((load_peak - 0.1).abs() < 1e-6);
            }
            other => panic!("expected ChannelPerf, got {other:?}"),
        }

        // The report reset the timers, so a channel that didn't run is not reported again.
        out.clear();
        collect_perf(&mut state, &mut out);
        assert!(channel_ids(&out).is_empty());
        assert_eq!(out.len(), 1, "EnginePerf still goes out");
    }

    #[test]
    fn perf_subscription_is_counted() {
        let mut state = EngineState::default();
        state.set_perf_subscription(true);
        state.set_perf_subscription(true);
        assert!(state.perf_timing);
        state.set_perf_subscription(false);
        assert!(state.perf_timing, "one subscriber remains");
        assert_eq!(state.perf_subscribers, 1);
        state.set_perf_subscription(false);
        assert!(!state.perf_timing);
        state.set_perf_subscription(false);
        assert_eq!(state.perf_subscribers, 0, "saturates at 0");
        assert!(!state.perf_timing);
    }

    #[test]
    fn perf_report_device_shares_of_block_time() {
        let mut state = state_with_channels(&[2]);
        state.set_perf_subscription(true);
        let channel = state.channels.get_mut(&2).unwrap();
        channel
            .devices
            .push(create_effect("sonara.builtin.delay", 48_000.0, 64).unwrap());
        // Two 1 ms blocks; the device ran in one of them (it slept in the other).
        for _ in 0..2 {
            channel.mix.timer.current_ns = 200_000;
            channel.mix.timer.end_block(1_000_000);
        }
        channel.device_timers[0].add(150_000);

        let mut out = Vec::new();
        collect_perf(&mut state, &mut out);
        match &out[0] {
            EngineStatus::ChannelPerf { devices, .. } => {
                assert_eq!(devices.len(), 1);
                assert!((devices[0].0 - 0.075).abs() < 1e-6, "{devices:?}");
                assert!((devices[0].1 - 0.15).abs() < 1e-6, "{devices:?}");
            }
            other => panic!("expected ChannelPerf, got {other:?}"),
        }
    }
}
