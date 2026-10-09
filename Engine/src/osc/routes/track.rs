//! Track routes: `/track/{id}/*`, including automation and clip instances.

use anyhow::Result;
use rosc::OscType;
use tracing::{info, warn};

use super::RouteCtx;
use crate::audio::automation::{AutomationPoint, AutomationPointId, AutomationTarget, CurveKind};
use crate::audio::AudioCommand;

/// Handle track routes: `/track/{id}/*`, including automation and clip instances. Returns false for an address this area doesn't
/// know, so the caller can try the next area or report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    match parts {
        // Track management - path-based: /track/{id}/{command}
        ["track", id_str, "create"] => {
            if let (Ok(id), Some(OscType::Int(channel_id))) =
                (id_str.parse::<usize>(), args.first())
            {
                info!("Create track {} -> channel {}", id, channel_id);
                cx.commands.send(AudioCommand::CreateTrack {
                    id,
                    channel_id: *channel_id as usize,
                })?;
            }
        }
        ["track", id_str, "route"] => {
            if let (Ok(id), Some(OscType::Int(channel_id))) =
                (id_str.parse::<usize>(), args.first())
            {
                info!("Route track {} to channel {}", id, channel_id);
                cx.commands.send(AudioCommand::SetTrackRoute {
                    id,
                    channel_id: *channel_id as usize,
                })?;
            }
        }

        // Automation - path-based: /track/{id}/automation/...
        ["track", id_str, "automation", "create"] => {
            if let (Ok(track_id), Some(OscType::String(lane_id)), Some(OscType::String(target))) =
                (id_str.parse::<usize>(), args.get(0), args.get(1))
            {
                match AutomationTarget::parse(target) {
                    Some(target) => {
                        info!(
                            "Create automation lane {} on track {} targeting {}",
                            lane_id, track_id, target
                        );
                        cx.commands.send(AudioCommand::CreateAutomationLane {
                            track_id,
                            lane_id: lane_id.clone(),
                            target,
                        })?;
                    }
                    None => {
                        warn!(
                            "Unparseable automation target '{}' for lane {} on track {} - ignoring",
                            target, lane_id, track_id
                        );
                    }
                }
            }
        }
        ["track", id_str, "automation", lane_id, "delete"] => {
            if let Ok(track_id) = id_str.parse::<usize>() {
                info!("Delete automation lane {} on track {}", lane_id, track_id);
                cx.commands.send(AudioCommand::DeleteAutomationLane {
                    track_id,
                    lane_id: lane_id.to_string(),
                })?;
            }
        }
        ["track", id_str, "automation", lane_id, "bypass"] => {
            if let (Ok(track_id), Some(OscType::Int(bypassed))) =
                (id_str.parse::<usize>(), args.first())
            {
                info!(
                    "Set automation lane {} on track {} bypass={}",
                    lane_id, track_id, bypassed
                );
                cx.commands.send(AudioCommand::SetAutomationLaneBypass {
                    track_id,
                    lane_id: lane_id.to_string(),
                    bypassed: *bypassed != 0,
                })?;
            }
        }
        ["track", id_str, "automation", lane_id, "add_point"] => {
            if let (Ok(track_id), Some(point)) =
                (id_str.parse::<usize>(), parse_automation_point(args))
            {
                info!(
                    "Add automation point {} to lane {} on track {}: tick={} value={}",
                    point.id, lane_id, track_id, point.tick, point.value
                );
                cx.commands.send(AudioCommand::AddAutomationPoint {
                    track_id,
                    lane_id: lane_id.to_string(),
                    point,
                })?;
            }
        }
        ["track", id_str, "automation", lane_id, "update_point"] => {
            if let (Ok(track_id), Some(point)) =
                (id_str.parse::<usize>(), parse_automation_point(args))
            {
                info!(
                    "Update automation point {} in lane {} on track {}: tick={} value={}",
                    point.id, lane_id, track_id, point.tick, point.value
                );
                cx.commands.send(AudioCommand::UpdateAutomationPoint {
                    track_id,
                    lane_id: lane_id.to_string(),
                    point,
                })?;
            }
        }
        ["track", id_str, "automation", lane_id, "remove_point"] => {
            if let (Ok(track_id), Some(OscType::Int(point_id))) =
                (id_str.parse::<usize>(), args.first())
            {
                info!(
                    "Remove automation point {} from lane {} on track {}",
                    point_id, lane_id, track_id
                );
                cx.commands.send(AudioCommand::RemoveAutomationPoint {
                    track_id,
                    lane_id: lane_id.to_string(),
                    point_id: *point_id as AutomationPointId,
                })?;
            }
        }
        ["track", id_str, "automation", lane_id, "clear"] => {
            if let Ok(track_id) = id_str.parse::<usize>() {
                info!("Clear automation lane {} on track {}", lane_id, track_id);
                cx.commands.send(AudioCommand::ClearAutomationLane {
                    track_id,
                    lane_id: lane_id.to_string(),
                })?;
            }
        }

        // ClipInstance management - path-based: /track/{track_id}/instance/{command}
        ["track", track_id_str, "add_instance"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let (
                    Some(OscType::String(instance_id)),
                    Some(OscType::String(clip_id)),
                    Some(OscType::Int(start_tick)),
                    Some(OscType::Int(duration)),
                ) = (args.get(0), args.get(1), args.get(2), args.get(3))
                {
                    info!(
                        "Add clip instance {} to track {}: clip {} at tick {} duration {}",
                        instance_id, track_id, clip_id, start_tick, duration
                    );
                    cx.commands.send(AudioCommand::CreateClipInstance {
                        track_id,
                        instance_id: instance_id.clone(),
                        clip_id: clip_id.clone(),
                        start_tick: *start_tick as i64,
                        duration_ticks: *duration as i64,
                    })?;
                }
            }
        }
        ["track", track_id_str, "remove_instance"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let Some(OscType::String(instance_id)) = args.first() {
                    info!(
                        "Remove clip instance {} from track {}",
                        instance_id, track_id
                    );
                    cx.commands.send(AudioCommand::RemoveClipInstance {
                        track_id,
                        instance_id: instance_id.clone(),
                    })?;
                }
            }
        }
        ["track", track_id_str, "instance", instance_id_str, "set_position"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let (
                    Some(OscType::Int(start_tick)),
                    Some(OscType::Int(duration)),
                    Some(OscType::Int(clip_offset)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    info!(
                        "Set instance {} position: start {} duration {} offset {}",
                        instance_id_str, start_tick, duration, clip_offset
                    );
                    cx.commands.send(AudioCommand::UpdateClipInstancePosition {
                        track_id,
                        instance_id: instance_id_str.to_string(),
                        start_tick: *start_tick as i64,
                        duration_ticks: *duration as i64,
                        clip_offset: *clip_offset as i64,
                    })?;
                }
            }
        }
        ["track", track_id_str, "instance", instance_id_str, "set_transpose"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let Some(OscType::Int(semitones)) = args.first() {
                    info!(
                        "Set instance {} transpose: {} semitones",
                        instance_id_str, semitones
                    );
                    cx.commands
                        .send(AudioCommand::UpdateClipInstanceTranspose {
                            track_id,
                            instance_id: instance_id_str.to_string(),
                            transpose: *semitones as i8,
                        })?;
                }
            }
        }
        ["track", track_id_str, "instance", instance_id_str, "set_gain"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let Some(OscType::Float(db)) = args.first() {
                    info!("Set instance {} gain: {} dB", instance_id_str, db);
                    cx.commands.send(AudioCommand::UpdateClipInstanceGain {
                        track_id,
                        instance_id: instance_id_str.to_string(),
                        gain_db: *db,
                    })?;
                }
            }
        }
        ["track", track_id_str, "instance", instance_id_str, "set_mute"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let Some(OscType::Int(muted)) = args.first() {
                    info!("Set instance {} mute: {}", instance_id_str, muted);
                    cx.commands.send(AudioCommand::UpdateClipInstanceMute {
                        track_id,
                        instance_id: instance_id_str.to_string(),
                        muted: *muted != 0,
                    })?;
                }
            }
        }
        ["track", track_id_str, "instance", instance_id_str, "set_loop"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let (
                    Some(OscType::Int(enabled)),
                    Some(OscType::Int(start_tick)),
                    Some(OscType::Int(length)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    info!(
                        "Set instance {} loop: enabled={} start={} length={}",
                        instance_id_str, enabled, start_tick, length
                    );
                    cx.commands.send(AudioCommand::UpdateClipInstanceLoop {
                        track_id,
                        instance_id: instance_id_str.to_string(),
                        enabled: *enabled != 0,
                        start_tick: *start_tick as i64,
                        length_ticks: *length as i64,
                    })?;
                }
            }
        }
        ["track", track_id_str, "instance", instance_id_str, "set_reverse"] => {
            if let Ok(track_id) = track_id_str.parse::<usize>() {
                if let Some(OscType::Int(reverse)) = args.first() {
                    info!("Set instance {} reverse: {}", instance_id_str, reverse);
                    cx.commands.send(AudioCommand::UpdateClipInstanceReverse {
                        track_id,
                        instance_id: instance_id_str.to_string(),
                        reverse: *reverse != 0,
                    })?;
                }
            }
        }
        _ => return Ok(false),
    }
    Ok(true)
}

/// Parse the shared `i:point_id, i:tick, f:value, s:curve, f:tension` argument list used by
/// `/track/{id}/automation/{lane_id}/add_point` and `.../update_point`.
fn parse_automation_point(args: &[OscType]) -> Option<AutomationPoint> {
    let (
        Some(OscType::Int(point_id)),
        Some(OscType::Int(tick)),
        Some(OscType::Float(value)),
        Some(OscType::String(curve)),
    ) = (args.get(0), args.get(1), args.get(2), args.get(3))
    else {
        warn!("Malformed automation point arguments: {:?}", args);
        return None;
    };
    // Tension is optional on the wire; phase-1 Godot always sends 0.0.
    let tension = match args.get(4) {
        Some(OscType::Float(t)) => *t,
        _ => 0.0,
    };
    Some(AutomationPoint::new(
        *point_id as AutomationPointId,
        *tick as i64,
        *value,
        CurveKind::parse(curve),
        tension,
    ))
}
