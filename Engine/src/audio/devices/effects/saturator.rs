//! Saturator effect (spec 031): a four-character waveshaper (Soft / Tube / Tape / Hard) with
//! drive, bias, level dependence, oversampling, tone, a tape stage group, Auto Gain and a Mix.
//!
//! Signal path, per channel:
//! `Input → split`. Wet: `Low Cut → drive gain × level-dependent boost → [Oversampler] shaper
//! [/Oversampler] → DC blocker → tape stages → wow/flutter/drift → High Cut → Tone → Auto Gain
//! → Output`, plus tape noise. Dry: `[phase-matched Oversampler, no stage] → the wow line's
//! centre delay`. Mix then crossfades the two linearly (spec 012 decision 5).
//!
//! Input is a true input gain (both sides), Output a wet-level trim (Mix 0 % ignores it).
//!
//! Dry compensation: the IIR half-band oversampler delays the wet side by a frequency-dependent
//! ~5–8 samples, so a plain dry sum comb-filters (−28 dB at 5 kHz for Mix 50 % at 2x). The dry
//! side therefore runs through a twin oversampler with no stage in it, which has exactly the
//! same phase response, and through a delay line at the wow centre delay. The compensation only
//! runs while Mix is strictly between 0 and 100 %, and is crossfaded in and out, so Mix 0 % is
//! still bit-exact dry (times the Input gain).
//!
//! Also: the type and quality crossfades, the `"curve"` data stream (a frozen 584-byte record;
//! see `BYTES` and `poll_device_data`), TailSleep, and a CPU benchmark among the tests.

use super::effect::{pass_through, TailSleep};
use crate::audio::devices::param_table::{
    flatten, linear, log, skewed, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::dsp::delay_line::{DelayLine, MIN_HERMITE_DELAY};
use crate::audio::dsp::env_follower::{Detection, EnvFollower};
use crate::audio::dsp::gain::{db_to_gain, dry_wet_gains, MixLaw};
use crate::audio::dsp::noise::{PinkNoise, Rng};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use crate::audio::dsp::oversampler::Oversampler;
use crate::audio::dsp::saturate::{drive_params, hard_clip, soft_clip, tube_clip};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::svf::{cutoff_to_g, FilterMode, Svf, SvfCoefs};

// === Parameters ===

pub const SAT_TYPE: ParamId = 0;
pub const DRIVE: ParamId = 1;
pub const BIAS: ParamId = 2;
pub const LEVEL_DEPEND: ParamId = 3;
pub const INPUT: ParamId = 4;
pub const QUALITY: ParamId = 5;

pub const PRE_HPF: ParamId = 10;
pub const POST_LPF: ParamId = 11;
pub const TILT: ParamId = 12;

pub const HF_LOSS: ParamId = 20;
pub const HEAD_BUMP: ParamId = 21;
pub const SQUASH: ParamId = 22;
pub const WOW: ParamId = 23;
pub const NOISE: ParamId = 24;
pub const FLUTTER: ParamId = 25;
pub const DRIFT: ParamId = 26;

pub const MIX: ParamId = 30;
pub const OUTPUT: ParamId = 31;
pub const AUTO_GAIN: ParamId = 32;

const TYPES: &[&str] = &["Soft", "Tube", "Tape", "Hard"];
const QUALITIES: &[&str] = &["1x", "2x", "4x"];

const SHAPE_MODULE: [ParamSpec; 6] = [
    spec(SAT_TYPE, "Type", "Shaper", "", Kind::Enum(TYPES), 0.0),
    spec(DRIVE, "Drive", "Shaper", "dB", linear(0.0, 36.0), 6.0),
    // Percent of [`BIAS_MAX`], on a signed square taper (see [`bias_amount`]).
    spec(BIAS, "Bias", "Shaper", "%", linear(-100.0, 100.0), 0.0),
    spec(
        LEVEL_DEPEND,
        "Dynamics",
        "Shaper",
        "%",
        linear(0.0, 100.0),
        0.0,
    ),
    spec(INPUT, "Input", "Shaper", "dB", linear(-24.0, 24.0), 0.0),
    spec(QUALITY, "Quality", "Shaper", "", Kind::Enum(QUALITIES), 1.0).not_automatable(),
];

const TONE_MODULE: [ParamSpec; 3] = [
    // 0 is Off; above that a power curve close to log over 20–1000 Hz (the SC Low Cut pattern).
    spec(
        PRE_HPF,
        "Low Cut",
        "Tone",
        "Hz",
        skewed(0.0, 1_000.0, 2.0),
        0.0,
    ),
    // The top of the range (20 kHz) is Off.
    spec(
        POST_LPF,
        "High Cut",
        "Tone",
        "Hz",
        log(1_000.0, 20_000.0),
        20_000.0,
    ),
    // A high shelf at the [`TILT_SPLIT_HZ`] pivot; the value is its far-side gain.
    spec(TILT, "Tone", "Tone", "dB", linear(-9.0, 9.0), 0.0),
];

const TAPE_MODULE: [ParamSpec; 7] = [
    spec(HF_LOSS, "HF Loss", "Tape", "%", linear(0.0, 100.0), 50.0),
    spec(HEAD_BUMP, "Head Bump", "Tape", "dB", linear(0.0, 6.0), 2.0),
    spec(SQUASH, "Squash", "Tape", "%", linear(0.0, 100.0), 30.0),
    // Wow, Flutter and Drift: percent on a square taper (see [`mod_amount`]).
    spec(WOW, "Wow", "Tape", "%", linear(0.0, 100.0), 0.0),
    // [`NOISE_OFF_DB`] is Off.
    spec(
        NOISE,
        "Noise",
        "Tape",
        "dBFS",
        linear(NOISE_OFF_DB, -40.0),
        NOISE_OFF_DB,
    ),
    spec(FLUTTER, "Flutter", "Tape", "%", linear(0.0, 100.0), 0.0),
    spec(DRIFT, "Drift", "Tape", "%", linear(0.0, 100.0), 0.0),
];

const OUTPUT_MODULE: [ParamSpec; 3] = [
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 100.0),
    spec(OUTPUT, "Output", "Output", "dB", linear(-24.0, 24.0), 0.0),
    spec(AUTO_GAIN, "Auto Gain", "Output", "", Kind::Bool, 1.0),
];

const PARAM_COUNT: usize = 19;
const SPECS: [ParamSpec; PARAM_COUNT] =
    flatten(&[&SHAPE_MODULE, &TONE_MODULE, &TAPE_MODULE, &OUTPUT_MODULE]);
const SLOTS: [u8; 33] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

// === Constants ===

/// Crossfade when the Type or the Quality changes, and of the dry compensation.
const SWITCH_FADE_MS: f32 = 10.0;
/// Smoothing time for continuous parameters.
const RAMP_MS: f32 = 5.0;
/// Glide of the Wow / Flutter / Drift amounts. Long, because the amounts move the delay itself:
/// a fast glide would bend the pitch audibly while the knob turns.
const MOD_RAMP_MS: f32 = 300.0;
/// Frames between control-rate updates (the filter.rs pattern).
const CTRL_BLOCK: usize = 32;
/// The High Cut value that means Off.
const LPF_OFF_HZ: f32 = 20_000.0;
/// Butterworth damping of the 12 dB/oct Low Cut and High Cut.
const BUTTERWORTH_K: f32 = std::f32::consts::SQRT_2;
/// Level-dependence envelope times (RMS).
const ENV_ATTACK_MS: f32 = 10.0;
const ENV_RELEASE_MS: f32 = 150.0;
/// Envelope level that counts as silence (−120 dBFS), so the dB math stays finite.
const ENV_FLOOR: f32 = 1.0e-6;
/// The full-scale shaper offset Bias 100 % maps to. Bias is added to the driven signal in the
/// shaper's domain, where the curves saturate at 1, so ±1 (the old range) all but rectifies the
/// signal; half of that is already strong.
const BIAS_MAX: f32 = 0.5;
/// DC blocker corner after the shaper.
const DC_HZ: f32 = 10.0;
/// The Tone shelf's crossover (the pivot). 1.3 kHz rather than a bare 1 kHz: with the pivot at
/// 1 kHz the split's phase shift alone drags the 600 Hz harmonic past REQ-010's "within 1 dB"
/// limit under any cut, while 1.3 kHz keeps it and still meets the ≥ 6 dB band figure at −9 dB
/// (verified numerically and by the test below).
const TILT_SPLIT_HZ: f32 = 1_300.0;
/// Tone changes smaller than this are the neutral bypass.
const TILT_NEUTRAL_DB: f32 = 1.0e-3;
/// Operating level of the Auto Gain measurement: a −18 dBFS sine.
const AUTO_GAIN_LEVEL_DB: f32 = -18.0;
/// Samples of the Auto Gain probe: exactly one period of `sample_rate / PERIOD`.
const AUTO_GAIN_PERIOD: usize = 256;
/// The Noise value that means Off.
const NOISE_OFF_DB: f32 = -90.0;
/// Head bump shelf corner. A one-pole low shelf: the low band is the lowpass output, the high
/// band is the input minus the same lowpass, so gain 1 is an exact bypass whatever the filter
/// state. A biquad shelf was considered but `dsp/svf.rs`' `FilterMode` has no shelf variant,
/// and a resonant 2-pole shape buys nothing this far below the audible band.
const BUMP_HZ: f32 = 100.0;
/// HF loss follows how hard the tape is hit: the pre-shaper RMS level *plus the effective
/// drive*. At [`LOSS_REF_DB`] it is lossless; over the next [`LOSS_SPAN_DB`] the cutoff falls
/// from [`LPF_OFF_HZ`] by up to `LOSS_MAX_OCTAVES × HF Loss` octaves, and stays there above.
const LOSS_REF_DB: f32 = -12.0;
const LOSS_SPAN_DB: f32 = 18.0;
const LOSS_MAX_OCTAVES: f32 = 5.0;
/// Squash envelope (peak) times. The detector reads the shaper's output, the signal Squash
/// acts on.
const SQ_ATTACK_MS: f32 = 5.0;
const SQ_RELEASE_MS: f32 = 100.0;
/// Squash knee: the soft-clip drive multiplier starts rising at `SQ_START_DB` peak and reaches
/// `1 + SQ_MAX_DRIVE × Squash` [`SQ_SPAN_DB`] above it.
const SQ_START_DB: f32 = -12.0;
const SQ_SPAN_DB: f32 = 12.0;
const SQ_MAX_DRIVE: f32 = 3.0;
/// Wow: a 0.5 Hz sine, up to ±3 ms (about ±0.9 % pitch at 100 %).
const WOW_MAX_SECONDS: f32 = 0.003;
const WOW_HZ: f32 = 0.5;
/// Flutter: a 6 Hz sine with a 9.7 Hz partner at a fixed 70/30 ratio (so it spans exactly
/// ±1 and doesn't sound like a plain LFO), up to ±0.15 ms (about ±0.5 % pitch at 100 %).
const FLUTTER_MAX_SECONDS: f32 = 0.000_15;
const FLUTTER_HZ: f32 = 6.0;
const FLUTTER_HZ_2: f32 = 9.7;
const FLUTTER_MIX: f32 = 0.7;
/// Drift: slow random wander, cosine-interpolated between random targets in ±1 that are
/// `DRIFT_MIN_SEG_S`…`DRIFT_MAX_SEG_S` apart; up to ±3 ms.
const DRIFT_MAX_SECONDS: f32 = 0.003;
const DRIFT_MIN_SEG_S: f32 = 0.7;
const DRIFT_MAX_SEG_S: f32 = 2.0;
/// The modulation delay line spans the centre delay (the sum of the three depths) plus the
/// same again for the swing, with a little headroom.
const MOD_LINE_SECONDS: f32 =
    2.0 * (WOW_MAX_SECONDS + FLUTTER_MAX_SECONDS + DRIFT_MAX_SECONDS) + 0.001;
/// Seeds of the stereo noise pair (decorrelated, deterministic — splitmix constants) and of the
/// drift generator.
const NOISE_SEEDS: [u32; 2] = [0x9E37_79B9, 0x85EB_CA6B];
const DRIFT_SEED: u32 = 0xC2B2_AE35;

// === `"curve"` data stream ===

/// Points of the streamed transfer curve, evenly spaced over input −1…+1.
pub const CURVE_POINTS: usize = 128;
/// Harmonic magnitudes streamed alongside the curve (dB).
pub const HARMONIC_COUNT: usize = 16;
/// dB floor of the harmonic magnitudes (a silent harmonic reads this).
pub const HARMONIC_FLOOR_DB: f32 = -160.0;
/// Floats in one record: the 2-value header, [`CURVE_POINTS`] and [`HARMONIC_COUNT`].
pub const RECORD_VALUES: usize = 2 + CURVE_POINTS + HARMONIC_COUNT;
/// Bytes in one `"curve"` record (146 little-endian f32s — the frozen contract; the Godot
/// decoder `SaturatorData.gd` hardcodes the same number).
pub const BYTES: usize = RECORD_VALUES * 4;
/// Device-data poll rate (the compressor's `"dynamics"` rate).
const DATA_RATE_HZ: f32 = 20.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SatType {
    Soft,
    Tube,
    Tape,
    Hard,
}

impl SatType {
    fn from_index(index: usize) -> Self {
        match index {
            0 => Self::Soft,
            1 => Self::Tube,
            2 => Self::Tape,
            _ => Self::Hard,
        }
    }
}

/// The shaper offset for a Bias value in percent: a signed square taper over ±[`BIAS_MAX`], so
/// the subtle range (where warmth lives) gets most of the knob.
pub fn bias_amount(percent: f32) -> f32 {
    let r = (percent * 0.01).clamp(-1.0, 1.0);
    BIAS_MAX * r * r.abs()
}

