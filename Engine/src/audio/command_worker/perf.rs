//! The 500 ms perf report (spec 042): the channel and device timers the audio callback fills
//! while a perf subscriber is listening, collected and reset under the state lock.

use std::time::{Duration, Instant};

use super::CommandWorker;
use crate::audio::channel::MAX_TIMED_DEVICES;
use crate::audio::commands::EngineStatus;
use crate::audio::devices::clap_host::SubprocessClapAdapter;
use crate::audio::devices::{container, DevicePath};
use crate::audio::proc_mem::MemorySampler;
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;

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
        let mut probes = std::mem::take(&mut self.memory_probes);
        {
            let mut state = self.lock_state();
            collect_perf(&mut state, &mut statuses);
            collect_memory_probes(&mut state, &mut probes);
        }
        // /proc is read with the lock released, at most once a second (`MemorySampler`).
        if !statuses.is_empty() {
            self.memory.refresh(now, probes.iter().map(|p| p.host_pid));
            memory_statuses(&probes, &self.memory, &mut statuses);
        }
        probes.clear();
        self.memory_probes = probes;
        for status in statuses.drain(..) {
            self.send_status(status);
        }
        self.perf_statuses = statuses;
    }
}

/// What the state lock yields about one device's memory: its own figure, or the host process it
/// runs in. The `/proc` reads and the statuses come after the lock is released.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct MemoryProbe {
    channel_id: ChannelId,
    device_path: DevicePath,
    own_bytes: Option<u64>,
    approximate: bool,
    /// Host process of a subprocess plugin, 0 for anything else.
    host_pid: u32,
}

/// Every device with a memory figure, nested ones included. Pushes nothing while nobody is
/// subscribed. Runs under the state lock, so each device only does a cheap sum or an atomic read.
fn collect_memory_probes(state: &mut EngineState, out: &mut Vec<MemoryProbe>) {
    if state.perf_subscribers == 0 {
        return;
    }
    for (&channel_id, channel) in state.channels.iter_mut() {
        container::visit_devices_mut(&mut channel.devices, &mut |device_path, device| {
            let mut probe = MemoryProbe {
                channel_id,
                device_path: *device_path,
                own_bytes: device.memory_bytes(),
                approximate: device.memory_is_approximate(),
                host_pid: 0,
            };
            if let Some(plugin) = device.as_any_mut().downcast_mut::<SubprocessClapAdapter>() {
                let load = plugin.load();
                if load.is_ready() {
                    probe.host_pid = load.host_pid();
                }
            }
            if probe.own_bytes.is_some() || probe.host_pid != 0 {
                out.push(probe);
            }
        });
    }
}

/// `DeviceMemory` for each probe with a figure, then `EngineMemory`. A plugin reports its host
/// process's memory with the number of probed plugins in that process; a host whose `/proc` entry
/// couldn't be read (just exited) gets none.
fn memory_statuses(probes: &[MemoryProbe], sampler: &MemorySampler, out: &mut Vec<EngineStatus>) {
    for probe in probes {
        let (bytes, shared_by) = match (probe.own_bytes, sampler.host_bytes(probe.host_pid)) {
            (Some(bytes), _) => (bytes, 1),
            (None, Some(bytes)) => {
                let sharing = probes
                    .iter()
                    .filter(|other| other.host_pid == probe.host_pid)
                    .count();
                (bytes, sharing.max(1) as u32)
            }
            (None, None) => continue,
        };
        out.push(EngineStatus::DeviceMemory {
            channel_id: probe.channel_id,
            device_path: probe.device_path,
            bytes,
            shared_by,
            approximate: probe.approximate,
        });
    }
    out.push(EngineStatus::EngineMemory {
        engine_bytes: sampler.engine_bytes(),
        plugin_bytes: sampler.plugin_bytes(),
        plugin_hosts: sampler.host_count() as u32,
    });
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

    #[test]
    fn memory_probes_need_a_subscriber_and_a_figure() {
        let mut state = state_with_channels(&[2]);
        state
            .channels
            .get_mut(&2)
            .unwrap()
            .devices
            .push(create_effect("sonara.builtin.delay", 48_000.0, 64).unwrap());
        let mut out = Vec::new();
        collect_memory_probes(&mut state, &mut out);
        assert!(out.is_empty(), "nobody subscribed");
        state.set_perf_subscription(true);
        collect_memory_probes(&mut state, &mut out);
        assert!(out.is_empty(), "a delay has no memory figure");
    }

    fn probe(device: usize, own: Option<u64>, pid: u32) -> MemoryProbe {
        MemoryProbe {
            channel_id: 2,
            device_path: DevicePath::root(device),
            own_bytes: own,
            approximate: false,
            host_pid: pid,
        }
    }

    #[test]
    fn memory_statuses_share_a_host_between_its_plugins() {
        let mut sampler = MemorySampler::default();
        let me = std::process::id();
        sampler.refresh(std::time::Instant::now(), [me]);
        let host = sampler.host_bytes(me).unwrap();
        let probes = [
            probe(0, Some(4096), 0),
            probe(1, None, me),
            probe(2, None, me),
            probe(3, None, u32::MAX - 1),
        ];
        let mut out = Vec::new();
        memory_statuses(&probes, &sampler, &mut out);
        assert_eq!(
            out.len(),
            4,
            "3 devices with a figure plus the engine: {out:?}"
        );
        assert!(matches!(
            out[0],
            EngineStatus::DeviceMemory {
                bytes: 4096,
                shared_by: 1,
                ..
            }
        ));
        for status in &out[1..3] {
            match status {
                EngineStatus::DeviceMemory {
                    bytes, shared_by, ..
                } => {
                    assert_eq!((*bytes, *shared_by), (host, 2));
                }
                other => panic!("expected DeviceMemory, got {other:?}"),
            }
        }
        match &out[3] {
            EngineStatus::EngineMemory {
                plugin_bytes,
                plugin_hosts,
                engine_bytes,
            } => {
                assert_eq!((*plugin_bytes, *plugin_hosts), (host, 1));
                assert!(*engine_bytes > 0);
            }
            other => panic!("expected EngineMemory, got {other:?}"),
        }
    }
}
