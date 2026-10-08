//! Channel metering and gain smoothing.

use super::Channel;

/// RMS integration time constant, matching the standard 300 ms RMS window.
const RMS_WINDOW_SECONDS: f32 = 0.3;

/// Gain smoothing coefficient for a 5 ms one-pole filter: alpha = 1 - exp(-1 / (tau * rate)).
/// 5 ms is a good balance between smoothness and responsiveness.
pub(super) fn gain_smoothing_alpha(sample_rate: f32) -> f32 {
    let tau = 0.005;
    1.0 - (-1.0 / (tau * sample_rate as f64)).exp() as f32
}

/// Convert a fader or send level in dB to linear gain. -60 dB and below is silence (0.0), not a
/// very quiet signal.
pub(crate) fn fader_gain(db: f32) -> f32 {
    if db <= -60.0 {
        0.0
    } else {
        10.0_f32.powf(db / 20.0)
    }
}

impl Channel {
    /// Convert dB to linear gain (target value, not smoothed)
    ///
    /// Prefers the automation override when one is set, leaving `volume_db` — the base value the
    /// project saves — untouched.
    pub fn get_gain(&self) -> f32 {
        let db = match self.automation_volume {
            Some(normalized) => crate::audio::automation::normalized_to_db(normalized),
            None => self.volume_db,
        };
        fader_gain(db)
    }

    /// Get smoothed gain value (advances smoothing by one sample)
    /// Call this once per sample to prevent clicks when changing volume
    pub fn get_smoothed_gain(&mut self) -> f32 {
        let target_gain = self.get_gain();
        // One-pole filter: current += (target - current) * alpha
        self.current_gain += (target_gain - self.current_gain) * self.smoothing_alpha;
        self.current_gain
    }

    /// Accumulate peak and RMS meters for this block (post-fader).
    ///
    /// The buffers already hold post-fader audio (gain/pan applied during mixing), but only the
    /// first `frames` samples are live: buffers are allocated at the engine's maximum block size
    /// and never resized, so the tail is stale zeros and must not be metered.
    ///
    /// Peaks accumulate as a max across every block until `take_meters()` sends them, so a
    /// transient landing between the ~20 Hz status sends is not lost. RMS is a one-pole average of
    /// the mean square with a 300 ms time constant (the standard RMS integration window), which
    /// carries across blocks and so needs no reset.
    pub fn update_peaks(&mut self, frames: usize, sample_rate: f32) {
        let frames = frames.min(self.buffer_left.len());
        if frames == 0 {
            return;
        }
        let left = &self.buffer_left[..frames];
        let right = &self.buffer_right[..frames];

        let block_peak_left = left.iter().map(|s| s.abs()).fold(0.0, f32::max);
        let block_peak_right = right.iter().map(|s| s.abs()).fold(0.0, f32::max);
        self.peak_left = self.peak_left.max(block_peak_left);
        self.peak_right = self.peak_right.max(block_peak_right);

        let n = frames as f32;
        let block_ms_left: f32 = left.iter().map(|s| s * s).sum::<f32>() / n;
        let block_ms_right: f32 = right.iter().map(|s| s * s).sum::<f32>() / n;

        // alpha for a 300 ms time constant over a block of `frames` samples
        let alpha = if sample_rate > 0.0 {
            1.0 - (-(n / (RMS_WINDOW_SECONDS * sample_rate))).exp()
        } else {
            1.0
        };
        self.mean_square_left += (block_ms_left - self.mean_square_left) * alpha;
        self.mean_square_right += (block_ms_right - self.mean_square_right) * alpha;

        self.rms_left = self.mean_square_left.sqrt();
        self.rms_right = self.mean_square_right.sqrt();
    }

    /// Read the accumulated meters and reset the peak accumulators for the next interval.
    /// RMS keeps integrating, so it is only read here.
    pub fn take_meters(&mut self) -> (f32, f32, f32, f32) {
        let meters = (
            self.peak_left,
            self.peak_right,
            self.rms_left,
            self.rms_right,
        );
        self.peak_left = 0.0;
        self.peak_right = 0.0;
        meters
    }
}

#[cfg(test)]
mod meter_tests {
    use super::*;

    const SR: f32 = 48_000.0;
    /// Channels are allocated at the engine's max block size, well above the real block size.
    const ALLOC: usize = 8192;
    const FRAMES: usize = 1024;

    fn channel_with_signal(amplitude: f32, frames: usize) -> Channel {
        let mut channel = Channel::new(2, "Meter".to_string(), ALLOC, SR);
        for i in 0..frames {
            channel.buffer_left[i] = amplitude;
            channel.buffer_right[i] = amplitude;
        }
        channel
    }

    #[test]
    fn fader_gain_floors_at_minus_60_db() {
        assert_eq!(fader_gain(-60.0), 0.0);
        assert_eq!(fader_gain(-90.0), 0.0);
        assert!((fader_gain(0.0) - 1.0).abs() < 1e-6);
        assert!((fader_gain(-6.0) - 0.501_187).abs() < 1e-5);
        assert!(fader_gain(-59.9) > 0.0);
    }

    #[test]
    fn rms_ignores_the_unwritten_tail_of_an_oversized_buffer() {
        // A full-scale DC block has an RMS of exactly its amplitude. Metering the whole
        // allocation instead of `frames` used to divide by 8x too many samples (-9 dB).
        let mut channel = channel_with_signal(0.5, FRAMES);
        // Settle the 300 ms integrator by feeding the same block for well over a second.
        for _ in 0..(SR as usize / FRAMES) * 2 {
            channel.update_peaks(FRAMES, SR);
        }
        assert!(
            (channel.rms_left - 0.5).abs() < 0.01,
            "expected RMS ~0.5, got {}",
            channel.rms_left
        );
    }

    #[test]
    fn peaks_accumulate_across_blocks_until_taken() {
        let mut channel = channel_with_signal(0.2, FRAMES);
        channel.update_peaks(FRAMES, SR);

        // A transient in a later block must survive, even though a quiet block follows it.
        channel.buffer_left[7] = 0.9;
        channel.update_peaks(FRAMES, SR);
        channel.buffer_left[7] = 0.2;
        channel.update_peaks(FRAMES, SR);

        let (peak_left, _, _, _) = channel.take_meters();
        assert!(
            (peak_left - 0.9).abs() < 1e-6,
            "expected the held transient 0.9, got {peak_left}"
        );

        // Taking the meters restarts the max, so the next interval reports only its own blocks.
        channel.update_peaks(FRAMES, SR);
        let (peak_left, _, _, _) = channel.take_meters();
        assert!(
            (peak_left - 0.2).abs() < 1e-6,
            "expected the accumulator to reset to 0.2, got {peak_left}"
        );
    }

    #[test]
    fn rms_integrates_over_roughly_300ms() {
        // One time constant of a step response reaches ~63% of the target in mean-square terms.
        let mut channel = channel_with_signal(1.0, FRAMES);
        let blocks = (0.3 * SR / FRAMES as f32).round() as usize;
        for _ in 0..blocks {
            channel.update_peaks(FRAMES, SR);
        }
        let mean_square = channel.rms_left * channel.rms_left;
        assert!(
            (mean_square - 0.632).abs() < 0.02,
            "expected ~0.632 mean square after one 300 ms time constant, got {mean_square}"
        );
    }
}