/// A Wow / Flutter / Drift percentage as a 0..1 depth: a square taper, so realistic subtle
/// settings get most of the knob.
fn mod_amount(percent: f32) -> f32 {
    let r = (percent * 0.01).clamp(0.0, 1.0);
    r * r
}

/// Decoded (real-valued) parameters.
#[derive(Clone, Copy, Debug)]
struct Params {
    ty: SatType,
    drive_db: f32,
    /// The shaper offset ([`bias_amount`] of the knob).
    bias: f32,
    /// Level-dependence amount, 0..1.
    level_depend: f32,
    input_db: f32,
    oversample: usize,
    /// Pre-shaper high-pass cutoff; 0 is Off.
    pre_hpf_hz: f32,
    /// Post-shaper low-pass cutoff; [`LPF_OFF_HZ`] is Off.
    post_lpf_hz: f32,
    tilt_db: f32,
    /// Tape amounts, 0..1 each.
    hf_loss: f32,
    head_bump_db: f32,
    squash: f32,
    /// Modulation depths, 0..1 each ([`mod_amount`] of the knobs).
    wow: f32,
    flutter: f32,
    drift: f32,
    /// Noise level in dBFS; [`NOISE_OFF_DB`] is Off.
    noise_db: f32,
    /// Mix, 0..1 (0 % is bit-exact dry).
    mix: f32,
    output_db: f32,
    auto_gain: bool,
}

impl Params {
    fn defaults(values: &ParamValues<PARAM_COUNT>) -> Self {
        let mut p = Self {
            ty: SatType::Soft,
            drive_db: 6.0,
            bias: 0.0,
            level_depend: 0.0,
            input_db: 0.0,
            oversample: 2,
            pre_hpf_hz: 0.0,
            post_lpf_hz: LPF_OFF_HZ,
            tilt_db: 0.0,
            hf_loss: 0.5,
            head_bump_db: 2.0,
            squash: 0.3,
            wow: 0.0,
            flutter: 0.0,
            drift: 0.0,
            noise_db: NOISE_OFF_DB,
            mix: 1.0,
            output_db: 0.0,
            auto_gain: true,
        };
        for spec in &SPECS {
            if let Some(real) = values.real(spec.id) {
                p.apply(spec.id, real);
            }
        }
        p
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            SAT_TYPE => self.ty = SatType::from_index(real as usize),
            DRIVE => self.drive_db = real,
            BIAS => self.bias = bias_amount(real),
            LEVEL_DEPEND => self.level_depend = real * 0.01,
            INPUT => self.input_db = real,
            QUALITY => self.oversample = 1 << (real as usize).min(2),
            PRE_HPF => self.pre_hpf_hz = real,
            POST_LPF => self.post_lpf_hz = real,
            TILT => self.tilt_db = real,
            HF_LOSS => self.hf_loss = real * 0.01,
            HEAD_BUMP => self.head_bump_db = real,
            SQUASH => self.squash = real * 0.01,
            WOW => self.wow = mod_amount(real),
            FLUTTER => self.flutter = mod_amount(real),
            DRIFT => self.drift = mod_amount(real),
            NOISE => self.noise_db = real,
            MIX => self.mix = real * 0.01,
            OUTPUT => self.output_db = real,
            AUTO_GAIN => self.auto_gain = real >= 0.5,
            _ => {}
        }
    }
}

// === Shaper and DC blocker ===

/// Replace a non-finite sample with silence, so a bad host buffer can't poison the DSP state.
#[inline]
fn finite(x: f32) -> f32 {
    if x.is_finite() {
        x
    } else {
        0.0
    }
}

/// Linear noise gain for a Noise level in dBFS; [`NOISE_OFF_DB`] (and below) is Off.
fn noise_level_gain(db: f32) -> f32 {
    if db > NOISE_OFF_DB + 0.01 {
        db_to_gain(db.min(-40.0))
    } else {
        0.0
    }
}

/// Signal power with the mean (DC) removed.
fn ac_power(xs: &[f32]) -> f64 {
    let mean = xs.iter().map(|&x| x as f64).sum::<f64>() / xs.len().max(1) as f64;
    xs.iter().map(|&x| (x as f64 - mean).powi(2)).sum()
}

/// Read `line` `delay` samples behind the sample just pushed (0 = that sample), continuously
/// down to 0: Hermite from one sample of delay up, linear between the two newest samples below
/// that (Hermite needs a sample on each side).
#[inline]
fn read_delay(line: &DelayLine, delay: f32) -> f32 {
    // `DelayLine` counts the newest sample as 1.
    let d = delay + 1.0;
    if d >= MIN_HERMITE_DELAY {
        line.read_hermite(d)
    } else {
        line.read_linear(d)
    }
}

/// One-pole DC blocker (`y = x − x₁ + a·y₁`). The shaper's signal-dependent DC (Tube and Bias
/// especially) must not reach the output.
#[derive(Clone, Copy, Debug)]
struct DcBlocker {
    x1: f32,
    y1: f32,
}

impl DcBlocker {
    fn new() -> Self {
        Self { x1: 0.0, y1: 0.0 }
    }

    /// The pole for a [`DC_HZ`] corner at `sample_rate`.
    fn coef(sample_rate: f32) -> f32 {
        (-std::f32::consts::TAU * DC_HZ / sample_rate).exp()
    }

    #[inline]
    fn tick(&mut self, x: f32, a: f32) -> f32 {
        let y = x - self.x1 + a * self.y1;
        self.x1 = x;
        self.y1 = y;
        y
    }

    fn reset(&mut self) {
        self.x1 = 0.0;
        self.y1 = 0.0;
    }
}

// === Device ===

/// The Tone shelf's crossover: a two-pole Butterworth low pass (one TPT SVF stage at damping
/// √2). The shelf mixes the low band against its complement (`hp = x − lp`), so a unity
/// high-band gain is an exact bypass whatever the split's state is. One pole alone cannot meet
/// REQ-010's figures — its asymptote is reached too late for the 2–5 kHz band while the
/// sub-1 kHz harmonics must stay within 1 dB — hence the pair.
#[derive(Clone, Copy, Debug)]
struct TiltSplit {
    ic1: f32,
    ic2: f32,
}

impl TiltSplit {
    fn new() -> Self {
        Self { ic1: 0.0, ic2: 0.0 }
    }

    /// Per-stage coefficients for the split cutoff; computed per control block.
    fn coefs(sample_rate: f32) -> (f32, f32, f32) {
        let g = one_pole_g(TILT_SPLIT_HZ, sample_rate);
        let k = std::f32::consts::SQRT_2;
        let a1 = 1.0 / (1.0 + g * (g + k));
        let a2 = g * a1;
        (a1, a2, g * a2)
    }

    #[inline]
    fn lowpass(&mut self, x: f32, a1: f32, a2: f32, a3: f32) -> f32 {
        let v3 = x - self.ic2;
        let v1 = a1 * self.ic1 + a2 * v3;
        let v2 = self.ic2 + a2 * self.ic1 + a3 * v3;
        self.ic1 = 2.0 * v1 - self.ic1;
        self.ic2 = 2.0 * v2 - self.ic2;
        v2
    }

    fn reset(&mut self) {
        self.ic1 = 0.0;
        self.ic2 = 0.0;
    }
}

/// A sine LFO as a rotating phasor: one complex multiply per sample instead of a `sin`. Starts
/// at phase 0 (output 0, rising); [`SineOsc::renormalize`] at control rate keeps its radius at 1.
#[derive(Clone, Copy, Debug)]
struct SineOsc {
    c: f32,
    s: f32,
    rc: f32,
    rs: f32,
}

impl SineOsc {
    fn new(hz: f32, sample_rate: f32) -> Self {
        let w = std::f32::consts::TAU * hz / sample_rate;
        Self {
            c: 1.0,
            s: 0.0,
            rc: w.cos(),
            rs: w.sin(),
        }
    }

    /// Advance one sample; returns the sine.
    #[inline]
    fn next(&mut self) -> f32 {
        let c = self.c * self.rc - self.s * self.rs;
        self.s = self.c * self.rs + self.s * self.rc;
        self.c = c;
        self.s
    }

    /// Pull the radius back to 1 (one Newton step; the drift per block is tiny).
    fn renormalize(&mut self) {
        let g = 1.5 - 0.5 * (self.c * self.c + self.s * self.s);
        self.c *= g;
        self.s *= g;
    }
}

/// Slow random wander in ±1 for Drift: cosine segments between seeded random targets.
#[derive(Clone, Debug)]
struct DriftGen {
    rng: Rng,
    from: f32,
    to: f32,
    pos: f32,
    inc: f32,
}

impl DriftGen {
    fn new() -> Self {
        Self {
            rng: Rng::new(DRIFT_SEED),
            from: 0.0,
            to: 0.0,
            // Past the end, so the first sample starts a segment.
            pos: 1.0,
            inc: 0.0,
        }
    }

    #[inline]
    fn next(&mut self, sample_rate: f32) -> f32 {
        if self.pos >= 1.0 {
            self.from = self.to;
            self.to = self.rng.bipolar();
            let seconds =
                DRIFT_MIN_SEG_S + self.rng.next_f32() * (DRIFT_MAX_SEG_S - DRIFT_MIN_SEG_S);
            self.inc = 1.0 / (seconds * sample_rate);
            self.pos = 0.0;
        }
        let shape = 0.5 - 0.5 * (std::f32::consts::PI * self.pos).cos();
        self.pos += self.inc;
        self.from + (self.to - self.from) * shape
    }
}

pub struct SaturatorDevice {
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,
    p: Params,

    /// The two oversampled shaper paths; `os[os_active]` is live, the other one only runs while
    /// a QUALITY crossfade blends over to it. Both are `prepare`d for the maximum factor, so
    /// `set_factor` only ever switches which region is used (nothing allocates on the audio
    /// thread).
    os: [Oversampler; 2],
    /// The dry side's phase-matched twins of `os` (same factor per index, no stage).
    dry_os: [Oversampler; 2],
    os_active: usize,
    /// While `os_fade < 1`: the instance that has the new factor and is being faded in.
    /// `os_active` keeps running as the outgoing path until the crossfade completes.
    os_next: usize,
    /// Crossfade progress from `os[os_active]` to `os[os_next]`: 1 when settled.
    os_fade: f32,
    /// A Quality that arrived while a crossfade was already running; it starts once that one
    /// completes, so a fading instance is never reset mid-fade.
    pending_os: Option<usize>,
    /// The shaper the type crossfade is blending away from.
    prev_type: SatType,
    /// Crossfade progress from `prev_type` to `p.ty`: 1 when settled.
    ty_fade: f32,
    /// A Type that arrived mid-crossfade, started once the running one completes.
    pending_ty: Option<SatType>,
    /// Per-channel DC blocker right after the shaper, and its pole.
    dc: [DcBlocker; 2],
    dc_a: f32,
    /// RMS envelope (10 ms / 150 ms) of the pre-shaper signal, per channel, for level-dependent
    /// drive and HF loss.
    env: [EnvFollower; 2],
    /// Extra drive dB from level dependence. Its target is refreshed every [`CTRL_BLOCK`]
    /// frames and the value ramps there linearly, so the drive never steps. At `LEVEL_DEPEND`
    /// 0 it is exactly 0.0, so the path equals the static curve.
    boost_db: f32,
    boost_target: f32,
    boost_inc: f32,
    boost_steps: usize,
    /// Pre-shaper high pass (Low Cut) and post-shaper low pass (High Cut), 12 dB/oct, per
    /// channel, with whether each ran last block (a filter switching on starts from reset).
    pre_hpf: [Svf; 2],
    post_lpf: [Svf; 2],
    hpf_was_on: bool,
    lpf_was_on: bool,
    /// The Tone split's low band, per channel.
    tilt: [TiltSplit; 2],
    /// Auto Gain compensation as a linear gain, smoothed so a curve change never steps.
    sm_auto: SmoothedParam,
    /// The settings the cached Auto Gain measurement is valid for: type, static drive, bias and
    /// whether compensation is wanted.
    curve_key: (u8, u32, u32, bool),

    /// The cached `"curve"` stream body: 128 transfer points and 16 harmonic magnitudes (dB),
    /// a pure function of (type, static drive, bias). Rebuilt at control rate — sharing the
    /// Auto Gain key pattern — only while subscribed, and only when one of those changes.
    curve_cache: [f32; CURVE_POINTS],
    curve_harmonics: [f32; HARMONIC_COUNT],
    /// The settings the curve cache is valid for. `(u8::MAX, ..)` is an impossible sentinel
    /// that forces a rebuild.
    curve_cache_key: (u8, u32, u32),
    /// `"curve"` stream bookkeeping (the compressor's `"dynamics"` pattern): the subscription
    /// flag, frames since the last poll, and the poll interval in frames (~20 Hz).
    curve_subscribed: bool,
    frames_since_poll: usize,
    poll_interval: usize,
    /// Header snapshot, refreshed every [`CTRL_BLOCK`]: the drive actually applied this block
    /// (static + level-dependent boost) and the pre-shaper envelope level in dBFS.
    effective_drive_db: f32,
    env_db: f32,
    /// Cached per-frame values that only change at control rate when everything has settled:
    /// the effective drive's gain/blend pair (keyed on its bits; [`u32::MAX`] forces a
    /// recompute) and the head-bump shelf gain.
    drive_key: u32,
    last_gain: f32,
    last_blend: f32,
    bump_g: f32,

