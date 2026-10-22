//! Virtual Stage commands (spec 051): the room, the Stage return and stage sources.
//!
//! The objects a stage source and the Stage return own (delay lines, a reverb) are big, so the
//! command thread builds them with the state lock released and these functions only swap them
//! in, under the lock, and hand the replaced ones to `CommandEffects` to drop afterwards.

use super::CommandEffects;
use crate::audio::channel::PanMode;
use crate::audio::stage::source::StageSource;
use crate::audio::stage::tail::StageTail;
use crate::audio::stage::{RoomModel, StageParams};
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;
use tracing::{info, warn};

/// The master channel's id: it can't be a stage source or the Stage return.
const MASTER_ID: ChannelId = 1;

/// Replace the project's room. Every stage source starts its crossfade to it and the Stage
/// return refits its tail. Only copies a `Copy` struct per source and sets reverb targets.
pub(super) fn set_stage(state: &mut EngineState, room: RoomModel) {
    let room = room.clamped();
    state.stage.room = room;
    for channel in state.channels.values_mut() {
        if let Some(source) = channel.stage.as_mut() {
            source.set_room(room);
        }
        if let Some(tail) = channel.stage_tail.as_mut() {
            tail.configure(&room);
        }
    }
}

/// Set a stage source's placement.
pub(super) fn set_channel_stage(state: &mut EngineState, id: ChannelId, params: StageParams) {
    let Some(channel) = state.channels.get_mut(&id) else {
        warn!("Cannot set stage placement for channel {} (not found)", id);
        return;
    };
    let finite = |v: f32| if v.is_finite() { v } else { 0.0 };
    channel.stage_params = StageParams {
        x: finite(params.x),
        y: finite(params.y),
        z: finite(params.z),
        size: finite(params.size).max(0.0),
        rotation_deg: finite(params.rotation_deg),
        ..params
    };
}

/// Why `id` can't enter the Stage pan mode, or `None` if it can (the channel exists, isn't
/// master and isn't the Stage return).
pub(crate) fn stage_refusal(state: &EngineState, id: ChannelId) -> Option<&'static str> {
    if !state.channels.contains_key(&id) {
        Some("channel not found")
    } else if id == MASTER_ID {
        Some("the master channel can't be a stage source")
    } else if state.stage.return_channel_id == Some(id) {
        Some("the Stage return can't be a stage source")
    } else {
        None
    }
}

/// Put a channel in the Stage pan mode with its prebuilt `source`, feeding the Stage return.
/// Refused (the source goes to the trash and the mode stays) on master and on the Stage return.
/// Returns whether the channel entered Stage.
pub(crate) fn enter_stage(
    state: &mut EngineState,
    id: ChannelId,
    mut source: Box<StageSource>,
    effects: &mut CommandEffects,
) -> bool {
    if let Some(reason) = stage_refusal(state, id) {
        warn!("Pan mode Stage refused for channel {}: {}", id, reason);
        effects.discard(source);
        return false;
    }
    source.set_room(state.stage.room);
    let feed = state.stage.return_channel_id;
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.pan_mode = PanMode::Stage;
        channel.stage_feed = feed;
        if let Some(old) = channel.stage.replace(source) {
            effects.discard(old);
        }
        info!("Channel {} is a stage source (Stage return {:?})", id, feed);
    }
    true
}

/// Take a channel out of the Stage pan mode: drop its source and the edge to the Stage return.
/// Does nothing for a channel that isn't a stage source.
pub(crate) fn leave_stage(state: &mut EngineState, id: ChannelId, effects: &mut CommandEffects) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.stage_feed = None;
        if let Some(old) = channel.stage.take() {
            effects.discard(old);
        }
    }
}

/// Set a channel's pan mode on the fast path. Stage needs a prebuilt source, so it goes through
/// `enter_stage` instead; a Stage request that reaches here is ignored.
pub(super) fn set_pan_mode(
    state: &mut EngineState,
    id: ChannelId,
    mode: i32,
    effects: &mut CommandEffects,
) {
    if PanMode::from(mode) == PanMode::Stage {
        warn!(
            "Pan mode Stage for channel {} must be handled by CommandWorker, ignoring",
            id
        );
        return;
    }
    super::channel::set_channel_pan_mode(state, id, mode);
    leave_stage(state, id, effects);
}

