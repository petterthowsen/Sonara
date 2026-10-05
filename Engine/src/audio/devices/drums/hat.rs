//! Hat (`sonara.builtin.hat`, spec 013, Phase 3): the 808 approach.
//!
//! Six band-limited pulse oscillators at the 808 inharmonic ratios, summed and mixed with white
//! noise by Metal, then a resonant band-pass at Tone (Ring is its resonance), a 12 dB high-pass
//! and a one-shot amp envelope. The high-pass follows Tone: **Body** sets how far below Tone it
//! sits (0 % = at Tone, thin; 100 % = two octaves below, full), so the two can never cancel out. Everything the audio callback touches is preallocated in `new()`;
//! `render()` chunks its buffer so any block size works and never allocates.
//!
//! Closed and open hats are two instances of this voice with different Decay, choked together by
//! the Drum Machine.

use super::params::GLOBAL_SPECS;
use super::{DrumParams, DrumVoice};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{FilterMode, OneShotEnvelope, Oscillator, Rng, Svf, SvfCoefs, WhiteNoise};

// === Parameters ===

const TUNE: ParamId = 0;
const DECAY: ParamId = 1;
const SHAPE: ParamId = 2;
const TONE: ParamId = 10;
const METAL: ParamId = 11;
const RING: ParamId = 12;
const BODY: ParamId = 13;

const OWN: [ParamSpec; 7] = [
    spec(TUNE, "Tune", "Hat", "st", linear(-12.0, 12.0), 0.0),
    spec(DECAY, "Decay", "Hat", "s", log(0.01, 2.0), 0.06),
    spec(SHAPE, "Shape", "Hat", "%", linear(-100.0, 100.0), -30.0),
    spec(TONE, "Tone", "Tone", "Hz", log(3_000.0, 12_000.0), 8_000.0),
    spec(METAL, "Metal", "Tone", "%", linear(0.0, 100.0), 30.0),
    spec(RING, "Ring", "Tone", "%", linear(0.0, 100.0), 30.0),
    spec(BODY, "Body", "Tone", "%", linear(0.0, 100.0), 20.0),
];
const SPECS: [ParamSpec; 10] = flatten(&[&OWN, &GLOBAL_SPECS]);
const SLOTS: [u8; 93] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

// === Synthesis constants ===

/// The six 808 metal partials (Hz) at Tune 1.
const RATIOS: [f32; 6] = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0];
/// Fixed phase offsets so the six oscillators don't all fire their edge on the same sample.
const PHASE_OFFSETS: [f64; 6] = [0.0, 0.17, 0.33, 0.51, 0.68, 0.83];
/// Each oscillator's contribution is scaled so the six-partial sum stays around ±1.
const METAL_SCALE: f32 = 1.0 / 6.0;
/// Internal render chunk. Any `render` length is cut into pieces of at most this many frames.
const CHUNK: usize = 512;
/// Seed for the white-noise generator; reset on every trigger so hits are reproducible.
const NOISE_SEED: u32 = 0x5A17_1B3D;
/// Softer hits lower Tone by up to half an octave, scaled by Velocity sensitivity.
const VELOCITY_BRIGHTNESS_OCTAVES: f32 = 0.5;
/// At Body 100 % the high-pass sits this many octaves below Tone.
const BODY_OCTAVES: f32 = 2.0;

/// The 808-style hat/cymbal voice.
pub struct HatVoice {
    sample_rate: f32,
    values: ParamValues<10>,
    params: DrumParams,

    oscs: [Oscillator; 6],
    noise: WhiteNoise,
    bp: Svf,
    hp: Svf,
    env: OneShotEnvelope,

    // Decoded parameter values (updated when a parameter changes).
    tune: f32,
    metal: f32,
    tone: f32,
    resonance: f32,
    body: f32,
    decay: f32,
    /// Tone of the current hit, after velocity brightness. Set at trigger.
    hit_tone_hz: f32,
    /// High-pass cutoff of the current hit: Body octaves below its tone.
    hit_low_cut_hz: f32,

    // Preallocated scratch: one oscillator's block, and the six-partial sum.
    osc_buf: Vec<f32>,
    acc: Vec<f32>,
}

impl HatVoice {
    /// Re-decode the cached parameter values from the normalized table.
    fn sync_params(&mut self) {
        self.tune = 2f32.powf(self.values.real(TUNE).unwrap_or(0.0) / 12.0);
        self.metal = self.values.real(METAL).unwrap_or(30.0) / 100.0;
        self.tone = self.values.real(TONE).unwrap_or(8_000.0);
        self.resonance = self.values.real(RING).unwrap_or(30.0) / 100.0;
        self.body = self.values.real(BODY).unwrap_or(20.0) / 100.0;
        self.decay = self.values.real(DECAY).unwrap_or(0.06);
        let curve = self.values.real(SHAPE).unwrap_or(-30.0) / 100.0;

        self.env.set_attack(0.0);
        self.env.set_decay(self.decay);
        self.env.set_curve(curve);
    }
}

