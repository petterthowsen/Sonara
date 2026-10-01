//! Signals and measurements for DSP and device tests (test builds only).
//!
//! Signals are mono `Vec<f32>` unless named otherwise; devices take interleaved stereo, so use
//! [`stereo`] / [`left`] / [`right`] around [`render`]. Phases are computed in f64 so the test
//! signal itself is accurate to well below −100 dB.

use crate::audio::devices::AudioDevice;
use realfft::RealFftPlanner;
use std::f64::consts::TAU;

// === Signals ===

pub fn sine(freq: f32, sample_rate: f32, frames: usize, amplitude: f32) -> Vec<f32> {
    (0..frames)
        .map(|n| amplitude * (TAU * freq as f64 * n as f64 / sample_rate as f64).sin() as f32)
        .collect()
}

/// A single 1.0 at frame 0, then silence.
pub fn impulse(frames: usize) -> Vec<f32> {
    let mut signal = vec![0.0; frames];
    if let Some(first) = signal.first_mut() {
        *first = 1.0;
    }
    signal
}

/// Deterministic white noise in −amplitude..amplitude.
pub fn white_noise(frames: usize, amplitude: f32, seed: u32) -> Vec<f32> {
    let mut state = seed.max(1);
    (0..frames)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            amplitude * (state as f32 / u32::MAX as f32 * 2.0 - 1.0)
        })
        .collect()
}

/// Deterministic pink noise (Paul Kellet's filter on white noise), peaking near `amplitude`.
pub fn pink_noise(frames: usize, amplitude: f32, seed: u32) -> Vec<f32> {
    let white = white_noise(frames, 1.0, seed);
    let mut b = [0.0f32; 7];
    let pink: Vec<f32> = white
        .iter()
        .map(|&w| {
            b[0] = 0.99886 * b[0] + w * 0.0555179;
            b[1] = 0.99332 * b[1] + w * 0.0750759;
            b[2] = 0.96900 * b[2] + w * 0.1538520;
            b[3] = 0.86650 * b[3] + w * 0.3104856;
            b[4] = 0.55000 * b[4] + w * 0.5329522;
            b[5] = -0.7616 * b[5] - w * 0.0168980;
            let out = b.iter().sum::<f32>() + w * 0.5362;
            b[6] = w * 0.115926;
            out
        })
        .collect();
    let peak = pink.iter().fold(0.0f32, |m, x| m.max(x.abs())).max(1e-9);
    pink.iter().map(|x| x * amplitude / peak).collect()
}

/// Exponential sine sweep from `f0` to `f1` Hz.
pub fn log_sweep(f0: f32, f1: f32, sample_rate: f32, frames: usize, amplitude: f32) -> Vec<f32> {
    let duration = frames as f64 / sample_rate as f64;
    let (f0, f1) = (f0 as f64, f1 as f64);
    let k = (f1 / f0).ln();
    (0..frames)
        .map(|n| {
            let t = n as f64 / sample_rate as f64;
            let phase = TAU * f0 * duration / k * ((t / duration * k).exp() - 1.0);
            amplitude * phase.sin() as f32
        })
        .collect()
}

// === Stereo ===

/// The same mono signal on both channels, interleaved.
pub fn stereo(mono: &[f32]) -> Vec<f32> {
    mono.iter().flat_map(|&x| [x, x]).collect()
}

pub fn interleave(left: &[f32], right: &[f32]) -> Vec<f32> {
    left.iter().zip(right).flat_map(|(&l, &r)| [l, r]).collect()
}

pub fn left(interleaved: &[f32]) -> Vec<f32> {
    interleaved.iter().step_by(2).copied().collect()
}

pub fn right(interleaved: &[f32]) -> Vec<f32> {
    interleaved.iter().skip(1).step_by(2).copied().collect()
}

// === Rendering ===

