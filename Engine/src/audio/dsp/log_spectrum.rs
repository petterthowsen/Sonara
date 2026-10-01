//! A spectrum on a log frequency axis, for display: `points` values spaced evenly in log
//! frequency from [`LogSpectrum::lo_hz`] to [`LogSpectrum::hi_hz`], each the mean power of a
//! fractional-octave band around it, with attack/release ballistics in dB.
//!
//! - The mean is taken over the per-bin power interpolated linearly between bins, so a band
//!   narrower than a bin (the bass at small FFT sizes) reads the interpolated power and a wide
//!   band (the treble) the average of its bins, with no seam between the two.
//! - It uses an `f64` running integral of the power, so every point costs O(1) whatever its width.
//! - `configure` allocates (command thread); `update` and `reset` don't (audio thread).

use super::spectrum::SILENCE_DB;

/// The lowest and highest frequencies shown.
pub const MIN_HZ: f32 = 20.0;
pub const MAX_HZ: f32 = 20_000.0;
/// The loudest value reported, in dBFS.
const CEIL_DB: f32 = 12.0;

pub struct LogSpectrum {
    lo_hz: f32,
    hi_hz: f32,
    /// Band edges per point, in (fractional) bins.
    edges: Vec<(f64, f64)>,
    /// `integral[k]` = ∫₀ᵏ power over bins, with power linear between bins.
    integral: Vec<f64>,
    db: Vec<f32>,
    attack: f32,
    release: f32,
}

impl LogSpectrum {
    /// `points` values (at least 2). Call [`LogSpectrum::configure`] before use. Allocates.
    pub fn new(points: usize) -> Self {
        let points = points.max(2);
        Self {
            lo_hz: MIN_HZ,
            hi_hz: MAX_HZ,
            edges: vec![(0.0, 0.0); points],
            integral: Vec::new(),
            db: vec![SILENCE_DB; points],
            attack: 1.0,
            release: 1.0,
        }
    }

    /// Lay the points out for an FFT of `fft_size` at `sample_rate`, each averaging a band
    /// `width_octaves` wide. Clears the ballistics. Allocates when the FFT size changes.
    pub fn configure(&mut self, sample_rate: f32, fft_size: usize, width_octaves: f32) {
        let bins = fft_size / 2 + 1;
        self.integral.resize(bins, 0.0);
        self.lo_hz = MIN_HZ;
        self.hi_hz = MAX_HZ.min(sample_rate * 0.49).max(MIN_HZ * 2.0);
        let bin_hz = sample_rate as f64 / fft_size as f64;
        let last_bin = (bins - 1) as f64;
        let half = 2f64.powf(width_octaves.max(0.0) as f64 * 0.5);
        let ratio = (self.hi_hz / self.lo_hz) as f64;
        let count = self.edges.len();
        for (i, edge) in self.edges.iter_mut().enumerate() {
            let hz = self.lo_hz as f64 * ratio.powf(i as f64 / (count - 1) as f64);
            let lo = (hz / half / bin_hz).clamp(0.0, last_bin);
            let hi = (hz * half / bin_hz).clamp(0.0, last_bin);
            *edge = (lo, hi);
        }
        self.reset();
    }

    /// Attack and release time constants, for updates every `frame_seconds`.
    pub fn set_ballistics(
        &mut self,
        attack_seconds: f32,
        release_seconds: f32,
        frame_seconds: f32,
    ) {
        let coef = |tau: f32| 1.0 - (-frame_seconds / tau.max(1e-4)).exp();
        self.attack = coef(attack_seconds);
        self.release = coef(release_seconds);
    }

    pub fn reset(&mut self) {
        self.db.fill(SILENCE_DB);
    }

    /// Fold one transform's per-bin power (`fft_size / 2 + 1` values) into the points.
    pub fn update(&mut self, power: &[f32]) {
        let n = power.len().min(self.integral.len());
        if n < 3 {
            return;
        }
        // DC carries nothing worth showing; let bin 0 repeat bin 1 so 20 Hz isn't pulled down.
        let p = |k: usize| power[k.max(1)] as f64;
        self.integral[0] = 0.0;
        for k in 1..n {
            self.integral[k] = self.integral[k - 1] + 0.5 * (p(k - 1) + p(k));
        }
        let integral = &self.integral[..n];
        let at = |x: f64| -> f64 {
            let k = (x.floor() as usize).min(n - 2);
            let t = x - k as f64;
            let (a, b) = (p(k), p(k + 1));
            integral[k] + a * t + (b - a) * t * t * 0.5
        };
        for (db, &(lo, hi)) in self.db.iter_mut().zip(&self.edges) {
            let mean = if hi - lo > 1e-9 {
                ((at(hi) - at(lo)) / (hi - lo)).max(0.0)
            } else {
                let k = (lo.floor() as usize).min(n - 2);
                let t = lo - k as f64;
                p(k) + (p(k + 1) - p(k)) * t
            };
            let target = ((10.0 * (mean + 1e-30).log10()) as f32).clamp(SILENCE_DB, CEIL_DB);
            let coef = if target > *db {
                self.attack
            } else {
                self.release
            };
            *db += (target - *db) * coef;
        }
    }

