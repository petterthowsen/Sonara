//! A small two-signal spectrum analyser for compact views (spec 044).
//!
//! [`MiniAnalyser`] runs an FFT over two signals, A and B, at a fixed resolution (4096 points at
//! 48 kHz, doubled at 96 kHz so the bin width stays put) and folds each into log-spaced display
//! points with ballistics, like the EQ's analyser but without options. A view feeds it with
//! [`push`](MiniAnalyser::push), asks [`due`](MiniAnalyser::due) on its poll, and appends the
//! frame to its own header with [`write_points`](MiniAnalyser::write_points).
//!
//! Allocation: only [`new`](MiniAnalyser::new) allocates, so build it on the command thread.
//! `push`, `due`, `reset` and `write_points` (apart from growing the caller's `Vec`) don't.

use super::log_spectrum::LogSpectrum;
use super::spectrum::{Spectrum, Window};

/// Frames per second the analyser produces.
pub const MINI_ANALYSER_RATE_HZ: f32 = 30.0;
/// FFT size at 48 kHz.
const FFT_SIZE_48K: usize = 4096;
/// Width in octaves of the band each point averages.
const POINT_WIDTH_OCTAVES: f32 = 1.0 / 6.0;
/// Display ballistics: attack and release time constants in seconds (the EQ's medium speed).
const ATTACK_SECONDS: f32 = 0.03;
const RELEASE_SECONDS: f32 = 0.35;

pub struct MiniAnalyser {
    points: usize,
    sample_rate: f32,
    a: Spectrum,
    b: Spectrum,
    a_log: LogSpectrum,
    b_log: LogSpectrum,
    frames: usize,
    interval: usize,
}

impl MiniAnalyser {
    /// Allocates: build it off the audio thread.
    pub fn new(sample_rate: f32, points: usize) -> Self {
        let points = points.max(2);
        let scale = (sample_rate / 48_000.0).round().max(1.0) as usize;
        let size = FFT_SIZE_48K * scale.next_power_of_two();
        let spectrum = || Spectrum::with_window(size, 0.0, Window::BlackmanHarris);
        let log = || {
            let mut log = LogSpectrum::new(points);
            log.configure(sample_rate, size, POINT_WIDTH_OCTAVES);
            log.set_ballistics(ATTACK_SECONDS, RELEASE_SECONDS, 1.0 / MINI_ANALYSER_RATE_HZ);
            log
        };
        Self {
            points,
            sample_rate,
            a: spectrum(),
            b: spectrum(),
            a_log: log(),
            b_log: log(),
            frames: 0,
            interval: (sample_rate / MINI_ANALYSER_RATE_HZ).max(1.0) as usize,
        }
    }

    /// The rate it was laid out for.
    pub fn sample_rate(&self) -> f32 {
        self.sample_rate
    }

    /// Display points per signal.
    pub fn points(&self) -> usize {
        self.points
    }

    /// Feed one sample of each signal.
    #[inline]
    pub fn push(&mut self, a: f32, b: f32) {
        self.a.push(a);
        self.b.push(b);
    }

    /// Clear both signals and the display.
    pub fn reset(&mut self) {
        self.a.reset();
        self.b.reset();
        self.a_log.reset();
        self.b_log.reset();
        self.frames = 0;
    }

    /// Credit `frames` of time; true once a frame is due.
    pub fn due(&mut self, frames: usize) -> bool {
        self.frames = self.frames.saturating_add(frames);
        if self.frames >= self.interval {
            // Keep the remainder so block sizes that don't divide the interval still average
            // 30 Hz; drop a backlog beyond one interval (a stalled poll doesn't burst).
            self.frames = (self.frames - self.interval).min(self.interval - 1);
            true
        } else {
            false
        }
    }

    /// Transform both signals and append `lo_hz, hi_hz`, `points` A values then `points` B
    /// values (dBFS, floor −160) as little-endian f32.
    pub fn write_points(&mut self, out: &mut Vec<u8>) {
        if self.a.transform() {
            self.a_log.update(self.a.power());
        }
        if self.b.transform() {
            self.b_log.update(self.b.power());
        }
        out.reserve((2 + 2 * self.points) * 4);
        let head = [self.a_log.lo_hz(), self.a_log.hi_hz()];
        for v in head.iter().chain(self.a_log.db()).chain(self.b_log.db()) {
            out.extend_from_slice(&v.to_le_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::spectrum::SILENCE_DB;

    const SR: f32 = 48_000.0;

    fn decode(bytes: &[u8]) -> Vec<f32> {
        bytes
            .chunks_exact(4)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect()
    }

    #[test]
    fn a_tone_on_a_lands_on_its_point_while_b_stays_at_the_floor() {
        let points = 128;
        let mut an = MiniAnalyser::new(SR, points);
        for i in 0..16_384 {
            let x = (std::f32::consts::TAU * 1_000.0 * i as f32 / SR).sin() * 0.5;
            an.push(x, 0.0);
        }
        // Let the ballistics settle.
        let mut bytes = Vec::new();
        for _ in 0..30 {
            bytes.clear();
            an.write_points(&mut bytes);
        }
        let v = decode(&bytes);
        let (lo, hi) = (v[0], v[1]);
        let a = &v[2..2 + points];
        let b = &v[2 + points..];
        let expected = ((1_000.0f32 / lo).ln() / (hi / lo).ln() * (points - 1) as f32).round();
        let peak = (0..points).max_by(|&i, &j| a[i].total_cmp(&a[j])).unwrap();
        assert!(
            (peak as f32 - expected).abs() <= 1.0,
            "peak at {peak}, expected {expected}"
        );
        assert!(a[peak] > -20.0, "tone level {}", a[peak]);
        assert!(b.iter().all(|&x| x <= SILENCE_DB + 1.0), "B stays silent");
    }

    #[test]
    fn write_points_appends_the_documented_length() {
        let mut an = MiniAnalyser::new(SR, 128);
        let mut bytes = vec![1, 2, 3];
        an.write_points(&mut bytes);
        assert_eq!(bytes.len(), 3 + (2 + 2 * 128) * 4);
    }

    #[test]
    fn due_fires_about_thirty_times_a_second() {
        let mut an = MiniAnalyser::new(SR, 128);
        let fired = (0..(SR as usize / 256)).filter(|_| an.due(256)).count();
        assert!((28..=31).contains(&fired), "{fired}");
    }
}
