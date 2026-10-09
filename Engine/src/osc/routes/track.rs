//! Track routes: `/track/{id}/*`, including automation and clip instances.

use anyhow::Result;
use rosc::OscType;
use tracing::{info, warn};

use super::RouteCtx;
use crate::audio::automation::{AutomationPoint, AutomationPointId, AutomationTarget, CurveKind};
use crate::audio::AudioCommand;
use crate::osc::parse::{segment, ArgError, Args};

/// Handle track routes: `/track/{id}/*`, including automation and clip instances. Returns false for an address this area doesn't
/// know, so the caller can try the next area or report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        // Track management - path-based: /track/{id}/{command}
        ["track", id_str, "create"] => {
            let id: usize = segment(cx.addr, id_str)?;
            let channel_id = a.int(0)?;
            info!("Create track {} -> channel {}", id, channel_id);
            cx.commands.send(AudioCommand::CreateTrack {
                id,
                channel_id: channel_id as usize,
            })?;
        }
        ["track", id_str, "route"] => {
            let id: usize = segment(cx.addr, id_str)?;
            let channel_id = a.int(0)?;
            info!("Route track {} to channel {}", id, channel_id);
            cx.commands.send(AudioCommand::SetTrackRoute {
                id,
                channel_id: channel_id as usize,
            })?;
        }

        // Automation - path-based: /track/{id}/automation/...
        ["track", id_str, "automation", "create"] => {
            let track_id: usize = segment(cx.addr, id_str)?;
            let (lane_id, target) = (a.string(0)?, a.string(1)?);
            match AutomationTarget::parse(target) {
                Some(target) => {
                    info!(
                        "Create automation lane {} on track {} targeting {}",
                        lane_id, track_id, target
                    );
                    cx.commands.send(AudioCommand::CreateAutomationLane {
                        track_id,
                        lane_id: lane_id.to_string(),
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
        ["track", id_str, "automation", lane_id, "delete"] => {
            let track_id: usize = segment(cx.addr, id_str)?;
            info!("Delete automation lane {} on track {}", lane_id, track_id);
            cx.commands.send(AudioCommand::DeleteAutomationLane {
                track_id,
                lane_id: lane_id.to_string(),
            })?;
        }
        ["track", id_str, "automation", lane_id, "bypass"] => {
            let track_id: usize = segment(cx.addr, id_str)?;
            let bypassed = a.int(0)?;
            info!(
                "Set automation lane {} on track {} bypass={}",
                lane_id, track_id, bypassed
            );
            cx.commands.send(AudioCommand::SetAutomationLaneBypass {
                track_id,
                lane_id: lane_id.to_string(),
                bypassed: bypassed != 0,
            })?;
        }
        ["track", id_str, "automation", lane_id, "add_point"] => {
            let track_id: usize = segment(cx.addr, id_str)?;
            let point = parse_automation_point(&a)?;
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
        ["track", id_str, "automation", lane_id, "update_point"] => {
            let track_id: usize = segment(cx.addr, id_str)?;
            let point = parse_automation_point(&a)?;
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
        ["track", id_str, "automation", lane_id, "remove_point"] => {
            let track_id: usize = segment(cx.addr, id_str)?;
            let point_id = a.int(0)?;
            info!(
                "Remove automation point {} from lane {} on track {}",
                point_id, lane_id, track_id
            );
            cx.commands.send(AudioCommand::RemoveAutomationPoint {
                track_id,
                lane_id: lane_id.to_string(),
                point_id: point_id as AutomationPointId,
            })?;
        }
        ["track", id_str, "automation", lane_id, "clear"] => {
            let track_id: usize = segment(cx.addr, id_str)?;
            info!("Clear automation lane {} on track {}", lane_id, track_id);
            cx.commands.send(AudioCommand::ClearAutomationLane {
                track_id,
                lane_id: lane_id.to_string(),
            })?;
        }

        // ClipInstance management - path-based: /track/{track_id}/instance/{command}
        ["track", track_id_str, "add_instance"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let (instance_id, clip_id) = (a.string(0)?, a.string(1)?);
            let (start_tick, duration) = (a.int(2)?, a.int(3)?);
            info!(
                "Add clip instance {} to track {}: clip {} at tick {} duration {}",
                instance_id, track_id, clip_id, start_tick, duration
            );
            cx.commands.send(AudioCommand::CreateClipInstance {
                track_id,
                instance_id: instance_id.to_string(),
                clip_id: clip_id.to_string(),
                start_tick: start_tick as i64,
                duration_ticks: duration as i64,
            })?;
        }
        ["track", track_id_str, "remove_instance"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let instance_id = a.string(0)?;
            info!(
                "Remove clip instance {} from track {}",
                instance_id, track_id
            );
            cx.commands.send(AudioCommand::RemoveClipInstance {
                track_id,
                instance_id: instance_id.to_string(),
            })?;
        }
        ["track", track_id_str, "instance", instance_id_str, "set_position"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let (start_tick, duration, clip_offset) = (a.int(0)?, a.int(1)?, a.int(2)?);
            info!(
                "Set instance {} position: start {} duration {} offset {}",
                instance_id_str, start_tick, duration, clip_offset
            );
            cx.commands.send(AudioCommand::UpdateClipInstancePosition {
                track_id,
                instance_id: instance_id_str.to_string(),
                start_tick: start_tick as i64,
                duration_ticks: duration as i64,
                clip_offset: clip_offset as i64,
            })?;
        }
        ["track", track_id_str, "instance", instance_id_str, "set_transpose"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let semitones = a.int(0)?;
            info!(
                "Set instance {} transpose: {} semitones",
                instance_id_str, semitones
            );
            cx.commands
                .send(AudioCommand::UpdateClipInstanceTranspose {
                    track_id,
                    instance_id: instance_id_str.to_string(),
                    transpose: semitones as i8,
                })?;
        }
        ["track", track_id_str, "instance", instance_id_str, "set_gain"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let db = a.float(0)?;
            info!("Set instance {} gain: {} dB", instance_id_str, db);
            cx.commands.send(AudioCommand::UpdateClipInstanceGain {
                track_id,
                instance_id: instance_id_str.to_string(),
                gain_db: db,
            })?;
        }
        ["track", track_id_str, "instance", instance_id_str, "set_mute"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let muted = a.int(0)?;
            info!("Set instance {} mute: {}", instance_id_str, muted);
            cx.commands.send(AudioCommand::UpdateClipInstanceMute {
                track_id,
                instance_id: instance_id_str.to_string(),
                muted: muted != 0,
            })?;
        }
        ["track", track_id_str, "instance", instance_id_str, "set_loop"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let (enabled, start_tick, length) = (a.int(0)?, a.int(1)?, a.int(2)?);
            info!(
                "Set instance {} loop: enabled={} start={} length={}",
                instance_id_str, enabled, start_tick, length
            );
            cx.commands.send(AudioCommand::UpdateClipInstanceLoop {
                track_id,
                instance_id: instance_id_str.to_string(),
                enabled: enabled != 0,
                start_tick: start_tick as i64,
                length_ticks: length as i64,
            })?;
        }
        ["track", track_id_str, "instance", instance_id_str, "set_reverse"] => {
            let track_id: usize = segment(cx.addr, track_id_str)?;
            let reverse = a.int(0)?;
            info!("Set instance {} reverse: {}", instance_id_str, reverse);
            cx.commands.send(AudioCommand::UpdateClipInstanceReverse {
                track_id,
                instance_id: instance_id_str.to_string(),
                reverse: reverse != 0,
            })?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}

/// Parse the shared `i:point_id, i:tick, f:value, s:curve, f:tension` argument list used by
/// `/track/{id}/automation/{lane_id}/add_point` and `.../update_point`.
fn parse_automation_point(a: &Args) -> Result<AutomationPoint, ArgError> {
    let (point_id, tick, value, curve) = (a.int(0)?, a.int(1)?, a.float(2)?, a.string(3)?);
    // Tension is optional on the wire; phase-1 Godot always sends 0.0.
    let tension = a.opt_float(4).unwrap_or(0.0);
    Ok(AutomationPoint::new(
        point_id as AutomationPointId,
        tick as i64,
        value,
        CurveKind::parse(curve),
        tension,
    ))
}
