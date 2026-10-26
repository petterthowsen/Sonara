//! Tom (`sonara.builtin.tom`, spec 056, Phase 1): a tuned membrane.
//!
//! A swept-sine **fundamental**, a second membrane mode (**Overtone**, at a ratio of the
//! fundamental, following the same pitch sweep with half the decay) and a short **skin** layer
//! (a click plus band-passed noise). Body and overtone go through the [`DriveStage`] and the skin
//! is added after it; a [`DcBlocker`] cleans the sum. One device covers low/mid/high toms, and
//! congas/bongos at a higher Tune with a short Decay.
//!
//! **Tune** is the pitch heard on note 45 (GM Low Tom). With **Keytrack** on, other notes
//! transpose from there. The default ratio 1.593 is the ideal circular membrane's (1,1)/(0,1).

use super::layers::{ClickLayer, ClickType, DriveStage};
use super::{DrumParams, DrumVoice, GLOBAL_SPECS};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::ParamId;
use crate::audio::dsp::gain::DcBlocker;
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{
    sweep_hz, FilterMode, OneShotEnvelope, Rng, Svf, SvfCoefs, SweepOsc, SweepShape, WhiteNoise,
};

// Parameter IDs, grouped in tens by module.
const TUNE: ParamId = 0;
const DECAY: ParamId = 1;
const DRIVE: ParamId = 2;
const KEYTRACK: ParamId = 3;
const SWEEP: ParamId = 10;
const SWEEP_TIME: ParamId = 11;
const OVERTONE: ParamId = 20;
const OVERTONE_RATIO: ParamId = 21;
const CLICK: ParamId = 30;
const NOISE: ParamId = 31;
const NOISE_TONE: ParamId = 32;

const TOM: [ParamSpec; 4] = [
    spec(TUNE, "Tune", "Tom", "Hz", log(40.0, 500.0), 110.0),
    spec(DECAY, "Decay", "Tom", "s", log(0.05, 2.0), 0.4),
    spec(DRIVE, "Drive", "Tom", "dB", linear(0.0, 24.0), 0.0),
    spec(KEYTRACK, "Keytrack", "Tom", "", Kind::Bool, 0.0),
];
const SWEEP_SPECS: [ParamSpec; 2] = [
    spec(SWEEP, "Sweep", "Sweep", "st", linear(0.0, 24.0), 5.0),
    spec(SWEEP_TIME, "Sweep Time", "Sweep", "s", log(0.01, 0.5), 0.08),
];
const MEMBRANE: [ParamSpec; 2] = [
    spec(
        OVERTONE,
        "Overtone",
        "Membrane",
        "%",
        linear(0.0, 100.0),
        30.0,
    ),
    spec(
        OVERTONE_RATIO,
        "Overtone Ratio",
        "Membrane",
        "\u{d7}",
        linear(1.2, 2.5),
        1.593,
    ),
];
const SKIN: [ParamSpec; 3] = [
    spec(CLICK, "Click", "Skin", "%", linear(0.0, 100.0), 20.0),
    spec(NOISE, "Noise", "Skin", "%", linear(0.0, 100.0), 15.0),
    spec(
        NOISE_TONE,
        "Noise Tone",
        "Skin",
        "Hz",
        log(500.0, 12_000.0),
        3_000.0,
    ),
];

const SPECS: [ParamSpec; 14] = flatten(&[&TOM, &SWEEP_SPECS, &MEMBRANE, &SKIN, &GLOBAL_SPECS]);
/// ID → slot lookup. `93` is above the highest ID (92, the last global).
const SLOTS: [u8; 93] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// With Keytrack on, this note plays exactly Tune (GM Low Tom).
const REFERENCE_NOTE: u8 = 45;
/// The overtone decays this fraction of the fundamental's Decay.
const OVERTONE_DECAY_RATIO: f32 = 0.5;
/// The skin noise decays this fraction of Decay, capped at `NOISE_MAX_DECAY`.
const NOISE_DECAY_RATIO: f32 = 0.25;
const NOISE_MAX_DECAY: f32 = 0.08;
/// Fixed resonance of the skin noise band-pass.
const NOISE_RESONANCE: f32 = 0.4;
/// Soft hits lose up to this fraction of the Sweep, scaled by Velocity sensitivity.
const VELOCITY_SWEEP_LOSS: f32 = 0.5;
/// Soft hits darken the noise by up to this many octaves, scaled by Velocity sensitivity.
const VELOCITY_NOISE_OCTAVES: f32 = 1.0;
/// Seed for the skin noise, reset on every trigger so hits are reproducible.
const NOISE_SEED: u32 = 0x70D1_0004;
const CLICK_SEED: u32 = 0x70D1_0003;
/// Body frames processed per inner chunk, so the drive stage needs only a small buffer.
const BODY_CHUNK: usize = 32;
const DC_HZ: f32 = 5.0;