impl DrumVoice for HatVoice {
    fn new(sample_rate: f32) -> Self {
        let mut voice = Self {
            sample_rate,
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            oscs: std::array::from_fn(|_| Oscillator::new()),
            noise: WhiteNoise::new(NOISE_SEED),
            bp: Svf::new(),
            hp: Svf::new(),
            env: OneShotEnvelope::new(sample_rate),
            tune: 1.0,
            metal: 0.3,
            tone: 8_000.0,
            resonance: 0.3,
            body: 0.2,
            decay: 0.06,
            hit_tone_hz: 8_000.0,
            hit_low_cut_hz: 6_000.0,
            osc_buf: vec![0.0; CHUNK],
            acc: vec![0.0; CHUNK],
        };
        voice.sync_params();
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        self.env.set_sample_rate(sample_rate);
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

        // Velocity brightness scales with sensitivity, so at 0 the hit is velocity-independent;
        // a full-velocity hit plays Tone and softer hits are darker.
        let soft = 1.0 - velocity.clamp(0.0, 1.0);
        let bright = 2f32.powf(-VELOCITY_BRIGHTNESS_OCTAVES * sens * soft);
        self.hit_tone_hz = (self.tone * bright).clamp(20.0, self.sample_rate * 0.45);
        self.hit_low_cut_hz = self.hit_tone_hz * 2f32.powf(-BODY_OCTAVES * self.body);

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

        self.noise.reset(NOISE_SEED);
        self.bp.reset();
        self.hp.reset();
        self.env
            .set_decay((self.decay * decay_scale).clamp(1e-4, 30.0));
        self.env.trigger();
    }

    fn render(&mut self, out: &mut [f32]) {
        if !self.env.is_active() {
            return;
        }

        // Cutoff and resonance are steady within a hit, so build the coefficients once per call.
        let sr = self.sample_rate;
        let bp_coefs = SvfCoefs::new(
            cutoff_to_g(self.hit_tone_hz, sr),
            resonance_to_k(self.resonance, FilterMode::Bp12),
            FilterMode::Bp12,
        );
        let bp_comp = compensation_coef(self.hit_tone_hz, sr);
        let hp_coefs = SvfCoefs::new(
            cutoff_to_g(self.hit_low_cut_hz, sr),
            resonance_to_k(0.0, FilterMode::Hp12),
            FilterMode::Hp12,
        );
        let hp_comp = compensation_coef(self.hit_low_cut_hz, sr);

        let resonance = self.resonance;
        let metal = self.metal;
        let noise_mix = 1.0 - metal;

        let mut pos = 0;
        while pos < out.len() {
            let n = (out.len() - pos).min(CHUNK);
            for a in &mut self.acc[..n] {
                *a = 0.0;
            }
            for osc in &mut self.oscs {
                osc.process_block(1, &mut self.osc_buf[..n], n);
                for (acc, &sample) in self.acc[..n].iter_mut().zip(&self.osc_buf[..n]) {
                    *acc += sample * METAL_SCALE;
                }
            }
            for j in 0..n {
                let x = metal * self.acc[j] + noise_mix * self.noise.next();
                let band = self
                    .bp
                    .process(x, FilterMode::Bp12, &bp_coefs, bp_comp, resonance);
                let high = self
                    .hp
                    .process(band, FilterMode::Hp12, &hp_coefs, hp_comp, 0.0);
                out[pos + j] += high * self.env.process_sample();
            }
            pos += n;
        }
    }

    fn release(&mut self) {}

    fn is_active(&self) -> bool {
        self.env.is_active()
    }

    fn reset(&mut self) {
        self.env.reset();
        self.bp.reset();
        self.hp.reset();
        for osc in &mut self.oscs {
            osc.reset();
        }
        self.noise.reset(NOISE_SEED);
    }

