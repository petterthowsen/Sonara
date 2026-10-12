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

/// Ignore SIGXCPU for the whole process. Call once at startup, before any thread is promoted.
///
/// Every promotion (ours, and cpal's for the engine callback) sets the soft `RLIMIT_RTTIME` to one
/// audio period, and the limit is process-wide. A single block that runs longer than its period
/// without blocking, such as a heavy sfizz render while a large project loads, then raises SIGXCPU,
/// whose default action kills the process with a core dump. Ignored, that block is an xrun. The
/// hard limit (rtkit's `RTTimeUSecMax`, 200 ms by default) still ends a runaway thread with SIGKILL.
pub fn ignore_cpu_time_signal() {
    // SAFETY: setting a signal's disposition to SIG_IGN installs no handler code and touches no
    // Rust state.
    if unsafe { libc::signal(libc::SIGXCPU, libc::SIG_IGN) } == libc::SIG_ERR {
        warn!("Could not ignore SIGXCPU; an overrunning realtime block will end the process");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_time_signal_does_not_end_the_process() {
        ignore_cpu_time_signal();
        // Unignored, this kills the test binary with a core dump.
        assert_eq!(unsafe { libc::raise(libc::SIGXCPU) }, 0);
    }
}
