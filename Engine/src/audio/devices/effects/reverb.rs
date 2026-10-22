//! Reverb device (spec 012, Phase 7).
//!
//! Three algorithms share one front end (pre-delay, early reflections, a 4-stage multi-channel
//! diffuser) and one output stage (wet tone filters, ducking, width, equal-power Mix):
//!
//! - **Room** and **Hall**: eight delay lines in a feedback delay network (FDN) with a Householder
//!   feedback matrix. Each line has a low-shelf and a high-shelf "absorbent" filter designed from
//!   Decay, the band multipliers and the band frequencies (after Jot), so the 1 kHz tail decays at
//!   `Decay` and each band at `Decay × Mult`. Room uses short, dense prime-millisecond lengths;
//!   Hall uses longer, sparser ones.
//! - **Plate**: the Dattorro figure-eight tank. Input all-passes feed two cross-coupled halves,
//!   each a modulated all-pass, a delay, the absorbent filter, a second all-pass and a second
//!   delay, and the output taps are spread over both halves. Same Decay EQ as the FDN.
//!
//! Every line inside a decay loop is read with all-pass interpolation, which is lossless at any
//! fraction: Size glides the lengths and the modulation sweeps them without the interpolation
//! adding its own high-frequency damping on every pass. All FDN lines and the first all-pass of
//! each plate half are modulated slowly to break up metallic ringing. Freeze fades the loop gain
//! to one and the damping, the modulation and the input out over `FREEZE_RAMP_MS`, bounded by a
//! soft clip. An algorithm change crossfades the whole wet signal (early reflections included) at
//! equal power. Ducking follows the dry input.

use super::effect::{pass_through, TailSleep};
use crate::audio::devices::param_table::{
    flatten, linear, log, skewed, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceContainer, DeviceSlots, DeviceVariant, ParamId, ParamInfo,
    ParamValue, SlotKind, SlotSpec, LOOP_BLOCK,
};
use crate::audio::dsp::block_delay::AlignDelay;
use crate::audio::dsp::delay_line::DelayLine;
use crate::audio::dsp::env_follower::{Detection, EnvFollower};
use crate::audio::dsp::gain::{db_to_gain, dry_wet_gains, gain_to_db, MixLaw};
use crate::audio::dsp::linear_svf::{LinearSvf, SvfCoefs, SvfShape};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::stream::MAX_BLOCK_FRAMES;
use std::f32::consts::{FRAC_1_SQRT_2, TAU};

// === Parameter table ===

pub const ALGORITHM: ParamId = 0;
pub const SIZE: ParamId = 1;
pub const DECAY: ParamId = 2;
pub const PREDELAY: ParamId = 3;
pub const DIFFUSION: ParamId = 4;
pub const EARLY: ParamId = 5;

pub const LOW_MULT: ParamId = 10;
pub const LOW_FREQ: ParamId = 11;
pub const HIGH_MULT: ParamId = 12;
pub const HIGH_FREQ: ParamId = 13;

pub const RATE: ParamId = 20;
pub const DEPTH: ParamId = 21;

pub const LOW_CUT: ParamId = 30;
pub const HIGH_CUT: ParamId = 31;

pub const DUCKING: ParamId = 40;
pub const FREEZE: ParamId = 41;

pub const WIDTH: ParamId = 50;
pub const MIX: ParamId = 51;

const ALGORITHMS: &[&str] = &["Room", "Hall", "Plate"];

/// Spec 040: Tank FX runs inside the decay loop, Wet FX on the finished wet signal.
static REVERB_SLOTS: [SlotSpec; 2] = [
    SlotSpec {
        key: "tank_fx",
        name: "Tank FX",
        kind: SlotKind::Loop,
    },
    SlotSpec {
        key: "wet_fx",
        name: "Wet FX",
        kind: SlotKind::Audio,
    },
];

/// While Tank FX is live no line is read closer than this many samples (see `LOOP_BLOCK`).
const LOOP_MIN_DELAY: f32 = (LOOP_BLOCK + 2) as f32;

/// Frames of scratch a new device holds before `prepare` sizes it for the stream.
const DEFAULT_SLOT_FRAMES: usize = 4096;

/// IDs are all below this.
const ID_SPACE: usize = 60;

#[rustfmt::skip]
const SPECS: [ParamSpec; 18] = flatten(&[
    &[
        spec(ALGORITHM, "Algorithm", "Space", "", Kind::Enum(ALGORITHMS), 1.0),
        spec(SIZE, "Size", "Space", "%", linear(0.0, 100.0), 50.0),
        spec(DECAY, "Decay", "Space", "s", log(0.1, 30.0), 2.2),
        spec(PREDELAY, "Pre-Delay", "Space", "ms", skewed(0.0, 500.0, 2.5), 20.0),
        spec(DIFFUSION, "Diffusion", "Space", "%", linear(0.0, 100.0), 80.0),
        spec(EARLY, "Early", "Space", "%", linear(0.0, 100.0), 50.0),
    ],
    &[
        spec(LOW_MULT, "Low Mult", "Decay EQ", "×", log(0.25, 2.0), 1.2),
        spec(LOW_FREQ, "Low Freq", "Decay EQ", "Hz", log(50.0, 1_000.0), 250.0),
        spec(HIGH_MULT, "High Mult", "Decay EQ", "×", log(0.1, 1.0), 0.5),
        spec(HIGH_FREQ, "High Freq", "Decay EQ", "Hz", log(1_000.0, 20_000.0), 4_000.0),
    ],
    &[
        spec(RATE, "Rate", "Modulation", "Hz", log(0.05, 5.0), 0.8),
        spec(DEPTH, "Depth", "Modulation", "%", linear(0.0, 100.0), 30.0),
    ],
    &[
        spec(LOW_CUT, "Low Cut", "Tone", "Hz", log(20.0, 1_000.0), 80.0),
        spec(HIGH_CUT, "High Cut", "Tone", "Hz", log(1_000.0, 20_000.0), 14_000.0),
    ],
    &[
        spec(DUCKING, "Ducking", "Dynamics", "%", linear(0.0, 100.0), 0.0),
        spec(FREEZE, "Freeze", "Dynamics", "", Kind::Bool, 0.0),
    ],
    &[
        spec(WIDTH, "Width", "Output", "%", linear(0.0, 200.0), 100.0),
        spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 30.0),
    ],
]);

/// Number of real parameters.
pub const PARAM_COUNT: usize = 18;

const SLOT_OF: [u8; ID_SPACE] = slot_table(&SPECS);

pub static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOT_OF);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Algorithm {
    Room,
    Hall,
    Plate,
}

impl Algorithm {
    fn from_index(index: usize) -> Self {
        match index {
            0 => Algorithm::Room,
            2 => Algorithm::Plate,
            _ => Algorithm::Hall,
        }
    }

    const ALL: [Algorithm; 3] = [Algorithm::Room, Algorithm::Hall, Algorithm::Plate];
}

// === Engineering constants ===

/// Size 0..1 maps to this length scale (50 % is the nominal 1.0).
const SIZE_MIN_SCALE: f32 = 0.5;
const SIZE_MAX_SCALE: f32 = 1.5;

/// Prime-millisecond FDN lengths per algorithm, scaled by Size. Mutually prime, so repeats
/// never line up.
const FDN_ROOM_MS: [f32; 8] = [17.0, 19.0, 23.0, 29.0, 31.0, 37.0, 41.0, 43.0];
const FDN_HALL_MS: [f32; 8] = [53.0, 59.0, 67.0, 71.0, 79.0, 83.0, 89.0, 97.0];

/// Modulation depth as a fraction of a line's length at Depth 100 %.
const FDN_MOD_FRACTION: f32 = 0.03;

/// Output and input tap patterns. The two output patterns are orthogonal (a Hadamard pair), so a
/// mono input — which excites the all-ones mode most — still gives decorrelated L and R.
const FDN_OUT_L: [f32; 8] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0];
const FDN_OUT_R: [f32; 8] = [1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0];
const FDN_IN_A: [f32; 8] = [1.0, 0.7, -0.5, 0.6, -0.8, 0.9, 0.3, -0.6];
const FDN_IN_B: [f32; 8] = [0.4, -0.7, 0.8, -0.3, 0.6, -0.9, 0.5, 0.7];

/// The eight modulation sines are one LFO at phase offsets `i·π/4`, as (cos, sin) of the offset:
/// `sin(θ + φ) = sin θ·cos φ + cos θ·sin φ` costs one `sin_cos` per sample for all eight.
const MOD_ROTATION: [(f32, f32); 8] = [
    (1.0, 0.0),
    (FRAC_1_SQRT_2, FRAC_1_SQRT_2),
    (0.0, 1.0),
    (-FRAC_1_SQRT_2, FRAC_1_SQRT_2),
    (-1.0, 0.0),
    (-FRAC_1_SQRT_2, -FRAC_1_SQRT_2),
    (0.0, -1.0),
    (FRAC_1_SQRT_2, -FRAC_1_SQRT_2),
];

/// Algorithm crossfade on a change, in seconds.
const ALGORITHM_CROSSFADE_S: f32 = 0.030;

/// Smoothing ramps. Gains (Early, Ducking, Width, Mix) glide per sample, the coefficients once
/// per block.
const PARAM_RAMP_MS: f32 = 20.0;
const SIZE_RAMP_MS: f32 = 120.0;
const PREDELAY_RAMP_MS: f32 = 40.0;
/// Freeze fades in and out over this, so the modulation and the input never step.
const FREEZE_RAMP_MS: f32 = 50.0;

/// The early reflections of one channel: (ms at Size 50 %, gain). Left and right use different
/// times, so they are decorrelated on their own and don't comb when summed to mono.
type Taps = &'static [(f32, f32)];

/// Room: dense and short.
///
/// Mirrored in `Godot/devices/builtin/reverb/ReverbData.gd` (`EARLY_ROOM`, `EARLY_HALL`,
/// `EARLY_PLATE`, `EARLY_RMS_GAIN`, `SIZE_MIN_SCALE`, `SIZE_MAX_SCALE`) for the decay map
/// (spec 050). Keep the two in step.
const EARLY_ROOM: [Taps; 2] = [
    &[
        (3.2, 0.80),
        (5.7, 0.60),
        (8.3, 0.75),
        (11.1, 0.50),
        (14.7, 0.65),
        (18.3, 0.45),
        (23.1, 0.50),
        (28.7, 0.35),
        (34.1, 0.40),
        (41.3, 0.30),
    ],
    &[
        (4.1, 0.70),
        (6.9, 0.55),
        (9.7, 0.50),
        (12.9, 0.70),
        (16.3, 0.60),
        (20.9, 0.55),
        (25.3, 0.40),
        (31.3, 0.45),
        (37.9, 0.30),
        (44.3, 0.35),
    ],
];
/// Hall: sparse and wide.
const EARLY_HALL: [Taps; 2] = [
    &[
        (17.3, 0.60),
        (23.7, 0.45),
        (31.1, 0.55),
        (41.7, 0.40),
        (53.3, 0.50),
        (67.7, 0.35),
        (83.1, 0.40),
    ],
    &[
        (19.9, 0.35),
        (27.1, 0.55),
        (35.9, 0.30),
        (47.3, 0.50),
        (59.9, 0.35),
        (73.1, 0.45),
        (89.3, 0.30),
    ],
];
/// Plate.
const EARLY_PLATE: [Taps; 2] = [
    &[
        (11.3, 0.50),
        (19.7, 0.40),
        (29.3, 0.45),
        (43.1, 0.35),
        (61.7, 0.30),
    ],
    &[
        (13.7, 0.40),
        (23.3, 0.50),
        (34.9, 0.35),
        (49.3, 0.45),
        (67.1, 0.35),
    ],
];
/// Every tap set is scaled to this RMS gain, so the algorithms' early reflections are equally
/// loud.
const EARLY_RMS_GAIN: f32 = 1.25;

/// Four diffuser stages, four mutually prime lengths (ms) each.
const DIFFUSER_MS: [[f32; 4]; 4] = [
    [1.3, 1.7, 2.1, 2.7],
    [3.1, 3.7, 4.3, 5.1],
    [5.7, 6.7, 7.9, 9.1],
    [10.3, 11.7, 13.3, 15.1],
];

/// Diffusion at which the plate's input all-passes have the paper's gains.
const DIFFUSION_NOMINAL: f32 = 0.8;

/// Dattorro input-diffusion all-pass lengths in samples at the paper's 29761 Hz, with gains.
const PLATE_IN_AP: [(f32, f32); 4] = [(142.0, 0.75), (107.0, 0.75), (379.0, 0.625), (277.0, 0.625)];
const PLATE_REF_RATE: f32 = 29_761.0;
/// The two tank halves (samples at 29761 Hz): modulated all-pass, delay, all-pass, delay.
const PLATE_HALF: [[f32; 4]; 2] = [
    [672.0, 4453.0, 1800.0, 3720.0],
    [908.0, 4217.0, 2656.0, 3163.0],
];
/// Tank all-pass gains: the paper's decay diffusion 1 (with its sign) and 2.
const PLATE_AP1_G: f32 = -0.7;
const PLATE_AP2_G: f32 = 0.5;
/// Peak sweep of the first tank all-passes at Depth 100 %, samples at 29761 Hz.
const PLATE_MOD_EXCURSION: f32 = 32.0;
/// Output taps per channel (Dattorro's table): (half, line, samples at 29761 Hz, sign), where line
/// 1 is the first delay, 2 the second all-pass and 3 the second delay.
const PLATE_TAPS: [[(usize, usize, f32, f32); 7]; 2] = [
    [
        (1, 1, 266.0, 1.0),
        (1, 1, 2974.0, 1.0),
        (1, 2, 1913.0, -1.0),
        (1, 3, 1996.0, 1.0),
        (0, 1, 1990.0, -1.0),
        (0, 2, 187.0, -1.0),
        (0, 3, 1066.0, -1.0),
    ],
    [
        (0, 1, 353.0, 1.0),
        (0, 1, 3627.0, 1.0),
        (0, 2, 1228.0, -1.0),
        (0, 3, 2673.0, 1.0),
        (1, 1, 2111.0, -1.0),
        (1, 2, 335.0, -1.0),
        (1, 3, 121.0, -1.0),
    ],
];
/// Output level of the plate taps: the plate's wet level matches Room's and Hall's.
const PLATE_OUT_SCALE: f32 = 0.36;

