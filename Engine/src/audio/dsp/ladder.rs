//! A four-pole nonlinear zero-delay-feedback ladder filter (Moog-style), for the Filter device.
//!
//! - Four TPT one-pole low-passes in series, with resonance feeding the last stage back to the
//!   input. The feedback is solved instantaneously for the *linear* ladder (so there is no
//!   unit delay and the resonance frequency stays on the cutoff), and each stage input then goes
//!   through a soft saturator, which is what gives the ladder its sound and keeps
//!   self-oscillation bounded.
//! - The saturator is the rational tanh from `svf::soft_clip` (within 2 %), scaled by
//!   [`HEADROOM`] so a signal near full scale is only lightly compressed at Drive 0.
//! - `g` is the pole frequency, so the response is −12 dB at the cutoff for LP 24 and the
//!   resonance peak sits on the cutoff.
//! - HP, BP and Notch come from mixing the stage taps with binomial weights.
//! - Resonance compensation: the low-pass modes lose `1/(1+k)` at DC. The output is scaled by
//!   `1 + COMPENSATION·k`, which keeps the bass close to its unresonant level.

use super::svf::soft_clip;

/// Feedback gain at full resonance. The linear ladder self-oscillates at 4.
pub const MAX_K: f32 = 4.2;
/// The saturator is linear to about ±HEADROOM/4.
pub const HEADROOM: f32 = 2.0;
/// How much of the DC loss the low-pass modes win back.
const COMPENSATION: f32 = 0.85;
/// Keeps the states out of denormal range when the input goes silent.
const ANTI_DENORMAL: f32 = 1.0e-18;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LadderMode {
    Lp12,
    Lp24,
    Hp12,
    Hp24,
    Bp12,
    Notch,
}

/// Everything [`Ladder::process`] needs for one `(g, resonance)`.
#[derive(Clone, Copy, Debug, Default)]
pub struct LadderCoefs {
    /// One-pole gain `g/(1+g)`.
    big_g: f32,
    k: f32,
    /// `1/(1 + k·G⁴)`: the instantaneous feedback solution.
    inv_fb: f32,
    /// Output scale for the low-pass modes.
    comp: f32,
}

impl LadderCoefs {
    /// `g` from `svf::cutoff_to_g` (the pole frequency), `resonance` in 0..1.
    #[inline]
    pub fn new(g: f32, resonance: f32) -> Self {
        let big_g = g / (1.0 + g);
        let k = resonance.clamp(0.0, 1.0) * MAX_K;
        let g2 = big_g * big_g;
        Self {
            big_g,
            k,
            inv_fb: 1.0 / (1.0 + k * g2 * g2),
            comp: 1.0 + COMPENSATION * k,
        }
    }
}

#[inline]
fn sat(x: f32) -> f32 {
    HEADROOM * soft_clip(x * (1.0 / HEADROOM))
}

/// One channel of the ladder.
#[derive(Clone, Copy, Debug, Default)]
pub struct Ladder {
    s: [f32; 4],
}

impl Ladder {
    pub fn reset(&mut self) {
        self.s = [0.0; 4];
    }

    /// Filter one sample.
    #[inline]
    pub fn process(&mut self, x: f32, mode: LadderMode, c: &LadderCoefs) -> f32 {
        let x = x + ANTI_DENORMAL;
        let g = c.big_g;
        let g2 = g * g;
        let g3 = g2 * g;
        let [s0, s1, s2, s3] = self.s;
        // The linear ladder's output is `G⁴·in + S` with `S` from the states; solve the loop.
        let state_part = (1.0 - g) * (g3 * s0 + g2 * s1 + g * s2 + s3);
        let y4_estimate = (g2 * g2 * x + state_part) * c.inv_fb;
        let u = sat(x - c.k * y4_estimate);

        let y1 = stage(&mut self.s[0], u, g);
        let y2 = stage(&mut self.s[1], sat(y1), g);
        let y3 = stage(&mut self.s[2], sat(y2), g);
        let y4 = stage(&mut self.s[3], sat(y3), g);

        match mode {
            LadderMode::Lp12 => y2 * c.comp,
            LadderMode::Lp24 => y4 * c.comp,
            LadderMode::Hp12 => u - 2.0 * y1 + y2,
            LadderMode::Hp24 => u - 4.0 * y1 + 6.0 * y2 - 4.0 * y3 + y4,
            // Peak gain 0.5 at the cutoff, scaled to unity.
            LadderMode::Bp12 => 2.0 * (y1 - y2),
            LadderMode::Notch => u - 2.0 * (y1 - y2),
        }
    }
}

