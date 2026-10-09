//! Device sleep state: lets idle devices skip processing after a stretch of silence.

use std::time::{Duration, Instant};

/// Audio silence threshold for sleep detection (-60dB)
const SLEEP_THRESHOLD: f32 = 0.001;

/// Default sleep timeout (3 seconds of inactivity)
const DEFAULT_SLEEP_TIMEOUT: Duration = Duration::from_secs(3);

/// Helper struct for tracking device sleep state (CPU optimization)
///
/// Usage:
/// 1. Call `mark_activity()` when MIDI/parameter changes occur
/// 2. Call `check_activity(has_audio)` before processing
/// 3. Use `is_sleeping()` to skip expensive processing
pub struct DeviceSleepState {
    last_activity_time: Instant,
    is_sleeping: bool,
    sleep_timeout: Duration,
}

impl DeviceSleepState {
    pub fn new() -> Self {
        Self {
            last_activity_time: Instant::now(),
            is_sleeping: false,
            sleep_timeout: DEFAULT_SLEEP_TIMEOUT,
        }
    }

    /// Mark activity (MIDI input, parameter change, etc.)
    /// Wakes device immediately
    pub fn mark_activity(&mut self) {
        self.last_activity_time = Instant::now();
        self.is_sleeping = false;
    }

    /// Check if device has had recent activity
    /// Returns true if state changed (for status events)
    pub fn check_activity(&mut self, has_audio_activity: bool) -> bool {
        let old_sleeping = self.is_sleeping;

        if has_audio_activity {
            // Audio activity detected - mark activity
            self.last_activity_time = Instant::now();
            self.is_sleeping = false;
        } else {
            // No audio - check if timeout elapsed
            let elapsed = self.last_activity_time.elapsed();
            if elapsed >= self.sleep_timeout {
                self.is_sleeping = true;
            }
        }

        // Return true if state changed
        old_sleeping != self.is_sleeping
    }

    pub fn is_sleeping(&self) -> bool {
        self.is_sleeping
    }

    pub fn set_sleep_timeout(&mut self, timeout: Duration) {
        self.sleep_timeout = timeout;
    }
}

impl Default for DeviceSleepState {
    fn default() -> Self {
        Self::new()
    }
}

/// Check if audio buffer has signal above sleep threshold
pub fn has_audio_signal(buffer: &[f32]) -> bool {
    buffer.iter().any(|&sample| sample.abs() > SLEEP_THRESHOLD)
}
