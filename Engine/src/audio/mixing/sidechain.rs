//! Cross-channel sidechain taps (spec 036).
//!
//! A `sidechain` modulator follows either its own device's input ("Device In", fed per
//! control step from the live input) or the post-fader output of any channel (D2/D8). This
//! module holds the tap pool: the mixer snapshots every subscribed source channel's final
//! buffer at the end of [`mix_and_output`](super::mix_and_output), and the next callback
//! feeds the snapshots to the subscribing modulators before the device passes run — one block
//! of latency, ≤ 5.3 ms at 256 frames / 48 kHz (D3).
//!
//! The pool is rebuilt only by the command thread, on modulator add/remove, a sidechain
//! Source change, channel/device add/remove/move and `/project/init`: the walk and any
//! allocation happen there and the old buffers are dropped after the state lock is released.
//! The audio callback only reads the preallocated buffers.

use std::collections::HashMap;

use crate::audio::channel::Channel;
use crate::audio::devices::{container, DevicePath};
use crate::audio::state::EngineState;
use crate::audio::stream::MAX_BLOCK_FRAMES;
use crate::audio::types::{ChannelId, HARDWARE_OUTPUT_BASE};

/// One tapped source channel: the mono (`0.5·(L+R)`) snapshot of its last block.
pub struct TapSlot {
    /// The channel the frames are copied from, by id (stable across reorder and rename).
    pub channel_id: ChannelId,
    /// Preallocated to the engine's max block size by the command thread; the audio callback
    /// never resizes it.
    pub mono: Vec<f32>,
    /// Frames the last snapshot filled.
    pub frames: usize,
}

/// One `sidechain` modulator with a channel source (Source ≥ 1), pointing into `slots`.
#[derive(PartialEq)]
pub struct TapSubscriber {
    /// The channel whose device carries the modulator.
    pub channel_id: ChannelId,
    /// The device's path within that channel.
    pub device_path: DevicePath,
    /// The modulator id within the device.
    pub mod_id: u8,
    /// Index into `slots`.
    pub slot: usize,
}

/// The whole tap pool, owned by [`EngineState`](EngineState).
#[derive(Default)]
pub struct SidechainTaps {
    /// One entry per distinct source channel, shared by every modulator tapping it.
    pub slots: Vec<TapSlot>,
    pub subscribers: Vec<TapSubscriber>,
}

impl SidechainTaps {
    /// Copy every slot's source channel's final buffer into its mono snapshot (post-fader,
    /// post-pan; master is post-master-fader). Called at the end of `mix_and_output`.
    /// Muted or solo-silenced channels were cleared, so they snapshot silence; so does a
    /// source channel that no longer exists.
    pub fn snapshot(&mut self, channels: &HashMap<ChannelId, Channel>, frames: usize) {
        for slot in &mut self.slots {
            let count = frames.min(slot.mono.len());
            match channels.get(&slot.channel_id) {
                Some(channel) => {
                    for (mono, (left, right)) in slot.mono[..count].iter_mut().zip(
                        channel.buffer_left[..count]
                            .iter()
                            .zip(&channel.buffer_right),
                    ) {
                        *mono = 0.5 * (left + right);
                    }
                }
                None => slot.mono[..count].fill(0.0),
            }
            slot.frames = count;
        }
    }
}

/// Feed every subscriber the previous block's snapshot. Called at the start of the live
/// callback, before the device passes run, so the block's control steps read the freshly fed
/// follower. A subscriber whose channel, device path or modulator no longer resolves is
/// skipped, never panicked: a removed target's follower simply decays to 0.
pub fn feed_taps(state: &mut EngineState) {
    let subscribers = std::mem::take(&mut state.sc_taps.subscribers);
    for subscriber in &subscribers {
        let Some(slot) = state.sc_taps.slots.get(subscriber.slot) else {
            continue;
        };
        let mono = &slot.mono[..slot.frames.min(slot.mono.len())];
        let Some(channel) = state.channels.get_mut(&subscriber.channel_id) else {
            continue;
        };
        let Some(device) = channel.device_at_path_mut(&subscriber.device_path) else {
            continue;
        };
        if let Some(modulated) = device.as_modulated_mut() {
            modulated.feed_sidechain(subscriber.mod_id, mono);
        }
    }
    state.sc_taps.subscribers = subscribers;
}

