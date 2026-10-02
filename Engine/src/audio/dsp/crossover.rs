//! Stereo multiband splitter: cascaded Linkwitz-Riley 4th-order (LR4) crossovers with phase
//! compensation, for the Multiband FX container (spec 016).
//!
//! - The splitter knows only a compacted, ascending list of `count` crossover frequencies (1..=5),
//!   so it makes `count + 1` bands. Mapping bands to positions is the caller's job.
//! - Topology is a cascade, low first. Crossover `j` splits the remainder into band `j` (LR4
//!   low-pass) and the new remainder (LR4 high-pass). The last band is what is left.
//! - An LR4 is two cascaded 2nd-order Butterworth stages (`LinearSvf`, Q = 1/√2). Its low-pass plus
//!   high-pass is a 2nd-order all-pass at the same frequency and Q. Band `j` therefore passes
//!   through the all-pass of every crossover `k > j`, so the bands sum to the input through the
//!   all-pass of every crossover: flat in magnitude, zero latency. That sum is also written as
//!   `dry_aligned`, the phase-aligned dry for a Mix control.
//! - Crossover frequencies are smoothed in log-frequency (~20 ms). Coefficients are rebuilt every
//!   [`COEF_INTERVAL`] samples while any ramp is active and once more when it settles.
//! - Cost per sample and channel at 6 bands: 5 × 4 split stages + 10 compensation + 5 dry
//!   all-passes = 35 biquads (the LR4 stages are shared by all bands).
//! - Everything is fixed-size: no allocation after `new`, safe for the audio thread.

use super::linear_svf::{LinearSvf, SvfCoefs, SvfShape};
use super::smoothing::SmoothedParam;
use std::f32::consts::FRAC_1_SQRT_2;

/// Most crossovers (6 bands).
pub const MAX_CROSSOVERS: usize = 5;
/// Most bands.
pub const MAX_BANDS: usize = MAX_CROSSOVERS + 1;
/// Samples between coefficient rebuilds while a frequency is moving.
const COEF_INTERVAL: u32 = 16;
const SMOOTH_MS: f32 = 20.0;
const MIN_HZ: f32 = 10.0;

pub struct MultibandSplitter {
    sample_rate: f32,
    count: usize,
    /// ln(frequency) per crossover slot.
    smoothed: [SmoothedParam; MAX_CROSSOVERS],
    lp_c: [SvfCoefs; MAX_CROSSOVERS],
    hp_c: [SvfCoefs; MAX_CROSSOVERS],
    ap_c: [SvfCoefs; MAX_CROSSOVERS],
    /// `[crossover][channel][stage]`
    lp: [[[LinearSvf; 2]; 2]; MAX_CROSSOVERS],
    hp: [[[LinearSvf; 2]; 2]; MAX_CROSSOVERS],
    /// Compensation all-passes `[band][crossover k > band][channel]`.
    comp: [[[LinearSvf; 2]; MAX_CROSSOVERS]; MAX_CROSSOVERS],
    /// Dry path all-passes `[crossover][channel]`.
    dry: [[LinearSvf; 2]; MAX_CROSSOVERS],
    pending: bool,
    tick: u32,
}

fn max_hz(sample_rate: f32) -> f32 {
    sample_rate * 0.45
}

impl MultibandSplitter {
    pub fn new(sample_rate: f32) -> Self {
        let default_hz = [100.0f32, 300.0, 1000.0, 3000.0, 8000.0];
        let smoothed = std::array::from_fn(|i| {
            SmoothedParam::new(
                default_hz[i].min(max_hz(sample_rate)).ln(),
                sample_rate,
                SMOOTH_MS,
            )
        });
        let placeholder = SvfCoefs::new(SvfShape::AllPass, 1000.0, FRAC_1_SQRT_2, 0.0, sample_rate);
        let mut s = Self {
            sample_rate,
            count: 1,
            smoothed,
            lp_c: [placeholder; MAX_CROSSOVERS],
            hp_c: [placeholder; MAX_CROSSOVERS],
            ap_c: [placeholder; MAX_CROSSOVERS],
            lp: Default::default(),
            hp: Default::default(),
            comp: Default::default(),
            dry: Default::default(),
            pending: false,
            tick: 0,
        };
        s.rebuild_all();
        s
    }