    /// Tape group gate: 1 while Type is Tape, 0 otherwise, ramped over [`SWITCH_FADE_MS`]
    /// alongside the type crossfade. Multiplies every tape amount; once settled at 0 the whole
    /// group short-circuits.
    sm_tape_gate: SmoothedParam,
    /// Head bump one-pole low shelf, per channel (the low band; the high band is `x − low`).
    bump_lp: [OnePole; 2],
    /// Level-dependent HF loss low pass, per channel.
    loss_lpf: [OnePole; 2],
    /// Peak envelope of the shaper output Squash follows, per channel.
    env_squash: [EnvFollower; 2],
    /// Control-rate values for the tape stages: the HF-loss cutoff coefficient (0 = bypass),
    /// the squash soft-clip drive multiplier (0 = bypass) and the noise level gain (the gate
    /// is applied per frame).
    loss_cut_g: f32,
    sq_drive: f32,
    noise_gain: f32,
    /// True while the tape group ran the previous control block, so a (re-)activation can
    /// start the followers and filters from reset.
    tape_was_active: bool,
    /// Wow / Flutter / Drift depths (0..1, already tapered), gliding to `amount` while Type is
    /// Tape and to 0 otherwise. Faded by themselves rather than by the fast tape gate, since
    /// they move the delay.
    sm_wow: SmoothedParam,
    sm_flutter: SmoothedParam,
    sm_drift: SmoothedParam,
    /// The modulation delay lines (wet) and their dry twins at the centre delay; never touched
    /// while every depth is 0, so a modulation-free render never reads or writes them.
    delay: [DelayLine; 2],
    dry_delay: [DelayLine; 2],
    mod_running: bool,
    wow_osc: SineOsc,
    flut_osc: SineOsc,
    flut_osc_2: SineOsc,
    drift: DriftGen,
    /// Seeded pink noise pair, per channel.
    noise: [PinkNoise; 2],
    /// Dry compensation weight: 1 while Mix is strictly between 0 and 100 %, else 0, over
    /// [`SWITCH_FADE_MS`]. At 0 the dry side is the plain (input-trimmed) signal.
    sm_comp: SmoothedParam,
    /// Whether the dry oversamplers ran last block (they restart from reset).
    comp_running: bool,

    // Scratch, sized in `prepare` only.
    wet_in: Vec<f32>,
    wet_out: Vec<f32>,
    wet_alt: Vec<f32>,
    dry_buf: Vec<f32>,
    dry_comp: Vec<f32>,
    dry_alt: Vec<f32>,
    frame_gain: Vec<f32>,
    frame_blend: Vec<f32>,
    frame_bias: Vec<f32>,
    frame_gate: Vec<f32>,
    frame_dry: Vec<f32>,
    frame_wet: Vec<f32>,
    frame_out: Vec<f32>,
    /// The Quality crossfade position per frame, shared by the wet and dry blends.
    frame_osf: Vec<f32>,

    sm_drive: SmoothedParam,
    sm_bias: SmoothedParam,
    sm_input: SmoothedParam,
    sm_mix: SmoothedParam,
    sm_output: SmoothedParam,

    sleep: TailSleep,
    is_active: bool,
    is_enabled: bool,
}

impl SaturatorDevice {
    pub fn new(sample_rate: f32) -> Self {
        let values = ParamValues::<PARAM_COUNT>::new(&TABLE);
        let p = Params::defaults(&values);
        let smoother = |v: f32| SmoothedParam::new(v, sample_rate, RAMP_MS);
        let mod_smoother = |v: f32| SmoothedParam::new(v, sample_rate, MOD_RAMP_MS);
        let env = || EnvFollower::new(ENV_ATTACK_MS, ENV_RELEASE_MS, sample_rate, Detection::Rms);
        let env_sq = || EnvFollower::new(SQ_ATTACK_MS, SQ_RELEASE_MS, sample_rate, Detection::Peak);
        let mut device = Self {
            sample_rate,
            values,
            p,
            os: [Oversampler::new(), Oversampler::new()],
            dry_os: [Oversampler::new(), Oversampler::new()],
            os_active: 0,
            os_next: 0,
            os_fade: 1.0,
            pending_os: None,
            prev_type: p.ty,
            ty_fade: 1.0,
            pending_ty: None,
            dc: [DcBlocker::new(), DcBlocker::new()],
            dc_a: DcBlocker::coef(sample_rate),
            env: [env(), env()],
            boost_db: 0.0,
            boost_target: 0.0,
            boost_inc: 0.0,
            boost_steps: 0,
            pre_hpf: [Svf::new(), Svf::new()],
            post_lpf: [Svf::new(), Svf::new()],
            hpf_was_on: false,
            lpf_was_on: false,
            tilt: [TiltSplit::new(), TiltSplit::new()],
            sm_auto: smoother(1.0),
            curve_key: (0, 0, 0, false),
            curve_cache: [0.0; CURVE_POINTS],
            curve_harmonics: [HARMONIC_FLOOR_DB; HARMONIC_COUNT],
            curve_cache_key: (u8::MAX, 0, 0),
            curve_subscribed: false,
            frames_since_poll: 0,
            poll_interval: (sample_rate / DATA_RATE_HZ) as usize,
            effective_drive_db: p.drive_db,
            env_db: -120.0,
            drive_key: u32::MAX,
            last_gain: 1.0,
            last_blend: 0.0,
            bump_g: 1.0,
            sm_tape_gate: SmoothedParam::new(0.0, sample_rate, SWITCH_FADE_MS),
            bump_lp: [OnePole::new(), OnePole::new()],
            loss_lpf: [OnePole::new(), OnePole::new()],
            env_squash: [env_sq(), env_sq()],
            loss_cut_g: 0.0,
            sq_drive: 0.0,
            noise_gain: 0.0,
            tape_was_active: false,
            sm_wow: mod_smoother(0.0),
            sm_flutter: mod_smoother(0.0),
            sm_drift: mod_smoother(0.0),
            delay: [DelayLine::new(), DelayLine::new()],
            dry_delay: [DelayLine::new(), DelayLine::new()],
            mod_running: false,
            wow_osc: SineOsc::new(WOW_HZ, sample_rate),
            flut_osc: SineOsc::new(FLUTTER_HZ, sample_rate),
            flut_osc_2: SineOsc::new(FLUTTER_HZ_2, sample_rate),
            drift: DriftGen::new(),
            noise: [
                PinkNoise::new(NOISE_SEEDS[0]),
                PinkNoise::new(NOISE_SEEDS[1]),
            ],
            sm_comp: SmoothedParam::new(0.0, sample_rate, SWITCH_FADE_MS),
            comp_running: false,
            wet_in: Vec::new(),
            wet_out: Vec::new(),
            wet_alt: Vec::new(),
            dry_buf: Vec::new(),
            dry_comp: Vec::new(),
            dry_alt: Vec::new(),
            frame_gain: Vec::new(),
            frame_blend: Vec::new(),
            frame_bias: Vec::new(),
            frame_gate: Vec::new(),
            frame_dry: Vec::new(),
            frame_wet: Vec::new(),
            frame_out: Vec::new(),
            frame_osf: Vec::new(),
            sm_drive: smoother(p.drive_db),
            sm_bias: smoother(p.bias),
            sm_input: smoother(db_to_gain(p.input_db)),
            sm_mix: smoother(p.mix),
            sm_output: smoother(db_to_gain(p.output_db)),
            sleep: TailSleep::new(sample_rate),
            is_active: true,
            is_enabled: true,
        };
        // A conservative size until the host calls `prepare`; both paths start at the default.
        device.prepare_buffers(4_096);
        device.reset_dsp();
        device
    }

    /// Size every scratch buffer, oversampler and delay line for `max_frames` (never on the
    /// audio thread).
    fn prepare_buffers(&mut self, max_frames: usize) {
        for buf in [&mut self.wet_in, &mut self.wet_out, &mut self.wet_alt] {
            *buf = vec![0.0; max_frames * 2];
        }
        for buf in [&mut self.dry_buf, &mut self.dry_comp, &mut self.dry_alt] {
            *buf = vec![0.0; max_frames * 2];
        }
        for buf in [
            &mut self.frame_gain,
            &mut self.frame_blend,
            &mut self.frame_bias,
            &mut self.frame_gate,
            &mut self.frame_dry,
            &mut self.frame_wet,
            &mut self.frame_out,
            &mut self.frame_osf,
        ] {
            *buf = vec![0.0; max_frames];
        }
        // Every instance sized for the maximum factor here, so `set_factor` never resizes.
        for slot in self.os.iter_mut().chain(self.dry_os.iter_mut()) {
            slot.prepare(max_frames);
            slot.set_factor(self.p.oversample);
        }
        // The modulation lines are sized once for the maximum depth here; never resized while
        // running.
        for line in self.delay.iter_mut().chain(self.dry_delay.iter_mut()) {
            line.prepare_seconds(MOD_LINE_SECONDS, self.sample_rate);
        }
    }

    /// The type's curve without drive or bias (the shaper's raw nonlinearity).
    #[inline]
    fn curve_at(ty: SatType, v: f32) -> f32 {
        match ty {
            SatType::Hard => hard_clip(v),
            SatType::Tube => tube_clip(v),
            _ => soft_clip(v),
        }
    }

    /// One shaper sample: drive blend around the type's curve. The drive gain is applied inside
    /// the `Oversampler` (it is linear, so either spot works and this keeps the stages tidy).
    /// Bias applies to every type as a transparent shift, `curve(x + b) − curve(b)`: at Bias 0
    /// Soft and Hard are odd (`curve(0) == 0`, so the path is bit-identical to the unshifted
    /// one), and a nonzero Bias breaks the symmetry and produces even harmonics. Tube's own
    /// curve is asymmetric already; Tape shares the Soft curve and gets its character from the
    /// gated tape stages.
    #[inline]
    fn shape(ty: SatType, x: f32, gain: f32, blend: f32, bias: f32) -> f32 {
        let shift = Self::curve_at(ty, bias);
        let y = Self::curve_at(ty, x * gain + bias) - shift;
        x + blend * (y - x)
    }

    /// The shaper over an interleaved (possibly oversampled) buffer. `gain`, `blend` and `bias`
    /// are per base-rate frame; the type crossfade advances once per (oversampled) frame.
    #[allow(clippy::too_many_arguments)]
    fn shape_block(
        cur: SatType,
        prev: SatType,
        fade: &mut f32,
        fade_inc: f32,
        gain: &[f32],
        blend: &[f32],
        bias: &[f32],
        buf: &mut [f32],
    ) {
        let blending = *fade < 1.0;
        // `buf` holds `factor` high-rate frames per base-rate frame; the per-frame values (gain,
        // blend, bias) are base-rate, so index them by the owning base frame.
        let factor = buf.len() / 2 / gain.len().max(1);
        for (k, frame) in buf.chunks_exact_mut(2).enumerate() {
            let base = k / factor.max(1);
            let (g, b, bias_v) = (gain[base], blend[base], bias[base]);
            // The bias shift `curve(bias)` is a constant of the base frame: hoist it out of the
            // (possibly oversampled) per-sample loop.
            let shift = Self::curve_at(cur, bias_v);
            let old_shift = Self::curve_at(prev, bias_v);
            for ch in 0..2 {
                let x = frame[ch];
                let mut y = x + b * (Self::curve_at(cur, x * g + bias_v) - shift - x);
                if blending {
                    let old = x + b * (Self::curve_at(prev, x * g + bias_v) - old_shift - x);
                    y = old + (y - old) * *fade;
                }
                frame[ch] = y;
            }
            if blending {
                *fade = (*fade + fade_inc).min(1.0);
            }
        }
    }

    /// Set oversampler pair `index` (wet and its dry twin) to `factor`. `set_factor` resets an
    /// instance whose factor changes.
    fn set_os_factor(&mut self, index: usize, factor: usize) {
        self.os[index].set_factor(factor);
        self.dry_os[index].set_factor(factor);
    }

    /// Begin crossfading to `factor` on the idle pair. Only called while no fade runs.
    fn start_quality_fade(&mut self, factor: usize) {
        let idle = 1 - self.os_active;
        self.set_os_factor(idle, factor);
        self.os_next = idle;
        self.os_fade = 0.0;
    }

    /// A Quality change: fade to it now, reverse a running fade that heads away from it, or
    /// queue it behind a running fade (so the instance being faded in is never reset).
    fn request_quality(&mut self, factor: usize) {
        if self.os_fade >= 1.0 {
            self.pending_os = None;
            if self.os[self.os_active].factor() != factor {
                self.start_quality_fade(factor);
            }
        } else if self.os[self.os_next].factor() == factor {
            self.pending_os = None;
        } else if self.os[self.os_active].factor() == factor {
            // Back to where the fade started. Nothing blended yet: cancel. Otherwise swap
            // roles; the blend is the same mix, mirrored, and still strictly inside (0, 1).
            if self.os_fade <= 0.0 {
                self.os_next = self.os_active;
                self.os_fade = 1.0;
            } else {
                std::mem::swap(&mut self.os_active, &mut self.os_next);
                self.os_fade = 1.0 - self.os_fade;
            }
            self.pending_os = None;
        } else {
            self.pending_os = Some(factor);
        }
    }

    /// Begin the 10 ms crossfade to `new`, with the tape gate and the modulation depths
    /// following it.
    fn start_type_fade(&mut self, new: SatType) {
        self.prev_type = self.p.ty;
        self.ty_fade = 0.0;
        self.p.ty = new;
        self.sm_tape_gate
            .set_target(if new == SatType::Tape { 1.0 } else { 0.0 });
        self.retarget_mod();
    }

    /// Point the Wow / Flutter / Drift glides at their amounts while Type is Tape, else at 0.
    fn retarget_mod(&mut self) {
        let on = if self.p.ty == SatType::Tape { 1.0 } else { 0.0 };
        self.sm_wow.set_target(self.p.wow * on);
        self.sm_flutter.set_target(self.p.flutter * on);
        self.sm_drift.set_target(self.p.drift * on);
    }

