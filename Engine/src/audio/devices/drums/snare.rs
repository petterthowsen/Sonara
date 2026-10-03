//! Snare drum (spec 013, Phase 2): `sonara.builtin.snare`.
//!
//! Three layers are summed:
//! - **Tone**: two sine modes (the drumhead). They share one pitch envelope — a fast drop from
//!   `base * 2^(Sweep/12)` down to `base` over Sweep Time — and each has its own amplitude
//!   envelope. Mode 2 is tuned to `Tune * Mode 2 Ratio` and decays `0.7x` as fast; Mode Balance
//!   crossfades the two.
//! - **Snares**: white noise through a mono SVF, blending a band-pass at Color (Q from Width)
//!   with a high-pass at Color. Width 0 is a narrow band-pass, 1 leans on the high-pass. The
//!   layer has its own decay envelope with a slightly fast curve.
//! - **Snap**: a short [`ClickLayer`] noise transient.
//!
//! Drive is applied to the sum of Tone and Snares only (never the Snap). Velocity brightness,
//! scaled by the shared velocity sensitivity, lifts the Snares Color (up to one octave) and the
//! Snap level, so at sensitivity 0 velocity only changes level (through the host curve).
//!
//! Parameters carry one `module` per Simple View section, using the drum vocabulary the generator
//! (and the Kick) expect: `Body` (Tone, plus Drive, which shapes that sum), `Noise` (Snares),
//! `Click` (Snap) and the shared `Global`. Every section holds at least two controls, so the
//! generated layout has no singleton group.

