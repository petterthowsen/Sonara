//! Shared drum layers (spec 013, Phase 1): the click/snap transient and the mono drive stage.
//!
//! [`ClickLayer`] is the short transient a drum uses for its attack: white noise through a
//! band-pass, or a brief high sine. The Kick owns it here; the Snare's Snap and the Clap's
//! bursts reuse it in later phases, so it has no Kick parameters of its own.
//!
//! [`DriveStage`] is a mono saturation stage: `fast_tanh` at 2× oversampling while drive > 0,
//! and bit-exact clean at 0 dB. Both are allocation-free and audio-thread safe: every buffer is
//! sized in `new`.

use crate::audio::dsp::oversampler::Oversampler;
use crate::audio::dsp::saturate::{drive_params, fast_tanh};
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{
    FilterMode, OneShotEnvelope, Svf, SvfCoefs, SweepOsc, SweepShape, WhiteNoise,
};

/// Resonance of the click's band-pass. Fixed: the click has no Q control.
const CLICK_RESONANCE: f32 = 0.4;
/// Click decay bounds (1–10 ms). Shorter at a higher tone; the caller passes the value.
const CLICK_MIN_DECAY: f32 = 0.001;
const CLICK_MAX_DECAY: f32 = 0.010;

/// The click transient shape.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClickType {
    /// White noise through a band-pass at the tone.
    Noise,
    /// A short sine at the tone.
    Tick,
}

/// One-shot click/snap transient: white noise → band-pass SVF (`Noise`) or a short high sine
/// (`Tick`), gated by a 1–10 ms decay envelope.
pub struct ClickLayer {
    kind: ClickType,
    sample_rate: f32,
    noise: WhiteNoise,
    filter: Svf,
    coefs: SvfCoefs,
    comp: f32,
    resonance: f32,
    tick: SweepOsc,
    env: OneShotEnvelope,
    tone_hz: f32,
    decay_s: f32,
}

impl ClickLayer {
    /// A silent click layer at `sample_rate`, `seed`ing its noise source.
    pub fn new(sample_rate: f32, seed: u32) -> Self {
        let sample_rate = sample_rate.max(1.0);
        let mut env = OneShotEnvelope::new(sample_rate);
        env.set_curve(0.0);
        env.set_decay(CLICK_MAX_DECAY);
        let mut layer = Self {
            kind: ClickType::Noise,
            sample_rate,
            noise: WhiteNoise::new(seed),
            filter: Svf::new(),
            coefs: SvfCoefs::default(),
            comp: 0.0,
            resonance: CLICK_RESONANCE,
            tick: SweepOsc::new(),
            env,
            tone_hz: 3_000.0,
            decay_s: CLICK_MAX_DECAY,
        };
        layer.update_filter();
        layer
    }

    /// Re-derive the filter for a new sample rate.
    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(1.0);
        self.env.set_sample_rate(self.sample_rate);
        self.update_filter();
    }

    /// Choose the transient shape.
    pub fn set_type(&mut self, kind: ClickType) {
        self.kind = kind;
    }

    /// Noise: SVF band-pass center Hz. Tick: sine Hz. Both use `decay_s` (clamped to 1–10 ms).
    pub fn set_tone(&mut self, tone_hz: f32, decay_s: f32) {
        self.tone_hz = tone_hz.max(1.0);
        self.decay_s = decay_s.clamp(CLICK_MIN_DECAY, CLICK_MAX_DECAY);
        self.env.set_decay(self.decay_s);
        self.update_filter();
    }

    /// Restart the transient from the current envelope level (no click on a retrigger).
    pub fn trigger(&mut self) {
        self.filter.reset();
        self.tick.reset();
        self.env.trigger();
    }

    /// Add the click into `out` at `level`; must not clear it.
    pub fn render(&mut self, out: &mut [f32], level: f32) {
        if !self.env.is_active() {
            return;
        }
        for sample in out.iter_mut() {
            let env = self.env.process_sample();
            let x = match self.kind {
                ClickType::Noise => self.filter.process(
                    self.noise.next(),
                    FilterMode::Bp12,
                    &self.coefs,
                    self.comp,
                    self.resonance,
                ),
                ClickType::Tick => self
                    .tick
                    .next(SweepShape::Sine, self.tone_hz, self.sample_rate),
            };
            *sample += x * env * level;
        }
    }

    /// Whether the transient is still sounding.
    pub fn is_active(&self) -> bool {
        self.env.is_active()
    }

    /// Silence the layer.
    pub fn reset(&mut self) {
        self.filter.reset();
        self.tick.reset();
        self.env.reset();
    }

    fn update_filter(&mut self) {
        let k = resonance_to_k(self.resonance, FilterMode::Bp12);
        self.coefs = SvfCoefs::new(
            cutoff_to_g(self.tone_hz, self.sample_rate),
            k,
            FilterMode::Bp12,
        );
        self.comp = compensation_coef(self.tone_hz, self.sample_rate);
    }
}

/// Frames a [`DriveStage`] oversamples at once. The oversampler's IIR is streaming, so the
/// chunking is output-neutral and any block length works.
const DRIVE_CHUNK: usize = 32;

/// Mono drive stage: `fast_tanh` at 2× oversampling when drive > 0, exactly clean at 0 dB.
pub struct DriveStage {
    oversampler: Oversampler,
    drive_db: f32,
    gain: f32,
    blend: f32,
    /// Interleaved stereo input/output for the oversampler (the mono signal duplicated).
    input: Vec<f32>,
    output: Vec<f32>,
}

