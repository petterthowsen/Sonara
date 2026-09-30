//! Windowed FFT magnitude spectrum in dBFS, shared by the Spectrum Analyzer and the EQ's
//! analyser.
//!
//! - Feed mono samples with [`Spectrum::push`]; [`Spectrum::compute`] transforms the latest
//!   `size` samples (Hann window) and updates an exponentially smoothed dB spectrum.
//! - Everything, including the FFT scratch, is allocated in `new`/`resize`; `push` and `compute`
//!   never allocate.
//! - Bins at or below 30 Hz and the Nyquist bin read as silence ([`SILENCE_DB`]), so DC and
//!   subsonic rumble don't dominate the display.

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};
use std::sync::Arc;

/// The floor of the spectrum, in dBFS.
pub const SILENCE_DB: f32 = -160.0;
/// Bins at or below this frequency are silenced.
const LOW_CUT_HZ: f32 = 30.0;

pub struct Spectrum {
    size: usize,
    fft: Arc<dyn RealToComplex<f32>>,
    /// The latest `size` samples, oldest at `write_pos`.
    ring: Vec<f32>,
    write_pos: usize,
    window: Vec<f32>,
    /// `2 / Σwindow`: turns FFT magnitudes into amplitudes relative to full scale.
    norm: f32,
    input: Vec<f32>,
    output: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
    smoothed: Vec<f32>,
    /// 0 = no smoothing, towards 1 = slow.
    smoothing: f32,
}

impl Spectrum {
    /// FFT of `size` samples (a power of two is fastest). Allocates: command thread only.
    pub fn new(size: usize, smoothing: f32) -> Self {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(size);
        let window = hann(size);
        let norm = 2.0 / window.iter().sum::<f32>();
        Self {
            size,
            input: fft.make_input_vec(),
            output: fft.make_output_vec(),
            scratch: fft.make_scratch_vec(),
            fft,
            ring: vec![0.0; size],
            write_pos: 0,
            window,
            norm,
            smoothed: vec![SILENCE_DB; size / 2 + 1],
            smoothing,
        }
    }

    /// Change the FFT size (clears the history). Allocates: command thread only.
    pub fn resize(&mut self, size: usize) {
        if size != self.size {
            *self = Self::new(size, self.smoothing);
        }
    }

    pub fn size(&self) -> usize {
        self.size
    }

    pub fn bin_count(&self) -> usize {
        self.size / 2 + 1
    }

    pub fn reset(&mut self) {
        self.ring.fill(0.0);
        self.write_pos = 0;
        self.smoothed.fill(SILENCE_DB);
    }

    #[inline]
    pub fn push(&mut self, sample: f32) {
        self.ring[self.write_pos] = sample;
        self.write_pos = (self.write_pos + 1) % self.size;
    }

    /// Transform the latest `size` samples and fold them into the smoothed spectrum.
    pub fn compute(&mut self, sample_rate: f32) {
        for i in 0..self.size {
            let sample = self.ring[(self.write_pos + i) % self.size];
            self.input[i] = sample * self.window[i];
        }
        if let Err(e) =
            self.fft
                .process_with_scratch(&mut self.input, &mut self.output, &mut self.scratch)
        {
            tracing::warn!("Spectrum FFT failed: {}", e);
            return;
        }

        let bins = self.bin_count();
        let bin_hz = sample_rate / self.size as f32;
        let low_cut_bin = ((LOW_CUT_HZ / bin_hz).ceil() as usize).min(bins - 1);
        for (i, bin) in self.output.iter().enumerate().take(bins) {
            let db = if i <= low_cut_bin || i == bins - 1 {
                SILENCE_DB
            } else {
                let amplitude = bin.norm() * self.norm;
                (20.0 * (amplitude + 1e-20).log10()).clamp(SILENCE_DB, 0.0)
            };
            self.smoothed[i] = self.smoothing * self.smoothed[i] + (1.0 - self.smoothing) * db;
        }
    }

    /// The smoothed spectrum in dBFS, one value per bin (`size / 2 + 1`).
    pub fn smoothed(&self) -> &[f32] {
        &self.smoothed
    }
}

fn hann(size: usize) -> Vec<f32> {
    (0..size)
        .map(|i| {
            let angle = std::f32::consts::TAU * i as f32 / (size - 1) as f32;
            0.5 * (1.0 - angle.cos())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sine_peaks_at_its_level_in_its_bin() {
        let sr = 48_000.0;
        let size = 2048;
        let mut spectrum = Spectrum::new(size, 0.0);
        // Centre the tone on bin 43 so there's no scalloping loss.
        let freq = 43.0 * sr / size as f32;
        for n in 0..size * 2 {
            spectrum.push(0.5 * (std::f32::consts::TAU * freq * n as f32 / sr).sin());
        }
        spectrum.compute(sr);
        let bins = spectrum.smoothed();
        let (peak_bin, peak_db) = bins
            .iter()
            .copied()
            .enumerate()
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .unwrap();
        assert_eq!(peak_bin, 43);
        assert!((peak_db + 6.02).abs() < 0.1, "{peak_db} dBFS");
        assert_eq!(bins[0], SILENCE_DB, "DC is silenced");
        assert_eq!(bins[size / 2], SILENCE_DB, "Nyquist is silenced");
    }
}
