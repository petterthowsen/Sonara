//! EQ (`sonara.builtin.eq`, spec 012 Phase 2): eight bands, each a Bell, shelf, cut, notch,
//! band pass or tilt, with an analyser stream for the view.
//!
//! - Parameter IDs: band *n* (0..8) owns `n*10 .. n*10+7`; Output is at 80.
//! - Each band is a [`BandFilter`]: up to four Simper SVF stages (`dsp/linear_svf.rs`) plus an
//!   optional one-pole (`dsp/one_pole.rs`), designed by one function that the device and the
//!   analytic [`BandFilter::magnitude_db`] share. The Godot curve (`EqResponse.gd`) repeats the
//!   same design, and `eq_response.json` (see the ignored fixture test) keeps the two honest.
//! - Coefficients are recomputed every [`CHUNK`] frames while something moves, at chunk
//!   boundaries counted from the device's first frame, so the output doesn't depend on how the
//!   host splits blocks. Steady bands cost nothing to update; disabled bands cost nothing.
//! - Mid and Side bands work on `m = (l+r)/2` or `s = (l-r)/2` and add the change back to both
//!   channels. That is exactly an M/S encode, filter and decode, but it keeps the bands in
//!   order without a separate encode and decode pass.

use super::effect::{pass_through, TailSleep};
use super::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use crate::audio::dsp::gain::db_to_gain;
use crate::audio::dsp::linear_svf::{LinearSvf, SvfCoefs, SvfShape};
use crate::audio::dsp::one_pole::{one_pole_g, one_pole_magnitude_db, OnePole};
use crate::audio::dsp::spectrum::Spectrum;
use std::f32::consts::FRAC_1_SQRT_2;

pub const DEVICE_ID: &str = "sonara.builtin.eq";

pub const BAND_COUNT: usize = 8;
/// Frames between coefficient updates.
pub const CHUNK: usize = 32;
const MAX_SVF_STAGES: usize = 4;

// Offsets inside a band's block of ten IDs.
pub const ENABLED: ParamId = 0;
pub const TYPE: ParamId = 1;
pub const FREQ: ParamId = 2;
pub const GAIN: ParamId = 3;
pub const Q: ParamId = 4;
pub const SLOPE: ParamId = 5;
pub const STEREO: ParamId = 6;

pub const OUTPUT_GAIN: ParamId = 80;
pub const LISTEN_BAND: ParamId = 81;

const ID_SPACE: usize = 82;
const PARAM_COUNT: usize = BAND_COUNT * 7 + 2;

const TYPES: &[&str] = &[
    "Bell",
    "Low Shelf",
    "High Shelf",
    "Low Cut",
    "High Cut",
    "Notch",
    "Band Pass",
    "Tilt",
];
const SLOPES: &[&str] = &[
    "6 dB/oct",
    "12 dB/oct",
    "18 dB/oct",
    "24 dB/oct",
    "36 dB/oct",
    "48 dB/oct",
];
const STEREO_MODES: &[&str] = &["Stereo", "Left", "Right", "Mid", "Side"];
const LISTEN_CHOICES: &[&str] = &["Off", "1", "2", "3", "4", "5", "6", "7", "8"];

const SLOPE_DEFAULT: f32 = 1.0;
const Q_DEFAULT: f32 = 0.71;

macro_rules! band_specs {
    ($base:expr, $module:literal, $type:expr, $freq:expr) => {
        [
            spec($base + ENABLED, "Enabled", $module, "", Kind::Bool, 0.0),
            spec($base + TYPE, "Type", $module, "", Kind::Enum(TYPES), $type),
            spec(
                $base + FREQ,
                "Freq",
                $module,
                "Hz",
                log(20.0, 20_000.0),
                $freq,
            ),
            spec(
                $base + GAIN,
                "Gain",
                $module,
                "dB",
                linear(-24.0, 24.0),
                0.0,
            ),
            spec($base + Q, "Q", $module, "", log(0.1, 30.0), Q_DEFAULT),
            spec(
                $base + SLOPE,
                "Slope",
                $module,
                "",
                Kind::Enum(SLOPES),
                SLOPE_DEFAULT,
            ),
            spec(
                $base + STEREO,
                "Stereo",
                $module,
                "",
                Kind::Enum(STEREO_MODES),
                0.0,
            ),
        ]
    };
}

const BAND1: [ParamSpec; 7] = band_specs!(0, "Band 1", 3.0, 50.0);
const BAND2: [ParamSpec; 7] = band_specs!(10, "Band 2", 0.0, 110.0);
const BAND3: [ParamSpec; 7] = band_specs!(20, "Band 3", 0.0, 240.0);
const BAND4: [ParamSpec; 7] = band_specs!(30, "Band 4", 0.0, 520.0);
const BAND5: [ParamSpec; 7] = band_specs!(40, "Band 5", 0.0, 1_150.0);
const BAND6: [ParamSpec; 7] = band_specs!(50, "Band 6", 0.0, 2_500.0);
const BAND7: [ParamSpec; 7] = band_specs!(60, "Band 7", 0.0, 5_500.0);
const BAND8: [ParamSpec; 7] = band_specs!(70, "Band 8", 4.0, 12_000.0);
const OUTPUT_SPECS: [ParamSpec; 2] = [
    spec(
        OUTPUT_GAIN,
        "Gain",
        "Output",
        "dB",
        linear(-24.0, 24.0),
        0.0,
    ),
    // The view sets it while a node is held; it isn't project state worth automating.
    spec(
        LISTEN_BAND,
        "Listen Band",
        "Output",
        "",
        Kind::Enum(LISTEN_CHOICES),
        0.0,
    )
    .hidden()
    .not_automatable(),
];