impl DriveStage {
    /// Preallocates; safe to call off the audio thread.
    pub fn new() -> Self {
        let mut oversampler = Oversampler::new();
        oversampler.prepare(DRIVE_CHUNK);
        oversampler.set_factor(1);
        Self {
            oversampler,
            drive_db: 0.0,
            gain: 1.0,
            blend: 0.0,
            input: vec![0.0; DRIVE_CHUNK * 2],
            output: vec![0.0; DRIVE_CHUNK * 2],
        }
    }

    /// 0 => 1×/clean, >0 => 2× oversampled. Command thread (the oversampler resets on a change).
    pub fn set_drive_db(&mut self, db: f32) {
        self.drive_db = db.max(0.0);
        let (gain, blend) = drive_params(self.drive_db);
        self.gain = gain;
        self.blend = blend;
        self.oversampler
            .set_factor(if self.drive_db > 0.0 { 2 } else { 1 });
    }

    /// Process `samples` in place, mono, any length, never allocating. Exactly clean at 0 dB.
    pub fn process(&mut self, samples: &mut [f32]) {
        if self.drive_db <= 0.0 {
            return;
        }
        let (gain, blend) = (self.gain, self.blend);
        for chunk in samples.chunks_mut(DRIVE_CHUNK) {
            let n = chunk.len();
            for (i, &x) in chunk.iter().enumerate() {
                self.input[i * 2] = x;
                self.input[i * 2 + 1] = x;
            }
            let frames = n;
            self.oversampler.process(
                &self.input[..frames * 2],
                &mut self.output[..frames * 2],
                frames,
                |buffer| {
                    for s in buffer.iter_mut() {
                        let x = *s;
                        *s = x + blend * (fast_tanh(x * gain) - x);
                    }
                },
            );
            for i in 0..n {
                chunk[i] = self.output[i * 2];
            }
        }
    }

    /// Clear the oversampler state.
    pub fn reset(&mut self) {
        self.oversampler.reset();
    }
}

impl Default for DriveStage {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f32 = 48_000.0;

    fn peak(signal: &[f32]) -> f32 {
        signal.iter().fold(0.0f32, |m, x| m.max(x.abs()))
    }

    /// A click's peak lands in the first millisecond, and the layer goes idle after the decay.
    #[test]
    fn click_peaks_within_the_first_millisecond() {
        let mut click = ClickLayer::new(SR, 1);
        click.set_type(ClickType::Noise);
        click.set_tone(3_000.0, 0.006);
        click.trigger();
        let mut buf = vec![0.0f32; 4_800];
        click.render(&mut buf, 1.0);

        let peak_index = buf
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.abs().total_cmp(&b.1.abs()))
            .map(|(i, _)| i)
            .unwrap();
        assert!(
            peak_index < (0.001 * SR) as usize,
            "peak at sample {peak_index}"
        );
        assert!(peak(&buf) > 0.05, "click is audible: {}", peak(&buf));

        // The decay is short: another 100 ms of rendering leaves it idle and silent.
        let mut tail = vec![0.0f32; 4_800];
        click.render(&mut tail, 1.0);
        assert!(!click.is_active());
        assert!(peak(&tail) < 1e-3, "tail is silent: {}", peak(&tail));
    }

    #[test]
    fn tick_is_a_short_high_sine() {
        let mut click = ClickLayer::new(SR, 2);
        click.set_type(ClickType::Tick);
        click.set_tone(6_000.0, 0.002);
        click.trigger();
        let mut buf = vec![0.0f32; 4_800];
        click.render(&mut buf, 1.0);
        assert!(peak(&buf) > 0.4, "tick is audible: {}", peak(&buf));
        let mut tail = vec![0.0f32; 4_800];
        click.render(&mut tail, 1.0);
        assert!(!click.is_active());
        assert!(peak(&tail) < 1e-3);
    }

    /// 0 dB leaves the samples bit-exact; 24 dB stays finite and bounded.
    ///
    /// `fast_tanh` bounds the signal to ±1 at the high rate. The polyphase half-band
    /// down-sampler adds a small, frequency-dependent transient overshoot (measured ~0.2 % here),
    /// and the host's own `soft_clip` stage removes any excess in the final output, so the check
    /// only requires "no runaway" — a few percent, not exact unity.
    #[test]
    fn drive_is_clean_at_zero_and_bounded_at_full() {
        let input: Vec<f32> = (0..512)
            .map(|i| (i as f32 * std::f32::consts::TAU * 100.0 / SR).sin())
            .collect();

        let mut stage = DriveStage::new();
        stage.set_drive_db(0.0);
        let mut clean = input.clone();
        stage.process(&mut clean);
        assert_eq!(clean, input, "0 dB is bit-exact");

        stage.set_drive_db(24.0);
        let mut driven = input.clone();
        stage.process(&mut driven);
        assert!(driven.iter().all(|x| x.is_finite()));
        let peak = peak(&driven);
        assert!(peak <= 1.01, "peak {peak}");
        assert!(peak > 0.9, "24 dB saturates: {peak}");
    }

    /// Any block length works: the same signal in one call or many is identical.
    #[test]
    fn drive_is_block_size_independent() {
        let input: Vec<f32> = (0..300).map(|i| (i as f32 * 0.11).sin() * 0.7).collect();
        let mut whole = DriveStage::new();
        whole.set_drive_db(18.0);
        let mut a = input.clone();
        whole.process(&mut a);

        let mut split = DriveStage::new();
        split.set_drive_db(18.0);
        let mut b = input.clone();
        for chunk in b.chunks_mut(7) {
            split.process(chunk);
        }
        assert_eq!(a, b);
    }
}