/// Run interleaved stereo `input` through `device`, cycling through `block_sizes` (frames) so
/// block-boundary bugs show up. Each size must be within what the device was prepared for.
pub fn render(device: &mut dyn AudioDevice, input: &[f32], block_sizes: &[usize]) -> Vec<f32> {
    let frames = input.len() / 2;
    let mut output = vec![0.0; input.len()];
    let (mut pos, mut i) = (0, 0);
    while pos < frames {
        let n = block_sizes[i % block_sizes.len()].min(frames - pos);
        device.process_block(
            &input[pos * 2..(pos + n) * 2],
            &mut output[pos * 2..(pos + n) * 2],
            n,
        );
        pos += n;
        i += 1;
    }
    output
}

// === Measurements ===

pub fn peak(signal: &[f32]) -> f32 {
    signal.iter().fold(0.0f32, |m, x| m.max(x.abs()))
}

pub fn rms(signal: &[f32]) -> f32 {
    if signal.is_empty() {
        return 0.0;
    }
    (signal.iter().map(|&x| x as f64 * x as f64).sum::<f64>() / signal.len() as f64).sqrt() as f32
}

pub fn to_db(amplitude: f32) -> f32 {
    20.0 * amplitude.max(1e-12).log10()
}

/// Amplitude of the `freq` component (correlation against a sine and cosine). Most accurate over
/// a whole number of cycles.
pub fn tone_amplitude(signal: &[f32], freq: f32, sample_rate: f32) -> f32 {
    let (mut re, mut im) = (0.0f64, 0.0f64);
    for (n, &x) in signal.iter().enumerate() {
        let phase = TAU * freq as f64 * n as f64 / sample_rate as f64;
        re += x as f64 * phase.cos();
        im += x as f64 * phase.sin();
    }
    (2.0 * (re * re + im * im).sqrt() / signal.len().max(1) as f64) as f32
}

/// Hann-windowed magnitude spectrum in dB (amplitude relative to full scale), one value per bin
/// of an FFT the length of `signal`.
pub fn spectrum_db(signal: &[f32]) -> Vec<f32> {
    let n = signal.len();
    let fft = RealFftPlanner::<f32>::new().plan_fft_forward(n);
    let window: Vec<f32> = (0..n)
        .map(|i| 0.5 * (1.0 - (TAU as f32 * i as f32 / (n - 1) as f32).cos()))
        .collect();
    let norm = 2.0 / window.iter().sum::<f32>();
    let mut input: Vec<f32> = signal.iter().zip(&window).map(|(x, w)| x * w).collect();
    let mut output = fft.make_output_vec();
    fft.process(&mut input, &mut output).unwrap();
    output.iter().map(|c| to_db(c.norm() * norm)).collect()
}

/// Reverberation time from an impulse response: Schroeder backward integration, a line through
/// the −5 dB and −25 dB points of the decay (T20), extrapolated to 60 dB. None if the response
/// never decays 25 dB.
pub fn schroeder_t60(response: &[f32], sample_rate: f32) -> Option<f32> {
    let mut energy: Vec<f64> = response.iter().map(|&x| x as f64 * x as f64).collect();
    for i in (0..energy.len().saturating_sub(1)).rev() {
        energy[i] += energy[i + 1];
    }
    let total = *energy.first()?;
    if total <= 0.0 {
        return None;
    }
    let crossing = |db: f64| {
        energy
            .iter()
            .position(|&e| 10.0 * (e / total).log10() <= db)
            .map(|i| i as f32 / sample_rate)
    };
    let (t5, t25) = (crossing(-5.0)?, crossing(-25.0)?);
    Some(3.0 * (t25 - t5))
}

/// Estimated fundamental of `signal` from upward zero crossings (linearly interpolated between
/// samples), using the first and last crossing so the estimate is not quantised by the window
/// length. 0.0 when there are fewer than two crossings.
pub fn instantaneous_freq(signal: &[f32], sample_rate: f32) -> f32 {
    let mut first = None;
    let mut last = 0.0f32;
    let mut count = 0usize;
    for i in 1..signal.len() {
        let (a, b) = (signal[i - 1], signal[i]);
        if a <= 0.0 && b > 0.0 {
            let frac = -a / (b - a);
            let t = i as f32 - 1.0 + frac;
            if first.is_none() {
                first = Some(t);
            }
            last = t;
            count += 1;
        }
    }
    match first {
        Some(f) if count >= 2 => (count - 1) as f32 * sample_rate / (last - f),
        _ => 0.0,
    }
}

