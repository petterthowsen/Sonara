//! AudioFileService routes: `/audiofile/*`.

use anyhow::Result;
use rosc::OscType;
use tracing::{debug, info, warn};

use crate::osc::server::OscServer;

impl OscServer {
    /// Handle the AudioFileService routes. Returns false for an address this area doesn't
    /// know, so the caller can report an unknown address.
    pub(super) fn route_audiofile(&self, parts: &[&str], args: &[OscType]) -> Result<bool> {
        match parts {
            // AudioFile service routes
            ["audiofile", "decode"] => {
                if let (Some(OscType::String(req_id)), Some(OscType::String(abs_path))) =
                    (args.get(0), args.get(1))
                {
                    info!("AudioFile decode request: {} for {}", req_id, abs_path);
                    if let Ok(afs) = self.audio_file_service.lock() {
                        let _ = afs.submit_decode_and_waveform(req_id.clone(), abs_path.clone());
                    }
                }
            }
            ["audiofile", "waveform", "start"] => {
                if let (Some(OscType::String(req_id)), Some(OscType::String(abs_path))) =
                    (args.get(0), args.get(1))
                {
                    info!("AudioFile waveform request: {} for {}", req_id, abs_path);
                    if let Ok(afs) = self.audio_file_service.lock() {
                        let _ = afs.submit_decode_and_waveform(req_id.clone(), abs_path.clone());
                    }
                }
            }
            ["audiofile", "samples"] => {
                // s:req_id s:cache_key i:channel i|h:start_frame i:count
                let as_u64 = |a: Option<&OscType>| match a {
                    Some(OscType::Int(v)) if *v >= 0 => Some(*v as u64),
                    Some(OscType::Long(v)) if *v >= 0 => Some(*v as u64),
                    _ => None,
                };
                if let (
                    Some(OscType::String(req_id)),
                    Some(OscType::String(cache_key)),
                    Some(channel),
                    Some(start_frame),
                    Some(count),
                ) = (
                    args.get(0),
                    args.get(1),
                    as_u64(args.get(2)),
                    as_u64(args.get(3)),
                    as_u64(args.get(4)),
                ) {
                    debug!(
                        request_id = %req_id,
                        cache_key = %cache_key,
                        channel,
                        start_frame,
                        count,
                        "AudioFile samples request"
                    );
                    if let Ok(afs) = self.audio_file_service.lock() {
                        let _ = afs.request_samples(
                            req_id.clone(),
                            cache_key.clone(),
                            channel as u16,
                            start_frame,
                            count as usize,
                        );
                    }
                } else {
                    warn!("/audiofile/samples: bad arguments {:?}", args);
                }
            }
            ["audiofile", "waveform", "cancel"] => {
                if let Some(OscType::String(req_id)) = args.first() {
                    info!("AudioFile cancel request: {}", req_id);
                    if let Ok(afs) = self.audio_file_service.lock() {
                        let _ = afs.cancel_job(req_id.clone());
                    }
                }
            }

            _ => return Ok(false),
        }
        Ok(true)
    }
}