    fn device_id() -> &'static str {
        "sonara.builtin.hat"
    }

    fn device_name() -> &'static str {
        "Hat"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::spectrum_db;

    const SR: f32 = 48_000.0;

    /// Largest spectrum value within ±`half` Hz of `hz`.
    fn peak_near(db: &[f32], bin_hz: f32, hz: f32, half: f32) -> f32 {
        let lo = (((hz - half) / bin_hz).floor().max(1.0)) as usize;
        let hi = (((hz + half) / bin_hz).ceil() as usize).min(db.len() - 1);
        db[lo..=hi].iter().copied().fold(f32::MIN, f32::max)
    }

    /// The spectrum peak, in dB.
    fn peak_db(db: &[f32]) -> f32 {
        db.iter().copied().fold(f32::MIN, f32::max)
    }

    /// (a) The 12 dB high-pass leaves no tonal energy an octave below its cutoff.
    ///
    /// The six metal partials are all below half the default cutoff (Body 20 % puts it about
    /// 6 kHz, under the 8 kHz Tone), so they must be more than 40 dB below the passband peak.
    #[test]
    fn high_pass_removes_the_metal_partials_below_low_cut_octave() {
        let mut voice = HatVoice::new(SR);
        voice.trigger(42, 1.0, &mut Rng::new(11));
        let mut buf = vec![0.0f32; 32_768];
        voice.render(&mut buf);

        let db = spectrum_db(&buf);
        let bin_hz = SR / buf.len() as f32;
        let peak = peak_db(&db);
        for &f in &RATIOS {
            assert!(f < 3_000.0);
            let band = peak_near(&db, bin_hz, f, 15.0);
            assert!(
                peak - band > 40.0,
                "partial {f:.1} Hz only {:.1} dB below the peak",
                peak - band
            );
        }
    }

    /// (b) At double Tune the six pulse oscillators stay band-limited: the only energy below
    /// 16 kHz is at harmonics of the partials. Everything else (folded components) is well down.
    ///
    /// The polyBLEP alias floor for these inharmonic partials measures around 55 dB below the
    /// passband peak, so the check allows 50 dB.
    #[test]
    fn pulse_oscillators_do_not_alias_at_double_tune() {
        let mut voice = HatVoice::new(SR);
        voice.set_parameter(TUNE, 1.0); // +12 st: 2x
        voice.set_parameter(METAL, 1.0); // noise off: isolate the oscillators
        voice.set_parameter(DECAY, 1.0); // 2 s: a long, slowly varying envelope
        voice.trigger(42, 1.0, &mut Rng::new(13));
        let mut buf = vec![0.0f32; 96_000];
        voice.render(&mut buf);

        // A steady window part-way through the decay, so the envelope doesn't smear the peaks.
        let seg = &buf[48_000..48_000 + 32_768];
        let db = spectrum_db(seg);
        let bin_hz = SR / seg.len() as f32;
        let peak = peak_db(&db);

        let mut worst = f32::MIN;
        for (i, &value) in db.iter().enumerate() {
            let hz = i as f32 * bin_hz;
            if hz <= 0.0 || hz > 16_000.0 {
                continue;
            }
            let near_harmonic = RATIOS.iter().any(|&f| {
                let fundamental = f * 2.0;
                let h = (hz / fundamental).round().max(1.0);
                (hz - h * fundamental).abs() < 30.0
            });
            if !near_harmonic {
                worst = worst.max(value);
            }
        }
        assert!(
            peak - worst > 50.0,
            "folded components only {:.1} dB below the peak",
            peak - worst
        );
    }

    /// (d) Body follows Tone: the high-pass sits Body · 2 octaves below the hit's tone, and a
    /// full-velocity hit plays Tone itself.
    #[test]
    fn body_sets_the_high_pass_relative_to_tone() {
        let mut voice = HatVoice::new(SR);
        voice.set_params(&DrumParams {
            velocity_sens: 1.0,
            output_db: 0.0,
            humanize: 0.0,
        });
        voice.set_parameter(TONE, 0.0); // 3 kHz, the lowest Tone
        voice.set_parameter(BODY, 0.5); // one octave below
        voice.trigger(42, 1.0, &mut Rng::new(1));
        assert!(
            (voice.hit_tone_hz - 3_000.0).abs() < 1.0,
            "{}",
            voice.hit_tone_hz
        );
        assert!(
            (voice.hit_low_cut_hz - 1_500.0).abs() < 1.0,
            "{}",
            voice.hit_low_cut_hz
        );

        // A soft hit is darker, and the high-pass moves down with it.
        voice.trigger(42, 0.0, &mut Rng::new(1));
        let expected = 3_000.0 * 2f32.powf(-VELOCITY_BRIGHTNESS_OCTAVES);
        assert!(
            (voice.hit_tone_hz - expected).abs() < 1.0,
            "{}",
            voice.hit_tone_hz
        );
        assert!((voice.hit_low_cut_hz - expected / 2.0).abs() < 1.0);
    }

    /// (c) Two voices given the same seed, parameters and hit produce identical samples.
    #[test]
    fn identical_hits_are_sample_identical_with_a_fixed_seed() {
        let params = DrumParams {
            velocity_sens: 0.5,
            output_db: 0.0,
            humanize: 1.0,
        };
        let mut a = HatVoice::new(SR);
        let mut b = HatVoice::new(SR);
        a.set_params(&params);
        b.set_params(&params);
        a.trigger(42, 0.8, &mut Rng::new(2_024));
        b.trigger(42, 0.8, &mut Rng::new(2_024));

        let mut out_a = vec![0.0f32; 12_000];
        let mut out_b = vec![0.0f32; 12_000];
        a.render(&mut out_a);
        b.render(&mut out_b);

        assert_eq!(out_a, out_b);
        assert!(out_a.iter().any(|&x| x != 0.0), "voice produced silence");
        assert!(out_a.iter().all(|x| x.is_finite()));
    }
}