/// Feedback gain of a delay line of `delay_seconds` for a 60 dB decay of `t60` seconds.
#[inline]
fn feedback_gain(delay_seconds: f32, t60: f32) -> f32 {
    10f32.powf(-3.0 * delay_seconds / t60.max(1e-4))
}

/// Absorbent shelf gain in dB for a band whose target T60 is `t60 * mult`.
#[inline]
fn shelf_db(delay_seconds: f32, t60: f32, mult: f32) -> f32 {
    (60.0 * delay_seconds / t60.max(1e-4)) * ((mult - 1.0) / mult.max(1e-4))
}

/// Linear below ±1, then asymptotes to ±2: bounds a frozen or high-feedback loop without
/// colouring normal levels.
#[inline]
fn soft_clip(x: f32) -> f32 {
    let a = x.abs();
    if a <= 1.0 {
        x
    } else {
        let over = a - 1.0;
        x.signum() * (1.0 + over / (1.0 + over))
    }
}

/// One Schroeder all-pass of a whole-sample length: `y = d − g·x`, fed back with `x + g·y`.
/// Fixed lengths are rounded, never interpolated: a fractional read would low-pass the signal and
/// the filter would no longer be all-pass.
#[inline]
fn allpass(line: &mut DelayLine, x: f32, delay: usize, g: f32) -> f32 {
    let d = line.read(delay);
    let y = d - g * x;
    line.push(x + g * y);
    y
}

/// A fixed length in whole samples.
#[inline]
fn whole_samples(seconds: f32, sample_rate: f32) -> usize {
    (seconds * sample_rate).round().max(1.0) as usize
}

/// Jot-style absorbent filter: a second-order low shelf and high shelf, flat in the mid band, so
/// the band decay rates can be set independently without leaking into the 1 kHz tail. `low_db`
/// is the low-frequency gain relative to the mid band, `high_db` the high-frequency one. Two
/// cascaded first-order sections reach the shelf asymptote fast enough for the band T60 to match.
///
/// `ReverbData.gd` (`band_t60`, spec 050) mirrors this filter's magnitude to draw the decay map.
#[derive(Clone, Copy)]
struct Absorbent {
    low_lp: [OnePole; 2],
    high_lp: [OnePole; 2],
    low_gain: f32,
    high_gain: f32,
    low_g: f32,
    high_g: f32,
}

impl Absorbent {
    fn new() -> Self {
        Self {
            low_lp: [OnePole::new(); 2],
            high_lp: [OnePole::new(); 2],
            low_gain: 1.0,
            high_gain: 1.0,
            low_g: 0.0,
            high_g: 0.0,
        }
    }

    fn reset(&mut self) {
        for f in self.low_lp.iter_mut() {
            f.reset();
        }
        for f in self.high_lp.iter_mut() {
            f.reset();
        }
    }

    fn update(
        &mut self,
        low_freq: f32,
        high_freq: f32,
        low_db: f32,
        high_db: f32,
        sample_rate: f32,
    ) {
        // Half the dB per cascaded section.
        self.low_gain = db_to_gain(low_db * 0.5);
        self.high_gain = db_to_gain(high_db * 0.5);
        self.low_g = one_pole_g(low_freq, sample_rate);
        self.high_g = one_pole_g(high_freq, sample_rate);
    }

    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let mut y = x;
        // Low shelf: gain `low_gain` per section at DC, 1 in the band.
        for f in self.low_lp.iter_mut() {
            let lp = f.lowpass(y, self.low_g);
            y += (self.low_gain - 1.0) * lp;
        }
        // High shelf: gain `high_gain` per section at Nyquist, 1 in the band.
        for f in self.high_lp.iter_mut() {
            let lp = f.lowpass(y, self.high_g);
            y = self.high_gain * y + (1.0 - self.high_gain) * lp;
        }
        y
    }
}

/// Per-sample values every algorithm reads.
#[derive(Clone, Copy)]
struct Frame {
    /// The diffused input.
    dl: f32,
    dr: f32,
    size_scale: f32,
    mods: [f32; 8],
    /// Modulation depth 0..1, faded out by Freeze.
    depth: f32,
    /// Input level into the loop, faded out by Freeze.
    inject: f32,
    /// Freeze 0..1: blends each loop gain toward one and each absorbent toward flat, per
    /// sample so neither steps.
    freeze: f32,
    diffusion: f32,
}

/// A loop stage's output with Freeze applied: `filtered` (the absorbent's output) fades to the
/// unfiltered `x` and the gain to one.
#[inline]
fn frozen(x: f32, filtered: f32, gain: f32, freeze: f32) -> f32 {
    (filtered + (x - filtered) * freeze) * (gain + (1.0 - gain) * freeze)
}

impl Frame {
    /// The plate's all-pass sweep in samples.
    #[inline]
    fn plate_mod(&self, sample_rate: f32) -> f32 {
        self.mods[0] * self.depth * PLATE_MOD_EXCURSION * sample_rate / PLATE_REF_RATE
    }
}

/// What the plate's write phase needs from a sample's `Frame`, held for Tank FX.
#[derive(Clone, Copy, Default)]
struct PlateHeld {
    size_scale: f32,
    sweep: f32,
    freeze: f32,
}

impl PlateHeld {
    #[inline]
    fn of(f: &Frame, sample_rate: f32) -> Self {
        Self {
            size_scale: f.size_scale,
            sweep: f.plate_mod(sample_rate),
            freeze: f.freeze,
        }
    }
}

// === Diffuser ===

/// Four stages of four all-pass delays with a Hadamard mix and a Diffusion crossfade between the
/// plain tap and the mixed tap.
struct Diffuser {
    lines: [[DelayLine; 4]; 4],
    len: [[usize; 4]; 4],
}

impl Diffuser {
    fn new() -> Self {
        Self {
            lines: std::array::from_fn(|_| std::array::from_fn(|_| DelayLine::new())),
            len: [[1; 4]; 4],
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        for (stage, lengths) in DIFFUSER_MS.iter().enumerate() {
            for (i, &ms) in lengths.iter().enumerate() {
                self.len[stage][i] = whole_samples(ms * 0.001, sample_rate);
                self.lines[stage][i].prepare(self.len[stage][i]);
            }
        }
    }

    fn reset(&mut self) {
        for stage in self.lines.iter_mut() {
            for line in stage.iter_mut() {
                line.clear();
            }
        }
    }

    /// All four channels out; the reverb uses the first two.
    #[inline]
    fn process4(&mut self, x: [f32; 4], diffusion: f32) -> [f32; 4] {
        let mut x = x;
        let g = diffusion * 0.7;
        for stage in 0..4 {
            let mut d = [0.0f32; 4];
            for i in 0..4 {
                d[i] = self.lines[stage][i].read(self.len[stage][i]);
            }
            let h = [
                0.5 * (d[0] + d[1] + d[2] + d[3]),
                0.5 * (d[0] - d[1] + d[2] - d[3]),
                0.5 * (d[0] + d[1] - d[2] - d[3]),
                0.5 * (d[0] - d[1] - d[2] + d[3]),
            ];
            let mut y = [0.0f32; 4];
            for i in 0..4 {
                let mixed = d[i] + (h[i] - d[i]) * diffusion;
                y[i] = mixed - g * x[i];
                let fb = x[i] + g * y[i];
                self.lines[stage][i].push(fb);
            }
            x = y;
        }
        x
    }

    #[inline]
    fn process(&mut self, l: f32, r: f32, diffusion: f32) -> (f32, f32) {
        let y = self.process4([l, r, l, -r], diffusion);
        (y[0], y[1])
    }
}

// === FDN (Room / Hall) ===

/// Eight-line feedback delay network with a Householder feedback matrix and per-line absorbent
/// low/high shelves.
struct Fdn {
    lines: [DelayLine; 8],
    /// All-pass interpolation state of each line's read.
    state: [f32; 8],
    absorb: [Absorbent; 8],
    gain: [f32; 8],
    base_ms: [f32; 8],
    inject: f32,
    out_scale: f32,
}

impl Fdn {
    fn new(base_ms: [f32; 8], inject: f32, out_scale: f32) -> Self {
        Self {
            lines: std::array::from_fn(|_| DelayLine::new()),
            state: [0.0; 8],
            absorb: [Absorbent::new(); 8],
            gain: [0.0; 8],
            base_ms,
            inject,
            out_scale,
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        let longest = SIZE_MAX_SCALE * (1.0 + FDN_MOD_FRACTION);
        for (i, line) in self.lines.iter_mut().enumerate() {
            line.prepare_seconds(self.base_ms[i] * 0.001 * longest, sample_rate);
        }
    }

    fn reset(&mut self) {
        for line in self.lines.iter_mut() {
            line.clear();
        }
        self.state = [0.0; 8];
        for a in self.absorb.iter_mut() {
            a.reset();
        }
    }

    /// Recompute the absorbent filters and loop gains for the current Decay / band settings.
    fn update_coefs(
        &mut self,
        sample_rate: f32,
        size_scale: f32,
        decay: f32,
        low: (f32, f32),
        high: (f32, f32),
    ) {
        for i in 0..8 {
            let len_s = self.base_ms[i] * 0.001 * size_scale;
            self.gain[i] = feedback_gain(len_s, decay);
            let low_db = shelf_db(len_s, decay, low.0);
            let high_db = shelf_db(len_s, decay, high.0);
            self.absorb[i].update(low.1, high.1, low_db, high_db, sample_rate);
        }
    }

    /// Read phase: read the lines, apply the absorbent filters and loop gains. Returns the
    /// filtered line outputs `y` and the stereo output tap. `pending` is the number of samples
    /// of the current sub-block whose writes are still to come (0 on the plain path), and
    /// `floor` the shortest delay a read may use.
    #[inline]
    fn read(
        &mut self,
        f: &Frame,
        sample_rate: f32,
        pending: f32,
        floor: f32,
    ) -> ([f32; 8], f32, f32) {
        let mut d = [0.0f32; 8];
        for i in 0..8 {
            let base = self.base_ms[i] * 0.001 * sample_rate * f.size_scale;
            let delay = (base * (1.0 + FDN_MOD_FRACTION * f.depth * f.mods[i]))
                .max(2.0)
                .max(floor);
            d[i] = self.lines[i].read_allpass(delay - pending, &mut self.state[i]);
        }
        let mut y = [0.0f32; 8];
        for i in 0..8 {
            let filtered = self.absorb[i].process(d[i]);
            y[i] = frozen(d[i], filtered, self.gain[i], f.freeze);
        }
        let mut ol = 0.0;
        let mut or = 0.0;
        for i in 0..8 {
            ol += y[i] * FDN_OUT_L[i];
            or += y[i] * FDN_OUT_R[i];
        }
        (y, ol * self.out_scale, or * self.out_scale)
    }

    /// Householder: (I − 2/N · 1) y = y − 2·mean(y).
    #[inline]
    fn householder_mean(y: &[f32; 8]) -> f32 {
        y.iter().sum::<f32>() * (2.0 / 8.0)
    }

    /// What the input injects into line `i`.
    #[inline]
    fn injection(&self, i: usize, f: &Frame) -> f32 {
        (f.dl * FDN_IN_A[i] + f.dr * FDN_IN_B[i]) * self.inject * f.inject
    }

    /// Write phase: push the feedback vector plus the injection into the lines.
    #[inline]
    fn write(&mut self, y: &[f32; 8], f: &Frame) {
        let mean = Self::householder_mean(y);
        for i in 0..8 {
            let injection = self.injection(i, f);
            self.lines[i].push(soft_clip(y[i] - mean + injection));
        }
    }

    #[inline]
    fn process(&mut self, f: &Frame, sample_rate: f32) -> (f32, f32) {
        let (y, ol, or) = self.read(f, sample_rate, 0.0, 0.0);
        self.write(&y, f);
        (ol, or)
    }
}

// === Plate ===

/// One half of the Dattorro tank: modulated all-pass, delay, absorbent filter and gain, all-pass,
/// delay and gain. Its decayed output crosses into the other half.
struct PlateHalf {
    /// Modulated all-pass, first delay, second all-pass, second delay.
    lines: [DelayLine; 4],
    /// All-pass interpolation state of each line's loop read.
    state: [f32; 4],
    absorb: Absorbent,
    /// Gains after the first delay and after the second.
    gain: [f32; 2],
    /// Line lengths in seconds at Size 50 %.
    len: [f32; 4],
}

impl PlateHalf {
    fn new(half: usize) -> Self {
        Self {
            lines: std::array::from_fn(|_| DelayLine::new()),
            state: [0.0; 4],
            absorb: Absorbent::new(),
            gain: [0.0; 2],
            len: std::array::from_fn(|i| PLATE_HALF[half][i] / PLATE_REF_RATE),
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        let excursion = PLATE_MOD_EXCURSION / PLATE_REF_RATE;
        for (i, line) in self.lines.iter_mut().enumerate() {
            let sweep = if i == 0 { excursion } else { 0.0 };
            line.prepare_seconds(self.len[i] * SIZE_MAX_SCALE + sweep, sample_rate);
        }
    }

    fn reset(&mut self) {
        for line in self.lines.iter_mut() {
            line.clear();
        }
        self.state = [0.0; 4];
        self.absorb.reset();
    }

    fn update_coefs(
        &mut self,
        sample_rate: f32,
        size_scale: f32,
        decay: f32,
        low: (f32, f32),
        high: (f32, f32),
    ) {
        // Each gain covers the all-pass and delay before it (an all-pass delays energy by its
        // length on average); the absorbent covers the whole half.
        let segments = [
            (self.len[0] + self.len[1]) * size_scale,
            (self.len[2] + self.len[3]) * size_scale,
        ];
        for (gain, &seconds) in self.gain.iter_mut().zip(&segments) {
            *gain = feedback_gain(seconds, decay);
        }
        let half = segments[0] + segments[1];
        self.absorb.update(
            low.1,
            high.1,
            shelf_db(half, decay, low.0),
            shelf_db(half, decay, high.0),
            sample_rate,
        );
    }

    /// Read phase: the decayed output that crosses into the other half. `scale` is samples per
    /// second at the current Size; see [`Fdn::read`] for `pending` and `floor`.
    #[inline]
    fn cross(&mut self, scale: f32, freeze: f32, pending: f32, floor: f32) -> f32 {
        let delay = (self.len[3] * scale).max(floor);
        let d = self.lines[3].read_allpass(delay - pending, &mut self.state[3]);
        frozen(d, d, self.gain[1], freeze)
    }

    /// Read phase: an output tap `at` samples (at 29761 Hz) into `line`.
    #[inline]
    fn tap(&self, line: usize, at: f32, scale_ref: f32, pending: f32, floor: f32) -> f32 {
        self.lines[line].read_hermite((at * scale_ref).max(floor) - pending)
    }

    /// Write phase: run `x` (the input plus the other half's cross signal) through the half up
    /// to its second delay. `sweep` is the first all-pass's modulation in samples.
    #[inline]
    fn write(&mut self, x: f32, scale: f32, sweep: f32, freeze: f32) {
        let [ap1, d1, ap2, d2] = &mut self.lines;
        let d = ap1.read_allpass(self.len[0] * scale + sweep, &mut self.state[0]);
        let y = d - PLATE_AP1_G * x;
        ap1.push(x + PLATE_AP1_G * y);
        let a = d1.read_allpass(self.len[1] * scale, &mut self.state[1]);
        d1.push(soft_clip(y));
        let a = frozen(a, self.absorb.process(a), self.gain[0], freeze);
        let d = ap2.read_allpass(self.len[2] * scale, &mut self.state[2]);
        let y = d - PLATE_AP2_G * a;
        ap2.push(a + PLATE_AP2_G * y);
        d2.push(soft_clip(y));
    }
}

/// Dattorro plate: the input diffusion all-passes feed both halves of the figure-eight tank.
struct Plate {
    in_ap: [DelayLine; 4],
    in_len: [usize; 4],
    halves: [PlateHalf; 2],
}

impl Plate {
    fn new() -> Self {
        Self {
            in_ap: std::array::from_fn(|_| DelayLine::new()),
            in_len: [1; 4],
            halves: [PlateHalf::new(0), PlateHalf::new(1)],
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        for i in 0..self.in_ap.len() {
            self.in_len[i] = whole_samples(PLATE_IN_AP[i].0 / PLATE_REF_RATE, sample_rate);
            self.in_ap[i].prepare(self.in_len[i]);
        }
        for half in self.halves.iter_mut() {
            half.prepare(sample_rate);
        }
    }

    fn reset(&mut self) {
        for line in self.in_ap.iter_mut() {
            line.clear();
        }
        for half in self.halves.iter_mut() {
            half.reset();
        }
    }

    fn update_coefs(
        &mut self,
        sample_rate: f32,
        size_scale: f32,
        decay: f32,
        low: (f32, f32),
        high: (f32, f32),
    ) {
        for half in self.halves.iter_mut() {
            half.update_coefs(sample_rate, size_scale, decay, low, high);
        }
    }

    /// The input diffusion all-passes: the mono signal both halves are fed. Diffusion scales
    /// their gains around the paper's.
    #[inline]
    fn input(&mut self, dl: f32, dr: f32, diffusion: f32) -> f32 {
        let scale = (diffusion / DIFFUSION_NOMINAL).min(1.15);
        let mut v = (dl + dr) * 0.5;
        for i in 0..self.in_ap.len() {
            v = allpass(
                &mut self.in_ap[i],
                v,
                self.in_len[i],
                PLATE_IN_AP[i].1 * scale,
            );
        }
        v
    }

    /// Read phase: the two halves' cross signals and the stereo output.
    #[inline]
    fn read(
        &mut self,
        f: &Frame,
        sample_rate: f32,
        pending: f32,
        floor: f32,
    ) -> ([f32; 2], f32, f32) {
        let scale = sample_rate * f.size_scale;
        let cross = [
            self.halves[0].cross(scale, f.freeze, pending, floor),
            self.halves[1].cross(scale, f.freeze, pending, floor),
        ];
        let scale_ref = scale / PLATE_REF_RATE;
        let mut out = [0.0f32; 2];
        for (o, taps) in out.iter_mut().zip(&PLATE_TAPS) {
            for &(half, line, at, sign) in taps {
                *o += sign * self.halves[half].tap(line, at, scale_ref, pending, floor);
            }
        }
        (cross, out[0] * PLATE_OUT_SCALE, out[1] * PLATE_OUT_SCALE)
    }

    /// Write phase: each half takes the input plus the other half's cross signal (after Tank FX
    /// when it is live).
    #[inline]
    fn write(&mut self, v: f32, cross: [f32; 2], held: &PlateHeld, sample_rate: f32) {
        let scale = sample_rate * held.size_scale;
        self.halves[0].write(v + cross[1], scale, held.sweep, held.freeze);
        self.halves[1].write(v + cross[0], scale, -held.sweep, held.freeze);
    }

    #[inline]
    fn process(&mut self, f: &Frame, sample_rate: f32) -> (f32, f32) {
        // Scaled ahead of the input all-passes: their delayed taps would switch on as steps when
        // the plate fades in from empty lines.
        let v = self.input(f.dl * f.inject, f.dr * f.inject, f.diffusion);
        let (cross, ol, or) = self.read(f, sample_rate, 0.0, 0.0);
        self.write(v, cross, &PlateHeld::of(f, sample_rate), sample_rate);
        (ol, or)
    }
}

// === Device ===

#[derive(Clone, Copy)]
struct Settings {
    size: f32,
    decay: f32,
    predelay_ms: f32,
    diffusion: f32,
    early: f32,
    low_mult: f32,
    low_freq: f32,
    high_mult: f32,
    high_freq: f32,
    rate_hz: f32,
    mod_depth: f32,
    low_cut: f32,
    high_cut: f32,
    ducking: f32,
    freeze: bool,
    width: f32,
    mix: f32,
}

/// Frames per `"envelope"` record (spec 050).
const ENVELOPE_RECORD_FRAMES: usize = 256;
/// Records the envelope ring holds between polls. Records past this are dropped.
const ENVELOPE_RING_CAPACITY: usize = 256;
/// How often the `"envelope"` stream is polled, in Hz.
const ENVELOPE_RATE_HZ: f32 = 20.0;

/// The `"envelope"` data stream (spec 050): per `ENVELOPE_RECORD_FRAMES` frames, the peak of the
/// reverb's input and of its wet signal (after tone, ducking and width, before Wet FX and Mix),
/// in dB. Everything is preallocated; nothing is collected while unsubscribed.
struct EnvelopeScope {
    subscribed: bool,
    ring: [[f32; 2]; ENVELOPE_RING_CAPACITY],
    ring_len: usize,
    /// Frames accumulated into the current record.
    record_frames: usize,
    in_peak: f32,
    wet_peak: f32,
    frames_since_poll: usize,
    poll_interval: usize,
    record_seconds: f32,
}

impl EnvelopeScope {
    fn new(sample_rate: f32) -> Self {
        let mut scope = Self {
            subscribed: false,
            ring: [[0.0; 2]; ENVELOPE_RING_CAPACITY],
            ring_len: 0,
            record_frames: 0,
            in_peak: 0.0,
            wet_peak: 0.0,
            frames_since_poll: 0,
            poll_interval: 0,
            record_seconds: 0.0,
        };
        scope.prepare(sample_rate);
        scope
    }