    /// The points in dBFS, low to high.
    pub fn db(&self) -> &[f32] {
        &self.db
    }

    pub fn lo_hz(&self) -> f32 {
        self.lo_hz
    }

    pub fn hi_hz(&self) -> f32 {
        self.hi_hz
    }

    /// The frequency of point `i`.
    #[cfg(test)]
    pub fn point_hz(&self, i: usize) -> f32 {
        let t = i as f32 / (self.db.len() - 1) as f32;
        self.lo_hz * (self.hi_hz / self.lo_hz).powf(t)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::spectrum::{Spectrum, Window};

    const SR: f32 = 48_000.0;

    fn analyse(signal: impl Fn(usize) -> f32, size: usize, width: f32) -> LogSpectrum {
        let mut spectrum = Spectrum::with_window(size, 0.0, Window::BlackmanHarris);
        for n in 0..size {
            spectrum.push(signal(n));
        }
        spectrum.transform();
        let mut log = LogSpectrum::new(256);
        log.configure(SR, size, width);
        log.update(spectrum.power());
        log
    }

    fn nearest(log: &LogSpectrum, hz: f32) -> usize {
        (0..log.db().len())
            .min_by(|&a, &b| {
                (log.point_hz(a) / hz)
                    .ln()
                    .abs()
                    .total_cmp(&(log.point_hz(b) / hz).ln().abs())
            })
            .unwrap()
    }

    #[test]
    fn points_span_20_hz_to_20_khz() {
        let mut log = LogSpectrum::new(256);
        log.configure(SR, 4096, 1.0 / 6.0);
        assert_eq!(log.point_hz(0), 20.0);
        assert!((log.point_hz(255) - 20_000.0).abs() < 1.0);
        log.configure(32_000.0, 4096, 1.0 / 6.0);
        assert!(log.hi_hz() < 16_000.0, "stays below Nyquist");
    }

    /// A bass tone is a single smooth hill: falling away on both sides of the peak, with no
    /// sidelobe spikes rising again nearby.
    #[test]
    fn a_bass_tone_is_one_smooth_hill() {
        for (size, width) in [(2048, 1.0 / 3.0), (4096, 1.0 / 6.0), (16384, 1.0 / 24.0)] {
            let log = analyse(
                |n| 0.5 * (std::f32::consts::TAU * 80.0 * n as f32 / SR).sin(),
                size,
                width,
            );
            let db = log.db();
            let (lo, hi) = (nearest(&log, 25.0), nearest(&log, 300.0));
            let peak = (lo..hi).max_by(|&a, &b| db[a].total_cmp(&db[b])).unwrap();
            let peak_hz = log.point_hz(peak);
            assert!(
                (peak_hz / 80.0).log2().abs() < width,
                "{size}: peak at {peak_hz} Hz"
            );
            // Only the visible range: Blackman-Harris ripples 90 dB down, far below the floor.
            let visible = |i: usize| db[i].max(db[i + 1]) > db[peak] - 70.0;
            for i in lo..peak {
                assert!(
                    !visible(i) || db[i] <= db[i + 1] + 0.01,
                    "{size}: rises up to the peak at {} Hz",
                    log.point_hz(i)
                );
            }
            for i in peak..hi {
                assert!(
                    !visible(i) || db[i + 1] <= db[i] + 0.01,
                    "{size}: falls after the peak at {} Hz",
                    log.point_hz(i)
                );
            }
            assert!(db[peak] > -20.0, "{size}: the tone shows ({})", db[peak]);
        }
    }

    #[test]
    fn white_noise_reads_flat() {
        let mut state = 1u32;
        let mut noise = Vec::new();
        for _ in 0..16384 {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            noise.push((state >> 8) as f32 / (1u32 << 24) as f32 - 0.5);
        }
        let log = analyse(|n| noise[n], 16384, 1.0 / 3.0);
        let (a, b) = (
            log.db()[nearest(&log, 1_000.0)],
            log.db()[nearest(&log, 10_000.0)],
        );
        assert!((a - b).abs() < 2.0, "1 kHz {a:.1} dB vs 10 kHz {b:.1} dB");
    }

    #[test]
    fn release_decays_towards_silence() {
        let mut log = LogSpectrum::new(16);
        log.configure(SR, 1024, 1.0 / 3.0);
        log.set_ballistics(0.0, 0.3, 0.05);
        let mut power = vec![1e-2f32; 513];
        log.update(&power);
        let loud = log.db()[8];
        assert!((loud + 20.0).abs() < 0.5, "instant attack: {loud}");
        power.fill(0.0);
        log.update(&power);
        let falling = log.db()[8];
        assert!(
            falling < loud && falling > -60.0,
            "falls gradually: {falling}"
        );
    }
}
