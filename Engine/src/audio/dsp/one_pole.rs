//! First-order zero-delay-feedback (TPT) filter: low pass, high pass and all pass from one state.
//!
//! - Low and high pass give the 6 dB/oct slopes (EQ cuts, feedback tone controls).
//! - The all pass is the Phaser's stage: unity gain, phase 0 → −180° through the cutoff.
//! - `g` comes from [`one_pole_g`] and may change every sample.

use std::f32::consts::PI;

/// Integrator gain for a cutoff of `hz` (clamped below Nyquist).
#[inline]
pub fn one_pole_g(hz: f32, sample_rate: f32) -> f32 {
    (PI * hz.clamp(1.0, sample_rate * 0.499) / sample_rate).tan()
}

#[derive(Clone, Copy, Debug, Default)]
pub struct OnePole {
    s: f32,
}

impl OnePole {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        self.s = 0.0;
    }

    /// Low-pass output.
    #[inline]
    pub fn lowpass(&mut self, x: f32, g: f32) -> f32 {
        let v = (x - self.s) * g / (1.0 + g);
        let lp = v + self.s;
        self.s = lp + v;
        lp
    }

    /// High-pass output.
    #[inline]
    pub fn highpass(&mut self, x: f32, g: f32) -> f32 {
        x - self.lowpass(x, g)
    }

    /// All-pass output (unity gain, −90° at the cutoff).
    #[inline]
    pub fn allpass(&mut self, x: f32, g: f32) -> f32 {
        2.0 * self.lowpass(x, g) - x
    }
}

/// Exact magnitude in dB of the low pass (`high = false`) or high pass at `freq`, for a cutoff
/// with integrator gain `g`.
pub fn one_pole_magnitude_db(g: f32, high: bool, freq: f32, sample_rate: f32) -> f32 {
    let w = (PI * freq.clamp(0.0, sample_rate * 0.499) / sample_rate).tan() as f64 / g as f64;
    let mag_sq = if high {
        w * w / (1.0 + w * w)
    } else {
        1.0 / (1.0 + w * w)
    };
    (10.0 * mag_sq.max(1e-30).log10()) as f32
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;

    const SR: f32 = 48_000.0;

    fn gain_db(freq: f32, mut f: impl FnMut(f32) -> f32) -> f32 {
        let (mut sin, mut sout) = (0.0f64, 0.0f64);
        for i in 0..SR as usize {
            let x = (TAU * freq * i as f32 / SR).sin();
            let y = f(x);
            if i > SR as usize / 4 {
                sin += (x * x) as f64;
                sout += (y * y) as f64;
            }
        }
        (10.0 * (sout / sin).log10()) as f32
    }

    #[test]
    fn lowpass_and_highpass_are_3db_down_at_cutoff_and_match_the_formula() {
        let g = one_pole_g(1_000.0, SR);
        for (high, freq) in [
            (false, 1_000.0),
            (true, 1_000.0),
            (false, 4_000.0),
            (true, 250.0),
        ] {
            let mut f = OnePole::new();
            let got = gain_db(freq, |x| {
                if high {
                    f.highpass(x, g)
                } else {
                    f.lowpass(x, g)
                }
            });
            let expected = one_pole_magnitude_db(g, high, freq, SR);
            assert!(
                (got - expected).abs() < 0.05,
                "high={high} {freq} Hz: {got} vs {expected}"
            );
        }
        assert!((one_pole_magnitude_db(g, false, 1_000.0, SR) + 3.01).abs() < 0.01);
    }

    #[test]
    fn allpass_has_unity_gain() {
        let g = one_pole_g(800.0, SR);
        for freq in [100.0, 800.0, 5_000.0] {
            let mut f = OnePole::new();
            assert!(gain_db(freq, |x| f.allpass(x, g)).abs() < 0.01);
        }
    }
}
