//! Cymbal (`sonara.builtin.cymbal`, spec 056, Phase 4): a synthetic crash by default, with
//! splash, ride and china reachable by parameters.
//!
//! The metal source is the Hat's six 808 pulse oscillators ([`RATIOS`] × the Tune transposition),
//! optionally ring-modulated in pairs (**Trash**) and topped with a little white noise for
//! density. Three bands with their own envelopes shape it, the 808 cymbal trick: the low end
//! (band-pass at Tone/4, 0.25 × Decay, level **Body**) dies first, the mid (band-pass at Tone/2,
//! 0.6 × Decay) next, and the high wash (12 dB high-pass at Tone, full Decay) rings longest.
//! **Bloom** is the high band's attack, so the wash swells in just after the strike. A noise
//! **Stick** transient sits on top, and four Schroeder allpasses (**Diffusion**) smear the
//! oscillators into a wash. **Grab** makes note-off choke the cymbal over 30 ms (a hand on the
//! cymbal); off, note-off is ignored like every other one-shot.
//!
//! Everything the audio callback touches is preallocated in `new()` (the allpass lines are sized
//! for 192 kHz), and `render()` chunks its buffer so any block length works.
//!
//! Variations (the Synth Kit uses Crash and Ride):
//! - Crash: the defaults.
//! - Splash: Tune +7, Decay 0.6, Body 20.
//! - Ride: Decay 4.0, Tone 9000, Stick 70, Diffusion 25, Bloom 0.001.
//! - China: Trash 70, Tone 5000, Decay 1.5.

use super::hat::{PHASE_OFFSETS, RATIOS};
use super::layers::{ClickLayer, ClickType};
use super::{DrumParams, DrumVoice, GLOBAL_SPECS};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::dsp::gain::DcBlocker;
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{FilterMode, OneShotEnvelope, Oscillator, Rng, Svf, SvfCoefs, WhiteNoise};

// === Parameters ===

const TUNE: ParamId = 0;
const DECAY: ParamId = 1;
const GRAB: ParamId = 2;
const TONE: ParamId = 10;
const BODY: ParamId = 11;
const TRASH: ParamId = 12;
const DIFFUSION: ParamId = 13;
const STICK: ParamId = 20;
const BLOOM: ParamId = 21;

const OWN: [ParamSpec; 9] = [
    spec(TUNE, "Tune", "Cymbal", "st", linear(-24.0, 24.0), 0.0),
    spec(DECAY, "Decay", "Cymbal", "s", log(0.2, 8.0), 1.8),
    spec(GRAB, "Grab", "Cymbal", "", Kind::Bool, 0.0),
    spec(TONE, "Tone", "Tone", "Hz", log(2_000.0, 14_000.0), 7_000.0),
    spec(BODY, "Body", "Tone", "%", linear(0.0, 100.0), 40.0),
    spec(TRASH, "Trash", "Tone", "%", linear(0.0, 100.0), 10.0),
    spec(
        DIFFUSION,
        "Diffusion",
        "Tone",
        "%",
        linear(0.0, 100.0),
        50.0,
    ),
    spec(STICK, "Stick", "Stick", "%", linear(0.0, 100.0), 30.0),
    spec(BLOOM, "Bloom", "Stick", "s", log(0.001, 0.2), 0.02),
];
const SPECS: [ParamSpec; 12] = flatten(&[&OWN, &GLOBAL_SPECS]);
const SLOTS: [u8; 93] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

// === Synthesis constants ===

