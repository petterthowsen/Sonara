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
//! - **Plate**: the Dattorro topology — four input all-passes into two cross-coupled tanks — with
//!   the same Decay EQ, modulation and Pre-Delay interface.
//!
//! Size glides every tank length with smoothed fractional reads; a few lines are modulated slowly
//! to break up metallic ringing; Freeze sets the loop gain to one with the damping and the input
//! off, bounded by a soft clip; Ducking follows the dry input.

use super::effect::{pass_through, TailSleep};
use crate::audio::devices::param_table::{
    flatten, linear, log, skewed, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::dsp::delay_line::DelayLine;
use crate::audio::dsp::env_follower::{Detection, EnvFollower};
use crate::audio::dsp::gain::{db_to_gain, dry_wet_gains, gain_to_db, MixLaw};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::modulation::lfo::{Lfo, LfoShape};

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
const PLATE_MOD_FRACTION: f32 = 0.02;

/// Output and input tap patterns. The two output patterns are orthogonal (a Hadamard pair), so a
/// mono input — which excites the all-ones mode most — still gives decorrelated L and R.
const FDN_OUT_L: [f32; 8] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0];
const FDN_OUT_R: [f32; 8] = [1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0];
const FDN_IN_A: [f32; 8] = [1.0, 0.7, -0.5, 0.6, -0.8, 0.9, 0.3, -0.6];
const FDN_IN_B: [f32; 8] = [0.4, -0.7, 0.8, -0.3, 0.6, -0.9, 0.5, 0.7];

/// Algorithm crossfade on a change, in seconds.
const ALGORITHM_CROSSFADE_S: f32 = 0.030;

/// Room early reflections (ms, left gain, right gain): dense and short.
const EARLY_ROOM: &[(f32, f32, f32)] = &[
    (3.2, 0.80, 0.70),
    (5.7, 0.60, 0.55),
    (8.3, 0.75, 0.50),
    (11.1, 0.50, 0.70),
    (14.7, 0.65, 0.60),
    (18.3, 0.45, 0.55),
    (23.1, 0.50, 0.40),
    (28.7, 0.35, 0.45),
    (34.1, 0.40, 0.30),
    (41.3, 0.30, 0.35),
];
/// Hall early reflections: sparse and wide.
const EARLY_HALL: &[(f32, f32, f32)] = &[
    (17.3, 0.60, 0.35),
    (23.7, 0.45, 0.55),
    (31.1, 0.55, 0.30),
    (41.7, 0.40, 0.50),
    (53.3, 0.50, 0.35),
    (67.7, 0.35, 0.45),
    (83.1, 0.40, 0.30),
];
/// Plate early reflections.
const EARLY_PLATE: &[(f32, f32, f32)] = &[
    (11.3, 0.50, 0.40),
    (19.7, 0.40, 0.50),
    (29.3, 0.45, 0.35),
    (43.1, 0.35, 0.45),
    (61.7, 0.30, 0.35),
];

/// Four diffuser stages, four mutually prime lengths (ms) each.
const DIFFUSER_MS: [[f32; 4]; 4] = [
    [1.3, 1.7, 2.1, 2.7],
    [3.1, 3.7, 4.3, 5.1],
    [5.7, 6.7, 7.9, 9.1],
    [10.3, 11.7, 13.3, 15.1],
];

/// Dattorro input-diffusion all-pass lengths in samples at the paper's 29761 Hz, with gains.
/// The last two are the tank all-passes, folded into the input path so the decay loop is a clean
/// two-delay cross-coupling.
const PLATE_IN_AP: [(f32, f32); 6] = [
    (142.0, 0.75),
    (107.0, 0.75),
    (379.0, 0.625),
    (277.0, 0.625),
    (672.0, 0.7),
    (908.0, 0.7),
];
/// The two Dattorro tank delay lengths (samples at 29761 Hz) that set the plate's decay.
const PLATE_TANK: [f32; 2] = [4453.0, 4217.0];
const PLATE_REF_RATE: f32 = 29_761.0;

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

