//! Shaker (`sonara.builtin.shaker`, spec 056, Phase 3): maracas and shakers.
//!
//! Shaped, filtered noise with an optional grainy "beads" texture. The source is
//! `(1 - Grain) * white + Grain * beads`, where beads is a sparse train of random impulses that
//! gets denser at the envelope's peak. It goes through a resonant band-pass at **Tone** (**Ring**
//! is its resonance) and a fixed 12 dB high-pass at 800 Hz, under an envelope with a linear
//! **Attack** and a **Decay**. There is no pitch, so no Tune; ID 0 is deliberately unused so Decay
//! keeps ID 1 like every other drum.

use super::params::GLOBAL_SPECS;
use super::{DrumParams, DrumVoice};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{FilterMode, OneShotEnvelope, Rng, Svf, SvfCoefs, WhiteNoise};

const DECAY: ParamId = 1;
const ATTACK: ParamId = 2;
const TONE: ParamId = 10;
const RING: ParamId = 11;
const GRAIN: ParamId = 12;

const OWN: [ParamSpec; 5] = [
    spec(DECAY, "Decay", "Shaker", "s", log(0.01, 0.5), 0.06),
    spec(ATTACK, "Attack", "Shaker", "s", log(0.001, 0.1), 0.008),
    spec(TONE, "Tone", "Tone", "Hz", log(1_000.0, 14_000.0), 6_000.0),
    spec(RING, "Ring", "Tone", "%", linear(0.0, 100.0), 20.0),
    spec(GRAIN, "Grain", "Tone", "%", linear(0.0, 100.0), 40.0),
];
const SPECS: [ParamSpec; 8] = flatten(&[&OWN, &GLOBAL_SPECS]);
const SLOTS: [u8; 93] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Fixed seeds for the white noise and the beads, reset on every trigger.
const NOISE_SEED: u32 = 0x54A7_E501;
const BEADS_SEED: u32 = 0x54A7_E502;
/// Bead probability per sample: `BEADS_BASE + BEADS_ENV * envelope`.
const BEADS_BASE: f32 = 0.02;
const BEADS_ENV: f32 = 0.1;
/// Bead amplitude scale.
const BEADS_GAIN: f32 = 4.0;
/// The fixed high-pass.
const HIGH_PASS_HZ: f32 = 800.0;
/// Softer hits lower Tone by up to half an octave, scaled by Velocity sensitivity.
const VELOCITY_BRIGHTNESS_OCTAVES: f32 = 0.5;

/// The shaker voice.
pub struct ShakerVoice {
    sample_rate: f32,
    values: ParamValues<8>,
    params: DrumParams,

    noise: WhiteNoise,
    beads: Rng,
    bp: Svf,
    hp: Svf,
    env: OneShotEnvelope,

    decay: f32,
    tone: f32,
    resonance: f32,
    grain: f32,
    hit_tone_hz: f32,
}

impl ShakerVoice {
    fn sync_params(&mut self) {
        self.decay = self.values.real(DECAY).unwrap_or(0.06);
        self.tone = self.values.real(TONE).unwrap_or(6_000.0);
        self.resonance = self.values.real(RING).unwrap_or(20.0) / 100.0;
        self.grain = self.values.real(GRAIN).unwrap_or(40.0) / 100.0;
        self.env
            .set_attack(self.values.real(ATTACK).unwrap_or(0.008));
        self.env.set_decay(self.decay);
    }
}