/// Each oscillator's contribution is scaled so the six-partial sum stays around ±1.
const METAL_SCALE: f32 = 1.0 / 6.0;
/// Fixed white-noise level added to the source for density.
const NOISE_LEVEL: f32 = 0.15;
/// Internal render chunk. Any `render` length is cut into pieces of at most this many frames.
const CHUNK: usize = 512;
/// Seed for the white-noise generator; reset on every trigger so hits are reproducible.
const NOISE_SEED: u32 = 0x7C1B_A105;
/// Seed of the Stick transient's noise.
const STICK_SEED: u32 = 0x57_1C_C0DE;
/// Resonance of the three band filters. Fixed: the bands have no Q control.
const BAND_RESONANCE: f32 = 0.15;
/// Envelope curve: slightly held, so the wash stays up before it falls.
const ENV_CURVE: f32 = 0.3;
/// Softer hits lower Tone by up to an octave, scaled by Velocity sensitivity.
const VELOCITY_BRIGHTNESS_OCTAVES: f32 = 1.0;
/// Release time of Grab (note-off choke).
const GRAB_SECONDS: f32 = 0.03;
/// The Stick transient's decay.
const STICK_DECAY: f32 = 0.01;
/// Output scale, so a full-velocity default hit peaks near -6 dBFS.
const OUTPUT_GAIN: f32 = 1.8;
/// DC blocker cutoff.
const DC_HZ: f32 = 5.0;

/// Allpass delays in milliseconds.
const ALLPASS_MS: [f32; 4] = [1.3, 2.9, 4.7, 7.1];
/// The highest sample rate the allpass lines are sized for.
const MAX_SAMPLE_RATE: f32 = 192_000.0;

/// A Schroeder allpass over a fixed, preallocated delay line.
struct Allpass {
    buf: Vec<f32>,
    pos: usize,
    len: usize,
}

impl Allpass {
    fn new(ms: f32, sample_rate: f32) -> Self {
        let max = (ms * 0.001 * MAX_SAMPLE_RATE).ceil() as usize + 2;
        let mut allpass = Self {
            buf: vec![0.0; max],
            pos: 0,
            len: 1,
        };
        allpass.set_delay(ms, sample_rate);
        allpass
    }

    /// Retune the delay for `sample_rate` (never allocates; clamped to the line's size).
    fn set_delay(&mut self, ms: f32, sample_rate: f32) {
        self.len = ((ms * 0.001 * sample_rate).round() as usize).clamp(1, self.buf.len());
        self.pos = 0;
    }

    fn clear(&mut self) {
        self.buf.fill(0.0);
        self.pos = 0;
    }

    #[inline]
    fn process(&mut self, x: f32, g: f32) -> f32 {
        let delayed = self.buf[self.pos];
        let v = x - g * delayed;
        self.buf[self.pos] = v;
        self.pos += 1;
        if self.pos >= self.len {
            self.pos = 0;
        }
        delayed + g * v
    }
}

/// The 808-style cymbal voice.
pub struct CymbalVoice {
    sample_rate: f32,
    values: ParamValues<12>,
    params: DrumParams,

    oscs: [Oscillator; 6],
    noise: WhiteNoise,
    low: Svf,
    mid: Svf,
    high: Svf,
    env_low: OneShotEnvelope,
    env_mid: OneShotEnvelope,
    env_high: OneShotEnvelope,
    stick: ClickLayer,
    allpasses: [Allpass; 4],
    dc: DcBlocker,

    // Decoded parameter values (updated when a parameter changes).
    tune: f32,
    decay: f32,
    grab: bool,
    tone: f32,
    body: f32,
    trash: f32,
    diffusion: f32,
    stick_level: f32,
    bloom: f32,
    /// Level of the fixed density noise. A field so a test can isolate the oscillators.
    noise_level: f32,

    // The current hit.
    hit_tone_hz: f32,
    hit_stick_level: f32,
    /// Grab fade: true after a note-off with Grab on.
    releasing: bool,
    grab_gain: f32,

    // Preallocated scratch: one block per oscillator, and the chunk mix.
    osc_bufs: [Vec<f32>; 6],
    mix: Vec<f32>,
}