use super::layers::{ClickLayer, ClickType, DriveStage};
use super::{DrumParams, DrumVoice, GLOBAL_SPECS};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::ParamId;
use crate::audio::dsp::svf::{cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{
    sweep_hz, FilterMode, OneShotEnvelope, Rng, Svf, SvfCoefs, SweepOsc, SweepShape, WhiteNoise,
};

// Parameter IDs, grouped in tens by module.
const TONE_TUNE: ParamId = 0;
const TONE_KEYTRACK: ParamId = 1;
const TONE_DECAY: ParamId = 2;
const TONE_RATIO: ParamId = 3;
const TONE_BALANCE: ParamId = 4;
const TONE_SWEEP: ParamId = 5;
const TONE_SWEEP_TIME: ParamId = 6;
const TONE_LEVEL: ParamId = 7;
const SNARES_LEVEL: ParamId = 10;
const SNARES_DECAY: ParamId = 11;
const SNARES_COLOR: ParamId = 12;
const SNARES_WIDTH: ParamId = 13;
const SNAP_LEVEL: ParamId = 20;
const SNAP_TONE: ParamId = 21;
const BODY_DRIVE: ParamId = 30;

const OWN: [ParamSpec; 15] = [
    spec(TONE_TUNE, "Tune", "Body", "Hz", log(80.0, 400.0), 180.0),
    spec(
        TONE_KEYTRACK,
        "Keytrack",
        "Body",
        "",
        crate::audio::devices::param_table::Kind::Bool,
        0.0,
    ),
    spec(TONE_DECAY, "Decay", "Body", "s", log(0.02, 0.8), 0.15),
    spec(
        TONE_RATIO,
        "Mode 2 Ratio",
        "Body",
        "x",
        linear(1.2, 2.5),
        1.6,
    ),
    spec(
        TONE_BALANCE,
        "Mode Balance",
        "Body",
        "",
        linear(0.0, 1.0),
        0.4,
    ),
    spec(TONE_SWEEP, "Sweep", "Body", "st", linear(0.0, 12.0), 3.0),
    spec(
        TONE_SWEEP_TIME,
        "Sweep Time",
        "Body",
        "s",
        log(0.005, 0.1),
        0.02,
    ),
    spec(TONE_LEVEL, "Level", "Body", "", linear(0.0, 1.0), 0.7),
    spec(SNARES_LEVEL, "Level", "Noise", "", linear(0.0, 1.0), 0.8),
    spec(SNARES_DECAY, "Decay", "Noise", "s", log(0.03, 1.5), 0.22),
    spec(
        SNARES_COLOR,
        "Color",
        "Noise",
        "Hz",
        log(1000.0, 12000.0),
        5000.0,
    ),
    spec(SNARES_WIDTH, "Width", "Noise", "", linear(0.0, 1.0), 0.5),
    spec(SNAP_LEVEL, "Level", "Click", "", linear(0.0, 1.0), 0.4),
    spec(
        SNAP_TONE,
        "Tone",
        "Click",
        "Hz",
        log(2000.0, 10000.0),
        6000.0,
    ),
    spec(BODY_DRIVE, "Drive", "Body", "dB", linear(0.0, 24.0), 0.0),
];
const SPECS: [ParamSpec; 18] = flatten(&[&OWN, &GLOBAL_SPECS]);
const SLOTS: [u8; 100] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Fixed noise seed so every hit of a fresh voice is identical (the snares are a repeated
/// transient, not a free-running bed).
const NOISE_SEED: u32 = 0x51A1_5EED;
/// The Snap transient is its own deterministic noise burst.
const SNAP_SEED: u32 = 0x5A17_0001;
/// Snap decay, in the 1–10 ms window of [`ClickLayer`].
const SNAP_DECAY: f32 = 0.005;
/// Mode 2's amplitude envelope decays this much faster than mode 1's.
const MODE2_DECAY_RATIO: f32 = 0.7;
/// Snares amplitude curve: slightly faster than exponential.
const SNARES_CURVE: f32 = -0.2;
/// Render chunk: bounds the preallocated drive scratch so any block length works.
const CHUNK: usize = 256;

/// MIDI note to frequency, A4 = 69.
#[inline]
fn note_hz(note: u8) -> f32 {
    440.0 * 2f32.powf((note as f32 - 69.0) / 12.0)
}

/// The snare voice: see the module docs for the synthesis.
pub struct SnareVoice {
    values: ParamValues<18>,
    params: DrumParams,
    sample_rate: f32,

    // Tone
    osc1: SweepOsc,
    osc2: SweepOsc,
    pitch_env: OneShotEnvelope,
    amp_env1: OneShotEnvelope,
    amp_env2: OneShotEnvelope,
    tune_hz: f32,
    tune_norm: f32,
    keytrack: bool,
    tone_decay: f32,
    ratio: f32,
    mode_balance: f32,
    sweep_st: f32,
    sweep_time: f32,
    tone_level: f32,
    /// Pitch of this hit, after keytrack and humanize.
    base_hz: f32,

    // Snares
    noise: WhiteNoise,
    svf: Svf,
    snares_env: OneShotEnvelope,
    snares_level: f32,
    snares_decay: f32,
    color_hz: f32,
    width: f32,
    snares_res: f32,
    /// Color with this hit's velocity brightness applied.
    snares_cutoff: f32,
    coefs: SvfCoefs,
    filter_dirty: bool,

    // Snap
    snap: ClickLayer,
    snap_level: f32,
    snap_tone: f32,
    /// Snap Tone as last pushed to the click layer.
    snap_tone_cached: f32,
    /// Snap level with this hit's velocity brightness applied.
    snap_gain: f32,

    // Drive
    drive_stage: DriveStage,
    drive_db: f32,
    /// Drive as last pushed to the drive stage.
    drive_db_cached: f32,

    /// Last trigger's velocity, and the decay multiplier from humanize.
    velocity: f32,
    decay_scale: f32,

    /// Preallocated tone + snares mix, handed to the drive stage in chunks.
    scratch: Vec<f32>,
}

impl SnareVoice {
    /// Read every scalar parameter. Envelope times are re-derived here too, so a parameter change
    /// takes effect on the next block; curves are fixed and only set once in `new`.
    fn sync(&mut self) {
        self.tune_hz = self.values.real(TONE_TUNE).unwrap_or(180.0);
        self.tune_norm = self.values.effective_norm(TONE_TUNE).unwrap_or(0.5);
        self.keytrack = self.values.real(TONE_KEYTRACK).unwrap_or(0.0) >= 0.5;
        self.tone_decay = self.values.real(TONE_DECAY).unwrap_or(0.15);
        self.ratio = self.values.real(TONE_RATIO).unwrap_or(1.6);
        self.mode_balance = self.values.real(TONE_BALANCE).unwrap_or(0.4);
        self.sweep_st = self.values.real(TONE_SWEEP).unwrap_or(3.0);
        self.sweep_time = self.values.real(TONE_SWEEP_TIME).unwrap_or(0.02);
        self.tone_level = self.values.real(TONE_LEVEL).unwrap_or(0.7);
        self.snares_level = self.values.real(SNARES_LEVEL).unwrap_or(0.8);
        self.snares_decay = self.values.real(SNARES_DECAY).unwrap_or(0.22);
        self.color_hz = self.values.real(SNARES_COLOR).unwrap_or(5000.0);
        self.width = self.values.real(SNARES_WIDTH).unwrap_or(0.5);
        self.snap_level = self.values.real(SNAP_LEVEL).unwrap_or(0.4);
        self.snap_tone = self.values.real(SNAP_TONE).unwrap_or(6000.0);
        self.drive_db = self.values.real(BODY_DRIVE).unwrap_or(0.0);

        let res = (1.0 - self.width).clamp(0.0, 1.0);
        if (res - self.snares_res).abs() > 1e-6 {
            self.snares_res = res;
            self.filter_dirty = true;
        }
        self.update_cutoff();

        // Cheap setters are guarded so a per-block `set_params` never rebuilds heavy state.
        if (self.snap_tone - self.snap_tone_cached).abs() > 1e-6 {
            self.snap.set_tone(self.snap_tone, SNAP_DECAY);
            self.snap_tone_cached = self.snap_tone;
        }
        if (self.drive_db - self.drive_db_cached).abs() > 1e-6 {
            self.drive_stage.set_drive_db(self.drive_db);
            self.drive_db_cached = self.drive_db;
        }
        if self.filter_dirty {
            self.update_filter();
        }
        self.apply_env_times();
    }

    /// Envelope times for this hit: humanize scales the decays, mode 2 runs `0.7x` faster.
    fn apply_env_times(&mut self) {
        self.pitch_env.set_attack(0.0);
        self.pitch_env.set_decay(self.sweep_time);
        self.amp_env1.set_attack(0.0);
        self.amp_env1.set_decay(self.tone_decay * self.decay_scale);
        self.amp_env2.set_attack(0.0);
        self.amp_env2
            .set_decay(self.tone_decay * MODE2_DECAY_RATIO * self.decay_scale);
        self.snares_env.set_attack(0.0);
        self.snares_env
            .set_decay(self.snares_decay * self.decay_scale);
    }

    /// Color with velocity brightness: `+sens * v` octaves (0 at sensitivity 0).
    fn update_cutoff(&mut self) {
        let octaves = self.params.velocity_sens * self.velocity;
        let cutoff = self.color_hz * 2f32.powf(octaves);
        if (cutoff - self.snares_cutoff).abs() > 1e-4 {
            self.snares_cutoff = cutoff;
            self.filter_dirty = true;
        }
    }

    /// Rebuild the static SVF coefficients for the current Color and Width.
    fn update_filter(&mut self) {
        let sr = self.sample_rate;
        let g = cutoff_to_g(self.snares_cutoff, sr);
        // Bp12 and Hp12 share their coefficients (neither is a 24 dB mode), so one set drives the
        // single `Svf` that produces both outputs.
        self.coefs = SvfCoefs::new(
            g,
            resonance_to_k(self.snares_res, FilterMode::Bp12),
            FilterMode::Bp12,
        );
        self.filter_dirty = false;
    }
}

impl DrumVoice for SnareVoice {
    fn new(sample_rate: f32) -> Self {
        let mut pitch_env = OneShotEnvelope::new(sample_rate);
        let mut amp_env1 = OneShotEnvelope::new(sample_rate);
        let mut amp_env2 = OneShotEnvelope::new(sample_rate);
        let mut snares_env = OneShotEnvelope::new(sample_rate);
        // Curves are fixed, so the shape tables are built once here and never on the audio path.
        pitch_env.set_curve(0.0);
        amp_env1.set_curve(0.0);
        amp_env2.set_curve(0.0);
        snares_env.set_curve(SNARES_CURVE);

        let snap = {
            let mut snap = ClickLayer::new(sample_rate, SNAP_SEED);
            snap.set_type(ClickType::Noise);
            snap.set_tone(6000.0, SNAP_DECAY);
            snap
        };
        let mut drive_stage = DriveStage::new();
        drive_stage.set_drive_db(0.0);

        let mut voice = Self {
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            sample_rate,
            osc1: SweepOsc::new(),
            osc2: SweepOsc::new(),
            pitch_env,
            amp_env1,
            amp_env2,
            tune_hz: 180.0,
            tune_norm: 0.5,
            keytrack: false,
            tone_decay: 0.15,
            ratio: 1.6,
            mode_balance: 0.4,
            sweep_st: 3.0,
            sweep_time: 0.02,
            tone_level: 0.7,
            base_hz: 180.0,
            noise: WhiteNoise::new(NOISE_SEED),
            svf: Svf::new(),
            snares_env,
            snares_level: 0.8,
            snares_decay: 0.22,
            color_hz: 5000.0,
            width: 0.5,
            snares_res: 0.5,
            snares_cutoff: 5000.0,
            coefs: SvfCoefs::default(),
            filter_dirty: true,
            snap,
            snap_level: 0.4,
            snap_tone: 6000.0,
            snap_tone_cached: 6000.0,
            snap_gain: 0.0,
            drive_stage,
            drive_db: 0.0,
            drive_db_cached: 0.0,
            velocity: 1.0,
            decay_scale: 1.0,
            scratch: vec![0.0; CHUNK],
        };
        voice.sync();
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        self.pitch_env.set_sample_rate(sample_rate);
        self.amp_env1.set_sample_rate(sample_rate);
        self.amp_env2.set_sample_rate(sample_rate);
        self.snares_env.set_sample_rate(sample_rate);
        self.snap.set_sample_rate(sample_rate);
        self.filter_dirty = true;
        self.update_filter();
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
        self.sync();
    }

    fn trigger(&mut self, note: u8, velocity: f32, rng: &mut Rng) {
        let v = velocity.clamp(0.0, 1.0);
        self.velocity = v;

        let humanize = self.params.humanize;
        let cents = humanize * 10.0 * rng.bipolar();
        self.decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();

        // Keytrack off: base is Tune. On: Tune is a ±12 st offset from the incoming note.
        let base = if self.keytrack {
            note_hz(note) * 2f32.powf((self.tune_norm - 0.5) * 2.0)
        } else {
            self.tune_hz
        };
        self.base_hz = base * 2f32.powf(cents / 1200.0);

        self.update_cutoff();
        if self.filter_dirty {
            self.update_filter();
        }
        // Velocity brightness on the Snap level: full at velocity 1, −6 dB at velocity 0, scaled
        // by sensitivity so it vanishes at 0.
        self.snap_gain = self.snap_level * (1.0 - self.params.velocity_sens * 0.5 * (1.0 - v));

        self.apply_env_times();
        self.osc1.reset();
        self.osc2.reset();
        self.noise.reset(NOISE_SEED);
        self.svf.reset();
        self.pitch_env.trigger();
        self.amp_env1.trigger();
        self.amp_env2.trigger();
        self.snares_env.trigger();
        self.snap.trigger();
    }

    fn render(&mut self, out: &mut [f32]) {
        let drive_on = self.drive_db > 0.0;
        let snap_gain = self.snap_gain;
        let sr = self.sample_rate;
        let mb = self.mode_balance;
        let tone_level = self.tone_level;
        let snares_level = self.snares_level;
        let width = self.width;
        let coefs = self.coefs;
        // A layer at Level 0 (or with an idle envelope) is skipped entirely, so it costs nothing
        // and doesn't keep the voice awake. An envelope that is idle at the start of a call stays
        // idle for the whole call, so these flags are safe to hoist out of the loop.
        let tone_on = tone_level > 0.0
            && (self.amp_env1.is_active()
                || self.amp_env2.is_active()
                || self.pitch_env.is_active());
        let snares_on = snares_level > 0.0 && self.snares_env.is_active();
        let pitch_on = self.pitch_env.is_active();
        let amp2_on = self.amp_env2.is_active();

        let mut pos = 0;
        while pos < out.len() {
            let n = (out.len() - pos).min(CHUNK);
            let chunk = &mut out[pos..pos + n];

            if tone_on || snares_on {
                for i in 0..n {
                    let mut mix = 0.0f32;
                    if tone_on {
                        let pitch = if pitch_on {
                            self.pitch_env.process_sample()
                        } else {
                            0.0
                        };
                        // Once the pitch envelope has decayed to zero the sweep is over: `f1` is
                        // just the base, so the `exp2` is skipped (most of the tail).
                        let f1 = if pitch > 0.0 {
                            sweep_hz(self.base_hz, self.sweep_st, pitch)
                        } else {
                            self.base_hz
                        };
                        let a1 = self.amp_env1.process_sample();
                        let a2 = if amp2_on {
                            self.amp_env2.process_sample()
                        } else {
                            0.0
                        };
                        let s1 = self.osc1.next(SweepShape::Sine, f1, sr);
                        let s2 = self.osc2.next(SweepShape::Sine, f1 * self.ratio, sr);
                        mix += (s1 * a1 * (1.0 - mb) + s2 * a2 * mb) * tone_level;
                    }
                    if snares_on {
                        let w = self.noise.next();
                        // One filter tick yields both the band and the high-pass output.
                        let (bp, hp) = self.svf.process_band_high(w, &coefs);
                        mix += ((1.0 - width) * bp + width * hp)
                            * self.snares_env.process_sample()
                            * snares_level;
                    }
                    // With no drive the mix goes straight into the output; with drive it goes via
                    // the scratch buffer the drive stage works on.
                    if drive_on {
                        self.scratch[i] = mix;
                    } else {
                        chunk[i] += mix;
                    }
                }
                if drive_on {
                    self.drive_stage.process(&mut self.scratch[..n]);
                    for i in 0..n {
                        chunk[i] += self.scratch[i];
                    }
                }
            }
            // Snap bypasses the drive: it is added straight to the output.
            self.snap.render(chunk, snap_gain);
            pos += n;
        }
    }

    fn release(&mut self) {
        // One-shot voice: note-off is ignored.
    }

    fn is_active(&self) -> bool {
        self.amp_env1.is_active()
            || self.amp_env2.is_active()
            || self.snares_env.is_active()
            || self.snap.is_active()
    }

    fn reset(&mut self) {
        self.osc1.reset();
        self.osc2.reset();
        self.pitch_env.reset();
        self.amp_env1.reset();
        self.amp_env2.reset();
        self.snares_env.reset();
        self.noise.reset(NOISE_SEED);
        self.svf.reset();
        self.snap.reset();
        self.drive_stage.reset();
        self.velocity = 1.0;
        self.decay_scale = 1.0;
        self.snap_gain = 0.0;
    }

    fn device_id() -> &'static str {
        "sonara.builtin.snare"
    }

    fn device_name() -> &'static str {
        "Snare"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::param_table::Kind;
    use crate::audio::devices::real_to_norm;
    use crate::audio::dsp::test_util::{spectrum_db, time_to_db, tone_amplitude};

    const SR: f32 = 48_000.0;

    fn voice() -> SnareVoice {
        SnareVoice::new(SR)
    }

    /// The normalized value that drives parameter `id` to the real value `real`.
    fn norm_for(id: ParamId, real: f32) -> f32 {
        let spec = SPECS.iter().find(|s| s.id == id).expect("parameter id");
        match spec.kind {
            Kind::Float {
                min,
                max,
                log,
                skew,
            } => real_to_norm(real, min, max, log, skew),
            Kind::Bool => {
                if real >= 0.5 {
                    1.0
                } else {
                    0.0
                }
            }
            Kind::Enum(_) => real,
        }
    }

    fn set_real(v: &mut SnareVoice, id: ParamId, real: f32) {
        v.set_parameter(id, norm_for(id, real));
    }

    /// One hit rendered into its own buffer, with a fixed humanize seed.
    fn hit(v: &mut SnareVoice, frames: usize, note: u8, velocity: f32) -> Vec<f32> {
        let mut rng = Rng::new(0x1234_5678);
        v.trigger(note, velocity, &mut rng);
        let mut out = vec![0.0; frames];
        v.render(&mut out);
        out
    }

    /// A short moving-average of the absolute signal: a smoother, near-deterministic envelope
    /// for `time_to_db` on a noise layer.
    fn abs_envelope(signal: &[f32], window: usize) -> Vec<f32> {
        let mut out = vec![0.0; signal.len()];
        let mut sum = 0.0f64;
        for i in 0..signal.len() {
            sum += signal[i].abs() as f64;
            if i >= window {
                sum -= signal[i - window].abs() as f64;
            }
            out[i] = (sum / window as f64) as f32;
        }
        out
    }

    /// Spectral centroid (Hz) of a mono signal, from its Hann-windowed magnitude spectrum.
    fn centroid(signal: &[f32]) -> f32 {
        let n = signal.len();
        let db = spectrum_db(signal);
        let mut num = 0.0f64;
        let mut den = 0.0f64;
        for (i, &d) in db.iter().enumerate().skip(1) {
            let mag = 10f64.powf(d as f64 / 20.0);
            let hz = i as f64 * SR as f64 / n as f64;
            num += hz * mag;
            den += mag;
        }
        (num / den) as f32
    }

    /// (a) The Tone layer has partials at Tune and Tune * Ratio, each a local peak.
    #[test]
    fn tone_partials_are_at_tune_and_tune_times_ratio() {
        let mut v = voice();
        set_real(&mut v, TONE_LEVEL, 1.0);
        set_real(&mut v, SNARES_LEVEL, 0.0);
        set_real(&mut v, SNAP_LEVEL, 0.0);
        set_real(&mut v, TONE_DECAY, 0.8);
        set_real(&mut v, TONE_BALANCE, 0.5);

        let tune = 180.0f32;
        let ratio = 1.6f32;
        let signal = hit(&mut v, (SR * 0.8) as usize, 60, 1.0);
        // The pitch sweep is over by 0.3 s; measure the steady tail.
        let tail = &signal[(SR * 0.3) as usize..];

        for f in [tune, tune * ratio] {
            let here = tone_amplitude(tail, f, SR);
            let below = tone_amplitude(tail, f * 0.95, SR);
            let above = tone_amplitude(tail, f * 1.05, SR);
            assert!(here > 1e-4, "no partial at {f} Hz: {here}");
            assert!(
                here > below * 1.05 && here > above * 1.05,
                "{f} Hz is not a peak: {here} vs {below}/{above}"
            );
        }
    }

    /// (b) The Snares layer decays to −60 dB within 5 % of its Decay setting.
    #[test]
    fn snares_decay_to_minus_60_db() {
        let mut v = voice();
        set_real(&mut v, TONE_LEVEL, 0.0);
        set_real(&mut v, SNAP_LEVEL, 0.0);
        set_real(&mut v, SNARES_LEVEL, 1.0);
        let decay = 0.5f32;
        set_real(&mut v, SNARES_DECAY, decay);

        let signal = hit(&mut v, SR as usize, 60, 1.0);
        let envelope = abs_envelope(&signal, 480);
        let t60 = time_to_db(&envelope, -60.0, SR);
        assert!(
            (t60 - decay).abs() <= decay * 0.05,
            "−60 dB at {t60} s, expected {decay} s"
        );
    }

    /// (c) Color raises the spectral centroid of the noise layer monotonically.
    #[test]
    fn snares_color_raises_spectral_centroid() {
        let colors = [2000.0f32, 5000.0, 9000.0];
        let mut centroids = Vec::new();
        for &color in &colors {
            let mut v = voice();
            set_real(&mut v, TONE_LEVEL, 0.0);
            set_real(&mut v, SNAP_LEVEL, 0.0);
            set_real(&mut v, SNARES_LEVEL, 1.0);
            set_real(&mut v, SNARES_DECAY, 1.0);
            set_real(&mut v, SNARES_WIDTH, 0.0);
            set_real(&mut v, SNARES_COLOR, color);
            let signal = hit(&mut v, (SR * 0.3) as usize, 60, 1.0);
            centroids.push(centroid(&signal));
        }
        assert!(
            centroids[0] < centroids[1] && centroids[1] < centroids[2],
            "centroids not monotonic: {centroids:?}"
        );
    }

    /// (d) Determinism: the same seed gives bit-identical hits.
    #[test]
    fn same_seed_gives_identical_hits() {
        let render = || {
            let mut v = voice();
            let mut rng = Rng::new(42);
            v.trigger(60, 0.9, &mut rng);
            let mut out = vec![0.0; (SR * 0.5) as usize];
            v.render(&mut out);
            out
        };
        assert_eq!(render(), render());
    }
}
