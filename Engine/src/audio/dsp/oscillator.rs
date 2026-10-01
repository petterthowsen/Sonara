use once_cell::sync::Lazy;

const SINE_TABLE_SIZE: usize = 65536; // 64k samples for high quality

/// Sine lookup table for fast sine generation
static SINE_TABLE: Lazy<Vec<f32>> = Lazy::new(|| {
    let mut table = Vec::with_capacity(SINE_TABLE_SIZE);
    for i in 0..SINE_TABLE_SIZE {
        let phase = (i as f32 / SINE_TABLE_SIZE as f32) * 2.0 * std::f32::consts::PI;
        table.push(phase.sin());
    }
    table
});

#[inline]
pub fn fast_sin(phase: f64) -> f32 {
    let idx = ((phase.fract() * SINE_TABLE_SIZE as f64) as usize) % SINE_TABLE_SIZE;
    SINE_TABLE[idx]
}

/// Waveform types supported by the oscillator
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Waveform {
    Sine = 0,
    Square = 1,
    Saw = 2,
    Triangle = 3,
}

impl From<u8> for Waveform {
    fn from(value: u8) -> Self {
        match value {
            0 => Waveform::Sine,
            1 => Waveform::Square,
            2 => Waveform::Saw,
            3 => Waveform::Triangle,
            _ => Waveform::Sine,
        }
    }
}

/// Four-point polynomial band-limited step residual: the cubic B-spline smoothed step minus the
/// ideal step, scaled to a unit-height (0..1 step -> 2.0 jump) convention so it can be added to
/// a naive waveform per discontinuity. `t` is the phase (0..1), `dt` the phase increment.
/// Non-zero only within two samples either side of a discontinuity at phase 0.
#[inline]
fn poly_blep(t: f64, dt: f64) -> f64 {
    // `a` is the distance from the edge in samples; `after` says which side of it we are on.
    let (a, after) = if t < 2.0 * dt {
        (t / dt, true)
    } else if t > 1.0 - 2.0 * dt {
        ((1.0 - t) / dt, false)
    } else {
        return 0.0;
    };
    let g = |a: f64| 2.0 * a / 3.0 - a * a * a / 3.0 + a * a * a * a / 8.0;
    let quartic = |a: f64| {
        let r = 2.0 - a;
        r * r * r * r / 24.0
    };
    let residual = match (after, a < 1.0) {
        (true, true) => g(a) - 0.5,
        (true, false) => -quartic(a),
        (false, true) => 0.5 - g(a),
        (false, false) => quartic(a),
    };
    2.0 * residual
}

/// Four-point band-limited ramp residual for a slope discontinuity at phase 0 (smoothed ramp
/// minus ideal ramp). Multiply by `dt` and the slope change per unit phase.
#[inline]
fn poly_blamp(t: f64, dt: f64) -> f64 {
    let a = if t < 2.0 * dt {
        t / dt
    } else if t > 1.0 - 2.0 * dt {
        (1.0 - t) / dt
    } else {
        return 0.0;
    };
    if a < 1.0 {
        let a2 = a * a;
        7.0 / 30.0 - a / 2.0 + a2 / 3.0 - a2 * a2 / 12.0 + a2 * a2 * a / 40.0
    } else {
        let r = 2.0 - a;
        r * r * r * r * r / 120.0
    }
}

/// Pulse width limits: keeps both edges more than a couple of samples apart at sane pitches.
pub const PULSE_WIDTH_MIN: f64 = 0.05;
pub const PULSE_WIDTH_MAX: f64 = 0.95;

/// High-performance oscillator using a phase accumulator.
///
/// - Sine uses a lookup table.
/// - Saw, pulse (`Waveform::Square`, variable width) and triangle are band-limited with
///   PolyBLEP / PolyBLAMP, so high notes don't fold back as aliasing.
pub struct Oscillator {
    pub phase: f64,
    pub phase_increment: f64,
    /// Pulse width (fraction of the cycle spent high), used by waveform 1.
    pub pulse_width: f64,
    /// Added to `phase_increment` every sample inside `process_block_ramped`.
    increment_step: f64,
}

impl Oscillator {
    pub fn new() -> Self {
        // Build the shared sine table here (devices are created off the audio thread) rather
        // than on first use, which would allocate and compute 64k sines inside the callback.
        Lazy::force(&SINE_TABLE);
        Self {
            phase: 0.0,
            phase_increment: 0.0,
            pulse_width: 0.5,
            increment_step: 0.0,
        }
    }

    /// Set the oscillator frequency in Hz
    pub fn set_frequency(&mut self, frequency: f64, sample_rate: f64) {
        self.phase_increment = frequency / sample_rate;
    }

    /// Set the pulse width (clamped to 5–95 %).
    pub fn set_pulse_width(&mut self, width: f64) {
        self.pulse_width = width.clamp(PULSE_WIDTH_MIN, PULSE_WIDTH_MAX);
    }

    /// Reset the oscillator phase to 0
    pub fn reset(&mut self) {
        self.phase = 0.0;
    }

