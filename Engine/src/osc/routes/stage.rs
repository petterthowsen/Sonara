//! Virtual Stage routes (spec 051): `/stage/*`. The per-channel placement is
//! `/channel/{id}/stage` in `channel.rs`.

use anyhow::Result;
use rosc::OscType;

use super::RouteCtx;
use crate::audio::stage::{OutputMode, RoomModel, SurfaceMaterial, Vec3};
use crate::audio::AudioCommand;
use crate::osc::parse::{ArgError, Args};

/// Arguments of `/stage/set`: 8 floats, 2 ints, then a gain and a damping for each of 6 surfaces.
const STAGE_SET_ARGS: usize = 8 + 2 + 12;

/// Handle stage routes: `/stage/*`. Returns false for an address this area doesn't know, so the
/// caller can try the next area or report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        ["stage", "set"] => {
            let room = parse_stage_set(&a)?;
            cx.commands.send(AudioCommand::SetStage { room })?;
        }
        ["stage", "return"] => {
            cx.commands.send(AudioCommand::SetStageReturn {
                id: a.non_negative(0)?,
            })?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}

/// Read a `/stage/set` message into a room: width, depth, height, listener x, y, z, decay, tail
/// dB, Distance delay, output mode, then (gain, damping) for front, back, left, right, floor and
/// ceiling. The engine clamps the values when it applies them.
fn parse_stage_set(a: &Args) -> Result<RoomModel, ArgError> {
    a.exactly(STAGE_SET_ARGS)?;
    let mut surfaces = [SurfaceMaterial::default(); 6];
    for (i, surface) in surfaces.iter_mut().enumerate() {
        surface.gain = a.float_or_int(10 + i * 2)?;
        surface.hf_damping = a.float_or_int(11 + i * 2)?;
    }
    Ok(RoomModel {
        width: a.float_or_int(0)?,
        depth: a.float_or_int(1)?,
        height: a.float_or_int(2)?,
        listener: Vec3::new(a.float_or_int(3)?, a.float_or_int(4)?, a.float_or_int(5)?),
        decay_s: a.float_or_int(6)?,
        tail_db: a.float_or_int(7)?,
        distance_delay: a.bool(8)?,
        output_mode: OutputMode::from(a.int(9)?),
        surfaces,
    })
}
