//! One absolute deadline per audio callback, shared with plugins that process out of process.
//!
//! `SubprocessClapAdapter` waits for its host process inside the callback. Fixed per-plugin
//! shares would cut off a slow plugin while fast ones leave their time unused, so the engine
//! publishes a single deadline for the whole callback here and every plugin waits against it.
//!
//! The deadline is stored as microseconds since the clock's creation so the audio thread can
//! read it without a lock. One engine callback sets it before mixing; plugin adapters read it.
//!
//! An offline render (`audio/render`) switches the clock to offline mode. Its deadline is kept
//! apart from the live one, so a live callback that publishes late can't cut a render block
//! short, and a missed block is counted for the render to fail on instead of being dropped.

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Fraction of the block time plugins may use before the engine gives up on them. Overridden
/// with `SONARA_PLUGIN_DEADLINE_FRACTION` (clamped to 0.1–0.95).
const DEFAULT_DEADLINE_FRACTION: f32 = 0.7;

/// How long a plugin may take for one block of an offline render before the render fails.
pub const OFFLINE_BLOCK_TIMEOUT: Duration = Duration::from_secs(2);

/// Shared per-callback deadline. Attach one to the engine state; adapters hold a clone.
pub struct BlockClock {
    /// Fixed reference so the deadline can live in an atomic. Monotonic `Instant` isn't
    /// representable as a plain integer otherwise.
    start: Instant,
    /// Absolute deadline as microseconds since `start`; 0 means "no deadline published".
    deadline_us: AtomicI64,
    /// Fraction of block time plugins get. Read from the environment once at construction.
    fraction: f32,
    /// An offline render owns the clock: `deadline` returns `offline_deadline_us`.
    offline: AtomicBool,
    /// The render block's deadline, same encoding as `deadline_us`.
    offline_deadline_us: AtomicI64,
    /// Plugin blocks that missed an offline deadline since the last `take_offline_misses`.
    offline_misses: AtomicU64,
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
            offline: AtomicBool::new(false),
            offline_deadline_us: AtomicI64::new(0),
            offline_misses: AtomicU64::new(0),
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

    /// The absolute deadline, or None when none was published. While offline, the render
    /// block's deadline.
    pub fn deadline(&self) -> Option<Instant> {
        let at = if self.is_offline() {
            self.offline_deadline_us.load(Ordering::Relaxed)
        } else {
            self.deadline_us.load(Ordering::Relaxed)
        };
        if at <= 0 {
            return None;
        }
        Some(self.start + Duration::from_micros(at as u64))
    }

    /// Enter offline mode for a render: plugins wait on the render's deadlines and misses are
    /// counted. Clears the miss count.
    pub fn begin_offline(&self) {
        self.offline_misses.store(0, Ordering::Relaxed);
        self.offline_deadline_us.store(0, Ordering::Relaxed);
        self.offline.store(true, Ordering::Release);
    }

    /// Leave offline mode; the live callback's deadline applies again.
    pub fn end_offline(&self) {
        self.offline.store(false, Ordering::Release);
    }

    pub fn is_offline(&self) -> bool {
        self.offline.load(Ordering::Acquire)
    }

    /// Publish the deadline for an offline block starting now: `OFFLINE_BLOCK_TIMEOUT` away.
    pub fn publish_offline_block(&self) {
        let offset = Instant::now().saturating_duration_since(self.start) + OFFLINE_BLOCK_TIMEOUT;
        self.offline_deadline_us
            .store(offset.as_micros() as i64, Ordering::Relaxed);
    }

    /// A plugin missed the offline deadline: the block it returned is dry, so the render is
    /// corrupt. Called by plugin adapters while `is_offline`.
    pub fn record_offline_miss(&self) {
        self.offline_misses.fetch_add(1, Ordering::Relaxed);
    }

    /// Offline misses since the last call.
    pub fn take_offline_misses(&self) -> u64 {
        self.offline_misses.swap(0, Ordering::Relaxed)
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
    fn offline_deadline_ignores_live_publishes() {
        let clock = BlockClock::with_fraction(0.5);
        clock.begin_offline();
        clock.publish_offline_block();
        // A live callback publishing late doesn't shorten the render block's deadline.
        clock.publish(Instant::now(), Duration::from_millis(1));
        let remaining = clock.deadline().unwrap() - Instant::now();
        assert!(remaining > OFFLINE_BLOCK_TIMEOUT / 2);

        clock.record_offline_miss();
        assert_eq!(clock.take_offline_misses(), 1);
        assert_eq!(clock.take_offline_misses(), 0);

        clock.end_offline();
        assert!(clock.deadline().unwrap() <= Instant::now() + Duration::from_millis(1));
    }

    #[test]
    fn fraction_is_clamped() {
        let clock = BlockClock::with_fraction(5.0);
        clock.publish(Instant::now(), Duration::from_millis(100));
        let remaining = clock.deadline().unwrap() - Instant::now();
        assert!(remaining <= Duration::from_millis(95));
    }
}