/// Register channel `id` as the Stage return (0 clears it) with its prebuilt `tail`, point every
/// stage source at it, and hand the previous return's tail to the trash. Refused (the tail is
/// trashed) when `id` isn't a channel other than master, or is a stage source itself.
/// Returns whether the registration changed.
pub(crate) fn set_return(
    state: &mut EngineState,
    id: ChannelId,
    tail: Option<Box<StageTail>>,
    effects: &mut CommandEffects,
) -> bool {
    if id != 0 {
        let reason = if !state.channels.contains_key(&id) {
            Some("channel not found")
        } else if id == MASTER_ID {
            Some("the master channel can't be the Stage return")
        } else if state.channels[&id].stage.is_some() {
            Some("a stage source can't be the Stage return")
        } else {
            None
        };
        if let Some(reason) = reason {
            warn!("Stage return {} refused: {}", id, reason);
            effects.discard(tail);
            return false;
        }
    }

    if let Some(old_id) = state.stage.return_channel_id.take() {
        if let Some(old) = state
            .channels
            .get_mut(&old_id)
            .and_then(|c| c.stage_tail.take())
        {
            effects.discard(old);
        }
    }
    let feed = (id != 0).then_some(id);
    state.stage.return_channel_id = feed;
    if let (Some(id), Some(mut tail)) = (feed, tail) {
        tail.configure(&state.stage.room);
        if let Some(channel) = state.channels.get_mut(&id) {
            channel.stage_tail = Some(tail);
        }
    }
    for channel in state.channels.values_mut() {
        if channel.stage.is_some() {
            channel.stage_feed = feed;
        }
    }
    info!("Stage return set to {:?}", feed);
    true
}

