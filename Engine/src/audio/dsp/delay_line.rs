//! A mono ring buffer with fractional reads, for delays, chorus voices and reverb lines.
//!
//! - Sized once in [`DelayLine::prepare`] (command thread); `read_*`/`push` never allocate.
//! - The length is a power of two so wrapping is a mask.
//! - Read, then push: `read_*(d)` returns the input from `d` samples before the next `push`, so
//!   `d = 1` is the most recently pushed sample. A feedback delay reads, mixes and pushes once
//!   per sample.

/// Shortest delay [`DelayLine::read_hermite`] allows: it needs one newer neighbour.
pub const MIN_HERMITE_DELAY: f32 = 2.0;

#[derive(Clone, Debug, Default)]
pub struct DelayLine {
    buffer: Vec<f32>,
    mask: usize,
    /// Index the next `push` writes.
    write: usize,
}

impl DelayLine {
    /// An empty line; call `prepare` before use.
    pub fn new() -> Self {
        Self::default()
    }

    /// Allocate for delays up to `max_samples` (plus interpolation headroom) and clear.
    /// Command thread only.
    pub fn prepare(&mut self, max_samples: usize) {
        let len = (max_samples + 4).next_power_of_two();
        self.buffer = vec![0.0; len];
        self.mask = len - 1;
        self.write = 0;
    }

    /// Allocate for `max_seconds` at `sample_rate`.
    pub fn prepare_seconds(&mut self, max_seconds: f32, sample_rate: f32) {
        self.prepare((max_seconds * sample_rate).ceil() as usize);
    }

    /// Longest delay a read can use, in samples.
    pub fn max_delay(&self) -> f32 {
        self.buffer.len().saturating_sub(4) as f32
    }