    fn prepare(&mut self, sample_rate: f32) {
        self.poll_interval = (sample_rate / ENVELOPE_RATE_HZ) as usize;
        self.record_seconds = ENVELOPE_RECORD_FRAMES as f32 / sample_rate.max(1.0);
    }

    fn clear(&mut self) {
        self.ring_len = 0;
        self.record_frames = 0;
        self.in_peak = 0.0;
        self.wet_peak = 0.0;
        self.frames_since_poll = 0;
    }

    /// Fold one frame in; stores a record when the window is full. Audio thread: array writes
    /// and compares only (the dB conversion happens once per 256 frames).
    #[inline]
    fn push_frame(&mut self, in_peak: f32, wet_peak: f32) {
        self.in_peak = self.in_peak.max(in_peak);
        self.wet_peak = self.wet_peak.max(wet_peak);
        self.record_frames += 1;
        if self.record_frames < ENVELOPE_RECORD_FRAMES {
            return;
        }
        if self.ring_len < ENVELOPE_RING_CAPACITY {
            self.ring[self.ring_len] = [gain_to_db(self.in_peak), gain_to_db(self.wet_peak)];
            self.ring_len += 1;
        }
        self.record_frames = 0;
        self.in_peak = 0.0;
        self.wet_peak = 0.0;
    }
}

pub struct ReverbDevice {
    sample_rate: f32,
    params: ParamValues<PARAM_COUNT>,
    settings: Settings,

    predelay_l: DelayLine,
    predelay_r: DelayLine,
    early_l: DelayLine,
    early_r: DelayLine,
    /// Per algorithm, the left and right tap gain scale that sets `EARLY_RMS_GAIN`.
    early_norm: [[f32; 2]; 3],

    diffuser: Diffuser,
    fdn: [Fdn; 2],
    plate: Plate,

    /// Phase of the modulation LFO, 0..1.
    lfo_phase: f64,
    duck: EnvFollower,
    /// Wet tone filters, 12 dB/oct: Low Cut high-passes, High Cut low-passes.
    tone_hp: [LinearSvf; 2],
    tone_lp: [LinearSvf; 2],
    tone_hp_coefs: SvfCoefs,
    tone_lp_coefs: SvfCoefs,

    algorithm: Algorithm,
    prev_algorithm: Option<Algorithm>,
    /// Frames into the crossfade from `prev_algorithm` to `algorithm`.
    xfade: usize,
    xfade_frames: usize,

    size_s: SmoothedParam,
    predelay_s: SmoothedParam,
    decay_s: SmoothedParam,
    low_mult_s: SmoothedParam,
    low_freq_s: SmoothedParam,
    high_mult_s: SmoothedParam,
    high_freq_s: SmoothedParam,
    diffusion_s: SmoothedParam,
    early_s: SmoothedParam,
    rate_s: SmoothedParam,
    depth_s: SmoothedParam,
    low_cut_s: SmoothedParam,
    high_cut_s: SmoothedParam,
    ducking_s: SmoothedParam,
    freeze_s: SmoothedParam,
    width_s: SmoothedParam,
    mix_s: SmoothedParam,
    /// The Mix value `mix_gains` were computed for (they only change while Mix glides).
    mix_last: f32,
    mix_gains: (f32, f32),

    sleep: TailSleep,
    /// The `"envelope"` stream (spec 050). Never touches the sleep state.
    scope: EnvelopeScope,
    is_active: bool,
    is_enabled: bool,

    /// Tank FX and Wet FX chains plus scratch (spec 040).
    slots: DeviceSlots,
    /// Whole-block output while a plugin sits in Wet FX (`begin_block` / `finish_block`).
    whole_buf: Vec<f32>,
    /// The frames `begin_block` rendered into `whole_buf`, until `finish_block` copies them.
    whole_pending: usize,
    /// Latency compensation (spec 042 part D): the dry input delayed by the Wet FX latency, so
    /// it meets the wet signal; also the bypassed output. Fed every block.
    dry: AlignDelay,
    /// The delayed dry of one Wet FX chunk.
    dry_buf: Vec<f32>,
    /// Shortest line read in samples: `LOOP_MIN_DELAY` while Tank FX is live, else 0.
    loop_floor: f32,
    /// Tank FX scratch for one sub-block: the FDN feedback vectors and injections, the plate's
    /// input and write-phase values.
    fdn_f: [[f32; 8]; LOOP_BLOCK],
    fdn_inj: [[f32; 8]; LOOP_BLOCK],
    plate_v: [f32; LOOP_BLOCK],
    plate_held: [PlateHeld; LOOP_BLOCK],
}

impl ReverbDevice {
    pub fn new(sample_rate: f32) -> Self {
        let params = ParamValues::<PARAM_COUNT>::new(&TABLE);
        let real = |id: ParamId| params.real(id).unwrap_or(0.0);
        let algorithm = Algorithm::from_index(real(ALGORITHM) as usize);
        let settings = Settings {
            size: real(SIZE) / 100.0,
            decay: real(DECAY),
            predelay_ms: real(PREDELAY),
            diffusion: real(DIFFUSION) / 100.0,
            early: real(EARLY) / 100.0,
            low_mult: real(LOW_MULT),
            low_freq: real(LOW_FREQ),
            high_mult: real(HIGH_MULT),
            high_freq: real(HIGH_FREQ),
            rate_hz: real(RATE),
            mod_depth: real(DEPTH) / 100.0,
            low_cut: real(LOW_CUT),
            high_cut: real(HIGH_CUT),
            ducking: real(DUCKING) / 100.0,
            freeze: real(FREEZE) >= 0.5,
            width: real(WIDTH) / 100.0,
            mix: real(MIX) / 100.0,
        };
        let sr = sample_rate;
        let smoothed = |value: f32| SmoothedParam::new(value, sr, PARAM_RAMP_MS);
        let mut device = Self {
            sample_rate: sr,
            params,
            settings,
            predelay_l: DelayLine::new(),
            predelay_r: DelayLine::new(),
            early_l: DelayLine::new(),
            early_r: DelayLine::new(),
            early_norm: early_norms(),
            diffuser: Diffuser::new(),
            fdn: [
                Fdn::new(FDN_ROOM_MS, 0.35, 0.35),
                Fdn::new(FDN_HALL_MS, 0.35, 0.35),
            ],
            plate: Plate::new(),
            lfo_phase: 0.0,
            duck: EnvFollower::new(5.0, 200.0, sr, Detection::Peak),
            tone_hp: [LinearSvf::new(); 2],
            tone_lp: [LinearSvf::new(); 2],
            tone_hp_coefs: tone_coefs(SvfShape::HighPass, settings.low_cut, sr),
            tone_lp_coefs: tone_coefs(SvfShape::LowPass, settings.high_cut, sr),
            algorithm,
            prev_algorithm: None,
            xfade: 0,
            xfade_frames: 1,
            size_s: SmoothedParam::new(settings.size, sr, SIZE_RAMP_MS),
            predelay_s: SmoothedParam::new(settings.predelay_ms, sr, PREDELAY_RAMP_MS),
            decay_s: smoothed(settings.decay),
            low_mult_s: smoothed(settings.low_mult),
            low_freq_s: smoothed(settings.low_freq),
            high_mult_s: smoothed(settings.high_mult),
            high_freq_s: smoothed(settings.high_freq),
            diffusion_s: smoothed(settings.diffusion),
            early_s: smoothed(settings.early),
            rate_s: smoothed(settings.rate_hz),
            depth_s: smoothed(settings.mod_depth),
            low_cut_s: smoothed(settings.low_cut),
            high_cut_s: smoothed(settings.high_cut),
            ducking_s: smoothed(settings.ducking),
            freeze_s: SmoothedParam::new(freeze_target(settings.freeze), sr, FREEZE_RAMP_MS),
            width_s: smoothed(settings.width),
            mix_s: smoothed(settings.mix),
            mix_last: f32::NAN,
            mix_gains: (1.0, 0.0),
            sleep: TailSleep::new(sr),
            scope: EnvelopeScope::new(sr),
            is_active: true,
            is_enabled: true,
            slots: DeviceSlots::new(&REVERB_SLOTS, DEFAULT_SLOT_FRAMES),
            whole_buf: vec![0.0; DEFAULT_SLOT_FRAMES * 2],
            whole_pending: 0,
            dry: AlignDelay::default(),
            dry_buf: vec![0.0; DEFAULT_SLOT_FRAMES * 2],
            loop_floor: 0.0,
            fdn_f: [[0.0; 8]; LOOP_BLOCK],
            fdn_inj: [[0.0; 8]; LOOP_BLOCK],
            plate_v: [0.0; LOOP_BLOCK],
            plate_held: [PlateHeld::default(); LOOP_BLOCK],
        };
        device.prepare(sr, 0);
        device.update_tail();
        device
    }