impl DrumVoice for ShakerVoice {
    fn new(sample_rate: f32) -> Self {
        let mut voice = Self {
            sample_rate,
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            noise: WhiteNoise::new(NOISE_SEED),
            beads: Rng::new(BEADS_SEED),
            bp: Svf::new(),
            hp: Svf::new(),
            env: OneShotEnvelope::new(sample_rate),
            decay: 0.06,
            tone: 6_000.0,
            resonance: 0.2,
            grain: 0.4,
            hit_tone_hz: 6_000.0,
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

        // Humanize: ±10 cents of pitch (here, of Tone) and ±5 % of decay at full amount.
        let cents = humanize * 10.0 * rng.bipolar();
        let pitch_scale = 2f32.powf(cents / 1200.0);
        let decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();

        let soft = 1.0 - velocity.clamp(0.0, 1.0);
        let bright = 2f32.powf(-VELOCITY_BRIGHTNESS_OCTAVES * sens * soft);
        self.hit_tone_hz = (self.tone * pitch_scale * bright).clamp(20.0, self.sample_rate * 0.45);

        self.noise.reset(NOISE_SEED);
        self.beads = Rng::new(BEADS_SEED);
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
        let sr = self.sample_rate;
        let bp_coefs = SvfCoefs::new(
            cutoff_to_g(self.hit_tone_hz, sr),
            resonance_to_k(self.resonance, FilterMode::Bp12),
            FilterMode::Bp12,
        );
        let bp_comp = compensation_coef(self.hit_tone_hz, sr);
        let hp_coefs = SvfCoefs::new(
            cutoff_to_g(HIGH_PASS_HZ, sr),
            resonance_to_k(0.0, FilterMode::Hp12),
            FilterMode::Hp12,
        );
        let hp_comp = compensation_coef(HIGH_PASS_HZ, sr);
        let (resonance, grain) = (self.resonance, self.grain);

        for sample in out.iter_mut() {
            let env = self.env.process_sample();
            let bead = if self.beads.next_f32() < BEADS_BASE + BEADS_ENV * env {
                self.beads.bipolar() * BEADS_GAIN
            } else {
                0.0
            };
            let x = (1.0 - grain) * self.noise.next() + grain * bead;
            let band = self
                .bp
                .process(x, FilterMode::Bp12, &bp_coefs, bp_comp, resonance);
            let high = self
                .hp
                .process(band, FilterMode::Hp12, &hp_coefs, hp_comp, 0.0);
            *sample += high * env;
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
        self.noise.reset(NOISE_SEED);
        self.beads = Rng::new(BEADS_SEED);
    }

    fn device_id() -> &'static str {
        "sonara.builtin.shaker"
    }

    fn device_name() -> &'static str {
        "Shaker"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{peak, rms};

    const SR: f32 = 48_000.0;

    fn set_real(voice: &mut ShakerVoice, id: ParamId, real: f32) {
        let spec = ShakerVoice::specs()
            .iter()
            .find(|s| s.id == id)
            .expect("parameter exists");
        voice.set_parameter(id, spec.to_norm(real));
    }

    fn render(v: &mut ShakerVoice, frames: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; frames];
        for chunk in out.chunks_mut(512) {
            v.render(chunk);
        }
        out
    }

    /// At the default Tone, nearly all the energy is above 2 kHz.
    #[test]
    fn energy_is_in_the_highs() {
        use crate::audio::dsp::test_util::spectrum_db;
        let mut v = ShakerVoice::new(SR);
        set_real(&mut v, DECAY, 0.2);
        v.trigger(70, 1.0, &mut Rng::new(1));
        let sig = render(&mut v, 16_384);
        assert!(peak(&sig) > 0.05, "audible: {}", peak(&sig));
        let db = spectrum_db(&sig);
        let bin = SR / (2.0 * (db.len() - 1) as f32);
        let power = |lo_hz: f32, hi_hz: f32| -> f64 {
            db.iter()
                .enumerate()
                .filter(|(i, _)| {
                    let hz = *i as f32 * bin;
                    hz >= lo_hz && hz < hi_hz
                })
                .map(|(_, &d)| 10f64.powf(d as f64 / 10.0))
                .sum()
        };
        let high = power(2_000.0, SR);
        let total = power(0.0, SR);
        assert!(
            high / total > 0.9,
            "only {:.1} % above 2 kHz",
            100.0 * high / total
        );
    }

    /// The envelope peaks at Attack.
    #[test]
    fn envelope_peaks_at_the_attack_time() {
        for attack in [0.02f32, 0.05] {
            let mut v = ShakerVoice::new(SR);
            set_real(&mut v, ATTACK, attack);
            v.trigger(70, 1.0, &mut Rng::new(1));
            let (mut best, mut best_i) = (0.0f32, 0usize);
            for i in 0..(0.2 * SR) as usize {
                let e = v.env.process_sample();
                if e > best {
                    best = e;
                    best_i = i;
                }
            }
            let at = best_i as f32 / SR;
            assert!((at - attack).abs() < 0.001, "attack {attack}: peak at {at}");
        }
    }

    /// Beads make the hit peakier than plain noise.
    #[test]
    fn grain_raises_the_crest_factor() {
        let crest = |grain: f32| {
            let mut v = ShakerVoice::new(SR);
            set_real(&mut v, GRAIN, grain);
            v.trigger(70, 1.0, &mut Rng::new(1));
            let sig = render(&mut v, 12_000);
            peak(&sig) / rms(&sig)
        };
        let (smooth, grainy) = (crest(0.0), crest(100.0));
        assert!(grainy > smooth * 1.1, "crest {smooth:.2} vs {grainy:.2}");
    }

    #[test]
    fn identical_hits_are_sample_identical_with_a_fixed_seed() {
        let params = DrumParams {
            velocity_sens: 0.5,
            output_db: 0.0,
            humanize: 1.0,
        };
        let mut a = ShakerVoice::new(SR);
        let mut b = ShakerVoice::new(SR);
        a.set_params(&params);
        b.set_params(&params);
        a.trigger(70, 0.8, &mut Rng::new(2_024));
        b.trigger(70, 0.8, &mut Rng::new(2_024));
        let out_a = render(&mut a, 12_000);
        let out_b = render(&mut b, 12_000);
        assert_eq!(out_a, out_b);
        assert!(out_a.iter().any(|&x| x != 0.0), "voice produced silence");
        assert!(out_a.iter().all(|x| x.is_finite()));
    }
}