pub const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[
    &BAND1,
    &BAND2,
    &BAND3,
    &BAND4,
    &BAND5,
    &BAND6,
    &BAND7,
    &BAND8,
    &OUTPUT_SPECS,
]);
const SLOT_OF: [u8; ID_SPACE] = slot_table(&SPECS);
pub static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOT_OF);

// === Filter design (shared by the device and the analytic response) ===

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BandKind {
    Bell,
    LowShelf,
    HighShelf,
    LowCut,
    HighCut,
    Notch,
    BandPass,
    Tilt,
}

impl BandKind {
    pub fn from_index(index: usize) -> Self {
        match index {
            0 => Self::Bell,
            1 => Self::LowShelf,
            2 => Self::HighShelf,
            3 => Self::LowCut,
            4 => Self::HighCut,
            5 => Self::Notch,
            6 => Self::BandPass,
            _ => Self::Tilt,
        }
    }
}

/// Butterworth section Qs for each slope (6, 12, 18, 24, 36, 48 dB/oct), lowest Q first. An odd
/// order adds a one-pole ([`CUT_HAS_POLE`]).
const CUT_Q: [&[f32]; 6] = [
    &[],
    &[FRAC_1_SQRT_2],
    &[1.0],
    &[0.541_196_1, 1.306_563],
    &[0.517_638_1, FRAC_1_SQRT_2, 1.931_851_7],
    &[0.509_795_6, 0.601_344_9, 0.899_976_2, 2.562_915_4],
];
const CUT_HAS_POLE: [bool; 6] = [true, false, true, false, false, false];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pole {
    None,
    Low,
    High,
}

/// One band's filter at one setting.
#[derive(Clone, Copy, Debug)]
pub struct BandFilter {
    svf: [SvfCoefs; MAX_SVF_STAGES],
    stages: usize,
    pole: Pole,
    pole_g: f32,
    /// Output scale: a band pass is normalised to 0 dB at its peak (the raw SVF peaks at Q).
    scale: f32,
}

impl BandFilter {
    /// `freq` in Hz, `gain_db` (Bell, shelves, Tilt), `q`, and `slope` as an index into
    /// 6/12/18/24/36/48 dB/oct (cuts only).
    pub fn new(
        kind: BandKind,
        freq: f32,
        gain_db: f32,
        q: f32,
        slope: usize,
        sample_rate: f32,
    ) -> Self {
        let blank = SvfCoefs::new(SvfShape::Bell, 1_000.0, 1.0, 0.0, sample_rate);
        let mut filter = Self {
            svf: [blank; MAX_SVF_STAGES],
            stages: 0,
            pole: Pole::None,
            pole_g: 0.0,
            scale: 1.0,
        };
        let mut push = |f: &mut Self, shape: SvfShape, q: f32, gain: f32| {
            f.svf[f.stages] = SvfCoefs::new(shape, freq, q, gain, sample_rate);
            f.stages += 1;
        };
        match kind {
            BandKind::Bell => push(&mut filter, SvfShape::Bell, q, gain_db),
            BandKind::LowShelf => push(&mut filter, SvfShape::LowShelf, q, gain_db),
            BandKind::HighShelf => push(&mut filter, SvfShape::HighShelf, q, gain_db),
            BandKind::Notch => push(&mut filter, SvfShape::Notch, q, 0.0),
            BandKind::BandPass => {
                push(&mut filter, SvfShape::BandPass, q, 0.0);
                filter.scale = filter.svf[0].k;
            }
            BandKind::Tilt => {
                // Positive gain tilts towards the highs: half the gain each way around `freq`.
                push(&mut filter, SvfShape::LowShelf, q, -gain_db * 0.5);
                push(&mut filter, SvfShape::HighShelf, q, gain_db * 0.5);
            }
            BandKind::LowCut | BandKind::HighCut => {
                let high = kind == BandKind::LowCut;
                let slope = slope.min(CUT_Q.len() - 1);
                if CUT_HAS_POLE[slope] {
                    filter.pole = if high { Pole::High } else { Pole::Low };
                    filter.pole_g = one_pole_g(freq, sample_rate);
                }
                let qs = CUT_Q[slope];
                for (i, &stage_q) in qs.iter().enumerate() {
                    // The Q knob sets the corner's resonance: it scales the sharpest section.
                    let stage_q = if i + 1 == qs.len() {
                        stage_q * q / FRAC_1_SQRT_2
                    } else {
                        stage_q
                    };
                    let shape = if high {
                        SvfShape::HighPass
                    } else {
                        SvfShape::LowPass
                    };
                    push(&mut filter, shape, stage_q, 0.0);
                }
            }
        }
        filter
    }

    /// Exact magnitude in dB at `freq`: the sum of the stages' responses.
    pub fn magnitude_db(&self, freq: f32, sample_rate: f32) -> f32 {
        let mut db = 0.0;
        if self.pole != Pole::None {
            db += one_pole_magnitude_db(self.pole_g, self.pole == Pole::High, freq, sample_rate);
        }
        for stage in &self.svf[..self.stages] {
            db += stage.magnitude_db(freq, sample_rate);
        }
        db + 20.0 * self.scale.log10()
    }
}

/// Analytic magnitude in dB of one band at `at_hz`.
pub fn band_magnitude_db(
    kind: BandKind,
    freq: f32,
    gain_db: f32,
    q: f32,
    slope: usize,
    sample_rate: f32,
    at_hz: f32,
) -> f32 {
    BandFilter::new(kind, freq, gain_db, q, slope, sample_rate).magnitude_db(at_hz, sample_rate)
}

