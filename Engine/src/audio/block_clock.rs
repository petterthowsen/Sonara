//! One absolute deadline per audio callback, shared with plugins that process out of process.
//!
//! `SubprocessClapAdapter` waits for its host process inside the callback. Fixed per-plugin
//! shares would cut off a slow plugin while fast ones leave their time unused, so the engine
//! publishes a single deadline for the whole callback here and every plugin waits against it.
//!
//! The deadline is stored as microseconds since the clock's creation so the audio thread can
//! read it without a lock. One engine callback sets it before mixing; plugin adapters read it.

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, Instant};

/// Fraction of the block time plugins may use before the engine gives up on them. Overridden
/// with `SONARA_PLUGIN_DEADLINE_FRACTION` (clamped to 0.1–0.95).
const DEFAULT_DEADLINE_FRACTION: f32 = 0.7;

/// Shared per-callback deadline. Attach one to the engine state; adapters hold a clone.
pub struct BlockClock {
    /// Fixed reference so the deadline can live in an atomic. Monotonic `Instant` isn't
    /// representable as a plain integer otherwise.
    start: Instant,
    /// Absolute deadline as microseconds since `start`; 0 means "no deadline published".
    deadline_us: AtomicI64,
    /// Fraction of block time plugins get. Read from the environment once at construction.
    fraction: f32,
}

impl BlockClock {
    pub fn new() -> Self {
        Self::with_fraction(configured_fraction())
    }

    pub fn with_fraction(fraction: f32) -> Self {
        Self {
            start: Instant::now(),
            deadline_us: AtomicI64::new(0),
            fraction: fraction.clamp(0.1, 0.95),
        }
    }

    /// Publish the deadline for a callback that started at `callback_start` and lasts
    /// `block_duration`.
    pub fn publish(&self, callback_start: Instant, block_duration: Duration) {
        let budget = block_duration.mul_f32(self.fraction);
        let offset = callback_start.saturating_duration_since(self.start);
        let at = offset.as_micros() as i64 + budget.as_micros() as i64;
        self.deadline_us.store(at, Ordering::Relaxed);
    }

    /// The absolute deadline, or None when none was published.
    pub fn deadline(&self) -> Option<Instant> {
        let at = self.deadline_us.load(Ordering::Relaxed);
        if at <= 0 {
            return None;
        }
        Some(self.start + Duration::from_micros(at as u64))
    }
}

impl Default for BlockClock {
    fn default() -> Self {
        Self::new()
    }
}

fn configured_fraction() -> f32 {
    std::env::var("SONARA_PLUGIN_DEADLINE_FRACTION")
        .ok()
        .and_then(|value| value.parse::<f32>().ok())
        .unwrap_or(DEFAULT_DEADLINE_FRACTION)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn publishes_a_deadline() {
        let clock = BlockClock::with_fraction(0.5);
        assert!(clock.deadline().is_none());

        clock.publish(Instant::now(), Duration::from_millis(100));
        let remaining = clock.deadline().unwrap() - Instant::now();
        assert!(remaining <= Duration::from_millis(50));
        assert!(remaining > Duration::from_millis(40));
    }

    #[test]
    fn fraction_is_clamped() {
        let clock = BlockClock::with_fraction(5.0);
        clock.publish(Instant::now(), Duration::from_millis(100));
        let remaining = clock.deadline().unwrap() - Instant::now();
        assert!(remaining <= Duration::from_millis(95));
    }
}