    /// The dry compensation is wanted only where both sides are heard.
    fn comp_target(mix: f32) -> f32 {
        if mix > 0.0 && mix < 1.0 {
            1.0
        } else {
            0.0
        }
    }

    /// Fold a decoded real value (base plus any modulation offset) into the DSP state.
    fn apply(&mut self, param_id: ParamId, real: f32) {
        if param_id == SAT_TYPE {
            let new = SatType::from_index(real as usize);
            if self.ty_fade < 1.0 {
                // Mid-crossfade: queue it (or drop a queued one if we're back at the target).
                self.pending_ty = (new != self.p.ty).then_some(new);
            } else if new != self.p.ty {
                self.start_type_fade(new);
            }
            return;
        }
        self.p.apply(param_id, real);
        let p = self.p;
        match param_id {
            DRIVE => self.sm_drive.set_target(p.drive_db),
            BIAS => self.sm_bias.set_target(p.bias),
            INPUT => self.sm_input.set_target(db_to_gain(p.input_db)),
            QUALITY => self.request_quality(p.oversample),
            MIX => {
                self.sm_mix.set_target(p.mix);
                let comp = Self::comp_target(p.mix);
                if self.sm_comp.target() != comp {
                    self.sm_comp.set_target(comp);
                }
            }
            OUTPUT => self.sm_output.set_target(db_to_gain(p.output_db)),
            WOW | FLUTTER | DRIFT => self.retarget_mod(),
            _ => {}
        }
    }

    /// The settings the cached Auto Gain measurement is valid for: the curve (type, static
    /// drive, bias) plus whether compensation is wanted at all.
    fn auto_gain_key(&self) -> (u8, u32, u32, bool) {
        (
            self.p.ty as u8,
            self.p.drive_db.to_bits(),
            self.p.bias.to_bits(),
            self.p.auto_gain,
        )
    }

    /// One period of a −18 dBFS sine through the current shaper at the *static* drive; the
    /// compensation is the RMS ratio (in / out) in linear gain. The level-dependent boost is
    /// deliberately left out — it is the effect, not an error to undo — and so is Input, which
    /// is a true input gain on both sides.
    fn measure_auto_gain(&self) -> f32 {
        let (gain, blend) = drive_params(self.p.drive_db);
        let amp = db_to_gain(AUTO_GAIN_LEVEL_DB);
        let mut xs = [0.0f32; AUTO_GAIN_PERIOD];
        let mut ys = [0.0f32; AUTO_GAIN_PERIOD];
        for (i, (x, y)) in xs.iter_mut().zip(&mut ys).enumerate() {
            *x = amp * (std::f32::consts::TAU * i as f32 / AUTO_GAIN_PERIOD as f32).sin();
            *y = Self::shape(self.p.ty, *x, gain, blend, self.p.bias);
        }
        // The DC blocker removes the curve's DC before anyone hears it, so it doesn't count as
        // level (it matters for Tube and for Bias). Both sides are measured the same way, so a
        // clean curve (Drive 0) is exactly unity.
        (ac_power(&xs) / ac_power(&ys).max(f64::EPSILON)).sqrt() as f32
    }

    /// Re-measure the Auto Gain compensation if the curve changed; called at control rate.
    fn refresh_auto_gain(&mut self) {
        let key = self.auto_gain_key();
        if key != self.curve_key {
            let comp = if self.p.auto_gain {
                self.measure_auto_gain()
            } else {
                1.0
            };
            self.sm_auto.set_target(comp);
            self.curve_key = key;
        }
    }

    /// The settings the `"curve"` cache is valid for: type, static drive, bias.
    fn curve_key(&self) -> (u8, u32, u32) {
        (
            self.p.ty as u8,
            self.p.drive_db.to_bits(),
            self.p.bias.to_bits(),
        )
    }

    /// Rebuild the `"curve"` body when the static curve changed: 128 transfer points over
    /// input −1…+1 and the first 16 harmonic magnitudes (dB) of a sine at the Auto Gain
    /// operating level (−18 dBFS, a 16-bin DFT over one period) through the same curve.
    /// Control rate, allocation-free, only while subscribed; the level-dependent boost is
    /// deliberately left out, like in [`Self::measure_auto_gain`].
    fn refresh_curve(&mut self) {
        if !self.curve_subscribed {
            return;
        }
        let key = self.curve_key();
        if key == self.curve_cache_key {
            return;
        }
        let (gain, blend) = drive_params(self.p.drive_db);
        let (ty, bias) = (self.p.ty, self.p.bias);
        for (i, slot) in self.curve_cache.iter_mut().enumerate() {
            let x = -1.0 + 2.0 * i as f32 / (CURVE_POINTS - 1) as f32;
            *slot = Self::shape(ty, x, gain, blend, bias);
        }
        let amp = db_to_gain(AUTO_GAIN_LEVEL_DB);
        let period = AUTO_GAIN_PERIOD as f32;
        let mut re = [0.0f64; HARMONIC_COUNT];
        let mut im = [0.0f64; HARMONIC_COUNT];
        for i in 0..AUTO_GAIN_PERIOD {
            let t = std::f32::consts::TAU * i as f32 / period;
            let y = Self::shape(ty, amp * t.sin(), gain, blend, bias) as f64;
            for (k, (re, im)) in re.iter_mut().zip(&mut im).enumerate() {
                let ph = t * (k as f32 + 1.0);
                *re += y * ph.cos() as f64;
                *im -= y * ph.sin() as f64;
            }
        }
        for (k, slot) in self.curve_harmonics.iter_mut().enumerate() {
            let mag = 2.0 * (re[k] * re[k] + im[k] * im[k]).sqrt() / AUTO_GAIN_PERIOD as f64;
            *slot = (20.0 * (mag as f32).max(1.0e-8).log10()).max(HARMONIC_FLOOR_DB);
        }
        self.curve_cache_key = key;
    }

    fn reset_dsp(&mut self) {
        // Commit anything queued or mid-fade, so the running state always matches the
        // parameters afterwards.
        if let Some(ty) = self.pending_ty.take() {
            self.p.ty = ty;
        }
        self.ty_fade = 1.0;
        self.prev_type = self.p.ty;
        self.pending_os = None;
        self.os_fade = 1.0;
        self.os_next = self.os_active;
        let active = self.os_active;
        self.set_os_factor(active, self.p.oversample);
        for slot in self.os.iter_mut().chain(self.dry_os.iter_mut()) {
            slot.reset();
        }
        for dc in &mut self.dc {
            dc.reset();
        }
        for env in &mut self.env {
            env.reset();
        }
        self.boost_db = 0.0;
        self.boost_target = 0.0;
        self.boost_inc = 0.0;
        self.boost_steps = 0;
        for f in self.pre_hpf.iter_mut().chain(self.post_lpf.iter_mut()) {
            f.reset();
        }
        self.hpf_was_on = false;
        self.lpf_was_on = false;
        for tilt in &mut self.tilt {
            tilt.reset();
        }
        // Tape group: gate to its type target, everything else back to neutral so the next
        // opening (or a wake from sleep) starts clean.
        let tape = self.p.ty == SatType::Tape;
        self.sm_tape_gate.snap(if tape { 1.0 } else { 0.0 });
        let on = if tape { 1.0 } else { 0.0 };
        self.sm_wow.snap(self.p.wow * on);
        self.sm_flutter.snap(self.p.flutter * on);
        self.sm_drift.snap(self.p.drift * on);
        for f in self.bump_lp.iter_mut().chain(self.loss_lpf.iter_mut()) {
            f.reset();
        }
        for f in &mut self.env_squash {
            f.reset();
        }
        self.loss_cut_g = 0.0;
        self.sq_drive = 0.0;
        self.noise_gain = noise_level_gain(self.p.noise_db);
        self.tape_was_active = tape;
        for line in self.delay.iter_mut().chain(self.dry_delay.iter_mut()) {
            line.clear();
        }
        self.mod_running = false;
        self.wow_osc = SineOsc::new(WOW_HZ, self.sample_rate);
        self.flut_osc = SineOsc::new(FLUTTER_HZ, self.sample_rate);
        self.flut_osc_2 = SineOsc::new(FLUTTER_HZ_2, self.sample_rate);
        self.drift = DriftGen::new();
        self.noise = [
            PinkNoise::new(NOISE_SEEDS[0]),
            PinkNoise::new(NOISE_SEEDS[1]),
        ];
        self.sm_comp.snap(Self::comp_target(self.p.mix));
        self.comp_running = false;
        self.sm_drive.snap(self.p.drive_db);
        self.sm_bias.snap(self.p.bias);
        self.sm_input.snap(db_to_gain(self.p.input_db));
        self.sm_mix.snap(self.p.mix);
        self.sm_output.snap(db_to_gain(self.p.output_db));
        // Recompute the cached control-rate values on the next frame.
        self.drive_key = u32::MAX;
        self.bump_g = db_to_gain(self.p.head_bump_db * self.sm_tape_gate.current());
        let comp = if self.p.auto_gain {
            self.measure_auto_gain()
        } else {
            1.0
        };
        self.sm_auto.snap(comp);
        self.curve_key = self.auto_gain_key();
    }
}