    fn update_tail(&mut self) {
        if self.settings.freeze {
            self.sleep.set_tail_seconds(None);
        } else {
            self.sleep.set_tail_seconds(Some(
                self.settings.decay * 1.5 + self.settings.predelay_ms * 0.001,
            ));
        }
    }

    /// Recompute block-rate coefficients from the smoothed parameter values, once per block.
    fn update_block(&mut self, frames: usize) {
        // Advance the block-rate smoothers by the whole block; the gains, Size, Pre-Delay and
        // Freeze glide per sample. Advancing by frames keeps the trajectory independent of the
        // block size.
        for p in [
            &mut self.decay_s,
            &mut self.low_mult_s,
            &mut self.low_freq_s,
            &mut self.high_mult_s,
            &mut self.high_freq_s,
            &mut self.diffusion_s,
            &mut self.rate_s,
            &mut self.depth_s,
            &mut self.low_cut_s,
            &mut self.high_cut_s,
        ] {
            p.skip(frames);
        }

        let size = SIZE_MIN_SCALE + self.size_s.current() * (SIZE_MAX_SCALE - SIZE_MIN_SCALE);
        let decay = self.decay_s.current();
        let low = (self.low_mult_s.current(), self.low_freq_s.current());
        let high = (self.high_mult_s.current(), self.high_freq_s.current());
        let sr = self.sample_rate;

        self.fdn[0].update_coefs(sr, size, decay, low, high);
        self.fdn[1].update_coefs(sr, size, decay, low, high);
        self.plate.update_coefs(sr, size, decay, low, high);

        self.tone_hp_coefs = tone_coefs(SvfShape::HighPass, self.low_cut_s.current(), sr);
        self.tone_lp_coefs = tone_coefs(SvfShape::LowPass, self.high_cut_s.current(), sr);
    }

    /// Dry and wet gains for the next sample; Mix glides per sample.
    #[inline]
    fn next_mix_gains(&mut self) -> (f32, f32) {
        let mix = self.mix_s.next();
        if mix != self.mix_last {
            self.mix_last = mix;
            self.mix_gains = dry_wet_gains(mix, MixLaw::EqualPower);
        }
        self.mix_gains
    }

    /// The eight modulation values for this sample, then advance the LFO.
    #[inline]
    fn next_mods(&mut self) -> [f32; 8] {
        let (s, c) = (TAU * self.lfo_phase as f32).sin_cos();
        self.lfo_phase += self.rate_s.current() as f64 / self.sample_rate as f64;
        if self.lfo_phase >= 1.0 {
            self.lfo_phase -= 1.0;
        }
        std::array::from_fn(|i| s * MOD_ROTATION[i].0 + c * MOD_ROTATION[i].1)
    }

    /// `algo`'s early reflections of the pre-delayed input, read before this sample is pushed.
    #[inline]
    fn early(&self, algo: Algorithm, size_scale: f32) -> (f32, f32) {
        let k = 0.001 * self.sample_rate * size_scale;
        let sum = |line: &DelayLine, taps: Taps| -> f32 {
            taps.iter()
                .map(|&(ms, g)| g * line.read_hermite(ms * k))
                .sum()
        };
        let [left, right] = early_taps(algo);
        let [norm_l, norm_r] = self.early_norm[algo as usize];
        (
            sum(&self.early_l, left) * norm_l,
            sum(&self.early_r, right) * norm_r,
        )
    }

    #[inline]
    fn late(&mut self, algo: Algorithm, f: &Frame) -> (f32, f32) {
        let sr = self.sample_rate;
        match algo {
            Algorithm::Room => self.fdn[0].process(f, sr),
            Algorithm::Hall => self.fdn[1].process(f, sr),
            Algorithm::Plate => self.plate.process(f, sr),
        }
    }

    /// `late` for the current algorithm with its loop signal held back for Tank FX (sample `k`
    /// of the sub-block). A fading algorithm finishes on the plain path.
    #[inline]
    fn late_looped(&mut self, f: &Frame, k: usize) -> (f32, f32) {
        let sr = self.sample_rate;
        let (pending, floor) = (k as f32, self.loop_floor);
        match self.algorithm {
            Algorithm::Room | Algorithm::Hall => {
                let fdn = &mut self.fdn[fdn_index(self.algorithm)];
                let (y, ol, or) = fdn.read(f, sr, pending, floor);
                let mean = Fdn::householder_mean(&y);
                let (mut pl, mut pr) = (0.0f32, 0.0f32);
                for i in 0..8 {
                    let fb = y[i] - mean;
                    self.fdn_f[k][i] = fb;
                    self.fdn_inj[k][i] = fdn.injection(i, f);
                    pl += fb * FDN_OUT_L[i];
                    pr += fb * FDN_OUT_R[i];
                }
                // The chain sees the loop at output level.
                self.slots.loop_in[2 * k] = pl * fdn.out_scale;
                self.slots.loop_in[2 * k + 1] = pr * fdn.out_scale;
                (ol, or)
            }
            Algorithm::Plate => {
                let v = self
                    .plate
                    .input(f.dl * f.inject, f.dr * f.inject, f.diffusion);
                let (cross, ol, or) = self.plate.read(f, sr, pending, floor);
                self.plate_v[k] = v;
                self.plate_held[k] = PlateHeld::of(f, sr);
                self.slots.loop_in[2 * k] = cross[0];
                self.slots.loop_in[2 * k + 1] = cross[1];
                (ol, or)
            }
        }
    }

    /// Chain and write phases for the `n` samples read since the last call: run Tank FX on the
    /// held loop signal and push the result into the lines.
    fn finish_loop(&mut self, n: usize) {
        if n == 0 {
            return;
        }
        // `take` leaves empty Vecs behind (no allocation) so the slot chain can be borrowed.
        let loop_in = std::mem::take(&mut self.slots.loop_in);
        let mut loop_out = std::mem::take(&mut self.slots.loop_out);
        if let Some(chain) = self.slots.chain_mut(0) {
            chain.process_block(&loop_in[..2 * n], &mut loop_out[..2 * n], n);
        }
        let sr = self.sample_rate;
        match self.algorithm {
            Algorithm::Room | Algorithm::Hall => {
                let fdn = &mut self.fdn[fdn_index(self.algorithm)];
                for k in 0..n {
                    // Only the difference the chain made goes back into the lines, along the
                    // two directions it saw. A unity chain leaves the vector untouched.
                    let dl = (loop_out[2 * k] - loop_in[2 * k]) / fdn.out_scale;
                    let dr = (loop_out[2 * k + 1] - loop_in[2 * k + 1]) / fdn.out_scale;
                    for i in 0..8 {
                        let f = self.fdn_f[k][i]
                            + dl * FDN_OUT_L[i] * 0.125
                            + dr * FDN_OUT_R[i] * 0.125;
                        fdn.lines[i].push(soft_clip(f + self.fdn_inj[k][i]));
                    }
                }
            }
            Algorithm::Plate => {
                for k in 0..n {
                    let cross = [loop_out[2 * k], loop_out[2 * k + 1]];
                    self.plate
                        .write(self.plate_v[k], cross, &self.plate_held[k], sr);
                }
            }
        }
        self.slots.loop_in = loop_in;
        self.slots.loop_out = loop_out;
    }

    /// One sample of the wet signal. `held` is the sample's index in the Tank FX sub-block, or
    /// `None` on the plain path.
    #[inline]
    fn process_sample(&mut self, in_l: f32, in_r: f32, held: Option<usize>) -> (f32, f32) {
        let sr = self.sample_rate;
        // Advance per-sample smoothers exactly once, whichever algorithm runs.
        let size_scale = SIZE_MIN_SCALE + self.size_s.next() * (SIZE_MAX_SCALE - SIZE_MIN_SCALE);
        let pd = (self.predelay_s.next() * 0.001 * sr).max(1.0);
        let freeze = self.freeze_s.next();
        let early_level = self.early_s.next();
        let duck = self.ducking_s.next();
        let width = self.width_s.next();

        let pl = self.predelay_l.read_hermite(pd);
        let pr = self.predelay_r.read_hermite(pd);
        self.predelay_l.push(in_l);
        self.predelay_r.push(in_r);

        let diffusion = self.diffusion_s.current();
        let (dl, dr) = self.diffuser.process(pl, pr, diffusion);
        let frame = Frame {
            dl,
            dr,
            size_scale,
            mods: self.next_mods(),
            depth: self.depth_s.current() * (1.0 - freeze),
            inject: 1.0 - freeze,
            freeze,
            diffusion,
        };

        // While it fades in, the incoming algorithm's input fades in too: it starts from empty
        // lines, and an input switched on at full level would come out of every line as a step.
        let incoming = match self.prev_algorithm {
            Some(_) => Frame {
                inject: frame.inject * (self.xfade as f32 / self.xfade_frames.max(1) as f32),
                ..frame
            },
            None => frame,
        };
        let (el, er) = self.early(self.algorithm, size_scale);
        let (ll, lr) = match held {
            Some(k) => self.late_looped(&incoming, k),
            None => self.late(self.algorithm, &incoming),
        };
        let mut wl = el * early_level + ll;
        let mut wr = er * early_level + lr;

        if let Some(prev) = self.prev_algorithm {
            // Equal power: the two tails are uncorrelated.
            let (pel, per) = self.early(prev, size_scale);
            let (pll, plr) = self.late(prev, &frame);
            // The last sample of the fade reaches t = 1, so dropping `prev` afterwards never steps.
            let t = (self.xfade + 1) as f32 / self.xfade_frames.max(1) as f32;
            let (out, into) = dry_wet_gains(t, MixLaw::EqualPower);
            wl = (pel * early_level + pll) * out + wl * into;
            wr = (per * early_level + plr) * out + wr * into;
            self.xfade += 1;
            if self.xfade >= self.xfade_frames {
                self.prev_algorithm = None;
            }
        }
        self.early_l.push(pl);
        self.early_r.push(pr);

        // Wet tone filters (outside the loop).
        wl = self.tone_lp[0].process(wl, &self.tone_lp_coefs);
        wl = self.tone_hp[0].process(wl, &self.tone_hp_coefs);
        wr = self.tone_lp[1].process(wr, &self.tone_lp_coefs);
        wr = self.tone_hp[1].process(wr, &self.tone_hp_coefs);

        // Ducking: the dry input turns the wet signal down.
        let env = self.duck.process(in_l.abs().max(in_r.abs()));
        if duck > 0.0 {
            let norm = ((gain_to_db(env) + 40.0) / 40.0).clamp(0.0, 1.0);
            let g = 1.0 - duck * norm;
            wl *= g;
            wr *= g;
        }

        // Width on the wet signal only (M/S).
        if (width - 1.0).abs() > 1e-6 {
            let m = (wl + wr) * 0.5;
            let s = (wl - wr) * 0.5;
            wl = m + s * width;
            wr = m - s * width;
        }
        if self.scope.subscribed {
            self.scope
                .push_frame(in_l.abs().max(in_r.abs()), wl.abs().max(wr.abs()));
        }
        (wl, wr)
    }

