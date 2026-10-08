//! Pitch-sweep oscillator for drum bodies: a phase accumulator that takes a fresh frequency
//! every sample, with a selectable start phase and sine/triangle shapes.

use super::oscillator::fast_sin;

/// Waveform of a [`SweepOsc`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SweepShape {
    Sine,
    Triangle,
}

/// Phase-accumulator oscillator whose frequency can change every sample.
///
/// [`next`](Self::next) emits the value at the current phase, then advances by `hz / sample_rate`
/// and wraps into 0..1, so a frequency step never jumps the phase.
#[derive(Clone, Copy, Debug, Default)]
pub struct SweepOsc {
    phase: f64,
    start_phase: f64,
}

impl SweepOsc {
    pub fn new() -> Self {
        Self {
            phase: 0.0,
            start_phase: 0.0,
        }
    }

    /// Start phase in degrees (clamped 0..90); 90° starts the sine at +1.
    pub fn set_start_phase_deg(&mut self, degrees: f32) {
        self.start_phase = (degrees.clamp(0.0, 90.0) / 360.0) as f64;
    }

    /// Reset the phase to the configured start phase.
    pub fn reset(&mut self) {
        self.phase = self.start_phase;
    }

    /// Output at the current phase, then advance by `hz / sample_rate`.
    pub fn next(&mut self, shape: SweepShape, hz: f32, sample_rate: f32) -> f32 {
        let y = match shape {
            SweepShape::Sine => fast_sin(self.phase),
            SweepShape::Triangle => {
                let y = (self.phase + 0.25).fract() as f32;
                if y < 0.5 {
                    4.0 * y - 1.0
                } else {
                    3.0 - 4.0 * y
                }
            }
        };
        // The increment is always below one cycle, so the phase lands in [0, 2) and wraps at most
        // once: a compare and subtract replaces `rem_euclid` (a libm `fmod`) per sample.
        self.phase += (hz / sample_rate) as f64;
        if self.phase >= 1.0 {
            self.phase -= 1.0;
        }
        y
    }
}

/// Frequency of a sweep: `base_hz * 2^(sweep_st * env / 12)`, with a fast `exp2`.
pub fn sweep_hz(base_hz: f32, sweep_st: f32, env: f32) -> f32 {
    base_hz * fast_exp2(sweep_st * env / 12.0)
}

/// Degree-5 polynomial approximation of `2^x`, relative error < 2.4e-7 (well under 0.1 cent) for
/// |x| ≤ 64, falling back to the libm `exp2` outside.
#[inline]
fn fast_exp2(x: f32) -> f32 {
    if x.abs() > 64.0 {
        return x.exp2();
    }
    let i = x.floor();
    let f = x - i;
    let poly = 0.99999977
        + f * (0.69315678
            + f * (0.24013168 + f * (0.05587657 + f * (0.008940578 + f * 0.0018943786))));
    let bits = ((i as i32 + 127) as u32) << 23;
    f32::from_bits(bits) * poly
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::instantaneous_freq;

    const SR: f32 = 48_000.0;

    #[test]
    fn start_phase_sets_the_first_sample() {
        let mut osc = SweepOsc::new();
        osc.set_start_phase_deg(90.0);
        osc.reset();
        assert!((osc.next(SweepShape::Sine, 1_000.0, SR) - 1.0).abs() < 1e-4);

        let mut osc = SweepOsc::new();
        osc.reset();
        assert_eq!(osc.next(SweepShape::Sine, 1_000.0, SR), 0.0);

        let mut osc = SweepOsc::new();
        osc.set_start_phase_deg(90.0);
        osc.reset();
        assert!((osc.next(SweepShape::Triangle, 1_000.0, SR) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn sweep_hz_matches_the_exact_formula() {
        assert!((sweep_hz(41.2, 24.0, 1.0) - 164.8).abs() / 164.8 < 0.005);
        assert!((sweep_hz(41.2, 24.0, 0.0) - 41.2).abs() / 41.2 < 0.005);
        for st in (0..=48).step_by(4) {
            for env in [0.0, 0.25, 0.5, 1.0] {
                let got = sweep_hz(440.0, st as f32, env);
                let want = 440.0 * 2f32.powf(st as f32 * env / 12.0);
                let cents = 1200.0 * (got / want).log2();
                assert!(cents.abs() < 0.1, "st {st} env {env}: {cents} cents");
            }
        }
    }

    #[test]
    fn phase_is_continuous_across_a_frequency_step() {
        let mut tri = SweepOsc::new();
        let mut sine = SweepOsc::new();
        let mut prev_tri = tri.next(SweepShape::Triangle, 1_000.0, SR);
        let mut prev_sine = sine.next(SweepShape::Sine, 1_000.0, SR);
        let (mut max_tri, mut max_sine) = (0.0f32, 0.0f32);
        for n in 0..2_000 {
            let hz = if n < 500 { 1_000.0 } else { 2_000.0 };
            let t = tri.next(SweepShape::Triangle, hz, SR);
            max_tri = max_tri.max((t - prev_tri).abs());
            prev_tri = t;
            let s = sine.next(SweepShape::Sine, hz, SR);
            max_sine = max_sine.max((s - prev_sine).abs());
            prev_sine = s;
        }
        assert!(max_tri < 0.2, "triangle step {max_tri}");
        // A sine at 2 kHz steps by at most 2*sin(pi*f/sr) naturally; a phase reset would spike
        // towards 2.0.
        let natural = 2.0 * (std::f32::consts::PI * 2_000.0 / SR).sin();
        assert!(
            max_sine <= natural * 1.05,
            "sine step {max_sine} vs {natural}"
        );
    }

    #[test]
    fn measures_its_own_frequency() {
        let mut osc = SweepOsc::new();
        let signal: Vec<f32> = (0..(SR * 0.5) as usize)
            .map(|_| osc.next(SweepShape::Sine, 100.0, SR))
            .collect();
        let f = instantaneous_freq(&signal, SR);
        assert!((f - 100.0).abs() / 100.0 < 0.01, "{f} Hz");
    }
}
