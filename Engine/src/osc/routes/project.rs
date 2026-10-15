//! Project routes: `/project/*`.

use anyhow::Result;
use rosc::OscType;
use tracing::{info, warn};

use super::RouteCtx;
use crate::audio::types::Tick;
use crate::audio::AudioCommand;
use crate::audio::ProjectSettings;
use crate::build_info;
use crate::logging::rotate_log_files;
use crate::osc::parse::Args;

/// Handle project routes: `/project/*`. Returns false for an address this area doesn't
/// know, so the caller can try the next area or report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        // Project setup
        ["project", "init"] => {
            let (tempo, num, den, ppq, sr) =
                (a.float(0)?, a.int(1)?, a.int(2)?, a.int(3)?, a.int(4)?);
            // Rotate log files before initializing new project
            if let Err(e) = rotate_log_files(cx.log_writers) {
                warn!("Failed to rotate log file: {}", e);
            }

            info!(
                "Initialize project: {}bpm {}/{} PPQ={} SR={}",
                tempo, num, den, ppq, sr
            );
            let settings = ProjectSettings {
                tempo,
                time_numerator: num,
                time_denominator: den,
                ppq,
                sample_rate: sr,
                // The scale follows in its own `/project/scale` message.
                scale_mask: 0,
            };
            cx.commands.send(AudioCommand::InitProject(settings))?;

            // Send confirmation that engine is ready
            match cx
                .server
                .send_message("/status/connected", vec![OscType::Int(1)])
            {
                Ok(_) => info!("Sent /status/connected to Godot"),
                Err(e) => warn!("Failed to send /status/connected: {}", e),
            }
            // Who we are, so the UI can compare versions (spec 046). Older engines never send it.
            if let Err(e) = cx.server.send_message(
                "/status/engine_info",
                vec![
                    OscType::String(build_info::VERSION.to_string()),
                    OscType::String(build_info::COMMIT.to_string()),
                    OscType::Int(build_info::PROTOCOL),
                ],
            ) {
                warn!("Failed to send /status/engine_info: {}", e);
            }
        }
        ["project", "scale"] => {
            let mask = a.int(0)?;
            cx.commands
                .send(AudioCommand::SetProjectScale((mask as u32 & 0x0FFF) as u16))?;
        }
        ["project", "scale_map"] => {
            let (changes, dropped) = parse_scale_map_args(args);
            if dropped {
                warn!("/project/scale_map: dropped malformed or out-of-range entries");
            }
            cx.commands.send(AudioCommand::SetScaleMap(changes))?;
        }
        ["project", "clear"] => {
            info!("Clear project");
            cx.commands.send(AudioCommand::ClearProject)?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}

/// Parse `/project/scale_map` args (`i:tick, i:mask` pairs). Malformed pairs (wrong arg types,
/// tick < 1 — tick 0 would be the base scale) are dropped and the flag is true; masks are clamped
/// to 12 bits. `ScaleMap::from_changes` then sorts, keeps the last of a duplicate tick and caps
/// the count.
fn parse_scale_map_args(args: &[OscType]) -> (Vec<(Tick, u16)>, bool) {
    let mut changes: Vec<(Tick, u16)> = Vec::with_capacity(args.len() / 2);
    let mut dropped = args.len() % 2 != 0;
    for pair in args.chunks_exact(2) {
        let (OscType::Int(tick), OscType::Int(mask)) = (&pair[0], &pair[1]) else {
            dropped = true;
            continue;
        };
        if *tick < 1 {
            dropped = true;
            continue;
        }
        changes.push((*tick as i64, (*mask as u32 & 0x0FFF) as u16));
    }
    (changes, dropped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_scale_map_args_filters() {
        let ints = |v: &[i32]| v.iter().map(|i| OscType::Int(*i)).collect::<Vec<_>>();

        let (c, dropped) = parse_scale_map_args(&ints(&[3840, 2741, 7680, 0]));
        assert_eq!(c, vec![(3840, 2741), (7680, 0)]);
        assert!(!dropped);

        // Empty clears the map, not an error.
        let (c, dropped) = parse_scale_map_args(&[]);
        assert!(c.is_empty() && !dropped);

        // Wrong types, a trailing lone int, tick 0 and a negative tick are dropped; masks clamp.
        let (c, dropped) = parse_scale_map_args(&[
            OscType::Int(960),
            OscType::Float(2741.0),
            OscType::Int(1920),
            OscType::Int(0xFFFF),
            OscType::Int(0),
            OscType::Int(500),
            OscType::Int(-3840),
            OscType::Int(500),
            OscType::Int(3840),
        ]);
        assert_eq!(c, vec![(1920, 0x0FFF)]);
        assert!(dropped);
    }
}
