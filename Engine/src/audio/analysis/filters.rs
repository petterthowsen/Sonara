//! Filters for the analyzer: BS.1770 K-weighting and the six-band bank. Offline only, so
//! everything runs in f64 and processes a stereo frame (two lanes) per call.

use std::f64::consts::PI;

pub type Frame = [f64; 2];

pub const BAND_COUNT: usize = 6;

/// Band edges in Hz: sub, bass, lowmid, mid, himid, air.
pub const BAND_EDGES: [(f64, f64); BAND_COUNT] = [
    (20.0, 60.0),
    (60.0, 250.0),
    (250.0, 800.0),
    (800.0, 2500.0),
    (2500.0, 6000.0),
    (6000.0, 20000.0),
];

/// Highest edge used, as a fraction of the sample rate. Keeps the bilinear transform sane at
/// low rates, and an edge above it is dropped.
const MAX_EDGE_FRACTION: f64 = 0.45;

#[derive(Debug, Clone, Copy)]
struct Coefs {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

impl Coefs {
    /// Normalizes by `a0`.
    fn new(b: [f64; 3], a: [f64; 3]) -> Self {
        Self {
            b0: b[0] / a[0],
            b1: b[1] / a[0],
            b2: b[2] / a[0],
            a1: a[1] / a[0],
            a2: a[2] / a[0],
        }
    }

    /// |H|^2 at `hz`.
    fn power(&self, hz: f64, sample_rate: f64) -> f64 {
        let w = 2.0 * PI * hz / sample_rate;
        let (c1, s1) = (w.cos(), w.sin());
        let (c2, s2) = ((2.0 * w).cos(), (2.0 * w).sin());
        let num =
            (self.b0 + self.b1 * c1 + self.b2 * c2).powi(2) + (self.b1 * s1 + self.b2 * s2).powi(2);
        let den =
            (1.0 + self.a1 * c1 + self.a2 * c2).powi(2) + (self.a1 * s1 + self.a2 * s2).powi(2);
        num / den
    }

    /// Second-order Butterworth (Q = 1/sqrt 2), RBJ cookbook.
    fn butterworth(hz: f64, sample_rate: f64, high_pass: bool) -> Self {
        let w0 = 2.0 * PI * hz / sample_rate;
        let (sin, cos) = w0.sin_cos();
        let alpha = sin / (2.0 * std::f64::consts::FRAC_1_SQRT_2);
        let a = [1.0 + alpha, -2.0 * cos, 1.0 - alpha];
        let b = if high_pass {
            [(1.0 + cos) / 2.0, -(1.0 + cos), (1.0 + cos) / 2.0]
        } else {
            [(1.0 - cos) / 2.0, 1.0 - cos, (1.0 - cos) / 2.0]
        };
        Self::new(b, a)
    }
}

#[derive(Debug, Clone)]
struct Biquad {
    c: Coefs,
    z1: Frame,
    z2: Frame,
}

impl Biquad {
    fn new(c: Coefs) -> Self {
        Self {
            c,
            z1: [0.0; 2],
            z2: [0.0; 2],
        }
    }

    #[inline]
    fn process(&mut self, x: Frame) -> Frame {
        let c = self.c;
        let mut y = [0.0; 2];
        for i in 0..2 {
            y[i] = c.b0 * x[i] + self.z1[i];
            self.z1[i] = c.b1 * x[i] - c.a1 * y[i] + self.z2[i];
            self.z2[i] = c.b2 * x[i] - c.a2 * y[i];
        }
        y
    }
}

/// BS.1770-4 K-weighting: a high shelf then a 38 Hz high-pass. The reference coefficients are
/// derived for any sample rate from the analog prototype, as libebur128 does.
#[derive(Debug, Clone)]
pub struct KWeight {
    shelf: Biquad,
    high_pass: Biquad,
}

impl KWeight {
    pub fn new(sample_rate: f64) -> Self {
        let (f0, gain_db, q) = (1681.974450955533, 3.999843853973347, 0.7071752369554196);
        let k = (PI * f0 / sample_rate).tan();
        let vh = 10f64.powf(gain_db / 20.0);
        let vb = vh.powf(0.4996667741545416);
        let a0 = 1.0 + k / q + k * k;
        let shelf = Coefs::new(
            [
                vh + vb * k / q + k * k,
                2.0 * (k * k - vh),
                vh - vb * k / q + k * k,
            ],
            [a0, 2.0 * (k * k - 1.0), 1.0 - k / q + k * k],
        );

        let (f0, q) = (38.13547087602444, 0.5003270373238773);
        let k = (PI * f0 / sample_rate).tan();
        let a0 = 1.0 + k / q + k * k;
        let high_pass = Coefs::new(
            [1.0, -2.0, 1.0],
            [a0, 2.0 * (k * k - 1.0), 1.0 - k / q + k * k],
        );
        Self {
            shelf: Biquad::new(shelf),
            high_pass: Biquad::new(high_pass),
        }
    }

