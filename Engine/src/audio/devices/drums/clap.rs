//! Clap drum voice (spec 013, Phase 4): `sonara.builtin.clap`.
//!
//! One white-noise source is band-passed (SVF `Bp12` at Tone/Resonance). The filtered noise is
//! shaped by the sum of two separate envelopes: a [`BurstEnvelope`] for the hands (Burst Count,
//! Spread, Burst Decay) and a [`OneShotEnvelope`] tail for the room (Tail Level, Tail Decay),
//! summed rather than folded together. A [`DriveStage`] saturates the mono sum when Drive > 0.
//!
//! Everything is preallocated in [`ClapVoice::new`]; [`ClapVoice::render`] runs on the audio
//! callback and never allocates, locks, blocks or logs.

use super::layers::DriveStage;
use super::params::GLOBAL_SPECS;
use super::{DrumParams, DrumVoice};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{ParamId, ParamValue};
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{
    BurstEnvelope, FilterMode, OneShotEnvelope, Rng, Svf, SvfCoefs, WhiteNoise,
};

// Parameter IDs, grouped in blocks of ten per module.
pub const BURST_COUNT: ParamId = 0;
pub const BURST_SPREAD: ParamId = 1;
pub const BURST_DECAY: ParamId = 2;
pub const BURST_RANDOMNESS: ParamId = 3;
pub const TONE: ParamId = 10;
pub const TONE_RESONANCE: ParamId = 11;
pub const TAIL_LEVEL: ParamId = 20;
pub const TAIL_DECAY: ParamId = 21;
pub const BODY_DRIVE: ParamId = 30;

/// Burst Count labels; the real value is the choice index, so "4" is index 3.
const BURST_CHOICES: &[&str] = &["1", "2", "3", "4", "5", "6"];

const BURST_SPECS: [ParamSpec; 4] = [
    spec(
        BURST_COUNT,
        "Burst Count",
        "Burst",
        "",
        Kind::Enum(BURST_CHOICES),
        3.0,
    ),
    spec(
        BURST_SPREAD,
        "Burst Spread",
        "Burst",
        "s",
        linear(0.003, 0.03),
        0.01,
    ),
    spec(
        BURST_DECAY,
        "Burst Decay",
        "Burst",
        "s",
        linear(0.001, 0.02),
        0.006,
    ),
    spec(
        BURST_RANDOMNESS,
        "Randomness",
        "Burst",
        "",
        linear(0.0, 1.0),
        0.2,
    ),
];

const TONE_SPECS: [ParamSpec; 2] = [
    spec(TONE, "Tone", "Tone", "Hz", log(500.0, 5000.0), 1200.0),
    spec(
        TONE_RESONANCE,
        "Resonance",
        "Tone",
        "",
        linear(0.0, 1.0),
        0.4,
    ),
];

const TAIL_SPECS: [ParamSpec; 2] = [
    spec(TAIL_LEVEL, "Tail Level", "Tail", "", linear(0.0, 1.0), 0.6),
    spec(TAIL_DECAY, "Tail Decay", "Tail", "s", log(0.03, 2.0), 0.25),
];

const BODY_SPECS: [ParamSpec; 1] = [spec(
    BODY_DRIVE,
    "Drive",
    "Body",
    "dB",
    linear(0.0, 24.0),
    0.0,
)];

/// Own parameters (9) in module order.
const OWN: [ParamSpec; 9] = flatten(&[&BURST_SPECS, &TONE_SPECS, &TAIL_SPECS, &BODY_SPECS]);
/// Own plus the shared global block (IDs 90–92).
const SPECS: [ParamSpec; 12] = flatten(&[&OWN, &GLOBAL_SPECS]);
const SLOTS: [u8; 93] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Fixed seed so every hit's noise is identical; a retrigger sounds the same.
const NOISE_SEED: u32 = 0x0c1a_900d;
/// Render is chunked into pieces this size so any block length works with a fixed scratch.
const CHUNK: usize = 256;