    /// Process a block of samples with the given waveform
    pub fn process_block(&mut self, waveform: u8, output: &mut [f32], frames: usize) {
        self.process::<false>(waveform, output, frames);
    }

    /// `RAMP` adds `increment_step` to the increment every sample; the steady path skips it.
    fn process<const RAMP: bool>(&mut self, waveform: u8, output: &mut [f32], frames: usize) {
        match waveform {
            0 => self.process_sine::<RAMP>(output, frames),
            1 => self.process_pulse::<RAMP>(output, frames),
            2 => self.process_saw::<RAMP>(output, frames),
            3 => self.process_triangle::<RAMP>(output, frames),
            _ => self.process_sine::<RAMP>(output, frames),
        }
    }

    /// Like `process_block`, but the frequency glides linearly from the current increment to
    /// `target_increment` over the block (so pitch modulation doesn't step), ending exactly on it.
    pub fn process_block_ramped(
        &mut self,
        waveform: u8,
        output: &mut [f32],
        frames: usize,
        target_increment: f64,
    ) {
        if frames > 0 && target_increment != self.phase_increment {
            self.increment_step = (target_increment - self.phase_increment) / frames as f64;
            self.process::<true>(waveform, output, frames);
        } else {
            self.process_block(waveform, output, frames);
        }
        self.phase_increment = target_increment;
    }

    #[inline]
    fn advance<const RAMP: bool>(&mut self) {
        self.phase += self.phase_increment;
        if RAMP {
            self.phase_increment += self.increment_step;
        }
        // Fast wrapping using branchless cast (no branch!)
        self.phase -= (self.phase >= 1.0) as i32 as f64;
    }

    fn process_sine<const RAMP: bool>(&mut self, output: &mut [f32], frames: usize) {
        for out in output[..frames].iter_mut() {
            *out = fast_sin(self.phase);
            self.advance::<RAMP>();
        }
    }

    fn process_pulse<const RAMP: bool>(&mut self, output: &mut [f32], frames: usize) {
        let pw = self.pulse_width;
        for out in output[..frames].iter_mut() {
            let dt = self.phase_increment;
            let p = self.phase;
            let mut v = if p < pw { 1.0 } else { -1.0 };
            v += poly_blep(p, dt);
            v -= poly_blep((p - pw).rem_euclid(1.0), dt);
            *out = v as f32;
            self.advance::<RAMP>();
        }
    }

    fn process_saw<const RAMP: bool>(&mut self, output: &mut [f32], frames: usize) {
        for out in output[..frames].iter_mut() {
            let dt = self.phase_increment;
            let p = self.phase;
            *out = (p * 2.0 - 1.0 - poly_blep(p, dt)) as f32;
            self.advance::<RAMP>();
        }
    }

    fn process_triangle<const RAMP: bool>(&mut self, output: &mut [f32], frames: usize) {
        for out in output[..frames].iter_mut() {
            let dt = self.phase_increment;
            let p = self.phase;
            let mut v = if p < 0.5 {
                p * 4.0 - 1.0
            } else {
                3.0 - p * 4.0
            };
            // Slope flips from -4 to +4 at phase 0 and from +4 to -4 at phase 0.5.
            v += 8.0 * dt * poly_blamp(p, dt);
            v -= 8.0 * dt * poly_blamp((p + 0.5).rem_euclid(1.0), dt);
            *out = v as f32;
            self.advance::<RAMP>();
        }
    }
}

