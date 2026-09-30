//! 2× and 4× oversampling with polyphase IIR half-band filters (the structure of Laurent de
//! Soras' HIIR: two parallel chains of first-order all-pass sections).
//!
//! - IIR, so the added delay is a few samples of group delay and nothing is reported as latency
//!   (spec 012, decision 2). The phase response is not linear, which is inaudible for the
//!   nonlinear stages this is for (filter drive, saturation).
//! - 4× is two cascaded 2× stages; the second can use a wide transition band because the first
//!   already removed everything above the original Nyquist.
//! - Coefficients are designed once in `new`; `prepare` sizes the high-rate buffer. Processing
//!   never allocates.

use std::f64::consts::PI;

/// All-pass sections per half-band, at most.
const MAX_COEFS: usize = 12;
/// Stage 1 (1×↔2×): steep. The passband ends at 0.215 of the 2× rate (about 20.6 kHz at a
/// 48 kHz base) and the stopband starts at 0.285 (27.4 kHz).
const STAGE1_COEFS: usize = 12;
const STAGE1_TRANSITION: f64 = 0.035;
/// Stage 2 (2×↔4×): the signal is already band-limited, so a wide, cheap transition.
const STAGE2_COEFS: usize = 6;
const STAGE2_TRANSITION: f64 = 0.2;

/// Half-band all-pass coefficients for `count` sections and a transition bandwidth (normalized
/// to the higher rate, 0..0.5). From HIIR's `PolyphaseIir2Designer`.
fn design_coefs(count: usize, transition: f64) -> Vec<f64> {
    let mut k = ((1.0 - transition * 2.0) * PI / 4.0).tan();
    k *= k;
    let kk_sqrt = (1.0 - k * k).powf(0.25);
    let e = 0.5 * (1.0 - kk_sqrt) / (1.0 + kk_sqrt);
    let e4 = e * e * e * e;
    let q = e * (1.0 + e4 * (2.0 + e4 * (15.0 + 150.0 * e4)));
    let order = (count * 2 + 1) as f64;

    (0..count)
        .map(|index| {
            let c = (index + 1) as f64;
            let mut num = 0.0;
            let (mut i, mut sign) = (0i32, 1.0);
            loop {
                let term = q.powi(i * (i + 1)) * ((i * 2 + 1) as f64 * c * PI / order).sin() * sign;
                num += term;
                sign = -sign;
                i += 1;
                if term.abs() <= 1e-100 || i > 64 {
                    break;
                }
            }
            let mut den = 0.0;
            let (mut i, mut sign) = (1i32, -1.0);
            loop {
                let term = q.powi(i * i) * ((i * 2) as f64 * c * PI / order).cos() * sign;
                den += term;
                sign = -sign;
                i += 1;
                if term.abs() <= 1e-100 || i > 64 {
                    break;
                }
            }
            let ww = num * q.powf(0.25) / (den + 0.5);
            let ww_sq = ww * ww;
            let x = ((1.0 - ww_sq * k) * (1.0 - ww_sq / k)).sqrt() / (1.0 + ww_sq);
            (1.0 - x) / (1.0 + x)
        })
        .collect()
}

/// A chain of first-order all-pass sections `y = c·(x − y₁) + x₁`, run at the lower rate.
#[derive(Clone, Copy, Debug)]
struct AllpassChain {
    coefs: [f32; MAX_COEFS],
    len: usize,
    x1: [f32; MAX_COEFS],
    y1: [f32; MAX_COEFS],
}

impl AllpassChain {
    fn new(coefs: impl Iterator<Item = f64>) -> Self {
        let mut chain = Self {
            coefs: [0.0; MAX_COEFS],
            len: 0,
            x1: [0.0; MAX_COEFS],
            y1: [0.0; MAX_COEFS],
        };
        for c in coefs {
            chain.coefs[chain.len] = c as f32;
            chain.len += 1;
        }
        chain
    }

    #[inline]
    fn process(&mut self, mut x: f32) -> f32 {
        for i in 0..self.len {
            let y = self.coefs[i] * (x - self.y1[i]) + self.x1[i];
            self.x1[i] = x;
            self.y1[i] = y;
            x = y;
        }
        x
    }

    fn reset(&mut self) {
        self.x1 = [0.0; MAX_COEFS];
        self.y1 = [0.0; MAX_COEFS];
    }
}

/// One half-band filter: even coefficients on path A, odd ones on path B.
#[derive(Clone, Copy, Debug)]
struct HalfBand {
    a: AllpassChain,
    b: AllpassChain,
}

impl HalfBand {
    fn new(coefs: &[f64]) -> Self {
        Self {
            a: AllpassChain::new(coefs.iter().copied().step_by(2)),
            b: AllpassChain::new(coefs.iter().copied().skip(1).step_by(2)),
        }
    }