/// The synthesized tom voice.
pub struct TomVoice {
    values: ParamValues<14>,
    params: DrumParams,
    sample_rate: f32,

    body_osc: SweepOsc,
    over_osc: SweepOsc,
    pitch_env: OneShotEnvelope,
    body_env: OneShotEnvelope,
    over_env: OneShotEnvelope,
    drive: DriveStage,
    scratch: [f32; BODY_CHUNK],

    click: ClickLayer,
    noise: WhiteNoise,
    noise_filter: Svf,
    noise_coefs: SvfCoefs,
    noise_comp: f32,
    noise_env: OneShotEnvelope,

    dc: DcBlocker,

    // Decoded parameters.
    tune_hz: f32,
    decay: f32,
    keytrack: bool,
    sweep_st: f32,
    overtone_level: f32,
    overtone_ratio: f32,
    click_level: f32,
    noise_level: f32,
    noise_tone: f32,

    // Per-hit state.
    hit_base: f32,
    hit_sweep_st: f32,
}

impl TomVoice {
    fn sync(&mut self) {
        self.tune_hz = self.values.real(TUNE).unwrap_or(110.0);
        self.decay = self.values.real(DECAY).unwrap_or(0.4);
        self.keytrack = self.values.real(KEYTRACK).unwrap_or(0.0) >= 0.5;
        self.sweep_st = self.values.real(SWEEP).unwrap_or(5.0);
        self.overtone_level = self.values.real(OVERTONE).unwrap_or(30.0) / 100.0;
        self.overtone_ratio = self.values.real(OVERTONE_RATIO).unwrap_or(1.593);
        self.click_level = self.values.real(CLICK).unwrap_or(20.0) / 100.0;
        self.noise_level = self.values.real(NOISE).unwrap_or(15.0) / 100.0;
        self.noise_tone = self.values.real(NOISE_TONE).unwrap_or(3_000.0);

        self.pitch_env
            .set_decay(self.values.real(SWEEP_TIME).unwrap_or(0.08));
        self.pitch_env.set_curve(0.0);
        self.body_env.set_decay(self.decay);
        self.over_env.set_decay(self.decay * OVERTONE_DECAY_RATIO);
        self.noise_env
            .set_decay((self.decay * NOISE_DECAY_RATIO).min(NOISE_MAX_DECAY));
        self.drive
            .set_drive_db(self.values.real(DRIVE).unwrap_or(0.0));
    }

    fn update_noise_filter(&mut self, hz: f32) {
        let hz = hz.clamp(20.0, self.sample_rate * 0.45);
        self.noise_coefs = SvfCoefs::new(
            cutoff_to_g(hz, self.sample_rate),
            resonance_to_k(NOISE_RESONANCE, FilterMode::Bp12),
            FilterMode::Bp12,
        );
        self.noise_comp = compensation_coef(hz, self.sample_rate);
    }
}

