//! Filter effect (spec 012, Phase 4): a clean SVF or a nonlinear ladder, with drive, an LFO and
//! an envelope follower on the cutoff.
//!
//! Signal path, per channel: `drive → filter (at the Quality rate) → soft limiter (base rate) →
//! Gain`, then Mix crossfades dry and that wet signal linearly (decision 5). Mix 0 % is bit-exact
//! dry, so Gain only trims the wet path.
//!
//! - Control (cutoff modulation, resonance, drive) runs every [`CTRL_BLOCK`] frames, counted
//!   across host blocks so results don't depend on block size. The cutoff's `g` is interpolated
//!   per sample between control points.
//! - Cutoff = base × 2^(LFO·Depth + Env·Amount). The right channel's LFO is offset by Stereo
//!   Phase. The envelope follows the louder channel of the input, so the two channels open
//!   together.
//! - Type and Character changes run the old and new filter side by side for 10 ms and crossfade
//!   (decision 8), so a saturating filter never jumps to a linear one.
//! - The nonlinear part runs on the `Oversampler` at 1×, 2× or 4×; at 1× nothing is resampled.

use super::effect::{pass_through, TailSleep};
use super::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use crate::audio::dsp::env_follower::{Detection, EnvFollower};
use crate::audio::dsp::gain::{db_to_gain, dry_wet_gains, gain_to_db, MixLaw};
use crate::audio::dsp::ladder::{Ladder, LadderCoefs, LadderMode};
use crate::audio::dsp::oversampler::Oversampler;
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::svf::{
    compensation_coef, cutoff_to_g, drive, drive_params, resonance_to_k, soft_clip, FilterMode,
    Svf, SvfCoefs,
};
use crate::audio::dsp::tempo_sync::{beats_to_hz, sync_beats, SYNC_CHOICES};
use crate::audio::modulation::lfo::{Lfo, LfoShape, LFO_SHAPES};

// === Parameters ===

pub const FILTER_TYPE: ParamId = 0;
pub const CHARACTER: ParamId = 1;
pub const CUTOFF: ParamId = 2;
pub const RESONANCE: ParamId = 3;
pub const DRIVE: ParamId = 4;
pub const QUALITY: ParamId = 5;

pub const LFO_SHAPE: ParamId = 10;
pub const LFO_RATE: ParamId = 11;
pub const LFO_SYNC: ParamId = 12;
pub const LFO_DEPTH: ParamId = 13;
pub const LFO_STEREO_PHASE: ParamId = 14;

pub const ENV_AMOUNT: ParamId = 20;
pub const ENV_ATTACK: ParamId = 21;
pub const ENV_RELEASE: ParamId = 22;

pub const MIX: ParamId = 30;
pub const GAIN: ParamId = 31;

const TYPES: &[&str] = &["LP 12", "LP 24", "HP 12", "HP 24", "BP 12", "Notch"];
const CHARACTERS: &[&str] = &["Clean", "Ladder"];
const QUALITIES: &[&str] = &["1x", "2x", "4x"];

const FILTER_MODULE: [ParamSpec; 6] = [
    spec(FILTER_TYPE, "Type", "Filter", "", Kind::Enum(TYPES), 1.0),
    spec(
        CHARACTER,
        "Character",
        "Filter",
        "",
        Kind::Enum(CHARACTERS),
        0.0,
    ),
    spec(
        CUTOFF,
        "Cutoff",
        "Filter",
        "Hz",
        log(20.0, 20_000.0),
        20_000.0,
    ),
    spec(RESONANCE, "Resonance", "Filter", "", linear(0.0, 1.0), 0.2),
    spec(DRIVE, "Drive", "Filter", "dB", linear(0.0, 24.0), 0.0),
    spec(QUALITY, "Quality", "Filter", "", Kind::Enum(QUALITIES), 1.0),
];

const LFO_MODULE: [ParamSpec; 5] = [
    spec(LFO_SHAPE, "Shape", "LFO", "", Kind::Enum(LFO_SHAPES), 0.0),
    spec(LFO_RATE, "Rate", "LFO", "Hz", log(0.01, 40.0), 1.0),
    spec(LFO_SYNC, "Sync", "LFO", "", Kind::Enum(SYNC_CHOICES), 0.0),
    spec(LFO_DEPTH, "Depth", "LFO", "oct", linear(-4.0, 4.0), 0.0),
    spec(
        LFO_STEREO_PHASE,
        "Stereo Phase",
        "LFO",
        "°",
        linear(0.0, 180.0),
        0.0,
    ),
];

const ENV_MODULE: [ParamSpec; 3] = [
    spec(
        ENV_AMOUNT,
        "Amount",
        "Envelope",
        "oct",
        linear(-4.0, 4.0),
        0.0,
    ),
    spec(ENV_ATTACK, "Attack", "Envelope", "ms", log(0.1, 100.0), 5.0),
    spec(
        ENV_RELEASE,
        "Release",
        "Envelope",
        "ms",
        log(5.0, 2_000.0),
        200.0,
    ),
];

const OUTPUT_MODULE: [ParamSpec; 2] = [
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 100.0),
    spec(GAIN, "Gain", "Output", "dB", linear(-12.0, 12.0), 0.0),
];

const PARAM_COUNT: usize = 16;
const SPECS: [ParamSpec; PARAM_COUNT] =
    flatten(&[&FILTER_MODULE, &LFO_MODULE, &ENV_MODULE, &OUTPUT_MODULE]);
const SLOTS: [u8; 32] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

// === Constants ===