/// A channel is going away: if it was the Stage return, forget it and the edges into it.
pub(crate) fn forget_removed_channel(state: &mut EngineState, id: ChannelId) {
    if state.stage.return_channel_id == Some(id) {
        state.stage.return_channel_id = None;
        for channel in state.channels.values_mut() {
            if channel.stage_feed == Some(id) {
                channel.stage_feed = None;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::channel::Channel;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 64;

    fn state_with(ids: &[ChannelId]) -> EngineState {
        let mut state = EngineState::default();
        state.device_sample_rate = SR;
        for &id in ids {
            state
                .channels
                .insert(id, Channel::new(id, format!("Channel {id}"), BLOCK, SR));
        }
        state
    }

    fn source() -> Box<StageSource> {
        Box::new(StageSource::new(SR, BLOCK))
    }

    #[test]
    fn stage_is_refused_on_master() {
        let mut state = state_with(&[1, 2]);
        let mut effects = CommandEffects::default();
        assert!(!enter_stage(&mut state, 1, source(), &mut effects));
        assert_eq!(state.channels[&1].pan_mode, PanMode::default());
        assert!(state.channels[&1].stage.is_none());
        assert_eq!(effects.trash.len(), 1, "the unused source is dropped later");

        assert!(enter_stage(&mut state, 2, source(), &mut effects));
        assert_eq!(state.channels[&2].pan_mode, PanMode::Stage);
        assert!(state.channels[&2].stage.is_some());
    }

    #[test]
    fn stage_is_refused_on_the_stage_return() {
        let mut state = state_with(&[1, 2, 3]);
        let mut effects = CommandEffects::default();
        assert!(set_return(
            &mut state,
            3,
            Some(Box::new(StageTail::new(SR, BLOCK))),
            &mut effects
        ));
        assert!(!enter_stage(&mut state, 3, source(), &mut effects));
        assert_eq!(state.channels[&3].pan_mode, PanMode::default());
        // And a stage source can't become the return.
        assert!(enter_stage(&mut state, 2, source(), &mut effects));
        assert!(!set_return(&mut state, 2, None, &mut effects));
        assert_eq!(state.stage.return_channel_id, Some(3));
    }

    #[test]
    fn the_return_feeds_every_source_and_follows_changes() {
        let mut state = state_with(&[1, 2, 3, 4, 5]);
        let mut effects = CommandEffects::default();
        assert!(enter_stage(&mut state, 2, source(), &mut effects));
        assert_eq!(state.channels[&2].stage_feed, None, "no return yet");

        assert!(set_return(
            &mut state,
            4,
            Some(Box::new(StageTail::new(SR, BLOCK))),
            &mut effects
        ));
        assert!(state.channels[&4].stage_tail.is_some());
        assert_eq!(state.channels[&2].stage_feed, Some(4));
        // A source that enters later feeds the existing return.
        assert!(enter_stage(&mut state, 3, source(), &mut effects));
        assert_eq!(state.channels[&3].stage_feed, Some(4));
        // A channel that isn't a source gets no edge.
        assert_eq!(state.channels[&5].stage_feed, None);

        // Moving the return moves the edges and the tail.
        assert!(set_return(
            &mut state,
            5,
            Some(Box::new(StageTail::new(SR, BLOCK))),
            &mut effects
        ));
        assert!(state.channels[&4].stage_tail.is_none());
        assert!(state.channels[&5].stage_tail.is_some());
        assert_eq!(state.channels[&2].stage_feed, Some(5));
        assert_eq!(state.channels[&3].stage_feed, Some(5));

        // Clearing it removes them.
        assert!(set_return(&mut state, 0, None, &mut effects));
        assert!(state.channels[&5].stage_tail.is_none());
        assert_eq!(state.channels[&2].stage_feed, None);
    }

    #[test]
    fn leaving_stage_drops_the_source_and_the_edge() {
        let mut state = state_with(&[1, 2, 3]);
        let mut effects = CommandEffects::default();
        set_return(
            &mut state,
            3,
            Some(Box::new(StageTail::new(SR, BLOCK))),
            &mut effects,
        );
        enter_stage(&mut state, 2, source(), &mut effects);
        let before = effects.trash.len();
        set_pan_mode(&mut state, 2, 2, &mut effects);
        let channel = &state.channels[&2];
        assert_eq!(channel.pan_mode, PanMode::StereoBalance);
        assert!(channel.stage.is_none());
        assert_eq!(channel.stage_feed, None);
        assert_eq!(effects.trash.len(), before + 1);
    }

    #[test]
    fn stage_on_the_fast_path_changes_nothing() {
        let mut state = state_with(&[1, 2]);
        let mut effects = CommandEffects::default();
        set_pan_mode(&mut state, 2, 4, &mut effects);
        assert_eq!(state.channels[&2].pan_mode, PanMode::default());
        assert!(state.channels[&2].stage.is_none());
    }

    #[test]
    fn a_new_room_reaches_sources_and_the_tail() {
        let mut state = state_with(&[1, 2, 3]);
        let mut effects = CommandEffects::default();
        set_return(
            &mut state,
            3,
            Some(Box::new(StageTail::new(SR, BLOCK))),
            &mut effects,
        );
        enter_stage(&mut state, 2, source(), &mut effects);
        let room = RoomModel {
            width: 33.0,
            decay_s: 4.0,
            ..RoomModel::default()
        };
        set_stage(&mut state, room);
        assert_eq!(state.stage.room, room);
        assert_eq!(*state.channels[&2].stage.as_ref().unwrap().room(), room);
        assert_eq!(
            *state.channels[&3].stage_tail.as_ref().unwrap().room(),
            room
        );
        // A source that enters afterwards starts in the current room.
        let mut state2 = state_with(&[1, 4]);
        set_stage(&mut state2, room);
        enter_stage(&mut state2, 4, source(), &mut effects);
        assert_eq!(*state2.channels[&4].stage.as_ref().unwrap().room(), room);
    }

    #[test]
    fn removing_the_return_clears_the_edges() {
        let mut state = state_with(&[1, 2, 3]);
        let mut effects = CommandEffects::default();
        set_return(
            &mut state,
            3,
            Some(Box::new(StageTail::new(SR, BLOCK))),
            &mut effects,
        );
        enter_stage(&mut state, 2, source(), &mut effects);
        forget_removed_channel(&mut state, 3);
        assert_eq!(state.stage.return_channel_id, None);
        assert_eq!(state.channels[&2].stage_feed, None);
    }

    #[test]
    fn channel_stage_params_are_sanitized() {
        let mut state = state_with(&[2]);
        set_channel_stage(
            &mut state,
            2,
            StageParams {
                x: f32::NAN,
                y: 7.0,
                size: -3.0,
                has_room: true,
                ..StageParams::default()
            },
        );
        let p = state.channels[&2].stage_params;
        assert_eq!((p.x, p.y, p.size), (0.0, 7.0, 0.0));
        assert!(p.has_room);
    }
}