    #[inline]
    pub fn process(&mut self, x: Frame) -> Frame {
        self.high_pass.process(self.shelf.process(x))
    }
}

/// One band: a Linkwitz-Riley 4th-order high-pass at the low edge and low-pass at the high
/// edge (two cascaded Butterworth sections each). Adjacent bands cross over at -6 dB and
/// their powers sum flat, so the bank splits the energy instead of double counting it.
#[derive(Debug, Clone)]
struct Band {
    high_pass: [Biquad; 2],
    low_pass: Option<[Biquad; 2]>,
    enabled: bool,
}

impl Band {
    fn new(lo: f64, hi: f64, sample_rate: f64) -> Self {
        let limit = sample_rate * MAX_EDGE_FRACTION;
        let hp = Coefs::butterworth(lo.min(limit), sample_rate, true);
        let lp = Coefs::butterworth(hi.min(limit), sample_rate, false);
        Self {
            high_pass: [Biquad::new(hp), Biquad::new(hp)],
            low_pass: (hi < limit).then(|| [Biquad::new(lp), Biquad::new(lp)]),
            enabled: lo < limit,
        }
    }

    #[inline]
    fn process(&mut self, x: Frame) -> Frame {
        if !self.enabled {
            return [0.0; 2];
        }
        let mut y = self.high_pass[0].process(x);
        y = self.high_pass[1].process(y);
        if let Some(lp) = &mut self.low_pass {
            y = lp[0].process(y);
            y = lp[1].process(y);
        }
        y
    }
}

impl KWeight {
    fn power(&self, hz: f64, sample_rate: f64) -> f64 {
        self.shelf.c.power(hz, sample_rate) * self.high_pass.c.power(hz, sample_rate)
    }
}

impl Band {
    fn power(&self, hz: f64, sample_rate: f64) -> f64 {
        if !self.enabled {
            return 0.0;
        }
        let mut p = self.high_pass[0].c.power(hz, sample_rate).powi(2);
        if let Some(lp) = &self.low_pass {
            p *= lp[0].c.power(hz, sample_rate).powi(2);
        }
        p
    }
}

/// What ideal pink noise (equal energy per octave, 20 Hz–20 kHz) does to each filter, from
/// the filters' own responses at this sample rate. A band's passed fraction already holds its
/// share of the octaves, so dividing the band's measured energy by it gives back the pink
/// energy P, the same in every band. Adding the K gain makes it read the same as LUFS.
#[derive(Debug, Clone)]
pub struct PinkCalibration {
    /// Fraction of pink energy each band passes, so pink of energy P gives a band `P * band`.
    pub band: [f64; BAND_COUNT],
    /// Mean |K|^2 over the pink spectrum.
    pub k: f64,
}

impl PinkCalibration {
    pub fn new(sample_rate: f64) -> Self {
        const POINTS: usize = 4000;
        let k_weight = KWeight::new(sample_rate);
        let bank = BandBank::new(sample_rate);
        let (lo, hi) = (BAND_EDGES[0].0, BAND_EDGES[BAND_COUNT - 1].1);
        let ratio = (hi / lo).ln();
        let mut band = [0.0; BAND_COUNT];
        let mut k = 0.0;
        for n in 0..POINTS {
            // Uniform in log frequency, which is what pink noise's 1/f density means.
            let f = lo * (ratio * (n as f64 + 0.5) / POINTS as f64).exp();
            k += k_weight.power(f, sample_rate) / POINTS as f64;
            for (b, sum) in bank.bands.iter().zip(band.iter_mut()) {
                *sum += b.power(f, sample_rate) / POINTS as f64;
            }
        }
        Self { band, k }
    }
}

#[derive(Debug, Clone)]
pub struct BandBank {
    bands: [Band; BAND_COUNT],
}

impl BandBank {
    pub fn new(sample_rate: f64) -> Self {
        Self {
            bands: std::array::from_fn(|i| {
                let (lo, hi) = BAND_EDGES[i];
                Band::new(lo, hi, sample_rate)
            }),
        }
    }

    #[inline]
    pub fn process(&mut self, x: Frame) -> [Frame; BAND_COUNT] {
        std::array::from_fn(|i| self.bands[i].process(x))
    }
}