/// The clap: band-passed noise shaped by a burst envelope plus a room tail, then driven.
pub struct ClapVoice {
    noise: WhiteNoise,
    svf: Svf,
    coefs: SvfCoefs,
    comp_coef: f32,
    resonance: f32,
    bursts: BurstEnvelope,
    tail: OneShotEnvelope,
    drive: DriveStage,

    values: ParamValues<12>,
    params: DrumParams,
    sample_rate: f32,

    // Decoded parameters, refreshed in `sync`.
    count: usize,
    spread_s: f32,
    burst_decay_s: f32,
    randomness: f32,
    tone_hz: f32,
    tail_level: f32,
    tail_decay_s: f32,
    drive_db: f32,

    /// Preallocated mono scratch; never grown on the audio path.
    scratch: Vec<f32>,
}

impl ClapVoice {
    /// Decode the parameter table into the fields the render path reads.
    fn sync(&mut self) {
        self.count = self.values.real(BURST_COUNT).unwrap_or(3.0) as usize + 1;
        self.spread_s = self.values.real(BURST_SPREAD).unwrap_or(0.01);
        self.burst_decay_s = self.values.real(BURST_DECAY).unwrap_or(0.006);
        self.randomness = self.values.real(BURST_RANDOMNESS).unwrap_or(0.2);
        self.tone_hz = self.values.real(TONE).unwrap_or(1200.0);
        self.resonance = self.values.real(TONE_RESONANCE).unwrap_or(0.4);
        self.tail_level = self.values.real(TAIL_LEVEL).unwrap_or(0.6);
        self.tail_decay_s = self.values.real(TAIL_DECAY).unwrap_or(0.25);
        self.drive_db = self.values.real(BODY_DRIVE).unwrap_or(0.0);

        self.bursts
            .configure(self.count, self.spread_s, self.burst_decay_s, 0.0);
        self.tail.set_decay(self.tail_decay_s);
        self.drive.set_drive_db(self.drive_db);
        self.set_tone(self.tone_hz);
    }

    /// Rebuild the band-pass coefficients for `hz`. Cutoff and resonance are static within a
    /// hit, so this runs only on a parameter change, a rate change and at `trigger`.
    fn set_tone(&mut self, hz: f32) {
        let hz = hz.max(1.0);
        let mode = FilterMode::Bp12;
        let g = cutoff_to_g(hz, self.sample_rate);
        let k = resonance_to_k(self.resonance, mode);
        self.coefs = SvfCoefs::new(g, k, mode);
        self.comp_coef = compensation_coef(hz, self.sample_rate);
    }
}

impl DrumVoice for ClapVoice {
    fn new(sample_rate: f32) -> Self {
        let mut tail = OneShotEnvelope::new(sample_rate);
        tail.set_attack(0.0);
        tail.set_hold(0.0);
        tail.set_curve(0.0);

        let mut voice = Self {
            noise: WhiteNoise::new(NOISE_SEED),
            svf: Svf::new(),
            coefs: SvfCoefs::default(),
            comp_coef: 0.0,
            resonance: 0.4,
            bursts: BurstEnvelope::new(sample_rate),
            tail,
            drive: DriveStage::new(),
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            sample_rate,
            count: 4,
            spread_s: 0.01,
            burst_decay_s: 0.006,
            randomness: 0.2,
            tone_hz: 1200.0,
            tail_level: 0.6,
            tail_decay_s: 0.25,
            drive_db: 0.0,
            scratch: vec![0.0; CHUNK],
        };
        voice.sync();
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(1.0);
        self.bursts.set_sample_rate(self.sample_rate);
        self.tail.set_sample_rate(self.sample_rate);
        self.sync();
    }