// === Runtime state ===

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StereoMode {
    Stereo,
    Left,
    Right,
    Mid,
    Side,
}

impl StereoMode {
    fn from_index(index: usize) -> Self {
        match index {
            1 => Self::Left,
            2 => Self::Right,
            3 => Self::Mid,
            4 => Self::Side,
            _ => Self::Stereo,
        }
    }
}

/// What the parameters ask for.
#[derive(Clone, Copy)]
struct BandTarget {
    enabled: bool,
    kind: BandKind,
    freq: f32,
    gain_db: f32,
    q: f32,
    slope: usize,
    stereo: StereoMode,
}

/// The parts of a band that change its filter structure: switching them crossfades the band out
/// and back in over two short ramps instead of jumping.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Structure {
    kind: BandKind,
    slope: usize,
    stereo: StereoMode,
}

struct BandRuntime {
    live: Structure,
    // Smoothed values (frequency and Q in the log domain).
    ln_freq: f32,
    gain_db: f32,
    ln_q: f32,
    level: f32,
    level_start: f32,
    active: bool,
    /// Coefficients need recomputing before the next use.
    stale: bool,
    filter: BandFilter,
    svf: [[LinearSvf; MAX_SVF_STAGES]; 2],
    pole: [OnePole; 2],
}

impl BandRuntime {
    fn new(target: &BandTarget, sample_rate: f32) -> Self {
        Self {
            live: Structure {
                kind: target.kind,
                slope: target.slope,
                stereo: target.stereo,
            },
            ln_freq: target.freq.ln(),
            gain_db: target.gain_db,
            ln_q: target.q.ln(),
            level: 0.0,
            level_start: 0.0,
            active: false,
            stale: true,
            filter: BandFilter::new(
                target.kind,
                target.freq,
                0.0,
                target.q,
                target.slope,
                sample_rate,
            ),
            svf: [[LinearSvf::new(); MAX_SVF_STAGES]; 2],
            pole: [OnePole::new(); 2],
        }
    }

    fn clear_state(&mut self) {
        self.svf = [[LinearSvf::new(); MAX_SVF_STAGES]; 2];
        self.pole = [OnePole::new(); 2];
    }

    fn build_filter(&mut self, sample_rate: f32) {
        self.filter = BandFilter::new(
            self.live.kind,
            self.ln_freq.exp(),
            self.gain_db,
            self.ln_q.exp(),
            self.live.slope,
            sample_rate,
        );
    }

    /// One channel through the band's stages.
    #[inline]
    fn run(&mut self, channel: usize, x: f32) -> f32 {
        let mut y = x;
        match self.filter.pole {
            Pole::None => {}
            Pole::Low => y = self.pole[channel].lowpass(y, self.filter.pole_g),
            Pole::High => y = self.pole[channel].highpass(y, self.filter.pole_g),
        }
        for stage in 0..self.filter.stages {
            y = self.svf[channel][stage].process(y, &self.filter.svf[stage]);
        }
        y * self.filter.scale
    }
}

pub struct EqDevice {
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,
    targets: [BandTarget; BAND_COUNT],
    bands: [BandRuntime; BAND_COUNT],
    /// Position in the current chunk (0 = a new chunk starts with the next frame).
    phase: usize,
    smooth: f32,
    level_step: f32,

    out_target_db: f32,
    out_db: f32,
    out_start: f32,
    out_end: f32,

    listen: usize,
    listen_level: f32,
    listen_start: f32,
    listen_band: usize,
    listen_coefs: SvfCoefs,
    listen_svf: [LinearSvf; 2],

    enabled: bool,
    sleep: TailSleep,

    // Analyser
    subscribed: bool,
    pre: Spectrum,
    post: Spectrum,
    frames_since_poll: usize,
    poll_interval: usize,
    send_post_next: bool,
}

/// FFT size and smoothing of the analyser frames.
const ANALYSER_FFT: usize = 4096;
const ANALYSER_SMOOTHING: f32 = 0.6;
/// Frames of the analyser stream start with `[flag, sample_rate]`: flag 0 = pre, 1 = post.
pub const SPECTRUM_HEADER_LEN: usize = 2;
/// Frames per second for each of pre and post.
const ANALYSER_RATE_HZ: f32 = 20.0;
const RAMP_SECONDS: f32 = 0.005;
/// Ringing time after input stops, for sleep.
const TAIL_SECONDS: f32 = 1.0;

impl EqDevice {
    pub fn new(sample_rate: f32) -> Self {
        let values = ParamValues::<PARAM_COUNT>::new(&TABLE);
        let targets: [BandTarget; BAND_COUNT] =
            std::array::from_fn(|band| decode_band(&values, band));
        let bands = std::array::from_fn(|i| BandRuntime::new(&targets[i], sample_rate));
        let mut sleep = TailSleep::new(sample_rate);
        sleep.set_tail_seconds(Some(TAIL_SECONDS));
        let mut device = Self {
            sample_rate,
            values,
            targets,
            bands,
            phase: 0,
            smooth: 0.0,
            level_step: 0.0,
            out_target_db: 0.0,
            out_db: 0.0,
            out_start: 1.0,
            out_end: 1.0,
            listen: 0,
            listen_level: 0.0,
            listen_start: 0.0,
            listen_band: 0,
            listen_coefs: SvfCoefs::new(SvfShape::BandPass, 1_000.0, 1.0, 0.0, sample_rate),
            listen_svf: [LinearSvf::new(); 2],
            enabled: true,
            sleep,
            subscribed: false,
            pre: Spectrum::new(ANALYSER_FFT, ANALYSER_SMOOTHING),
            post: Spectrum::new(ANALYSER_FFT, ANALYSER_SMOOTHING),
            frames_since_poll: 0,
            poll_interval: 0,
            send_post_next: false,
        };
        device.configure_rate(sample_rate);
        device.snap_all();
        device
    }

