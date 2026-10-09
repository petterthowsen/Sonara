//! Linear trapezoidal state-variable filter (Andrew Simper, "SvfLinearTrapOptimised2") with the
//! EQ responses: low/high pass, band pass, notch, all pass, bell and both shelves.
//!
//! - One structure for every response: the output is `m0·in + m1·band + m2·low`, so switching or
//!   modulating a response never needs a different topology, and coefficients can change every
//!   sample without blowing up.
//! - [`SvfShape::magnitude_db`] is the exact response of the digital filter (the SVF is the
//!   bilinear transform of the analog prototype, pre-warped at the cutoff), so an EQ view can draw
//!   the curve the engine actually applies.
//! - Unlike `svf.rs` (the synth filter), there is no drive, compensation or resonance clamp.

use std::f32::consts::PI;

/// Highest frequency, as a fraction of the sample rate, the coefficients allow.
const MAX_FREQ_RATIO: f32 = 0.499;
const MIN_FREQ_HZ: f32 = 1.0;
const MIN_Q: f32 = 0.025;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SvfShape {
    LowPass,
    HighPass,
    BandPass,
    Notch,
    AllPass,
    Bell,
    LowShelf,
    HighShelf,
}

/// Coefficients for one response at one setting. Cheap to build (one `tan`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SvfCoefs {
    /// Pre-warped integrator gain (shelves fold the gain into it).
    pub g: f32,
    /// Damping, `1/Q` (a bell folds the gain into it).
    pub k: f32,
    a1: f32,
    a2: f32,
    a3: f32,
    m0: f32,
    m1: f32,
    m2: f32,
}

impl SvfCoefs {
    /// `freq` in Hz, `q` > 0, `gain_db` used by Bell and the shelves only.
    pub fn new(shape: SvfShape, freq: f32, q: f32, gain_db: f32, sample_rate: f32) -> Self {
        let freq = freq.clamp(MIN_FREQ_HZ, sample_rate * MAX_FREQ_RATIO);
        let q = q.max(MIN_Q);
        let base_g = (PI * freq / sample_rate).tan();
        // A = 10^(dB/40): the square root of the linear gain.
        let a = 10f32.powf(gain_db / 40.0);
        let k = 1.0 / q;
        let (g, k, m0, m1, m2) = match shape {
            SvfShape::LowPass => (base_g, k, 0.0, 0.0, 1.0),
            SvfShape::HighPass => (base_g, k, 1.0, -k, -1.0),
            SvfShape::BandPass => (base_g, k, 0.0, 1.0, 0.0),
            SvfShape::Notch => (base_g, k, 1.0, -k, 0.0),
            SvfShape::AllPass => (base_g, k, 1.0, -2.0 * k, 0.0),
            SvfShape::Bell => {
                let k = 1.0 / (q * a);
                (base_g, k, 1.0, k * (a * a - 1.0), 0.0)
            }
            SvfShape::LowShelf => (base_g / a.sqrt(), k, 1.0, k * (a - 1.0), a * a - 1.0),
            SvfShape::HighShelf => (base_g * a.sqrt(), k, a * a, k * (1.0 - a) * a, 1.0 - a * a),
        };
        let a1 = 1.0 / (1.0 + g * (g + k));
        let a2 = g * a1;
        let a3 = g * a2;
        Self {
            g,
            k,
            a1,
            a2,
            a3,
            m0,
            m1,
            m2,
        }
    }

    /// Magnitude in dB at `freq` Hz: the exact response of the digital filter.
    pub fn magnitude_db(&self, freq: f32, sample_rate: f32) -> f32 {
        // Bilinear transform: s = j·tan(πf/fs)/g in the prototype normalized to the cutoff.
        let w = (PI * freq.clamp(0.0, sample_rate * MAX_FREQ_RATIO) / sample_rate).tan() as f64
            / self.g as f64;
        let (m0, m1, m2, k) = (
            self.m0 as f64,
            self.m1 as f64,
            self.m2 as f64,
            self.k as f64,
        );
        // H(s) = (m0·(s² + k·s + 1) + m1·s + m2) / (s² + k·s + 1), with s = j·w.
        let num_re = m0 * (1.0 - w * w) + m2;
        let num_im = (m0 * k + m1) * w;
        let den_re = 1.0 - w * w;
        let den_im = k * w;
        let mag_sq = (num_re * num_re + num_im * num_im) / (den_re * den_re + den_im * den_im);
        (10.0 * mag_sq.max(1e-30).log10()) as f32
    }
}

