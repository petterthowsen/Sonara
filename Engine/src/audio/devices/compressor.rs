//! Compressor (`sonara.builtin.compressor`, spec 012 Phase 3).
//!
//! Feed-forward, log-domain gain computer with the Giannoulis/Massberg/Reiss soft knee. Four
//! styles share the layout: Clean, Glue (RMS-leaning, program-dependent release), Punch
//! (feedback topology, fast, mild odd-harmonic saturation) and Opto (release slows the deeper
//! and longer the gain reduction has been).
//!
//! - The level detector is a peak-hold with an instant attack and a fast release (a fifteenth of
//!   the release time), so a steady tone reads its peak; the user's Attack and Release are
//!   applied to the gain reduction by a branching smoother. A branching detector on the *level*
//!   under-reads a sine by about 0.9 dB, which would fail the static-curve test below.
//! - Every continuous parameter is smoothed over ~5 ms, stepped once per [`CHUNK`] frames
//!   counted from the device's first frame (so the output doesn't depend on how the host splits
//!   blocks) and interpolated per sample. Detection, SC Listen, Auto Gain and Punch saturation
//!   are crossfaded, so switching them never clicks.
//! - Range caps the gain reduction; Auto Gain adds half the static reduction at 0 dBFS; the
//!   sidechain low cut is a 12 dB/oct high pass in the detector path only, and SC Listen
//!   replaces the output with what the detector hears.
//! - Data stream `"dynamics"`: one record per 64 frames (`in_peak_db`, `out_peak_db`, `gr_db`)
//!   into a preallocated ring, drained on polls of about 20 Hz into `u32 count` + records, then a
//!   [`SUMMARY_FLOATS`]-float [`MeterWindow`] summary for the meters (per-side peak and RMS of
//!   the input and output, the detector level, the largest reduction) over the whole window.

use super::effect::{pass_through, TailSleep};
use super::param_table::{
    flatten, linear, log, skewed, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use crate::audio::dsp::gain::{dry_wet_gains, MixLaw, SILENCE_DB};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};

pub const DEVICE_ID: &str = "sonara.builtin.compressor";

// Parameter IDs, grouped in blocks of ten per module.
pub const THRESHOLD: ParamId = 0;
pub const RATIO: ParamId = 1;
pub const KNEE: ParamId = 2;
pub const RANGE: ParamId = 3;
pub const ATTACK: ParamId = 10;
pub const RELEASE: ParamId = 11;
pub const AUTO_RELEASE: ParamId = 12;
pub const STYLE: ParamId = 20;
pub const DETECTION: ParamId = 21;
pub const STEREO_LINK: ParamId = 22;
pub const CHANNELS: ParamId = 23;
pub const SC_LOW_CUT: ParamId = 24;
pub const SC_LISTEN: ParamId = 25;
pub const MAKEUP: ParamId = 30;
pub const AUTO_GAIN: ParamId = 31;
pub const MIX: ParamId = 32;

const ID_SPACE: usize = 33;
const PARAM_COUNT: usize = 16;

/// Ratio the knob's top of travel reaches. The view labels the top as infinity.
pub const RATIO_MAX: f32 = 30.0;

const STYLES: &[&str] = &["Clean", "Glue", "Punch", "Opto"];
const DETECTIONS: &[&str] = &["Peak", "RMS"];
const CHANNEL_MODES: &[&str] = &["Stereo", "Mid", "Side"];

const DYNAMICS: [ParamSpec; 4] = [
    spec(
        THRESHOLD,
        "Threshold",
        "Dynamics",
        "dB",
        linear(-60.0, 0.0),
        -18.0,
    ),
    // Skewed so the low ratios get most of the travel; the top reads infinity in the view.
    spec(
        RATIO,
        "Ratio",
        "Dynamics",
        "",
        skewed(1.0, RATIO_MAX, 2.0),
        4.0,
    ),
    spec(KNEE, "Knee", "Dynamics", "dB", linear(0.0, 24.0), 6.0),
    spec(RANGE, "Range", "Dynamics", "dB", linear(0.0, 60.0), 60.0),
];
const TIMING: [ParamSpec; 3] = [
    spec(ATTACK, "Attack", "Timing", "ms", log(0.05, 200.0), 10.0),
    spec(RELEASE, "Release", "Timing", "ms", log(5.0, 2000.0), 150.0),
    spec(AUTO_RELEASE, "Auto Release", "Timing", "", Kind::Bool, 0.0),
];
const DETECTOR: [ParamSpec; 6] = [
    spec(STYLE, "Style", "Detector", "", Kind::Enum(STYLES), 0.0),
    spec(
        DETECTION,
        "Detection",
        "Detector",
        "",
        Kind::Enum(DETECTIONS),
        0.0,
    ),
    spec(
        STEREO_LINK,
        "Stereo Link",
        "Detector",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        CHANNELS,
        "Channels",
        "Detector",
        "",
        Kind::Enum(CHANNEL_MODES),
        0.0,
    ),
    // 0 is Off; above that a power curve close to log over 20–500 Hz.
    spec(
        SC_LOW_CUT,
        "SC Low Cut",
        "Detector",
        "Hz",
        skewed(0.0, 500.0, 2.0),
        0.0,
    ),
    spec(SC_LISTEN, "SC Listen", "Detector", "", Kind::Bool, 0.0).not_automatable(),
];
const OUTPUT: [ParamSpec; 3] = [
    spec(MAKEUP, "Makeup", "Output", "dB", linear(-12.0, 24.0), 0.0),
    spec(AUTO_GAIN, "Auto Gain", "Output", "", Kind::Bool, 1.0),
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 100.0),
];

pub const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[&DYNAMICS, &TIMING, &DETECTOR, &OUTPUT]);
const SLOT_OF: [u8; ID_SPACE] = slot_table(&SPECS);
pub static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOT_OF);

/// Frames between parameter updates.
pub const CHUNK: usize = 32;
/// Glide time of a parameter move (a one-pole, stepped once per chunk).
const RAMP_SECONDS: f32 = 0.005;
/// The detector's peak-hold release, as a fraction of the Release setting.
const DETECTOR_RELEASE_RATIO: f32 = 15.0;
/// RMS detector window.
const RMS_SECONDS: f32 = 0.010;
/// Glue leans the detection this far towards RMS.
const GLUE_RMS_LEAN: f32 = 0.3;
/// Program-dependent release memory time constant.
const PROGRAM_SECONDS: f32 = 0.300;
/// How far the Punch saturation pushes at 6 dB of gain reduction.
const PUNCH_DRIVE: f32 = 0.35;
/// Frames per `"dynamics"` record.
pub const RECORD_FRAMES: usize = 64;
/// Records the ring holds before a poll drains it.
pub const RING_CAPACITY: usize = 1024;
/// Bytes in one `"dynamics"` record.
pub const RECORD_BYTES: usize = 12;
/// `f32`s in the meter summary that follows the records.
pub const SUMMARY_FLOATS: usize = 10;
const DATA_RATE_HZ: f32 = 20.0;

// === Gain computer (shared by the device, the tests and the Godot view) ===