    pub fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.write = 0;
    }

    #[inline]
    pub fn push(&mut self, x: f32) {
        self.buffer[self.write] = x;
        self.write = (self.write + 1) & self.mask;
    }

    /// The sample pushed `ago` pushes back (1 = the latest).
    #[inline]
    fn tap(&self, ago: usize) -> f32 {
        self.buffer[self.write.wrapping_sub(ago) & self.mask]
    }

    /// Whole-sample read, `delay` clamped to `1..=max_delay`.
    #[inline]
    pub fn read(&self, delay: usize) -> f32 {
        self.tap(delay.clamp(1, self.max_delay() as usize))
    }

    /// Linear interpolation, `delay` clamped to `1..=max_delay`.
    #[inline]
    pub fn read_linear(&self, delay: f32) -> f32 {
        let d = delay.clamp(1.0, self.max_delay());
        let i = d as usize;
        let t = d - i as f32;
        let a = self.tap(i);
        a + (self.tap(i + 1) - a) * t
    }

    /// 4-point Hermite interpolation, `delay` clamped to `MIN_HERMITE_DELAY..=max_delay`.
    /// Smoother than linear for slowly swept delays (chorus, tape).
    #[inline]
    pub fn read_hermite(&self, delay: f32) -> f32 {
        let d = delay.clamp(MIN_HERMITE_DELAY, self.max_delay());
        let i = d as usize;
        let t = d - i as f32;
        let xm1 = self.tap(i - 1);
        let x0 = self.tap(i);
        let x1 = self.tap(i + 1);
        let x2 = self.tap(i + 2);
        let c1 = 0.5 * (x1 - xm1);
        let c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
        ((c3 * t + c2) * t + c1) * t + x0
    }

    /// First-order all-pass (Thiran) interpolation, `delay` clamped to `1.5..=max_delay - 1`.
    /// Its magnitude is flat at every fraction, so a read inside a feedback loop loses nothing
    /// (linear and Hermite reads low-pass at fractional delays, which builds up over hundreds of
    /// passes). Suits fixed or slowly moving delays. `state` is the previous output: one per read
    /// position, read once per sample in order, zeroed when the line is cleared.
    #[inline]
    pub fn read_allpass(&self, delay: f32, state: &mut f32) -> f32 {
        let d = delay.clamp(1.5, self.max_delay() - 1.0);
        // The fraction lies in [0.5, 1.5), which keeps the coefficient in (−1/5, 1/3]: well away
        // from the pole near Nyquist that a fraction near 0 brings.
        let i = (d - 0.5) as usize;
        let frac = d - i as f32;
        let eta = (1.0 - frac) / (1.0 + frac);
        let y = eta * self.tap(i) + self.tap(i + 1) - eta * *state;
        *state = y;
        y
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_delay_is_exact() {
        let mut line = DelayLine::new();
        line.prepare(100);
        let mut out = Vec::new();
        for n in 0..200 {
            out.push(line.read(10));
            line.push(if n == 5 { 1.0 } else { 0.0 });
        }
        assert_eq!(out.iter().position(|&x| x == 1.0), Some(15));
        assert_eq!(out.iter().filter(|&&x| x != 0.0).count(), 1);
    }

    #[test]
    fn fractional_reads_follow_a_sine() {
        // Signals in f64: an f32 phase this large is itself off by about 1e-5.
        let sine = |t: f64| (std::f64::consts::TAU * 500.0 * t / 48_000.0).sin() as f32;
        let delay = 37.4;
        let mut line = DelayLine::new();
        line.prepare(256);
        let (mut err_lin, mut err_herm) = (0.0f32, 0.0f32);
        for n in 0..2000 {
            let (lin, herm) = (line.read_linear(delay), line.read_hermite(delay));
            if n > 100 {
                let expected = sine(n as f64 - delay as f64);
                err_lin = err_lin.max((lin - expected).abs());
                err_herm = err_herm.max((herm - expected).abs());
            }
            line.push(sine(n as f64));
        }
        assert!(err_lin < 1e-3, "linear error {err_lin}");
        assert!(err_herm < 1e-5, "hermite error {err_herm}");
    }

    #[test]
    fn allpass_reads_keep_the_level_and_the_delay() {
        // Returns (level dB, correlation with the exactly delayed sine) for an all-pass read, and
        // the linear read's level.
        let run = |freq: f64| {
            let sine = |t: f64| (std::f64::consts::TAU * freq * t / 48_000.0).sin() as f32;
            let delay = 20.5;
            let mut line = DelayLine::new();
            line.prepare(256);
            let mut state = 0.0;
            let (mut e_in, mut e_ap, mut e_lin, mut dot) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
            for n in 0..4000 {
                let ap = line.read_allpass(delay, &mut state);
                let lin = line.read_linear(delay);
                if n > 200 {
                    let expected = sine(n as f64 - delay as f64);
                    e_in += expected * expected;
                    e_ap += ap * ap;
                    e_lin += lin * lin;
                    dot += ap * expected;
                }
                line.push(sine(n as f64));
            }
            let db = |e: f32| 10.0 * (e / e_in).log10();
            (db(e_ap), dot / e_in, db(e_lin))
        };
        // 15 kHz at fraction 0.5: linear interpolation loses about 5 dB, all-pass nothing.
        let (ap_db, _, lin_db) = run(15_000.0);
        assert!(ap_db.abs() < 0.05, "all-pass level {ap_db} dB");
        assert!(lin_db < -4.0, "linear level {lin_db} dB");
        // The delay is exact at low frequencies.
        let (_, corr, _) = run(500.0);
        assert!(corr > 0.999, "all-pass delay off: correlation {corr}");
    }

    #[test]
    fn prepare_sizes_for_the_longest_delay_and_clamps_beyond() {
        let mut line = DelayLine::new();
        line.prepare_seconds(5.0, 192_000.0);
        assert!(line.max_delay() >= 960_000.0);
        line.push(1.0);
        // Out-of-range delays clamp rather than panic.
        assert_eq!(line.read(0), 1.0);
        let _ = line.read_hermite(1e9);
        line.clear();
        assert_eq!(line.read(1), 0.0);
    }
}
