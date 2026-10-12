//! Latency compensation plan (spec 042 part D): where parallel paths meet (a bus, master, a
//! hardware pair), the earlier ones are delayed so everything arrives aligned.
//!
//! Each channel's `in_frames` is the largest `out_frames` among the channels routing or sending
//! into it, and its `out_frames` adds the latency of its own top-level devices. Every edge (the
//! route, each send, the hardware write) then delays its source by the difference between where
//! the target is and where the source is. The command thread builds a `LatencySignature` under
//! the lock, plans outside it, and only replans when the signature changes.

use std::collections::HashMap;

use crate::audio::channel::{Channel, ChannelLatency};
use crate::audio::dsp::block_delay::{AlignDelay, StereoBlockDelay};
use crate::audio::types::{ChannelId, HARDWARE_OUTPUT_BASE};

use super::routing::{is_valid_route, output_target};

/// What the plan depends on for one channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelSignature {
    pub id: ChannelId,
    /// The channel it routes into, if that route is valid (`output_target` + `is_valid_route`).
    pub route: Option<ChannelId>,
    /// Hardware pair it writes to, as its output id (1000 and up).
    pub hardware: Option<ChannelId>,
    /// Each send in `send_channels` order: the target (`None` when the send isn't valid) and
    /// whether it's pre-fader.
    pub sends: Vec<(Option<ChannelId>, bool)>,
    /// Latency of the top-level devices the mixer runs after its inputs have mixed in (from
    /// `chain_start`), summed.
    pub device_frames: u32,
    /// Latency of the aux-source device, which runs before the inputs mix in and feeds the
    /// return channels. `None` without an aux source.
    pub aux_frames: Option<u32>,
    /// Return channels this channel's aux source writes into.
    pub aux_targets: Vec<ChannelId>,
}

/// The inputs of a plan, in channel id order. Compare two to see whether anything changed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LatencySignature {
    pub channels: Vec<ChannelSignature>,
}

impl LatencySignature {
    /// Command thread, under the state lock: read the graph and every top-level device's
    /// `latency_frames()`. Allocates (it's not the callback).
    pub fn build(channels: &HashMap<ChannelId, Channel>) -> Self {
        let mut ids: Vec<ChannelId> = channels.keys().copied().collect();
        ids.sort_unstable();
        let channels = ids
            .iter()
            .map(|&id| {
                let channel = &channels[&id];
                let valid = |target: ChannelId| is_valid_route(channels, id, target);
                let aux_targets: Vec<ChannelId> = channel
                    .extra_out_targets
                    .iter()
                    .copied()
                    .filter(|&t| t > 0 && t != id && channels.contains_key(&t))
                    .collect();
                let has_aux = channel.extra_out_targets.iter().any(|&t| t > 0);
                // The mixer's `chain_start`, from the graph rather than `mix.has_aux_source`
                // (which the callback sets each buffer).
                let start = if has_aux {
                    channel.aux_source_index() + 1
                } else {
                    0
                };
                let aux_frames = has_aux.then(|| {
                    channel
                        .devices
                        .get(channel.aux_source_index())
                        .map_or(0, |d| d.latency_frames())
                });
                ChannelSignature {
                    id,
                    route: output_target(channel).filter(|&t| valid(t)),
                    hardware: channel
                        .output_channel_id
                        .filter(|&t| t >= HARDWARE_OUTPUT_BASE),
                    sends: channel
                        .send_channels
                        .iter()
                        .map(|send| {
                            let target = send.target_channel_id;
                            (valid(target).then_some(target), send.pre_fader)
                        })
                        .collect(),
                    device_frames: channel
                        .devices
                        .iter()
                        .skip(start)
                        .map(|d| d.latency_frames())
                        .fold(0u32, u32::saturating_add),
                    aux_frames,
                    aux_targets,
                }
            })
            .collect();
        Self { channels }
    }
}