    /// One input sample → two output samples at twice the rate.
    #[inline]
    fn upsample(&mut self, x: f32) -> (f32, f32) {
        (self.a.process(x), self.b.process(x))
    }

    /// Two input samples (in time order) → one output sample at half the rate.
    #[inline]
    fn downsample(&mut self, x0: f32, x1: f32) -> f32 {
        0.5 * (self.a.process(x1) + self.b.process(x0))
    }

    fn reset(&mut self) {
        self.a.reset();
        self.b.reset();
    }
}

/// Stereo oversampler. Run a nonlinear stage at the high rate with [`Oversampler::process`].
#[derive(Clone, Debug)]
pub struct Oversampler {
    factor: usize,
    /// Per channel: stage 1 and stage 2 filters, up and down.
    up: [[HalfBand; 2]; 2],
    down: [[HalfBand; 2]; 2],
    /// Interleaved stereo at the high rate.
    buffer: Vec<f32>,
    /// Scratch for the 2× signal between the stages (4× only), interleaved stereo.
    middle: Vec<f32>,
}

impl Default for Oversampler {
    fn default() -> Self {
        Self::new()
    }
}

impl Oversampler {
    /// Factor 1 (off); call `prepare` before processing.
    pub fn new() -> Self {
        let stage1 = HalfBand::new(&design_coefs(STAGE1_COEFS, STAGE1_TRANSITION));
        let stage2 = HalfBand::new(&design_coefs(STAGE2_COEFS, STAGE2_TRANSITION));
        Self {
            factor: 1,
            up: [[stage1, stage2]; 2],
            down: [[stage1, stage2]; 2],
            buffer: Vec::new(),
            middle: Vec::new(),
        }
    }

    /// Size the buffers for blocks of up to `max_frames` at the base rate. Command thread only.
    pub fn prepare(&mut self, max_frames: usize) {
        self.buffer = vec![0.0; max_frames * 4 * 2];
        self.middle = vec![0.0; max_frames * 2 * 2];
        self.reset();
    }

    pub fn factor(&self) -> usize {
        self.factor
    }

    /// 1, 2 or 4 (anything else rounds to the nearest of those). Clears the filter state when it
    /// changes, so crossfade around a switch if it happens during playback.
    pub fn set_factor(&mut self, factor: usize) {
        let factor = match factor {
            0 | 1 => 1,
            2 | 3 => 2,
            _ => 4,
        };
        if factor != self.factor {
            self.factor = factor;
            self.reset();
        }
    }

    pub fn reset(&mut self) {
        for channel in 0..2 {
            for stage in 0..2 {
                self.up[channel][stage].reset();
                self.down[channel][stage].reset();
            }
        }
    }

    /// Upsample `frames` of interleaved stereo `input`, run `stage` on the high-rate interleaved
    /// buffer (`frames × factor` frames), and downsample into `output`. `frames` must not exceed
    /// the prepared maximum.
    pub fn process(
        &mut self,
        input: &[f32],
        output: &mut [f32],
        frames: usize,
        mut stage: impl FnMut(&mut [f32]),
    ) {
        let n = frames * 2;
        match self.factor {
            1 => {
                self.buffer[..n].copy_from_slice(&input[..n]);
                stage(&mut self.buffer[..n]);
                output[..n].copy_from_slice(&self.buffer[..n]);
            }
            2 => {
                up2(&mut self.up, 0, &input[..n], &mut self.buffer[..n * 2]);
                stage(&mut self.buffer[..n * 2]);
                down2(&mut self.down, 0, &self.buffer[..n * 2], &mut output[..n]);
            }
            _ => {
                up2(&mut self.up, 0, &input[..n], &mut self.middle[..n * 2]);
                up2(
                    &mut self.up,
                    1,
                    &self.middle[..n * 2],
                    &mut self.buffer[..n * 4],
                );
                stage(&mut self.buffer[..n * 4]);
                down2(
                    &mut self.down,
                    1,
                    &self.buffer[..n * 4],
                    &mut self.middle[..n * 2],
                );
                down2(&mut self.down, 0, &self.middle[..n * 2], &mut output[..n]);
            }
        }
    }
}

/// Interleaved stereo `input` → twice as many frames in `output`, with filter stage `stage`.
fn up2(filters: &mut [[HalfBand; 2]; 2], stage: usize, input: &[f32], output: &mut [f32]) {
    for (frame, out) in input.chunks_exact(2).zip(output.chunks_exact_mut(4)) {
        let (l0, l1) = filters[0][stage].upsample(frame[0]);
        let (r0, r1) = filters[1][stage].upsample(frame[1]);
        out.copy_from_slice(&[l0, r0, l1, r1]);
    }
}