/// Frames between control updates (cutoff modulation, resonance, drive).
const CTRL_BLOCK: usize = 32;
/// Crossfade when the Type or Character changes.
const SWITCH_FADE_MS: f32 = 10.0;
/// Smoothing time for continuous parameters.
const RAMP_MS: f32 = 5.0;
/// Cutoff range the modulated cutoff is clamped to (Hz). The top is also limited by the rate.
const MIN_CUTOFF_HZ: f32 = 10.0;
/// Fraction of full resonance that Clean feeds its bass compensation. At 1.0 the lows rise
/// 3.2 dB at Resonance 0.9; this keeps them within ±3 dB there and still fat.
const CLEAN_COMPENSATION_SCALE: f32 = 0.7;
/// The envelope follower maps the input level from this many dB below full scale (0) to 1.
const ENV_RANGE_DB: f32 = 40.0;
/// Soft limiter: linear up to 1.0, then a smooth knee that tops out at 2.0 (+6 dBFS).
const LIMIT_KNEE: f32 = 1.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FilterType {
    Lp12,
    Lp24,
    Hp12,
    Hp24,
    Bp12,
    Notch,
}

impl FilterType {
    fn from_index(index: usize) -> Self {
        match index {
            0 => Self::Lp12,
            1 => Self::Lp24,
            2 => Self::Hp12,
            3 => Self::Hp24,
            4 => Self::Bp12,
            _ => Self::Notch,
        }
    }

    fn svf(self) -> FilterMode {
        match self {
            Self::Lp12 => FilterMode::Lp12,
            Self::Lp24 => FilterMode::Lp24,
            Self::Hp12 => FilterMode::Hp12,
            Self::Hp24 => FilterMode::Hp24,
            Self::Bp12 => FilterMode::Bp12,
            Self::Notch => FilterMode::Notch,
        }
    }

    fn ladder(self) -> LadderMode {
        match self {
            Self::Lp12 => LadderMode::Lp12,
            Self::Lp24 => LadderMode::Lp24,
            Self::Hp12 => LadderMode::Hp12,
            Self::Hp24 => LadderMode::Hp24,
            Self::Bp12 => LadderMode::Bp12,
            Self::Notch => LadderMode::Notch,
        }
    }
}

/// Decoded (real-valued) parameters.
#[derive(Clone, Copy, Debug)]
struct Params {
    ty: FilterType,
    ladder: bool,
    cutoff_log2: f32,
    resonance: f32,
    drive_db: f32,
    oversample: usize,
    lfo_shape: LfoShape,
    lfo_hz: f32,
    sync_beats: Option<f64>,
    depth: f32,
    stereo_phase: f32,
    env_amount: f32,
    env_attack_ms: f32,
    env_release_ms: f32,
    mix: f32,
    gain_db: f32,
}

impl Params {
    fn defaults(values: &ParamValues<PARAM_COUNT>) -> Self {
        let mut p = Self {
            ty: FilterType::Lp24,
            ladder: false,
            cutoff_log2: 20_000f32.log2(),
            resonance: 0.2,
            drive_db: 0.0,
            oversample: 2,
            lfo_shape: LfoShape::Sine,
            lfo_hz: 1.0,
            sync_beats: None,
            depth: 0.0,
            stereo_phase: 0.0,
            env_amount: 0.0,
            env_attack_ms: 5.0,
            env_release_ms: 200.0,
            mix: 1.0,
            gain_db: 0.0,
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
            FILTER_TYPE => self.ty = FilterType::from_index(real as usize),
            CHARACTER => self.ladder = real >= 0.5,
            CUTOFF => self.cutoff_log2 = real.max(1.0).log2(),
            RESONANCE => self.resonance = real,
            DRIVE => self.drive_db = real,
            QUALITY => self.oversample = 1 << (real as usize).min(2),
            LFO_SHAPE => self.lfo_shape = LfoShape::from_index(real as usize),
            LFO_RATE => self.lfo_hz = real,
            LFO_SYNC => self.sync_beats = sync_beats(real as usize),
            LFO_DEPTH => self.depth = real,
            LFO_STEREO_PHASE => self.stereo_phase = real,
            ENV_AMOUNT => self.env_amount = real,
            ENV_ATTACK => self.env_attack_ms = real,
            ENV_RELEASE => self.env_release_ms = real,
            MIX => self.mix = real * 0.01,
            GAIN => self.gain_db = real,
            _ => {}
        }
    }
}

// === Filter core ===

/// Per-sample filter coefficients for one frame of one channel.
#[derive(Clone, Copy, Debug, Default)]
struct Frame {
    /// SVF pole coefficient, from `svf::cutoff_to_g`.
    g: f32,
    /// Ladder pole coefficient (`g/(1+g)`) and its feedback solution `1/(1 + k·G⁴)`.
    big_g: f32,
    inv_fb: f32,
}

/// Per-control-block values the per-sample filters read.
#[derive(Clone, Copy, Debug, Default)]
struct Ctl {
    /// Integrator coefficient at the start and end of the block, per channel, at the
    /// oversampled rate.
    g_a: [f32; 2],
    g_b: [f32; 2],
    /// The ladder's pole values for the same two cutoffs. Interpolating these beats dividing
    /// per sample, and the interpolation error over 32 frames is far below the cutoff step.
    big_a: [f32; 2],
    big_b: [f32; 2],
    inv_a: [f32; 2],
    inv_b: [f32; 2],
    /// The ladder's per-block constants (everything that doesn't depend on the cutoff).
    ladder: LadderCoefs,
    resonance: f32,
    /// Clean's bass-compensation coefficient, per channel.
    comp_coef: [f32; 2],
    drive_gain: f32,
    drive_blend: f32,
}

impl Ctl {
    /// Interpolated coefficients `t` of the way through the control block, for one channel.
    #[inline]
    fn frame(&self, ch: usize, t: f32) -> Frame {
        Frame {
            g: self.g_a[ch] + (self.g_b[ch] - self.g_a[ch]) * t,
            big_g: self.big_a[ch] + (self.big_b[ch] - self.big_a[ch]) * t,
            inv_fb: self.inv_a[ch] + (self.inv_b[ch] - self.inv_a[ch]) * t,
        }
    }
}

