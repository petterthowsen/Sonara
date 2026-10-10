//! Track commands: creation, routing, and automation lanes and points.
//!
//! The automation commands only mutate lane data. They send no `EngineStatus`, so playback never
//! rewrites what Godot has stored and saves.

use crate::audio::automation::{
    AutomationLane, AutomationLaneId, AutomationPoint, AutomationPointId, AutomationTarget,
};
use crate::audio::commands::EngineStatus;
use crate::audio::state::EngineState;
use crate::audio::track::Track;
use crate::audio::types::{ChannelId, TrackId};
use tracing::{info, warn};

/// Create a track routed to a channel.
pub(super) fn create_track(state: &mut EngineState, id: TrackId, channel_id: ChannelId) {
    let track = Track::new(id, channel_id);
    state.tracks.insert(id, track);
    info!("Track {} created, routed to channel {}", id, channel_id);
}

/// Point a track at a different channel.
pub(super) fn set_track_route(state: &mut EngineState, id: TrackId, channel_id: ChannelId) {
    if let Some(track) = state.tracks.get_mut(&id) {
        track.channel_id = channel_id;
        info!("Track {} routed to channel {}", id, channel_id);
    } else {
        warn!("Cannot set route for track {} (not found)", id);
    }
}

/// Add an automation lane to a track, ignoring a duplicate lane id.
///
/// Automation lane management. These arms only mutate lane data — they deliberately send no
/// `EngineStatus`, so playback never rewrites what Godot has stored and saves.
pub(super) fn create_automation_lane(
    state: &mut EngineState,
    track_id: TrackId,
    lane_id: AutomationLaneId,
    target: AutomationTarget,
) -> Option<EngineStatus> {
    let Some(track) = state.tracks.get_mut(&track_id) else {
        warn!(
            "Cannot create automation lane on track {} (not found)",
            track_id
        );
        return None;
    };
    if track.automation_lanes.iter().any(|l| l.id == lane_id) {
        warn!(
            "Automation lane {} already exists on track {} - ignoring duplicate create",
            lane_id, track_id
        );
        return None;
    }
    if let Some(existing) = track.automation_lanes.iter().find(|l| l.target == target) {
        // One lane per target per track (REQ-011): two lanes would fight over it.
        warn!(
            "Automation lane for {} already exists on track {} as lane {} - refusing create",
            target, track_id, existing.id
        );
        return None;
    }
    info!(
        "Automation lane {} created on track {} targeting {}",
        lane_id, track_id, target
    );
    track
        .automation_lanes
        .push(AutomationLane::new(lane_id, target));

    None
}

/// Delete an automation lane after handing its parameter back to the base value.
pub(super) fn delete_automation_lane(
    state: &mut EngineState,
    track_id: TrackId,
    lane_id: AutomationLaneId,
) -> Option<EngineStatus> {
    // Hand the parameter back to its base value before the lane disappears (REQ-004).
    crate::audio::automation::release_track_lane(state, track_id, &lane_id);
    let Some(track) = state.tracks.get_mut(&track_id) else {
        warn!(
            "Cannot delete automation lane on track {} (not found)",
            track_id
        );
        return None;
    };
    let before = track.automation_lanes.len();
    track.automation_lanes.retain(|l| l.id != lane_id);
    if track.automation_lanes.len() == before {
        warn!(
            "Automation lane {} not found on track {} for delete",
            lane_id, track_id
        );
    } else {
        info!(
            "Automation lane {} deleted from track {}",
            lane_id, track_id
        );
    }

    None
}

/// Bypass or re-enable an automation lane; bypassing restores the base value at once.
pub(super) fn set_automation_lane_bypass(
    state: &mut EngineState,
    track_id: TrackId,
    lane_id: AutomationLaneId,
    bypassed: bool,
) {
    if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "bypass") {
        lane.bypassed = bypassed;
        info!(
            "Automation lane {} on track {} bypass={}",
            lane_id, track_id, bypassed
        );
        if bypassed {
            // Restore the base value now rather than waiting for the next buffer, so a
            // bypass with the transport stopped is audible immediately (REQ-009).
            crate::audio::automation::release_track_lane(state, track_id, &lane_id);
        }
    }
}

/// Insert a point into an automation lane.
pub(super) fn add_automation_point(
    state: &mut EngineState,
    track_id: TrackId,
    lane_id: AutomationLaneId,
    point: AutomationPoint,
) {
    if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "add point") {
        if lane.insert_point(point) {
            info!(
                "Automation point {} added to lane {} on track {}: tick={} value={}",
                point.id, lane_id, track_id, point.tick, point.value
            );
        } else {
            warn!(
                "Automation point {} already exists in lane {} - ignoring duplicate add",
                point.id, lane_id
            );
        }
    }
}

/// Replace an automation point with the same id.
pub(super) fn update_automation_point(
    state: &mut EngineState,
    track_id: TrackId,
    lane_id: AutomationLaneId,
    point: AutomationPoint,
) {
    if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "update point") {
        if lane.update_point(point) {
            info!(
                "Automation point {} updated in lane {} on track {}: tick={} value={}",
                point.id, lane_id, track_id, point.tick, point.value
            );
        } else {
            warn!(
                "Automation point {} not found in lane {} for update",
                point.id, lane_id
            );
        }
    }
}

/// Remove a point from an automation lane.
pub(super) fn remove_automation_point(
    state: &mut EngineState,
    track_id: TrackId,
    lane_id: AutomationLaneId,
    point_id: AutomationPointId,
) {
    if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "remove point") {
        if lane.remove_point(point_id) {
            info!(
                "Automation point {} removed from lane {} on track {}",
                point_id, lane_id, track_id
            );
        } else {
            warn!(
                "Automation point {} not found in lane {} for removal",
                point_id, lane_id
            );
        }
    }
}

/// Remove every point of an automation lane.
pub(super) fn clear_automation_lane(
    state: &mut EngineState,
    track_id: TrackId,
    lane_id: AutomationLaneId,
) {
    if let Some(lane) = automation_lane_mut(state, track_id, &lane_id, "clear") {
        lane.clear_points();
        info!("Automation lane {} on track {} cleared", lane_id, track_id);
    }
}

/// Look up a lane for an automation command, warning once when the track or lane is missing.
fn automation_lane_mut<'a>(
    state: &'a mut EngineState,
    track_id: TrackId,
    lane_id: &str,
    action: &str,
) -> Option<&'a mut AutomationLane> {
    let Some(track) = state.tracks.get_mut(&track_id) else {
        warn!(
            "Cannot {} automation lane: track {} not found",
            action, track_id
        );
        return None;
    };
    let lane = track.automation_lane_mut(lane_id);
    if lane.is_none() {
        warn!(
            "Cannot {} automation lane {}: not found on track {}",
            action, lane_id, track_id
        );
    }
    lane
}
