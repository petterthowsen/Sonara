//! Project routes: `/project/*`.

use anyhow::Result;
use rosc::OscType;
use tracing::{info, warn};

use super::RouteCtx;
use crate::audio::AudioCommand;
use crate::audio::ProjectSettings;
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
        }
        ["project", "scale"] => {
            let mask = a.int(0)?;
            cx.commands
                .send(AudioCommand::SetProjectScale((mask as u32 & 0x0FFF) as u16))?;
        }
        ["project", "clear"] => {
            info!("Clear project");
            cx.commands.send(AudioCommand::ClearProject)?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}