/// Advance a block-rate smoother by a whole block of samples.
#[inline]
fn advance(p: &mut SmoothedParam, frames: usize) {
    for _ in 0..frames {
        p.next();
    }
}

/// One Schroeder all-pass: `y = d − g·x`, fed back with `x + g·y`.
#[inline]
fn allpass(line: &mut DelayLine, x: f32, delay: f32, g: f32) -> f32 {
    let d = line.read_linear(delay);
    let y = d - g * x;
    line.push(x + g * y);
    y
}

/// Jot-style absorbent filter: a second-order low shelf and high shelf, flat in the mid band, so
/// the band decay rates can be set independently without leaking into the 1 kHz tail. `low_db`
/// is the low-frequency gain relative to the mid band, `high_db` the high-frequency one. Two
/// cascaded first-order sections reach the shelf asymptote fast enough for the band T60 to match.
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

// === Diffuser ===

/// Four stages of four all-pass delays with a Hadamard mix and a Diffusion crossfade between the
/// plain tap and the mixed tap.
struct Diffuser {
    lines: [[DelayLine; 4]; 4],
    len: [[f32; 4]; 4],
}

impl Diffuser {
    fn new() -> Self {
        Self {
            lines: std::array::from_fn(|_| std::array::from_fn(|_| DelayLine::new())),
            len: [[0.0; 4]; 4],
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        for (stage, lengths) in DIFFUSER_MS.iter().enumerate() {
            for (i, &ms) in lengths.iter().enumerate() {
                self.len[stage][i] = ms * 0.001 * sample_rate;
                self.lines[stage][i].prepare_seconds(ms * 0.001 * 2.0, sample_rate);
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

    #[inline]
    fn process(&mut self, l: f32, r: f32, diffusion: f32) -> (f32, f32) {
        let mut x = [l, r, l, -r];
        let g = diffusion * 0.7;
        for stage in 0..4 {
            let mut d = [0.0f32; 4];
            for i in 0..4 {
                d[i] = self.lines[stage][i].read_linear(self.len[stage][i]);
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
        (x[0], x[1])
    }
}

// === FDN (Room / Hall) ===

/// Eight-line feedback delay network with a Householder feedback matrix and per-line absorbent
/// low/high shelves.
struct Fdn {
    lines: [DelayLine; 8],
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
            absorb: [Absorbent::new(); 8],
            gain: [0.0; 8],
            base_ms,
            inject,
            out_scale,
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        let scale = SIZE_MAX_SCALE / SIZE_MIN_SCALE;
        for (i, line) in self.lines.iter_mut().enumerate() {
            line.prepare_seconds(self.base_ms[i] * 0.001 * scale, sample_rate);
        }
    }

    fn reset(&mut self) {
        for line in self.lines.iter_mut() {
            line.clear();
        }
        for a in self.absorb.iter_mut() {
            a.reset();
        }
    }

    /// Recompute the absorbent filters and loop gains for the current Decay / band settings.
    fn update_coefs(
        &mut self,
        sample_rate: f32,
        size_scale: f32,
        frozen: bool,
        decay: f32,
        low: (f32, f32),
        high: (f32, f32),
    ) {
        for i in 0..8 {
            let len_s = self.base_ms[i] * 0.001 * size_scale;
            let (gain, low_db, high_db) = if frozen {
                (1.0, 0.0, 0.0)
            } else {
                (
                    feedback_gain(len_s, decay),
                    shelf_db(len_s, decay, low.0),
                    shelf_db(len_s, decay, high.0),
                )
            };
            self.gain[i] = gain;
            self.absorb[i].update(low.1, high.1, low_db, high_db, sample_rate);
        }
    }

    #[inline]
    fn process(
        &mut self,
        dl: f32,
        dr: f32,
        size_scale: f32,
        mods: &[f32; 8],
        mod_depth: f32,
        frozen: bool,
        sample_rate: f32,
    ) -> (f32, f32) {
        let mut d = [0.0f32; 8];
        for i in 0..8 {
            let base = self.base_ms[i] * 0.001 * sample_rate * size_scale;
            let delay = if frozen {
                base.round().max(2.0)
            } else {
                (base * (1.0 + FDN_MOD_FRACTION * mod_depth * mods[i])).max(2.0)
            };
            d[i] = self.lines[i].read_hermite(delay);
        }
        let mut y = [0.0f32; 8];
        for i in 0..8 {
            y[i] = self.absorb[i].process(d[i]) * self.gain[i];
        }
        // Householder: (I − 2/N · 1) y = y − 2·mean(y).
        let mean = y.iter().sum::<f32>() * (2.0 / 8.0);
        for i in 0..8 {
            let injection = if frozen {
                0.0
            } else {
                (dl * FDN_IN_A[i] + dr * FDN_IN_B[i]) * self.inject
            };
            self.lines[i].push(soft_clip(y[i] - mean + injection));
        }
        let mut ol = 0.0;
        let mut or = 0.0;
        for i in 0..8 {
            ol += y[i] * FDN_OUT_L[i];
            or += y[i] * FDN_OUT_R[i];
        }
        (ol * self.out_scale, or * self.out_scale)
    }
}

// === Plate ===

/// One plate tank: a modulated delay with damping and decay, cross-coupled with the other tank.
struct PlateTank {
    line: DelayLine,
    absorb: Absorbent,
    gain: f32,
    /// Nominal delay in seconds at Size 50 %.
    len_seconds: f32,
    /// The previous output, cross-coupled into the other tank.
    last: f32,
}

impl PlateTank {
    fn new(len_seconds: f32) -> Self {
        Self {
            line: DelayLine::new(),
            absorb: Absorbent::new(),
            gain: 0.0,
            len_seconds,
            last: 0.0,
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        self.line
            .prepare_seconds(self.len_seconds * SIZE_MAX_SCALE, sample_rate);
    }

    fn reset(&mut self) {
        self.line.clear();
        self.absorb.reset();
        self.last = 0.0;
    }

    #[inline]
    fn process(
        &mut self,
        inx: f32,
        size_scale: f32,
        mod_val: f32,
        mod_depth: f32,
        frozen: bool,
        sample_rate: f32,
    ) -> (f32, f32) {
        let base = self.len_seconds * size_scale * sample_rate;
        let delay = if frozen {
            base.round().max(2.0)
        } else {
            (base * (1.0 + PLATE_MOD_FRACTION * mod_depth * mod_val)).max(2.0)
        };
        let out = self.line.read_hermite(delay);
        let decayed = self.absorb.process(out) * self.gain;
        // Only the coupled signal (the other tank's decayed output plus the input) is stored; the
        // tank's own decayed output travels through the cross-coupling, so the loop is a clean
        // orthogonal two-delay network.
        let stored = if frozen { decayed } else { inx };
        self.line.push(soft_clip(stored));
        (out, decayed)
    }
}

/// Dattorro-derived plate: the input diffusion all-passes feed two cross-coupled tanks, each a
/// modulated delay with an absorbent filter and a decay gain.
struct Plate {
    in_ap: [DelayLine; 6],
    in_len: [f32; 6],
    in_g: [f32; 6],
    tanks: [PlateTank; 2],
    out_scale: f32,
}

impl Plate {
    fn new(sample_rate: f32) -> Self {
        let ratio = sample_rate / PLATE_REF_RATE;
        Self {
            in_ap: std::array::from_fn(|_| DelayLine::new()),
            in_len: std::array::from_fn(|i| PLATE_IN_AP[i].0 * ratio),
            in_g: std::array::from_fn(|i| PLATE_IN_AP[i].1),
            tanks: [
                PlateTank::new(PLATE_TANK[0] / PLATE_REF_RATE),
                PlateTank::new(PLATE_TANK[1] / PLATE_REF_RATE),
            ],
            out_scale: 0.6,
        }
    }

    fn prepare(&mut self, sample_rate: f32) {
        for i in 0..self.in_ap.len() {
            self.in_ap[i].prepare_seconds((self.in_len[i] / PLATE_REF_RATE) * 2.0, sample_rate);
        }
        for tank in self.tanks.iter_mut() {
            tank.prepare(sample_rate);
        }
    }

    fn reset(&mut self) {
        for line in self.in_ap.iter_mut() {
            line.clear();
        }
        for tank in self.tanks.iter_mut() {
            tank.reset();
        }
    }

    fn update_coefs(
        &mut self,
        sample_rate: f32,
        size_scale: f32,
        frozen: bool,
        decay: f32,
        low: (f32, f32),
        high: (f32, f32),
    ) {
        // A signal crosses both tanks in one loop; each tank applies the square root of the
        // round-trip gain, so the shelf dB halves too.
        let total_loop =
            (self.tanks[0].len_seconds + self.tanks[1].len_seconds) * size_scale.max(0.01);
        let (product, low_db, high_db) = if frozen {
            (1.0, 0.0, 0.0)
        } else {
            (
                feedback_gain(total_loop, decay),
                shelf_db(total_loop, decay, low.0) * 0.5,
                shelf_db(total_loop, decay, high.0) * 0.5,
            )
        };
        for tank in self.tanks.iter_mut() {
            tank.gain = product.sqrt();
            tank.absorb
                .update(low.1, high.1, low_db, high_db, sample_rate);
        }
    }

    #[inline]
    fn process(
        &mut self,
        dl: f32,
        dr: f32,
        size_scale: f32,
        mod_val: f32,
        mod_depth: f32,
        frozen: bool,
        sample_rate: f32,
    ) -> (f32, f32) {
        let x = (dl + dr) * 0.5;
        let mut v = x;
        for i in 0..self.in_ap.len() {
            v = allpass(&mut self.in_ap[i], v, self.in_len[i].max(2.0), self.in_g[i]);
        }
        let (y0, d0) = self.tanks[0].process(
            v + self.tanks[1].last,
            size_scale,
            mod_val,
            mod_depth,
            frozen,
            sample_rate,
        );
        let (y1, d1) = self.tanks[1].process(
            v + self.tanks[0].last,
            size_scale,
            -mod_val,
            mod_depth,
            frozen,
            sample_rate,
        );
        self.tanks[0].last = d0;
        self.tanks[1].last = d1;
        let out_l = (y0 * 0.7 + y1 * 0.4) * self.out_scale;
        let out_r = (y1 * 0.7 + y0 * 0.4) * self.out_scale;
        (out_l, out_r)
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

pub struct ReverbDevice {
    sample_rate: f32,
    params: ParamValues<PARAM_COUNT>,
    settings: Settings,

    predelay_l: DelayLine,
    predelay_r: DelayLine,
    early_l: DelayLine,
    early_r: DelayLine,
    decor_r: DelayLine,
    early_taps: &'static [(f32, f32, f32)],

    diffuser: Diffuser,
    fdn: [Fdn; 2],
    plate: Plate,

    lfo: Lfo,
    duck: EnvFollower,
    tone_low: [OnePole; 2],
    tone_high: [OnePole; 2],
    tone_low_g: f32,
    tone_high_g: f32,

    algorithm: Algorithm,
    prev_algorithm: Option<Algorithm>,
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
    width_s: SmoothedParam,
    mix_s: SmoothedParam,

    sleep: TailSleep,
    is_active: bool,
    is_enabled: bool,
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
        let mut device = Self {
            sample_rate: sr,
            params,
            settings,
            predelay_l: DelayLine::new(),
            predelay_r: DelayLine::new(),
            early_l: DelayLine::new(),
            early_r: DelayLine::new(),
            decor_r: DelayLine::new(),
            early_taps: early_taps(algorithm),
            diffuser: Diffuser::new(),
            fdn: [
                Fdn::new(FDN_ROOM_MS, 0.35, 0.35),
                Fdn::new(FDN_HALL_MS, 0.35, 0.35),
            ],
            plate: Plate::new(sr),
            lfo: Lfo::default(),
            duck: EnvFollower::new(5.0, 200.0, sr, Detection::Peak),
            tone_low: [OnePole::new(); 2],
            tone_high: [OnePole::new(); 2],
            tone_low_g: 0.0,
            tone_high_g: 0.0,
            algorithm,
            prev_algorithm: None,
            xfade: 0,
            xfade_frames: (ALGORITHM_CROSSFADE_S * sr) as usize,
            size_s: SmoothedParam::new(settings.size, sr, 120.0),
            predelay_s: SmoothedParam::new(settings.predelay_ms, sr, 40.0),
            decay_s: SmoothedParam::new(settings.decay, sr, 20.0),
            low_mult_s: SmoothedParam::new(settings.low_mult, sr, 20.0),
            low_freq_s: SmoothedParam::new(settings.low_freq, sr, 20.0),
            high_mult_s: SmoothedParam::new(settings.high_mult, sr, 20.0),
            high_freq_s: SmoothedParam::new(settings.high_freq, sr, 20.0),
            diffusion_s: SmoothedParam::new(settings.diffusion, sr, 20.0),
            early_s: SmoothedParam::new(settings.early, sr, 20.0),
            rate_s: SmoothedParam::new(settings.rate_hz, sr, 20.0),
            depth_s: SmoothedParam::new(settings.mod_depth, sr, 20.0),
            low_cut_s: SmoothedParam::new(settings.low_cut, sr, 20.0),
            high_cut_s: SmoothedParam::new(settings.high_cut, sr, 20.0),
            ducking_s: SmoothedParam::new(settings.ducking, sr, 20.0),
            width_s: SmoothedParam::new(settings.width, sr, 20.0),
            mix_s: SmoothedParam::new(settings.mix, sr, 20.0),
            sleep: TailSleep::new(sr),
            is_active: true,
            is_enabled: true,
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
        // Advance the block-rate smoothers by the whole block; size and pre-delay glide per
        // sample. Advancing by frames keeps the trajectory independent of the block size.
        advance(&mut self.decay_s, frames);
        advance(&mut self.low_mult_s, frames);
        advance(&mut self.low_freq_s, frames);
        advance(&mut self.high_mult_s, frames);
        advance(&mut self.high_freq_s, frames);
        advance(&mut self.diffusion_s, frames);
        advance(&mut self.early_s, frames);
        advance(&mut self.rate_s, frames);
        advance(&mut self.depth_s, frames);
        advance(&mut self.width_s, frames);
        advance(&mut self.mix_s, frames);
        advance(&mut self.ducking_s, frames);
        advance(&mut self.low_cut_s, frames);
        advance(&mut self.high_cut_s, frames);

        let size = SIZE_MIN_SCALE + self.size_s.current() * (SIZE_MAX_SCALE - SIZE_MIN_SCALE);
        let decay = self.decay_s.current();
        let low = (self.low_mult_s.current(), self.low_freq_s.current());
        let high = (self.high_mult_s.current(), self.high_freq_s.current());
        let frozen = self.settings.freeze;

        self.fdn[0].update_coefs(self.sample_rate, size, frozen, decay, low, high);
        self.fdn[1].update_coefs(self.sample_rate, size, frozen, decay, low, high);
        self.plate
            .update_coefs(self.sample_rate, size, frozen, decay, low, high);

        self.tone_low_g = one_pole_g(self.low_cut_s.current(), self.sample_rate);
        self.tone_high_g = one_pole_g(self.high_cut_s.current(), self.sample_rate);
    }

    fn early_taps_here(&self) -> &'static [(f32, f32, f32)] {
        self.early_taps
    }

    #[inline]
    fn early(&mut self, pl: f32, pr: f32) -> (f32, f32) {
        let sr = self.sample_rate;
        let (mut el, mut er) = (0.0f32, 0.0f32);
        for &(ms, gl, gr) in self.early_taps_here() {
            let ago = ((ms * 0.001 * sr).round() as usize).max(1);
            el += gl * self.early_l.read(ago);
            er += gr * self.early_r.read(ago);
        }
        self.early_l.push(pl);
        self.early_r.push(pr);
        (el, er)
    }

    fn algorithm_wet(
        &mut self,
        algo: Algorithm,
        dl: f32,
        dr: f32,
        size_scale: f32,
        mods: &[f32; 8],
    ) -> (f32, f32) {
        let frozen = self.settings.freeze;
        let depth = self.depth_s.current();
        let sr = self.sample_rate;
        match algo {
            Algorithm::Room => self.fdn[0].process(dl, dr, size_scale, mods, depth, frozen, sr),
            Algorithm::Hall => self.fdn[1].process(dl, dr, size_scale, mods, depth, frozen, sr),
            Algorithm::Plate => self
                .plate
                .process(dl, dr, size_scale, mods[0], depth, frozen, sr),
        }
    }

    #[inline]
    fn late(&mut self, dl: f32, dr: f32, size_scale: f32, mods: &[f32; 8]) -> (f32, f32) {
        let current = self.algorithm;
        let cur = self.algorithm_wet(current, dl, dr, size_scale, mods);
        if let Some(prev) = self.prev_algorithm {
            let p = self.algorithm_wet(prev, dl, dr, size_scale, mods);
            let t = self.xfade as f32 / self.xfade_frames.max(1) as f32;
            self.xfade += 1;
            if self.xfade >= self.xfade_frames {
                self.prev_algorithm = None;
            }
            return (cur.0 + (p.0 - cur.0) * t, cur.1 + (p.1 - cur.1) * t);
        }
        cur
    }

    #[inline]
    fn process_sample(&mut self, in_l: f32, in_r: f32) -> (f32, f32) {
        // Advance per-sample smoothers exactly once, whichever algorithm runs.
        let size_scale = SIZE_MIN_SCALE + self.size_s.next() * (SIZE_MAX_SCALE - SIZE_MIN_SCALE);
        let pd = (self.predelay_s.next() * 0.001 * self.sample_rate).max(1.0);
        let mut mods = [0.0f32; 8];
        for (i, m) in mods.iter_mut().enumerate() {
            *m = self.lfo.value_at(LfoShape::Sine, i as f64 * 0.125);
        }
        self.lfo
            .advance(self.rate_s.current() as f64 / self.sample_rate as f64);

        let pl = self.predelay_l.read_hermite(pd);
        let pr = self.predelay_r.read_hermite(pd);
        self.predelay_l.push(in_l);
        self.predelay_r.push(in_r);

        let early_level = self.early_s.current();
        let (el, er) = self.early(pl, pr);

        let (dl, dr) = self.diffuser.process(pl, pr, self.diffusion_s.current());
        let (ll, lr) = self.late(dl, dr, size_scale, &mods);

        let mut wl = el * early_level + ll;
        let wr_raw = er * early_level + lr;

        // Decorrelate the wet channels: a mono input would otherwise give near-identical L and R
        // (the FDN lines are driven coherently). A few milliseconds of extra delay on R does it
        // without a filter, and Width then sets the stereo image.
        let decor = (self.sample_rate * 0.0047).max(2.0);
        let mut wr = self.decor_r.read_hermite(decor);
        self.decor_r.push(wr_raw);

        // Wet tone filters (outside the loop).
        wl = self.tone_high[0].lowpass(wl, self.tone_high_g);
        wl = self.tone_low[0].highpass(wl, self.tone_low_g);
        wr = self.tone_high[1].lowpass(wr, self.tone_high_g);
        wr = self.tone_low[1].highpass(wr, self.tone_low_g);

        // Ducking: the dry input turns the wet signal down.
        let env = self.duck.process(in_l.abs().max(in_r.abs()));
        let duck = self.ducking_s.current();
        if duck > 0.0 {
            let norm = ((gain_to_db(env) + 40.0) / 40.0).clamp(0.0, 1.0);
            let g = 1.0 - duck * norm;
            wl *= g;
            wr *= g;
        }

        // Width on the wet signal only (M/S).
        let w = self.width_s.current();
        if (w - 1.0).abs() > 1e-6 {
            let m = (wl + wr) * 0.5;
            let s = (wl - wr) * 0.5;
            wl = m + s * w;
            wr = m - s * w;
        }
        (wl, wr)
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            ALGORITHM => {
                let algo = Algorithm::from_index(real as usize);
                if algo != self.algorithm {
                    self.prev_algorithm = Some(self.algorithm);
                    self.xfade = 0;
                    self.algorithm = algo;
                    self.early_taps = early_taps(algo);
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

fn early_taps(algorithm: Algorithm) -> &'static [(f32, f32, f32)] {
    match algorithm {
        Algorithm::Room => EARLY_ROOM,
        Algorithm::Hall => EARLY_HALL,
        Algorithm::Plate => EARLY_PLATE,
    }
}

impl AudioDevice for ReverbDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_active || !self.is_enabled {
            pass_through(inputs, outputs, sample_count);
            self.sleep.on_block(sample_count);
            return;
        }
        let frames = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        self.update_block(frames);
        for f in 0..frames {
            let in_l = inputs[f * 2];
            let in_r = inputs[f * 2 + 1];
            let (wl, wr) = self.process_sample(in_l, in_r);
            let (dry, wet) = dry_wet_gains(self.mix_s.current(), MixLaw::EqualPower);
            outputs[f * 2] = in_l * dry + wl * wet;
            outputs[f * 2 + 1] = in_r * dry + wr * wet;
        }
        self.sleep.on_block(frames);
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
        self.predelay_l.clear();
        self.predelay_r.clear();
        self.early_l.clear();
        self.early_r.clear();
        self.decor_r.clear();
        self.diffuser.reset();
        for fdn in self.fdn.iter_mut() {
            fdn.reset();
        }
        self.plate.reset();
        self.duck.reset();
        for p in self.tone_low.iter_mut() {
            p.reset();
        }
        for p in self.tone_high.iter_mut() {
            p.reset();
        }
        self.lfo = Lfo::default();
        self.prev_algorithm = None;
        self.xfade = 0;
        // Snap the smoothers to their targets so a reset starts from the current settings.
        self.size_s.snap(self.settings.size);
        self.predelay_s.snap(self.settings.predelay_ms);
        self.decay_s.snap(self.settings.decay);
        self.low_mult_s.snap(self.settings.low_mult);
        self.low_freq_s.snap(self.settings.low_freq);
        self.high_mult_s.snap(self.settings.high_mult);
        self.high_freq_s.snap(self.settings.high_freq);
        self.diffusion_s.snap(self.settings.diffusion);
        self.early_s.snap(self.settings.early);
        self.rate_s.snap(self.settings.rate_hz);
        self.depth_s.snap(self.settings.mod_depth);
        self.low_cut_s.snap(self.settings.low_cut);
        self.high_cut_s.snap(self.settings.high_cut);
        self.ducking_s.snap(self.settings.ducking);
        self.width_s.snap(self.settings.width);
        self.mix_s.snap(self.settings.mix);
        self.sleep.wake();
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        self.predelay_l.prepare_seconds(0.5, sample_rate);
        self.predelay_r.prepare_seconds(0.5, sample_rate);
        self.early_l.prepare_seconds(0.25, sample_rate);
        self.early_r.prepare_seconds(0.25, sample_rate);
        self.decor_r.prepare_seconds(0.05, sample_rate);
        self.diffuser.prepare(sample_rate);
        for fdn in self.fdn.iter_mut() {
            fdn.prepare(sample_rate);
        }
        self.plate.prepare(sample_rate);
        self.duck.set_times(5.0, 200.0, sample_rate);
        self.rate_s.set_ramp(sample_rate, 20.0);
        self.size_s.set_ramp(sample_rate, 120.0);
        self.predelay_s.set_ramp(sample_rate, 40.0);
        if self.xfade_frames == 0 {
            self.xfade_frames = (ALGORITHM_CROSSFADE_S * sample_rate) as usize;
        }
        self.sleep.set_sample_rate(sample_rate);
        self.mix_s.set_ramp(sample_rate, 20.0);
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
        self.is_enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::linear_svf::{LinearSvf, SvfCoefs, SvfShape};
    use crate::audio::dsp::test_util::schroeder_t60;
    use crate::audio::dsp::test_util::{
        impulse, left, peak, pink_noise, render, right, rms, spectrum_db, stereo, tone_amplitude,
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