    /// The processing core of `process_block`: the plain path when both slots are empty, else
    /// Tank FX in sub-blocks and/or Wet FX in a second pass over the wet signal.
    fn render(&mut self, inputs: &[f32], outputs: &mut [f32], frames: usize) {
        self.update_block(frames);
        let tank = self.slots.is_live(0);
        let wet_fx = self.slots.is_live(1);
        self.loop_floor = if tank { LOOP_MIN_DELAY } else { 0.0 };

        if !wet_fx {
            // Keep the dry delay's history current for when Wet FX turns live
            self.dry.write(inputs, frames);
        }
        if !tank && !wet_fx {
            for f in 0..frames {
                let in_l = inputs[f * 2];
                let in_r = inputs[f * 2 + 1];
                let (wl, wr) = self.process_sample(in_l, in_r, None);
                let (dry, wet) = self.next_mix_gains();
                outputs[f * 2] = in_l * dry + wl * wet;
                outputs[f * 2 + 1] = in_r * dry + wr * wet;
            }
            return;
        }

        // Wet FX: pass 1 renders the wet signal into `wet_buf`, the chain runs on it (its output
        // lands in `outputs`, used as scratch), pass 2 mixes. Long blocks go in chunks.
        let mut wet_buf = std::mem::take(&mut self.slots.slot_buf);
        let chunk = if wet_fx {
            (wet_buf.len() / 2).max(1)
        } else {
            frames.max(1)
        };
        let mut base = 0;
        while base < frames {
            let n = (frames - base).min(chunk);
            let mut held = 0;
            for i in 0..n {
                let f = base + i;
                let in_l = inputs[f * 2];
                let in_r = inputs[f * 2 + 1];
                let (wl, wr) = self.process_sample(in_l, in_r, tank.then_some(held));
                if tank {
                    held += 1;
                    if held == LOOP_BLOCK {
                        self.finish_loop(held);
                        held = 0;
                    }
                }
                if wet_fx {
                    wet_buf[i * 2] = wl;
                    wet_buf[i * 2 + 1] = wr;
                } else {
                    let (dry, wet) = self.next_mix_gains();
                    outputs[f * 2] = in_l * dry + wl * wet;
                    outputs[f * 2 + 1] = in_r * dry + wr * wet;
                }
            }
            self.finish_loop(held);
            if wet_fx {
                let out = &mut outputs[base * 2..(base + n) * 2];
                if let Some(chain) = self.slots.chain_mut(1) {
                    chain.process_block(&wet_buf[..n * 2], out, n);
                }
                // The dry waits for the Wet FX chain's latency
                let input = &inputs[base * 2..(base + n) * 2];
                self.dry.process(input, &mut self.dry_buf[..n * 2], n);
                for i in 0..n {
                    let f = base + i;
                    let (dry, wet) = self.next_mix_gains();
                    outputs[f * 2] = self.dry_buf[i * 2] * dry + outputs[f * 2] * wet;
                    outputs[f * 2 + 1] = self.dry_buf[i * 2 + 1] * dry + outputs[f * 2 + 1] * wet;
                }
            }
            base += n;
        }
        self.slots.slot_buf = wet_buf;
    }

    /// Clear one algorithm's loop.
    fn clear_engine(&mut self, algo: Algorithm) {
        match algo {
            Algorithm::Room => self.fdn[0].reset(),
            Algorithm::Hall => self.fdn[1].reset(),
            Algorithm::Plate => self.plate.reset(),
        }
    }

    /// Clear everything that holds the wet signal: the shared front end and filters and the
    /// current algorithm. The others are cleared when they are selected.
    fn clear_tail(&mut self) {
        self.predelay_l.clear();
        self.predelay_r.clear();
        self.early_l.clear();
        self.early_r.clear();
        self.diffuser.reset();
        self.clear_engine(self.algorithm);
        self.duck.reset();
        for f in self.tone_hp.iter_mut().chain(self.tone_lp.iter_mut()) {
            *f = LinearSvf::new();
        }
        self.prev_algorithm = None;
        self.xfade = 0;
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            ALGORITHM => {
                let algo = Algorithm::from_index(real as usize);
                if algo != self.algorithm {
                    if self.prev_algorithm == Some(algo) {
                        // Back to the one still fading out: carry on from its current level.
                        self.xfade = self.xfade_frames.saturating_sub(self.xfade);
                    } else {
                        // Its lines still hold what was ringing when it was last left (a bounded
                        // memset, no allocation).
                        self.clear_engine(algo);
                        self.xfade = 0;
                    }
                    self.prev_algorithm = Some(self.algorithm);
                    self.algorithm = algo;
                }
            }
            SIZE => {
                self.settings.size = real / 100.0;
                self.size_s.set_target(self.settings.size);
            }
            DECAY => {
                self.settings.decay = real;
                self.decay_s.set_target(real);
                self.update_tail();
            }
            PREDELAY => {
                self.settings.predelay_ms = real;
                self.predelay_s.set_target(real);
                self.update_tail();
            }
            DIFFUSION => {
                self.settings.diffusion = real / 100.0;
                self.diffusion_s.set_target(self.settings.diffusion);
            }
            EARLY => {
                self.settings.early = real / 100.0;
                self.early_s.set_target(self.settings.early);
            }
            LOW_MULT => {
                self.settings.low_mult = real;
                self.low_mult_s.set_target(real);
            }
            LOW_FREQ => {
                self.settings.low_freq = real;
                self.low_freq_s.set_target(real);
            }
            HIGH_MULT => {
                self.settings.high_mult = real;
                self.high_mult_s.set_target(real);
            }
            HIGH_FREQ => {
                self.settings.high_freq = real;
                self.high_freq_s.set_target(real);
            }
            RATE => {
                self.settings.rate_hz = real;
                self.rate_s.set_target(real);
            }
            DEPTH => {
                self.settings.mod_depth = real / 100.0;
                self.depth_s.set_target(self.settings.mod_depth);
            }
            LOW_CUT => {
                self.settings.low_cut = real;
                self.low_cut_s.set_target(real);
            }
            HIGH_CUT => {
                self.settings.high_cut = real;
                self.high_cut_s.set_target(real);
            }
            DUCKING => {
                self.settings.ducking = real / 100.0;
                self.ducking_s.set_target(self.settings.ducking);
            }
            FREEZE => {
                self.settings.freeze = real >= 0.5;
                self.freeze_s
                    .set_target(freeze_target(self.settings.freeze));
                self.update_tail();
            }
            WIDTH => {
                self.settings.width = real / 100.0;
                self.width_s.set_target(self.settings.width);
            }
            MIX => {
                self.settings.mix = real / 100.0;
                self.mix_s.set_target(self.settings.mix);
            }
            _ => {}
        }
    }
}

fn early_taps(algorithm: Algorithm) -> [Taps; 2] {
    match algorithm {
        Algorithm::Room => EARLY_ROOM,
        Algorithm::Hall => EARLY_HALL,
        Algorithm::Plate => EARLY_PLATE,
    }
}

fn early_norms() -> [[f32; 2]; 3] {
    let norm = |taps: Taps| {
        let energy: f32 = taps.iter().map(|&(_, g)| g * g).sum();
        EARLY_RMS_GAIN / energy.sqrt()
    };
    Algorithm::ALL.map(|algo| early_taps(algo).map(norm))
}

fn fdn_index(algorithm: Algorithm) -> usize {
    if algorithm == Algorithm::Room {
        0
    } else {
        1
    }
}

fn freeze_target(freeze: bool) -> f32 {
    if freeze {
        1.0
    } else {
        0.0
    }
}

fn tone_coefs(shape: SvfShape, freq: f32, sample_rate: f32) -> SvfCoefs {
    SvfCoefs::new(
        shape,
        freq.min(sample_rate * 0.45),
        FRAC_1_SQRT_2,
        0.0,
        sample_rate,
    )
}

impl AudioDevice for ReverbDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_enabled && self.dry.frames() > 0 {
            // Bypass keeps the Wet FX latency
            self.dry.process(inputs, outputs, sample_count);
            self.sleep.on_block(sample_count);
            return;
        }
        if !self.is_active || !self.is_enabled {
            pass_through(inputs, outputs, sample_count);
            self.sleep.on_block(sample_count);
            return;
        }
        let frames = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        self.render(inputs, outputs, frames);
        if self.scope.subscribed {
            self.scope.frames_since_poll += frames;
        }
        self.sleep.on_block(frames);
    }

    /// With a plugin in Wet FX the wrapper must not split the block (REQ-013): the whole block
    /// is rendered here, synchronously, and `finish_block` hands it out.
    fn begin_block(&mut self, inputs: &[f32], sample_count: usize) -> bool {
        if !self.has_async_blocks() {
            return false;
        }
        let frames = sample_count.min(inputs.len() / 2);
        if frames * 2 > self.whole_buf.len() {
            return false;
        }
        let mut out = std::mem::take(&mut self.whole_buf);
        self.process_block(inputs, &mut out[..frames * 2], frames);
        self.whole_buf = out;
        self.whole_pending = frames;
        true
    }

    fn finish_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let frames = std::mem::take(&mut self.whole_pending);
        if frames == 0 {
            pass_through(inputs, outputs, sample_count);
            return;
        }
        let n = (frames * 2).min(outputs.len());
        outputs[..n].copy_from_slice(&self.whole_buf[..n]);
    }

    fn has_async_blocks(&self) -> bool {
        self.slots.has_async(1)
    }

    /// The Wet FX chain's latency while it runs (an empty or all-bypassed slot is skipped).
    /// Tank FX is a loop slot and takes no plugins.
    fn latency_frames(&self) -> u32 {
        if self.slots.is_live(1) {
            self.slots
                .chain(1)
                .map_or(0, |chain| chain.latency_frames())
        } else {
            0
        }
    }

    fn update_latency(&mut self, sample_rate: f32) -> u32 {
        if let Some(chain) = self.slots.chain_mut(1) {
            chain.update_latency(sample_rate);
        }
        let latency = self.latency_frames();
        self.dry.set(latency as usize, MAX_BLOCK_FRAMES);
        latency
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.sleep.wake();
        if let Some((_, real)) = self.params.set(param_id, value) {
            self.apply(param_id, real);
        }
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        self.sleep.wake();
        if let Some((_, real)) = self.params.set_offset(param_id, offset) {
            self.apply(param_id, real);
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.params.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.reverb"
    }

    fn device_name(&self) -> &str {
        "Reverb"
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
        self.slots.reset();
        self.whole_buf.fill(0.0);
        self.whole_pending = 0;
        self.clear_tail();
        for algo in Algorithm::ALL {
            self.clear_engine(algo);
        }
        self.lfo_phase = 0.0;
        self.scope.clear();
        // Snap the smoothers to their targets so a reset starts from the current settings.
        let s = self.settings;
        self.size_s.snap(s.size);
        self.predelay_s.snap(s.predelay_ms);
        self.decay_s.snap(s.decay);
        self.low_mult_s.snap(s.low_mult);
        self.low_freq_s.snap(s.low_freq);
        self.high_mult_s.snap(s.high_mult);
        self.high_freq_s.snap(s.high_freq);
        self.diffusion_s.snap(s.diffusion);
        self.early_s.snap(s.early);
        self.rate_s.snap(s.rate_hz);
        self.depth_s.snap(s.mod_depth);
        self.low_cut_s.snap(s.low_cut);
        self.high_cut_s.snap(s.high_cut);
        self.ducking_s.snap(s.ducking);
        self.freeze_s.snap(freeze_target(s.freeze));
        self.width_s.snap(s.width);
        self.mix_s.snap(s.mix);
        self.sleep.wake();
    }

    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        self.sample_rate = sample_rate;
        self.slots.prepare(sample_rate, max_frames);
        if self.whole_buf.len() < max_frames * 2 {
            self.whole_buf.resize(max_frames * 2, 0.0);
        }
        if self.dry_buf.len() < self.slots.slot_buf.len() {
            self.dry_buf.resize(self.slots.slot_buf.len(), 0.0);
        }
        self.predelay_l.prepare_seconds(0.5, sample_rate);
        self.predelay_r.prepare_seconds(0.5, sample_rate);
        // The longest early tap at Size 100 %.
        self.early_l.prepare_seconds(0.25, sample_rate);
        self.early_r.prepare_seconds(0.25, sample_rate);
        self.diffuser.prepare(sample_rate);
        for fdn in self.fdn.iter_mut() {
            fdn.prepare(sample_rate);
        }
        self.plate.prepare(sample_rate);
        self.duck.set_times(5.0, 200.0, sample_rate);
        self.xfade_frames = ((ALGORITHM_CROSSFADE_S * sample_rate) as usize).max(1);
        self.size_s.set_ramp(sample_rate, SIZE_RAMP_MS);
        self.predelay_s.set_ramp(sample_rate, PREDELAY_RAMP_MS);
        self.freeze_s.set_ramp(sample_rate, FREEZE_RAMP_MS);
        for p in [
            &mut self.decay_s,
            &mut self.low_mult_s,
            &mut self.low_freq_s,
            &mut self.high_mult_s,
            &mut self.high_freq_s,
            &mut self.diffusion_s,
            &mut self.early_s,
            &mut self.rate_s,
            &mut self.depth_s,
            &mut self.low_cut_s,
            &mut self.high_cut_s,
            &mut self.ducking_s,
            &mut self.width_s,
            &mut self.mix_s,
        ] {
            p.set_ramp(sample_rate, PARAM_RAMP_MS);
        }
        self.sleep.set_sample_rate(sample_rate);
        self.scope.prepare(sample_rate);
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
        self.reset();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        // A bypassed reverb isn't processed, so its lines still hold the tail it was cut off
        // with: start clean rather than resume it.
        if enabled && !self.is_enabled {
            self.clear_tail();
        }
        self.is_enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    // === Slots (spec 040) ===

    fn device_slots(&self) -> &'static [SlotSpec] {
        &REVERB_SLOTS
    }

    fn as_container(&self) -> Option<&dyn DeviceContainer> {
        Some(&self.slots)
    }

    fn as_container_mut(&mut self) -> Option<&mut dyn DeviceContainer> {
        Some(&mut self.slots)
    }

    fn is_container(&self) -> bool {
        true
    }