/// One channel's compensation.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChannelPlan {
    pub id: ChannelId,
    /// Where this channel's inputs are aligned to.
    pub in_frames: u32,
    /// Path latency of this channel's output.
    pub out_frames: u32,
    /// Delay on the route into the target channel.
    pub route_delay: u32,
    /// Delay on each send, in `send_channels` order (0 for an invalid send).
    pub send_delays: Vec<u32>,
    /// Delay on the hardware write.
    pub hw_delay: u32,
    /// Delay on the aux-source device's own main output, so it meets the returns mixing back
    /// into this channel at `in_frames`.
    pub aux_delay: u32,
}

impl ChannelPlan {
    /// Some edge reads the post-fader block late: the route, a post-fader send or the hardware
    /// write.
    pub fn needs_post_ring(&self, signature: &ChannelSignature) -> bool {
        self.route_delay > 0
            || self.hw_delay > 0
            || self
                .send_delays
                .iter()
                .zip(&signature.sends)
                .any(|(&delay, &(_, pre))| delay > 0 && !pre)
    }

    /// Some pre-fader send reads the pre-fader block late.
    pub fn needs_pre_ring(&self, signature: &ChannelSignature) -> bool {
        self.send_delays
            .iter()
            .zip(&signature.sends)
            .any(|(&delay, &(_, pre))| delay > 0 && pre)
    }

    /// The longest delay any of this channel's edges uses.
    pub fn max_delay(&self) -> u32 {
        self.send_delays
            .iter()
            .copied()
            .chain([self.route_delay, self.hw_delay])
            .max()
            .unwrap_or(0)
    }
}

impl ChannelPlan {
    /// The runtime state for this plan: the delays, and rings sized for the longest edge plus
    /// `max_block` frames, only where an edge needs one. Allocates, so command thread only,
    /// outside the lock.
    pub fn to_latency(&self, signature: &ChannelSignature, max_block: usize) -> ChannelLatency {
        let ring = |needed: bool| {
            needed.then(|| {
                let mut ring = StereoBlockDelay::new();
                ring.prepare(self.max_delay() as usize, max_block);
                ring
            })
        };
        ChannelLatency {
            in_frames: self.in_frames,
            out_frames: self.out_frames,
            route_delay: self.route_delay,
            send_delays: self.send_delays.clone(),
            hw_delay: self.hw_delay,
            aux_delay: self.aux_delay,
            post: ring(self.needs_post_ring(signature)),
            pre: ring(self.needs_pre_ring(signature)),
            aux: {
                let mut aux = AlignDelay::default();
                aux.set(self.aux_delay as usize, max_block);
                aux
            },
        }
    }
}

/// The compensation for every channel, in channel id order (the signature's order).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LatencyPlan {
    pub channels: Vec<ChannelPlan>,
    /// The largest path latency into any hardware pair: what compensation adds before output.
    pub output_frames: u32,
    /// Channels whose path latency was clamped to the maximum (REQ-017).
    pub over_limit: Vec<ChannelId>,
}

impl LatencyPlan {
    pub fn channel(&self, id: ChannelId) -> Option<&ChannelPlan> {
        self.channels
            .binary_search_by_key(&id, |plan| plan.id)
            .ok()
            .map(|i| &self.channels[i])
    }
}

