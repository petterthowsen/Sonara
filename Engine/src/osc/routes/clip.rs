//! Clip routes: `/clip/*`.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::{info, warn};

use crate::audio::AudioCommand;
use crate::osc::audio_files::PendingClip;
use crate::osc::parse::osc_arg_types;
use crate::osc::server::OscServer;

impl OscServer {
    /// Handle clip routes: `/clip/*`. Returns false for an address this area doesn't
    /// know, so the caller can try the next area or report an unknown address.
    pub(super) fn route_clip(
        &self,
        addr: &str,
        parts: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
    ) -> Result<bool> {
        match parts {
            // Clip management - path-based: /clip/{id}/{command}
            ["clip", "create"] => {
                if let (
                    Some(OscType::String(id)),
                    Some(OscType::String(clip_type)),
                    Some(OscType::String(name)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    info!("Create clip {} ({}) - {}", id, clip_type, name);
                    command_tx.send(AudioCommand::CreateClip {
                        id: id.clone(),
                        name: name.clone(),
                        clip_type: clip_type.clone(),
                    })?;
                }
            }
            ["clip", "delete"] => {
                if let Some(OscType::String(id)) = args.first() {
                    info!("Delete clip {}", id);
                    command_tx.send(AudioCommand::RemoveClip { id: id.clone() })?;
                }
            }
            ["clip", id_str, "add_note"] => {
                if let Some(n) = parse_clip_note_args(addr, args) {
                    info!(
                        "Add note to clip {}: note_id {} note {} at tick {} duration {} vel {} rel {}",
                        id_str, n.note_id, n.note, n.start_tick, n.duration_ticks, n.velocity, n.release
                    );
                    command_tx.send(AudioCommand::AddNoteToClip {
                        clip_id: id_str.to_string(),
                        note_id: n.note_id,
                        note: n.note,
                        start_tick: n.start_tick,
                        duration_ticks: n.duration_ticks,
                        velocity: n.velocity,
                        release: n.release,
                    })?;
                }
            }
            ["clip", id_str, "remove_note"] => {
                if let Some(OscType::Int(note_id)) = args.first() {
                    info!("Remove note from clip {}: note_id {}", id_str, note_id);
                    command_tx.send(AudioCommand::RemoveNoteFromClip {
                        clip_id: id_str.to_string(),
                        note_id: *note_id as u64,
                    })?;
                }
            }
            ["clip", id_str, "update_note"] => {
                if let Some(n) = parse_clip_note_args(addr, args) {
                    info!(
                        "Update note in clip {}: note_id {} note {} at tick {} duration {} vel {} rel {}",
                        id_str, n.note_id, n.note, n.start_tick, n.duration_ticks, n.velocity, n.release
                    );
                    command_tx.send(AudioCommand::UpdateClipNote {
                        clip_id: id_str.to_string(),
                        note_id: n.note_id,
                        note: n.note,
                        start_tick: n.start_tick,
                        duration_ticks: n.duration_ticks,
                        velocity: n.velocity,
                        release: n.release,
                    })?;
                }
            }
            ["clip", id_str, "load_audio_file"] => {
                if let (
                    Some(OscType::String(file_path)),
                    Some(OscType::Int(_sample_rate)),
                    Some(OscType::Int(_channels)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    let req_id = Self::generate_clip_request_id(id_str);
                    info!(
                        "Requesting audio load for clip {} (req_id={}) from {}",
                        id_str, req_id, file_path
                    );

                    {
                        let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                        pending_guard.insert(
                            req_id.clone(),
                            PendingClip {
                                clip_id: id_str.to_string(),
                                source_path: file_path.clone(),
                            },
                        );
                    }

                    command_tx.send(AudioCommand::BeginLoadAudioClip {
                        clip_id: id_str.to_string(),
                        req_id: req_id.clone(),
                        source_path: file_path.clone(),
                    })?;

                    match self.audio_file_service.lock() {
                        Ok(service) => {
                            if let Err(err) = service
                                .submit_decode_and_waveform(req_id.clone(), file_path.clone())
                            {
                                warn!(
                                    "Failed to submit decode request for clip {} (req_id={}): {}",
                                    id_str, req_id, err
                                );
                                {
                                    let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                                    pending_guard.remove(&req_id);
                                }
                                let _ = command_tx.send(AudioCommand::FailAudioClipLoad {
                                    clip_id: id_str.to_string(),
                                    req_id: req_id.clone(),
                                    message: err.to_string(),
                                });
                            }
                        }
                        Err(err) => {
                            warn!(
                                "Failed to lock AudioFileService for clip {} (req_id={}): {}",
                                id_str, req_id, err
                            );
                            {
                                let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                                pending_guard.remove(&req_id);
                            }
                            let _ = command_tx.send(AudioCommand::FailAudioClipLoad {
                                clip_id: id_str.to_string(),
                                req_id: req_id.clone(),
                                message: "AudioFileService unavailable".to_string(),
                            });
                        }
                    }
                } else {
                    warn!(
                        "OSC: load_audio_file missing arguments: got {} args",
                        args.len()
                    );
                }
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
}

/// Arguments of `/clip/{id}/add_note` and `/clip/{id}/update_note`.
#[derive(Debug, PartialEq)]
struct ClipNoteArgs {
    note_id: u64,
    note: u8,
    start_tick: i64,
    duration_ticks: i64,
    velocity: f32,
    release: f32,
}

/// Parse `i:note_id i:note i:start_tick i:duration f:vel f:rel`. Any other shape (an old Godot
/// build still sending an int velocity, say) logs a warning instead of being dropped silently.
fn parse_clip_note_args(addr: &str, args: &[OscType]) -> Option<ClipNoteArgs> {
    if let [OscType::Int(note_id), OscType::Int(note), OscType::Int(start_tick), OscType::Int(duration), OscType::Float(velocity), OscType::Float(release)] =
        args
    {
        return Some(ClipNoteArgs {
            note_id: *note_id as u64,
            note: (*note).clamp(0, 127) as u8,
            start_tick: *start_tick as i64,
            duration_ticks: *duration as i64,
            velocity: velocity.clamp(0.0, 1.0),
            release: release.clamp(0.0, 1.0),
        });
    }
    warn!(
        "{}: expected args (i i i i f f), got ({})",
        addr,
        osc_arg_types(args)
    );
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clip_note_args_parse_floats_and_reject_old_shape() {
        let args = vec![
            OscType::Int(3),
            OscType::Int(60),
            OscType::Int(0),
            OscType::Int(480),
            OscType::Float(0.5039),
            OscType::Float(0.25),
        ];
        assert_eq!(
            parse_clip_note_args("/clip/x/add_note", &args),
            Some(ClipNoteArgs {
                note_id: 3,
                note: 60,
                start_tick: 0,
                duration_ticks: 480,
                velocity: 0.5039,
                release: 0.25,
            })
        );

        let old = vec![
            OscType::Int(1),
            OscType::Int(60),
            OscType::Int(0),
            OscType::Int(480),
            OscType::Int(100),
        ];
        assert_eq!(parse_clip_note_args("/clip/x/add_note", &old), None);
        assert_eq!(osc_arg_types(&old), "i i i i i");
    }
}