impl DrumVoice for TomVoice {
    fn new(sample_rate: f32) -> Self {
        let sample_rate = sample_rate.max(1.0);
        let mut env = OneShotEnvelope::new(sample_rate);
        env.set_curve(0.0);
        let mut voice = Self {
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            sample_rate,
            body_osc: SweepOsc::new(),
            over_osc: SweepOsc::new(),
            pitch_env: env.clone(),
            body_env: env.clone(),
            over_env: env.clone(),
            drive: DriveStage::new(),
            scratch: [0.0; BODY_CHUNK],
            click: ClickLayer::new(sample_rate, CLICK_SEED),
            noise: WhiteNoise::new(NOISE_SEED),
            noise_filter: Svf::new(),
            noise_coefs: SvfCoefs::default(),
            noise_comp: 0.0,
            noise_env: env,
            dc: DcBlocker::new(DC_HZ, sample_rate),
            tune_hz: 110.0,
            decay: 0.4,
            keytrack: false,
            sweep_st: 5.0,
            overtone_level: 0.3,
            overtone_ratio: 1.593,
            click_level: 0.2,
            noise_level: 0.15,
            noise_tone: 3_000.0,
            hit_base: 110.0,
            hit_sweep_st: 5.0,
        };
        voice.sync();
        voice.update_noise_filter(3_000.0);
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(1.0);
        self.pitch_env.set_sample_rate(self.sample_rate);
        self.body_env.set_sample_rate(self.sample_rate);
        self.over_env.set_sample_rate(self.sample_rate);
        self.noise_env.set_sample_rate(self.sample_rate);
        self.click.set_sample_rate(self.sample_rate);
        self.update_noise_filter(self.noise_tone);
        self.dc = DcBlocker::new(DC_HZ, self.sample_rate);
    }

