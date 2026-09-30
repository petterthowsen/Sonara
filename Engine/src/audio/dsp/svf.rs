//! Zero-delay-feedback state-variable filter (Andrew Simper's trapezoidal SVF), with drive and
//! resonance compensation.
//!
//! - Coefficients are cheap to change every sample: callers compute `g` once per control block
//!   with [`cutoff_to_g`], interpolate it (and `k`) across the block, and build [`SvfCoefs`] per
//!   sample, or once when nothing moves.
//! - LP 24 is two cascaded stages tuned as a 4-pole Butterworth at resonance 0; resonance only
//!   sharpens the first stage.
//! - Resonance is clamped just below self-oscillation.

use std::f32::consts::{PI, SQRT_2};

/// Lowest and highest cutoff the coefficient helper allows (the top as a fraction of the rate).
pub const MIN_CUTOFF_HZ: f32 = 10.0;
const MAX_CUTOFF_RATIO: f32 = 0.49;
/// Damping at full resonance (Q = 20): high, but short of self-oscillation.
const K_MIN: f32 = 0.05;
/// 4-pole Butterworth damping for the two LP 24 stages (Q 0.541 and 1.307).
const K_BUTTER4_A: f32 = 1.847_759;
const K_BUTTER4_B: f32 = 0.765_367;
/// How much low-passed input comes back at full resonance (LP modes), so the lows don't thin
/// out under a big resonant peak. 0.5 is about +3.5 dB of bass at resonance 1.
const RESONANCE_COMPENSATION: f32 = 0.5;
/// Drive reaches a fully saturated signal at this many dB; below it the clean and saturated
/// signals are crossfaded, so 0 dB is exactly clean and the knob has no jump.
const DRIVE_BLEND_DB: f32 = 6.0;
/// Keeps the integrator states out of denormal range when the input goes silent.
const ANTI_DENORMAL: f32 = 1.0e-18;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterMode {
    Lp12,
    Lp24,
    Hp12,
    Bp12,
}

/// Integrator coefficient for `hz` at `sample_rate` (clamped to a safe range).
pub fn cutoff_to_g(hz: f32, sample_rate: f32) -> f32 {
    let hz = hz.clamp(MIN_CUTOFF_HZ, sample_rate * MAX_CUTOFF_RATIO);
    (PI * hz / sample_rate).tan()
}

/// Damping (`1/Q`) of the resonant stage for `resonance` in 0..1.
pub fn resonance_to_k(resonance: f32, mode: FilterMode) -> f32 {
    let k0 = if mode == FilterMode::Lp24 {
        K_BUTTER4_A
    } else {
        SQRT_2
    };
    k0 * (K_MIN / k0).powf(resonance.clamp(0.0, 1.0))
}

/// One-pole coefficient for the compensation low-pass, an octave below the cutoff.
pub fn compensation_coef(hz: f32, sample_rate: f32) -> f32 {
    1.0 - (-PI * hz.max(MIN_CUTOFF_HZ) / sample_rate).exp()
}

/// Rational tanh: exact at 0, within 2 % up to ±3, and ±1 beyond.
#[inline]
pub fn soft_clip(x: f32) -> f32 {
    let x = x.clamp(-3.0, 3.0);
    let x2 = x * x;
    x * (27.0 + x2) / (27.0 + 9.0 * x2)
}

/// Pre-filter drive for `drive_db` (0 and up): `(gain, blend)`, applied by [`drive`].
pub fn drive_params(drive_db: f32) -> (f32, f32) {
    let db = drive_db.max(0.0);
    (10f32.powf(db / 20.0), (db / DRIVE_BLEND_DB).min(1.0))
}

#[inline]
pub fn drive(x: f32, gain: f32, blend: f32) -> f32 {
    x + blend * (soft_clip(x * gain) - x)
}

/// One stage's per-sample coefficients for a given `g` and `k`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct StageCoefs {
    k: f32,
    a1: f32,
    a2: f32,
    a3: f32,
}

