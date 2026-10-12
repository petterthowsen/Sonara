//! Browser sample preview commands (spec 037). The decode runs in the AudioFileService; these
//! only swap the finished PCM in and change the player's state, and every state change answers
//! with a `/preview/status`.

use crate::audio::commands::{CommandEffects, EngineStatus};
use crate::audio::state::EngineState;
use tracing::{info, warn};

/// Stop what plays and wait for the decode `req_id` of `path`.
pub(super) fn begin(
    state: &mut EngineState,
    req_id: String,
    path: &str,
    start_s: f32,
    effects: &mut CommandEffects,
) -> Option<EngineStatus> {
    info!("Preview: loading {} (req_id={})", path, req_id);
    state.preview.begin_load(req_id, path, start_s, effects);
    Some(state.preview.status())
}

/// Decoded PCM arrived. A result for a request that a newer play or a stop replaced is dropped.
pub(super) fn load(
    state: &mut EngineState,
    req_id: &str,
    samples: Vec<f32>,
    channels: usize,
    sample_rate: u32,
    effects: &mut CommandEffects,
) -> Option<EngineStatus> {
    if !state
        .preview
        .finish_load(req_id, samples, channels, sample_rate, effects)
    {
        info!("Preview: ignoring stale decode {}", req_id);
        return None;
    }
    Some(state.preview.status())
}

pub(super) fn fail(state: &mut EngineState, req_id: &str, message: &str) -> Option<EngineStatus> {
    if !state.preview.fail_load(req_id) {
        return None;
    }
    warn!("Preview: decode failed (req_id={}): {}", req_id, message);
    Some(state.preview.status())
}

/// Play the PCM that is already loaded.
pub(super) fn play_loaded(
    state: &mut EngineState,
    path: &str,
    start_s: f32,
) -> Option<EngineStatus> {
    if !state.preview.play_loaded(path, start_s) {
        warn!("Preview: {} is not loaded", path);
        return None;
    }
    Some(state.preview.status())
}

pub(super) fn stop(state: &mut EngineState, effects: &mut CommandEffects) -> Option<EngineStatus> {
    state.preview.stop(effects);
    Some(state.preview.status())
}

pub(super) fn seek(state: &mut EngineState, pos_s: f32) -> Option<EngineStatus> {
    state.preview.seek_seconds(pos_s);
    Some(state.preview.status())
}