/// Rebuild the tap pool from the project's current modulators: one slot per distinct source
/// channel that exists, one subscriber per `sidechain` modulator with Source ≥ 1 (source ids
/// at or above the hardware outputs are not sources, D2). A source id that does not exist
/// gets no slot, so its subscribers are skipped and the follower decays to 0 (REQ-006).
///
/// Command thread only; returns the replaced pool for the caller to drop after the state
/// lock is released (`CommandEffects::discard`, or the lock guard dropped in the worker).
pub fn rebuild_taps(state: &mut EngineState) -> SidechainTaps {
    // (channel, device path, mod id, source channel id) per sidechain with a channel source.
    let mut wanted: Vec<(ChannelId, DevicePath, u8, ChannelId)> = Vec::new();
    for channel in state.channels.values_mut() {
        let channel_id = channel.id;
        container::visit_devices_mut(&mut channel.devices, &mut |path, device| {
            let Some(modulated) = device.as_modulated_mut() else {
                return;
            };
            for (mod_id, source) in modulated.sidechain_sources() {
                wanted.push((channel_id, *path, mod_id, source));
            }
        });
    }

    // One slot per distinct existing source channel, in a stable (sorted) order.
    let mut sources: Vec<ChannelId> = wanted.iter().map(|wanted| wanted.3).collect();
    sources.sort_unstable();
    sources.dedup();
    let mut slots: Vec<TapSlot> = Vec::with_capacity(sources.len());
    for source in sources.iter().copied() {
        if source >= 1 && source < HARDWARE_OUTPUT_BASE && state.channels.contains_key(&source) {
            slots.push(TapSlot {
                channel_id: source,
                mono: vec![0.0; MAX_BLOCK_FRAMES],
                frames: 0,
            });
        }
    }
    let mut subscribers: Vec<TapSubscriber> = Vec::with_capacity(wanted.len());
    for (channel_id, device_path, mod_id, source) in wanted {
        if let Some(slot) = slots.iter().position(|slot| slot.channel_id == source) {
            subscribers.push(TapSubscriber {
                channel_id,
                device_path,
                mod_id,
                slot,
            });
        }
    }

    // Nothing changed (a Source set to the id it already had, say): keep the pool, buffers
    // and all.
    let unchanged = state.sc_taps.slots.len() == slots.len()
        && state
            .sc_taps
            .slots
            .iter()
            .zip(&slots)
            .all(|(old, new)| old.channel_id == new.channel_id)
        && state.sc_taps.subscribers == subscribers;
    if unchanged {
        return SidechainTaps::default();
    }
    std::mem::replace(&mut state.sc_taps, SidechainTaps { slots, subscribers })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::mixing::{mix_and_output, test_support};
    use crate::audio::modulation::kinds::{SC_ATTACK, SC_RELEASE, SC_SOURCE};
    use crate::audio::modulation::{wrap_at_path, ModulatorKind};
    use crossbeam::channel::unbounded;

    const SR: f32 = test_support::SAMPLE_RATE;
    const FRAMES: usize = test_support::BUFFER_SIZE;

    /// A channel holding one wrapped device with a `sidechain` modulator. `source` 0 is
    /// Device In (no tap); anything else is a channel id.
    fn sidechain_channel(id: ChannelId, source: u32) -> Channel {
        let mut channel = test_support::test_channel(id, None, 0.0);
        test_support::add_test_device(&mut channel, 0.0);
        wrap_at_path(&mut channel.devices, &DevicePath::root(0), SR).expect("wrap");
        let device = channel.device_at_path_mut(&DevicePath::root(0)).unwrap();
        let modulated = device.as_modulated_mut().unwrap();
        modulated
            .add_modulator(0, ModulatorKind::Sidechain)
            .unwrap();
        // Instant attack and the 5 ms minimum release, so 4-frame test blocks move the value.
        modulated.set_modulator_param(0, SC_ATTACK, 0.0).unwrap();
        modulated.set_modulator_param(0, SC_RELEASE, 0.0).unwrap();
        if source > 0 {
            modulated
                .set_modulator_param(0, SC_SOURCE, source as f32 / 999.0)
                .expect("source");
        }
        channel
    }

    fn sidechain_value(channel: &mut Channel) -> f32 {
        channel
            .device_at_path_mut(&DevicePath::root(0))
            .and_then(|device| device.as_modulated_mut())
            .and_then(|modulated| modulated.modulator_value(0))
            .unwrap_or(f32::NAN)
    }

    fn mix_block(state: &mut EngineState, out: &mut [f32]) {
        let (status_tx, _status_rx) = unbounded();
        mix_and_output(state, out, 2, FRAMES, &status_tx);
    }

    #[test]
    fn a_tap_follows_its_source_one_block_late() {
        let mut state = test_support::state_with(vec![
            sidechain_channel(2, 3),
            test_support::test_channel(3, None, 0.0),
        ]);
        // The command thread builds the pool; the test replays its work.
        rebuild_taps(&mut state);
        state.channels.get_mut(&3).unwrap().buffer_left.fill(0.5);
        state.channels.get_mut(&3).unwrap().buffer_right.fill(0.5);
        let mut out = vec![0.0f32; FRAMES * 2];

        // Block 1: B plays, but A's follower has not seen anything yet.
        mix_block(&mut state, &mut out);
        assert!(
            sidechain_value(state.channels.get_mut(&2).unwrap()) < 0.01,
            "the tap is one block late"
        );

        // Block 2: the snapshot of block 1 reaches A.
        feed_taps(&mut state);
        mix_block(&mut state, &mut out);
        let value = sidechain_value(state.channels.get_mut(&2).unwrap());
        assert!(value > 0.5, "A's follower reads B at {value}");
        // Mono collapse: L + R at 0.5 each is one signal, not two summed.
        assert!(value <= 1.0, "0 dBFS maps to 1, got {value}");

        // B goes silent: the follower decays back to 0 without any panic.
        let b = state.channels.get_mut(&3).unwrap();
        b.buffer_left.fill(0.0);
        b.buffer_right.fill(0.0);
        for _ in 0..1_500 {
            feed_taps(&mut state);
            mix_block(&mut state, &mut out);
        }
        let value = sidechain_value(state.channels.get_mut(&2).unwrap());
        assert!(value < 0.01, "silence decayed to {value}");
    }

    #[test]
    fn a_missing_source_id_skips_the_feed_and_decays_to_zero() {
        let mut state = test_support::state_with(vec![sidechain_channel(2, 77)]);
        // Prime the follower by hand, as it would have been before the source vanished.
        let sine = crate::audio::dsp::test_util::stereo(&crate::audio::dsp::test_util::sine(
            1_000.0, SR, FRAMES, 0.5,
        ));
        let channel = state.channels.get_mut(&2).unwrap();
        let device = channel.device_at_path_mut(&DevicePath::root(0)).unwrap();
        device
            .as_modulated_mut()
            .unwrap()
            .feed_sidechain(0, &crate::audio::dsp::test_util::left(&sine));
        assert!(sidechain_value(state.channels.get_mut(&2).unwrap()) > 0.5);

        // The source id has no channel: no slot, no feed, decay to 0, no panic.
        rebuild_taps(&mut state);
        assert!(state.sc_taps.slots.is_empty());
        assert!(state.sc_taps.subscribers.is_empty());
        let mut out = vec![0.0f32; FRAMES * 2];
        for _ in 0..1_500 {
            feed_taps(&mut state);
            mix_block(&mut state, &mut out);
        }
        let value = sidechain_value(state.channels.get_mut(&2).unwrap());
        assert!(value < 0.01, "the orphaned follower decayed to {value}");
    }

    #[test]
    fn two_sidechains_on_one_source_share_one_slot() {
        let mut state = test_support::state_with(vec![
            sidechain_channel(2, 3),
            sidechain_channel(4, 3),
            test_support::test_channel(3, None, 0.0),
        ]);
        rebuild_taps(&mut state);
        assert_eq!(state.sc_taps.slots.len(), 1, "one slot per source channel");
        assert_eq!(state.sc_taps.slots[0].channel_id, 3);
        assert_eq!(state.sc_taps.slots[0].mono.len(), MAX_BLOCK_FRAMES);
        assert_eq!(state.sc_taps.subscribers.len(), 2);
        assert!(state
            .sc_taps
            .subscribers
            .iter()
            .all(|subscriber| subscriber.slot == 0));

        // A second rebuild with nothing changed keeps the pool (and its buffers).
        let _ = rebuild_taps(&mut state);
        assert_eq!(state.sc_taps.slots.len(), 1);
    }

    #[test]
    fn a_rebuild_picks_up_added_and_dropped_sources() {
        let mut state = test_support::state_with(vec![
            sidechain_channel(2, 3),
            test_support::test_channel(3, None, 0.0),
        ]);
        rebuild_taps(&mut state);
        assert_eq!(state.sc_taps.slots.len(), 1);

        // The only sidechain goes away: the pool empties.
        let channel = state.channels.get_mut(&2).unwrap();
        let device = channel.device_at_path_mut(&DevicePath::root(0)).unwrap();
        device
            .as_modulated_mut()
            .unwrap()
            .remove_modulator(0)
            .unwrap();
        let _ = rebuild_taps(&mut state);
        assert!(state.sc_taps.slots.is_empty());
        assert!(state.sc_taps.subscribers.is_empty());
    }
}