impl Default for Oscillator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    const SR: f64 = 48_000.0;
    const N: usize = 16384;
    const AUDIBLE_HZ: f64 = 16_000.0;

    fn render(waveform: u8, freq: f64) -> Vec<f32> {
        let mut osc = Oscillator::new();
        osc.set_frequency(freq, SR);
        let mut out = vec![0.0; N];
        osc.process_block(waveform, &mut out, N);
        out
    }

    /// Naive (aliasing) saw for comparison.
    fn naive_saw(freq: f64) -> Vec<f32> {
        let dt = freq / SR;
        (0..N)
            .map(|i| ((i as f64 * dt).fract() * 2.0 - 1.0) as f32)
            .collect()
    }

    fn naive_pulse(freq: f64) -> Vec<f32> {
        let dt = freq / SR;
        (0..N)
            .map(|i| {
                if (i as f64 * dt).fract() < 0.5 {
                    1.0
                } else {
                    -1.0
                }
            })
            .collect()
    }

    /// In-place radix-2 FFT.
    fn fft(re: &mut [f64], im: &mut [f64]) {
        let n = re.len();
        let mut j = 0;
        for i in 1..n {
            let mut bit = n >> 1;
            while j & bit != 0 {
                j ^= bit;
                bit >>= 1;
            }
            j |= bit;
            if i < j {
                re.swap(i, j);
                im.swap(i, j);
            }
        }
        let mut len = 2;
        while len <= n {
            let ang = -2.0 * PI / len as f64;
            for start in (0..n).step_by(len) {
                for k in 0..len / 2 {
                    let (wr, wi) = ((ang * k as f64).cos(), (ang * k as f64).sin());
                    let (a, b) = (start + k, start + k + len / 2);
                    let (tr, ti) = (re[b] * wr - im[b] * wi, re[b] * wi + im[b] * wr);
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
            }
            len <<= 1;
        }
    }

    /// Energy below `max_hz` that is not within a few bins of a true harmonic of `freq`
    /// (i.e. aliasing). Content above ~16 kHz is barely audible, so tests measure below that.
    fn alias_energy(signal: &[f32], freq: f64, max_hz: f64) -> f64 {
        let n = signal.len();
        let mut re: Vec<f64> = signal
            .iter()
            .enumerate()
            .map(|(i, &s)| {
                // Blackman-Harris window: leakage far below the aliasing we measure.
                let x = 2.0 * PI * i as f64 / n as f64;
                let w = 0.35875 - 0.48829 * x.cos() + 0.14128 * (2.0 * x).cos()
                    - 0.01168 * (3.0 * x).cos();
                s as f64 * w
            })
            .collect();
        let mut im = vec![0.0; n];
        fft(&mut re, &mut im);
        let bin_hz = SR / n as f64;
        let mut energy = 0.0;
        for k in 1..n / 2 {
            let hz = k as f64 * bin_hz;
            if hz > max_hz {
                break;
            }
            let harmonic = (hz / freq).round();
            let near_harmonic = harmonic >= 1.0 && (hz - harmonic * freq).abs() < 6.0 * bin_hz;
            if !near_harmonic {
                energy += re[k] * re[k] + im[k] * im[k];
            }
        }
        energy
    }

    fn db_ratio(a: f64, b: f64) -> f64 {
        10.0 * (a / b).log10()
    }

    #[test]
    fn saw_aliasing_is_at_least_40db_below_naive_at_c7() {
        let freq = 2093.0;
        let naive = alias_energy(&naive_saw(freq), freq, AUDIBLE_HZ);
        let blep = alias_energy(&render(2, freq), freq, AUDIBLE_HZ);
        let gain = db_ratio(naive, blep);
        assert!(
            gain >= 40.0,
            "saw aliasing (<16 kHz) only {gain:.1} dB below naive"
        );
    }

    #[test]
    fn pulse_aliasing_is_at_least_40db_below_naive_at_c7() {
        let freq = 2093.0;
        let naive = alias_energy(&naive_pulse(freq), freq, AUDIBLE_HZ);
        let blep = alias_energy(&render(1, freq), freq, AUDIBLE_HZ);
        let gain = db_ratio(naive, blep);
        assert!(
            gain >= 40.0,
            "pulse aliasing (<16 kHz) only {gain:.1} dB below naive"
        );
    }

    #[test]
    fn triangle_stays_in_range_and_has_no_alias_burst() {
        let freq = 2093.0;
        let tri = render(3, freq);
        assert!(tri.iter().all(|s| s.abs() <= 1.05));
        // A naive triangle already aliases very little; just make sure the correction
        // doesn't add any energy of its own.
        let naive: Vec<f32> = (0..N)
            .map(|i| {
                let p = (i as f64 * freq / SR).fract();
                (if p < 0.5 {
                    p * 4.0 - 1.0
                } else {
                    3.0 - p * 4.0
                }) as f32
            })
            .collect();
        assert!(
            alias_energy(&tri, freq, AUDIBLE_HZ) <= alias_energy(&naive, freq, AUDIBLE_HZ) * 1.01
        );
    }

    #[test]
    fn saw_has_expected_level_and_no_dc() {
        let saw = render(2, 220.0);
        let mean: f32 = saw.iter().sum::<f32>() / N as f32;
        let peak = saw.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(mean.abs() < 0.01, "dc {mean}");
        assert!(peak > 0.95 && peak < 1.1, "peak {peak}");
    }

    #[test]
    fn pulse_width_changes_duty_cycle() {
        let mut osc = Oscillator::new();
        osc.set_frequency(100.0, SR);
        osc.set_pulse_width(0.25);
        let mut out = vec![0.0; 48_000];
        osc.process_block(1, &mut out, 48_000);
        let high = out.iter().filter(|&&s| s > 0.0).count() as f64 / out.len() as f64;
        assert!((high - 0.25).abs() < 0.01, "duty {high}");
    }

    #[test]
    fn ramped_block_glides_the_increment_and_lands_on_target() {
        let mut ramped = Oscillator::new();
        ramped.phase_increment = 0.01;
        let mut out = [0.0f32; 32];
        ramped.process_block_ramped(2, &mut out, 32, 0.02);
        assert_eq!(ramped.phase_increment, 0.02);
        // The phase advanced by the ramp's average increment, not the start or end one.
        let expected: f64 = (0..32).map(|i| 0.01 + 0.01 * i as f64 / 32.0).sum();
        assert!(
            (ramped.phase - expected.fract()).abs() < 1e-9,
            "{}",
            ramped.phase
        );
        // Afterwards it runs steadily at the target.
        let before = ramped.phase;
        ramped.process_block(2, &mut out, 1);
        assert!((ramped.phase - (before + 0.02).fract()).abs() < 1e-12);
    }
}