    fn specs() -> &'static [ParamSpec] {
        &SPECS
    }

    fn set_parameter(&mut self, id: ParamId, norm: ParamValue) {
        if self.values.set(id, norm).is_some() {
            self.sync();
        }
    }

    fn set_param_mod(&mut self, id: ParamId, offset: f32) {
        if self.values.set_offset(id, offset).is_some() {
            self.sync();
        }
    }

    fn get_parameter(&self, id: ParamId) -> Option<ParamValue> {
        self.values.get(id)
    }

    fn set_params(&mut self, params: &DrumParams) {
        self.params = *params;
    }

    fn trigger(&mut self, _note: u8, velocity: f32, rng: &mut Rng) {
        let humanize = self.params.humanize;
        // ±10 cents is inaudible on noise, but drawing it keeps the humanize draws in the same
        // order as the other drums.
        let _cents = humanize * 10.0 * rng.bipolar();
        let decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();

        // Velocity brightens the band-pass up to half an octave, scaled by sensitivity so a
        // sensitivity of 0 leaves the hit identical at any velocity.
        let velocity = velocity.max(0.0);
        let bright = 2f32.powf(0.5 * self.params.velocity_sens * velocity);
        self.set_tone(self.tone_hz * bright);

        self.tail
            .set_decay((self.tail_decay_s * decay_scale).max(1e-4));
        self.noise.reset(NOISE_SEED);
        self.svf.reset();
        self.bursts.trigger(rng, self.randomness);
        self.tail.reset();
        self.tail.trigger();
    }

    fn render(&mut self, out: &mut [f32]) {
        if !self.is_active() {
            return;
        }
        for chunk in out.chunks_mut(CHUNK) {
            if !self.is_active() {
                break;
            }
            let n = chunk.len();
            for i in 0..n {
                let burst = self.bursts.process_sample();
                let tail = self.tail.process_sample();
                let x = self.noise.next();
                let filtered = self.svf.process(
                    x,
                    FilterMode::Bp12,
                    &self.coefs,
                    self.comp_coef,
                    self.resonance,
                );
                self.scratch[i] = filtered * (burst + tail * self.tail_level);
            }
            self.drive.process(&mut self.scratch[..n]);
            for (o, s) in chunk.iter_mut().zip(&self.scratch[..n]) {
                *o += *s;
            }
        }
    }

    /// One-shot: note-off is ignored.
    fn release(&mut self) {}

    fn is_active(&self) -> bool {
        self.bursts.is_active() || self.tail.is_active()
    }

    fn reset(&mut self) {
        self.noise.reset(NOISE_SEED);
        self.svf.reset();
        self.bursts.reset();
        self.tail.reset();
        self.drive.reset();
    }

    fn device_id() -> &'static str {
        "sonara.builtin.clap"
    }

    fn device_name() -> &'static str {
        "Clap"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::time_to_db;

    const SR: f32 = 48_000.0;

    fn set_real(voice: &mut ClapVoice, id: ParamId, real: f32) {
        let norm = TABLE.spec(id).unwrap().to_norm(real);
        voice.set_parameter(id, norm);
    }

    /// Burst onsets, read from a short backward moving average of the rectified render. The
    /// burst envelope is front-loaded and the gaps are silent, so the average first crosses a
    /// tiny threshold on the burst's first sample.
    fn burst_starts(signal: &[f32]) -> Vec<usize> {
        const W: usize = 16;
        let mut env = Vec::with_capacity(signal.len());
        let mut sum = 0.0f32;
        for (i, &x) in signal.iter().enumerate() {
            sum += x.abs();
            if i >= W {
                sum -= signal[i - W].abs();
            }
            env.push(sum / (i + 1).min(W) as f32);
        }
        let max = env.iter().cloned().fold(0.0f32, f32::max);
        if max <= 0.0 {
            return Vec::new();
        }
        // A tiny threshold: the gaps are numerically silent, so the average first rises on
        // the burst's first sample regardless of that sample's noise value.
        let threshold = max * 1.0e-6;
        let mut starts = Vec::new();
        let mut above = false;
        for (i, &e) in env.iter().enumerate() {
            if e > threshold && !above {
                starts.push(i);
                above = true;
            } else if e <= threshold {
                above = false;
            }
        }
        starts
    }

    /// Rectified one-pole envelope of a mono signal (about 1 ms).
    fn envelope(signal: &[f32], sample_rate: f32) -> Vec<f32> {
        let coef = 1.0 - (-1.0 / (0.001 * sample_rate)).exp();
        let mut e = 0.0f32;
        signal
            .iter()
            .map(|&x| {
                e += coef * (x.abs() - e);
                e
            })
            .collect()
    }

    /// Configure a clean burst train: 4 bursts, 30 ms apart, 1 ms decay, no tail.
    fn burst_train(voice: &mut ClapVoice, randomness: f32) {
        set_real(voice, BURST_COUNT, 3.0);
        set_real(voice, BURST_SPREAD, 0.03);
        set_real(voice, BURST_DECAY, 0.001);
        set_real(voice, BURST_RANDOMNESS, randomness);
        set_real(voice, TAIL_LEVEL, 0.0);
    }

    #[test]
    fn burst_count_and_spread_match_the_settings() {
        let mut voice = ClapVoice::new(SR);
        burst_train(&mut voice, 0.0);
        let mut rng = Rng::new(1);
        voice.trigger(60, 1.0, &mut rng);

        let mut buf = vec![0.0f32; (SR * 0.2) as usize];
        voice.render(&mut buf);
        let starts = burst_starts(&buf);
        assert_eq!(starts.len(), 4, "starts: {starts:?}");

        let spread_samples = (0.03 * SR).round() as i64;
        for pair in starts.windows(2) {
            let gap = (pair[1] as i64 - pair[0] as i64 - spread_samples).abs();
            assert!(gap <= 1, "gap {gap} in {starts:?}");
        }
    }

    #[test]
    fn randomness_zero_is_deterministic_and_randomness_changes_spacing() {
        let mut voice = ClapVoice::new(SR);
        burst_train(&mut voice, 0.0);
        let n = (SR * 0.2) as usize;

        let mut rng = Rng::new(42);
        voice.trigger(60, 1.0, &mut rng);
        let mut first = vec![0.0f32; n];
        voice.render(&mut first);

        voice.reset();
        let mut rng = Rng::new(42);
        voice.trigger(60, 1.0, &mut rng);
        let mut second = vec![0.0f32; n];
        voice.render(&mut second);
        assert_eq!(first, second, "randomness 0 must be deterministic");

        set_real(&mut voice, BURST_RANDOMNESS, 0.5);

        voice.reset();
        let mut rng = Rng::new(7);
        voice.trigger(60, 1.0, &mut rng);
        let mut a = vec![0.0f32; n];
        voice.render(&mut a);

        voice.reset();
        let mut rng = Rng::new(8);
        voice.trigger(60, 1.0, &mut rng);
        let mut b = vec![0.0f32; n];
        voice.render(&mut b);

        let gaps =
            |s: &[f32]| -> Vec<usize> { burst_starts(s).windows(2).map(|w| w[1] - w[0]).collect() };
        let (ga, gb) = (gaps(&a), gaps(&b));
        assert_eq!(ga.len(), 3, "{ga:?}");
        assert_ne!(ga, gb, "randomness should change the spacing");
    }

    #[test]
    fn tail_decays_to_minus_60_db_within_five_percent() {
        let mut voice = ClapVoice::new(SR);
        set_real(&mut voice, BURST_COUNT, 0.0); // one burst
        set_real(&mut voice, BURST_DECAY, 0.001);
        set_real(&mut voice, BURST_RANDOMNESS, 0.0);
        set_real(&mut voice, TAIL_LEVEL, 1.0);
        set_real(&mut voice, TAIL_DECAY, 0.3);

        let mut rng = Rng::new(3);
        voice.trigger(60, 1.0, &mut rng);
        let mut buf = vec![0.0f32; (SR * 1.0) as usize];
        voice.render(&mut buf);

        // The tail rides on noise, so measure its envelope; skip the 1 ms burst (and the
        // filter ringing after it) so its peak does not lift the −60 dB reference.
        let env = envelope(&buf, SR);
        let skip = (SR * 0.005) as usize;
        let measured = skip as f32 / SR + time_to_db(&env[skip..], -60.0, SR);
        assert!(
            (measured - 0.3).abs() / 0.3 < 0.05,
            "decay {measured} s vs 0.3 s"
        );
    }
}
