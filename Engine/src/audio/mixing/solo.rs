//! Solo roles: decides per buffer which channels play in full, only through their sends, or not
//! at all.

use std::collections::HashMap;

use crate::audio::channel::Channel;
use crate::audio::render_scratch::SoloRole;
use crate::audio::types::*;

use super::routing::{is_valid_route, output_target};
use super::{MASTER_CHANNEL_ID, SOLO_WALK_LIMIT};

/// True if this channel contributes no audio this buffer (muted or excluded by solo).
pub(super) fn is_silenced(channel: &Channel) -> bool {
    channel.mix.solo_role == SoloRole::Silent
}

/// True if this channel or anything it routes into is soloed.
pub(super) fn output_reaches_soloed(
    channel_map: &HashMap<ChannelId, Channel>,
    mut id: ChannelId,
) -> bool {
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
pub(super) fn any_output(
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
pub(super) fn spread_solo_up(
    channel_map: &mut HashMap<ChannelId, Channel>,
    source_id: ChannelId,
) -> bool {
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
pub(super) fn assign_solo_roles(
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

#[cfg(test)]
mod tests {
    use crate::audio::channel::{fader_gain, Send};
    use crate::audio::mixing::test_support::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn soloed_track_still_routes_through_unsoloed_bus() {
        let mut state = track_bus_master_state();
        state.channels.get_mut(&3).unwrap().solo = true;
        let output = mix(&mut state);

        let expected = 0.5 * fader_gain(-6.0) * fader_gain(-6.0);
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

        let expected = 0.5 * fader_gain(-6.0) * fader_gain(-6.0);
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

        let expected = 0.5 * fader_gain(-6.0) * fader_gain(-6.0);
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

        let expected = 0.5 * fader_gain(-6.0) * fader_gain(-6.0) * fader_gain(-6.0);
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
