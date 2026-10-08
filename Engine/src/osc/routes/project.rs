//! Project routes: `/project/*`.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::{info, warn};

use crate::audio::AudioCommand;
use crate::audio::ProjectSettings;
use crate::logging::{rotate_log_files, LogWriters};
use crate::osc::server::OscServer;

impl OscServer {
    /// Handle project routes: `/project/*`. Returns false for an address this area doesn't
    /// know, so the caller can try the next area or report an unknown address.
    pub(super) fn route_project(
        &self,
        parts: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
        log_writers: &LogWriters,
    ) -> Result<bool> {
        match parts {
            // Project setup
            ["project", "init"] => {
                if let (
                    Some(OscType::Float(tempo)),
                    Some(OscType::Int(num)),
                    Some(OscType::Int(den)),
                    Some(OscType::Int(ppq)),
                    Some(OscType::Int(sr)),
                ) = (
                    args.get(0),
                    args.get(1),
                    args.get(2),
                    args.get(3),
                    args.get(4),
                ) {
                    // Rotate log files before initializing new project
                    if let Err(e) = rotate_log_files(log_writers) {
                        warn!("Failed to rotate log file: {}", e);
                    }

                    info!(
                        "Initialize project: {}bpm {}/{} PPQ={} SR={}",
                        tempo, num, den, ppq, sr
                    );
                    let settings = ProjectSettings {
                        tempo: *tempo,
                        time_numerator: *num,
                        time_denominator: *den,
                        ppq: *ppq,
                        sample_rate: *sr,
                        // The scale follows in its own `/project/scale` message.
                        scale_mask: 0,
                    };
                    command_tx.send(AudioCommand::InitProject(settings))?;

                    // Send confirmation that engine is ready
                    match self.send_message("/status/connected", vec![OscType::Int(1)]) {
                        Ok(_) => info!("Sent /status/connected to Godot"),
                        Err(e) => warn!("Failed to send /status/connected: {}", e),
                    }
                } else {
                    warn!(
                        "/project/init ignored (expected f,i,i,i,i); args={:?}",
                        args
                    );
                }
            }
            ["project", "scale"] => {
                if let Some(OscType::Int(mask)) = args.first() {
                    command_tx.send(AudioCommand::SetProjectScale(
                        (*mask as u32 & 0x0FFF) as u16,
                    ))?;
                } else {
                    warn!("/project/scale ignored (expected i); args={:?}", args);
                }
            }
            ["project", "clear"] => {
                info!("Clear project");
                command_tx.send(AudioCommand::ClearProject)?;
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
}
