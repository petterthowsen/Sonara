//! Cowbell (`sonara.builtin.cowbell`, spec 056, Phase 2): the 808 recipe.
//!
//! Two band-limited pulse oscillators (PW 0.5) at **Tune** and **Tune x Spread**, summed at equal
//! level, through a resonant band-pass at **Tone** (**Ring** is its resonance) and the
//! [`DriveStage`]. The amplitude envelope has two stages: a sharp **Strike** (a 15 ms decay) and a
//! longer tail (**Decay**), mixed `Strike * fast + (1 - Strike) * slow`. Softer hits lower Tone by
//! up to an octave, scaled by Velocity sensitivity. Everything is preallocated in `new()`.

use super::layers::DriveStage;
use super::params::GLOBAL_SPECS;
use super::{DrumParams, DrumVoice};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{FilterMode, OneShotEnvelope, Oscillator, Rng, Svf, SvfCoefs};

const TUNE: ParamId = 0;
const DECAY: ParamId = 1;
const SPREAD: ParamId = 2;
const TONE: ParamId = 10;
const RING: ParamId = 11;
const STRIKE: ParamId = 12;
const DRIVE: ParamId = 13;

const OWN: [ParamSpec; 7] = [
    spec(TUNE, "Tune", "Cowbell", "Hz", log(200.0, 1_200.0), 540.0),
    spec(DECAY, "Decay", "Cowbell", "s", log(0.05, 1.5), 0.3),
    spec(
        SPREAD,
        "Spread",
        "Cowbell",
        "\u{d7}",
        linear(1.2, 1.8),
        1.48,
    ),
    spec(TONE, "Tone", "Tone", "Hz", log(500.0, 8_000.0), 2_000.0),
    spec(RING, "Ring", "Tone", "%", linear(0.0, 100.0), 40.0),
    spec(STRIKE, "Strike", "Tone", "%", linear(0.0, 100.0), 60.0),
    spec(DRIVE, "Drive", "Tone", "dB", linear(0.0, 24.0), 0.0),
];
const SPECS: [ParamSpec; 10] = flatten(&[&OWN, &GLOBAL_SPECS]);
const SLOTS: [u8; 93] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Internal render chunk. Any `render` length is cut into pieces of at most this many frames.
const CHUNK: usize = 512;
/// Decay of the sharp strike stage.
const STRIKE_DECAY: f32 = 0.015;
/// Softer hits lower Tone by up to an octave, scaled by Velocity sensitivity.
const VELOCITY_BRIGHTNESS_OCTAVES: f32 = 1.0;

/// The 808-style cowbell voice.
pub struct CowbellVoice {
    sample_rate: f32,
    values: ParamValues<10>,
    params: DrumParams,

    oscs: [Oscillator; 2],
    bp: Svf,
    fast_env: OneShotEnvelope,
    slow_env: OneShotEnvelope,
    drive: DriveStage,

    tune: f32,
    spread: f32,
    decay: f32,
    tone: f32,
    resonance: f32,
    strike: f32,
    hit_tone_hz: f32,

    acc: Vec<f32>,
    osc_buf: Vec<f32>,
}

impl CowbellVoice {
    fn sync_params(&mut self) {
        self.tune = self.values.real(TUNE).unwrap_or(540.0);
        self.decay = self.values.real(DECAY).unwrap_or(0.3);
        self.spread = self.values.real(SPREAD).unwrap_or(1.48);
        self.tone = self.values.real(TONE).unwrap_or(2_000.0);
        self.resonance = self.values.real(RING).unwrap_or(40.0) / 100.0;
        self.strike = self.values.real(STRIKE).unwrap_or(60.0) / 100.0;
        self.fast_env.set_decay(STRIKE_DECAY);
        self.slow_env.set_decay(self.decay);
        self.drive
            .set_drive_db(self.values.real(DRIVE).unwrap_or(0.0));
    }
}

impl DrumVoice for CowbellVoice {
    fn new(sample_rate: f32) -> Self {
        let mut voice = Self {
            sample_rate,
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            oscs: std::array::from_fn(|_| Oscillator::new()),
            bp: Svf::new(),
            fast_env: OneShotEnvelope::new(sample_rate),
            slow_env: OneShotEnvelope::new(sample_rate),
            drive: DriveStage::new(),
            tune: 540.0,
            spread: 1.48,
            decay: 0.3,
            tone: 2_000.0,
            resonance: 0.4,
            strike: 0.6,
            hit_tone_hz: 2_000.0,
            acc: vec![0.0; CHUNK],
            osc_buf: vec![0.0; CHUNK],
        };
        voice.sync_params();
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        self.fast_env.set_sample_rate(sample_rate);
        self.slow_env.set_sample_rate(sample_rate);
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

        let soft = 1.0 - velocity.clamp(0.0, 1.0);
        let bright = 2f32.powf(-VELOCITY_BRIGHTNESS_OCTAVES * sens * soft);
        self.hit_tone_hz = (self.tone * bright).clamp(20.0, self.sample_rate * 0.45);

        let freqs = [
            self.tune * pitch_scale,
            self.tune * self.spread * pitch_scale,
        ];
        for (osc, hz) in self.oscs.iter_mut().zip(freqs) {
            osc.set_frequency(hz as f64, self.sample_rate as f64);
            osc.set_pulse_width(0.5);
            osc.reset();
        }
        self.bp.reset();
        self.slow_env
            .set_decay((self.decay * decay_scale).clamp(1e-4, 30.0));
        // A stage with no weight stays idle, so Strike 100 % ends at the strike's decay.
        if self.strike > 0.0 {
            self.fast_env.trigger();
        }
        if self.strike < 1.0 {
            self.slow_env.trigger();
        }
    }