impl CymbalVoice {
    /// Re-decode the cached parameter values from the normalized table.
    fn sync_params(&mut self) {
        self.tune = 2f32.powf(self.values.real(TUNE).unwrap_or(0.0) / 12.0);
        self.decay = self.values.real(DECAY).unwrap_or(1.8);
        self.grab = self.values.real(GRAB).unwrap_or(0.0) >= 0.5;
        self.tone = self.values.real(TONE).unwrap_or(7_000.0);
        self.body = self.values.real(BODY).unwrap_or(40.0) / 100.0;
        self.trash = self.values.real(TRASH).unwrap_or(10.0) / 100.0;
        self.diffusion = self.values.real(DIFFUSION).unwrap_or(50.0) / 100.0;
        self.stick_level = self.values.real(STICK).unwrap_or(30.0) / 100.0;
        self.bloom = self.values.real(BLOOM).unwrap_or(0.02);
        self.apply_envelopes(1.0);
    }

    /// Set every band envelope's times from the current parameters; `decay_scale` is the hit's
    /// humanize jitter.
    fn apply_envelopes(&mut self, decay_scale: f32) {
        let decay = (self.decay * decay_scale).clamp(1e-3, 30.0);
        self.env_low.set_attack(0.0);
        self.env_low.set_decay(0.25 * decay);
        self.env_mid.set_attack(0.0);
        self.env_mid.set_decay(0.6 * decay);
        self.env_high.set_attack(self.bloom);
        self.env_high.set_decay(decay);
    }

    fn bands_active(&self) -> bool {
        self.env_low.is_active() || self.env_mid.is_active() || self.env_high.is_active()
    }

    /// Stop everything (the end of a Grab fade).
    fn silence(&mut self) {
        self.env_low.reset();
        self.env_mid.reset();
        self.env_high.reset();
        self.stick.reset();
    }
}

impl DrumVoice for CymbalVoice {
    fn new(sample_rate: f32) -> Self {
        let mk_env = |sr: f32| {
            let mut env = OneShotEnvelope::new(sr);
            env.set_curve(ENV_CURVE);
            env
        };
        let mut stick = ClickLayer::new(sample_rate, STICK_SEED);
        stick.set_type(ClickType::Noise);
        stick.set_tone(10_000.0, STICK_DECAY);
        let mut voice = Self {
            sample_rate,
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            oscs: std::array::from_fn(|_| Oscillator::new()),
            noise: WhiteNoise::new(NOISE_SEED),
            low: Svf::new(),
            mid: Svf::new(),
            high: Svf::new(),
            env_low: mk_env(sample_rate),
            env_mid: mk_env(sample_rate),
            env_high: mk_env(sample_rate),
            stick,
            allpasses: std::array::from_fn(|i| Allpass::new(ALLPASS_MS[i], sample_rate)),
            dc: DcBlocker::new(DC_HZ, sample_rate),
            tune: 1.0,
            decay: 1.8,
            grab: false,
            tone: 7_000.0,
            body: 0.4,
            trash: 0.1,
            diffusion: 0.5,
            stick_level: 0.3,
            bloom: 0.02,
            noise_level: NOISE_LEVEL,
            hit_tone_hz: 7_000.0,
            hit_stick_level: 0.3,
            releasing: false,
            grab_gain: 1.0,
            osc_bufs: std::array::from_fn(|_| vec![0.0; CHUNK]),
            mix: vec![0.0; CHUNK],
        };
        voice.sync_params();
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        self.env_low.set_sample_rate(sample_rate);
        self.env_mid.set_sample_rate(sample_rate);
        self.env_high.set_sample_rate(sample_rate);
        self.stick.set_sample_rate(sample_rate);
        for (allpass, &ms) in self.allpasses.iter_mut().zip(ALLPASS_MS.iter()) {
            allpass.set_delay(ms, sample_rate);
        }
        self.dc = DcBlocker::new(DC_HZ, sample_rate);
    }

