//! Rimshot (`sonara.builtin.rimshot`, spec 056, Phase 2): the 808 approach.
//!
//! A short [`ClickLayer`] tick rings two tuned resonant band-passes in parallel, one at **Tune**
//! and one at **Tune x 3.66** (455 -> 1665 Hz, the 808 pair) at **Overtone** level; **Ring** is
//! their resonance. The sum goes through a high-pass at **Tone**, a one-shot envelope (**Decay**)
//! and the [`DriveStage`] for the snap. With high Ring and Tone it also makes claves. The
//! envelope gates the whole hit, so the voice is silent once Decay has run out.

use super::layers::{ClickLayer, ClickType, DriveStage};
use super::params::GLOBAL_SPECS;
use super::{DrumParams, DrumVoice};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{FilterMode, OneShotEnvelope, Rng, Svf, SvfCoefs};

const TUNE: ParamId = 0;
const DECAY: ParamId = 1;
const DRIVE: ParamId = 2;
const RING: ParamId = 10;
const TONE: ParamId = 11;
const OVERTONE: ParamId = 12;

const OWN: [ParamSpec; 6] = [
    spec(TUNE, "Tune", "Rimshot", "Hz", log(200.0, 2_000.0), 455.0),
    spec(DECAY, "Decay", "Rimshot", "s", log(0.005, 0.3), 0.04),
    spec(DRIVE, "Drive", "Rimshot", "dB", linear(0.0, 24.0), 9.0),
    spec(RING, "Ring", "Tone", "%", linear(0.0, 100.0), 70.0),
    spec(TONE, "Tone", "Tone", "Hz", log(50.0, 3_000.0), 300.0),
    spec(OVERTONE, "Overtone", "Tone", "%", linear(0.0, 100.0), 50.0),
];
const SPECS: [ParamSpec; 9] = flatten(&[&OWN, &GLOBAL_SPECS]);
const SLOTS: [u8; 93] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

const CHUNK: usize = 512;
/// The second resonator's ratio to the first (the 808 pair).
const OVERTONE_RATIO: f32 = 3.66;
/// The tick sits at this multiple of Tune, so it excites both resonators.
const TICK_RATIO: f32 = 2.0;
/// Duration of the tick.
const TICK_DECAY: f32 = 0.002;
/// Makeup for the band-passes, whose peak gain falls as Ring narrows them.
const RESONATOR_GAIN: f32 = 4.0;
/// Softer hits excite the resonators up to this much less, scaled by Velocity sensitivity.
const VELOCITY_CLICK_LOSS: f32 = 0.5;

/// The 808-style rimshot / clave voice.
pub struct RimshotVoice {
    sample_rate: f32,
    values: ParamValues<9>,
    params: DrumParams,

    click: ClickLayer,
    bps: [Svf; 2],
    hp: Svf,
    env: OneShotEnvelope,
    drive: DriveStage,

    tune: f32,
    decay: f32,
    ring: f32,
    tone: f32,
    overtone: f32,
    hit_pitch_scale: f32,
    hit_click_level: f32,

    acc: Vec<f32>,
}

impl RimshotVoice {
    fn sync_params(&mut self) {
        self.tune = self.values.real(TUNE).unwrap_or(455.0);
        self.decay = self.values.real(DECAY).unwrap_or(0.04);
        self.ring = self.values.real(RING).unwrap_or(70.0) / 100.0;
        self.tone = self.values.real(TONE).unwrap_or(300.0);
        self.overtone = self.values.real(OVERTONE).unwrap_or(50.0) / 100.0;
        self.env.set_decay(self.decay);
        self.drive
            .set_drive_db(self.values.real(DRIVE).unwrap_or(9.0));
    }
}