    fn render(&mut self, out: &mut [f32]) {
        if !self.is_active() {
            return;
        }
        let sr = self.sample_rate;
        let coefs = SvfCoefs::new(
            cutoff_to_g(self.hit_tone_hz, sr),
            resonance_to_k(self.resonance, FilterMode::Bp12),
            FilterMode::Bp12,
        );
        let comp = compensation_coef(self.hit_tone_hz, sr);
        let (strike, resonance) = (self.strike, self.resonance);

        let mut pos = 0;
        while pos < out.len() {
            let n = (out.len() - pos).min(CHUNK);
            self.oscs[0].process_block(1, &mut self.acc[..n], n);
            self.oscs[1].process_block(1, &mut self.osc_buf[..n], n);
            for j in 0..n {
                let x = 0.5 * (self.acc[j] + self.osc_buf[j]);
                let band = self
                    .bp
                    .process(x, FilterMode::Bp12, &coefs, comp, resonance);
                let env = strike * self.fast_env.process_sample()
                    + (1.0 - strike) * self.slow_env.process_sample();
                self.acc[j] = band * env;
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
        self.fast_env.is_active() || self.slow_env.is_active()
    }

    fn reset(&mut self) {
        self.fast_env.reset();
        self.slow_env.reset();
        self.bp.reset();
        self.drive.reset();
        for osc in &mut self.oscs {
            osc.reset();
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.cowbell"
    }

    fn device_name() -> &'static str {
        "Cowbell"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{rms, spectrum_db};

    const SR: f32 = 48_000.0;

    fn set_real(voice: &mut CowbellVoice, id: ParamId, real: f32) {
        let spec = CowbellVoice::specs()
            .iter()
            .find(|s| s.id == id)
            .expect("parameter exists");
        voice.set_parameter(id, spec.to_norm(real));
    }

    fn render(v: &mut CowbellVoice, frames: usize) -> Vec<f32> {
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

    /// Both oscillators show up as spectral peaks, well above the level between them.
    #[test]
    fn peaks_at_tune_and_tune_times_spread() {
        let mut v = CowbellVoice::new(SR);
        set_real(&mut v, DECAY, 1.0);
        v.trigger(56, 1.0, &mut Rng::new(1));
        let sig = render(&mut v, 24_000);
        let db = spectrum_db(&sig[2_000..2_000 + 16_384]);
        let spread = 1.48;
        let between = level_near(&db, 540.0 * 1.22);
        for hz in [540.0, 540.0 * spread] {
            let peak = level_near(&db, hz);
            assert!(
                peak > between + 10.0,
                "{hz} Hz peak {peak:.1} dB vs {between:.1} dB between"
            );
        }
    }

    /// Strike 100 % leaves almost nothing at 200 ms; Strike 0 % still rings.
    #[test]
    fn strike_shortens_the_tail() {
        let tail_rms = |strike: f32| {
            let mut v = CowbellVoice::new(SR);
            set_real(&mut v, STRIKE, strike);
            v.trigger(56, 1.0, &mut Rng::new(1));
            let sig = render(&mut v, 12_000);
            rms(&sig[9_000..10_000])
        };
        let (sharp, long) = (tail_rms(100.0), tail_rms(0.0));
        let diff_db = 20.0 * (long.max(1e-12) / sharp.max(1e-12)).log10();
        assert!(diff_db >= 20.0, "only {diff_db:.1} dB less energy");
    }

    #[test]
    fn identical_hits_are_sample_identical_with_a_fixed_seed() {
        let params = DrumParams {
            velocity_sens: 0.5,
            output_db: 0.0,
            humanize: 1.0,
        };
        let mut a = CowbellVoice::new(SR);
        let mut b = CowbellVoice::new(SR);
        a.set_params(&params);
        b.set_params(&params);
        a.trigger(56, 0.8, &mut Rng::new(2_024));
        b.trigger(56, 0.8, &mut Rng::new(2_024));
        let out_a = render(&mut a, 12_000);
        let out_b = render(&mut b, 12_000);
        assert_eq!(out_a, out_b);
        assert!(out_a.iter().any(|&x| x != 0.0), "voice produced silence");
        assert!(out_a.iter().all(|x| x.is_finite()));
    }
}