/// One complete filter (both characters' state, for both channels) for a type and character.
#[derive(Clone, Copy, Debug)]
struct Core {
    ty: FilterType,
    ladder: bool,
    /// Damping for the current Clean mode, refreshed every control block.
    k: f32,
    svf: [Svf; 2],
    lad: [Ladder; 2],
}

impl Core {
    fn new(ty: FilterType, ladder: bool) -> Self {
        Self {
            ty,
            ladder,
            k: 1.0,
            svf: [Svf::new(); 2],
            lad: [Ladder::default(); 2],
        }
    }

    fn reset_state(&mut self) {
        self.svf = [Svf::new(); 2];
        self.lad = [Ladder::default(); 2];
    }

    fn update_control(&mut self, resonance: f32) {
        self.k = resonance_to_k(resonance, self.ty.svf());
    }

    #[inline]
    fn tick(&mut self, ch: usize, x: f32, frame: &Frame, ctl: &Ctl) -> f32 {
        if self.ladder {
            let mut coefs = ctl.ladder;
            coefs.set_pole_parts(frame.big_g, frame.inv_fb);
            self.lad[ch].process(x, self.ty.ladder(), &coefs)
        } else {
            let mode = self.ty.svf();
            let coefs = SvfCoefs::new(frame.g, self.k, mode);
            self.svf[ch].process(
                x,
                mode,
                &coefs,
                ctl.comp_coef[ch],
                ctl.resonance * CLEAN_COMPENSATION_SCALE,
            )
        }
    }
}

/// The output limiter: linear up to [`LIMIT_KNEE`], then a smooth knee that tops out one unit
/// above it, so self-oscillation can never run away. It runs at the base rate, after the
/// oversampler: the half-band down-sampler is a chain of all-pass sections, whose transient
/// overshoot can exceed the bound the high-rate stage enforced.
#[inline]
fn soft_limit(x: f32) -> f32 {
    let a = x.abs();
    if a <= LIMIT_KNEE {
        x
    } else {
        (LIMIT_KNEE + soft_clip(a - LIMIT_KNEE)).copysign(x)
    }
}

/// Advance `param` by `frames` samples. A settled parameter (the common case) needs no stepping
/// at all, which keeps the eight smoothers out of the per-control-block cost.
fn advance(param: &mut SmoothedParam, frames: usize) -> f32 {
    if param.is_settled() {
        return param.current();
    }
    let mut v = param.current();
    for _ in 0..frames {
        v = param.next();
    }
    v
}

// === Device ===

pub struct FilterDevice {
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,
    p: Params,

    cur: Core,
    prev: Core,
    /// Crossfade progress from `prev` to `cur`: 1 when no switch is running.
    fade: f32,
    oversampler: Oversampler,
    wet: Vec<f32>,

    // Control state.
    ctl: Ctl,
    ctrl_pos: usize,
    hz_prev: [f32; 2],
    primed: bool,
    env: EnvFollower,
    lfo: Lfo,
    rng: u32,
    tempo: f64,
    playing: bool,
    song_pos_beats: f64,
    frames_since_transport: f64,

    sm_cutoff: SmoothedParam,
    sm_resonance: SmoothedParam,
    sm_drive: SmoothedParam,
    sm_depth: SmoothedParam,
    sm_amount: SmoothedParam,
    sm_phase: SmoothedParam,
    sm_mix: SmoothedParam,
    sm_gain: SmoothedParam,

    sleep: TailSleep,
    is_active: bool,
    is_enabled: bool,

    #[cfg(test)]
    lfo_probe: Vec<f32>,
}

impl FilterDevice {
    pub fn new(sample_rate: f32) -> Self {
        let values = ParamValues::<PARAM_COUNT>::new(&TABLE);
        let p = Params::defaults(&values);
        let smoother = |v: f32| SmoothedParam::new(v, sample_rate, RAMP_MS);
        let core = Core::new(p.ty, p.ladder);
        let mut device = Self {
            sample_rate,
            values,
            p,
            cur: core,
            prev: core,
            fade: 1.0,
            oversampler: Oversampler::new(),
            wet: vec![0.0; CTRL_BLOCK * 2],
            ctl: Ctl::default(),
            ctrl_pos: 0,
            hz_prev: [0.0; 2],
            primed: false,
            env: EnvFollower::new(
                p.env_attack_ms,
                p.env_release_ms,
                sample_rate,
                Detection::Peak,
            ),
            lfo: Lfo::default(),
            rng: 0x1234_5678,
            tempo: 120.0,
            playing: false,
            song_pos_beats: 0.0,
            frames_since_transport: 0.0,
            sm_cutoff: smoother(p.cutoff_log2),
            sm_resonance: smoother(p.resonance),
            sm_drive: smoother(p.drive_db),
            sm_depth: smoother(p.depth),
            sm_amount: smoother(p.env_amount),
            sm_phase: smoother(p.stereo_phase),
            sm_mix: smoother(p.mix),
            sm_gain: smoother(db_to_gain(p.gain_db)),
            sleep: TailSleep::new(sample_rate),
            is_active: true,
            is_enabled: true,
            #[cfg(test)]
            lfo_probe: Vec::new(),
        };
        device.oversampler.prepare(CTRL_BLOCK);
        device.oversampler.set_factor(p.oversample);
        device
    }