    /// Number of crossovers (1..=5); the splitter makes `count + 1` bands.
    pub fn crossover_count(&self) -> usize {
        self.count
    }

    /// Change the number of crossovers. The caller then sets new targets, and normally calls
    /// [`snap`](Self::snap) and [`reset`](Self::reset) (the fade-out, switch, fade-in of spec D13).
    pub fn set_topology(&mut self, count: usize) {
        self.count = count.clamp(1, MAX_CROSSOVERS);
    }

    /// Glide the first `count` crossovers to `freqs` (Hz, ascending; the caller applies the
    /// ordering rule). Slots beyond the slice length keep their targets.
    pub fn set_targets(&mut self, freqs: &[f32]) {
        let hi = max_hz(self.sample_rate);
        for (sm, &f) in self.smoothed.iter_mut().zip(freqs.iter().take(self.count)) {
            let target = f.clamp(MIN_HZ, hi).ln();
            if target != sm.target() {
                sm.set_target(target);
            }
        }
        self.pending = true;
    }

    /// Jump every smoother to its target and rebuild the coefficients.
    pub fn snap(&mut self) {
        for sm in self.smoothed.iter_mut() {
            let t = sm.target();
            sm.snap(t);
        }
        self.rebuild_all();
        self.pending = false;
    }

    /// Clear all filter state.
    pub fn reset(&mut self) {
        self.lp = Default::default();
        self.hp = Default::default();
        self.comp = Default::default();
        self.dry = Default::default();
    }

    /// Current (smoothed) crossover frequency in Hz.
    pub fn frequency(&self, index: usize) -> f32 {
        self.smoothed[index].current().exp()
    }

    fn rebuild(&mut self, j: usize) {
        let f = self.smoothed[j].current().exp();
        let sr = self.sample_rate;
        self.lp_c[j] = SvfCoefs::new(SvfShape::LowPass, f, FRAC_1_SQRT_2, 0.0, sr);
        self.hp_c[j] = SvfCoefs::new(SvfShape::HighPass, f, FRAC_1_SQRT_2, 0.0, sr);
        self.ap_c[j] = SvfCoefs::new(SvfShape::AllPass, f, FRAC_1_SQRT_2, 0.0, sr);
    }

    fn rebuild_all(&mut self) {
        for j in 0..MAX_CROSSOVERS {
            self.rebuild(j);
        }
    }

    /// Advance the smoothers one sample and rebuild coefficients on schedule.
    #[inline]
    fn advance(&mut self) {
        let mut moved = false;
        for sm in self.smoothed[..self.count].iter_mut() {
            if !sm.is_settled() {
                sm.next();
                moved = true;
            }
        }
        if moved {
            self.pending = true;
        }
        if self.pending {
            self.tick = self.tick.wrapping_add(1);
            if !moved || self.tick % COEF_INTERVAL == 0 {
                for j in 0..self.count {
                    self.rebuild(j);
                }
                if !moved {
                    self.pending = false;
                }
            }
        }
    }