/// Plan the compensation for `signature`, compensating at most `max_frames` (1 s at the running
/// rate) on any path.
///
/// Channels are visited in the mixer's own order: in sweeps of channels whose inputs have all
/// finished, and in a routing cycle from the first unfinished channel. An edge into a channel
/// that already finished carries nothing in the mixer (the cycle's back edge), so it gets no
/// delay and doesn't move the target.
pub fn plan(signature: &LatencySignature, max_frames: u32) -> LatencyPlan {
    let channels = &signature.channels;
    let n = channels.len();
    let index: HashMap<ChannelId, usize> = channels
        .iter()
        .enumerate()
        .map(|(i, c)| (c.id, i))
        .collect();
    let targets = |c: &ChannelSignature| -> Vec<usize> {
        c.route
            .into_iter()
            .chain(c.sends.iter().filter_map(|&(target, _)| target))
            .filter_map(|t| index.get(&t).copied())
            .collect()
    };

    // Inputs still to finish, counted like `count_route_inputs` (one per route or send).
    let mut pending = vec![0usize; n];
    for c in channels {
        for t in targets(c) {
            pending[t] += 1;
        }
    }
    // Return channels start where their aux-source device's output is.
    let mut floor = vec![0u32; n];
    for c in channels {
        if let Some(aux) = c.aux_frames {
            for t in c.aux_targets.iter().filter_map(|t| index.get(t)) {
                floor[*t] = floor[*t].max(aux.min(max_frames));
            }
        }
    }

    let mut done = vec![false; n];
    // The sweep each channel finished in: an edge carries audio only into a later sweep.
    let mut sweep = vec![0usize; n];
    let mut sweeps = 0usize;
    let mut in_frames = floor;
    let mut out_frames = vec![0u32; n];
    let mut over_limit = Vec::new();
    let mut remaining = n;
    let mut ready = Vec::with_capacity(n);
    while remaining > 0 {
        ready.clear();
        ready.extend((0..n).filter(|&i| !done[i] && pending[i] == 0));
        if ready.is_empty() {
            // Routing cycle: break it at the first unfinished channel, as the mixer does.
            match (0..n).find(|&i| !done[i]) {
                Some(i) => ready.push(i),
                None => break,
            }
        }
        sweeps += 1;
        for &i in &ready {
            done[i] = true;
            sweep[i] = sweeps;
            let c = &channels[i];
            let start = c
                .aux_frames
                .map_or(in_frames[i], |aux| in_frames[i].max(aux));
            in_frames[i] = start.min(max_frames);
            let out = start.saturating_add(c.device_frames);
            if out > max_frames {
                over_limit.push(c.id);
            }
            out_frames[i] = out.min(max_frames);
        }
        for &i in &ready {
            for t in targets(&channels[i]) {
                pending[t] = pending[t].saturating_sub(1);
                if !done[t] {
                    in_frames[t] = in_frames[t].max(out_frames[i]);
                }
            }
        }
        remaining = remaining.saturating_sub(ready.len());
    }

    // An edge into a channel that finished first (a cycle's back edge) carries nothing.
    let edge_delay = |source: usize, target: Option<ChannelId>| -> u32 {
        match target.and_then(|t| index.get(&t)) {
            Some(&t) if sweep[t] > sweep[source] => in_frames[t].saturating_sub(out_frames[source]),
            _ => 0,
        }
    };
    let output_frames = channels
        .iter()
        .enumerate()
        .filter(|(_, c)| c.hardware.is_some())
        .map(|(i, _)| out_frames[i])
        .max()
        .unwrap_or(0);

    let channels = channels
        .iter()
        .enumerate()
        .map(|(i, c)| ChannelPlan {
            id: c.id,
            in_frames: in_frames[i],
            out_frames: out_frames[i],
            route_delay: edge_delay(i, c.route),
            send_delays: c
                .sends
                .iter()
                .map(|&(target, _)| edge_delay(i, target))
                .collect(),
            hw_delay: if c.hardware.is_some() {
                output_frames - out_frames[i]
            } else {
                0
            },
            aux_delay: c
                .aux_frames
                .map_or(0, |aux| in_frames[i].saturating_sub(aux)),
        })
        .collect();
    LatencyPlan {
        channels,
        output_frames,
        over_limit,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::mixing::test_support::{add_test_device, send_to, test_channel};

    const MASTER: ChannelId = 1;

    fn channel(id: ChannelId, route: Option<ChannelId>, device_frames: u32) -> ChannelSignature {
        ChannelSignature {
            id,
            route,
            hardware: None,
            sends: Vec::new(),
            device_frames,
            aux_frames: None,
            aux_targets: Vec::new(),
        }
    }

    fn master() -> ChannelSignature {
        ChannelSignature {
            hardware: Some(HARDWARE_OUTPUT_BASE),
            ..channel(MASTER, None, 0)
        }
    }

    fn signature(mut channels: Vec<ChannelSignature>) -> LatencySignature {
        channels.sort_by_key(|c| c.id);
        LatencySignature { channels }
    }

    #[test]
    fn plan_aligns_parallel_paths() {
        // REQ-013's example: A (0) and B (512-frame EQ) into Drums; Drums and a reverb bus into
        // master. A also sends post-fader and B pre-fader to the reverb bus.
        const DRUMS: ChannelId = 2;
        const REVERB: ChannelId = 3;
        const A: ChannelId = 4;
        const B: ChannelId = 5;
        let mut a = channel(A, Some(DRUMS), 0);
        a.sends.push((Some(REVERB), false));
        let mut b = channel(B, Some(DRUMS), 512);
        b.sends.push((Some(REVERB), true));
        let plan = plan(
            &signature(vec![
                master(),
                channel(DRUMS, Some(MASTER), 0),
                channel(REVERB, Some(MASTER), 0),
                a,
                b,
            ]),
            48_000,
        );

        let a = plan.channel(A).unwrap();
        assert_eq!((a.out_frames, a.route_delay), (0, 512));
        assert_eq!(a.send_delays, vec![512]);
        let b = plan.channel(B).unwrap();
        assert_eq!((b.out_frames, b.route_delay, b.send_delays[0]), (512, 0, 0));
        let drums = plan.channel(DRUMS).unwrap();
        assert_eq!(
            (drums.in_frames, drums.out_frames, drums.route_delay),
            (512, 512, 0)
        );
        let reverb = plan.channel(REVERB).unwrap();
        assert_eq!((reverb.out_frames, reverb.route_delay), (512, 0));
        assert_eq!(plan.channel(MASTER).unwrap().out_frames, 512);
        assert_eq!(plan.output_frames, 512);
        assert!(plan.over_limit.is_empty());
    }

    #[test]
    fn a_channel_on_its_own_hardware_pair_aligns_with_master() {
        let plan = plan(
            &signature(vec![
                master(),
                channel(2, Some(MASTER), 300),
                ChannelSignature {
                    hardware: Some(HARDWARE_OUTPUT_BASE + 1),
                    ..channel(3, None, 100)
                },
            ]),
            48_000,
        );
        assert_eq!(plan.output_frames, 300);
        assert_eq!(plan.channel(MASTER).unwrap().hw_delay, 0);
        assert_eq!(plan.channel(3).unwrap().hw_delay, 200);
    }

    #[test]
    fn return_channels_start_at_the_aux_device_latency() {
        // A Layer-style source (aux device 64 frames, then a 10-frame FX) with returns 3 (no
        // latency) and 4 (a 100-frame FX) mixing back into it.
        let mut parent = channel(2, Some(MASTER), 10);
        parent.aux_frames = Some(64);
        parent.aux_targets = vec![3, 4];
        let plan = plan(
            &signature(vec![
                master(),
                parent,
                channel(3, Some(2), 0),
                channel(4, Some(2), 100),
            ]),
            48_000,
        );
        assert_eq!(plan.channel(3).unwrap().out_frames, 64);
        assert_eq!(plan.channel(3).unwrap().route_delay, 100);
        assert_eq!(plan.channel(4).unwrap().out_frames, 164);
        let parent = plan.channel(2).unwrap();
        assert_eq!((parent.in_frames, parent.out_frames), (164, 174));
        assert_eq!(
            parent.aux_delay, 100,
            "its own aux output waits for the returns"
        );
    }

    #[test]
    fn plan_survives_cycles_and_clamps() {
        // 2 → 3 → 2 is a cycle, both reach master; 4 has a device beyond the 1 s maximum.
        let mut cycle_b = channel(3, Some(2), 200);
        cycle_b.sends.push((Some(MASTER), false));
        let signature = signature(vec![
            master(),
            channel(2, Some(3), 50),
            cycle_b,
            channel(4, Some(MASTER), 60_000),
            channel(5, Some(MASTER), 0),
        ]);
        let plan = plan(&signature, 48_000);

        assert_eq!(plan.over_limit, vec![4]);
        assert_eq!(plan.channel(4).unwrap().out_frames, 48_000);
        assert_eq!(plan.channel(MASTER).unwrap().in_frames, 48_000);
        assert_eq!(plan.channel(5).unwrap().route_delay, 48_000);
        // No channel is ready once 4 and 5 finish, so the mixer breaks at the first unfinished
        // channel: master, which still waits on the cycle. The cycle's send into master then
        // arrives after master finished and carries nothing. Next 2 (lowest id) breaks the
        // cycle itself: 2 runs, then 3, whose route back into 2 carries nothing either.
        let two = plan.channel(2).unwrap();
        let three = plan.channel(3).unwrap();
        assert_eq!(
            (two.out_frames, three.in_frames, three.out_frames),
            (50, 50, 250)
        );
        assert_eq!(two.route_delay, 0);
        assert_eq!(three.route_delay, 0, "the back edge gets no delay");
        assert_eq!(
            three.send_delays,
            vec![0],
            "master finished before the cycle"
        );
        for c in &plan.channels {
            assert!(c.max_delay() <= 48_000);
        }
    }

    #[test]
    fn a_project_without_latency_plans_nothing() {
        let mut a = channel(3, Some(2), 0);
        a.sends.push((Some(4), true));
        let plan = plan(
            &signature(vec![
                master(),
                channel(2, Some(MASTER), 0),
                a,
                channel(4, Some(MASTER), 0),
            ]),
            48_000,
        );
        assert!(plan
            .channels
            .iter()
            .all(|c| c.max_delay() == 0 && c.out_frames == 0));
        assert_eq!(plan.output_frames, 0);
    }

    /// A pass-through that reports `frames` of latency.
    struct Latent(u32);

    impl crate::audio::devices::AudioDevice for Latent {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], n: usize) {
            outputs[..n * 2].copy_from_slice(&inputs[..n * 2]);
        }
        fn latency_frames(&self) -> u32 {
            self.0
        }
        fn set_parameter(
            &mut self,
            _: crate::audio::devices::ParamId,
            _: crate::audio::devices::ParamValue,
        ) {
        }
        fn get_parameter(
            &self,
            _: crate::audio::devices::ParamId,
        ) -> Option<crate::audio::devices::ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.latent"
        }
        fn device_name(&self) -> &str {
            "Latent"
        }
        fn device_category(&self) -> crate::audio::devices::DeviceCategory {
            crate::audio::devices::DeviceCategory::Effect
        }
        fn device_variant(&self) -> crate::audio::devices::DeviceVariant {
            crate::audio::devices::DeviceVariant::BuiltIn
        }
        fn parameters(&self) -> Vec<crate::audio::devices::ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    #[test]
    fn signature_reads_routes_sends_and_device_latency() {
        let mut track = test_channel(3, Some(2), 0.0);
        track.devices.push(Box::new(Latent(100)));
        add_test_device(&mut track, 0.0);
        track.devices.push(Box::new(Latent(28)));
        track.send_channels.push(send_to(4, true));
        track.send_channels.push(send_to(99, false)); // no such channel
        let mut layer = test_channel(4, Some(MASTER), 0.0);
        layer.devices.push(Box::new(Latent(64)));
        layer.devices.push(Box::new(Latent(5)));
        layer.set_aux_out(0, 5);
        let mut channels = HashMap::new();
        for channel in [
            test_channel(MASTER, Some(HARDWARE_OUTPUT_BASE), 0.0),
            test_channel(2, Some(MASTER), 0.0),
            track,
            layer,
            test_channel(5, Some(4), 0.0),
        ] {
            channels.insert(channel.id, channel);
        }

        let signature = LatencySignature::build(&channels);
        let ids: Vec<ChannelId> = signature.channels.iter().map(|c| c.id).collect();
        assert_eq!(ids, vec![1, 2, 3, 4, 5]);
        let master = &signature.channels[0];
        assert_eq!(
            (master.route, master.hardware),
            (None, Some(HARDWARE_OUTPUT_BASE))
        );
        let track = &signature.channels[2];
        assert_eq!(track.route, Some(2));
        assert_eq!(track.device_frames, 128);
        assert_eq!(track.sends, vec![(Some(4), true), (None, false)]);
        let layer = &signature.channels[3];
        assert_eq!((layer.aux_frames, layer.device_frames), (Some(64), 5));
        assert_eq!(layer.aux_targets, vec![5]);
        assert_eq!(signature, LatencySignature::build(&channels), "stable");
    }
}