/// Interleaved stereo `input` → half as many frames in `output`, with filter stage `stage`.
fn down2(filters: &mut [[HalfBand; 2]; 2], stage: usize, input: &[f32], output: &mut [f32]) {
    for (frames, out) in input.chunks_exact(4).zip(output.chunks_exact_mut(2)) {
        out[0] = filters[0][stage].downsample(frames[0], frames[2]);
        out[1] = filters[1][stage].downsample(frames[1], frames[3]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;

    /// Amplitude of `freq` in `signal` (one channel), by correlation over whole cycles.
    fn amplitude(signal: &[f32], freq: f32, sr: f32) -> f32 {
        let (mut re, mut im) = (0.0f64, 0.0f64);
        for (i, &x) in signal.iter().enumerate() {
            let phase = (TAU as f64) * freq as f64 * i as f64 / sr as f64;
            re += x as f64 * phase.cos();
            im += x as f64 * phase.sin();
        }
        (2.0 * (re * re + im * im).sqrt() / signal.len() as f64) as f32
    }

    fn stereo_sine(freq: f32, sr: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .flat_map(|i| {
                let x = 0.5 * (TAU * freq * i as f32 / sr).sin();
                [x, x]
            })
            .collect()
    }

    fn left(interleaved: &[f32]) -> Vec<f32> {
        interleaved.iter().step_by(2).copied().collect()
    }

    #[test]
    fn round_trip_keeps_the_passband() {
        let sr = 48_000.0;
        let frames = 48_000;
        for factor in [2, 4] {
            for freq in [100.0, 1_000.0, 10_000.0, 18_000.0] {
                let mut os = Oversampler::new();
                os.prepare(frames);
                os.set_factor(factor);
                let input = stereo_sine(freq, sr, frames);
                let mut output = vec![0.0; input.len()];
                os.process(&input, &mut output, frames, |_| {});
                let tail = &left(&output)[4_800..];
                let gain_db = 20.0 * (amplitude(tail, freq, sr) / 0.5).log10();
                assert!(
                    gain_db.abs() < 0.1,
                    "{factor}× at {freq} Hz: {gain_db:.3} dB"
                );
            }
        }
    }

    #[test]
    fn upsampling_rejects_images() {
        // A 15 kHz tone at 48 kHz images to 33 kHz at 96 kHz.
        let (sr, frames, freq) = (48_000.0, 24_000, 15_000.0);
        for factor in [2usize, 4] {
            let mut os = Oversampler::new();
            os.prepare(frames);
            os.set_factor(factor);
            let input = stereo_sine(freq, sr, frames);
            let mut output = vec![0.0; input.len()];
            let high_sr = sr * factor as f32;
            let mut image_db = 0.0;
            os.process(&input, &mut output, frames, |high| {
                let signal = &left(high)[4_800..];
                let wanted = amplitude(signal, freq, high_sr);
                let image = amplitude(signal, sr - freq, high_sr);
                image_db = 20.0 * (image / wanted).log10();
            });
            assert!(image_db < -80.0, "{factor}× image at {image_db:.1} dB");
        }
    }

    #[test]
    fn downsampling_rejects_content_above_the_base_nyquist() {
        // A 30 kHz tone made at the high rate would alias to 18 kHz at 48 kHz.
        let (sr, frames) = (48_000.0, 24_000);
        for factor in [2usize, 4] {
            let mut os = Oversampler::new();
            os.prepare(frames);
            os.set_factor(factor);
            let input = vec![0.0; frames * 2];
            let mut output = vec![0.0; frames * 2];
            let high_sr = sr * factor as f32;
            os.process(&input, &mut output, frames, |high| {
                for (i, frame) in high.chunks_exact_mut(2).enumerate() {
                    let x = 0.5 * (TAU * 30_000.0 * i as f32 / high_sr).sin();
                    frame[0] = x;
                    frame[1] = x;
                }
            });
            let alias = amplitude(&left(&output)[4_800..], 18_000.0, sr);
            let alias_db = 20.0 * (alias / 0.5).log10();
            assert!(alias_db < -80.0, "{factor}× alias at {alias_db:.1} dB");
        }
    }

    #[test]
    fn factor_one_runs_the_stage_in_place() {
        let mut os = Oversampler::new();
        os.prepare(64);
        let input: Vec<f32> = (0..128).map(|i| i as f32).collect();
        let mut output = vec![0.0; 128];
        os.process(&input, &mut output, 64, |buf| {
            buf.iter_mut().for_each(|x| *x *= 2.0)
        });
        assert_eq!(output[10], 20.0);
    }
}