/// Gain reduction in dB for a detector level, with the Giannoulis/Massberg/Reiss soft knee.
/// `ratio` is `N:1`, `knee_db` the knee width and `range_db` the cap on the reduction.
#[inline]
pub fn gain_reduction_db(
    level_db: f32,
    threshold_db: f32,
    ratio: f32,
    knee_db: f32,
    range_db: f32,
) -> f32 {
    let ratio = ratio.max(1.0);
    // 1:1 is exactly no reduction, so the null test can stay bit-exact.
    if ratio == 1.0 {
        return 0.0;
    }
    let over = 2.0 * (level_db - threshold_db);
    let out = if knee_db <= 0.0 {
        if over < 0.0 {
            level_db
        } else {
            threshold_db + (level_db - threshold_db) / ratio
        }
    } else if over < -knee_db {
        level_db
    } else if over <= knee_db {
        let x = level_db - threshold_db + knee_db * 0.5;
        level_db + (1.0 / ratio - 1.0) * x * x / (2.0 * knee_db)
    } else {
        threshold_db + (level_db - threshold_db) / ratio
    };
    (level_db - out).clamp(0.0, range_db.max(0.0))
}

/// Output level in dB of the static curve.
pub fn static_curve_db(
    level_db: f32,
    threshold_db: f32,
    ratio: f32,
    knee_db: f32,
    range_db: f32,
) -> f32 {
    level_db - gain_reduction_db(level_db, threshold_db, ratio, knee_db, range_db)
}

// === Fast math ===
//
// The per-sample path converts a level to dB and a gain to linear. `log10`/`powf` are library
// calls that would eat the CPU budget, so both go through these approximations (relative error
// below 1e-5, exact at 0 dB so a unity gain stays bit-exact).

/// `ln(x)` for `x > 0`, via range reduction to `[1/√2, √2]` and the `atanh` series.
#[inline]
fn fast_ln(x: f32) -> f32 {
    let x = x.max(1.0e-30);
    let bits = x.to_bits();
    let mut e = ((bits >> 23) as i32) - 127;
    let mut m = f32::from_bits((bits & 0x007f_ffff) | 0x3f80_0000);
    if m > 1.414_213_6 {
        m *= 0.5;
        e += 1;
    }
    let t = (m - 1.0) / (m + 1.0);
    let t2 = t * t;
    let series = t * (2.0 + t2 * (0.666_666_7 + t2 * (0.4 + t2 * 0.285_714_3)));
    series + e as f32 * 0.693_147_2
}

/// Linear amplitude to dBFS, floored at −160 dB.
#[inline]
fn lin_to_db(x: f32) -> f32 {
    (8.685_889_6 * fast_ln(x)).max(crate::audio::dsp::gain::SILENCE_DB)
}

/// `2^x`.
#[inline]
fn fast_exp2(x: f32) -> f32 {
    if x <= -126.0 {
        return 0.0;
    }
    if x >= 127.0 {
        return f32::MAX;
    }
    // `floor` is a library call without SSE4.1, so bias into positive territory where the
    // integer cast truncates the same way.
    let n = ((x + 128.0) as i32 - 128) as f32;
    let f = x - n;
    let poly = 1.0
        + f * (0.693_147_2
            + f * (0.240_226_5
                + f * (0.055_504_11
                    + f * (0.009_618_129 + f * (0.001_333_355_8 + f * 0.000_154_035_3)))));
    let scale = f32::from_bits(((n as i32 + 127) as u32) << 23);
    poly * scale
}

/// `10^(db/20)`. Exactly 1.0 at 0 dB, so a unity gain stays bit-exact.
#[inline]
fn gain_db_to_lin(db: f32) -> f32 {
    fast_exp2(db * 0.166_096_4)
}

/// One-pole coefficient for a time constant of `ms` at `sample_rate` (0 ms = instant).
#[inline]
fn time_coef(ms: f32, sample_rate: f32) -> f32 {
    if ms <= 0.0 {
        0.0
    } else {
        (-1.0 / (ms * 0.001 * sample_rate)).exp()
    }
}

// === Enums ===

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    Clean,
    Glue,
    Punch,
    Opto,
}

impl Style {
    fn from_index(index: usize) -> Self {
        match index {
            1 => Self::Glue,
            2 => Self::Punch,
            3 => Self::Opto,
            _ => Self::Clean,
        }
    }

    /// Punch detects the output instead of the input.
    fn is_feedback(self) -> bool {
        self == Self::Punch
    }

    /// Punch is the fast one: its time constants are half the knobs' values.
    fn time_scale(self) -> f32 {
        if self == Self::Punch {
            0.5
        } else {
            1.0
        }
    }