impl AudioDevice for SaturatorDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_active || !self.is_enabled {
            pass_through(inputs, outputs, sample_count);
            return;
        }
        let n = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        if n == 0 {
            self.sleep.on_block(sample_count);
            return;
        }
        let out = &mut outputs[..n * 2];
        let input = &inputs[..n * 2];
        if self.sleep.is_sleeping() && crate::audio::devices::has_audio_signal(input) {
            // Waking up (ADR 0008): start the filters and envelopes from reset so the first
            // hit is clean — identical to a freshly prepared device, no click from stale
            // state. `update_sleep_state` covers the host-driven wake the same way.
            self.sleep.wake();
            self.reset_dsp();
        }
        let sr = self.sample_rate;
        let settled = self.sm_input.is_settled()
            && self.sm_drive.is_settled()
            && self.sm_bias.is_settled()
            && self.sm_mix.is_settled()
            && self.sm_output.is_settled()
            && self.sm_auto.is_settled();
        let tape_settled = self.sm_tape_gate.is_settled();
        // The tape group runs while the gate is moving or open; settled at 0 it short-circuits.
        let tape_active = !(tape_settled && self.sm_tape_gate.current() <= 0.0);
        let bump_coef = one_pole_g(BUMP_HZ, sr);

        // Tone coefficients, per control block. Off values skip their filters entirely; one
        // that switches on starts from reset, so it never replays stale state.
        let hpf_on = self.p.pre_hpf_hz > 0.0;
        if hpf_on && !self.hpf_was_on {
            for f in &mut self.pre_hpf {
                f.reset();
            }
        }
        self.hpf_was_on = hpf_on;
        let hpf_c = SvfCoefs::new(
            cutoff_to_g(self.p.pre_hpf_hz.max(1.0), sr),
            BUTTERWORTH_K,
            FilterMode::Hp12,
        );
        let lpf_on = self.p.post_lpf_hz < LPF_OFF_HZ;
        if lpf_on && !self.lpf_was_on {
            for f in &mut self.post_lpf {
                f.reset();
            }
        }
        self.lpf_was_on = lpf_on;
        let lpf_c = SvfCoefs::new(
            cutoff_to_g(self.p.post_lpf_hz, sr),
            BUTTERWORTH_K,
            FilterMode::Lp12,
        );
        let tilt_on = self.p.tilt_db.abs() > TILT_NEUTRAL_DB;
        let tilt_gain = if tilt_on {
            db_to_gain(self.p.tilt_db)
        } else {
            1.0
        };
        let (a1, a2, a3) = TiltSplit::coefs(sr);

        // Base-rate pass: input gain (both sides), Low Cut, the level-dependence envelope, and
        // the per-frame values the (oversampled) shaper and the output stage need. Smoothed
        // per sample; held across the block's high-rate frames.
        for (k, frame) in input.chunks_exact(2).enumerate() {
            let (in_gain, drive_db, bias, mix, out_gain) = if settled {
                (
                    self.sm_input.current(),
                    self.sm_drive.current(),
                    self.sm_bias.current(),
                    self.sm_mix.current(),
                    self.sm_output.current() * self.sm_auto.current(),
                )
            } else {
                (
                    self.sm_input.next(),
                    self.sm_drive.next(),
                    self.sm_bias.next(),
                    self.sm_mix.next(),
                    self.sm_output.next() * self.sm_auto.next(),
                )
            };
            let (l, r) = (finite(frame[0]) * in_gain, finite(frame[1]) * in_gain);
            self.dry_buf[2 * k] = l;
            self.dry_buf[2 * k + 1] = r;
            let (mut wl, mut wr) = (l, r);
            if hpf_on {
                wl = self.pre_hpf[0].process(wl, FilterMode::Hp12, &hpf_c, 0.0, 0.0);
                wr = self.pre_hpf[1].process(wr, FilterMode::Hp12, &hpf_c, 0.0, 0.0);
            }
            self.env[0].track(wl);
            self.env[1].track(wr);
            let gate = if tape_settled {
                self.sm_tape_gate.current()
            } else {
                self.sm_tape_gate.next()
            };
            self.frame_gate[k] = gate;
            if k % CTRL_BLOCK == 0 {
                // Level-dependent drive: up to ±12 dB around a −18 dBFS reference, ramped
                // linearly to over the next control block. The product with `level_depend` is
                // exactly 0.0 at 0 %, so the path equals the static curve.
                let env_db = 20.0
                    * self.env[0]
                        .value()
                        .max(self.env[1].value())
                        .max(ENV_FLOOR)
                        .log10();
                self.env_db = env_db;
                let target = self.p.level_depend * (env_db + 18.0).clamp(-12.0, 12.0);
                if target != self.boost_target || self.boost_steps > 0 {
                    self.boost_target = target;
                    self.boost_inc = (target - self.boost_db) / CTRL_BLOCK as f32;
                    self.boost_steps = CTRL_BLOCK;
                }
                self.effective_drive_db = drive_db + target;
                self.refresh_auto_gain();
                self.refresh_curve();
                self.bump_g = db_to_gain(self.p.head_bump_db * gate);
                if tape_active {
                    if !self.tape_was_active {
                        // (Re-)activating: start the followers and filters from reset.
                        for f in self.bump_lp.iter_mut().chain(self.loss_lpf.iter_mut()) {
                            f.reset();
                        }
                        for f in &mut self.env_squash {
                            f.reset();
                        }
                        self.sq_drive = 0.0;
                        self.tape_was_active = true;
                    }
                    let hf_eff = self.p.hf_loss * gate;
                    self.loss_cut_g = if hf_eff > 0.0 {
                        // How hard the tape is hit: the input level plus the drive. Harder →
                        // cutoff down.
                        let hit_db = env_db + self.effective_drive_db.max(0.0);
                        let fall = ((hit_db - LOSS_REF_DB) / LOSS_SPAN_DB).clamp(0.0, 1.0);
                        let cutoff = LPF_OFF_HZ * (2.0f32).powf(-LOSS_MAX_OCTAVES * hf_eff * fall);
                        one_pole_g(cutoff, sr)
                    } else {
                        0.0
                    };
                    self.noise_gain = noise_level_gain(self.p.noise_db);
                } else {
                    self.loss_cut_g = 0.0;
                    self.sq_drive = 0.0;
                    self.tape_was_active = false;
                }
            }
            if self.boost_steps > 0 {
                self.boost_steps -= 1;
                // Land exactly on the target, so a settled boost carries no rounding residue.
                self.boost_db = if self.boost_steps == 0 {
                    self.boost_target
                } else {
                    self.boost_db + self.boost_inc
                };
            }
            // The gain/blend pair only changes when the effective drive does; while settled
            // (the common case) the `powf` in `drive_params` runs at control rate only.
            let drive_eff = drive_db + self.boost_db;
            if drive_eff.to_bits() != self.drive_key {
                let (gain, blend) = drive_params(drive_eff);
                self.last_gain = gain;
                self.last_blend = blend;
                self.drive_key = drive_eff.to_bits();
            }
            self.wet_in[2 * k] = wl;
            self.wet_in[2 * k + 1] = wr;
            self.frame_gain[k] = self.last_gain;
            self.frame_blend[k] = self.last_blend;
            self.frame_bias[k] = bias;
            let (dry, wet) = dry_wet_gains(mix, MixLaw::Linear);
            self.frame_dry[k] = dry;
            self.frame_wet[k] = wet;
            self.frame_out[k] = out_gain;
        }

        // The shaper, wrapped in the active Oversampler. A type change crossfades prev → cur
        // per oversampled frame, the filter.rs `fade_inc` pattern.
        let ty_cur = self.p.ty;
        let ty_prev = self.prev_type;
        let fade_inc_for = |factor: usize| 1.0 / (SWITCH_FADE_MS * 0.001 * sr * factor as f32);
        let fade_inc_a = fade_inc_for(self.os[self.os_active].factor());
        let fade_inc_b = fade_inc_for(self.os[self.os_next].factor());
        let gain = &self.frame_gain[..n];
        let blend = &self.frame_blend[..n];
        let bias = &self.frame_bias[..n];
        let mut ty_a = self.ty_fade;
        let mut ty_b = ty_a;
        let (active, next) = (self.os_active, self.os_next);
        self.os[active].process(
            &self.wet_in[..n * 2],
            &mut self.wet_out[..n * 2],
            n,
            |buf| {
                Self::shape_block(
                    ty_cur, ty_prev, &mut ty_a, fade_inc_a, gain, blend, bias, buf,
                )
            },
        );

        // The dry compensation: the same oversampler round trip with no stage, so the dry side
        // gets the wet side's exact phase response. Starts from reset when it (re)starts.
        let comp_on = !(self.sm_comp.is_settled() && self.sm_comp.current() <= 0.0);
        if comp_on {
            if !self.comp_running {
                for slot in &mut self.dry_os {
                    slot.reset();
                }
                for line in &mut self.dry_delay {
                    line.clear();
                }
                self.comp_running = true;
            }
            self.dry_os[active].process(
                &self.dry_buf[..n * 2],
                &mut self.dry_comp[..n * 2],
                n,
                |_| {},
            );
        } else {
            self.comp_running = false;
        }

        // A QUALITY change crossfades the running instance over to the freshly prepared one,
        // per base-rate frame; the new one becomes active once the fade settles. The dry twins
        // follow the same per-frame fade.
        let fading = self.os_fade < 1.0;
        if fading {
            self.os[next].process(
                &self.wet_in[..n * 2],
                &mut self.wet_alt[..n * 2],
                n,
                |buf| {
                    Self::shape_block(
                        ty_cur, ty_prev, &mut ty_b, fade_inc_b, gain, blend, bias, buf,
                    )
                },
            );
            let inc = 1.0 / (SWITCH_FADE_MS * 0.001 * sr);
            for (k, (o, a)) in self.wet_out[..n * 2]
                .chunks_exact_mut(2)
                .zip(self.wet_alt[..n * 2].chunks_exact(2))
                .enumerate()
            {
                let f = self.os_fade;
                self.frame_osf[k] = f;
                o[0] += (a[0] - o[0]) * f;
                o[1] += (a[1] - o[1]) * f;
                self.os_fade = (f + inc).min(1.0);
            }
            if comp_on {
                self.dry_os[next].process(
                    &self.dry_buf[..n * 2],
                    &mut self.dry_alt[..n * 2],
                    n,
                    |_| {},
                );
                for (k, (o, a)) in self.dry_comp[..n * 2]
                    .chunks_exact_mut(2)
                    .zip(self.dry_alt[..n * 2].chunks_exact(2))
                    .enumerate()
                {
                    let f = self.frame_osf[k];
                    o[0] += (a[0] - o[0]) * f;
                    o[1] += (a[1] - o[1]) * f;
                }
            }
            if self.os_fade >= 1.0 {
                self.os_active = self.os_next;
                if let Some(factor) = self.pending_os.take() {
                    if factor != self.os[self.os_active].factor() {
                        self.start_quality_fade(factor);
                    }
                }
            }
        }
        self.ty_fade = ty_a.max(ty_b);
        if self.ty_fade >= 1.0 {
            if let Some(ty) = self.pending_ty.take() {
                if ty != self.p.ty {
                    self.start_type_fade(ty);
                }
            }
        }

        // Modulation (Wow / Flutter / Drift) runs while any depth is nonzero or gliding.
        let mod_settled =
            self.sm_wow.is_settled() && self.sm_flutter.is_settled() && self.sm_drift.is_settled();
        let mod_active = !(mod_settled
            && self.sm_wow.current() <= 0.0
            && self.sm_flutter.current() <= 0.0
            && self.sm_drift.current() <= 0.0);
        if mod_active && !self.mod_running {
            // (Re)starting the lines from silence, so the growing delay never digs up stale
            // audio. A knob opened from 0 glides the depth up from the newest sample; after a
            // reset the depth may start in full, and the first few ms read that silence.
            for line in self.delay.iter_mut().chain(self.dry_delay.iter_mut()) {
                line.clear();
            }
            self.wow_osc = SineOsc::new(WOW_HZ, sr);
            self.flut_osc = SineOsc::new(FLUTTER_HZ, sr);
            self.flut_osc_2 = SineOsc::new(FLUTTER_HZ_2, sr);
            self.drift = DriftGen::new();
            self.mod_running = true;
        } else if !mod_active {
            // Every depth closed: stop feeding. The lines themselves are not touched, so a
            // modulation-free render stays deterministic.
            self.mod_running = false;
        }
        let dc_a = self.dc_a;
        let comp_settled = self.sm_comp.is_settled();

        // DC blocker, then the tape stages, the modulation, the post tone stages (High Cut,
        // Tone) and the output stage.
        for (k, o) in out.chunks_exact_mut(2).enumerate() {
            let (dry_w, wet_w, out_gain) =
                (self.frame_dry[k], self.frame_wet[k], self.frame_out[k]);
            let (raw_l, raw_r) = (self.dry_buf[2 * k], self.dry_buf[2 * k + 1]);
            let (mut wl, mut wr) = (
                self.dc[0].tick(self.wet_out[2 * k], dc_a),
                self.dc[1].tick(self.wet_out[2 * k + 1], dc_a),
            );
            // The dry side's compensated twin (before the modulation's centre delay).
            let (mut cl, mut cr) = if comp_on {
                (self.dry_comp[2 * k], self.dry_comp[2 * k + 1])
            } else {
                (raw_l, raw_r)
            };
            // Tape stages: head bump → level-dependent HF loss → squash → noise, all behind
            // the smoothed `tape_gate`. Every stage is exactly neutral at amount × gate = 0,
            // and the whole group short-circuits once the gate has settled at 0.
            let gate = self.frame_gate[k];
            let (mut nl, mut nr) = (0.0, 0.0);
            if tape_active {
                // Head bump: one-pole low shelf — the low band (`bump_lp`) is gained, the
                // high band is the input minus the same lowpass, so gain 1 is an exact bypass.
                // While the gate has settled the gain only changes at control rate.
                let bump_g = if tape_settled {
                    self.bump_g
                } else {
                    db_to_gain(self.p.head_bump_db * gate)
                };
                if bump_g != 1.0 {
                    let l0 = self.bump_lp[0].lowpass(wl, bump_coef);
                    let l1 = self.bump_lp[1].lowpass(wr, bump_coef);
                    wl = l0 * bump_g + (wl - l0);
                    wr = l1 * bump_g + (wr - l1);
                }
                if self.loss_cut_g > 0.0 {
                    wl = self.loss_lpf[0].lowpass(wl, self.loss_cut_g);
                    wr = self.loss_lpf[1].lowpass(wr, self.loss_cut_g);
                }
                // Squash: soft-clip-based peak compression of the shaper's output. The drive
                // multiplier rises with that signal's peak envelope; at 0 the stage is out.
                let sq = self.p.squash * gate;
                if sq > 0.0 {
                    self.env_squash[0].track(wl);
                    self.env_squash[1].track(wr);
                    if k % CTRL_BLOCK == 0 || self.sq_drive == 0.0 {
                        let peak_db = 20.0
                            * self.env_squash[0]
                                .value()
                                .max(self.env_squash[1].value())
                                .max(ENV_FLOOR)
                                .log10();
                        let rise = ((peak_db - SQ_START_DB) / SQ_SPAN_DB).clamp(0.0, 1.0);
                        self.sq_drive = 1.0 + SQ_MAX_DRIVE * sq * rise;
                    }
                    wl += sq * (soft_clip(wl * self.sq_drive) / self.sq_drive - wl);
                    wr += sq * (soft_clip(wr * self.sq_drive) / self.sq_drive - wr);
                }
                // Seeded pink noise at the Noise level (added after Auto Gain below, so the
                // level reads true), scaled by the gate.
                if self.noise_gain > 0.0 {
                    let ng = self.noise_gain * gate;
                    nl = self.noise[0].next() * ng;
                    nr = self.noise[1].next() * ng;
                }
            }
            // Wow / flutter / drift: the wet delay swings around a centre delay equal to the
            // sum of the depths (so it never goes negative), and the dry side is delayed by
            // that centre, so the two stay aligned on average and Mix doesn't flange.
            if mod_active {
                let (w, f, d) = if mod_settled {
                    (
                        self.sm_wow.current(),
                        self.sm_flutter.current(),
                        self.sm_drift.current(),
                    )
                } else {
                    (
                        self.sm_wow.next(),
                        self.sm_flutter.next(),
                        self.sm_drift.next(),
                    )
                };
                if k % CTRL_BLOCK == 0 {
                    self.wow_osc.renormalize();
                    self.flut_osc.renormalize();
                    self.flut_osc_2.renormalize();
                }
                let dw = WOW_MAX_SECONDS * sr * w;
                let df = FLUTTER_MAX_SECONDS * sr * f;
                let dd = DRIFT_MAX_SECONDS * sr * d;
                let centre = dw + df + dd;
                let flutter = FLUTTER_MIX * self.flut_osc.next()
                    + (1.0 - FLUTTER_MIX) * self.flut_osc_2.next();
                let drift = if dd > 0.0 { self.drift.next(sr) } else { 0.0 };
                let swing = dw * self.wow_osc.next() + df * flutter + dd * drift;
                let delay = (centre + swing).max(0.0);
                self.delay[0].push(wl);
                self.delay[1].push(wr);
                wl = read_delay(&self.delay[0], delay);
                wr = read_delay(&self.delay[1], delay);
                // The dry twin only matters while both sides are heard; it is cleared when the
                // compensation (re)starts, so it never replays stale audio.
                if comp_on {
                    self.dry_delay[0].push(cl);
                    self.dry_delay[1].push(cr);
                    cl = read_delay(&self.dry_delay[0], centre);
                    cr = read_delay(&self.dry_delay[1], centre);
                }
            }
            if lpf_on {
                wl = self.post_lpf[0].process(wl, FilterMode::Lp12, &lpf_c, 0.0, 0.0);
                wr = self.post_lpf[1].process(wr, FilterMode::Lp12, &lpf_c, 0.0, 0.0);
            }
            if tilt_on {
                let l0 = self.tilt[0].lowpass(wl, a1, a2, a3);
                let l1 = self.tilt[1].lowpass(wr, a1, a2, a3);
                wl = l0 + (wl - l0) * tilt_gain;
                wr = l1 + (wr - l1) * tilt_gain;
            }
            // Dry: the plain signal, crossfaded to its compensated twin while both sides are
            // heard. At weight 0 it is exactly the input-trimmed input (Mix 0 % bit-exact).
            let (dl, dr) = if comp_on || mod_active {
                let c = if comp_settled {
                    self.sm_comp.current()
                } else {
                    self.sm_comp.next()
                };
                (raw_l + c * (cl - raw_l), raw_r + c * (cr - raw_r))
            } else {
                (raw_l, raw_r)
            };
            o[0] = dl * dry_w + (wl * out_gain + nl) * wet_w;
            o[1] = dr * dry_w + (wr * out_gain + nr) * wet_w;
        }
        self.frames_since_poll += n;
        self.sleep.on_block(n);
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        let Some((_, real)) = self.values.set(param_id, value) else {
            return;
        };
        self.sleep.wake();
        self.apply(param_id, real);
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        let Some((_, real)) = self.values.set_offset(param_id, offset) else {
            return;
        };
        self.sleep.wake();
        self.apply(param_id, real);
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.values.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.saturator"
    }

    fn device_name(&self) -> &str {
        "Saturator"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Effect
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        TABLE.infos()
    }

    fn reset(&mut self) {
        self.reset_dsp();
    }

    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        self.sample_rate = sample_rate;
        self.poll_interval = (sample_rate / DATA_RATE_HZ) as usize;
        self.dc_a = DcBlocker::coef(sample_rate);
        self.prepare_buffers(max_frames);
        for smoother in [
            &mut self.sm_drive,
            &mut self.sm_bias,
            &mut self.sm_input,
            &mut self.sm_mix,
            &mut self.sm_output,
            &mut self.sm_auto,
        ] {
            smoother.set_ramp(sample_rate, RAMP_MS);
        }
        for smoother in [&mut self.sm_wow, &mut self.sm_flutter, &mut self.sm_drift] {
            smoother.set_ramp(sample_rate, MOD_RAMP_MS);
        }
        // The gate and the compensation ride the type crossfade's time.
        self.sm_tape_gate.set_ramp(sample_rate, SWITCH_FADE_MS);
        self.sm_comp.set_ramp(sample_rate, SWITCH_FADE_MS);
        for env in &mut self.env {
            env.set_times(ENV_ATTACK_MS, ENV_RELEASE_MS, sample_rate);
        }
        for env in &mut self.env_squash {
            env.set_times(SQ_ATTACK_MS, SQ_RELEASE_MS, sample_rate);
        }
        self.sleep.set_sample_rate(sample_rate);
        self.reset_dsp();
    }

    fn latency_frames(&self) -> u32 {
        0
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        self.is_active = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.is_active = false;
        self.reset_dsp();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    fn is_sleeping(&self) -> bool {
        self.sleep.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.sleep.wake();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        // While the curve view watches, keep running so the operating point keeps moving.
        let changed = self
            .sleep
            .update(has_audio_activity || self.curve_subscribed);
        if changed && !self.sleep.is_sleeping() {
            // Waking (ADR 0008): start from reset so the first hit is clean.
            self.reset_dsp();
        }
        changed
    }

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if data_type != "curve" {
            return Err(format!("Saturator does not support '{data_type}' data"));
        }
        if !self.curve_subscribed {
            self.frames_since_poll = 0;
            self.curve_subscribed = true;
            // Build the body right away, so the first poll never carries a stale curve even
            // before the next control block runs.
            self.refresh_curve();
        }
        self.sleep.wake();
        Ok(())
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "curve" {
            self.curve_subscribed = false;
        }
    }

    /// One fixed-size record ([`BYTES`]): `effective_drive_db`, `env_db`, then [`CURVE_POINTS`]
    /// transfer points over input −1…+1 and [`HARMONIC_COUNT`] harmonic magnitudes in dB,
    /// all little-endian f32 — the same byte encoding as the compressor's `"dynamics"`
    /// records, one record per poll (about [`DATA_RATE_HZ`]) while subscribed.
    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        if !self.curve_subscribed || self.frames_since_poll < self.poll_interval {
            return None;
        }
        self.frames_since_poll = 0;
        // In case the curve changed without a control block since (e.g. the device is idle).
        self.refresh_curve();
        let mut bytes = Vec::with_capacity(BYTES);
        bytes.extend_from_slice(&self.effective_drive_db.to_le_bytes());
        bytes.extend_from_slice(&self.env_db.to_le_bytes());
        for value in self.curve_cache.iter().copied().chain(self.curve_harmonics) {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        Some(("curve".to_string(), bytes))
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{
        impulse, peak, render, rms, sine, spectrum_db, stereo, to_db, tone_amplitude, white_noise,
    };

    const SR: f32 = 48_000.0;

    fn device() -> SaturatorDevice {
        let mut d = SaturatorDevice::new(SR);
        d.prepare(SR, 4_096);
        d
    }

    fn set_real(d: &mut SaturatorDevice, id: ParamId, real: f32) {
        let spec = TABLE.spec(id).unwrap();
        d.set_parameter(id, spec.to_norm(real));
    }

    fn set_choice(d: &mut SaturatorDevice, id: ParamId, index: usize) {
        set_real(d, id, index as f32);
    }

    #[test]
    fn nineteen_parameters_with_the_design_defaults() {
        let d = device();
        let infos = d.parameters();
        assert_eq!(infos.len(), 19);
        let real = |id: ParamId| {
            let spec = TABLE.spec(id).unwrap();
            let norm = d.get_parameter(id).unwrap();
            spec.to_real(norm)
        };
        assert_eq!(real(SAT_TYPE) as usize, 0, "Type defaults to Soft");
        assert_eq!(real(DRIVE), 6.0);
        assert_eq!(real(BIAS), 0.0);
        assert_eq!(real(LEVEL_DEPEND), 0.0);
        assert_eq!(real(INPUT), 0.0);
        assert_eq!(real(QUALITY) as usize, 1, "Quality defaults to 2x");
        assert!(!TABLE.spec(QUALITY).unwrap().automatable);
        assert!(TABLE.spec(SAT_TYPE).unwrap().automatable);
        assert_eq!(real(PRE_HPF), 0.0, "Low Cut defaults to Off");
        assert_eq!(real(POST_LPF), LPF_OFF_HZ, "High Cut defaults to Off");
        assert_eq!(real(TILT), 0.0);
        assert_eq!(real(HF_LOSS), 50.0);
        assert_eq!(real(HEAD_BUMP), 2.0);
        assert!((real(SQUASH) - 30.0).abs() < 1e-3);
        assert_eq!(real(WOW), 0.0);
        assert_eq!(real(FLUTTER), 0.0);
        assert_eq!(real(DRIFT), 0.0);
        assert_eq!(real(NOISE), NOISE_OFF_DB, "Noise defaults to Off");
        assert_eq!(real(MIX), 100.0);
        assert_eq!(real(OUTPUT), 0.0);
        assert_eq!(real(AUTO_GAIN), 1.0);
    }

    #[test]
    fn mix_zero_is_bit_exact_at_maximum_drive() {
        let mut d = device();
        set_real(&mut d, DRIVE, 36.0);
        set_real(&mut d, BIAS, 100.0);
        set_real(&mut d, WOW, 100.0);
        set_real(&mut d, MIX, 0.0);
        // Let the smoothers settle before comparing.
        render(&mut d, &vec![0.0; (SR as usize / 10) * 2], &[512]);
        let input = stereo(&white_noise(SR as usize / 2, 0.9, 3));
        assert_eq!(render(&mut d, &input, &[512]), input);
    }

    /// Ratio of the 2nd harmonic to the fundamental for a 1 kHz sine of amplitude `amp` at
    /// `bias` (%) and `drive` (dB).
    fn second_to_first(ty: usize, bias: f32, drive: f32, amp: f32) -> f32 {
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, ty);
        set_real(&mut d, BIAS, bias);
        set_real(&mut d, DRIVE, drive);
        // 48 cycles of 1 kHz in 48_000 frames.
        let frames = 48_000;
        let out = render(&mut d, &stereo(&sine(1_000.0, SR, frames, amp)), &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let fund = tone_amplitude(&left[frames / 2..], 1_000.0, SR);
        tone_amplitude(&left[frames / 2..], 2_000.0, SR) / fund
    }

    #[test]
    fn soft_type_is_odd_and_tube_type_is_not() {
        let soft = second_to_first(0, 0.0, 36.0, 0.9);
        assert!(soft < 1e-3, "soft 2nd/1st harmonic {soft}");
        // Tube is asymmetric on its own, without any Bias, at a musical drive.
        let tube = second_to_first(1, 0.0, 12.0, 0.5);
        assert!(tube > 0.05, "tube 2nd/1st harmonic {tube}");
    }

    #[test]
    fn output_has_no_dc() {
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, 1); // Tube
        set_real(&mut d, BIAS, 100.0);
        set_real(&mut d, DRIVE, 36.0);
        let frames = 48_000;
        let out = render(&mut d, &stereo(&sine(1_000.0, SR, frames, 0.5)), &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let tail = &left[frames / 2..];
        let mean = tail.iter().sum::<f32>() / tail.len() as f32;
        assert!(mean.abs() < 1e-3, "DC {mean} ({} dBFS)", to_db(mean.abs()));
    }

    #[test]
    fn nan_and_inf_input_stay_finite() {
        let mut d = device();
        set_real(&mut d, DRIVE, 24.0);
        set_real(&mut d, BIAS, 50.0);
        let mut mono = white_noise(9_600, 0.9, 5);
        mono[100] = f32::NAN;
        mono[200] = f32::INFINITY;
        mono[300] = f32::NEG_INFINITY;
        let out = render(&mut d, &stereo(&mono), &[512, 37]);
        assert!(out.iter().all(|x| x.is_finite()));
    }

    #[test]
    fn type_change_does_not_click() {
        let frames = 48_000;
        let input = stereo(&sine(220.0, SR, frames, 0.7));
        for from in 0..4 {
            for to in 0..4 {
                if from == to {
                    continue;
                }
                let mut d = device();
                set_choice(&mut d, SAT_TYPE, from);
                set_real(&mut d, DRIVE, 18.0);
                set_real(&mut d, BIAS, 50.0);
                let mut out = render(&mut d, &input[..frames / 2], &[256]);
                set_choice(&mut d, SAT_TYPE, to);
                out.extend(render(&mut d, &input[frames / 2..], &[256]));
                let left: Vec<f32> = out.iter().step_by(2).copied().collect();
                let worst_step = left
                    .windows(2)
                    .map(|w| (w[1] - w[0]).abs())
                    .fold(0.0, f32::max);
                assert!(worst_step <= 0.4, "type {from}->{to}: step {worst_step}");
                assert!(peak(&left) < 2.0, "type {from}->{to}: peak {}", peak(&left));
            }
        }
    }

    /// Non-harmonic energy (dB, relative to the fundamental's power) for a hard-driven 7 kHz
    /// sine at the given Quality. 24_000 frames = 3 500 whole cycles.
    fn alias_energy_db(quality: usize) -> f32 {
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, 3); // Hard, the type most in need of oversampling
        set_real(&mut d, DRIVE, 36.0);
        set_choice(&mut d, QUALITY, quality);
        let frames = 48_000;
        let out = render(&mut d, &stereo(&sine(7_000.0, SR, frames, 0.3)), &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let window = &left[24_000..48_000];
        let bins = spectrum_db(window);
        let fund = tone_amplitude(window, 7_000.0, SR);
        let bin_hz = SR / window.len() as f32;
        let mut energy = 0.0f64;
        for (i, &level) in bins.iter().enumerate() {
            let hz = i as f32 * bin_hz;
            let harmonic = (hz / 7_000.0).round();
            let near_harmonic = (hz - harmonic * 7_000.0).abs() < 4.0 * bin_hz && harmonic >= 1.0;
            if !near_harmonic && hz > 100.0 {
                energy += 10f64.powf((level - to_db(fund)) as f64 / 10.0);
            }
        }
        (10.0 * energy.log10()) as f32
    }

    #[test]
    fn oversampling_reduces_aliasing() {
        let at_1x = alias_energy_db(0);
        let at_4x = alias_energy_db(2);
        println!("alias energy: 1x {at_1x:.1} dB, 4x {at_4x:.1} dB");
        assert!(at_1x - at_4x >= 6.0, "1x {at_1x} dB, 4x {at_4x} dB");
    }

    #[test]
    fn quality_switch_does_not_click() {
        let frames = 96_000;
        let input = stereo(&sine(300.0, SR, frames, 0.5));
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, 3); // Hard
        set_real(&mut d, DRIVE, 24.0);
        let mut out = render(&mut d, &input[..frames / 2], &[256]);
        // Flip the Quality mid-stream; each stretch is longer than the crossfade.
        for (i, chunk) in input[frames / 2..].chunks(2_000).enumerate() {
            set_choice(&mut d, QUALITY, i % 3);
            out.extend(render(&mut d, chunk, &[1_000]));
        }
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        assert!(left.iter().all(|x| x.is_finite()));
        let worst_step = left
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        assert!(worst_step <= 0.5, "quality switch: step {worst_step}");
        assert!(peak(&left) < 2.0, "peak {}", peak(&left));
    }

    #[test]
    fn latency_is_zero_at_every_quality() {
        for quality in 0..3 {
            let mut d = device();
            set_choice(&mut d, QUALITY, quality);
            assert_eq!(d.latency_frames(), 0, "quality {quality}");
            // While the crossfade runs, the new factor lives on the incoming slot.
            assert_eq!(d.os[d.os_next].factor(), 1 << quality);
        }
    }

    /// Harmonic distortion (dB, relative to the fundamental's power) over the first `harmonics`
    /// harmonics of `freq` — `10·log₁₀(Σ harmonics² / fundamental²)`.
    fn thd_db(signal: &[f32], freq: f32, harmonics: usize) -> f32 {
        let fund = tone_amplitude(signal, freq, SR);
        assert!(fund > 0.0, "no fundamental at {freq}");
        let mut power = 0.0f64;
        for h in 2..=harmonics {
            let a = tone_amplitude(signal, freq * h as f32, SR);
            power += (a * a) as f64;
        }
        (10.0 * (power / ((fund * fund) as f64)).log10()) as f32
    }

    #[test]
    fn level_depend_widens_the_thd_gap() {
        let frames = 24_000; // long enough for the 150 ms release to settle
        let input_for =
            |level_db: f32| stereo(&sine(1_000.0, SR, frames, 10f32.powf(level_db / 20.0)));
        let quiet = input_for(-18.0);
        let loud = input_for(-6.0);
        let thd = |depend: f32, input: &[f32]| {
            let mut d = device();
            set_real(&mut d, DRIVE, 12.0);
            set_real(&mut d, LEVEL_DEPEND, depend);
            let out = render(&mut d, input, &[512]);
            let left: Vec<f32> = out.iter().step_by(2).copied().collect();
            thd_db(&left[frames / 2..], 1_000.0, 8)
        };
        let gap_at_0 = thd(0.0, &loud) - thd(0.0, &quiet);
        let gap_at_100 = thd(100.0, &loud) - thd(100.0, &quiet);
        println!("THD gap: 0 % {gap_at_0:.2} dB, 100 % {gap_at_100:.2} dB");
        assert!(
            gap_at_100 > gap_at_0 + 3.0,
            "gap at 0 % {gap_at_0} vs 100 % {gap_at_100}"
        );
    }

    #[test]
    fn level_depend_zero_nulls_against_static_curve() {
        let frames = 24_000;
        let input = stereo(&sine(300.0, SR, frames, 0.4));
        // A device that ran with level dependence on first, so any leftover boost would show.
        let mut d = device();
        set_real(&mut d, DRIVE, 18.0);
        set_real(&mut d, LEVEL_DEPEND, 100.0);
        let _warm = render(&mut d, &input, &[512]);
        set_real(&mut d, LEVEL_DEPEND, 0.0);
        // The audio thread flushes denormals every block; do the same here, so the exponential
        // tail (DC blocker, oversampler) the warm render left behind decays to exact zero
        // instead of haunting the first samples as subnormals.
        crate::audio::dsp::denormal::flush_denormals_to_zero();
        let silence = vec![0.0; SR as usize * 4];
        let _settle = render(&mut d, &silence, &[512]);
        let out = render(&mut d, &input, &[512]);
        // Reference: a fresh device that never had level dependence, settled the same way.
        let mut r = device();
        set_real(&mut r, DRIVE, 18.0);
        let _settle = render(&mut r, &silence, &[512]);
        let reference = render(&mut r, &input, &[512]);
        assert_eq!(out, reference, "0 % level dependence must be bit-exact");
    }

    #[test]
    fn auto_gain_tracks_drive() {
        let frames = 24_000;
        let input = stereo(&sine(1_000.0, SR, frames, 10f32.powf(-18.0 / 20.0)));
        let rms_db_at = |drive: f32| {
            let mut d = device();
            set_real(&mut d, DRIVE, drive);
            assert!(d.p.auto_gain, "Auto Gain defaults to on");
            let out = render(&mut d, &input, &[512]);
            let left: Vec<f32> = out.iter().step_by(2).copied().collect();
            to_db(rms(&left[frames / 2..]))
        };
        let at_0 = rms_db_at(0.0);
        let at_36 = rms_db_at(36.0);
        println!("auto gain RMS: drive 0 {at_0:.2} dB, drive 36 {at_36:.2} dB");
        assert!(
            (at_36 - at_0).abs() <= 3.0,
            "drive 0 {at_0} dB vs drive 36 {at_36} dB"
        );
    }

    #[test]
    fn input_trim_is_gain_and_output_trim_is_gain() {
        let frames = 24_000;
        let input = stereo(&sine(1_000.0, SR, frames, 0.25));
        let rms_db_at = |input_db: f32, output_db: f32| {
            let mut d = device();
            set_real(&mut d, DRIVE, 0.0);
            set_real(&mut d, INPUT, input_db);
            set_real(&mut d, OUTPUT, output_db);
            let silence = vec![0.0; (SR as usize / 10) * 2];
            let _settle = render(&mut d, &silence, &[512]);
            let out = render(&mut d, &input, &[512]);
            let left: Vec<f32> = out.iter().step_by(2).copied().collect();
            to_db(rms(&left[frames / 2..]))
        };
        let base = rms_db_at(0.0, 0.0);
        let in_up = rms_db_at(12.0, 0.0);
        let out_up = rms_db_at(0.0, 12.0);
        assert!(
            (in_up - base - 12.0).abs() <= 1.0,
            "input trim: {base} -> {in_up}"
        );
        assert!(
            (out_up - base - 12.0).abs() <= 1.0,
            "output trim: {base} -> {out_up}"
        );
    }

    #[test]
    fn post_tone_cuts_harsh_band_but_keeps_lows() {
        let frames = 48_000;
        let input = stereo(&sine(200.0, SR, frames, 0.5));
        let render_with = |tilt_db: f32| {
            let mut d = device();
            set_real(&mut d, DRIVE, 24.0);
            set_real(&mut d, TILT, tilt_db);
            let out = render(&mut d, &input, &[512]);
            out.iter().step_by(2).copied().collect::<Vec<f32>>()
        };
        let flat = render_with(0.0);
        let dark = render_with(-9.0);
        let tail = frames / 2;
        let amp = |sig: &[f32], h: usize| tone_amplitude(&sig[tail..], 200.0 * h as f32, SR);
        // Band energy of the 2–5 kHz harmonics (odd multiples of 200 Hz live there).
        let band_power = |sig: &[f32]| -> f64 {
            (10..=25)
                .map(|h| {
                    let f = 200.0 * h as f32;
                    if (2_000.0..=5_000.0).contains(&f) {
                        let a = amp(sig, h) as f64;
                        a * a
                    } else {
                        0.0
                    }
                })
                .sum::<f64>()
        };
        let band_drop = 10.0 * (band_power(&dark) / band_power(&flat)).log10();
        println!("tone -9: 2–5 kHz band {band_drop:.2} dB");
        assert!(band_drop <= -6.0, "2–5 kHz band only {band_drop} dB down");
        // Fundamental and harmonics below 1 kHz stay within 1 dB. Soft at bias 0 is odd, so
        // the even harmonics sit at the numerical floor and are skipped.
        for h in 1..=4 {
            let before = to_db(amp(&flat, h));
            if before < -120.0 {
                continue;
            }
            let after = to_db(amp(&dark, h));
            assert!(
                (after - before).abs() <= 1.0,
                "harmonic {} Hz: {before} -> {after}",
                200 * h
            );
        }
    }

    #[test]
    fn soft_with_bias_produces_even_harmonics() {
        // The generalized bias: Soft at Bias 0 is odd; raised, the 2nd harmonic appears.
        assert!(
            second_to_first(0, 0.0, 12.0, 0.5) < 1e-3,
            "Soft at bias 0 must be odd"
        );
        let biased = second_to_first(0, 100.0, 12.0, 0.5);
        assert!(biased > 0.02, "Soft with bias: 2nd/1st harmonic {biased}");
    }

    // === Tape stages (T-009) ===

    /// 6 kHz level (dB) through Tape at `drive` dB for a sine at `level_db`, HF Loss `hf_loss`.
    fn tape_hf_at(level_db: f32, drive: f32, hf_loss: f32) -> f32 {
        let frames = 24_000;
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, 2); // Tape
        set_real(&mut d, DRIVE, drive);
        set_real(&mut d, HF_LOSS, hf_loss);
        set_real(&mut d, HEAD_BUMP, 0.0);
        set_real(&mut d, SQUASH, 0.0);
        let input = stereo(&sine(6_000.0, SR, frames, 10f32.powf(level_db / 20.0)));
        let out = render(&mut d, &input, &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        to_db(tone_amplitude(&left[frames / 2..], 6_000.0, SR))
    }

    #[test]
    fn tape_hf_loss_follows_level() {
        // Compare against the same settings with HF_LOSS off, so the loudness difference
        // cancels and only the level-driven loss remains.
        let drop = |level_db: f32, drive: f32| {
            tape_hf_at(level_db, drive, 100.0) - tape_hf_at(level_db, drive, 0.0)
        };
        let quiet = drop(-18.0, 12.0);
        let loud = drop(-6.0, 12.0);
        println!("6 kHz drop at drive 12: quiet {quiet:.2}, loud {loud:.2} dB");
        assert!(
            loud < quiet - 3.0,
            "loss must follow level: quiet {quiet} vs loud {loud}"
        );
        // With HF_LOSS at 0 the whole tape group is out: both levels pass through untouched.
        let (quiet_off, loud_off) = (tape_hf_at(-18.0, 0.0, 0.0), tape_hf_at(-6.0, 0.0, 0.0));
        assert!(
            (quiet_off - (-18.0)).abs() < 0.1 && (loud_off - (-6.0)).abs() < 0.1,
            "HF_LOSS 0 must be transparent: {quiet_off} vs {loud_off}"
        );
    }

    #[test]
    fn tape_hf_loss_follows_drive() {
        // Hitting the tape harder with Drive (same input level) darkens it more.
        let drop = |drive: f32| tape_hf_at(-12.0, drive, 100.0) - tape_hf_at(-12.0, drive, 0.0);
        let (soft, hard) = (drop(0.0), drop(18.0));
        println!("6 kHz drop at -12 dBFS: drive 0 {soft:.2}, drive 18 {hard:.2} dB");
        assert!(hard < soft - 3.0, "drive 0 {soft} vs drive 18 {hard}");
    }

    #[test]
    fn tape_controls_inactive_outside_tape() {
        let frames = 24_000;
        let render_with = |tape_amounts: f32| {
            let mut d = device();
            set_real(&mut d, DRIVE, 18.0);
            set_real(&mut d, HF_LOSS, tape_amounts);
            set_real(&mut d, HEAD_BUMP, tape_amounts * 6.0);
            set_real(&mut d, SQUASH, tape_amounts);
            let input = stereo(&white_noise(frames, 0.5, 7));
            render(&mut d, &input, &[512])
        };
        assert_eq!(
            render_with(100.0),
            render_with(0.0),
            "Soft must ignore the tape knobs entirely"
        );
    }

    #[test]
    fn tape_squash_lowers_peak_to_rms() {
        let frames = 24_000;
        let crest = |ty: usize| {
            let mut d = device();
            set_choice(&mut d, SAT_TYPE, ty);
            set_real(&mut d, DRIVE, 12.0);
            set_real(&mut d, HF_LOSS, 0.0);
            set_real(&mut d, HEAD_BUMP, 0.0);
            set_real(&mut d, SQUASH, 100.0);
            let input = stereo(&white_noise(frames, 0.6, 11));
            let out = render(&mut d, &input, &[512]);
            let left: Vec<f32> = out.iter().step_by(2).copied().collect();
            // Peak and RMS over the same settled window, so the Auto Gain ramp can't skew it.
            let tail = &left[frames / 2..];
            peak(tail) / rms(tail)
        };
        let soft = crest(0);
        let tape = crest(2);
        println!("crest: soft {soft:.2}, tape {tape:.2}");
        assert!(tape < soft, "tape crest {tape} must be below soft {soft}");
    }

    #[test]
    fn soft_tape_switch_does_not_click() {
        let frames = 48_000;
        let input = stereo(&sine(220.0, SR, frames, 0.7));
        let mut d = device();
        set_real(&mut d, DRIVE, 18.0);
        set_real(&mut d, BIAS, 50.0);
        let mut out = render(&mut d, &input[..frames / 2], &[256]);
        set_choice(&mut d, SAT_TYPE, 2); // Tape: the gate opens with the type crossfade
        out.extend(render(&mut d, &input[frames / 2..frames / 4 * 3], &[256]));
        set_choice(&mut d, SAT_TYPE, 0); // and closes again
        out.extend(render(&mut d, &input[frames / 4 * 3..], &[256]));
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let worst_step = left
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        assert!(worst_step <= 0.4, "soft↔tape step {worst_step}");
        assert!(peak(&left) < 2.0, "peak {}", peak(&left));
    }

    // === Wow & flutter and noise (T-010) ===

    #[test]
    fn wow_zero_has_no_delay() {
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, 2); // Tape
        set_real(&mut d, DRIVE, 0.0);
        set_real(&mut d, HF_LOSS, 0.0);
        set_real(&mut d, HEAD_BUMP, 0.0);
        set_real(&mut d, SQUASH, 0.0);
        assert_eq!(TABLE.spec(WOW).unwrap().default, 0.0, "Wow defaults to 0");
        // 1x and settled: the oversampling halfband smears a single-sample impulse on its own,
        // so the delay path is isolated at 1x. The −0.0025 ring afterwards is the DC blocker,
        // not delay.
        set_choice(&mut d, QUALITY, 0);
        let silence = vec![0.0; SR as usize];
        let _ = render(&mut d, &silence, &[512]);
        crate::audio::dsp::denormal::flush_denormals_to_zero();
        let input = stereo(&impulse(SR as usize / 4));
        let out = render(&mut d, &input, &[512]);
        assert_eq!(out[0], 1.0, "impulse must come out at frame 0");
        assert_eq!(out[1], 1.0, "impulse must come out at frame 0");
    }

    #[test]
    fn wow_from_zero_does_not_click() {
        let frames = 48_000;
        let input = stereo(&sine(300.0, SR, frames, 0.5));
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, 2); // Tape
        set_real(&mut d, DRIVE, 18.0);
        let mut out = render(&mut d, &input[..frames / 2], &[256]);
        set_real(&mut d, WOW, 100.0);
        out.extend(render(&mut d, &input[frames / 2..], &[256]));
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        assert!(left.iter().all(|x| x.is_finite()));
        let worst_step = left
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        assert!(worst_step <= 0.1, "wow fade-in step {worst_step}");
    }

    #[test]
    fn noise_off_silence_in_silence_out() {
        let mut d = device();
        set_choice(&mut d, SAT_TYPE, 2); // Tape: the gate opens, the group runs
        let silence = vec![0.0; SR as usize * 2];
        let out = render(&mut d, &silence, &[512]);
        assert!(out.iter().all(|&x| x == 0.0), "noise off must add nothing");
    }

    #[test]
    fn noise_on_is_seeded() {
        let render_noise = || {
            let mut d = device();
            set_choice(&mut d, SAT_TYPE, 2); // Tape
            set_real(&mut d, NOISE, -40.0);
            let silence = vec![0.0; SR as usize];
            render(&mut d, &silence, &[512])
        };
        assert_eq!(render_noise(), render_noise(), "noise must be seeded");
    }

    #[test]
    fn modulation_from_zero_does_not_click() {
        let frames = 48_000;
        let input = stereo(&sine(300.0, SR, frames, 0.5));
        for id in [FLUTTER, DRIFT] {
            let mut d = device();
            set_choice(&mut d, SAT_TYPE, 2); // Tape
            set_real(&mut d, DRIVE, 18.0);
            let mut out = render(&mut d, &input[..frames / 2], &[256]);
            set_real(&mut d, id, 100.0);
            out.extend(render(&mut d, &input[frames / 2..], &[256]));
            let left: Vec<f32> = out.iter().step_by(2).copied().collect();
            assert!(left.iter().all(|x| x.is_finite()));
            let worst_step = left
                .windows(2)
                .map(|w| (w[1] - w[0]).abs())
                .fold(0.0, f32::max);
            assert!(worst_step <= 0.1, "param {id} fade-in step {worst_step}");
        }
    }

    #[test]
    fn flutter_and_drift_move_the_signal_and_are_seeded() {
        let input = stereo(&sine(1_000.0, SR, 24_000, 0.3));
        let render_with = |id: ParamId, amount: f32| {
            let mut d = device();
            set_choice(&mut d, SAT_TYPE, 2); // Tape
            set_real(&mut d, id, amount);
            render(&mut d, &input, &[512])
        };
        for id in [WOW, FLUTTER, DRIFT] {
            let off = render_with(id, 0.0);
            let on = render_with(id, 100.0);
            assert_ne!(on, off, "param {id} must modulate");
            assert_eq!(
                on,
                render_with(id, 100.0),
                "param {id} must be deterministic"
            );
        }
    }

    #[test]
    fn modulation_is_inactive_outside_tape() {
        let input = stereo(&white_noise(24_000, 0.5, 9));
        let render_with = |amount: f32| {
            let mut d = device();
            set_real(&mut d, DRIVE, 12.0);
            for id in [WOW, FLUTTER, DRIFT] {
                set_real(&mut d, id, amount);
            }
            render(&mut d, &input, &[512])
        };
        assert_eq!(render_with(100.0), render_with(0.0));
    }

    // === Dry/wet alignment, Input, queued switches ===

    /// Gain (dB) of a sine at `freq` through the device at Mix 50 %, Drive 0 (a clean wet side:
    /// any deviation is the dry and wet sides disagreeing in phase).
    fn parallel_gain_db(quality: usize, freq: f32) -> f32 {
        let frames = 24_000;
        let mut d = device();
        set_real(&mut d, DRIVE, 0.0);
        set_choice(&mut d, QUALITY, quality);
        set_real(&mut d, MIX, 50.0);
        let out = render(&mut d, &stereo(&sine(freq, SR, frames, 0.25)), &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        to_db(tone_amplitude(&left[frames / 2..], freq, SR) / 0.25)
    }

    #[test]
    fn parallel_mix_does_not_comb_filter() {
        for quality in 0..3 {
            for freq in [
                100.0, 1_000.0, 3_000.0, 5_000.0, 10_000.0, 15_000.0, 18_000.0,
            ] {
                let g = parallel_gain_db(quality, freq);
                assert!(
                    g.abs() < 0.2,
                    "quality {quality}, {freq} Hz at Mix 50 %: {g:.2} dB"
                );
            }
        }
    }

    #[test]
    fn input_is_a_true_input_gain() {
        // At Mix 0 % the Input still applies (both sides), and nothing else does.
        let frames = 24_000;
        let input = stereo(&sine(1_000.0, SR, frames, 0.25));
        let mut d = device();
        set_real(&mut d, INPUT, 12.0);
        set_real(&mut d, OUTPUT, -12.0); // a wet-only trim: ignored at Mix 0 %
        set_real(&mut d, MIX, 0.0);
        let out = render(&mut d, &input, &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let gain = to_db(rms(&left[frames / 2..])) - to_db(rms(&sine(1_000.0, SR, frames, 0.25)));
        assert!((gain - 12.0).abs() < 0.1, "input gain at Mix 0: {gain}");
    }

    #[test]
    fn quality_switched_back_mid_fade_lands_on_the_parameter() {
        let input = stereo(&sine(300.0, SR, 4_800, 0.5));
        let mut d = device();
        assert_eq!(d.os[d.os_active].factor(), 2);
        // 2x → 4x → 2x before a single block runs, then 4x → 1x → 4x → 1x.
        set_choice(&mut d, QUALITY, 2);
        set_choice(&mut d, QUALITY, 1);
        render(&mut d, &input, &[512]);
        assert_eq!(d.os[d.os_active].factor(), 2, "back to 2x");
        assert!(d.os_fade >= 1.0);
        set_choice(&mut d, QUALITY, 2);
        render(&mut d, &input[..128], &[64]); // part-way into the fade
        set_choice(&mut d, QUALITY, 0);
        set_choice(&mut d, QUALITY, 2);
        set_choice(&mut d, QUALITY, 0);
        render(&mut d, &input, &[512]);
        assert_eq!(d.os[d.os_active].factor(), 1, "queued 1x must win");
        assert!(d.os_fade >= 1.0 && d.pending_os.is_none());
        // A reset mid-fade commits the parameter too.
        set_choice(&mut d, QUALITY, 2);
        d.reset();
        assert_eq!(d.os[d.os_active].factor(), 4);
    }

    #[test]
    fn type_changed_mid_fade_is_queued() {
        let input = stereo(&sine(220.0, SR, 9_600, 0.7));
        let mut d = device();
        set_real(&mut d, DRIVE, 18.0);
        render(&mut d, &input, &[256]);
        set_choice(&mut d, SAT_TYPE, 3); // Hard
        render(&mut d, &input[..64], &[64]); // part-way
        set_choice(&mut d, SAT_TYPE, 1); // Tube: waits for the Hard fade
        assert_eq!(d.p.ty, SatType::Hard);
        let out = render(&mut d, &input, &[256]);
        assert_eq!(d.p.ty, SatType::Tube);
        assert!(d.ty_fade >= 1.0 && d.pending_ty.is_none());
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let worst_step = left
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        assert!(worst_step <= 0.4, "queued type switch: step {worst_step}");
    }

    #[test]
    fn bias_taper_is_signed_square() {
        assert_eq!(bias_amount(0.0), 0.0);
        assert_eq!(bias_amount(100.0), BIAS_MAX);
        assert_eq!(bias_amount(-100.0), -BIAS_MAX);
        assert!((bias_amount(50.0) - BIAS_MAX * 0.25).abs() < 1e-6);
    }

    // === Sleep (T-011) ===

    #[test]
    fn it_sleeps_after_silence_and_wakes_clean() {
        let mut d = device();
        let quiet = [0.0f32; 1_024];
        let mut sink = [0.0f32; 1_024];
        for _ in 0..(10 * SR as usize / 512) {
            d.process_block(&quiet, &mut sink, 512);
            d.update_sleep_state(false);
        }
        assert!(
            d.is_sleeping(),
            "10 s of silence must put the device to sleep"
        );
        // A drum-like burst: white noise with an exponential decay.
        let mut hit = white_noise(4_800, 0.8, 21);
        for (i, x) in hit.iter_mut().enumerate() {
            *x *= (-(i as f32) / 1_200.0).exp();
        }
        let burst = stereo(&hit);
        let out_slept = render(&mut d, &burst, &[512]);
        let mut fresh = device();
        let out_fresh = render(&mut fresh, &burst, &[512]);
        assert_eq!(
            out_slept, out_fresh,
            "the first hit after sleep must match a fresh device"
        );
    }

    // === "curve" data stream (T-013) ===

    #[test]
    fn curve_record_matches_the_shaper() {
        let mut d = device();
        assert!(
            d.subscribe_data("spectrum").is_err(),
            "unknown names rejected"
        );
        assert!(
            d.poll_device_data().is_none(),
            "unsubscribed: nothing built"
        );
        d.subscribe_data("curve").unwrap();

        set_choice(&mut d, SAT_TYPE, 1); // Tube: the bias produces even harmonics
        set_real(&mut d, BIAS, 40.0);
        set_real(&mut d, DRIVE, 18.0);
        set_real(&mut d, LEVEL_DEPEND, 50.0); // must not enter the static curve body
                                              // Enough frames to pass one poll interval and refresh the cache at control rate.
        let frames = 25_000;
        render(&mut d, &stereo(&sine(220.0, SR, frames, 0.4)), &[512]);

        let (kind, bytes) = d.poll_device_data().expect("one record per poll");
        assert_eq!(kind, "curve");
        assert_eq!(bytes.len(), BYTES);
        let v: Vec<f32> = bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
            .collect();
        assert_eq!(v.len(), RECORD_VALUES);
        assert!(v.iter().all(|x| x.is_finite()));

        // Header: the effective drive includes the level-dependent boost (the envelope sits
        // above the −18 dBFS reference at 0.4 amplitude), the envelope level is sane.
        assert!(v[0] > 18.0 && v[0] < 36.0, "effective drive {}", v[0]);
        assert!(v[1] > -60.0 && v[1] < 6.0, "env db {}", v[1]);

        // The body is the device's own shaper at the *static* settings.
        let (gain, blend) = drive_params(18.0);
        for i in 0..CURVE_POINTS {
            let x = -1.0 + 2.0 * i as f32 / (CURVE_POINTS - 1) as f32;
            let expected = SaturatorDevice::shape(SatType::Tube, x, gain, blend, bias_amount(40.0));
            assert!(
                (v[2 + i] - expected).abs() < 1e-5,
                "point {i}: {} vs {expected}",
                v[2 + i]
            );
        }
        // Harmonics: the fundamental is the strongest bin, and an even harmonic exists.
        let harm = &v[2 + CURVE_POINTS..];
        assert!(harm[0] > harm[15], "fundamental above the 16th harmonic");
        assert!(
            harm[1] > -120.0,
            "even harmonic present with bias: {}",
            harm[1]
        );

        d.unsubscribe_data("curve");
        assert!(d.poll_device_data().is_none());
    }

    // === CPU benchmark (T-012) ===

    #[test]
    #[ignore = "CPU measurement: cargo test --release saturator_cpu -- --ignored --nocapture"]
    fn saturator_cpu() {
        const FRAMES: usize = 512;
        const SECONDS: usize = 10;
        const REPEATS: usize = 5;
        const LIMIT: f64 = 1.5;
        let input = stereo(&sine(1_000.0, SR, FRAMES, 0.3));
        let mut output = vec![0.0; FRAMES * 2];
        let blocks = (SR as usize * SECONDS) / FRAMES;

        for quality in [0usize, 2] {
            let mut sat = device();
            set_choice(&mut sat, SAT_TYPE, 2); // Tape
            set_real(&mut sat, DRIVE, 24.0);
            set_real(&mut sat, WOW, 40.0);
            set_choice(&mut sat, QUALITY, quality);

            let mut filt = crate::audio::devices::effects::filter::FilterDevice::new(SR);
            filt.prepare(SR, 4_096);
            filt.set_parameter(
                crate::audio::devices::effects::filter::QUALITY,
                crate::audio::devices::params::enum_to_norm(quality, 3),
            );

            let mut time = |d: &mut dyn AudioDevice| -> f64 {
                let mut best = f64::MAX;
                for _ in 0..REPEATS {
                    // Warm up, so the first block's cache misses don't count.
                    for _ in 0..64 {
                        d.process_block(&input, &mut output, FRAMES);
                    }
                    let start = std::time::Instant::now();
                    for _ in 0..blocks {
                        d.process_block(&input, &mut output, FRAMES);
                    }
                    best = best.min(start.elapsed().as_secs_f64());
                }
                best
            };
            let sat_t = time(&mut sat);
            let filt_t = time(&mut filt);
            let ratio = sat_t / filt_t;
            println!(
                "quality {}: saturator {sat_t:.3} s vs filter {filt_t:.3} s for {SECONDS} s of \
                 audio, ratio {ratio:.2}",
                ["1x", "2x", "4x"][quality]
            );
            assert!(
                ratio <= LIMIT,
                "saturator {}x costs {ratio:.2}x the filter (limit {LIMIT})",
                quality + 1
            );
        }
    }
}