impl DrumVoice for RimshotVoice {
    fn new(sample_rate: f32) -> Self {
        let mut env = OneShotEnvelope::new(sample_rate);
        env.set_attack(0.0);
        env.set_curve(0.0);
        let mut voice = Self {
            sample_rate,
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            click: ClickLayer::new(sample_rate, 0x41B5_0001),
            bps: [Svf::new(), Svf::new()],
            hp: Svf::new(),
            env,
            drive: DriveStage::new(),
            tune: 455.0,
            decay: 0.04,
            ring: 0.7,
            tone: 300.0,
            overtone: 0.5,
            hit_pitch_scale: 1.0,
            hit_click_level: 1.0,
            acc: vec![0.0; CHUNK],
        };
        voice.sync_params();
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        self.env.set_sample_rate(sample_rate);
        self.click.set_sample_rate(sample_rate);
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
        self.hit_pitch_scale = 2f32.powf(cents / 1200.0);
        let decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();

        let soft = 1.0 - velocity.clamp(0.0, 1.0);
        self.hit_click_level = 1.0 - VELOCITY_CLICK_LOSS * sens * soft;

        self.click.set_type(ClickType::Tick);
        self.click.set_tone(
            (self.tune * self.hit_pitch_scale * TICK_RATIO).min(self.sample_rate * 0.45),
            TICK_DECAY,
        );
        self.click.trigger();
        for bp in &mut self.bps {
            bp.reset();
        }
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
        let nyquist_limit = sr * 0.45;
        let f1 = (self.tune * self.hit_pitch_scale).min(nyquist_limit);
        let f2 = (f1 * OVERTONE_RATIO).min(nyquist_limit);
        let k = resonance_to_k(self.ring, FilterMode::Bp12);
        let coefs = [
            SvfCoefs::new(cutoff_to_g(f1, sr), k, FilterMode::Bp12),
            SvfCoefs::new(cutoff_to_g(f2, sr), k, FilterMode::Bp12),
        ];
        let comps = [compensation_coef(f1, sr), compensation_coef(f2, sr)];
        let hp_hz = self.tone.min(nyquist_limit);
        let hp_coefs = SvfCoefs::new(
            cutoff_to_g(hp_hz, sr),
            resonance_to_k(0.0, FilterMode::Hp12),
            FilterMode::Hp12,
        );
        let hp_comp = compensation_coef(hp_hz, sr);
        let (ring, overtone) = (self.ring, self.overtone);

        let mut pos = 0;
        while pos < out.len() {
            let n = (out.len() - pos).min(CHUNK);
            self.acc[..n].fill(0.0);
            self.click.render(&mut self.acc[..n], self.hit_click_level);
            for j in 0..n {
                let x = self.acc[j];
                let a = self.bps[0].process(x, FilterMode::Bp12, &coefs[0], comps[0], ring);
                let b = self.bps[1].process(x, FilterMode::Bp12, &coefs[1], comps[1], ring);
                let sum = RESONATOR_GAIN * (a + overtone * b);
                let high = self
                    .hp
                    .process(sum, FilterMode::Hp12, &hp_coefs, hp_comp, 0.0);
                self.acc[j] = high * self.env.process_sample();
            }
            self.drive.process(&mut self.acc[..n]);
            for (o, &s) in out[pos..pos + n].iter_mut().zip(&self.acc[..n]) {
                *o += s;
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
        self.click.reset();
        for bp in &mut self.bps {
            bp.reset();
        }
        self.hp.reset();
        self.drive.reset();
    }

    fn device_id() -> &'static str {
        "sonara.builtin.rimshot"
    }

    fn device_name() -> &'static str {
        "Rimshot"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{peak, spectrum_db, to_db};

    const SR: f32 = 48_000.0;

    fn set_real(voice: &mut RimshotVoice, id: ParamId, real: f32) {
        let spec = RimshotVoice::specs()
            .iter()
            .find(|s| s.id == id)
            .expect("parameter exists");
        voice.set_parameter(id, spec.to_norm(real));
    }

    fn render(v: &mut RimshotVoice, frames: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; frames];
        for chunk in out.chunks_mut(512) {
            v.render(chunk);
        }
        out
    }

    /// Largest level within ±3 % of `hz`.
    fn level_near(db: &[f32], hz: f32) -> f32 {
        let bin = SR / (2.0 * (db.len() - 1) as f32);
        let lo = ((hz * 0.97) / bin).floor() as usize;
        let hi = ((hz * 1.03) / bin).ceil() as usize;
        db[lo..=hi].iter().copied().fold(f32::MIN, f32::max)
    }

    /// Spectrum levels (near Tune, near the overtone, between them) of a long, undriven hit.
    fn analyse(overtone: f32) -> (f32, f32, f32) {
        let mut v = RimshotVoice::new(SR);
        set_real(&mut v, DECAY, 0.3);
        set_real(&mut v, DRIVE, 0.0);
        set_real(&mut v, OVERTONE, overtone);
        v.trigger(37, 1.0, &mut Rng::new(1));
        let sig = render(&mut v, 16_384);
        let db = spectrum_db(&sig);
        (
            level_near(&db, 455.0),
            level_near(&db, 455.0 * OVERTONE_RATIO),
            level_near(&db, 455.0 * 2.0),
        )
    }

    #[test]
    fn rings_at_tune_and_the_overtone_only_when_asked() {
        let (tune, over, between) = analyse(100.0);
        assert!(
            tune > between + 10.0,
            "tune {tune:.1} vs between {between:.1}"
        );
        assert!(
            over > between + 5.0,
            "overtone {over:.1} vs between {between:.1}"
        );

        let (tune0, over0, _) = analyse(0.0);
        assert!((tune0 - tune).abs() < 1.0, "tune moved: {tune0} vs {tune}");
        assert!(
            over - over0 > 15.0,
            "overtone only {:.1} dB above its off level",
            over - over0
        );
    }

    #[test]
    fn is_silent_after_decay() {
        let mut v = RimshotVoice::new(SR);
        v.trigger(37, 1.0, &mut Rng::new(1));
        let sig = render(&mut v, (0.1 * SR) as usize);
        assert!(
            peak(&sig[..2_400]) > 0.1,
            "audible: {}",
            peak(&sig[..2_400])
        );
        let after = (0.04 * SR) as usize + (0.05 * SR) as usize;
        assert!(to_db(peak(&sig[after..])) < -90.0);
        assert!(!v.is_active());
    }

    #[test]
    fn identical_hits_are_sample_identical_with_a_fixed_seed() {
        let params = DrumParams {
            velocity_sens: 0.5,
            output_db: 0.0,
            humanize: 1.0,
        };
        let mut a = RimshotVoice::new(SR);
        let mut b = RimshotVoice::new(SR);
        a.set_params(&params);
        b.set_params(&params);
        a.trigger(37, 0.8, &mut Rng::new(2_024));
        b.trigger(37, 0.8, &mut Rng::new(2_024));
        let out_a = render(&mut a, 12_000);
        let out_b = render(&mut b, 12_000);
        assert_eq!(out_a, out_b);
        assert!(out_a.iter().any(|&x| x != 0.0), "voice produced silence");
        assert!(out_a.iter().all(|x| x.is_finite()));
    }
}