    /// Fold a decoded real value (base plus any modulation offset) into the DSP state.
    fn apply(&mut self, param_id: ParamId, real: f32) {
        self.p.apply(param_id, real);
        let p = self.p;
        match param_id {
            FILTER_TYPE | CHARACTER => self.switch_started(p.ty, p.ladder),
            CUTOFF => self.sm_cutoff.set_target(p.cutoff_log2),
            RESONANCE => self.sm_resonance.set_target(p.resonance),
            DRIVE => self.sm_drive.set_target(p.drive_db),
            QUALITY => {
                self.oversampler.set_factor(p.oversample);
                // The control values depend on the rate; recompute at the next frame.
                self.ctrl_pos = 0;
                self.primed = false;
            }
            LFO_DEPTH => self.sm_depth.set_target(p.depth),
            LFO_STEREO_PHASE => self.sm_phase.set_target(p.stereo_phase),
            ENV_AMOUNT => self.sm_amount.set_target(p.env_amount),
            ENV_ATTACK | ENV_RELEASE => {
                self.env
                    .set_times(p.env_attack_ms, p.env_release_ms, self.sample_rate)
            }
            MIX => self.sm_mix.set_target(p.mix),
            GAIN => self.sm_gain.set_target(db_to_gain(p.gain_db)),
            _ => {}
        }
    }

    fn switch_started(&mut self, ty: FilterType, ladder: bool) {
        if ty == self.cur.ty && ladder == self.cur.ladder {
            return;
        }
        self.prev = self.cur;
        self.cur.ty = ty;
        if ladder != self.cur.ladder {
            // A different character starts from rest; the old one keeps ringing in `prev`.
            self.cur.ladder = ladder;
            self.cur.reset_state();
        }
        self.fade = 0.0;
    }

    fn random(&mut self) -> f32 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        self.rng as f32 / u32::MAX as f32 * 2.0 - 1.0
    }

    /// Advance the LFO by one control block and return its outputs for (left, right).
    fn step_lfo(&mut self) -> (f32, f32) {
        let sr = self.sample_rate as f64;
        let old_phase = self.lfo.phase;
        let wrapped = match self.p.sync_beats {
            Some(beats) if self.playing => {
                let beat_rate = self.tempo / 60.0 / sr;
                let pos = self.song_pos_beats
                    + (self.frames_since_transport + CTRL_BLOCK as f64) * beat_rate;
                self.lfo.phase = (pos / beats).rem_euclid(1.0);
                self.lfo.phase < old_phase
            }
            Some(beats) => self
                .lfo
                .advance(beats_to_hz(beats, self.tempo) * CTRL_BLOCK as f64 / sr),
            None => self
                .lfo
                .advance(self.p.lfo_hz as f64 * CTRL_BLOCK as f64 / sr),
        };
        if wrapped {
            let held = self.random();
            self.lfo.set_held(held);
        }
        let phase = advance(&mut self.sm_phase, CTRL_BLOCK) as f64 / 360.0;
        (
            self.lfo.value(self.p.lfo_shape),
            self.lfo.value_at(self.p.lfo_shape, phase),
        )
    }

    /// Recompute the per-block control values. Runs every `CTRL_BLOCK` frames.
    fn update_control(&mut self) {
        let sr_hi = self.sample_rate * self.oversampler.factor() as f32;
        let nyquist_cap = sr_hi * 0.49;

        let cutoff_log2 = advance(&mut self.sm_cutoff, CTRL_BLOCK);
        let resonance = advance(&mut self.sm_resonance, CTRL_BLOCK);
        let drive_db = advance(&mut self.sm_drive, CTRL_BLOCK);
        let depth = advance(&mut self.sm_depth, CTRL_BLOCK);
        let amount = advance(&mut self.sm_amount, CTRL_BLOCK);
        let (lfo_l, lfo_r) = self.step_lfo();
        #[cfg(test)]
        self.lfo_probe.push(lfo_l);

        // Envelope: input level from -ENV_RANGE_DB..0 dBFS mapped to 0..1.
        let env_db = gain_to_db(self.env.value());
        let env = ((env_db + ENV_RANGE_DB) / ENV_RANGE_DB).clamp(0.0, 1.0);

        let ladder = LadderCoefs::for_resonance(resonance);
        for (ch, lfo) in [lfo_l, lfo_r].into_iter().enumerate() {
            let octaves = cutoff_log2 + lfo * depth + env * amount;
            let hz = octaves.exp2().clamp(MIN_CUTOFF_HZ, nyquist_cap);
            let start = if self.primed { self.hz_prev[ch] } else { hz };
            self.hz_prev[ch] = hz;
            self.ctl.g_a[ch] = cutoff_to_g(start, sr_hi);
            self.ctl.g_b[ch] = cutoff_to_g(hz, sr_hi);
            (self.ctl.big_a[ch], self.ctl.inv_a[ch]) = ladder.pole_parts(self.ctl.g_a[ch]);
            (self.ctl.big_b[ch], self.ctl.inv_b[ch]) = ladder.pole_parts(self.ctl.g_b[ch]);
            self.ctl.comp_coef[ch] = compensation_coef(hz, sr_hi);
        }
        self.primed = true;

        self.ctl.ladder = ladder;
        self.ctl.resonance = resonance;
        let (gain, blend) = drive_params(drive_db);
        self.ctl.drive_gain = gain;
        self.ctl.drive_blend = blend;
        self.cur.update_control(resonance);
        self.prev.update_control(resonance);
    }

    /// The nonlinear stage: runs `frames_hi` interleaved frames of `buf` at the oversampled
    /// rate, starting `hi_pos` frames into the control block of `hi_total`.
    fn run_stage(
        cur: &mut Core,
        prev: &mut Core,
        fade: &mut f32,
        fade_inc: f32,
        ctl: &Ctl,
        hi_pos: usize,
        hi_total: usize,
        buf: &mut [f32],
    ) {
        let step = 1.0 / hi_total as f32;
        let mut t = (hi_pos + 1) as f32 * step;
        // A cutoff that hasn't moved since the last block makes the interpolation a no-op, so
        // build each channel's coefficients once instead of once per sample (as PolySynth's
        // filter does). The branch is the same for the whole loop, so it predicts perfectly.
        let steady = ctl.g_a[0] == ctl.g_b[0] && ctl.g_a[1] == ctl.g_b[1];
        let fixed = [ctl.frame(0, 1.0), ctl.frame(1, 1.0)];
        for frame in buf.chunks_exact_mut(2) {
            for ch in 0..2 {
                let f = if steady { fixed[ch] } else { ctl.frame(ch, t) };
                let x = drive(frame[ch], ctl.drive_gain, ctl.drive_blend);
                let mut y = cur.tick(ch, x, &f, ctl);
                if *fade < 1.0 {
                    let old = prev.tick(ch, x, &f, ctl);
                    y = old + (y - old) * *fade;
                }
                frame[ch] = y;
            }
            if *fade < 1.0 {
                *fade = (*fade + fade_inc).min(1.0);
            }
            t += step;
        }
    }

    fn reset_dsp(&mut self) {
        self.cur.reset_state();
        self.prev.reset_state();
        self.fade = 1.0;
        self.oversampler.reset();
        self.env.reset();
        self.ctrl_pos = 0;
        self.primed = false;
        self.sm_cutoff.snap(self.p.cutoff_log2);
        self.sm_resonance.snap(self.p.resonance);
        self.sm_drive.snap(self.p.drive_db);
        self.sm_depth.snap(self.p.depth);
        self.sm_amount.snap(self.p.env_amount);
        self.sm_phase.snap(self.p.stereo_phase);
        self.sm_mix.snap(self.p.mix);
        self.sm_gain.snap(db_to_gain(self.p.gain_db));
    }
}

