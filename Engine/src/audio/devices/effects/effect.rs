//! Helpers shared by the built-in audio effects (spec 012).

/// Copy interleaved stereo input to output (bypass, not yet activated).
#[inline]
pub fn pass_through(inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
    let n = (sample_count * 2).min(inputs.len()).min(outputs.len());
    outputs[..n].copy_from_slice(&inputs[..n]);
}

/// Silence (input and output) that puts an effect to sleep, before its tail is added.
pub const SLEEP_AFTER_SECONDS: f32 = 3.0;

/// Sleep state for an effect with a tail (delay repeats, reverb decay).
///
/// The host keeps a device awake while its input or output has signal (`update_sleep_state`
/// gets `input || output` activity), and wakes a sleeping one when audio reaches it. On top of
/// that, an effect must stay awake while its tail may still come back above the threshold: a
/// 5 s delay is silent between repeats. So it sleeps only after `SLEEP_AFTER_SECONDS` plus its
/// tail of quiet, and never while the tail is infinite (freeze, feedback at or above 100 %).
///
/// Time is counted in processed frames, so it is deterministic and testable: call
/// [`TailSleep::on_block`] from `process_block`.
#[derive(Clone, Copy, Debug)]
pub struct TailSleep {
    sample_rate: f32,
    /// Frames of the block last processed, counted by the next `update`.
    last_block: usize,
    quiet_frames: u64,
    /// Extra quiet time the tail needs, in frames; None never sleeps.
    tail_frames: Option<u64>,
    sleeping: bool,
}

impl TailSleep {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            last_block: 0,
            quiet_frames: 0,
            tail_frames: Some(0),
            sleeping: false,
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
    }

    /// How long the effect can ring after its input stops, in seconds; None if it rings forever.
    /// Call it when a parameter that sets the tail changes.
    pub fn set_tail_seconds(&mut self, seconds: Option<f32>) {
        self.tail_frames = seconds.map(|s| (s.max(0.0) * self.sample_rate) as u64);
        if self.tail_frames.is_none() {
            self.wake();
        }
    }

    /// Record a processed block. Call from `process_block`.
    #[inline]
    pub fn on_block(&mut self, frames: usize) {
        self.last_block = frames;
    }

    /// Wake up (parameter change, MIDI) and restart the quiet count.
    pub fn wake(&mut self) {
        self.quiet_frames = 0;
        self.sleeping = false;
    }

    pub fn is_sleeping(&self) -> bool {
        self.sleeping
    }

    /// The host's `update_sleep_state`. Returns true when the sleep state changed.
    pub fn update(&mut self, has_audio_activity: bool) -> bool {
        let was_sleeping = self.sleeping;
        if has_audio_activity {
            self.wake();
        } else {
            self.quiet_frames += std::mem::take(&mut self.last_block) as u64;
            if let Some(tail) = self.tail_frames {
                let limit = (SLEEP_AFTER_SECONDS * self.sample_rate) as u64 + tail;
                if self.quiet_frames >= limit {
                    self.sleeping = true;
                }
            }
        }
        was_sleeping != self.sleeping
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f32 = 1_000.0;

    /// Quiet blocks of 100 frames until it sleeps; returns the frames it took (or None).
    fn frames_to_sleep(sleep: &mut TailSleep) -> Option<u64> {
        for block in 1..=1_000u64 {
            sleep.on_block(100);
            if sleep.update(false) {
                return Some(block * 100);
            }
        }
        None
    }

    #[test]
    fn sleeps_after_the_timeout_plus_the_tail() {
        let mut sleep = TailSleep::new(SR);
        assert_eq!(frames_to_sleep(&mut sleep), Some(3_000));

        let mut sleep = TailSleep::new(SR);
        sleep.set_tail_seconds(Some(5.0));
        assert_eq!(frames_to_sleep(&mut sleep), Some(8_000));
    }

    #[test]
    fn activity_restarts_the_count_and_an_infinite_tail_never_sleeps() {
        let mut sleep = TailSleep::new(SR);
        for _ in 0..20 {
            sleep.on_block(100);
            sleep.update(false);
        }
        sleep.on_block(100);
        assert!(!sleep.update(true));
        assert_eq!(frames_to_sleep(&mut sleep), Some(3_000));
        assert!(sleep.is_sleeping());

        assert!(sleep.update(true), "waking is a change");
        sleep.set_tail_seconds(None);
        assert_eq!(frames_to_sleep(&mut sleep), None);
    }
}
