//! AudioFileService routes: `/audiofile/*`.

use anyhow::Result;
use rosc::OscType;
use tracing::{debug, info};

use super::RouteCtx;
use crate::osc::parse::Args;

/// Handle the AudioFileService routes. Returns false for an address this area doesn't
/// know, so the caller can report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        // AudioFile service routes
        ["audiofile", "decode"] => {
            let (req_id, abs_path) = (a.string(0)?, a.string(1)?);
            info!("AudioFile decode request: {} for {}", req_id, abs_path);
            if let Ok(afs) = cx.server.audio_file_service.lock() {
                let _ = afs.submit_decode_and_waveform(req_id.to_string(), abs_path.to_string());
            }
        }
        ["audiofile", "waveform", "start"] => {
            let (req_id, abs_path) = (a.string(0)?, a.string(1)?);
            info!("AudioFile waveform request: {} for {}", req_id, abs_path);
            if let Ok(afs) = cx.server.audio_file_service.lock() {
                let _ = afs.submit_decode_and_waveform(req_id.to_string(), abs_path.to_string());
            }
        }
        ["audiofile", "samples"] => {
            // s:req_id s:cache_key i:channel i|h:start_frame i:count
            let (req_id, cache_key) = (a.string(0)?, a.string(1)?);
            let (channel, start_frame, count) = (a.unsigned(2)?, a.unsigned(3)?, a.unsigned(4)?);
            debug!(
                request_id = %req_id,
                cache_key = %cache_key,
                channel,
                start_frame,
                count,
                "AudioFile samples request"
            );
            if let Ok(afs) = cx.server.audio_file_service.lock() {
                let _ = afs.request_samples(
                    req_id.to_string(),
                    cache_key.to_string(),
                    channel as u16,
                    start_frame,
                    count as usize,
                );
            }
        }
        ["audiofile", "waveform", "cancel"] => {
            let req_id = a.string(0)?;
            info!("AudioFile cancel request: {}", req_id);
            if let Ok(afs) = cx.server.audio_file_service.lock() {
                let _ = afs.cancel_job(req_id.to_string());
            }
        }

        _ => return Ok(false),
    }
    Ok(true)
}
