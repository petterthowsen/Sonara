//! Deterministic noise sources for drum voices: xorshift32 white noise and Paul Kellet's economy
//! pink filter. Neither allocates.

/// Small, fast, seedable xorshift32 generator (Marsaglia).
#[derive(Clone, Debug)]
pub struct Rng {
    state: u32,
}

impl Rng {
    /// Seed 0 would lock the generator at 0, so it maps to a fixed nonzero constant.
    pub fn new(seed: u32) -> Self {
        Self {
            state: if seed == 0 { 0x9E37_79B9 } else { seed },
        }
    }

    #[inline]
    pub fn next_u32(&mut self) -> u32 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        x
    }

    /// Uniform in 0.0..1.0, from the top 24 bits (so it is exactly representable in f32).
    #[inline]
    pub fn next_f32(&mut self) -> f32 {
        (self.next_u32() >> 8) as f32 / (1u32 << 24) as f32
    }

    /// Uniform in −1.0..1.0.
    #[inline]
    pub fn bipolar(&mut self) -> f32 {
        self.next_f32() * 2.0 - 1.0
    }
}

impl Default for Rng {
    fn default() -> Self {
        Self::new(0x1234_5678)
    }
}

/// White noise in −1.0..1.0.
#[derive(Clone, Debug)]
pub struct WhiteNoise {
    rng: Rng,
}

impl WhiteNoise {
    pub fn new(seed: u32) -> Self {
        Self {
            rng: Rng::new(seed),
        }
    }

    pub fn reset(&mut self, seed: u32) {
        self.rng = Rng::new(seed);
    }

    #[inline]
    pub fn next(&mut self) -> f32 {
        self.rng.bipolar()
    }
}

/// Pink noise from a white source, roughly −3 dB/octave (Paul Kellet's economy filter).
#[derive(Clone, Debug)]
pub struct PinkNoise {
    rng: Rng,
    b0: f32,
    b1: f32,
    b2: f32,
}

impl PinkNoise {
    pub fn new(seed: u32) -> Self {
        Self {
            rng: Rng::new(seed),
            b0: 0.0,
            b1: 0.0,
            b2: 0.0,
        }
    }

    pub fn reset(&mut self, seed: u32) {
        self.rng = Rng::new(seed);
        self.b0 = 0.0;
        self.b1 = 0.0;
        self.b2 = 0.0;
    }

    #[inline]
    pub fn next(&mut self) -> f32 {
        let w = self.rng.bipolar();
        self.b0 = 0.99765 * self.b0 + w * 0.0990460;
        self.b1 = 0.96300 * self.b1 + w * 0.2965164;
        self.b2 = 0.57000 * self.b2 + w * 1.0526913;
        (self.b0 + self.b1 + self.b2 + w * 0.1848) * 0.11
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::spectrum_db;

    const SR: f32 = 48_000.0;
    const FFT_LEN: usize = 65_536;
    const SEGMENTS: usize = 8;
    /// Bins summed around each centre for one measurement (fixed width in Hz, so a flat
    /// per-bin spectrum reads flat and a 1/f spectrum falls 3 dB/oct).
    const HALF_BINS: usize = 8;

    fn collect(count: usize, mut next: impl FnMut() -> f32) -> Vec<f32> {
        (0..count).map(|_| next()).collect()
    }

    fn narrow_band_db(signal: &[f32], center_hz: f32) -> f32 {
        let bin_hz = SR / FFT_LEN as f32;
        let center = (center_hz / bin_hz).round() as usize;
        let lo = center.saturating_sub(HALF_BINS);
        let hi = (center + HALF_BINS).min(FFT_LEN / 2);
        let mut power = 0.0f64;
        let mut segments = 0usize;
        let mut pos = 0;
        while pos + FFT_LEN <= signal.len() {
            let db = spectrum_db(&signal[pos..pos + FFT_LEN]);
            for b in lo..=hi {
                power += 10f64.powf(db[b] as f64 / 10.0);
            }
            segments += 1;
            pos += FFT_LEN;
        }
        (10.0 * (power / segments.max(1) as f64).max(1e-30).log10()) as f32
    }

    #[test]
    fn same_seed_gives_identical_samples() {
        let mut a = WhiteNoise::new(1234);
        let mut b = WhiteNoise::new(1234);
        for n in 0..1000 {
            assert_eq!(a.next(), b.next(), "white at {n}");
        }
        let mut a = PinkNoise::new(99);
        let mut b = PinkNoise::new(99);
        for n in 0..1000 {
            assert_eq!(a.next(), b.next(), "pink at {n}");
        }
    }

    #[test]
    fn white_is_zero_mean() {
        let mut noise = WhiteNoise::new(1);
        let n = 200_000;
        let mean = collect(n, || noise.next()).iter().sum::<f32>() / n as f32;
        assert!(mean.abs() < 0.005, "mean {mean}");
    }

    #[test]
    fn white_is_flat_and_pink_falls_3db_per_octave() {
        let centers = [125.0f32, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0];
        let mut white = WhiteNoise::new(2024);
        let white_signal = collect(FFT_LEN * SEGMENTS, || white.next());
        let levels: Vec<f32> = centers
            .iter()
            .map(|&c| narrow_band_db(&white_signal, c))
            .collect();
        let spread = levels.iter().cloned().fold(f32::MIN, f32::max)
            - levels.iter().cloned().fold(f32::MAX, f32::min);
        assert!(spread < 1.5, "white spread {spread} dB: {levels:?}");

        let mut pink = PinkNoise::new(2024);
        let pink_signal = collect(FFT_LEN * SEGMENTS, || pink.next());
        let at_125 = narrow_band_db(&pink_signal, 125.0);
        let at_4k = narrow_band_db(&pink_signal, 4_000.0);
        let octaves = (4_000f32 / 125.0).log2();
        let slope = (at_4k - at_125) / octaves;
        assert!((slope + 3.0).abs() < 1.0, "pink slope {slope} dB/oct");
    }
}
