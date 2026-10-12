//! Realtime scheduling for the threads that process audio outside cpal's own callback.
//!
//! The promotion asks rtkit over D-Bus, which blocks and fails on a thread that is already
//! realtime. So call it once, from the thread being promoted, before it does any audio work, and
//! keep the returned handle alive for as long as the thread runs. A denied request (no rtkit, no
//! D-Bus, burst limit) is not an error for the caller: the thread keeps running with normal
//! priority.

use audio_thread_priority::{promote_current_thread_to_real_time, RtPriorityHandle};
use tracing::{info, warn};

/// Outcome of a promotion request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RealtimeState {
    Granted,
    Denied,
}

impl RealtimeState {
    /// The value stored in `Doorbell::audio_realtime` (0 means unknown).
    pub fn as_u32(self) -> u32 {
        match self {
            RealtimeState::Granted => 1,
            RealtimeState::Denied => 2,
        }
    }
}

/// Promote the calling thread to realtime. `frames` and `rate` describe the audio period the
/// thread serves; rtkit derives the deadline from them. Logs the result under `label`.
///
/// The handle is `Some` when granted. Keep it until the thread exits.
pub fn promote_current_thread(
    label: &str,
    frames: u32,
    rate: u32,
) -> (RealtimeState, Option<RtPriorityHandle>) {
    match promote_current_thread_to_real_time(frames, rate) {
        Ok(handle) => {
            info!("Realtime priority granted for {label} ({frames} frames at {rate} Hz)");
            (RealtimeState::Granted, Some(handle))
        }
        Err(e) => {
            warn!("Realtime priority denied for {label}: {e}");
            (RealtimeState::Denied, None)
        }
    }
}