    fn specs() -> &'static [ParamSpec] {
        &SPECS
    }

    fn set_parameter(&mut self, id: ParamId, norm: ParamValue) {
        if self.values.set(id, norm).is_some() {
            self.sync_params();
        }
    }

    fn set_param_mod(&mut self, id: ParamId, offset: f32) {
        if self.values.set_offset(id, offset).is_some() {
            self.sync_params();
        }
    }

    fn get_parameter(&self, id: ParamId) -> Option<ParamValue> {
        self.values.get(id)
    }

    fn set_params(&mut self, params: &DrumParams) {
        self.params = *params;
    }

    fn trigger(&mut self, _note: u8, velocity: f32, rng: &mut Rng) {
        let sens = self.params.velocity_sens.clamp(0.0, 1.0);
        let humanize = self.params.humanize.clamp(0.0, 1.0);

        // Humanize: ±10 cents of pitch and ±5 % of decay at full amount.
        let cents = humanize * 10.0 * rng.bipolar();
        let pitch_scale = 2f32.powf(cents / 1200.0);
        let decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();

        // Velocity: softer hits are darker and have less stick, scaled by sensitivity.
        let soft = 1.0 - velocity.clamp(0.0, 1.0);
        let bright = 2f32.powf(-VELOCITY_BRIGHTNESS_OCTAVES * sens * soft);
        self.hit_tone_hz = (self.tone * bright).clamp(40.0, self.sample_rate * 0.45);
        self.hit_stick_level = self.stick_level * (1.0 - sens * soft);

        let tune = self.tune * pitch_scale;
        for (osc, (&ratio, &offset)) in self
            .oscs
            .iter_mut()
            .zip(RATIOS.iter().zip(PHASE_OFFSETS.iter()))
        {
            osc.set_frequency((ratio * tune) as f64, self.sample_rate as f64);
            osc.set_pulse_width(0.5);
            osc.phase = offset;
        }

        let stick_tone = (self.hit_tone_hz * 1.5).clamp(1_000.0, self.sample_rate * 0.45);
        self.stick.set_tone(stick_tone, STICK_DECAY);

        self.noise.reset(NOISE_SEED);
        self.low.reset();
        self.mid.reset();
        self.high.reset();
        self.releasing = false;
        self.grab_gain = 1.0;
        self.apply_envelopes(decay_scale);
        self.env_low.trigger();
        self.env_mid.trigger();
        self.env_high.trigger();
        if self.hit_stick_level > 0.0 {
            self.stick.trigger();
        }
    }

    fn render(&mut self, out: &mut [f32]) {
        if !self.bands_active() && !self.stick.is_active() {
            return;
        }

        let sr = self.sample_rate;
        let tone = self.hit_tone_hz;
        let low_hz = (tone * 0.25).clamp(20.0, sr * 0.45);
        let mid_hz = (tone * 0.5).clamp(20.0, sr * 0.45);
        let k = resonance_to_k(BAND_RESONANCE, FilterMode::Bp12);
        let low_coefs = SvfCoefs::new(cutoff_to_g(low_hz, sr), k, FilterMode::Bp12);
        let low_comp = compensation_coef(low_hz, sr);
        let mid_coefs = SvfCoefs::new(cutoff_to_g(mid_hz, sr), k, FilterMode::Bp12);
        let mid_comp = compensation_coef(mid_hz, sr);
        let high_coefs = SvfCoefs::new(
            cutoff_to_g(tone, sr),
            resonance_to_k(0.0, FilterMode::Hp12),
            FilterMode::Hp12,
        );
        let high_comp = compensation_coef(tone, sr);

        let trash = self.trash;
        let metal_mix = 1.0 - trash;
        let noise_level = self.noise_level;
        let low_level = self.body;
        let mid_level = 0.5 + 0.5 * self.body;
        let diffusion = self.diffusion;
        let g = 0.4 + 0.3 * diffusion;
        let grab_step = 1.0 / (GRAB_SECONDS * sr);

        let mut pos = 0;
        while pos < out.len() {
            let n = (out.len() - pos).min(CHUNK);
            for (osc, buf) in self.oscs.iter_mut().zip(self.osc_bufs.iter_mut()) {
                osc.process_block(1, &mut buf[..n], n);
            }
            for j in 0..n {
                let o = [
                    self.osc_bufs[0][j],
                    self.osc_bufs[1][j],
                    self.osc_bufs[2][j],
                    self.osc_bufs[3][j],
                    self.osc_bufs[4][j],
                    self.osc_bufs[5][j],
                ];
                let metal = (o[0] + o[1] + o[2] + o[3] + o[4] + o[5]) * METAL_SCALE;
                let ring = (o[0] * o[3] + o[1] * o[4] + o[2] * o[5]) * (1.0 / 3.0);
                let x = metal_mix * metal + trash * ring + noise_level * self.noise.next();

                let low =
                    self.low
                        .process(x, FilterMode::Bp12, &low_coefs, low_comp, BAND_RESONANCE);
                let mid =
                    self.mid
                        .process(x, FilterMode::Bp12, &mid_coefs, mid_comp, BAND_RESONANCE);
                let high = self
                    .high
                    .process(x, FilterMode::Hp12, &high_coefs, high_comp, 0.0);
                self.mix[j] = low * self.env_low.process_sample() * low_level
                    + mid * self.env_mid.process_sample() * mid_level
                    + high * self.env_high.process_sample();
            }
            self.stick.render(&mut self.mix[..n], self.hit_stick_level);

            for j in 0..n {
                let dry = self.mix[j];
                let mut wet = dry;
                for allpass in &mut self.allpasses {
                    wet = allpass.process(wet, g);
                }
                let mut y = dry * (1.0 - diffusion) + wet * diffusion;
                y = self.dc.process(y) * OUTPUT_GAIN;
                if self.releasing {
                    self.grab_gain -= grab_step;
                    if self.grab_gain <= 0.0 {
                        self.grab_gain = 0.0;
                        self.silence();
                    }
                    y *= self.grab_gain;
                }
                out[pos + j] += y;
            }
            pos += n;
            if self.releasing && self.grab_gain <= 0.0 {
                break;
            }
        }
    }

    fn release(&mut self) {
        if self.grab && self.is_active() {
            self.releasing = true;
        }
    }

    fn is_active(&self) -> bool {
        self.bands_active() || self.stick.is_active()
    }

    fn reset(&mut self) {
        self.silence();
        self.low.reset();
        self.mid.reset();
        self.high.reset();
        for osc in &mut self.oscs {
            osc.reset();
        }
        for allpass in &mut self.allpasses {
            allpass.clear();
        }
        self.dc.reset();
        self.noise.reset(NOISE_SEED);
        self.releasing = false;
        self.grab_gain = 1.0;
    }

    fn device_id() -> &'static str {
        "sonara.builtin.cymbal"
    }

    fn device_name() -> &'static str {
        "Cymbal"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{peak, spectrum_db, to_db};

    const SR: f32 = 48_000.0;

    fn hit(voice: &mut CymbalVoice, seconds: f32) -> Vec<f32> {
        voice.trigger(49, 1.0, &mut Rng::new(5));
        let mut buf = vec![0.0f32; (SR * seconds) as usize];
        voice.render(&mut buf);
        buf
    }

    /// Sum of squared spectrum amplitude between `lo` and `hi` Hz for the window `[a, b)`.
    fn band_power(buf: &[f32], a: usize, b: usize, lo: f32, hi: f32) -> f32 {
        let seg = &buf[a..b];
        let db = spectrum_db(seg);
        let bin_hz = SR / seg.len() as f32;
        db.iter()
            .enumerate()
            .filter(|(i, _)| {
                let hz = *i as f32 * bin_hz;
                hz >= lo && hz < hi
            })
            .map(|(_, &d)| 10f32.powf(d / 10.0))
            .sum()
    }

    fn set_real(voice: &mut CymbalVoice, id: ParamId, real: f32) {
        let norm = TABLE
            .spec(id)
            .map(|s| s.to_norm(real))
            .expect("known parameter");
        voice.set_parameter(id, norm);
    }

    /// Defaults fall silent within the conformance tail limit, and the default is a crash of
    /// about the Decay length.
    #[test]
    fn defaults_fall_silent_within_the_max_tail() {
        let mut voice = CymbalVoice::new(SR);
        let buf = hit(&mut voice, 4.0);
        let tail = &buf[(3.9 * SR) as usize..];
        assert!(
            peak(tail) < 10f32.powf(-90.0 / 20.0),
            "{}",
            to_db(peak(tail))
        );
        assert!(!voice.is_active());
        eprintln!(
            "default tail: {:.2} s to -60 dB, peak {:.1} dBFS",
            crate::audio::dsp::test_util::time_to_db(&buf, -60.0, SR),
            to_db(peak(&buf))
        );
    }

    /// The low end dies first: below Tone/2 loses at least 12 dB more than above Tone does.
    #[test]
    fn low_end_dies_before_the_wash() {
        let mut voice = CymbalVoice::new(SR);
        voice.set_params(&DrumParams {
            velocity_sens: 0.0,
            output_db: 0.0,
            humanize: 0.0,
        });
        let buf = hit(&mut voice, 1.0);
        let (a0, a1) = (0, (0.1 * SR) as usize);
        let (b0, b1) = ((0.6 * SR) as usize, (0.8 * SR) as usize);
        let tone = 7_000.0;
        let low_drop = 10.0
            * (band_power(&buf, a0, a1, 100.0, tone / 2.0)
                / band_power(&buf, b0, b1, 100.0, tone / 2.0))
            .log10();
        let high_drop = 10.0
            * (band_power(&buf, a0, a1, tone, 20_000.0) / band_power(&buf, b0, b1, tone, 20_000.0))
                .log10();
        eprintln!("low dropped {low_drop:.1} dB, high {high_drop:.1} dB");
        assert!(
            low_drop - high_drop >= 12.0,
            "low dropped {low_drop:.1} dB, high {high_drop:.1} dB"
        );
    }

    /// Bloom is the high band's attack: its envelope peaks Bloom seconds after the hit.
    #[test]
    fn bloom_delays_the_high_band_peak() {
        let peak_time = |bloom: f32| {
            let mut voice = CymbalVoice::new(SR);
            set_real(&mut voice, BLOOM, bloom);
            voice.trigger(49, 1.0, &mut Rng::new(1));
            let mut best = (0.0f32, 0usize);
            for i in 0..(SR * 0.5) as usize {
                let v = voice.env_high.process_sample();
                if v > best.0 {
                    best = (v, i);
                }
            }
            best.1 as f32 / SR
        };
        assert!(peak_time(0.1) >= 0.08, "{}", peak_time(0.1));
        assert!(peak_time(0.001) < 0.01, "{}", peak_time(0.001));
    }

    /// Grab on: note-off chokes the cymbal. Off: note-off changes nothing.
    #[test]
    fn grab_chokes_on_note_off_and_off_ignores_it() {
        let render = |grab: bool, release: bool| {
            let mut voice = CymbalVoice::new(SR);
            set_real(&mut voice, GRAB, if grab { 1.0 } else { 0.0 });
            voice.trigger(49, 1.0, &mut Rng::new(3));
            let mut buf = vec![0.0f32; (0.3 * SR) as usize];
            voice.render(&mut buf[..(0.1 * SR) as usize]);
            if release {
                voice.release();
            }
            voice.render(&mut buf[(0.1 * SR) as usize..]);
            (buf, voice.is_active())
        };
        let (grabbed, active) = render(true, true);
        let after = &grabbed[(0.15 * SR) as usize..];
        assert!(
            peak(after) < 10f32.powf(-60.0 / 20.0),
            "{}",
            to_db(peak(after))
        );
        assert!(!active);

        let (with, _) = render(false, true);
        let (without, _) = render(false, false);
        assert_eq!(with, without);
        assert!(peak(&with) > 0.01);
    }

    /// Trash adds ring-modulation products, so the spectra differ.
    #[test]
    fn trash_changes_the_spectrum() {
        let spectrum = |trash: f32| {
            let mut voice = CymbalVoice::new(SR);
            voice.noise_level = 0.0;
            set_real(&mut voice, TRASH, trash);
            set_real(&mut voice, TONE, 2_000.0);
            let buf = hit(&mut voice, 0.5);
            spectrum_db(&buf[2_000..2_000 + 16_384])
        };
        let (clean, trashy) = (spectrum(0.0), spectrum(100.0));
        let bin_hz = SR / 16_384.0;
        let (lo, hi) = ((1_000.0 / bin_hz) as usize, (12_000.0 / bin_hz) as usize);
        let mean_diff =
            (lo..hi).map(|i| (clean[i] - trashy[i]).abs()).sum::<f32>() / (hi - lo) as f32;
        assert!(
            mean_diff > 3.0,
            "mean spectral difference {mean_diff:.2} dB"
        );
    }

    /// At Tune +24 st the pulse oscillators stay band-limited: apart from harmonics of the
    /// partials, nothing below 16 kHz is within 50 dB of the peak.
    #[test]
    fn pulse_oscillators_do_not_alias_at_plus_24_semitones() {
        let mut voice = CymbalVoice::new(SR);
        voice.noise_level = 0.0;
        set_real(&mut voice, TUNE, 24.0);
        set_real(&mut voice, TRASH, 0.0);
        set_real(&mut voice, STICK, 0.0);
        set_real(&mut voice, DIFFUSION, 0.0);
        set_real(&mut voice, TONE, 2_000.0);
        set_real(&mut voice, DECAY, 8.0);
        let buf = hit(&mut voice, 3.0);
        let seg = &buf[48_000..48_000 + 32_768];
        let db = spectrum_db(seg);
        let bin_hz = SR / seg.len() as f32;
        let top = db.iter().copied().fold(f32::MIN, f32::max);

        let mut worst = f32::MIN;
        for (i, &value) in db.iter().enumerate() {
            let hz = i as f32 * bin_hz;
            if hz <= 0.0 || hz > 16_000.0 {
                continue;
            }
            let near_harmonic = RATIOS.iter().any(|&f| {
                let fundamental = f * 4.0;
                let h = (hz / fundamental).round().max(1.0);
                (hz - h * fundamental).abs() < 30.0
            });
            if !near_harmonic {
                worst = worst.max(value);
            }
        }
        assert!(
            top - worst > 50.0,
            "folded components only {:.1} dB below the peak",
            top - worst
        );
    }

    /// Two voices given the same seed, parameters and hit produce identical samples.
    #[test]
    fn identical_hits_are_sample_identical_with_a_fixed_seed() {
        let params = DrumParams {
            velocity_sens: 0.5,
            output_db: 0.0,
            humanize: 1.0,
        };
        let mut a = CymbalVoice::new(SR);
        let mut b = CymbalVoice::new(SR);
        a.set_params(&params);
        b.set_params(&params);
        a.trigger(49, 0.8, &mut Rng::new(2_024));
        b.trigger(49, 0.8, &mut Rng::new(2_024));

        let mut out_a = vec![0.0f32; 24_000];
        let mut out_b = vec![0.0f32; 24_000];
        a.render(&mut out_a);
        b.render(&mut out_b);

        assert_eq!(out_a, out_b);
        assert!(out_a.iter().any(|&x| x != 0.0), "voice produced silence");
        assert!(out_a.iter().all(|x| x.is_finite()));
    }
}