/// One TPT one-pole low-pass stage.
#[inline]
fn stage(s: &mut f32, x: f32, g: f32) -> f32 {
    let v = g * (x - *s);
    let y = v + *s;
    *s = y + v;
    y
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::svf::cutoff_to_g;
    use crate::audio::dsp::test_util::{sine, tone_amplitude};

    const SR: f32 = 48_000.0;

    fn gain_at(mode: LadderMode, cutoff: f32, resonance: f32, hz: f32, amp: f32) -> f32 {
        let c = LadderCoefs::new(cutoff_to_g(cutoff, SR), resonance);
        let mut ladder = Ladder::default();
        let x = sine(hz, SR, SR as usize, amp);
        let y: Vec<f32> = x.iter().map(|&v| ladder.process(v, mode, &c)).collect();
        tone_amplitude(&y[SR as usize / 2..], hz, SR) / amp
    }

    #[test]
    fn taps_give_the_expected_shapes_at_low_level() {
        // Low level keeps the saturators linear, so the analog prototypes apply: 4 × (1/(1+s))
        // is −12 dB at the pole frequency and −28 dB an octave above it.
        let at = gain_at(LadderMode::Lp24, 1_000.0, 0.0, 1_000.0, 0.01);
        assert!((at - 0.25).abs() < 0.02, "{at}");
        let above = gain_at(LadderMode::Lp24, 1_000.0, 0.0, 2_000.0, 0.01);
        assert!((above - 0.04).abs() < 0.008, "{above}");
        assert!(gain_at(LadderMode::Lp24, 1_000.0, 0.0, 50.0, 0.01) > 0.98);
        assert!(gain_at(LadderMode::Hp24, 1_000.0, 0.0, 50.0, 0.01) < 1e-3);
        assert!(gain_at(LadderMode::Hp24, 1_000.0, 0.0, 12_000.0, 0.01) > 0.95);
        assert!(gain_at(LadderMode::Hp12, 1_000.0, 0.0, 50.0, 0.01) < 0.01);
        assert!((gain_at(LadderMode::Bp12, 1_000.0, 0.0, 1_000.0, 0.01) - 1.0).abs() < 0.05);
        assert!(gain_at(LadderMode::Bp12, 1_000.0, 0.0, 100.0, 0.01) < 0.3);
        assert!(gain_at(LadderMode::Notch, 1_000.0, 0.0, 1_000.0, 0.01) < 0.05);
        assert!(gain_at(LadderMode::Notch, 1_000.0, 0.0, 50.0, 0.01) > 0.95);
    }

    #[test]
    fn resonance_peaks_at_the_cutoff_and_compensation_keeps_the_bass() {
        let peak = gain_at(LadderMode::Lp24, 1_000.0, 0.9, 1_000.0, 0.01);
        assert!(peak > 3.0, "resonant peak {peak}");
        let bass = gain_at(LadderMode::Lp24, 1_000.0, 0.9, 50.0, 0.01);
        let dry_bass = gain_at(LadderMode::Lp24, 1_000.0, 0.0, 50.0, 0.01);
        let diff_db = 20.0 * (bass / dry_bass).log10();
        assert!(diff_db.abs() < 3.0, "bass moved {diff_db} dB");
    }

    #[test]
    fn saturation_bounds_self_oscillation() {
        let c = LadderCoefs::new(cutoff_to_g(1_000.0, SR), 1.0);
        let mut ladder = Ladder::default();
        let mut peak = 0.0f32;
        for n in 0..SR as usize * 2 {
            // A kick to start the ring, then silence.
            let x = if n < 50 { 0.8 } else { 0.0 };
            let y = ladder.process(x, LadderMode::Lp24, &c);
            assert!(y.is_finite());
            peak = peak.max(y.abs());
        }
        assert!(peak < 20.0, "peak {peak}");
    }
}