/// Seconds until `signal`'s absolute level last exceeds `db` relative to its peak. 0.0 if it
/// never exceeds it.
pub fn time_to_db(signal: &[f32], db: f32, sample_rate: f32) -> f32 {
    let peak = peak(signal);
    if peak <= 0.0 {
        return 0.0;
    }
    let threshold = peak * 10f32.powf(db / 20.0);
    let mut last = None;
    for (i, &x) in signal.iter().enumerate() {
        if x.abs() > threshold {
            last = Some(i);
        }
    }
    match last {
        Some(i) => i as f32 / sample_rate,
        None => 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f32 = 48_000.0;

    #[test]
    fn tone_amplitude_reads_a_sine() {
        let signal = sine(1_000.0, SR, 48_000, 0.3);
        assert!((tone_amplitude(&signal, 1_000.0, SR) - 0.3).abs() < 1e-4);
        assert!(tone_amplitude(&signal, 3_000.0, SR) < 1e-4);
        assert!((to_db(rms(&signal)) - to_db(0.3 / 2f32.sqrt())).abs() < 0.01);
    }

    #[test]
    fn t60_of_an_exponential_decay() {
        // Noise decaying 60 dB in 1.5 s.
        let t60 = 1.5;
        let noise = white_noise(SR as usize * 3, 1.0, 7);
        let response: Vec<f32> = noise
            .iter()
            .enumerate()
            .map(|(n, x)| x * 10f32.powf(-3.0 * n as f32 / SR / t60))
            .collect();
        let measured = schroeder_t60(&response, SR).unwrap();
        assert!((measured - t60).abs() / t60 < 0.05, "{measured} s");
    }

    #[test]
    fn spectrum_peaks_at_the_tone() {
        let signal = sine(750.0, SR, 4_096, 0.5);
        let bins = spectrum_db(&signal);
        let peak_bin = (0..bins.len())
            .max_by(|&a, &b| bins[a].total_cmp(&bins[b]))
            .unwrap();
        assert_eq!(peak_bin, (750.0 * 4_096.0 / SR).round() as usize);
        assert!(peak(&pink_noise(10_000, 0.5, 3)) <= 0.5 + 1e-6);
        assert_eq!(log_sweep(20.0, 20_000.0, SR, 100, 1.0).len(), 100);
    }

    #[test]
    fn instantaneous_freq_reads_a_sine() {
        let signal = sine(100.0, SR, (SR * 0.5) as usize, 1.0);
        let f = instantaneous_freq(&signal, SR);
        assert!((f - 100.0).abs() / 100.0 < 0.01, "{f}");
        assert_eq!(instantaneous_freq(&[0.5; 100], SR), 0.0);
        assert_eq!(instantaneous_freq(&[], SR), 0.0);
    }

    #[test]
    fn time_to_db_finds_the_decay_point() {
        let t60 = 1.5;
        let signal: Vec<f32> = (0..(SR * 2.0) as usize)
            .map(|n| 10f32.powf(-3.0 * n as f32 / SR / t60))
            .collect();
        // -6 dB relative to the peak (1.0) is reached at about 0.1 * t60.
        let t = time_to_db(&signal, -6.0, SR);
        let want = 0.1 * t60;
        assert!((t - want).abs() / want < 0.02, "{t} vs {want}");
        let constant = vec![1.0; 100];
        assert!((time_to_db(&constant, -6.0, SR) - 99.0 / SR).abs() < 1e-6);
        assert_eq!(time_to_db(&[0.0; 10], -6.0, SR), 0.0);
    }
}