/// One channel of filter state.
#[derive(Clone, Copy, Debug, Default)]
pub struct LinearSvf {
    ic1eq: f32,
    ic2eq: f32,
}

impl LinearSvf {
    pub fn new() -> Self {
        Self::default()
    }

    #[inline]
    pub fn process(&mut self, v0: f32, c: &SvfCoefs) -> f32 {
        let v3 = v0 - self.ic2eq;
        let v1 = c.a1 * self.ic1eq + c.a2 * v3;
        let v2 = self.ic2eq + c.a2 * self.ic1eq + c.a3 * v3;
        self.ic1eq = 2.0 * v1 - self.ic1eq;
        self.ic2eq = 2.0 * v2 - self.ic2eq;
        c.m0 * v0 + c.m1 * v1 + c.m2 * v2
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;

    const SR: f32 = 48_000.0;
    const SHAPES: [SvfShape; 8] = [
        SvfShape::LowPass,
        SvfShape::HighPass,
        SvfShape::BandPass,
        SvfShape::Notch,
        SvfShape::AllPass,
        SvfShape::Bell,
        SvfShape::LowShelf,
        SvfShape::HighShelf,
    ];

    /// Measured gain in dB of a steady sine through the filter.
    fn measured_db(c: &SvfCoefs, freq: f32) -> f32 {
        let mut f = LinearSvf::new();
        let settle = SR as usize / 2;
        let n = settle + SR as usize / 2;
        let (mut sum_in, mut sum_out) = (0.0f64, 0.0f64);
        for i in 0..n {
            let x = (TAU * freq * i as f32 / SR).sin();
            let y = f.process(x, c);
            if i >= settle {
                sum_in += (x * x) as f64;
                sum_out += (y * y) as f64;
            }
        }
        (10.0 * (sum_out / sum_in).log10()) as f32
    }

    #[test]
    fn measured_response_matches_magnitude_db() {
        for shape in SHAPES {
            let c = SvfCoefs::new(shape, 1_000.0, 1.5, 9.0, SR);
            for freq in [100.0, 500.0, 1_000.0, 2_000.0, 8_000.0] {
                let (expected, got) = (c.magnitude_db(freq, SR), measured_db(&c, freq));
                // Deep notches/stopbands are measured against a noise floor; compare above −60.
                if expected > -60.0 {
                    assert!(
                        (expected - got).abs() < 0.1,
                        "{shape:?} at {freq} Hz: expected {expected:.2} dB, measured {got:.2} dB"
                    );
                }
            }
        }
    }

    #[test]
    fn eq_shapes_reach_their_gain() {
        let bell = SvfCoefs::new(SvfShape::Bell, 1_000.0, 1.0, 6.0, SR);
        assert!((bell.magnitude_db(1_000.0, SR) - 6.0).abs() < 0.01);
        assert!(bell.magnitude_db(20.0, SR).abs() < 0.1);
        let low = SvfCoefs::new(SvfShape::LowShelf, 200.0, 0.707, -12.0, SR);
        assert!((low.magnitude_db(20.0, SR) + 12.0).abs() < 0.1);
        assert!(low.magnitude_db(10_000.0, SR).abs() < 0.1);
        let high = SvfCoefs::new(SvfShape::HighShelf, 5_000.0, 0.707, 9.0, SR);
        assert!((high.magnitude_db(20_000.0, SR) - 9.0).abs() < 0.3);
        let lp = SvfCoefs::new(
            SvfShape::LowPass,
            1_000.0,
            std::f32::consts::FRAC_1_SQRT_2,
            0.0,
            SR,
        );
        assert!(
            (lp.magnitude_db(1_000.0, SR) + 3.01).abs() < 0.05,
            "Butterworth −3 dB"
        );
        let ap = SvfCoefs::new(SvfShape::AllPass, 1_000.0, 0.7, 0.0, SR);
        assert!(ap.magnitude_db(3_000.0, SR).abs() < 1e-3);
    }

    #[test]
    fn zero_gain_bell_is_transparent() {
        let c = SvfCoefs::new(SvfShape::Bell, 1_000.0, 2.0, 0.0, SR);
        let mut f = LinearSvf::new();
        for i in 0..1000 {
            let x = ((i * 7919) % 1000) as f32 / 500.0 - 1.0;
            assert!((f.process(x, &c) - x).abs() < 1e-5);
        }
    }
}