    /// How much the program-dependent release memory stretches the release.
    fn program_scale(self, memory_db: f32) -> f32 {
        let depth = (memory_db / 12.0).max(0.0);
        match self {
            Self::Glue => 1.0 + depth,
            Self::Opto => 1.0 + 2.0 * depth,
            _ => 1.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Detection {
    Peak,
    Rms,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channels {
    Stereo,
    Mid,
    Side,
}

impl Channels {
    fn from_index(index: usize) -> Self {
        match index {
            1 => Self::Mid,
            2 => Self::Side,
            _ => Self::Stereo,
        }
    }
}

// === Smoothing ===

/// A parameter that glides to its target once per chunk and is interpolated per sample, so a
/// move is smooth and the output doesn't depend on the host's block splits.
#[derive(Clone, Copy, Debug)]
struct Ramp {
    start: f32,
    end: f32,
    target: f32,
}

impl Ramp {
    fn new(value: f32) -> Self {
        Self {
            start: value,
            end: value,
            target: value,
        }
    }

    fn set_target(&mut self, value: f32) {
        self.target = value;
    }

    /// Advance one chunk towards the target (`smooth` is the per-chunk fraction).
    #[inline]
    fn advance(&mut self, smooth: f32) {
        self.start = self.end;
        let delta = self.target - self.end;
        self.end += delta * smooth;
        if (self.target - self.end).abs() < 1.0e-4 {
            self.end = self.target;
        }
    }

    /// The value inside the chunk at position `t` in `0..=1`.
    #[inline]
    fn at(&self, t: f32) -> f32 {
        if self.start == self.end {
            self.end
        } else {
            self.start + (self.end - self.start) * t
        }
    }

    /// Jump to the target (initialisation, reset).
    fn snap(&mut self) {
        self.start = self.target;
        self.end = self.target;
    }
}

// === Meter window ===

/// Level accumulators over one poll window. Plain fields, so the audio thread never allocates.
#[derive(Clone, Copy)]
struct MeterWindow {
    in_peak: [f32; 2],
    out_peak: [f32; 2],
    in_sq: [f64; 2],
    out_sq: [f64; 2],
    frames: u32,
    detector_db: f32,
    gr_max_db: f32,
}

impl MeterWindow {
    const EMPTY: Self = Self {
        in_peak: [0.0; 2],
        out_peak: [0.0; 2],
        in_sq: [0.0; 2],
        out_sq: [0.0; 2],
        frames: 0,
        detector_db: SILENCE_DB,
        gr_max_db: 0.0,
    };

    #[inline]
    fn add(&mut self, input: [f32; 2], output: [f32; 2], detector_db: f32, gr_db: f32) {
        for c in 0..2 {
            self.in_peak[c] = self.in_peak[c].max(input[c].abs());
            self.out_peak[c] = self.out_peak[c].max(output[c].abs());
            self.in_sq[c] += (input[c] as f64) * (input[c] as f64);
            self.out_sq[c] += (output[c] as f64) * (output[c] as f64);
        }
        self.frames += 1;
        self.detector_db = self.detector_db.max(detector_db);
        self.gr_max_db = self.gr_max_db.max(gr_db);
    }

    fn rms_db(&self, sum_sq: f64) -> f32 {
        if self.frames == 0 {
            return SILENCE_DB;
        }
        lin_to_db((sum_sq / self.frames as f64).sqrt() as f32)
    }

    /// `in_peak_l, in_peak_r, out_peak_l, out_peak_r, in_rms_l, in_rms_r, out_rms_l, out_rms_r,
    /// detector_db, gr_max_db`, all in dB.
    fn summary(&self) -> [f32; SUMMARY_FLOATS] {
        [
            lin_to_db(self.in_peak[0]),
            lin_to_db(self.in_peak[1]),
            lin_to_db(self.out_peak[0]),
            lin_to_db(self.out_peak[1]),
            self.rms_db(self.in_sq[0]),
            self.rms_db(self.in_sq[1]),
            self.rms_db(self.out_sq[0]),
            self.rms_db(self.out_sq[1]),
            self.detector_db,
            self.gr_max_db,
        ]
    }
}

// === Device ===

pub struct CompressorDevice {
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,

    style: Style,
    detection: Detection,
    channels: Channels,
    auto_release: bool,
    auto_gain: bool,
    sc_listen: bool,

    threshold: Ramp,
    ratio: Ramp,
    knee: Ramp,
    range: Ramp,
    attack_ms: Ramp,
    release_ms: Ramp,
    makeup: Ramp,
    mix: Ramp,
    link: Ramp,
    sc_cut_hz: Ramp,
    sc_cut_mix: Ramp,
    punch_mix: Ramp,
    detection_mix: Ramp,
    sc_listen_mix: Ramp,
    auto_gain_mix: Ramp,

    // Coefficients, recomputed once per chunk.
    attack_coef: f32,
    release_coef: f32,
    release_fast_coef: f32,
    release_slow_coef: f32,
    det_coef: f32,
    rms_coef: f32,
    sc_g: f32,
    prog_coef: f32,
    auto_attack_coef: f32,
    auto_release_coef: f32,

    det_peak: [f32; 2],
    det_ms: [f32; 2],
    gain: [f32; 2],
    prev_out: [f32; 2],
    sc_hp: [[OnePole; 2]; 2],
    auto_blend: f32,
    prog_mem: f32,

    // Per-chunk flags and values, so a bypassed feature costs nothing per sample.
    sc_bypass: bool,
    detect_bypass: bool,
    prog_active: bool,
    punch_active: bool,
    feedback: bool,
    auto_gain_db: f32,

    phase: usize,
    smooth: f32,
    enabled: bool,
    sleep: TailSleep,

    subscribed: bool,
    frames_since_poll: usize,
    poll_interval: usize,
    ring: [[f32; 3]; RING_CAPACITY],
    ring_len: usize,
    record_frames: usize,
    rec_in_peak: f32,
    rec_out_peak: f32,
    rec_gr: f32,
    meter: MeterWindow,
    last_detector_db: f32,
}

impl CompressorDevice {
    pub fn new(sample_rate: f32) -> Self {
        let values = ParamValues::<PARAM_COUNT>::new(&TABLE);
        let real = |id: ParamId| values.real(id).unwrap_or(0.0);
        let mut sleep = TailSleep::new(sample_rate);
        sleep.set_tail_seconds(Some(0.0));
        let mut device = Self {
            sample_rate,
            values,
            style: Style::from_index(real(STYLE) as usize),
            detection: if real(DETECTION) >= 0.5 {
                Detection::Rms
            } else {
                Detection::Peak
            },
            channels: Channels::from_index(real(CHANNELS) as usize),
            auto_release: real(AUTO_RELEASE) >= 0.5,
            auto_gain: real(AUTO_GAIN) >= 0.5,
            sc_listen: real(SC_LISTEN) >= 0.5,
            threshold: Ramp::new(real(THRESHOLD)),
            ratio: Ramp::new(real(RATIO)),
            knee: Ramp::new(real(KNEE)),
            range: Ramp::new(real(RANGE)),
            attack_ms: Ramp::new(real(ATTACK)),
            release_ms: Ramp::new(real(RELEASE)),
            makeup: Ramp::new(real(MAKEUP)),
            mix: Ramp::new(real(MIX) * 0.01),
            link: Ramp::new(real(STEREO_LINK) * 0.01),
            sc_cut_hz: Ramp::new(real(SC_LOW_CUT).max(20.0)),
            sc_cut_mix: Ramp::new(if real(SC_LOW_CUT) > 0.0 { 1.0 } else { 0.0 }),
            punch_mix: Ramp::new(0.0),
            detection_mix: Ramp::new(0.0),
            sc_listen_mix: Ramp::new(0.0),
            auto_gain_mix: Ramp::new(0.0),
            attack_coef: 0.0,
            release_coef: 0.0,
            release_fast_coef: 0.0,
            release_slow_coef: 0.0,
            det_coef: 0.0,
            rms_coef: 0.0,
            sc_g: 0.0,
            prog_coef: 0.0,
            auto_attack_coef: 0.0,
            auto_release_coef: 0.0,
            det_peak: [0.0; 2],
            det_ms: [0.0; 2],
            gain: [0.0; 2],
            prev_out: [0.0; 2],
            sc_hp: [[OnePole::new(); 2]; 2],
            auto_blend: 0.0,
            prog_mem: 0.0,
            sc_bypass: true,
            detect_bypass: true,
            prog_active: false,
            punch_active: false,
            feedback: false,
            auto_gain_db: 0.0,
            phase: 0,
            smooth: 0.0,
            enabled: true,
            sleep,
            subscribed: false,
            frames_since_poll: 0,
            poll_interval: 0,
            ring: [[0.0; 3]; RING_CAPACITY],
            ring_len: 0,
            record_frames: 0,
            rec_in_peak: 0.0,
            rec_out_peak: 0.0,
            rec_gr: 0.0,
            meter: MeterWindow::EMPTY,
            last_detector_db: SILENCE_DB,
        };
        device.configure_rate(sample_rate);
        device.apply(THRESHOLD);
        device.snap_all();
        device
    }

    fn configure_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        let chunk_seconds = CHUNK as f32 / sample_rate;
        self.smooth = 1.0 - (-chunk_seconds / RAMP_SECONDS).exp();
        self.rms_coef = time_coef(RMS_SECONDS * 1000.0, sample_rate);
        self.prog_coef = 1.0 - time_coef(PROGRAM_SECONDS * 1000.0, sample_rate);
        self.auto_attack_coef = time_coef(20.0, sample_rate);
        self.auto_release_coef = time_coef(300.0, sample_rate);
        self.poll_interval = (sample_rate / DATA_RATE_HZ) as usize;
        self.sleep.set_sample_rate(sample_rate);
    }

    /// Snap every smoothed value to its target and clear all state.
    fn snap_all(&mut self) {
        for ramp in [
            &mut self.threshold,
            &mut self.ratio,
            &mut self.knee,
            &mut self.range,
            &mut self.attack_ms,
            &mut self.release_ms,
            &mut self.makeup,
            &mut self.mix,
            &mut self.link,
            &mut self.sc_cut_hz,
            &mut self.sc_cut_mix,
            &mut self.punch_mix,
            &mut self.detection_mix,
            &mut self.sc_listen_mix,
            &mut self.auto_gain_mix,
        ] {
            ramp.snap();
        }
        self.det_peak = [0.0; 2];
        self.det_ms = [0.0; 2];
        self.gain = [0.0; 2];
        self.prev_out = [0.0; 2];
        self.sc_hp = [[OnePole::new(); 2]; 2];
        self.auto_blend = 0.0;
        self.prog_mem = 0.0;
        self.phase = 0;
        self.ring_len = 0;
        self.record_frames = 0;
        self.rec_in_peak = 0.0;
        self.rec_out_peak = 0.0;
        self.rec_gr = 0.0;
        self.meter = MeterWindow::EMPTY;
        self.frames_since_poll = 0;
        self.update_coefficients();
    }

    /// Advance the smoothers by one chunk and recompute what moved.
    fn begin_chunk(&mut self) {
        let smooth = self.smooth;
        for ramp in [
            &mut self.threshold,
            &mut self.ratio,
            &mut self.knee,
            &mut self.range,
            &mut self.attack_ms,
            &mut self.release_ms,
            &mut self.makeup,
            &mut self.mix,
            &mut self.link,
            &mut self.sc_cut_hz,
            &mut self.sc_cut_mix,
            &mut self.punch_mix,
            &mut self.detection_mix,
            &mut self.sc_listen_mix,
            &mut self.auto_gain_mix,
        ] {
            ramp.advance(smooth);
        }
        self.update_coefficients();
    }

    /// Recompute the one-pole coefficients from the chunk's smoothed values.
    fn update_coefficients(&mut self) {
        let sample_rate = self.sample_rate;
        let scale = self.style.time_scale();
        let program = self.style.program_scale(self.prog_mem);
        let release_ms = self.release_ms.end * scale * program;
        let attack_ms = self.attack_ms.end * scale;
        self.attack_coef = time_coef(attack_ms, sample_rate);
        self.release_coef = time_coef(release_ms, sample_rate);
        self.release_fast_coef = time_coef(release_ms * 0.25, sample_rate);
        self.release_slow_coef = time_coef(release_ms * 4.0, sample_rate);
        self.det_coef = time_coef((release_ms / DETECTOR_RELEASE_RATIO).max(0.05), sample_rate);
        self.sc_g = one_pole_g(self.sc_cut_hz.end, sample_rate);

        // What this chunk can skip, and the auto gain (which only moves with the chunk's
        // threshold, ratio, knee and range).
        let bypass = self.sc_cut_mix.start == 0.0 && self.sc_cut_mix.end == 0.0;
        if bypass && !self.sc_bypass {
            self.sc_hp = [[OnePole::new(); 2]; 2];
        }
        self.sc_bypass = bypass;
        self.detect_bypass = self.detection_mix.start == 0.0 && self.detection_mix.end == 0.0;
        self.prog_active = matches!(self.style, Style::Glue | Style::Opto);
        self.punch_active = self.punch_mix.start > 0.0 || self.punch_mix.end > 0.0;
        self.feedback = self.style.is_feedback();
        self.auto_gain_db = 0.5
            * gain_reduction_db(
                0.0,
                self.threshold.end,
                self.ratio.end,
                self.knee.end,
                self.range.end,
            );
    }

    /// The detection mix the style asks for: Glue leans towards RMS.
    fn effective_detection_mix(&self) -> f32 {
        let base = if self.detection == Detection::Rms {
            1.0
        } else {
            0.0
        };
        match self.style {
            Style::Glue => (base + GLUE_RMS_LEAN).min(1.0),
            _ => base,
        }
    }

    /// Level detector for one channel, in dB: a peak-hold with an instant attack and a fast
    /// release, blended towards a fixed-window RMS by `mix`.
    #[inline]
    fn detect(&mut self, channel: usize, x: f32, mix: f32) -> f32 {
        let level = x.abs();
        let peak = if level > self.det_peak[channel] {
            self.det_peak[channel] = level;
            level
        } else {
            self.det_peak[channel] =
                self.det_coef * self.det_peak[channel] + (1.0 - self.det_coef) * level;
            self.det_peak[channel]
        };
        if self.detect_bypass {
            return lin_to_db(peak);
        }
        self.det_ms[channel] = self.rms_coef * self.det_ms[channel] + (1.0 - self.rms_coef) * x * x;
        let rms = self.det_ms[channel].sqrt();
        lin_to_db(peak + mix * (rms - peak))
    }

    #[inline]
    fn process_frame(&mut self, in_l: f32, in_r: f32, t: f32) -> (f32, f32) {
        let threshold = self.threshold.at(t);
        let ratio = self.ratio.at(t);
        let knee = self.knee.at(t);
        let range = self.range.at(t);
        let link = self.link.at(t);
        let mix = self.mix.at(t);
        let detection_mix = self.detection_mix.at(t);
        let sc_listen_mix = self.sc_listen_mix.at(t);
        let makeup_db = self.makeup.at(t) + self.auto_gain_mix.at(t) * self.auto_gain_db;

        // What the detector listens to: the input, or the previous output for Punch's feedback.
        let (mut dl, mut dr) = if self.feedback {
            (self.prev_out[0], self.prev_out[1])
        } else {
            (in_l, in_r)
        };
        if !self.sc_bypass {
            let sc_cut_mix = self.sc_cut_mix.at(t);
            let hl = self.sc_hp[0][0].highpass(dl, self.sc_g);
            let hl = self.sc_hp[0][1].highpass(hl, self.sc_g);
            let hr = self.sc_hp[1][0].highpass(dr, self.sc_g);
            let hr = self.sc_hp[1][1].highpass(hr, self.sc_g);
            dl += sc_cut_mix * (hl - dl);
            dr += sc_cut_mix * (hr - dr);
        }

        let (al, ar) = match self.channels {
            Channels::Stereo => (dl, dr),
            Channels::Mid => {
                let m = (dl + dr) * 0.5;
                (m, m)
            }
            Channels::Side => {
                let s = (dl - dr) * 0.5;
                (s, s)
            }
        };
        let lvl_l = self.detect(0, al, detection_mix);
        let lvl_r = self.detect(1, ar, detection_mix);
        let linked = lvl_l.max(lvl_r);
        self.last_detector_db = linked;
        let lvl_l = lvl_l + link * (linked - lvl_l);
        let lvl_r = lvl_r + link * (linked - lvl_r);

        let target_l = gain_reduction_db(lvl_l, threshold, ratio, knee, range);
        let target_r = gain_reduction_db(lvl_r, threshold, ratio, knee, range);
        let mean_target = (target_l + target_r) * 0.5;

        if self.prog_active {
            self.prog_mem += (mean_target - self.prog_mem) * self.prog_coef;
        }
        let release_coef = if self.auto_release {
            if mean_target > 0.5 * (self.gain[0] + self.gain[1]) {
                self.auto_blend += (1.0 - self.auto_blend) * self.auto_attack_coef;
            } else {
                self.auto_blend += (0.0 - self.auto_blend) * self.auto_release_coef;
            }
            self.release_slow_coef
                + (self.release_fast_coef - self.release_slow_coef) * self.auto_blend
        } else {
            self.release_coef
        };
        let attack = self.attack_coef;
        let current = self.gain[0];
        let coef = if target_l > current {
            attack
        } else {
            release_coef
        };
        self.gain[0] = current + (1.0 - coef) * (target_l - current);
        let current = self.gain[1];
        let coef = if target_r > current {
            attack
        } else {
            release_coef
        };
        self.gain[1] = current + (1.0 - coef) * (target_r - current);

        let gain_l = gain_db_to_lin(makeup_db - self.gain[0]);
        let gain_r = gain_db_to_lin(makeup_db - self.gain[1]);
        let mut wet_l = in_l * gain_l;
        let mut wet_r = in_r * gain_r;

        // Punch's mild odd-harmonic saturation, driven by how hard it is working.
        if self.punch_active {
            let punch_mix = self.punch_mix.at(t);
            let drive = 1.0 + PUNCH_DRIVE * (self.gain[0].max(self.gain[1]) / 6.0).clamp(0.0, 1.0);
            let sat_l = (drive * wet_l).tanh() / drive;
            let sat_r = (drive * wet_r).tanh() / drive;
            wet_l += punch_mix * (sat_l - wet_l);
            wet_r += punch_mix * (sat_r - wet_r);
        }
        self.prev_out = [wet_l, wet_r];

        let (dry, wet) = dry_wet_gains(mix, MixLaw::Linear);
        let mut out_l = dry * in_l + wet * wet_l;
        let mut out_r = dry * in_r + wet * wet_r;

        // SC Listen replaces the output with what the detector hears.
        if sc_listen_mix > 0.0 {
            out_l += sc_listen_mix * (dl - out_l);
            out_r += sc_listen_mix * (dr - out_r);
        }
        (out_l, out_r)
    }

    /// Store one `"dynamics"` record if the record window is full.
    #[inline]
    fn push_record(&mut self) {
        self.record_frames += 1;
        if self.record_frames < RECORD_FRAMES {
            return;
        }
        if self.ring_len < RING_CAPACITY {
            self.ring[self.ring_len] = [
                lin_to_db(self.rec_in_peak),
                lin_to_db(self.rec_out_peak),
                self.rec_gr,
            ];
            self.ring_len += 1;
        }
        self.record_frames = 0;
        self.rec_in_peak = 0.0;
        self.rec_out_peak = 0.0;
        self.rec_gr = 0.0;
    }

    fn apply(&mut self, _id: ParamId) {
        let real = |id: ParamId| self.values.real(id).unwrap_or(0.0);
        self.style = Style::from_index(real(STYLE) as usize);
        self.detection = if real(DETECTION) >= 0.5 {
            Detection::Rms
        } else {
            Detection::Peak
        };
        self.channels = Channels::from_index(real(CHANNELS) as usize);
        self.auto_release = real(AUTO_RELEASE) >= 0.5;
        self.auto_gain = real(AUTO_GAIN) >= 0.5;
        self.sc_listen = real(SC_LISTEN) >= 0.5;

        self.threshold.set_target(real(THRESHOLD));
        self.ratio.set_target(real(RATIO));
        self.knee.set_target(real(KNEE));
        self.range.set_target(real(RANGE));
        self.attack_ms.set_target(real(ATTACK));
        self.release_ms.set_target(real(RELEASE));
        self.makeup.set_target(real(MAKEUP));
        self.mix.set_target(real(MIX) * 0.01);
        self.link.set_target(real(STEREO_LINK) * 0.01);
        let sc_cut = real(SC_LOW_CUT);
        self.sc_cut_hz.set_target(sc_cut.max(20.0));
        self.sc_cut_mix
            .set_target(if sc_cut > 0.0 { 1.0 } else { 0.0 });
        self.punch_mix
            .set_target(if self.style == Style::Punch { 1.0 } else { 0.0 });
        self.detection_mix
            .set_target(self.effective_detection_mix());
        self.sc_listen_mix
            .set_target(if self.sc_listen { 1.0 } else { 0.0 });
        self.auto_gain_mix
            .set_target(if self.auto_gain { 1.0 } else { 0.0 });
    }
}

impl AudioDevice for CompressorDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let n = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        if !self.enabled {
            pass_through(inputs, outputs, n);
            return;
        }
        self.sleep.on_block(n);
        let mut i = 0;
        while i < n {
            if self.phase == 0 {
                self.begin_chunk();
            }
            let run = (CHUNK - self.phase).min(n - i);
            for s in 0..run {
                let t = (self.phase + s + 1) as f32 / CHUNK as f32;
                let frame = (i + s) * 2;
                let (in_l, in_r) = (inputs[frame], inputs[frame + 1]);
                let (out_l, out_r) = self.process_frame(in_l, in_r, t);
                outputs[frame] = out_l;
                outputs[frame + 1] = out_r;
                self.rec_in_peak = self.rec_in_peak.max(in_l.abs()).max(in_r.abs());
                self.rec_out_peak = self.rec_out_peak.max(out_l.abs()).max(out_r.abs());
                let gr = 0.5 * (self.gain[0] + self.gain[1]);
                self.rec_gr = self.rec_gr.max(gr);
                if self.subscribed {
                    self.meter
                        .add([in_l, in_r], [out_l, out_r], self.last_detector_db, gr);
                }
                self.push_record();
            }
            self.phase += run;
            if self.phase == CHUNK {
                self.phase = 0;
            }
            i += run;
        }
        if self.subscribed {
            self.frames_since_poll += n;
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        if let Some((_, _real)) = self.values.set(param_id, value) {
            self.apply(param_id);
            self.sleep.wake();
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.values.get(param_id)
    }

    fn device_id(&self) -> &str {
        DEVICE_ID
    }

    fn device_name(&self) -> &str {
        "Compressor"
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
        self.snap_all();
        self.sleep.wake();
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.configure_rate(sample_rate);
        self.reset();
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
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
        // While the view watches, keep running so the meters and history keep moving.
        self.sleep.update(has_audio_activity || self.subscribed)
    }

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if data_type != "dynamics" {
            return Err(format!("Compressor does not support '{data_type}' data"));
        }
        if !self.subscribed {
            self.ring_len = 0;
            self.record_frames = 0;
            self.frames_since_poll = 0;
            self.meter = MeterWindow::EMPTY;
            self.subscribed = true;
        }
        self.sleep.wake();
        Ok(())
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "dynamics" {
            self.subscribed = false;
        }
    }

    /// `u32 count` followed by `count` records of `in_peak_db, out_peak_db, gr_db`, then the
    /// [`SUMMARY_FLOATS`] meter summary of the whole window (little-endian f32).
    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        if !self.subscribed || self.frames_since_poll < self.poll_interval {
            return None;
        }
        self.frames_since_poll = 0;
        if self.ring_len == 0 {
            return None;
        }
        let count = self.ring_len;
        let mut bytes = Vec::with_capacity(4 + count * RECORD_BYTES + SUMMARY_FLOATS * 4);
        bytes.extend_from_slice(&(count as u32).to_le_bytes());
        for record in &self.ring[..count] {
            for value in record {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        for value in self.meter.summary() {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        self.meter = MeterWindow::EMPTY;
        self.ring_len = 0;
        Some(("dynamics".to_string(), bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{
        left, peak, render, right, sine, spectrum_db, stereo, tone_amplitude, white_noise,
    };

    const SR: f32 = 48_000.0;

    fn device() -> CompressorDevice {
        let mut d = CompressorDevice::new(SR);
        d.prepare(SR, 4096);
        d
    }

    fn set(d: &mut CompressorDevice, id: ParamId, real: f32) {
        let norm = TABLE.spec(id).unwrap().to_norm(real);
        d.set_parameter(id, norm);
    }

    /// Settle a steady tone and return the output level in dBFS over the last half second.
    fn steady_out_db(d: &mut CompressorDevice, freq: f32, level_db: f32, seconds: f32) -> f32 {
        d.reset();
        let amplitude = 10f32.powf(level_db / 20.0);
        let input = stereo(&sine(freq, SR, (SR * seconds) as usize, amplitude));
        let out = left(&render(d, &input, &[512]));
        let tail = &out[out.len() - SR as usize / 2..];
        20.0 * tone_amplitude(tail, freq, SR).log10()
    }

    /// Applied gain per millisecond over `input`, from the left channel.
    fn gain_trace(d: &mut CompressorDevice, input: &[f32], freq: f32, amplitude: f32) -> Vec<f32> {
        let out = left(&render(d, input, &[SR as usize / 1000]));
        let window = SR as usize / 1000;
        out.chunks_exact(window)
            .map(|w| tone_amplitude(w, freq, SR) / amplitude)
            .collect()
    }

    #[test]
    fn table_has_the_documented_layout() {
        assert_eq!(TABLE.len(), PARAM_COUNT);
        let d = device();
        let infos = d.parameters();
        let info = |id: ParamId| infos.iter().find(|p| p.id == id).unwrap();
        assert_eq!(info(THRESHOLD).module, "Dynamics");
        assert_eq!(info(STYLE).module, "Detector");
        assert_eq!(info(RELEASE).unit, "ms");
        assert_eq!(info(THRESHOLD).default, -18.0);
        assert_eq!(info(RATIO).default, 4.0);
        assert_eq!(info(AUTO_GAIN).default, 1.0);
        assert!(info(SC_LISTEN).is_hidden == false && !info(SC_LISTEN).is_automation_safe);
        assert_eq!(d.get_parameter(AUTO_GAIN), Some(1.0));
    }

    #[test]
    fn fast_math_matches_the_library() {
        for x in [1e-6f32, 0.001, 0.1, 0.3, 0.7, 1.0, 2.0, 7.5, 1000.0] {
            let got = fast_ln(x);
            let want = x.ln();
            assert!((got - want).abs() < 1e-4, "ln({x}): {got} vs {want}");
            let db = lin_to_db(x);
            assert!((db - 20.0 * x.log10()).abs() < 1e-3, "db({x}): {db}");
        }
        assert_eq!(gain_db_to_lin(0.0), 1.0);
        for db in [-60.0f32, -18.0, -6.0, -0.5, 0.5, 6.0, 24.0] {
            let got = gain_db_to_lin(db);
            let want = 10f32.powf(db / 20.0);
            assert!((got / want - 1.0).abs() < 1e-4, "{db} dB: {got} vs {want}");
        }
    }

    #[test]
    fn static_curve_matches_the_textbook_value() {
        // -10 dBFS in, threshold -20, ratio 4:1, no knee -> -20 + 10/4 = -17.5 dBFS out.
        let mut d = device();
        set(&mut d, KNEE, 0.0);
        set(&mut d, THRESHOLD, -20.0);
        set(&mut d, RATIO, 4.0);
        set(&mut d, AUTO_GAIN, 0.0);
        let got = steady_out_db(&mut d, 1_000.0, -10.0, 3.0);
        assert!((got + 17.5).abs() < 0.2, "measured {got:.3} dB");
    }

    #[test]
    fn the_knee_is_continuous() {
        let (threshold, ratio, knee) = (-15.0, 4.0, 6.0);
        let mut previous = static_curve_db(-30.0, threshold, ratio, knee, 60.0);
        let mut step = 0.0f32;
        let mut level = -30.0;
        while level <= 0.0 {
            let out = static_curve_db(level, threshold, ratio, knee, 60.0);
            step = step.max((out - previous).abs());
            previous = out;
            level += 0.01;
        }
        assert!(step <= 0.0101, "largest step {step:.4} dB across the sweep");
        // And the knee really bends the curve: the corner is neither straight line.
        let corner = static_curve_db(threshold, threshold, ratio, knee, 60.0);
        let below = threshold - knee * 0.5;
        let above = threshold + knee * 0.5;
        assert!(corner > below && corner < above);
    }

    #[test]
    fn attack_and_release_land_within_ten_percent() {
        // Attack: step from below the threshold to 10 dB above it.
        let mut d = device();
        set(&mut d, KNEE, 0.0);
        set(&mut d, THRESHOLD, -20.0);
        set(&mut d, RATIO, 4.0);
        set(&mut d, AUTO_GAIN, 0.0);
        set(&mut d, ATTACK, 50.0);
        set(&mut d, RELEASE, 200.0);
        let quiet = stereo(&sine(1_000.0, SR, SR as usize, 10f32.powf(-30.0 / 20.0)));
        let loud = stereo(&sine(
            1_000.0,
            SR,
            SR as usize / 2,
            10f32.powf(-10.0 / 20.0),
        ));
        render(&mut d, &quiet, &[512]);
        let trace = gain_trace(&mut d, &loud, 1_000.0, 10f32.powf(-10.0 / 20.0));
        let final_gr = -20.0 * trace[trace.len() - 1].log10();
        assert!(final_gr > 7.0, "settles at {final_gr:.2} dB of reduction");
        let attack = crossing_ms(&trace, final_gr * 0.63, true);
        assert!(
            (attack - 50.0).abs() <= 5.0,
            "attack measured {attack:.1} ms, want 50"
        );

        // Release: step between two levels above the threshold so nothing clamps.
        let mut d = device();
        set(&mut d, KNEE, 0.0);
        set(&mut d, THRESHOLD, -20.0);
        set(&mut d, RATIO, 4.0);
        set(&mut d, AUTO_GAIN, 0.0);
        set(&mut d, ATTACK, 10.0);
        set(&mut d, RELEASE, 200.0);
        let loud = stereo(&sine(1_000.0, SR, SR as usize, 10f32.powf(-5.0 / 20.0)));
        let quieter = stereo(&sine(1_000.0, SR, SR as usize, 10f32.powf(-15.0 / 20.0)));
        render(&mut d, &loud, &[512]);
        let trace = gain_trace(&mut d, &quieter, 1_000.0, 10f32.powf(-15.0 / 20.0));
        let initial_gr = -20.0 * trace[0].log10();
        let final_gr = -20.0 * trace[trace.len() - 1].log10();
        // The one-pole reaches 63 % of the change after one time constant.
        let release = crossing_ms(&trace, final_gr + 0.37 * (initial_gr - final_gr), false);
        assert!(
            (release - 200.0).abs() <= 20.0,
            "release measured {release:.1} ms, want 200"
        );
    }

    /// Time in ms at which the applied gain first crosses `target_gr` of reduction.
    fn crossing_ms(trace: &[f32], target_gr: f32, rising: bool) -> f32 {
        let mut previous = 0.0f32;
        for (i, &gain) in trace.iter().enumerate() {
            let gr = -20.0 * gain.max(1e-12).log10();
            let hit = if rising {
                gr >= target_gr
            } else {
                gr <= target_gr
            };
            if hit {
                // Linear interpolation between the previous and this window.
                let span = gr - previous;
                let frac = if span.abs() > 1e-9 {
                    (target_gr - previous) / span
                } else {
                    1.0
                };
                return (i as f32 - 1.0 + frac.clamp(0.0, 1.0)) as f32;
            }
            previous = gr;
        }
        f32::NAN
    }

    #[test]
    fn ratio_one_nulls_against_the_input() {
        let mut d = device();
        set(&mut d, RATIO, 1.0);
        set(&mut d, AUTO_GAIN, 0.0);
        set(&mut d, MAKEUP, 0.0);
        // Let the parameter ramps settle before comparing.
        render(&mut d, &vec![0.0; (SR as usize / 10) * 2], &[512]);
        let input = stereo(&white_noise(SR as usize, 0.5, 7));
        let out = render(&mut d, &input, &[512]);
        let worst = out
            .iter()
            .zip(&input)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        assert!(worst < 1e-6, "differs by {worst} (want below -120 dB)");
    }

    #[test]
    fn stereo_link_gives_identical_reduction() {
        let mut d = device();
        set(&mut d, THRESHOLD, -30.0);
        set(&mut d, RATIO, 4.0);
        set(&mut d, AUTO_GAIN, 0.0);
        set(&mut d, STEREO_LINK, 100.0);
        let loud = sine(1_000.0, SR, SR as usize, 10f32.powf(-6.0 / 20.0));
        let quiet = sine(1_000.0, SR, SR as usize, 10f32.powf(-24.0 / 20.0));
        let input = crate::audio::dsp::test_util::interleave(&loud, &quiet);
        let out = render(&mut d, &input, &[512]);
        let tail = SR as usize / 2;
        let gain_l = tone_amplitude(&left(&out)[tail..], 1_000.0, SR)
            / tone_amplitude(&loud[tail..], 1_000.0, SR);
        let gain_r = tone_amplitude(&right(&out)[tail..], 1_000.0, SR)
            / tone_amplitude(&quiet[tail..], 1_000.0, SR);
        assert!(
            (gain_l - gain_r).abs() < 1e-3,
            "L gain {gain_l:.5}, R gain {gain_r:.5}"
        );
    }

    #[test]
    fn the_sidechain_low_cut_lifts_the_gain_reduction_on_bass() {
        let mut d = device();
        set(&mut d, THRESHOLD, -30.0);
        set(&mut d, RATIO, 4.0);
        set(&mut d, KNEE, 0.0);
        set(&mut d, AUTO_GAIN, 0.0);
        set(&mut d, ATTACK, 1.0);
        set(&mut d, RELEASE, 100.0);
        let without = steady_out_db(&mut d, 60.0, -6.0, 2.0);
        set(&mut d, SC_LOW_CUT, 200.0);
        let with = steady_out_db(&mut d, 60.0, -6.0, 2.0);
        let reduction = with - without;
        assert!(
            reduction >= 6.0,
            "SC Low Cut 200 Hz only lifted the reduction by {reduction:.2} dB"
        );
    }

    #[test]
    fn sc_listen_outputs_the_detector_path() {
        let mut d = device();
        set(&mut d, SC_LISTEN, 1.0);
        let unity = steady_out_db(&mut d, 1_000.0, -12.0, 1.0);
        assert!(
            (unity + 12.0).abs() < 0.2,
            "SC Listen is unity: {unity:.3} dBFS"
        );
        set(&mut d, SC_LOW_CUT, 200.0);
        let cut = steady_out_db(&mut d, 60.0, -12.0, 2.0);
        assert!(cut < -12.0, "the 60 Hz tone is filtered: {cut:.2} dB");
        // Turning SC Listen off returns to the compressed output.
        set(&mut d, SC_LISTEN, 0.0);
        set(&mut d, SC_LOW_CUT, 0.0);
        set(&mut d, THRESHOLD, -30.0);
        set(&mut d, RATIO, 4.0);
        set(&mut d, AUTO_GAIN, 0.0);
        let compressed = steady_out_db(&mut d, 1_000.0, -6.0, 2.0);
        assert!(compressed < -9.0, "{compressed:.2} dB");
    }

    #[test]
    fn every_style_settles_near_the_static_curve() {
        // A tone a couple of dB above the threshold: the feedback style's steady state is the
        // fixed point of y = x - gr(y), which meets the feed-forward curve here.
        let expected = -18.0 + (-16.0 + 18.0) / 4.0;
        for style in 0..STYLES.len() {
            let mut d = device();
            set(&mut d, STYLE, style as f32);
            set(&mut d, KNEE, 0.0);
            set(&mut d, AUTO_GAIN, 0.0);
            let got = steady_out_db(&mut d, 1_000.0, -16.0, 3.0);
            assert!(
                (got - expected).abs() <= 1.0,
                "{} settles at {got:.2} dB, want {expected:.2}",
                STYLES[style]
            );
        }
    }

    #[test]
    fn punch_stays_below_one_percent_thd() {
        let mut d = device();
        set(&mut d, STYLE, 2.0);
        set(&mut d, KNEE, 0.0);
        set(&mut d, RATIO, 4.0);
        set(&mut d, AUTO_GAIN, 0.0);
        // In feedback the reduction is the fixed point of `y = x - gr(y)`: a threshold of -26
        // with a -12 dBFS tone lands on 6 dB.
        set(&mut d, THRESHOLD, -26.0);
        d.reset();
        let amplitude = 10f32.powf(-12.0 / 20.0);
        let input = stereo(&sine(1_000.0, SR, SR as usize * 2, amplitude));
        let out = left(&render(&mut d, &input, &[512]));
        let tail = &out[out.len() - SR as usize..];
        let reduction = -20.0 * (tone_amplitude(tail, 1_000.0, SR) / amplitude).log10();
        assert!((reduction - 6.0).abs() < 1.0, "reduction {reduction:.2} dB");
        let bins = spectrum_db(tail);
        let bin = |k: usize| bins[k * 1_000 * tail.len() / SR as usize];
        let fundamental = bin(1);
        let harmonics: f32 = (2..=8)
            .map(|k| 10f32.powf(bin(k) / 10.0))
            .sum::<f32>()
            .sqrt();
        let thd = 100.0 * harmonics / 10f32.powf(fundamental / 20.0);
        assert!(thd < 1.0, "THD {thd:.2} %");
    }

    #[test]
    fn dynamics_records_decode_to_the_expected_count() {
        let mut d = device();
        assert!(d.subscribe_data("spectrum").is_err());
        d.subscribe_data("dynamics").unwrap();
        set(&mut d, THRESHOLD, -20.0);
        set(&mut d, RATIO, 4.0);
        let frames = SR as usize * 2;
        let input = stereo(&sine(1_000.0, SR, frames, 0.3));
        let mut records = 0usize;
        let mut blobs = 0usize;
        for block in input.chunks(512 * 2) {
            let mut out = vec![0.0; block.len()];
            d.process_block(block, &mut out, block.len() / 2);
            while let Some((kind, bytes)) = d.poll_device_data() {
                assert_eq!(kind, "dynamics");
                let count = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
                assert_eq!(bytes.len(), 4 + count * RECORD_BYTES + SUMMARY_FLOATS * 4);
                let values: Vec<f32> = bytes[4..4 + count * RECORD_BYTES]
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
                    .collect();
                assert!(values
                    .chunks_exact(3)
                    .all(|r| r.iter().all(|v| v.is_finite())));
                assert!(
                    values.chunks_exact(3).any(|r| r[2] > 1.0),
                    "shows reduction"
                );
                records += count;
                blobs += 1;
            }
        }
        assert!(blobs >= 30, "about 20 polls a second: {blobs}");
        // The last partial poll window stays in the ring, so a handful can be outstanding.
        assert!(
            (records as i64 - (frames / RECORD_FRAMES) as i64).abs() <= RECORD_FRAMES as i64,
            "{records} records for {frames} frames"
        );
        d.unsubscribe_data("dynamics");
        assert!(d.poll_device_data().is_none());
    }

    /// Run `frames` of `input` (interleaved stereo) with the stream on and return the summary of
    /// the last blob.
    fn last_summary(d: &mut CompressorDevice, input: &[f32]) -> [f32; SUMMARY_FLOATS] {
        let mut summary = None;
        for block in input.chunks(512 * 2) {
            let mut out = vec![0.0; block.len()];
            d.process_block(block, &mut out, block.len() / 2);
            while let Some((_, bytes)) = d.poll_device_data() {
                let count = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
                let tail = &bytes[4 + count * RECORD_BYTES..];
                assert_eq!(
                    tail.len(),
                    SUMMARY_FLOATS * 4,
                    "summary follows the records"
                );
                let mut values = [0.0; SUMMARY_FLOATS];
                for (v, b) in values.iter_mut().zip(tail.chunks_exact(4)) {
                    *v = f32::from_le_bytes(b.try_into().unwrap());
                }
                summary = Some(values);
            }
        }
        summary.expect("at least one poll")
    }

    #[test]
    fn summary_reports_hard_panned_peaks_per_side() {
        let mut d = device();
        d.subscribe_data("dynamics").unwrap();
        set(&mut d, THRESHOLD, 0.0);
        let frames = SR as usize;
        let mono = sine(1_000.0, SR, frames, 0.5);
        let input: Vec<f32> = mono.iter().flat_map(|&x| [x, 0.0]).collect();
        let s = last_summary(&mut d, &input);
        let half = 20.0 * 0.5f32.log10();
        assert!((s[0] - half).abs() < 0.2, "in peak L {:.2}", s[0]);
        assert!(
            s[1] <= SILENCE_DB + 0.01,
            "in peak R is silent: {:.2}",
            s[1]
        );
        assert!((s[2] - half).abs() < 0.5, "out peak L {:.2}", s[2]);
        assert!(
            s[3] <= SILENCE_DB + 0.01,
            "out peak R is silent: {:.2}",
            s[3]
        );
        assert!(s[5] <= SILENCE_DB + 0.01, "in rms R is silent: {:.2}", s[5]);
        assert!(
            s[9] < 0.1,
            "no reduction above a 0 dB threshold: {:.2}",
            s[9]
        );
    }

    #[test]
    fn summary_rms_of_a_sine_is_three_db_below_its_peak() {
        let mut d = device();
        d.subscribe_data("dynamics").unwrap();
        let input = stereo(&sine(1_000.0, SR, SR as usize, 0.5));
        let s = last_summary(&mut d, &input);
        assert!(
            ((s[0] - s[4]) - 3.01).abs() < 0.3,
            "peak {:.2} rms {:.2}",
            s[0],
            s[4]
        );
        assert!(
            ((s[2] - s[6]) - 3.01).abs() < 0.3,
            "out peak {:.2} rms {:.2}",
            s[2],
            s[6]
        );
    }

    #[test]
    fn summary_detector_level_follows_what_the_gain_computer_sees() {
        let mut d = device();
        d.subscribe_data("dynamics").unwrap();
        set(&mut d, THRESHOLD, -30.0);
        set(&mut d, RATIO, 4.0);
        let input = stereo(&sine(1_000.0, SR, SR as usize, 0.25));
        let s = last_summary(&mut d, &input);
        let expected = 20.0 * 0.25f32.log10();
        assert!(
            (s[8] - expected).abs() < 1.0,
            "detector {:.2} dB, input peak {expected:.2}",
            s[8]
        );
        assert!(s[9] > 5.0, "reduction reported: {:.2}", s[9]);
        // A 2 kHz sidechain low cut lowers what the detector sees but not the input peak.
        let mut cut = device();
        cut.subscribe_data("dynamics").unwrap();
        set(&mut cut, THRESHOLD, -30.0);
        set(&mut cut, SC_LOW_CUT, 2_000.0);
        let low = stereo(&sine(100.0, SR, SR as usize, 0.25));
        let s = last_summary(&mut cut, &low);
        assert!(
            s[8] < s[0] - 10.0,
            "detector {:.2} below input {:.2}",
            s[8],
            s[0]
        );
    }

    #[test]
    fn every_rate_and_channel_mode_stays_finite() {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            for channels in 0..3 {
                let mut d = CompressorDevice::new(rate);
                d.prepare(rate, 512);
                set(&mut d, CHANNELS, channels as f32);
                set(&mut d, RATIO, 30.0);
                set(&mut d, KNEE, 24.0);
                let input = stereo(&white_noise(rate as usize / 4, 0.5, 3));
                assert!(render(&mut d, &input, &[512]).iter().all(|x| x.is_finite()));
            }
        }
    }

    #[test]
    fn range_caps_the_reduction() {
        let mut d = device();
        set(&mut d, RANGE, 3.0);
        set(&mut d, THRESHOLD, -40.0);
        set(&mut d, RATIO, 10.0);
        set(&mut d, KNEE, 0.0);
        set(&mut d, AUTO_GAIN, 0.0);
        let got = steady_out_db(&mut d, 1_000.0, 0.0, 3.0);
        assert!(
            (got + 3.0).abs() < 0.3,
            "capped at {got:.2} dB of reduction"
        );
    }

    #[test]
    fn auto_gain_adds_half_the_reduction_at_full_scale() {
        // threshold -18, ratio 4: gr(0 dBFS) = 18 * 0.75 = 13.5 dB, so +6.75 dB of makeup.
        let mut d = device();
        set(&mut d, KNEE, 0.0);
        set(&mut d, AUTO_GAIN, 1.0);
        set(&mut d, THRESHOLD, -18.0);
        set(&mut d, RATIO, 4.0);
        // A signal well below the threshold is untouched, so its level shows the makeup.
        let got = steady_out_db(&mut d, 1_000.0, -50.0, 2.0);
        assert!(
            (got + 50.0 - 6.75).abs() < 0.3,
            "{:.3} dB of auto gain",
            got + 50.0
        );
    }

    #[test]
    fn disabled_device_passes_audio_through() {
        let mut d = device();
        d.set_enabled(false);
        let input = stereo(&white_noise(1_000, 0.5, 2));
        assert_eq!(render(&mut d, &input, &[100]), input);
    }

    /// Stereo, 48 kHz, all four styles in turn, with the view's data stream running. Run in
    /// release: `cargo test --release --lib compressor::tests::cpu_comp -- --ignored --nocapture`.
    #[test]
    #[ignore = "CPU measurement; run in release"]
    fn cpu_comp() {
        let mut d = device();
        d.subscribe_data("dynamics").unwrap();
        let seconds = 10.0;
        let input = stereo(&white_noise((SR * seconds) as usize, 0.3, 8));
        let start = std::time::Instant::now();
        let out = render(&mut d, &input, &[512]);
        let elapsed = start.elapsed().as_secs_f32();
        assert!(out.iter().all(|x| x.is_finite()));
        assert!(peak(&out) < 4.0);
        let cpu = elapsed / seconds * 100.0;
        println!("Compressor, stereo, data stream: {cpu:.3} % of a core");
        assert!(cpu < 0.3, "{cpu:.3} % of a core");
    }
}
