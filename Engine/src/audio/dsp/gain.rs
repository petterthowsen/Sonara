//! Gain helpers shared by the built-in effects: dB conversion, a DC blocker, and the dry/wet
//! Mix law (spec 012, decision 5).

use std::f32::consts::{FRAC_PI_2, TAU};

/// Levels at or below this many dB count as silence in [`gain_to_db`].
pub const SILENCE_DB: f32 = -160.0;

#[inline]
pub fn db_to_gain(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

/// Gain in dB, floored at [`SILENCE_DB`].
#[inline]
pub fn gain_to_db(gain: f32) -> f32 {
    if gain <= 0.0 {
        SILENCE_DB
    } else {
        (20.0 * gain.log10()).max(SILENCE_DB)
    }
}

/// How Mix crossfades dry and wet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MixLaw {
    /// `dry·(1−m) + wet·m`: parallel compression, filters.
    Linear,
    /// `dry·cos + wet·sin`: constant power, for time-based and modulation effects.
    EqualPower,
}

/// Dry and wet gains for `mix` in 0..1. The ends are exact: 0 gives (1, 0) and 1 gives (0, 1),
/// so Mix 0 % is bit-exact dry.
#[inline]
pub fn dry_wet_gains(mix: f32, law: MixLaw) -> (f32, f32) {
    if mix <= 0.0 {
        return (1.0, 0.0);
    }
    if mix >= 1.0 {
        return (0.0, 1.0);
    }
    match law {
        MixLaw::Linear => (1.0 - mix, mix),
        MixLaw::EqualPower => {
            let (sin, cos) = (mix * FRAC_PI_2).sin_cos();
            (cos, sin)
        }
    }
}

/// One-pole DC blocker (`y = x − x₁ + R·y₁`), cutoff around `hz`.
#[derive(Clone, Copy, Debug)]
pub struct DcBlocker {
    r: f32,
    x1: f32,
    y1: f32,
}

impl DcBlocker {
    /// Default cutoff: low enough to leave sub-bass alone.
    pub const DEFAULT_HZ: f32 = 5.0;

    pub fn new(hz: f32, sample_rate: f32) -> Self {
        Self {
            r: 1.0 - TAU * hz / sample_rate,
            x1: 0.0,
            y1: 0.0,
        }
    }

    pub fn reset(&mut self) {
        self.x1 = 0.0;
        self.y1 = 0.0;
    }

    #[inline]
    pub fn process(&mut self, x: f32) -> f32 {
        let y = x - self.x1 + self.r * self.y1;
        self.x1 = x;
        self.y1 = y;
        y
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn db_round_trip_and_floor() {
        assert!((db_to_gain(-6.0206) - 0.5).abs() < 1e-4);
        assert!((gain_to_db(db_to_gain(-17.5)) + 17.5).abs() < 1e-4);
        assert_eq!(gain_to_db(0.0), SILENCE_DB);
    }

    #[test]
    fn mix_ends_are_exact_and_equal_power_is_constant_power() {
        for law in [MixLaw::Linear, MixLaw::EqualPower] {
            assert_eq!(dry_wet_gains(0.0, law), (1.0, 0.0));
            assert_eq!(dry_wet_gains(1.0, law), (0.0, 1.0));
        }
        for m in [0.1, 0.5, 0.9] {
            let (d, w) = dry_wet_gains(m, MixLaw::EqualPower);
            assert!((d * d + w * w - 1.0).abs() < 1e-6);
            let (d, w) = dry_wet_gains(m, MixLaw::Linear);
            assert!((d + w - 1.0).abs() < 1e-6);
        }
    }

    #[test]
    fn dc_blocker_removes_offset_and_passes_audio() {
        let sr = 48_000.0;
        let mut dc = DcBlocker::new(DcBlocker::DEFAULT_HZ, sr);
        let mut last = 0.0;
        for _ in 0..sr as usize * 2 {
            last = dc.process(0.5);
        }
        assert!(last.abs() < 1e-3, "{last}");
        let mut dc = DcBlocker::new(DcBlocker::DEFAULT_HZ, sr);
        let mut peak = 0.0f32;
        for i in 0..sr as usize {
            let y = dc.process((TAU * 1_000.0 * i as f32 / sr).sin());
            if i > 4_800 {
                peak = peak.max(y.abs());
            }
        }
        assert!((peak - 1.0).abs() < 0.01, "{peak}");
    }
}