impl StageCoefs {
    #[inline]
    fn new(g: f32, k: f32) -> Self {
        let a1 = 1.0 / (1.0 + g * (g + k));
        let a2 = g * a1;
        Self {
            k,
            a1,
            a2,
            a3: g * a2,
        }
    }
}

/// Everything [`Svf::process`] needs for one `(g, k, mode)`. Computing it costs a division or
/// two, so hold on to it while cutoff and resonance are steady.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SvfCoefs {
    first: StageCoefs,
    /// The fixed-damping second stage of LP 24.
    second: StageCoefs,
}

impl SvfCoefs {
    #[inline]
    pub fn new(g: f32, k: f32, mode: FilterMode) -> Self {
        Self {
            first: StageCoefs::new(g, k),
            second: if mode == FilterMode::Lp24 {
                StageCoefs::new(g, K_BUTTER4_B)
            } else {
                StageCoefs::default()
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Stage {
    ic1: f32,
    ic2: f32,
}

impl Stage {
    /// One sample: returns (low, band, high).
    #[inline]
    fn tick(&mut self, x: f32, c: &StageCoefs) -> (f32, f32, f32) {
        let v3 = x - self.ic2;
        let v1 = c.a1 * self.ic1 + c.a2 * v3;
        let v2 = self.ic2 + c.a2 * self.ic1 + c.a3 * v3;
        self.ic1 = 2.0 * v1 - self.ic1;
        self.ic2 = 2.0 * v2 - self.ic2;
        (v2, v1, x - c.k * v1 - v2)
    }
}

/// One channel of the filter.
#[derive(Clone, Copy, Debug, Default)]
pub struct Svf {
    stages: [Stage; 2],
    /// Low-passed input for resonance compensation.
    lows: f32,
}

impl Svf {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Filter one sample. `coefs` must have been made for the same `mode`; `comp_coef` comes
    /// from [`compensation_coef`] and `resonance` scales the compensation (LP modes only).
    #[inline]
    pub fn process(
        &mut self,
        x: f32,
        mode: FilterMode,
        coefs: &SvfCoefs,
        comp_coef: f32,
        resonance: f32,
    ) -> f32 {
        let x = x + ANTI_DENORMAL;
        let c = &coefs.first;
        match mode {
            FilterMode::Lp12 => {
                let (low, _, _) = self.stages[0].tick(x, c);
                low + self.compensation(x, comp_coef, resonance)
            }
            FilterMode::Lp24 => {
                let (a, _, _) = self.stages[0].tick(x, c);
                let (low, _, _) = self.stages[1].tick(a, &coefs.second);
                low + self.compensation(x, comp_coef, resonance)
            }
            FilterMode::Hp12 => self.stages[0].tick(x, c).2,
            // Scaled by k so the peak stays at unity gain as the band narrows.
            FilterMode::Bp12 => self.stages[0].tick(x, c).1 * c.k,
        }
    }

    #[inline]
    fn compensation(&mut self, x: f32, coef: f32, resonance: f32) -> f32 {
        self.lows += coef * (x - self.lows);
        RESONANCE_COMPENSATION * resonance * self.lows
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODES: [FilterMode; 4] = [
        FilterMode::Lp12,
        FilterMode::Lp24,
        FilterMode::Hp12,
        FilterMode::Bp12,
    ];

    /// Steady-state RMS gain of a sine at `hz` through a static filter.
    fn gain_at(mode: FilterMode, cutoff: f32, resonance: f32, hz: f32, sr: f32) -> f32 {
        let mut f = Svf::new();
        let coefs = SvfCoefs::new(
            cutoff_to_g(cutoff, sr),
            resonance_to_k(resonance, mode),
            mode,
        );
        let c = compensation_coef(cutoff, sr);
        let n = (sr * 0.5) as usize;
        let (mut sum_in, mut sum_out) = (0.0f64, 0.0f64);
        for i in 0..n {
            let x = (std::f32::consts::TAU * hz * i as f32 / sr).sin();
            let y = f.process(x, mode, &coefs, c, resonance);
            if i > n / 2 {
                sum_in += (x * x) as f64;
                sum_out += (y * y) as f64;
            }
        }
        (sum_out / sum_in).sqrt() as f32
    }

    #[test]
    fn stable_across_cutoff_and_resonance_sweeps_at_every_rate() {
        for sr in [44_100.0f32, 48_000.0, 96_000.0, 192_000.0] {
            for mode in MODES {
                let mut f = Svf::new();
                let (gain, blend) = drive_params(24.0);
                let frames = (sr * 0.5) as usize;
                let mut peak = 0.0f32;
                // Sweep cutoff 10 Hz → Nyquist and resonance 0 → 1 per sample, full-scale noise.
                let mut rng = 1u32;
                for i in 0..frames {
                    let t = i as f32 / frames as f32;
                    let cutoff = 10.0 * (sr / 20.0).powf(t);
                    let resonance = (t * 7.0).fract();
                    rng ^= rng << 13;
                    rng ^= rng >> 17;
                    rng ^= rng << 5;
                    let x = drive(rng as i32 as f32 / i32::MAX as f32, gain, blend);
                    let coefs = SvfCoefs::new(
                        cutoff_to_g(cutoff, sr),
                        resonance_to_k(resonance, mode),
                        mode,
                    );
                    let y = f.process(x, mode, &coefs, compensation_coef(cutoff, sr), resonance);
                    assert!(y.is_finite(), "{mode:?} at {sr}: non-finite at {i}");
                    peak = peak.max(y.abs());
                }
                assert!(peak < 100.0, "{mode:?} at {sr}: peak {peak}");
            }
        }
    }

    #[test]
    fn responses_have_the_right_shape() {
        let sr = 48_000.0;
        // Low-passes pass lows and cut highs; LP 24 cuts harder.
        let lp12 = gain_at(FilterMode::Lp12, 1_000.0, 0.0, 8_000.0, sr);
        let lp24 = gain_at(FilterMode::Lp24, 1_000.0, 0.0, 8_000.0, sr);
        assert!(gain_at(FilterMode::Lp24, 1_000.0, 0.0, 100.0, sr) > 0.95);
        assert!(lp12 < 0.03 && lp24 < 0.001 && lp24 < lp12, "{lp12} {lp24}");
        // Butterworth: -3 dB at the cutoff.
        let at_cutoff = gain_at(FilterMode::Lp24, 1_000.0, 0.0, 1_000.0, sr);
        assert!((at_cutoff - 0.707).abs() < 0.05, "{at_cutoff}");
        // High-pass and band-pass.
        assert!(gain_at(FilterMode::Hp12, 1_000.0, 0.0, 100.0, sr) < 0.02);
        assert!(gain_at(FilterMode::Hp12, 1_000.0, 0.0, 8_000.0, sr) > 0.95);
        assert!((gain_at(FilterMode::Bp12, 1_000.0, 0.8, 1_000.0, sr) - 1.0).abs() < 0.05);
        assert!(gain_at(FilterMode::Bp12, 1_000.0, 0.8, 8_000.0, sr) < 0.1);
    }

    #[test]
    fn resonance_peaks_and_compensation_keeps_the_lows() {
        let sr = 48_000.0;
        let peak = gain_at(FilterMode::Lp24, 1_000.0, 1.0, 1_000.0, sr);
        assert!(peak > 5.0, "resonant peak {peak}");
        let lows = gain_at(FilterMode::Lp24, 1_000.0, 1.0, 60.0, sr);
        assert!(lows > 1.2, "lows at full resonance {lows}");
    }

    #[test]
    fn zero_drive_is_clean() {
        let (gain, blend) = drive_params(0.0);
        for x in [-1.0, -0.3, 0.0, 0.5, 1.0] {
            assert_eq!(drive(x, gain, blend), x);
        }
        let (gain, blend) = drive_params(24.0);
        assert!(drive(1.0, gain, blend) <= 1.0);
        assert!(drive(0.1, gain, blend) > 0.5, "drive boosts quiet input");
    }
}