impl AudioDevice for FilterDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_active || !self.is_enabled {
            pass_through(inputs, outputs, sample_count);
            return;
        }
        let sample_count = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        let factor = self.oversampler.factor();
        let fade_inc = 1.0 / (SWITCH_FADE_MS * 0.001 * self.sample_rate * factor as f32);

        let mut done = 0;
        while done < sample_count {
            if self.ctrl_pos == 0 {
                self.update_control();
            }
            let n = (CTRL_BLOCK - self.ctrl_pos).min(sample_count - done);
            let input = &inputs[done * 2..(done + n) * 2];

            for frame in input.chunks_exact(2) {
                self.env.process(frame[0].abs().max(frame[1].abs()));
            }

            let hi_pos = self.ctrl_pos * factor;
            let hi_total = CTRL_BLOCK * factor;
            self.oversampler
                .process(input, &mut self.wet[..n * 2], n, |buf| {
                    Self::run_stage(
                        &mut self.cur,
                        &mut self.prev,
                        &mut self.fade,
                        fade_inc,
                        &self.ctl,
                        hi_pos,
                        hi_total,
                        buf,
                    )
                });

            // A runaway would poison the state for good; start over instead. NaN spreads through
            // the filter within a sample or two, so a stride is enough to catch it.
            let check: f32 = self.wet[..n * 2].iter().step_by(8).map(|x| x.abs()).sum();
            if !check.is_finite() {
                self.wet[..n * 2].fill(0.0);
                self.cur.reset_state();
                self.prev.reset_state();
                self.oversampler.reset();
            }

            let out = &mut outputs[done * 2..(done + n) * 2];
            let wet = &self.wet[..n * 2];
            if self.sm_mix.is_settled() && self.sm_gain.is_settled() {
                // Mix and Gain are not moving, so the per-sample smoothing is a no-op: fold the
                // two gains once and drop the smoother calls out of the loop.
                let (dry_gain, wet_gain) = dry_wet_gains(self.sm_mix.current(), MixLaw::Linear);
                let wet_gain = wet_gain * self.sm_gain.current();
                for ((o, i), w) in out
                    .chunks_exact_mut(2)
                    .zip(input.chunks_exact(2))
                    .zip(wet.chunks_exact(2))
                {
                    o[0] = i[0] * dry_gain + soft_limit(w[0]) * wet_gain;
                    o[1] = i[1] * dry_gain + soft_limit(w[1]) * wet_gain;
                }
            } else {
                for ((o, i), w) in out
                    .chunks_exact_mut(2)
                    .zip(input.chunks_exact(2))
                    .zip(wet.chunks_exact(2))
                {
                    let (dry_gain, wet_gain) = dry_wet_gains(self.sm_mix.next(), MixLaw::Linear);
                    let wet_gain = wet_gain * self.sm_gain.next();
                    o[0] = i[0] * dry_gain + soft_limit(w[0]) * wet_gain;
                    o[1] = i[1] * dry_gain + soft_limit(w[1]) * wet_gain;
                }
            }

            self.ctrl_pos = (self.ctrl_pos + n) % CTRL_BLOCK;
            self.frames_since_transport += n as f64;
            done += n;
        }
        self.sleep.on_block(sample_count);
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
        "sonara.builtin.filter"
    }

    fn device_name(&self) -> &str {
        "Filter"
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

    fn set_transport(&mut self, transport: &crate::audio::transport::Transport) {
        if transport.tempo > 0.0 {
            self.tempo = transport.tempo;
        }
        self.playing = transport.playing;
        self.song_pos_beats = transport.song_pos_beats;
        self.frames_since_transport = 0.0;
    }

    fn reset(&mut self) {
        self.reset_dsp();
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        self.env
            .set_times(self.p.env_attack_ms, self.p.env_release_ms, sample_rate);
        for smoother in [
            &mut self.sm_cutoff,
            &mut self.sm_resonance,
            &mut self.sm_drive,
            &mut self.sm_depth,
            &mut self.sm_amount,
            &mut self.sm_phase,
            &mut self.sm_mix,
            &mut self.sm_gain,
        ] {
            smoother.set_ramp(sample_rate, RAMP_MS);
        }
        self.oversampler.prepare(CTRL_BLOCK);
        self.sleep.set_sample_rate(sample_rate);
        self.reset_dsp();
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
        self.sleep.update(has_audio_activity)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{
        peak, render, rms, sine, spectrum_db, stereo, to_db, tone_amplitude, white_noise,
    };
    use crate::audio::transport::Transport;

    const SR: f32 = 48_000.0;

    fn device() -> FilterDevice {
        let mut d = FilterDevice::new(SR);
        d.prepare(SR, 4_096);
        d
    }

    fn set_real(d: &mut FilterDevice, id: ParamId, real: f32) {
        let spec = TABLE.spec(id).unwrap();
        d.set_parameter(id, spec.to_norm(real));
    }

    fn set_choice(d: &mut FilterDevice, id: ParamId, index: usize) {
        set_real(d, id, index as f32);
    }

    /// Steady-state gain of a sine through the device (Mix 100 %, Gain 0 dB, no modulation).
    fn gain_at(d: &mut FilterDevice, hz: f32, amp: f32) -> f32 {
        let frames = SR as usize;
        let out = render(d, &stereo(&sine(hz, SR, frames, amp)), &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        tone_amplitude(&left[frames / 2..], hz, SR) / amp
    }

    fn db(x: f32) -> f32 {
        to_db(x)
    }

    fn configured(ty: usize, character: usize, cutoff: f32, resonance: f32) -> FilterDevice {
        let mut d = device();
        set_choice(&mut d, FILTER_TYPE, ty);
        set_choice(&mut d, CHARACTER, character);
        set_real(&mut d, CUTOFF, cutoff);
        set_real(&mut d, RESONANCE, resonance);
        // Let the smoothers settle.
        render(&mut d, &vec![0.0; 4_800 * 2], &[512]);
        d
    }

    #[test]
    fn lp12_is_minus_3_db_at_the_cutoff() {
        let mut d = configured(0, 0, 1_000.0, 0.0);
        let at = db(gain_at(&mut d, 1_000.0, 0.1));
        assert!((at + 3.0).abs() < 0.5, "LP 12 at cutoff: {at} dB");
    }

    #[test]
    fn lp24_is_24_db_down_an_octave_above_the_cutoff() {
        let mut d = configured(1, 0, 1_000.0, 0.0);
        let above = db(gain_at(&mut d, 2_000.0, 0.1));
        assert!((above + 24.0).abs() < 2.0, "LP 24 an octave up: {above} dB");
    }

    #[test]
    fn resonance_keeps_the_bass_fat_in_both_characters() {
        for character in [0, 1] {
            let mut flat = configured(1, character, 1_000.0, 0.0);
            let mut resonant = configured(1, character, 1_000.0, 0.9);
            let a = db(gain_at(&mut flat, 50.0, 0.05));
            let b = db(gain_at(&mut resonant, 50.0, 0.05));
            assert!(
                (a - b).abs() < 3.0,
                "character {character}: 50 Hz {a} dB flat vs {b} dB at resonance 0.9"
            );
        }
    }

    #[test]
    fn every_type_does_its_job_in_both_characters() {
        for character in [0, 1] {
            // (type, frequency, expected to pass)
            let cases = [
                (0, 8_000.0, false),
                (0, 60.0, true),
                (1, 8_000.0, false),
                (2, 60.0, false),
                (2, 10_000.0, true),
                (3, 60.0, false),
                (3, 10_000.0, true),
                (4, 60.0, false),
                (4, 12_000.0, false),
                (5, 1_000.0, false),
                (5, 60.0, true),
            ];
            for (ty, hz, passes) in cases {
                let mut d = configured(ty, character, 1_000.0, 0.2);
                let g = db(gain_at(&mut d, hz, 0.05));
                if passes {
                    assert!(g > -3.0, "type {ty} char {character} at {hz} Hz: {g} dB");
                } else {
                    assert!(g < -10.0, "type {ty} char {character} at {hz} Hz: {g} dB");
                }
            }
        }
    }

    #[test]
    fn a_full_sweep_is_finite_at_every_rate_for_both_characters() {
        for rate in [44_100.0f32, 48_000.0, 96_000.0, 192_000.0] {
            for character in [0, 1] {
                for ty in [1, 2, 3, 4, 5] {
                    let mut d = FilterDevice::new(rate);
                    d.prepare(rate, 4_096);
                    set_choice(&mut d, FILTER_TYPE, ty);
                    set_choice(&mut d, CHARACTER, character);
                    set_real(&mut d, RESONANCE, 1.0);
                    set_real(&mut d, DRIVE, 24.0);
                    let frames = (rate * 0.6) as usize;
                    let input = stereo(&white_noise(frames, 0.9, 5));
                    let mut out = Vec::new();
                    // Sweep the cutoff across the block boundaries.
                    for (i, chunk) in input.chunks(2 * 256).enumerate() {
                        let t = i as f32 * 256.0 / frames as f32;
                        set_real(&mut d, CUTOFF, 20.0 * 1_000f32.powf(t.min(1.0)));
                        out.extend(render(&mut d, chunk, &[256]));
                    }
                    assert!(
                        out.iter().all(|x| x.is_finite()),
                        "non-finite at {rate} Hz, character {character}, type {ty}"
                    );
                    assert!(
                        peak(&out) <= 2.0 + 1e-3,
                        "peak {} at {rate} char {character} type {ty}",
                        peak(&out)
                    );
                }
            }
        }
    }

    /// Energy (dB) in the bins that aren't odd multiples of 5 kHz, for a 5 kHz sine driven hard.
    fn alias_energy_db(quality: usize) -> f32 {
        let mut d = device();
        set_choice(&mut d, QUALITY, quality);
        set_real(&mut d, DRIVE, 24.0);
        set_real(&mut d, RESONANCE, 0.0);
        let frames = 48_000;
        let out = render(&mut d, &stereo(&sine(5_000.0, SR, frames, 0.3)), &[512]);
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        // Skip the start, use a whole number of periods: 4800 samples = 500 cycles of 5 kHz.
        let bins = spectrum_db(&left[24_000..24_000 + 4_800]);
        let bin_hz = SR / 4_800.0;
        let mut energy = 0.0f32;
        for (i, &level) in bins.iter().enumerate() {
            let hz = i as f32 * bin_hz;
            let harmonic = (hz / 5_000.0).round();
            let near_harmonic =
                (hz - harmonic * 5_000.0).abs() < 4.0 * bin_hz && (harmonic as i32) % 2 == 1;
            if !near_harmonic && hz > 100.0 {
                energy += 10f32.powf(level / 10.0);
            }
        }
        10.0 * energy.log10()
    }

    #[test]
    fn oversampling_cuts_alias_energy_under_heavy_drive() {
        let at_1x = alias_energy_db(0);
        let at_2x = alias_energy_db(1);
        let at_4x = alias_energy_db(2);
        println!("alias energy: 1x {at_1x:.1} dB, 2x {at_2x:.1} dB, 4x {at_4x:.1} dB");
        assert!(
            at_1x - at_2x >= 20.0,
            "alias energy: 1x {at_1x} dB, 2x {at_2x} dB, 4x {at_4x} dB"
        );
        assert!(at_2x - at_4x >= -1.0, "4x isn't worse than 2x");
    }

    #[test]
    fn a_synced_lfo_period_is_one_beat_at_120_bpm() {
        for playing in [true, false] {
            let mut d = device();
            set_choice(
                &mut d,
                LFO_SYNC,
                crate::audio::dsp::tempo_sync::index_of("1/4"),
            );
            set_real(&mut d, LFO_DEPTH, 1.0);
            d.set_transport(&Transport {
                tempo: 120.0,
                playing,
                song_pos_beats: 0.0,
                ..Default::default()
            });
            d.lfo_probe.clear();
            // Four seconds of audio in one host block, so the anchor isn't refreshed.
            render(&mut d, &vec![0.0; 2 * 48_000 * 4], &[48_000 * 4]);
            let probe = &d.lfo_probe;
            // Upward zero crossings.
            let crossings: Vec<usize> = (1..probe.len())
                .filter(|&i| probe[i - 1] < 0.0 && probe[i] >= 0.0)
                .collect();
            assert!(crossings.len() >= 6, "{} crossings", crossings.len());
            let periods: Vec<f32> = crossings
                .windows(2)
                .map(|w| (w[1] - w[0]) as f32 * CTRL_BLOCK as f32)
                .collect();
            for period in periods {
                // One beat at 120 BPM is 0.5 s, 24000 samples.
                assert!(
                    (period - 24_000.0).abs() <= CTRL_BLOCK as f32 * 1.5,
                    "playing {playing}: period {period} samples"
                );
            }
        }
    }

    #[test]
    fn a_synced_lfo_follows_the_song_position_while_playing() {
        let mut d = device();
        set_choice(
            &mut d,
            LFO_SYNC,
            crate::audio::dsp::tempo_sync::index_of("1/4"),
        );
        set_real(&mut d, LFO_DEPTH, 1.0);
        // A quarter beat in: the sine is at its peak, whatever happened before.
        d.set_transport(&Transport {
            tempo: 120.0,
            playing: true,
            song_pos_beats: 100.25 - CTRL_BLOCK as f64 / 48_000.0 * 2.0,
            ..Default::default()
        });
        d.lfo_probe.clear();
        render(&mut d, &vec![0.0; 2 * CTRL_BLOCK], &[CTRL_BLOCK]);
        assert!(d.lfo_probe[0] > 0.99, "{}", d.lfo_probe[0]);
    }

    #[test]
    fn envelope_amount_opens_the_cutoff_on_transients() {
        let burst = |amount: f32| {
            let mut d = device();
            set_real(&mut d, CUTOFF, 200.0);
            set_real(&mut d, ENV_AMOUNT, amount);
            set_real(&mut d, ENV_ATTACK, 0.1);
            let mut input = vec![0.0; 4_800];
            input.extend(sine(3_000.0, SR, 9_600, 0.8));
            let out = render(&mut d, &stereo(&input), &[512]);
            let left: Vec<f32> = out.iter().step_by(2).copied().collect();
            rms(&left[4_800 + 4_800..])
        };
        let closed = burst(0.0);
        let open = burst(4.0);
        assert!(
            db(open) - db(closed) > 20.0,
            "closed {} dB, open {} dB",
            db(closed),
            db(open)
        );
        // Negative amounts close it further: both ends are near silence, so compare against the
        // open case rather than the tiny residual the closed one leaves.
        let neg = burst(-4.0);
        assert!(
            db(neg) < db(open) - 30.0,
            "neg {} dB vs open {} dB",
            db(neg),
            db(open)
        );
    }

    #[test]
    fn lfo_depth_moves_the_cutoff_and_stereo_phase_splits_the_channels() {
        let mut d = device();
        set_real(&mut d, CUTOFF, 1_000.0);
        set_real(&mut d, LFO_DEPTH, 3.0);
        set_real(&mut d, LFO_RATE, 2.0);
        set_real(&mut d, LFO_STEREO_PHASE, 180.0);
        let out = render(&mut d, &stereo(&white_noise(96_000, 0.3, 9)), &[512]);
        let l: Vec<f32> = out.iter().step_by(2).copied().collect();
        let r: Vec<f32> = out.iter().skip(1).step_by(2).copied().collect();
        // Level in 4800-frame windows: the two channels swing in opposition.
        let window = |x: &[f32], i: usize| rms(&x[i * 4_800..(i + 1) * 4_800]);
        let (mut diff_max, mut swing) = (0.0f32, 0.0f32);
        for i in 2..19 {
            let (a, b) = (db(window(&l, i)), db(window(&r, i)));
            diff_max = diff_max.max((a - b).abs());
            swing = swing.max(a);
        }
        assert!(diff_max > 6.0, "channels differ by up to {diff_max} dB");
        assert!(swing > -30.0);
    }

    #[test]
    fn a_type_switch_jumps_no_further_than_the_signal_itself() {
        for character in [0, 1] {
            for (from, to) in [(1, 3), (1, 5), (3, 1)] {
                let mut d = configured(from, character, 500.0, 0.3);
                let input = stereo(&sine(440.0, SR, 48_000, 0.5));
                let mut out = render(&mut d, &input[..48_000], &[256]);
                set_choice(&mut d, FILTER_TYPE, to);
                out.extend(render(&mut d, &input[48_000..], &[256]));
                let left: Vec<f32> = out.iter().step_by(2).copied().collect();
                let worst_step = left
                    .windows(2)
                    .map(|w| (w[1] - w[0]).abs())
                    .fold(0.0, f32::max);
                // The signal itself swings 1.0 peak to peak.
                assert!(
                    worst_step <= 0.5,
                    "char {character} {from}->{to}: step {worst_step}"
                );
                assert!(peak(&left) < 1.5, "peak {}", peak(&left));
            }
        }
        // And a Character switch.
        let mut d = configured(1, 0, 500.0, 0.3);
        let input = stereo(&sine(440.0, SR, 48_000, 0.5));
        let mut out = render(&mut d, &input[..48_000], &[256]);
        set_choice(&mut d, CHARACTER, 1);
        out.extend(render(&mut d, &input[48_000..], &[256]));
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let worst_step = left
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        assert!(worst_step <= 0.5, "character switch: step {worst_step}");
    }

    #[test]
    fn the_limiter_caps_self_oscillation_and_gain_trims_the_wet_path() {
        let mut d = configured(1, 1, 1_000.0, 1.0);
        set_real(&mut d, DRIVE, 24.0);
        let out = render(&mut d, &stereo(&white_noise(48_000, 1.0, 3)), &[512]);
        assert!(peak(&out) <= 2.0 + 1e-4, "peak {}", peak(&out));

        let mut d = configured(0, 0, 20_000.0, 0.0);
        let unity = gain_at(&mut d, 500.0, 0.1);
        set_real(&mut d, GAIN, -12.0);
        let quiet = gain_at(&mut d, 500.0, 0.1);
        assert!((db(quiet) - db(unity) + 12.0).abs() < 0.3);
    }

    #[test]
    fn mix_is_linear_between_dry_and_wet() {
        let mut d = configured(0, 0, 100.0, 0.0);
        set_real(&mut d, MIX, 50.0);
        // 8 kHz is removed by the filter, so half the dry level remains.
        let g = gain_at(&mut d, 8_000.0, 0.1);
        assert!((g - 0.5).abs() < 0.02, "{g}");
    }

    #[test]
    fn quality_change_mid_stream_stays_finite_and_bounded() {
        let mut d = device();
        let input = stereo(&sine(300.0, SR, 48_000, 0.5));
        let mut out = Vec::new();
        for (i, chunk) in input.chunks(2 * 1_000).enumerate() {
            set_choice(&mut d, QUALITY, i % 3);
            out.extend(render(&mut d, chunk, &[300]));
        }
        assert!(out.iter().all(|x| x.is_finite()));
        assert!(peak(&out) < 1.5);
    }

    #[test]
    fn it_sleeps_after_silence_and_wakes_on_parameter_changes() {
        let mut d = device();
        for _ in 0..(3 * 48_000 / 512 + 2) {
            d.on_quiet_block();
        }
        assert!(d.is_sleeping());
        set_real(&mut d, RESONANCE, 0.5);
        assert!(!d.is_sleeping());
    }

    impl FilterDevice {
        fn on_quiet_block(&mut self) {
            self.process_block(&[0.0; 1_024], &mut [0.0; 1_024], 512);
            self.update_sleep_state(false);
        }
    }

    /// CPU at 2x Ladder, stereo, with the LFO and the envelope moving the cutoff (the worst
    /// case). Run with `cargo test --release filter_cpu -- --ignored --nocapture`: the plan's
    /// budget is 0.5 % of a core at 48 kHz.
    #[test]
    #[ignore = "timing test: run in release mode"]
    fn filter_cpu_2x_ladder_stereo() {
        let mut d = device();
        set_choice(&mut d, CHARACTER, 1);
        set_real(&mut d, RESONANCE, 0.6);
        set_real(&mut d, DRIVE, 12.0);
        set_real(&mut d, LFO_DEPTH, 2.0);
        set_real(&mut d, ENV_AMOUNT, 1.0);
        let seconds = 20;
        let input = stereo(&white_noise(SR as usize, 0.3, 4));
        let mut out = vec![0.0; input.len()];
        let start = std::time::Instant::now();
        for _ in 0..seconds {
            for (i, o) in input.chunks(512 * 2).zip(out.chunks_mut(512 * 2)) {
                d.process_block(i, o, i.len() / 2);
            }
        }
        let cpu = start.elapsed().as_secs_f64() / seconds as f64 * 100.0;
        println!("Filter 2x Ladder stereo: {cpu:.3} % of a core");
        assert!(cpu < 0.5, "{cpu} %");
    }
}