    fn configure_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
        let chunk_seconds = CHUNK as f32 / sample_rate;
        self.smooth = 1.0 - (-chunk_seconds / RAMP_SECONDS).exp();
        self.level_step = chunk_seconds / RAMP_SECONDS;
        self.poll_interval = (sample_rate / (ANALYSER_RATE_HZ * 2.0)) as usize;
        self.sleep.set_sample_rate(sample_rate);
    }

    /// Jump every smoothed value to its target and clear all filter state.
    fn snap_all(&mut self) {
        for (band, target) in self.bands.iter_mut().zip(&self.targets) {
            band.live = Structure {
                kind: target.kind,
                slope: target.slope,
                stereo: target.stereo,
            };
            band.ln_freq = target.freq.ln();
            band.gain_db = target.gain_db;
            band.ln_q = target.q.ln();
            band.level = if target.enabled { 1.0 } else { 0.0 };
            band.level_start = band.level;
            band.stale = true;
            band.clear_state();
        }
        self.out_db = self.out_target_db;
        let gain = db_to_gain(self.out_db);
        self.out_start = gain;
        self.out_end = gain;
        self.listen_level = if self.listen > 0 { 1.0 } else { 0.0 };
        self.listen_start = self.listen_level;
        self.listen_svf = [LinearSvf::new(); 2];
        self.phase = 0;
    }

    /// Advance the smoothers by one chunk and rebuild what moved.
    fn begin_chunk(&mut self) {
        let sample_rate = self.sample_rate;
        for (band, target) in self.bands.iter_mut().zip(&self.targets) {
            let wanted = Structure {
                kind: target.kind,
                slope: target.slope,
                stereo: target.stereo,
            };
            band.level_start = band.level;
            let mut want_level = if target.enabled { 1.0 } else { 0.0 };
            if wanted != band.live {
                if band.level > 0.0 {
                    want_level = 0.0; // fade out first, switch at zero
                } else {
                    band.live = wanted;
                    band.clear_state();
                    band.stale = true;
                }
            }
            band.level += (want_level - band.level).clamp(-self.level_step, self.level_step);

            let target_ln_freq = target.freq.ln();
            let target_ln_q = target.q.ln();
            if band.level_start == 0.0 && band.level == 0.0 {
                // Idle: follow the targets exactly and keep the state clean.
                if band.ln_freq != target_ln_freq
                    || band.gain_db != target.gain_db
                    || band.ln_q != target_ln_q
                {
                    band.ln_freq = target_ln_freq;
                    band.gain_db = target.gain_db;
                    band.ln_q = target_ln_q;
                    band.stale = true;
                }
                if band.active {
                    band.clear_state();
                }
                band.active = false;
                continue;
            }
            band.active = true;
            let smooth = self.smooth;
            let mut moved = false;
            let mut follow = |current: &mut f32, goal: f32, eps: f32| {
                if *current != goal {
                    *current += (goal - *current) * smooth;
                    if (goal - *current).abs() < eps {
                        *current = goal;
                    }
                    moved = true;
                }
            };
            follow(&mut band.ln_freq, target_ln_freq, 1e-5);
            follow(&mut band.gain_db, target.gain_db, 1e-4);
            follow(&mut band.ln_q, target_ln_q, 1e-5);
            if moved || band.stale {
                band.build_filter(sample_rate);
                band.stale = false;
            }
        }

        // Output gain.
        self.out_start = self.out_end;
        if self.out_db != self.out_target_db {
            self.out_db += (self.out_target_db - self.out_db) * self.smooth;
            if (self.out_target_db - self.out_db).abs() < 1e-4 {
                self.out_db = self.out_target_db;
            }
        }
        self.out_end = db_to_gain(self.out_db);

        // Listen.
        self.listen_start = self.listen_level;
        let want = if self.listen > 0 { 1.0 } else { 0.0 };
        self.listen_level += (want - self.listen_level).clamp(-self.level_step, self.level_step);
        if self.listen > 0 {
            self.listen_band = self.listen - 1;
        }
        if self.listen_start > 0.0 || self.listen_level > 0.0 {
            let band = &self.bands[self.listen_band];
            self.listen_coefs = SvfCoefs::new(
                SvfShape::BandPass,
                band.ln_freq.exp(),
                band.ln_q.exp(),
                0.0,
                self.sample_rate,
            );
        } else {
            self.listen_svf = [LinearSvf::new(); 2];
        }
    }

    #[inline]
    fn process_frame(&mut self, in_l: f32, in_r: f32, t: f32) -> (f32, f32) {
        let (mut l, mut r) = (in_l, in_r);
        for band in self.bands.iter_mut() {
            if !band.active {
                continue;
            }
            let level = if band.level == band.level_start {
                band.level
            } else {
                band.level_start + (band.level - band.level_start) * t
            };
            // At full level the band's output replaces the input (no blend rounding).
            let full = level == 1.0;
            match band.live.stereo {
                StereoMode::Stereo => {
                    let fl = band.run(0, l);
                    let fr = band.run(1, r);
                    if full {
                        l = fl;
                        r = fr;
                    } else {
                        l += level * (fl - l);
                        r += level * (fr - r);
                    }
                }
                StereoMode::Left => {
                    let fl = band.run(0, l);
                    l = if full { fl } else { l + level * (fl - l) };
                }
                StereoMode::Right => {
                    let fr = band.run(1, r);
                    r = if full { fr } else { r + level * (fr - r) };
                }
                StereoMode::Mid => {
                    let m = (l + r) * 0.5;
                    let delta = level * (band.run(0, m) - m);
                    l += delta;
                    r += delta;
                }
                StereoMode::Side => {
                    let s = (l - r) * 0.5;
                    let delta = level * (band.run(0, s) - s);
                    l += delta;
                    r -= delta;
                }
            }
        }
        let listen = self.listen_start + (self.listen_level - self.listen_start) * t;
        if self.listen_start > 0.0 || self.listen_level > 0.0 {
            // Unity at the peak: the raw band output peaks at Q.
            let k = self.listen_coefs.k;
            let bl = self.listen_svf[0].process(in_l, &self.listen_coefs) * k;
            let br = self.listen_svf[1].process(in_r, &self.listen_coefs) * k;
            l += listen * (bl - l);
            r += listen * (br - r);
        }
        if self.out_start != 1.0 || self.out_end != 1.0 {
            let gain = self.out_start + (self.out_end - self.out_start) * t;
            l *= gain;
            r *= gain;
        }
        (l, r)
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        if id == OUTPUT_GAIN {
            self.out_target_db = real;
        } else if id == LISTEN_BAND {
            self.listen = real as usize;
        } else if (id as usize) < BAND_COUNT * 10 {
            let band = id as usize / 10;
            self.targets[band] = decode_band(&self.values, band);
        }
    }

    /// Band `band`'s settings as the analytic filter, for tests and tools.
    pub fn band_filter(&self, band: usize) -> BandFilter {
        let t = &self.targets[band];
        BandFilter::new(t.kind, t.freq, t.gain_db, t.q, t.slope, self.sample_rate)
    }
}