    fn is_sleeping(&self) -> bool {
        self.sleep.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.sleep.wake();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        // The envelope stream deliberately does not keep the reverb awake (spec 050 REQ-010).
        self.sleep.update(has_audio_activity)
    }

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if data_type != "envelope" {
            return Err(format!("Reverb does not support '{data_type}' data"));
        }
        if !self.scope.subscribed {
            self.scope.clear();
            self.scope.subscribed = true;
        }
        Ok(())
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "envelope" {
            self.scope.subscribed = false;
        }
    }

    /// `u32 count`, `f32 record_seconds`, then `count` records of `in_peak_db, wet_peak_db`
    /// (little-endian, floor -120 dB).
    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        let scope = &mut self.scope;
        if !scope.subscribed || scope.frames_since_poll < scope.poll_interval {
            return None;
        }
        scope.frames_since_poll = 0;
        if scope.ring_len == 0 {
            return None;
        }
        let count = scope.ring_len;
        let mut bytes = Vec::with_capacity(8 + count * 8);
        bytes.extend_from_slice(&(count as u32).to_le_bytes());
        bytes.extend_from_slice(&scope.record_seconds.to_le_bytes());
        for record in &scope.ring[..count] {
            for value in record {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        scope.ring_len = 0;
        Some(("envelope".to_string(), bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::linear_svf::{LinearSvf, SvfCoefs, SvfShape};
    use crate::audio::dsp::test_util::schroeder_t60;
    use crate::audio::dsp::test_util::{
        impulse, left, peak, pink_noise, render, right, rms, sine, spectrum_db, stereo,
        tone_amplitude,
    };

    fn make(sr: f32) -> ReverbDevice {
        let mut device = ReverbDevice::new(sr);
        device.prepare(sr, 4096);
        device
    }

    fn set_real(device: &mut ReverbDevice, id: ParamId, real: f32) {
        let norm = TABLE.spec(id).unwrap().to_norm(real);
        device.set_parameter(id, norm);
    }

    /// T60 of the band around `freq`, measured from an impulse response (skip the first 200 ms
    /// so the early reflections don't set the Schroeder slope).
    fn band_t60(device: &mut ReverbDevice, sr: f32, seconds: f32, freq: f32, q: f32) -> f32 {
        let frames = (seconds * sr) as usize;
        let input = stereo(&impulse(frames));
        let out = render(device, &input, &[512]);
        let l = left(&out);
        let skip = (sr * 0.2) as usize;
        let coefs = SvfCoefs::new(SvfShape::BandPass, freq, q, 0.0, sr);
        let mut filter_a = LinearSvf::new();
        let mut filter_b = LinearSvf::new();
        let filtered: Vec<f32> = l[skip..]
            .iter()
            .map(|&x| filter_b.process(filter_a.process(x, &coefs), &coefs))
            .collect();
        schroeder_t60(&filtered, sr).expect("decays at least 25 dB")
    }

    #[test]
    fn t60_at_1khz_matches_decay_for_every_algorithm() {
        for sr in [44_100.0, 96_000.0] {
            for algorithm in 0..3 {
                let mut device = make(sr);
                set_real(&mut device, ALGORITHM, algorithm as f32);
                set_real(&mut device, MIX, 100.0);
                set_real(&mut device, DECAY, 1.5);
                // Settle the smoothing out of the way.
                render(&mut device, &vec![0.0; 4096 * 2], &[512]);
                let measured = band_t60(&mut device, sr, 5.0, 1_000.0, 2.0);
                assert!(
                    (measured - 1.5).abs() / 1.5 < 0.15,
                    "{:?} at {sr}: T60 {measured:.3} s vs 1.5",
                    Algorithm::from_index(algorithm)
                );
            }
        }
    }

    #[test]
    fn absorbent_reaches_its_shelf_gains() {
        let sr = 48_000.0;
        let mut filter = Absorbent::new();
        filter.update(250.0, 4_000.0, 3.0, -11.6, sr);
        let gain = |filter: &mut Absorbent, freq: f32| {
            let (mut in_energy, mut out_energy) = (0.0f64, 0.0f64);
            for n in 0..sr as usize {
                let x = (std::f32::consts::TAU * freq * n as f32 / sr).sin();
                let y = filter.process(x);
                if n > sr as usize / 2 {
                    in_energy += (x * x) as f64;
                    out_energy += (y * y) as f64;
                }
            }
            10.0 * (out_energy / in_energy).log10() as f32
        };
        assert!((gain(&mut filter, 60.0) - 3.0).abs() < 0.4, "low shelf");
        assert!(gain(&mut filter, 1_000.0).abs() < 0.4, "flat in the band");
        assert!(gain(&mut filter, 10_000.0) < -8.0, "high shelf at 10 kHz");
        assert!(gain(&mut filter, 20_000.0) < -10.0, "high shelf at 20 kHz");
    }

    #[test]
    fn decay_eq_moves_the_band_t60s() {
        let sr = 48_000.0;
        let mut device = make(sr);
        set_real(&mut device, MIX, 100.0);
        set_real(&mut device, DECAY, 1.5);
        render(&mut device, &vec![0.0; 4096 * 2], &[512]);
        let low = band_t60(&mut device, sr, 5.0, 60.0, 3.0);
        let high = band_t60(&mut device, sr, 4.0, 10_000.0, 3.0);
        // Defaults: Low ×1.2, High ×0.5.
        assert!(
            (low - 1.5 * 1.2).abs() / (1.5 * 1.2) < 0.2,
            "low default {low:.3}"
        );
        assert!(
            (high - 1.5 * 0.5).abs() / (1.5 * 0.5) < 0.2,
            "high default {high:.3}"
        );

        set_real(&mut device, LOW_MULT, 2.0);
        set_real(&mut device, HIGH_MULT, 0.25);
        render(&mut device, &vec![0.0; 4096 * 2], &[512]);
        let low2 = band_t60(&mut device, sr, 5.0, 60.0, 3.0);
        let high2 = band_t60(&mut device, sr, 4.0, 10_000.0, 3.0);
        assert!(
            low2 > low * 1.05,
            "Low ×2 lengthens the low tail ({low:.3} → {low2:.3})"
        );
        assert!(
            high2 < high * 0.95,
            "High ×0.25 shortens the high tail ({high:.3} → {high2:.3})"
        );
        assert!(
            (low2 - 1.5 * 2.0).abs() / (1.5 * 2.0) < 0.2,
            "Low ×2 T60 {low2:.3}"
        );
        assert!(
            (high2 - 1.5 * 0.25).abs() / (1.5 * 0.25) < 0.2,
            "High ×0.25 T60 {high2:.3}"
        );
    }

    #[test]
    fn late_tail_has_no_strong_spectral_peaks() {
        let sr = 48_000.0;
        let mut device = make(sr);
        set_real(&mut device, MIX, 100.0);
        set_real(&mut device, DECAY, 2.5);
        render(&mut device, &vec![0.0; 4096 * 2], &[512]);
        let out = render(&mut device, &stereo(&impulse(sr as usize * 4)), &[512]);
        let l = left(&out);
        let start = (sr * 0.5) as usize;
        let segment = &l[start..start + sr as usize];
        let bins = spectrum_db(segment);
        let half = bins.len() / 2;
        let window = 200usize;
        let mut worst = 0.0f32;
        for i in window..half - window {
            if bins[i] < -70.0 {
                continue;
            }
            let avg: f32 = bins[i - window..i + window].iter().sum::<f32>() / (2 * window) as f32;
            worst = worst.max(bins[i] - avg);
        }
        assert!(
            worst <= 10.0,
            "worst late-tail peak {worst:.2} dB above the envelope"
        );
    }

    #[test]
    fn mono_input_decorrelates_the_wet_channels() {
        let sr = 48_000.0;
        for algorithm in 0..3 {
            let mut device = make(sr);
            set_real(&mut device, ALGORITHM, algorithm as f32);
            set_real(&mut device, MIX, 100.0);
            set_real(&mut device, WIDTH, 100.0);
            render(&mut device, &vec![0.0; 4096 * 2], &[512]);
            let input = stereo(&pink_noise(sr as usize * 2, 0.5, 9));
            let out = render(&mut device, &input, &[512]);
            let skip = (sr * 0.3) as usize;
            let (l, r) = (left(&out), right(&out));
            let (mut dot, mut nl, mut nr) = (0.0f64, 0.0f64, 0.0f64);
            for i in skip..l.len() {
                dot += (l[i] * r[i]) as f64;
                nl += (l[i] * l[i]) as f64;
                nr += (r[i] * r[i]) as f64;
            }
            let corr = dot / (nl.sqrt() * nr.sqrt()).max(1e-12);
            assert!(
                corr < 0.3,
                "{:?}: L/R correlation {corr:.3}",
                Algorithm::from_index(algorithm)
            );
        }
    }

    #[test]
    fn freeze_holds_energy_and_stays_bounded() {
        let sr = 48_000.0;
        let mut device = make(sr);
        set_real(&mut device, MIX, 100.0);
        render(&mut device, &stereo(&impulse(sr as usize)), &[512]);
        set_real(&mut device, FREEZE, 1.0);
        render(&mut device, &vec![0.0; 4096 * 2], &[512]);
        let out = render(&mut device, &vec![0.0; sr as usize * 10 * 2], &[512]);
        let l = left(&out);
        let window = sr as usize;
        let levels: Vec<f32> = (0..10)
            .map(|w| {
                let seg = &l[w * window..(w + 1) * window];
                crate::audio::dsp::gain::gain_to_db(rms(seg))
            })
            .collect();
        let (min, max) = levels
            .iter()
            .fold((f32::INFINITY, f32::NEG_INFINITY), |(lo, hi), &x| {
                (lo.min(x), hi.max(x))
            });
        assert!(
            max - min < 1.0,
            "freeze energy drifted {:.2} dB: {levels:?}",
            max - min
        );
        assert!(peak(&l) < 4.0, "freeze peak {}", peak(&l));
    }

    #[test]
    fn never_sleeps_while_the_tail_is_loud() {
        let sr = 48_000.0;
        const BLOCK: usize = 512;
        let mut device = make(sr);
        set_real(&mut device, MIX, 100.0);
        let mut input = vec![0.0f32; BLOCK * 2];
        input[0] = 1.0;
        input[1] = 1.0;
        let mut output = vec![0.0f32; BLOCK * 2];
        let mut slept = false;
        for _ in 0..((sr as usize * 20) / BLOCK) {
            let in_activity = peak(&input) > 0.001;
            device.process_block(&input, &mut output, BLOCK);
            let out_activity = peak(&output) > 0.001;
            device.update_sleep_state(in_activity || out_activity);
            if out_activity {
                assert!(!device.is_sleeping(), "slept with a loud tail");
            }
            if device.is_sleeping() {
                slept = true;
                break;
            }
            input.fill(0.0);
        }
        assert!(slept, "never slept after the tail died");
    }

    // === Envelope stream (spec 050) ===

    /// Render `input` in `block`-frame blocks, polling after each; returns the decoded records
    /// as (count-weighted) `[in_db, wet_db]` pairs plus the header's `record_seconds`.
    fn render_polled(d: &mut ReverbDevice, input: &[f32], block: usize) -> (Vec<[f32; 2]>, f32) {
        let frames = input.len() / 2;
        let mut out = vec![0.0f32; block * 2];
        let mut records = Vec::new();
        let mut record_seconds = 0.0;
        let mut pos = 0;
        while pos < frames {
            let n = block.min(frames - pos);
            d.process_block(&input[pos * 2..(pos + n) * 2], &mut out[..n * 2], n);
            pos += n;
            while let Some((kind, bytes)) = d.poll_device_data() {
                assert_eq!(kind, "envelope");
                let count = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
                record_seconds = f32::from_le_bytes(bytes[4..8].try_into().unwrap());
                assert_eq!(bytes.len(), 8 + count * 8);
                for r in 0..count {
                    let at = 8 + r * 8;
                    records.push([
                        f32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()),
                        f32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()),
                    ]);
                }
            }
        }
        (records, record_seconds)
    }

    #[test]
    fn envelope_stream_is_silent_until_subscribed() {
        let sr = 48_000.0;
        let mut d = make(sr);
        assert!(d.subscribe_data("spectrum").is_err());
        let input = stereo(&impulse(sr as usize));
        let (records, _) = render_polled(&mut d, &input, 512);
        assert!(records.is_empty(), "collected while unsubscribed");

        d.subscribe_data("envelope").unwrap();
        let (records, _) = render_polled(&mut d, &input, 512);
        assert!(!records.is_empty());

        d.unsubscribe_data("envelope");
        assert!(d.poll_device_data().is_none());
        let (records, _) = render_polled(&mut d, &input, 512);
        assert!(records.is_empty(), "collected after unsubscribing");
    }

    #[test]
    fn envelope_blob_layout() {
        let sr = 44_100.0;
        let mut d = make(sr);
        d.subscribe_data("envelope").unwrap();
        let mut input = stereo(&vec![0.0; 8192]);
        input[0] = 0.5;
        let mut out = vec![0.0f32; 8192 * 2];
        d.process_block(&input, &mut out, 8192);
        d.process_block(&input[..1024 * 2], &mut out[..1024 * 2], 1024);
        let (kind, bytes) = d.poll_device_data().expect("a poll is due");
        assert_eq!(kind, "envelope");
        let count = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
        assert_eq!(count, (8192 + 1024) / ENVELOPE_RECORD_FRAMES);
        let seconds = f32::from_le_bytes(bytes[4..8].try_into().unwrap());
        assert!((seconds - 256.0 / sr).abs() < 1e-9);
        assert_eq!(bytes.len(), 8 + count * 8);
        // The first record holds the 0.5 impulse: -6 dB.
        let first_in = f32::from_le_bytes(bytes[8..12].try_into().unwrap());
        assert!((first_in + 6.02).abs() < 0.1, "input peak {first_in}");
    }

    #[test]
    fn envelope_records_follow_the_impulse_decay() {
        let sr = 48_000.0;
        let mut d = make(sr);
        set_real(&mut d, MIX, 100.0);
        set_real(&mut d, DECAY, 2.0);
        // A flat Decay EQ, so the broadband envelope has one slope.
        set_real(&mut d, LOW_MULT, 1.0);
        set_real(&mut d, HIGH_MULT, 1.0);
        render(&mut d, &vec![0.0; 4096 * 2], &[512]);
        d.subscribe_data("envelope").unwrap();
        let input = stereo(&impulse((sr * 6.0) as usize));
        let (records, seconds) = render_polled(&mut d, &input, 512);
        assert!(records.len() > 100);
        // Fit a line to the wet level between -50 and -100 dB, past the early reflections and
        // the diffusion build-up (the first 30 dB fall faster than the late tail).
        let points: Vec<(f32, f32)> = records
            .iter()
            .enumerate()
            .filter(|(_, r)| r[1] < -50.0 && r[1] > -100.0)
            .map(|(i, r)| (i as f32 * seconds, r[1]))
            .collect();
        assert!(points.len() > 20, "too few points: {}", points.len());
        let n = points.len() as f32;
        let (sx, sy) = points
            .iter()
            .fold((0.0, 0.0), |a, p| (a.0 + p.0, a.1 + p.1));
        let (mx, my) = (sx / n, sy / n);
        let num: f32 = points.iter().map(|p| (p.0 - mx) * (p.1 - my)).sum();
        let den: f32 = points.iter().map(|p| (p.0 - mx) * (p.0 - mx)).sum();
        let slope = num / den; // dB per second, negative
        let t60 = -60.0 / slope;
        assert!(
            (t60 - 2.0).abs() / 2.0 < 0.1,
            "envelope T60 {t60:.3} s vs 2.0"
        );
    }

    #[test]
    fn subscribed_reverb_still_sleeps() {
        let sr = 48_000.0;
        const BLOCK: usize = 512;
        let mut d = make(sr);
        set_real(&mut d, MIX, 100.0);
        set_real(&mut d, DECAY, 0.3);
        d.subscribe_data("envelope").unwrap();
        let mut input = vec![0.0f32; BLOCK * 2];
        input[0] = 1.0;
        input[1] = 1.0;
        let mut output = vec![0.0f32; BLOCK * 2];
        let mut slept = false;
        for _ in 0..((sr as usize * 20) / BLOCK) {
            let in_activity = peak(&input) > 0.001;
            d.process_block(&input, &mut output, BLOCK);
            let out_activity = peak(&output) > 0.001;
            d.update_sleep_state(in_activity || out_activity);
            d.poll_device_data();
            if d.is_sleeping() {
                slept = true;
                break;
            }
            input.fill(0.0);
        }
        assert!(slept, "a subscribed reverb never slept");
    }

    #[test]
    fn impulse_response_is_not_a_single_tone() {
        // A cheap sanity check that the wet signal is broadband (diffusion working).
        let sr = 48_000.0;
        let mut device = make(sr);
        set_real(&mut device, MIX, 100.0);
        render(&mut device, &vec![0.0; 4096 * 2], &[512]);
        let out = render(&mut device, &stereo(&impulse(sr as usize)), &[512]);
        let l = left(&out);
        let start = (sr * 0.4) as usize;
        let segment = &l[start..start + 16_384];
        let one_k = tone_amplitude(segment, 1_000.0, sr);
        let rms_all = rms(segment);
        assert!(one_k < rms_all * 0.5, "tail is dominated by one tone");
    }

    /// Largest sample-to-sample step of the left channel in `[from, to)` frames.
    fn max_step(out: &[f32], from: usize, to: usize) -> f32 {
        let l = left(out);
        (from.max(1)..to).fold(0.0f32, |m, i| m.max((l[i] - l[i - 1]).abs()))
    }

    /// Largest second difference of the left channel in `[from, to)` frames: tiny on a smooth
    /// signal whatever its level, about the size of the jump at a discontinuity.
    fn max_kink(out: &[f32], from: usize, to: usize) -> f32 {
        let l = left(out);
        (from.max(2)..to).fold(0.0f32, |m, i| {
            m.max((l[i] - 2.0 * l[i - 1] + l[i - 2]).abs())
        })
    }

    /// A reverb at full Mix and its input: a 200 Hz sine, so the wet signal is smooth and any
    /// discontinuity stands out as a step.
    fn smooth_wet(algorithm: usize, depth: f32, seconds: f32) -> (ReverbDevice, Vec<f32>) {
        let sr = 48_000.0;
        let mut d = make(sr);
        set_real(&mut d, ALGORITHM, algorithm as f32);
        set_real(&mut d, MIX, 100.0);
        set_real(&mut d, DEPTH, depth);
        render(&mut d, &vec![0.0; 8192 * 2], &[512]);
        let input = stereo(&sine(200.0, sr, (seconds * sr) as usize, 0.3));
        (d, input)
    }

    #[test]
    fn algorithm_change_crossfades_without_a_step() {
        let sr = 48_000.0;
        for (from, to) in [(0, 1), (1, 2), (2, 0)] {
            let (mut d, input) = smooth_wet(from, 0.0, 2.0);
            let half = input.len() / 2;
            let mut out = render(&mut d, &input[..half], &[512]);
            set_real(&mut d, ALGORITHM, to as f32);
            out.extend(render(&mut d, &input[half..], &[512]));
            let at = half / 2;
            let before = max_kink(&out, at - (sr * 0.3) as usize, at);
            let during = max_kink(&out, at, at + (sr * 0.1) as usize);
            assert!(
                during < before * 3.0,
                "{} → {}: kink {during} vs {before} before",
                algo_name(from),
                algo_name(to)
            );
        }
    }

    #[test]
    fn switching_back_does_not_revive_an_old_tail() {
        let sr = 48_000.0;
        let mut d = make(sr);
        set_real(&mut d, ALGORITHM, 0.0);
        set_real(&mut d, MIX, 100.0);
        set_real(&mut d, DECAY, 0.5);
        render(&mut d, &vec![0.0; 8192 * 2], &[512]);
        // Room rings, then Hall takes over mid-tail and everything dies away.
        render(
            &mut d,
            &stereo(&pink_noise(sr as usize / 4, 0.5, 2)),
            &[512],
        );
        set_real(&mut d, ALGORITHM, 1.0);
        render(&mut d, &vec![0.0; 5 * sr as usize * 2], &[512]);
        set_real(&mut d, ALGORITHM, 0.0);
        let out = render(&mut d, &vec![0.0; sr as usize * 2 / 2], &[512]);
        assert!(peak(&out) < 1e-4, "old Room tail came back: {}", peak(&out));
    }

    #[test]
    fn freeze_engages_and_releases_without_a_step() {
        let sr = 48_000.0;
        for algorithm in 0..3 {
            // Full modulation depth: the swept reads must glide to rest, not jump.
            let (mut d, input) = smooth_wet(algorithm, 100.0, 3.0);
            let third = input.len() / 3;
            let mut out = render(&mut d, &input[..third], &[512]);
            set_real(&mut d, FREEZE, 1.0);
            out.extend(render(&mut d, &input[third..2 * third], &[512]));
            set_real(&mut d, FREEZE, 0.0);
            out.extend(render(&mut d, &input[2 * third..], &[512]));
            let frames = |s: f32| (s * sr) as usize;
            let before = max_kink(&out, frames(0.6), frames(1.0));
            let on = max_kink(&out, frames(1.0), frames(1.2));
            let off = max_kink(&out, frames(2.0), frames(2.2));
            assert!(
                on < before * 3.0 && off < before * 3.0,
                "{}: kinks {on} (on), {off} (off) vs {before}",
                algo_name(algorithm)
            );
        }
    }

    #[test]
    fn mix_glides_within_a_long_block() {
        let sr = 48_000.0;
        let mut d = make(sr);
        set_real(&mut d, MIX, 0.0);
        let dc = vec![0.5f32; 8192 * 2];
        render(&mut d, &dc, &[4096]);
        set_real(&mut d, MIX, 100.0);
        let out = render(&mut d, &dc[..4096 * 2], &[4096]);
        assert!((out[0] - 0.5).abs() < 0.01, "Mix stepped: {}", out[0]);
        assert!(
            max_step(&out, 1, 4096) < 0.01,
            "Mix stepped inside the block"
        );
    }

    #[test]
    fn diffuser_keeps_the_highs() {
        // At full Diffusion the diffuser is a lossless 4-channel all-pass: an impulse keeps its
        // energy. Interpolated (fractional) lengths would low-pass it.
        let sr = 48_000.0;
        let mut diffuser = Diffuser::new();
        diffuser.prepare(sr);
        let mut energy = 0.0f64;
        for n in 0..sr as usize {
            let x = if n == 0 { 1.0 } else { 0.0 };
            let y = diffuser.process4([x, 0.0, 0.0, 0.0], 1.0);
            energy += y.iter().map(|&v| (v * v) as f64).sum::<f64>();
        }
        assert!((energy - 1.0).abs() < 1e-3, "diffuser energy {energy}");
    }

    /// Largest normalised autocorrelation of `x` at lags in `[min_lag, max_lag)`.
    fn max_autocorrelation(x: &[f32], min_lag: usize, max_lag: usize) -> f32 {
        use realfft::num_complex::Complex;
        use realfft::RealFftPlanner;
        let n = (x.len() * 2).next_power_of_two();
        let mut planner = RealFftPlanner::<f32>::new();
        let forward = planner.plan_fft_forward(n);
        let inverse = planner.plan_fft_inverse(n);
        let mut buf = vec![0.0f32; n];
        buf[..x.len()].copy_from_slice(x);
        let mut spectrum = forward.make_output_vec();
        forward.process(&mut buf, &mut spectrum).unwrap();
        for c in spectrum.iter_mut() {
            *c = Complex::new(c.norm_sqr(), 0.0);
        }
        let mut ac = inverse.make_output_vec();
        inverse.process(&mut spectrum, &mut ac).unwrap();
        (min_lag..max_lag).fold(0.0f32, |m, lag| m.max(ac[lag] / ac[0]))
    }

    /// Largest autocorrelation of the late impulse response at lags of 5 to 800 ms, flattened to
    /// a constant level and whitened.
    fn tail_self_similarity(algorithm: usize, depth: f32) -> f32 {
        let sr = 48_000.0;
        let mut d = make(sr);
        set_real(&mut d, ALGORITHM, algorithm as f32);
        set_real(&mut d, MIX, 100.0);
        set_real(&mut d, EARLY, 0.0);
        set_real(&mut d, DEPTH, depth);
        set_real(&mut d, DECAY, 4.0);
        set_real(&mut d, LOW_MULT, 1.0);
        set_real(&mut d, HIGH_MULT, 1.0);
        render(&mut d, &vec![0.0; 8192 * 2], &[512]);
        let l = left(&render(&mut d, &stereo(&impulse(2 * sr as usize)), &[512]));
        // The first difference whitens what is left of the tone filters' tilt.
        let diff: Vec<f32> = l.windows(2).map(|w| w[1] - w[0]).collect();
        let tail = &diff[(sr * 0.3) as usize..(sr * 1.8) as usize];
        let window = (sr * 0.01) as usize;
        let flat: Vec<f32> = tail
            .chunks(window)
            .flat_map(|c| {
                let level = rms(c).max(1e-12);
                c.iter().map(move |&x| x / level)
            })
            .collect();
        max_autocorrelation(&flat, (sr * 0.005) as usize, (sr * 0.8) as usize)
    }

    #[test]
    fn late_tail_does_not_repeat() {
        // A loop of plain delays replays the same diffused burst every round trip; all-passes
        // inside the loop make every pass different. The plate is checked without modulation
        // (the old two-delay tank scored 0.76 here). Unmodulated, the FDN still echoes itself once
        // per total line length (Room about 0.6 at 240 ms), which the default modulation breaks.
        let plate = tail_self_similarity(2, 0.0);
        assert!(plate < 0.3, "unmodulated Plate repeats: {plate:.3}");
        for algorithm in 0..3 {
            let worst = tail_self_similarity(algorithm, 30.0);
            assert!(
                worst < 0.3,
                "{}: tail repeats, autocorrelation {worst:.3}",
                algo_name(algorithm)
            );
        }
    }

    #[test]
    fn flat_decay_eq_keeps_long_bright_tails() {
        // High Mult ×1 means the highs decay like the mids; the interpolation in the loop must
        // not add damping of its own.
        let sr = 48_000.0;
        for algorithm in 0..3 {
            let mut device = make(sr);
            set_real(&mut device, ALGORITHM, algorithm as f32);
            set_real(&mut device, MIX, 100.0);
            set_real(&mut device, DECAY, 5.0);
            set_real(&mut device, HIGH_MULT, 1.0);
            set_real(&mut device, HIGH_CUT, 20_000.0);
            set_real(&mut device, DEPTH, 100.0);
            render(&mut device, &vec![0.0; 4096 * 2], &[512]);
            let high = band_t60(&mut device, sr, 8.0, 8_000.0, 3.0);
            assert!(
                (high - 5.0).abs() / 5.0 < 0.2,
                "{}: 8 kHz T60 {high:.2} s vs 5",
                algo_name(algorithm)
            );
        }
    }

    #[test]
    fn reenabling_starts_without_the_old_tail() {
        let sr = 48_000.0;
        let mut d = make(sr);
        set_real(&mut d, MIX, 100.0);
        set_real(&mut d, EARLY, 100.0);
        render(
            &mut d,
            &stereo(&pink_noise(sr as usize / 2, 0.5, 8)),
            &[512],
        );
        d.set_enabled(false);
        render(&mut d, &vec![0.0; 512 * 2], &[512]);
        d.set_enabled(true);
        let out = render(&mut d, &vec![0.0; sr as usize * 2 / 2], &[512]);
        assert!(peak(&out) < 1e-6, "old tail resumed: {}", peak(&out));
    }

    // === Spec 040: Tank FX and Wet FX ===

    use crate::audio::devices::effects::DelayDevice;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// A gain stage that counts its `process_block` calls and can claim async blocks.
    struct Gain {
        gain: f32,
        calls: Arc<AtomicUsize>,
        enabled: bool,
        async_blocks: bool,
    }

    impl Gain {
        fn boxed(gain: f32) -> (Box<dyn AudioDevice>, Arc<AtomicUsize>) {
            let calls = Arc::new(AtomicUsize::new(0));
            let g = Gain {
                gain,
                calls: calls.clone(),
                enabled: true,
                async_blocks: false,
            };
            (Box::new(g), calls)
        }
    }

    impl AudioDevice for Gain {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], n: usize) {
            self.calls.fetch_add(1, Ordering::Relaxed);
            for i in 0..n * 2 {
                outputs[i] = inputs[i] * self.gain;
            }
        }
        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.gain"
        }
        fn device_name(&self) -> &str {
            "Gain"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Effect
        }
        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }
        fn has_async_blocks(&self) -> bool {
            self.async_blocks
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
        fn is_enabled(&self) -> bool {
            self.enabled
        }
        fn set_enabled(&mut self, enabled: bool) {
            self.enabled = enabled;
        }
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    const TANK: usize = 0;
    const WET: usize = 1;

    fn put(d: &mut ReverbDevice, slot: usize, device: Box<dyn AudioDevice>) {
        d.slots.children_mut(slot).unwrap().push(device);
    }

    fn algo_name(algorithm: usize) -> &'static str {
        ALGORITHMS[algorithm]
    }

    /// A busy reverb: modulation and ducking on, so every path is exercised.
    fn busy(algorithm: usize) -> ReverbDevice {
        let mut d = make(48_000.0);
        set_real(&mut d, ALGORITHM, algorithm as f32);
        set_real(&mut d, MIX, 60.0);
        set_real(&mut d, DECAY, 3.0);
        set_real(&mut d, DEPTH, 60.0);
        set_real(&mut d, DUCKING, 30.0);
        // Let the smoothers and the algorithm crossfade finish, so block size can't matter.
        render(&mut d, &vec![0.0; 8192 * 2], &[512]);
        d
    }

    fn noise_burst(frames: usize) -> Vec<f32> {
        let mut x = pink_noise(frames, 0.3, 17);
        for v in x.iter_mut().skip(frames / 4) {
            *v = 0.0;
        }
        stereo(&x)
    }

    #[test]
    fn reverb_has_a_loop_slot_and_an_audio_slot() {
        let mut d = ReverbDevice::new(48_000.0);
        let specs = d.device_slots();
        assert_eq!(specs.len(), 2);
        assert_eq!((specs[0].key, specs[0].kind), ("tank_fx", SlotKind::Loop));
        assert_eq!((specs[1].key, specs[1].kind), ("wet_fx", SlotKind::Audio));
        assert!(d.is_container());
        assert_eq!(d.as_container().unwrap().child_count(), 2);
        d.as_container_mut()
            .unwrap()
            .insert_child(0, Gain::boxed(1.0).0);
        assert_eq!(d.as_container().unwrap().child_count(), 2);
    }

    #[test]
    fn empty_slots_are_sample_identical() {
        // Slots holding only bypassed devices stay on the plain path, the code that ran before
        // the slots existed.
        for algorithm in 0..3 {
            let input = noise_burst(30_000);
            let mut plain = busy(algorithm);
            let mut slotted = busy(algorithm);
            let (mut a, calls_a) = Gain::boxed(0.1);
            let (mut b, calls_b) = Gain::boxed(0.1);
            a.set_enabled(false);
            b.set_enabled(false);
            put(&mut slotted, TANK, a);
            put(&mut slotted, WET, b);
            let x = render(&mut plain, &input, &[512, 100, 64, 3]);
            let y = render(&mut slotted, &input, &[512, 100, 64, 3]);
            assert_eq!(x, y, "{}", algo_name(algorithm));
            assert_eq!(calls_a.load(Ordering::Relaxed), 0);
            assert_eq!(calls_b.load(Ordering::Relaxed), 0);
        }
    }

    fn window_rms(signal: &[f32], sr: f32, from: f32, to: f32) -> f32 {
        rms(&signal[(from * sr) as usize..(to * sr) as usize])
    }

    #[test]
    fn tank_fx_shortens_tail_per_algorithm() {
        let sr = 48_000.0;
        for algorithm in 0..3 {
            let input = stereo(&impulse(4 * sr as usize));
            let run = |gain: Option<f32>| {
                let mut d = make(sr);
                set_real(&mut d, ALGORITHM, algorithm as f32);
                set_real(&mut d, MIX, 100.0);
                set_real(&mut d, DECAY, 3.0);
                render(&mut d, &vec![0.0; 8192 * 2], &[512]);
                if let Some(g) = gain {
                    put(&mut d, TANK, Gain::boxed(g).0);
                }
                left(&render(&mut d, &input, &[512]))
            };
            let plain = run(None);
            let slotted = run(Some(0.5));
            let before = window_rms(&plain, sr, 1.0, 1.5);
            let after = window_rms(&slotted, sr, 1.0, 1.5);
            assert!(before > 1e-5, "{}: no tail", algo_name(algorithm));
            assert!(
                after < before * 0.5,
                "{}: tail {after} vs {before}",
                algo_name(algorithm)
            );
        }
    }

    #[test]
    fn unity_tank_fx_matches_empty() {
        for algorithm in 0..3 {
            let input = noise_burst(40_000);
            let mut plain = busy(algorithm);
            let mut slotted = busy(algorithm);
            let (fx, calls) = Gain::boxed(1.0);
            put(&mut slotted, TANK, fx);
            let x = render(&mut plain, &input, &[512, 100, 64, 3]);
            let y = render(&mut slotted, &input, &[512, 100, 64, 3]);
            assert!(calls.load(Ordering::Relaxed) > 0);
            let diff = x
                .iter()
                .zip(&y)
                .fold(0.0f32, |m, (a, b)| m.max((a - b).abs()));
            assert!(
                diff < 1e-3 * peak(&x).max(1e-3),
                "{}: unity Tank FX differs by {diff} (peak {})",
                algo_name(algorithm),
                peak(&x)
            );
        }
    }

    #[test]
    fn tank_fx_runs_while_frozen() {
        let sr = 48_000.0;
        for algorithm in 0..3 {
            let input = stereo(&pink_noise(sr as usize / 4, 0.3, 3));
            let run = |gain: Option<f32>| {
                let mut d = make(sr);
                set_real(&mut d, ALGORITHM, algorithm as f32);
                set_real(&mut d, MIX, 100.0);
                if let Some(g) = gain {
                    put(&mut d, TANK, Gain::boxed(g).0);
                }
                render(&mut d, &input, &[512]);
                set_real(&mut d, FREEZE, 1.0);
                left(&render(&mut d, &vec![0.0; 3 * sr as usize * 2], &[512]))
            };
            let plain = run(None);
            let slotted = run(Some(0.8));
            let held = window_rms(&plain, sr, 2.0, 2.5) / window_rms(&plain, sr, 0.2, 0.7);
            let fading = window_rms(&slotted, sr, 2.0, 2.5) / window_rms(&slotted, sr, 0.2, 0.7);
            assert!(held > 0.7, "{}: frozen plain {held}", algo_name(algorithm));
            assert!(
                fading < held * 0.5,
                "{}: frozen tank {fading} vs {held}",
                algo_name(algorithm)
            );
        }
    }

    #[test]
    fn tank_fx_does_not_depend_on_block_size() {
        for algorithm in 0..3 {
            let input = noise_burst(30_000);
            let mut a = busy(algorithm);
            let mut b = busy(algorithm);
            put(&mut a, TANK, Gain::boxed(0.9).0);
            put(&mut b, TANK, Gain::boxed(0.9).0);
            let x = render(&mut a, &input, &[512]);
            let y = render(&mut b, &input, &[37, 64, 200, 1]);
            let diff = x
                .iter()
                .zip(&y)
                .fold(0.0f32, |m, (a, b)| m.max((a - b).abs()));
            assert!(
                diff < 1e-3 * peak(&x).max(1e-3),
                "{}: {diff}",
                algo_name(algorithm)
            );
        }
    }

    #[test]
    fn wet_fx_never_touches_dry() {
        let sr = 48_000.0;
        let input = stereo(&pink_noise(20_000, 0.3, 9));
        let mut plain = make(sr);
        let mut silenced = make(sr);
        let mut doubled = make(sr);
        for d in [&mut plain, &mut silenced, &mut doubled] {
            set_real(d, MIX, 50.0);
            render(d, &vec![0.0; 8192 * 2], &[512]);
        }
        put(&mut silenced, WET, Gain::boxed(0.0).0);
        put(&mut doubled, WET, Gain::boxed(2.0).0);
        let (dry, _) = dry_wet_gains(0.5, MixLaw::EqualPower);
        let p = render(&mut plain, &input, &[512]);
        let s = render(&mut silenced, &input, &[512]);
        let t = render(&mut doubled, &input, &[512]);
        for i in 0..input.len() {
            let dry_part = input[i] * dry;
            assert!(
                (s[i] - dry_part).abs() < 1e-6,
                "silenced wet leaves the dry at {i}"
            );
            let wet_plain = p[i] - dry_part;
            assert!(
                (t[i] - dry_part - 2.0 * wet_plain).abs() < 1e-5,
                "doubled wet at {i}"
            );
        }
    }

    #[test]
    fn bypassed_reverb_skips_slots() {
        let mut d = make(48_000.0);
        let (a, calls_a) = Gain::boxed(0.0);
        let (b, calls_b) = Gain::boxed(0.0);
        put(&mut d, TANK, a);
        put(&mut d, WET, b);
        d.set_enabled(false);
        let input = stereo(&pink_noise(2000, 0.5, 5));
        let out = render(&mut d, &input, &[512]);
        assert_eq!(out, input);
        assert_eq!(calls_a.load(Ordering::Relaxed), 0);
        assert_eq!(calls_b.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn sleep_waits_for_wet_fx_tail() {
        let sr = 48_000.0;
        const BLOCK: usize = 512;
        let sleep_time = |with_delay: bool| {
            let mut d = make(sr);
            set_real(&mut d, MIX, 100.0);
            set_real(&mut d, DECAY, 0.3);
            if with_delay {
                let mut delay = DelayDevice::new(sr, 5000.0);
                delay.prepare(sr, BLOCK);
                use super::super::delay as dl;
                // Normalised: Mix 100 %, Time 1000 ms (log 1..5000), Sync Off, Feedback 50 %.
                delay.set_parameter(dl::MIX, 1.0);
                delay.set_parameter(dl::TIME_L, (1000.0f32).ln() / (5000.0f32).ln());
                delay.set_parameter(dl::SYNC_L, 0.0);
                delay.set_parameter(dl::FEEDBACK, 50.0 / 110.0);
                put(&mut d, WET, Box::new(delay));
            }
            let mut input = vec![0.0f32; BLOCK * 2];
            input[0] = 1.0;
            input[1] = 1.0;
            let mut output = vec![0.0f32; BLOCK * 2];
            for block in 0..((sr as usize * 40) / BLOCK) {
                let in_activity = peak(&input) > 0.001;
                d.process_block(&input, &mut output, BLOCK);
                let out_activity = peak(&output) > 0.001;
                d.update_sleep_state(in_activity || out_activity);
                if out_activity {
                    assert!(!d.is_sleeping(), "slept with a loud tail");
                }
                if d.is_sleeping() {
                    return Some(block * BLOCK);
                }
                input.fill(0.0);
            }
            None
        };
        let plain = sleep_time(false).expect("plain reverb sleeps");
        let with_fx = sleep_time(true).expect("reverb with Wet FX sleeps once the repeats die");
        assert!(
            with_fx > plain + sr as usize * 3,
            "Wet FX tail ignored: slept at {with_fx} vs {plain}"
        );
    }

    #[test]
    fn whole_block_path_matches_process_block() {
        let sr = 48_000.0;
        let input = stereo(&pink_noise(4096, 0.3, 21));
        let build = || {
            let mut d = busy(1);
            let calls;
            let mut fx = Gain {
                gain: 0.5,
                calls: Arc::new(AtomicUsize::new(0)),
                enabled: true,
                async_blocks: true,
            };
            calls = fx.calls.clone();
            fx.gain = 0.5;
            put(&mut d, WET, Box::new(fx));
            (d, calls)
        };
        let (mut a, _) = build();
        let (mut b, calls) = build();
        assert!(b.has_async_blocks());
        let x = render(&mut a, &input, &[512]);
        let mut y = vec![0.0f32; input.len()];
        for start in (0..input.len() / 2).step_by(512) {
            let (i, o) = (
                &input[start * 2..(start + 512) * 2],
                &mut y[start * 2..(start + 512) * 2],
            );
            assert!(b.begin_block(i, 512));
            b.finish_block(i, o, 512);
        }
        assert_eq!(x, y);
        assert!(calls.load(Ordering::Relaxed) > 0);
        let _ = sr;
        // Without a plugin in Wet FX the wrapper still splits blocks.
        let plain = busy(1);
        assert!(!plain.has_async_blocks());
    }

    /// A Wet FX device with latency delays the dry to match: at any Mix the output is the
    /// zero-latency Wet FX reverb's, `DELAY` frames late. Bypassed, the input comes out late too.
    #[test]
    fn wet_fx_latency_keeps_dry_and_wet_aligned() {
        use crate::audio::mixing::test_support::LatencyDevice;
        const DELAY: usize = 700;
        let input = noise_burst(16_384);
        let build = |delay: usize, mix: f32| {
            let mut d = busy(0);
            put(&mut d, WET, Box::new(LatencyDevice::new(delay, 1.0)));
            set_real(&mut d, MIX, mix);
            assert_eq!(d.update_latency(48_000.0), delay as u32);
            render(&mut d, &vec![0.0; 8192 * 2], &[512]);
            d
        };
        let late = |x: &[f32]| -> Vec<f32> {
            let mut out = vec![0.0; DELAY * 2];
            out.extend_from_slice(&x[..x.len() - DELAY * 2]);
            out
        };
        for mix in [0.0, 40.0, 100.0] {
            let expected = late(&render(&mut build(0, mix), &input, &[512]));
            let actual = render(&mut build(DELAY, mix), &input, &[512]);
            for (i, (a, e)) in actual.iter().zip(&expected).enumerate() {
                assert!((a - e).abs() < 1e-5, "mix {mix}: sample {i}: {a} vs {e}");
            }
        }

        let mut bypassed = build(DELAY, 40.0);
        bypassed.set_enabled(false);
        assert_eq!(render(&mut bypassed, &input, &[512]), late(&input));
    }
}

#[cfg(test)]
mod bench {
    use super::*;

    /// Stereo reverb on a real room: the full algorithm at the default Decay.
    /// `cargo test --release cpu_reverb -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn cpu_reverb() {
        const SR: f32 = 48_000.0;
        const FRAMES: usize = 256;
        let mut device = ReverbDevice::new(SR);
        device.prepare(SR, FRAMES);
        let mut input = vec![0.0f32; FRAMES * 2];
        let mut output = vec![0.0f32; FRAMES * 2];
        let blocks = (SR as usize * 10) / FRAMES; // 10 s of audio
        let start = std::time::Instant::now();
        for b in 0..blocks {
            for (i, x) in input.iter_mut().enumerate() {
                *x = if (b + i) % 3 == 0 { 0.1 } else { -0.1 };
            }
            device.process_block(&input, &mut output, FRAMES);
        }
        let elapsed = start.elapsed().as_secs_f64();
        println!(
            "10 s rendered in {:.3} s: {:.2} % of one core",
            elapsed,
            elapsed / 10.0 * 100.0
        );
    }
}