    fn specs() -> &'static [ParamSpec] {
        &SPECS
    }

    fn set_parameter(&mut self, id: ParamId, norm: f32) {
        if self.values.set(id, norm).is_some() {
            self.sync();
        }
    }

    fn set_param_mod(&mut self, id: ParamId, offset: f32) {
        if self.values.set_offset(id, offset).is_some() {
            self.sync();
        }
    }

    fn get_parameter(&self, id: ParamId) -> Option<f32> {
        self.values.get(id)
    }

    fn set_params(&mut self, params: &DrumParams) {
        self.params = *params;
    }

    fn trigger(&mut self, note: u8, velocity: f32, rng: &mut Rng) {
        let sens = self.params.velocity_sens.clamp(0.0, 1.0);
        let humanize = self.params.humanize.clamp(0.0, 1.0);
        // Humanize: ±10 cents of pitch and ±5 % of decay at full amount.
        let cents = humanize * 10.0 * rng.bipolar();
        let decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();

        let transpose = if self.keytrack {
            (note as f32 - REFERENCE_NOTE as f32) / 12.0
        } else {
            0.0
        };
        self.hit_base = self.tune_hz * 2f32.powf(transpose + cents / 1200.0);

        // Velocity: softer hits get less sweep and a darker skin, scaled by sensitivity.
        let soft = 1.0 - velocity.clamp(0.0, 1.0);
        self.hit_sweep_st = self.sweep_st * (1.0 - VELOCITY_SWEEP_LOSS * sens * soft);
        let noise_hz = self.noise_tone * 2f32.powf(-VELOCITY_NOISE_OCTAVES * sens * soft);
        self.update_noise_filter(noise_hz);

        let decay = (self.decay * decay_scale).max(1e-4);
        self.body_env.set_decay(decay);
        self.over_env.set_decay(decay * OVERTONE_DECAY_RATIO);
        self.noise_env
            .set_decay((decay * NOISE_DECAY_RATIO).min(NOISE_MAX_DECAY));

        let click_hz = (self.hit_base * 8.0).clamp(1_000.0, 8_000.0);
        let tone_norm = (click_hz - 1_000.0) / 7_000.0;
        self.click.set_type(ClickType::Noise);
        self.click.set_tone(click_hz, 0.010 - 0.008 * tone_norm);

        self.body_osc.reset();
        self.over_osc.reset();
        self.pitch_env.trigger();
        self.body_env.trigger();
        if self.overtone_level > 0.0 {
            self.over_env.trigger();
        }
        if self.click_level > 0.0 {
            self.click.trigger();
        }
        if self.noise_level > 0.0 {
            self.noise.reset(NOISE_SEED);
            self.noise_filter.reset();
            self.noise_env.trigger();
        }
    }

    fn render(&mut self, out: &mut [f32]) {
        if !self.is_active() {
            return;
        }
        let sr = self.sample_rate;

        if self.body_env.is_active() || self.over_env.is_active() {
            for chunk in out.chunks_mut(BODY_CHUNK) {
                let n = chunk.len();
                for i in 0..n {
                    let pitch = self.pitch_env.process_sample();
                    let amp = self.body_env.process_sample();
                    let hz = if pitch > 0.0 {
                        sweep_hz(self.hit_base, self.hit_sweep_st, pitch)
                    } else {
                        self.hit_base
                    };
                    let mut x = self.body_osc.next(SweepShape::Sine, hz, sr) * amp;
                    if self.over_env.is_active() {
                        let over_amp = self.over_env.process_sample();
                        x += self
                            .over_osc
                            .next(SweepShape::Sine, hz * self.overtone_ratio, sr)
                            * over_amp
                            * self.overtone_level;
                    }
                    self.scratch[i] = x;
                }
                self.drive.process(&mut self.scratch[..n]);
                for (o, &s) in chunk.iter_mut().zip(&self.scratch[..n]) {
                    *o += s;
                }
            }
        }

        // Skin: click plus band-passed noise, added after the drive.
        self.click.render(out, self.click_level);
        if self.noise_env.is_active() {
            for sample in out.iter_mut() {
                let env = self.noise_env.process_sample();
                let x = self.noise_filter.process(
                    self.noise.next(),
                    FilterMode::Bp12,
                    &self.noise_coefs,
                    self.noise_comp,
                    NOISE_RESONANCE,
                );
                *sample += x * env * self.noise_level;
            }
        }

        for sample in out.iter_mut() {
            *sample = self.dc.process(*sample);
        }
    }

    fn release(&mut self) {}

    fn is_active(&self) -> bool {
        self.body_env.is_active()
            || self.over_env.is_active()
            || self.click.is_active()
            || self.noise_env.is_active()
    }

    fn reset(&mut self) {
        self.pitch_env.reset();
        self.body_env.reset();
        self.over_env.reset();
        self.noise_env.reset();
        self.click.reset();
        self.noise_filter.reset();
        self.noise.reset(NOISE_SEED);
        self.body_osc.reset();
        self.over_osc.reset();
        self.drive.reset();
        self.dc.reset();
    }

    fn device_id() -> &'static str {
        "sonara.builtin.tom"
    }

    fn device_name() -> &'static str {
        "Tom"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{instantaneous_freq, spectrum_db};

    const SR: f32 = 48_000.0;

    fn set_real(voice: &mut TomVoice, id: ParamId, real: f32) {
        let spec = TomVoice::specs()
            .iter()
            .find(|s| s.id == id)
            .expect("parameter exists");
        voice.set_parameter(id, spec.to_norm(real));
    }

    fn voice() -> TomVoice {
        let mut v = TomVoice::new(SR);
        v.set_params(&DrumParams {
            velocity_sens: 0.0,
            output_db: 0.0,
            humanize: 0.0,
        });
        v
    }

    fn render(v: &mut TomVoice, frames: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; frames];
        for chunk in out.chunks_mut(512) {
            v.render(chunk);
        }
        out
    }

    /// Frequency of the largest spectrum bin, with parabolic refinement unnecessary at this
    /// bin width (about 3 Hz).
    fn peak_hz(signal: &[f32]) -> f32 {
        let db = spectrum_db(signal);
        let bin = SR / signal.len() as f32;
        let (i, _) = db
            .iter()
            .enumerate()
            .skip(1)
            .fold((1, f32::MIN), |m, (i, &v)| if v > m.1 { (i, v) } else { m });
        i as f32 * bin
    }

    /// Largest level within ±3 % of `hz`.
    fn level_near(db: &[f32], hz: f32) -> f32 {
        let bin = SR / (2.0 * (db.len() - 1) as f32);
        let lo = ((hz * 0.97) / bin).floor() as usize;
        let hi = ((hz * 1.03) / bin).ceil() as usize;
        db[lo..=hi].iter().copied().fold(f32::MIN, f32::max)
    }

    /// The spectral peak after the sweep sits on Tune.
    #[test]
    fn peak_is_the_tune() {
        for tune in [100.0f32, 200.0, 400.0] {
            let mut v = voice();
            set_real(&mut v, TUNE, tune);
            v.trigger(45, 1.0, &mut Rng::new(1));
            let sig = render(&mut v, (0.1 * SR) as usize + 16_384);
            let f = peak_hz(&sig[(0.1 * SR) as usize..]);
            assert!((f - tune).abs() / tune < 0.03, "tune {tune}: peak {f}");
        }
    }

    /// Overtone at 100 % rings at Tune x ratio; at 0 % there is nothing there.
    #[test]
    fn overtone_adds_a_second_mode() {
        let tune = 110.0;
        let over_hz = tune * 1.593;
        let analyse = |overtone: f32| {
            let mut v = voice();
            set_real(&mut v, OVERTONE, overtone);
            set_real(&mut v, CLICK, 0.0);
            set_real(&mut v, NOISE, 0.0);
            v.trigger(45, 1.0, &mut Rng::new(1));
            let sig = render(&mut v, 24_000);
            let db = spectrum_db(&sig[2_400..2_400 + 16_384]);
            (level_near(&db, over_hz), level_near(&db, tune))
        };
        let (over_full, fund_full) = analyse(100.0);
        let (over_none, fund_none) = analyse(0.0);
        assert!(
            over_full > fund_full - 30.0,
            "overtone only {:.1} dB below the fundamental",
            fund_full - over_full
        );
        assert!(
            fund_none - over_none > 40.0,
            "overtone-off leaves {:.1} dB",
            fund_none - over_none
        );
    }

    /// Keytrack transposes from the reference note.
    #[test]
    fn keytrack_follows_the_note() {
        let mut v = voice();
        set_real(&mut v, KEYTRACK, 1.0);
        v.trigger(45, 1.0, &mut Rng::new(1));
        let a = render(&mut v, (0.1 * SR) as usize + 16_384);
        let fa = peak_hz(&a[(0.1 * SR) as usize..]);
        v.reset();
        v.trigger(57, 1.0, &mut Rng::new(1));
        let b = render(&mut v, (0.1 * SR) as usize + 16_384);
        let fb = peak_hz(&b[(0.1 * SR) as usize..]);
        assert!((fb / fa - 2.0).abs() < 0.06, "{fa} -> {fb}");
        assert!((fa - 110.0).abs() / 110.0 < 0.03, "{fa}");
    }

    /// Sweep 0 keeps the pitch constant from the first milliseconds on.
    #[test]
    fn no_sweep_means_constant_pitch() {
        let mut v = voice();
        set_real(&mut v, TUNE, 400.0);
        set_real(&mut v, SWEEP, 0.0);
        set_real(&mut v, OVERTONE, 0.0);
        set_real(&mut v, CLICK, 0.0);
        set_real(&mut v, NOISE, 0.0);
        v.trigger(45, 1.0, &mut Rng::new(1));
        let sig = render(&mut v, (0.2 * SR) as usize);
        let ms = |t: f32| (t * 0.001 * SR) as usize;
        let early = instantaneous_freq(&sig[..ms(15.0)], SR);
        let late = instantaneous_freq(&sig[ms(140.0)..ms(155.0)], SR);
        assert!((early - late).abs() / late < 0.02, "{early} vs {late}");

        // Sanity: with a sweep the start is clearly higher.
        set_real(&mut v, SWEEP, 12.0);
        v.reset();
        v.trigger(45, 1.0, &mut Rng::new(1));
        let swept = render(&mut v, (0.2 * SR) as usize);
        let start = instantaneous_freq(&swept[..ms(15.0)], SR);
        assert!(start > late * 1.2, "{start} vs {late}");
    }

    #[test]
    fn identical_hits_are_sample_identical_with_a_fixed_seed() {
        let params = DrumParams {
            velocity_sens: 0.5,
            output_db: 0.0,
            humanize: 1.0,
        };
        let mut a = TomVoice::new(SR);
        let mut b = TomVoice::new(SR);
        a.set_params(&params);
        b.set_params(&params);
        a.trigger(45, 0.8, &mut Rng::new(2_024));
        b.trigger(45, 0.8, &mut Rng::new(2_024));
        let out_a = render(&mut a, 12_000);
        let out_b = render(&mut b, 12_000);
        assert_eq!(out_a, out_b);
        assert!(out_a.iter().any(|&x| x != 0.0));
        assert!(out_a.iter().all(|x| x.is_finite()));
    }
}