    /// Split interleaved stereo `input` (`frames` frames) into `bands[0..=count]` and write the
    /// phase-aligned dry into `dry_aligned`. Every output slice must hold at least `frames * 2`
    /// samples. Bands above `count` are left untouched.
    pub fn split(
        &mut self,
        input: &[f32],
        bands: &mut [Vec<f32>; MAX_BANDS],
        dry_aligned: &mut [f32],
        frames: usize,
    ) {
        let n = self.count;
        for f in 0..frames {
            self.advance();
            for ch in 0..2 {
                let i = f * 2 + ch;
                let x = input[i];

                let mut d = x;
                for k in 0..n {
                    d = self.dry[k][ch].process(d, &self.ap_c[k]);
                }
                dry_aligned[i] = d;

                let mut rem = x;
                for j in 0..n {
                    let [lp0, lp1] = &mut self.lp[j][ch];
                    let [hp0, hp1] = &mut self.hp[j][ch];
                    let lo = lp1.process(lp0.process(rem, &self.lp_c[j]), &self.lp_c[j]);
                    let hi = hp1.process(hp0.process(rem, &self.hp_c[j]), &self.hp_c[j]);
                    let mut b = lo;
                    for k in (j + 1)..n {
                        b = self.comp[j][k][ch].process(b, &self.ap_c[k]);
                    }
                    bands[j][i] = b;
                    rem = hi;
                }
                bands[n][i] = rem;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{peak, rms, sine, stereo, white_noise};

    const SR: f32 = 48_000.0;

    const EDGES: [f32; MAX_CROSSOVERS] = [100.0, 300.0, 1000.0, 3000.0, 8000.0];

    fn make(count: usize, edges: &[f32]) -> MultibandSplitter {
        let mut s = MultibandSplitter::new(SR);
        s.set_topology(count);
        s.set_targets(edges);
        s.snap();
        s
    }

    fn buffers(frames: usize) -> ([Vec<f32>; MAX_BANDS], Vec<f32>) {
        (
            std::array::from_fn(|_| vec![0.0; frames * 2]),
            vec![0.0; frames * 2],
        )
    }

    /// Mono left channel of a stereo buffer from `skip` frames on.
    fn left_from(buf: &[f32], skip: usize) -> Vec<f32> {
        buf.iter().step_by(2).skip(skip).copied().collect()
    }

    #[test]
    fn bands_sum_to_phase_aligned_dry_for_every_band_count() {
        let frames = 48_000;
        let input = stereo(&white_noise(frames, 0.5, 7));
        for count in 1..=MAX_CROSSOVERS {
            let mut s = make(count, &EDGES);
            let (mut bands, mut dry) = buffers(frames);
            s.split(&input, &mut bands, &mut dry, frames);
            let mut worst = 0.0f32;
            for i in 0..frames * 2 {
                let sum: f32 = bands[..=count].iter().map(|b| b[i]).sum();
                worst = worst.max((sum - dry[i]).abs());
            }
            assert!(
                worst < 1e-4,
                "{} bands: sum vs dry differ by {worst}",
                count + 1
            );
        }
    }

    #[test]
    fn sum_is_flat_in_magnitude() {
        let frames = 48_000;
        for count in [1, 3, 5] {
            for freq in [
                30.0, 100.0, 300.0, 1000.0, 2500.0, 8000.0, 12_000.0, 18_000.0,
            ] {
                let input = stereo(&sine(freq, SR, frames, 0.5));
                let mut s = make(count, &EDGES);
                let (mut bands, mut dry) = buffers(frames);
                s.split(&input, &mut bands, &mut dry, frames);
                let sum: Vec<f32> = (0..frames * 2)
                    .map(|i| bands[..=count].iter().map(|b| b[i]).sum())
                    .collect();
                let db = 20.0
                    * (rms(&left_from(&sum, frames / 2)) / rms(&left_from(&input, frames / 2)))
                        .log10();
                assert!(
                    db.abs() < 0.1,
                    "{} bands at {freq} Hz: {db:.3} dB",
                    count + 1
                );
            }
        }
    }

    #[test]
    fn band_center_tone_stays_in_its_band() {
        let frames = 48_000;
        let count = MAX_CROSSOVERS;
        let mut lows = vec![40.0];
        lows.extend_from_slice(&EDGES);
        let mut highs: Vec<f32> = EDGES.to_vec();
        highs.push(18_000.0);
        for band in 0..=count {
            let center = (lows[band] * highs[band]).sqrt();
            let input = stereo(&sine(center, SR, frames, 0.5));
            let mut s = make(count, &EDGES);
            let (mut bands, mut dry) = buffers(frames);
            s.split(&input, &mut bands, &mut dry, frames);
            let energy: Vec<f32> = bands[..=count]
                .iter()
                .map(|b| {
                    let r = rms(&left_from(b, frames / 2));
                    r * r
                })
                .collect();
            let share = energy[band] / energy.iter().sum::<f32>();
            assert!(
                share >= 0.9,
                "band {band} at {center:.0} Hz holds {share:.3}"
            );
        }
    }

    #[test]
    fn slope_is_24_db_per_octave() {
        let frames = 48_000;
        let fc = 1000.0;
        let reference = rms(&left_from(
            &stereo(&sine(fc * 2.0, SR, frames, 0.5)),
            frames / 2,
        ));
        // Low band, one octave above the crossover.
        let mut s = make(1, &[fc]);
        let (mut bands, mut dry) = buffers(frames);
        s.split(
            &stereo(&sine(fc * 2.0, SR, frames, 0.5)),
            &mut bands,
            &mut dry,
            frames,
        );
        let low_db = 20.0 * (rms(&left_from(&bands[0], frames / 2)) / reference).log10();
        assert!(
            (low_db + 24.6).abs() < 3.0,
            "low band at 2·fc: {low_db:.2} dB"
        );
        // High band, one octave below.
        let reference = rms(&left_from(
            &stereo(&sine(fc / 2.0, SR, frames, 0.5)),
            frames / 2,
        ));
        let mut s = make(1, &[fc]);
        s.split(
            &stereo(&sine(fc / 2.0, SR, frames, 0.5)),
            &mut bands,
            &mut dry,
            frames,
        );
        let high_db = 20.0 * (rms(&left_from(&bands[1], frames / 2)) / reference).log10();
        assert!(
            (high_db + 24.6).abs() < 3.0,
            "high band at fc/2: {high_db:.2} dB"
        );
        // And −6 dB at the crossover itself.
        let at = stereo(&sine(fc, SR, frames, 0.5));
        s = make(1, &[fc]);
        s.split(&at, &mut bands, &mut dry, frames);
        let db = 20.0
            * (rms(&left_from(&bands[0], frames / 2)) / rms(&left_from(&at, frames / 2))).log10();
        assert!((db + 6.02).abs() < 0.3, "LR4 at fc: {db:.2} dB");
    }

    #[test]
    fn sweeping_a_crossover_stays_finite_and_bounded() {
        let block = 64;
        let blocks = 48_000 / block;
        let frames = block * blocks;
        let input = stereo(&white_noise(frames, 0.5, 3));
        let mut s = make(3, &[100.0, 1000.0, 5000.0]);
        let (mut bands, mut dry) = buffers(block);
        let mut out = Vec::with_capacity(frames * 2);
        for b in 0..blocks {
            let t = b as f32 / (blocks - 1) as f32;
            let sweep = 20.0 * 1000f32.powf(t);
            // Keep the list ascending, as the device would.
            let f1 = sweep.max(110.0);
            s.set_targets(&[100.0, f1, (f1 * 1.1).max(5000.0)]);
            s.split(
                &input[b * block * 2..(b + 1) * block * 2],
                &mut bands,
                &mut dry,
                block,
            );
            for i in 0..block * 2 {
                out.push(bands[..=3].iter().map(|x| x[i]).sum::<f32>());
            }
        }
        assert!(out.iter().all(|v| v.is_finite()));
        assert!(peak(&out) < 2.0, "peak {}", peak(&out));
    }

    #[test]
    fn smoothing_converges_to_target() {
        let mut s = make(1, &[1000.0]);
        s.set_targets(&[4000.0]);
        let (mut bands, mut dry) = buffers(4800);
        s.split(&stereo(&vec![0.0; 4800]), &mut bands, &mut dry, 4800);
        assert!((s.frequency(0) - 4000.0).abs() < 1.0);
    }
}