fn decode_band(values: &ParamValues<PARAM_COUNT>, band: usize) -> BandTarget {
    let base = band as ParamId * 10;
    let real = |offset: ParamId| values.real(base + offset).unwrap_or(0.0);
    BandTarget {
        enabled: real(ENABLED) >= 0.5,
        kind: BandKind::from_index(real(TYPE) as usize),
        freq: real(FREQ),
        gain_db: real(GAIN),
        q: real(Q),
        slope: real(SLOPE) as usize,
        stereo: StereoMode::from_index(real(STEREO) as usize),
    }
}

impl AudioDevice for EqDevice {
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
                let (l, r) = self.process_frame(inputs[frame], inputs[frame + 1], t);
                outputs[frame] = l;
                outputs[frame + 1] = r;
            }
            self.phase += run;
            if self.phase == CHUNK {
                self.phase = 0;
            }
            i += run;
        }
        if self.subscribed {
            for frame in 0..n {
                let k = frame * 2;
                self.pre.push((inputs[k] + inputs[k + 1]) * 0.5);
                self.post.push((outputs[k] + outputs[k + 1]) * 0.5);
            }
            self.frames_since_poll += n;
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        if let Some((_, real)) = self.values.set(param_id, value) {
            self.apply(param_id, real);
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
        "EQ"
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
        self.pre.reset();
        self.post.reset();
        self.frames_since_poll = 0;
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
        // While the view watches, keep running so the analyser decays instead of freezing.
        self.sleep.update(has_audio_activity || self.subscribed)
    }

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if data_type != "spectrum" {
            return Err(format!("EQ does not support '{data_type}' data"));
        }
        if !self.subscribed {
            self.pre.reset();
            self.post.reset();
            self.frames_since_poll = 0;
            self.subscribed = true;
        }
        self.sleep.wake();
        Ok(())
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "spectrum" {
            self.subscribed = false;
        }
    }

    /// Alternates a pre and a post frame, each 20 times a second:
    /// `[flag, sample_rate, bins…]` as little-endian f32 (flag 0 = pre, 1 = post).
    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        if !self.subscribed || self.frames_since_poll < self.poll_interval {
            return None;
        }
        self.frames_since_poll = 0;
        let post = self.send_post_next;
        self.send_post_next = !post;
        let spectrum = if post { &mut self.post } else { &mut self.pre };
        spectrum.compute(self.sample_rate);
        let bins = spectrum.smoothed();
        let mut bytes = Vec::with_capacity((SPECTRUM_HEADER_LEN + bins.len()) * 4);
        bytes.extend_from_slice(&(post as u8 as f32).to_le_bytes());
        bytes.extend_from_slice(&self.sample_rate.to_le_bytes());
        for value in bins {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        Some(("spectrum".to_string(), bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{
        interleave, left, peak, pink_noise, render, right, sine, stereo, tone_amplitude,
        white_noise,
    };

    const SR: f32 = 48_000.0;

    fn device() -> EqDevice {
        let mut d = EqDevice::new(SR);
        d.prepare(SR, 4096);
        d
    }

    fn set(d: &mut EqDevice, id: ParamId, real: f32) {
        let norm = TABLE.spec(id).unwrap().to_norm(real);
        d.set_parameter(id, norm);
    }

    fn configure(
        d: &mut EqDevice,
        band: usize,
        kind: usize,
        freq: f32,
        gain: f32,
        q: f32,
        slope: usize,
    ) {
        let base = band as ParamId * 10;
        set(d, base + ENABLED, 1.0);
        set(d, base + TYPE, kind as f32);
        set(d, base + FREQ, freq);
        set(d, base + GAIN, gain);
        set(d, base + Q, q);
        set(d, base + SLOPE, slope as f32);
    }

    /// Steady-state gain in dB of a sine through the device (measured over the last half second,
    /// a whole number of cycles for multiples of 2 Hz).
    fn measured_db(d: &mut EqDevice, freq: f32) -> f32 {
        d.reset();
        let input = stereo(&sine(freq, SR, SR as usize, 0.25));
        let out = left(&render(d, &input, &[512]));
        let tail = SR as usize / 2;
        let got = tone_amplitude(&out[out.len() - tail..], freq, SR);
        20.0 * (got / 0.25).log10()
    }

    #[test]
    fn table_has_the_documented_layout() {
        assert_eq!(TABLE.len(), 58);
        let d = device();
        let infos = d.parameters();
        let info = |id: ParamId| infos.iter().find(|p| p.id == id).unwrap();
        assert_eq!(info(0).module, "Band 1");
        assert_eq!(info(73).name, "Gain");
        assert_eq!(info(0 + TYPE).default, 3.0, "band 1 starts as a Low Cut");
        assert_eq!(info(70 + TYPE).default, 4.0, "band 8 starts as a High Cut");
        assert!(info(LISTEN_BAND).is_hidden && !info(LISTEN_BAND).is_automation_safe);
        assert_eq!(d.get_parameter(ENABLED), Some(0.0));
    }

    #[test]
    fn every_type_measures_like_its_analytic_response() {
        let mut d = device();
        for kind in 0..TYPES.len() {
            let (freq, gain, q) = (1_000.0, 9.0, 1.5);
            for slope in [1usize, 3] {
                d.set_parameter(ENABLED, 0.0);
                configure(&mut d, 0, kind, freq, gain, q, slope);
                let filter = d.band_filter(0);
                for f in [100.0, 500.0, 900.0, 1_000.0, 1_100.0, 2_000.0, 8_000.0] {
                    let expected = filter.magnitude_db(f, SR);
                    if expected < -50.0 {
                        continue; // below the measurement floor
                    }
                    let got = measured_db(&mut d, f);
                    assert!(
                        (expected - got).abs() < 0.1,
                        "{} slope {slope} at {f} Hz: expected {expected:.3} dB, measured {got:.3}",
                        TYPES[kind]
                    );
                }
            }
        }
    }

    #[test]
    fn cut_slopes_are_nominal_one_octave_past_the_corner() {
        let mut d = device();
        for (kind, name) in [(3usize, "Low Cut"), (4, "High Cut")] {
            for (slope, db_per_oct) in [6.0f32, 12.0, 18.0, 24.0, 36.0, 48.0].iter().enumerate() {
                d.set_parameter(ENABLED, 0.0);
                configure(&mut d, 0, kind, 1_000.0, 0.0, FRAC_1_SQRT_2, slope);
                // One and two octaves past the corner.
                let (near, far) = if kind == 3 {
                    (500.0, 250.0)
                } else {
                    (2_000.0, 4_000.0)
                };
                let measured = measured_db(&mut d, near) - measured_db(&mut d, far);
                assert!(
                    (measured - db_per_oct).abs() <= 1.5,
                    "{name} {db_per_oct} dB/oct: {measured:.2} dB between 1 and 2 octaves out"
                );
            }
        }
    }

    #[test]
    fn a_mid_band_leaves_the_side_signal_untouched() {
        let mut d = device();
        configure(&mut d, 3, 0, 800.0, 12.0, 1.0, 1);
        set(&mut d, 30 + STEREO, 3.0);
        let noise = white_noise(SR as usize / 2, 0.3, 5);
        let negated: Vec<f32> = noise.iter().map(|x| -x).collect();
        let side_only = interleave(&noise, &negated);
        let out = render(&mut d, &side_only, &[256]);
        assert_eq!(out, side_only, "pure side material passes bit-exact");

        // The same band does boost mid material.
        let mid_only = stereo(&sine(800.0, SR, SR as usize, 0.1));
        d.reset();
        let out = render(&mut d, &mid_only, &[256]);
        let gain = tone_amplitude(&left(&out)[SR as usize / 2..], 800.0, SR)
            / tone_amplitude(&left(&mid_only)[SR as usize / 2..], 800.0, SR);
        assert!((20.0 * gain.log10() - 12.0).abs() < 0.1);
        assert_eq!(
            left(&out),
            right(&out),
            "a mid band keeps the channels equal"
        );
    }

    #[test]
    fn a_side_band_leaves_mono_material_untouched() {
        let mut d = device();
        configure(&mut d, 2, 0, 3_000.0, -9.0, 2.0, 1);
        set(&mut d, 20 + STEREO, 4.0);
        let mono = stereo(&white_noise(SR as usize / 2, 0.3, 9));
        assert_eq!(render(&mut d, &mono, &[128]), mono);
    }

    #[test]
    fn left_and_right_bands_touch_one_channel() {
        let mut d = device();
        configure(&mut d, 0, 0, 1_000.0, 12.0, 1.0, 1);
        set(&mut d, STEREO, 1.0);
        let input = stereo(&sine(1_000.0, SR, SR as usize, 0.1));
        let out = render(&mut d, &input, &[512]);
        assert_eq!(right(&out), right(&input));
        assert!(peak(&left(&out)) > 0.3);
    }

    #[test]
    fn all_bands_off_at_zero_db_is_bit_exact() {
        let mut d = device();
        let input = stereo(&white_noise(SR as usize, 0.8, 1));
        assert_eq!(render(&mut d, &input, &[37, 512]), input);
    }

    #[test]
    fn output_gain_scales_the_signal() {
        let mut d = device();
        set(&mut d, OUTPUT_GAIN, -6.0);
        let input = stereo(&sine(440.0, SR, SR as usize, 0.5));
        let out = left(&render(&mut d, &input, &[512]));
        let tail = &out[SR as usize / 2..];
        let got = 20.0 * (tone_amplitude(tail, 440.0, SR) / 0.5).log10();
        assert!((got + 6.0).abs() < 0.01, "{got}");
    }

    #[test]
    fn switching_a_band_on_crossfades_without_a_click() {
        let mut d = device();
        let input = stereo(&sine(100.0, SR, SR as usize / 2, 0.5));
        let half = input.len() / 2;
        let mut out = render(&mut d, &input[..half], &[512]);
        configure(&mut d, 3, 0, 100.0, 24.0, 1.0, 1);
        out.extend(render(&mut d, &input[half..], &[512]));
        let worst = left(&out)
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max);
        // A clean 100 Hz sine at 0.5 moves at most 0.5*2*pi*100/48000 ≈ 0.0065 per sample; the
        // boost grows to 16x over 5 ms, so allow the ramp's own slope.
        assert!(worst < 0.25, "largest sample step {worst}");
        // Switching the type mid-signal also avoids a step larger than the signal's peak.
        set(&mut d, 30 + TYPE, 5.0);
        let more = render(&mut d, &input, &[512]);
        assert!(peak(&more) < 20.0 && more.iter().all(|x| x.is_finite()));
    }

    #[test]
    fn listen_band_outputs_a_band_pass_at_unity() {
        let mut d = device();
        configure(&mut d, 4, 0, 2_000.0, 12.0, 4.0, 1);
        set(&mut d, LISTEN_BAND, 5.0);
        let centre = measured_db(&mut d, 2_000.0);
        assert!(centre.abs() < 0.1, "unity at the band frequency: {centre}");
        let off = measured_db(&mut d, 200.0);
        assert!(off < -20.0, "{off}");
        set(&mut d, LISTEN_BAND, 0.0);
        // Back to the EQ curve.
        let boosted = measured_db(&mut d, 2_000.0);
        assert!((boosted - 12.0).abs() < 0.1, "{boosted}");
    }

    #[test]
    fn higher_rates_and_high_frequencies_stay_finite() {
        for rate in [44_100.0, 96_000.0, 192_000.0] {
            let mut d = EqDevice::new(rate);
            d.prepare(rate, 512);
            for band in 0..BAND_COUNT {
                configure(&mut d, band, band, 19_000.0, 18.0, 25.0, 5);
            }
            let input = stereo(&white_noise(rate as usize / 4, 0.3, 3));
            assert!(render(&mut d, &input, &[512]).iter().all(|x| x.is_finite()));
        }
    }

    #[test]
    fn spectrum_frames_alternate_pre_and_post() {
        let mut d = device();
        assert!(d.subscribe_data("oscilloscope").is_err());
        d.subscribe_data("spectrum").unwrap();
        configure(&mut d, 0, 0, 1_000.0, 12.0, 1.0, 1);
        set(&mut d, 0 + TYPE, 0.0);
        let mut flags = Vec::new();
        let mut last_post = Vec::new();
        let input = stereo(&pink_noise(SR as usize, 0.3, 4));
        for block in input.chunks(512 * 2) {
            let mut out = vec![0.0; block.len()];
            d.process_block(block, &mut out, block.len() / 2);
            if let Some((kind, bytes)) = d.poll_device_data() {
                assert_eq!(kind, "spectrum");
                let values: Vec<f32> = bytes
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
                    .collect();
                assert_eq!(values.len(), SPECTRUM_HEADER_LEN + ANALYSER_FFT / 2 + 1);
                assert_eq!(values[1], SR);
                flags.push(values[0]);
                if values[0] == 1.0 {
                    last_post = values;
                }
            }
        }
        assert!(
            flags.len() >= 30,
            "about 40 frames a second: {}",
            flags.len()
        );
        assert!(flags.windows(2).all(|w| w[0] != w[1]), "{flags:?}");
        assert_eq!(flags[0], 0.0);
        assert!(last_post.iter().skip(2).any(|&db| db > -60.0));
        d.unsubscribe_data("spectrum");
        assert!(d.poll_device_data().is_none());
    }

    /// Pink noise through a +12 dB bell reads about 12 dB higher around the bell in the post
    /// analyser than in the pre analyser, which is what the view's curve promises.
    #[test]
    fn the_drawn_curve_matches_the_analyser_for_pink_noise() {
        let mut d = device();
        d.subscribe_data("spectrum").unwrap();
        configure(&mut d, 4, 0, 1_000.0, 12.0, 1.0, 1);
        let input = stereo(&pink_noise(SR as usize * 4, 0.3, 4));
        // Average the frames after the first second, so the noise's own variance settles.
        let len = ANALYSER_FFT / 2 + 1 + SPECTRUM_HEADER_LEN;
        let (mut pre, mut post) = (vec![0.0f32; len], vec![0.0f32; len]);
        let (mut pre_n, mut post_n) = (0.0f32, 0.0f32);
        for (n, block) in input.chunks(512 * 2).enumerate() {
            let mut out = vec![0.0; block.len()];
            d.process_block(block, &mut out, block.len() / 2);
            while let Some((_, bytes)) = d.poll_device_data() {
                let values: Vec<f32> = bytes
                    .chunks_exact(4)
                    .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
                    .collect();
                if n < 90 {
                    continue;
                }
                let (sum, count) = if values[0] == 0.0 {
                    (&mut pre, &mut pre_n)
                } else {
                    (&mut post, &mut post_n)
                };
                sum.iter_mut().zip(&values).for_each(|(s, v)| *s += v);
                *count += 1.0;
            }
        }
        pre.iter_mut().for_each(|v| *v /= pre_n);
        post.iter_mut().for_each(|v| *v /= post_n);
        let filter = d.band_filter(4);
        let bin_hz = SR / ANALYSER_FFT as f32;
        // Average over a band of bins to tame the noise's own variance.
        for centre in [300.0f32, 1_000.0, 3_000.0] {
            let lo = (centre * 0.9 / bin_hz) as usize + 2;
            let hi = (centre * 1.1 / bin_hz) as usize + 2;
            let mean = |v: &[f32]| v[lo..hi].iter().sum::<f32>() / (hi - lo) as f32;
            let seen = mean(&post) - mean(&pre);
            let drawn = filter.magnitude_db(centre, SR);
            assert!(
                (seen - drawn).abs() < 1.0,
                "{centre} Hz: analyser shows {seen:.2} dB, curve {drawn:.2} dB"
            );
        }
    }

    #[test]
    fn disabled_device_passes_audio_through() {
        let mut d = device();
        configure(&mut d, 0, 0, 1_000.0, 12.0, 1.0, 1);
        d.set_enabled(false);
        let input = stereo(&white_noise(1_000, 0.5, 2));
        assert_eq!(render(&mut d, &input, &[100]), input);
    }

    /// 8 bands in stereo, each in the most expensive common setting. Run in release:
    /// `cargo test --release --lib eq::tests::cpu_eq -- --ignored --nocapture`.
    #[test]
    #[ignore = "CPU measurement; run in release"]
    fn cpu_eq() {
        let mut d = device();
        for band in 0..BAND_COUNT {
            configure(
                &mut d,
                band,
                if band == 0 { 3 } else { 0 },
                200.0 * (band + 1) as f32,
                6.0,
                1.0,
                3,
            );
        }
        let seconds = 10.0;
        let input = stereo(&white_noise((SR * seconds) as usize, 0.3, 8));
        let start = std::time::Instant::now();
        let out = render(&mut d, &input, &[512]);
        let elapsed = start.elapsed().as_secs_f32();
        assert!(out.iter().all(|x| x.is_finite()));
        let cpu = elapsed / seconds * 100.0;
        println!("EQ, 8 bands stereo: {cpu:.3} % of a core");
        assert!(cpu < 0.5, "{cpu:.3} % of a core");
    }

    /// Regenerates `Godot/tests/fixtures/eq_response.json`, which `test_eq_response.gd` checks
    /// `EqResponse.gd` against: `cargo test --lib eq::tests::write_response_fixture -- --ignored`.
    #[test]
    #[ignore = "regenerates the Godot fixture"]
    fn write_response_fixture() {
        use serde_json::json;
        // (kind, freq, gain, q, slope)
        let band_settings: [(usize, f32, f32, f32, usize); 24] = [
            (0, 1_000.0, 9.0, 1.0, 1),
            (0, 250.0, -12.0, 4.0, 1),
            (0, 8_000.0, 18.0, 0.3, 1),
            (1, 200.0, 6.0, 0.71, 1),
            (1, 80.0, -9.0, 1.5, 1),
            (2, 5_000.0, 12.0, 0.71, 1),
            (2, 12_000.0, -6.0, 2.0, 1),
            (3, 100.0, 0.0, 0.71, 0),
            (3, 100.0, 0.0, 0.71, 1),
            (3, 100.0, 0.0, 1.5, 2),
            (3, 120.0, 0.0, 0.71, 3),
            (3, 120.0, 0.0, 2.0, 4),
            (3, 60.0, 0.0, 0.71, 5),
            (4, 10_000.0, 0.0, 0.71, 0),
            (4, 10_000.0, 0.0, 0.71, 1),
            (4, 8_000.0, 0.0, 1.5, 2),
            (4, 6_000.0, 0.0, 0.71, 3),
            (4, 6_000.0, 0.0, 3.0, 4),
            (4, 12_000.0, 0.0, 0.71, 5),
            (5, 1_000.0, 0.0, 4.0, 1),
            (6, 2_000.0, 0.0, 1.0, 1),
            (7, 1_000.0, 6.0, 0.71, 1),
            (7, 300.0, -12.0, 1.0, 1),
            (0, 18_000.0, 12.0, 1.0, 1),
        ];
        let freqs: Vec<f32> = (0..64)
            .map(|i| 20.0 * 1000f32.powf(i as f32 / 63.0))
            .collect();
        let mut cases = Vec::new();
        for rate in [44_100.0f32, 48_000.0, 96_000.0] {
            for &(kind, freq, gain, q, slope) in &band_settings {
                let db: Vec<f32> = freqs
                    .iter()
                    .map(|&f| {
                        band_magnitude_db(BandKind::from_index(kind), freq, gain, q, slope, rate, f)
                    })
                    .collect();
                cases.push(json!({
                    "sample_rate": rate,
                    "type": kind, "freq": freq, "gain": gain, "q": q, "slope": slope,
                    "db": db,
                }));
            }
        }
        let doc = json!({
            "comment": "Generated by the ignored Rust test eq::tests::write_response_fixture; do not edit.",
            "freqs": freqs,
            "cases": cases,
        });
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../Godot/tests/fixtures/eq_response.json");
        std::fs::write(&path, serde_json::to_string(&doc).unwrap()).unwrap();
        println!("wrote {}", path.display());
    }
}
