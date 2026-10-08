//! Sampler MIDI instrument: pitch, speed, polyphony, region, loop, per-voice filter, ADSR.
//!
//! - Every voice plays a [`Zone`]: PCM, resolved regions and per-sample settings. Single-sample
//!   mode has one implicit zone, `single`, rebuilt from the device parameters. Multisample mode
//!   (spec 023) holds up to [`MAX_ZONES`] zones sent by Godot as real-unit snapshots; at note-on
//!   [`select_zones`] picks the matching ones (ranges, group mute/solo, round robin/random) and
//!   each starts a voice keyed from the zone's root. A note-off releases every voice its note-on
//!   started. Device Root/Tune/Fine/Start/End/Reverse/Loop/Crossfade only feed `single`.
//! - Start, End, Loop Start and Loop End are stored raw (normalized over the whole file) and
//!   ordered/clamped at use time by [`resolve_regions`], so restoring a state where several of
//!   them move at once doesn't depend on the order the values arrive in.
//! - Loop Off plays Start→End (End→Start when Reverse) and ends with a short declick; it never
//!   reads past the boundary. Loop On wraps inside the loop; Ping-Pong bounces. With any loop on,
//!   note-off releases even in One-shot. Points stay in file space whatever the direction.
//! - The crossfade blends the loop's tail with the material just before Loop Start (just after
//!   Loop End when reversed). Ping-Pong is already continuous, so it ignores the crossfade.
//! - The filter runs per voice (key tracking is per note) in chunks of [`FILTER_CHUNK`] frames.
//! - Data stream `"playheads"`: `u32 count` then `count` × (`f32 position` 0–1 over the whole
//!   file, `f32 velocity` signed file-fractions per second, `f32 level` 0–1), every ~33 ms of
//!   audio, plus one `count = 0` frame when the last voice ends. In multisample mode only the
//!   focused zone's voices are listed, normalized over that zone's file.

use super::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use super::sampler_zones::{
    select_zones, velocity_to_midi, GroupPlayMode, SelectableZone, ZoneGroup, ZoneRanges,
    ZoneSettings, MAX_GROUPS, MAX_ZONES, UNGROUPED,
};
use super::{
    has_audio_signal, AudioDevice, DeviceCategory, DevicePath, DeviceSleepState, DeviceVariant,
    FileLoadingSupport, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use crate::audio::commands::EngineStatus;
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::svf::{
    compensation_coef, cutoff_to_g, resonance_to_k, FilterMode, Svf, SvfCoefs,
};
use crate::audio::midi_types::NoteEvent;
use crate::audio::modulation::envelope::{AdsrEnvelope, AdsrState};
use crossbeam::channel::Sender;
use std::f32::consts::FRAC_PI_2;
use tracing::{info, warn};

const MAX_VOICES: usize = 64;
const VOICES_MIN: usize = 1;
const DEFAULT_VOICES: usize = 16;
const MIDI_EVENT_CAP: usize = 64;
const DEFAULT_ROOT: u8 = 60;
const TUNE_RANGE: f32 = 24.0;
const SPEED_MIN: f32 = 0.25;
const SPEED_MAX: f32 = 4.0;
const TIME_MIN: f32 = 0.001;
const TIME_MAX: f32 = 2.0;
const DEFAULT_ATTACK: f32 = 0.001;
const DEFAULT_DECAY: f32 = 0.001;
const DEFAULT_SUSTAIN: f32 = 1.0;
const DEFAULT_RELEASE: f32 = 0.01;
/// Shortest play region and loop, in frames.
const MIN_REGION_FRAMES: f64 = 2.0;
const MIN_LOOP_FRAMES: f64 = 4.0;
/// Fade at the end of a non-looping region.
const DECLICK_SECONDS: f32 = 0.002;
/// Sentinel key in the queued MIDI list marking a choke (real keys are 0–127).
const CHOKE_KEY: u8 = 255;
/// Frames between filter coefficient updates.
const FILTER_CHUNK: usize = 32;
const FILTER_RAMP_MS: f32 = 5.0;
/// Audio between `"playheads"` records.
const PLAYHEAD_INTERVAL_SECONDS: f32 = 0.033;
const PLAYHEAD_RECORD_BYTES: usize = 12;
/// `Voice::zone` of the implicit single-mode zone.
const SINGLE_ZONE: u16 = u16::MAX;

pub const PARAM_VOLUME: ParamId = 0;
pub const PARAM_TUNE: ParamId = 1;
pub const PARAM_SPEED: ParamId = 2;
pub const PARAM_ROOT: ParamId = 3;
pub const PARAM_KEY_TRACK: ParamId = 4;
pub const PARAM_PLAY_MODE: ParamId = 5;
pub const PARAM_VELOCITY: ParamId = 6;
pub const PARAM_START: ParamId = 7;
pub const PARAM_END: ParamId = 8;
pub const PARAM_ATTACK: ParamId = 9;
pub const PARAM_DECAY: ParamId = 10;
pub const PARAM_SUSTAIN: ParamId = 11;
pub const PARAM_RELEASE: ParamId = 12;
pub const PARAM_VOICES: ParamId = 13;
pub const PARAM_FINE: ParamId = 14;
pub const PARAM_REVERSE: ParamId = 20;
pub const PARAM_LOOP_MODE: ParamId = 21;
pub const PARAM_LOOP_START: ParamId = 22;
pub const PARAM_LOOP_END: ParamId = 23;
pub const PARAM_CROSSFADE: ParamId = 24;
pub const PARAM_FILTER_TYPE: ParamId = 30;
pub const PARAM_CUTOFF: ParamId = 31;
pub const PARAM_RESONANCE: ParamId = 32;
pub const PARAM_FILTER_KEY_TRACK: ParamId = 33;

const PLAY_MODES: &[&str] = &["One-shot", "Gated"];
const LOOP_MODES: &[&str] = &["Off", "On", "Ping-Pong"];
const FILTER_TYPES: &[&str] = &["Off", "LP12", "LP24", "BP12", "BP24", "HP12", "HP24"];

const AMP_MODULE: [ParamSpec; 6] = [
    spec(PARAM_VOLUME, "Volume", "Amp", "", linear(0.0, 2.0), 1.0),
    spec(PARAM_VELOCITY, "Velocity", "Amp", "", linear(0.0, 1.0), 1.0),
    spec(
        PARAM_ATTACK,
        "Attack",
        "Amp",
        "s",
        linear(TIME_MIN, TIME_MAX),
        DEFAULT_ATTACK,
    ),
    spec(
        PARAM_DECAY,
        "Decay",
        "Amp",
        "s",
        linear(TIME_MIN, TIME_MAX),
        DEFAULT_DECAY,
    ),
    spec(
        PARAM_SUSTAIN,
        "Sustain",
        "Amp",
        "",
        linear(0.0, 1.0),
        DEFAULT_SUSTAIN,
    ),
    spec(
        PARAM_RELEASE,
        "Release",
        "Amp",
        "s",
        linear(TIME_MIN, TIME_MAX),
        DEFAULT_RELEASE,
    ),
];

const PITCH_MODULE: [ParamSpec; 4] = [
    spec(
        PARAM_TUNE,
        "Tune",
        "Pitch",
        "st",
        linear(-TUNE_RANGE, TUNE_RANGE),
        0.0,
    ),
    spec(
        PARAM_FINE,
        "Fine",
        "Pitch",
        "ct",
        linear(-100.0, 100.0),
        0.0,
    ),
    spec(
        PARAM_ROOT,
        "Root",
        "Pitch",
        "note",
        linear(0.0, 127.0),
        DEFAULT_ROOT as f32,
    ),
    spec(PARAM_KEY_TRACK, "Key Track", "Pitch", "", Kind::Bool, 0.0),
];

const PLAYBACK_MODULE: [ParamSpec; 6] = [
    // Speed is shown in %; the normalized curve is the old 0.25–4x log range.
    spec(
        PARAM_SPEED,
        "Speed",
        "Playback",
        "%",
        log(SPEED_MIN * 100.0, SPEED_MAX * 100.0),
        100.0,
    ),
    spec(
        PARAM_PLAY_MODE,
        "Play Mode",
        "Playback",
        "",
        Kind::Enum(PLAY_MODES),
        0.0,
    ),
    spec(PARAM_START, "Start", "Playback", "", linear(0.0, 1.0), 0.0),
    spec(PARAM_END, "End", "Playback", "", linear(0.0, 1.0), 1.0),
    spec(
        PARAM_VOICES,
        "Voices",
        "Playback",
        "",
        linear(VOICES_MIN as f32, MAX_VOICES as f32),
        DEFAULT_VOICES as f32,
    ),
    spec(PARAM_REVERSE, "Reverse", "Playback", "", Kind::Bool, 0.0),
];

const LOOP_MODULE: [ParamSpec; 4] = [
    spec(
        PARAM_LOOP_MODE,
        "Loop Mode",
        "Loop",
        "",
        Kind::Enum(LOOP_MODES),
        0.0,
    ),
    spec(
        PARAM_LOOP_START,
        "Loop Start",
        "Loop",
        "",
        linear(0.0, 1.0),
        0.0,
    ),
    spec(
        PARAM_LOOP_END,
        "Loop End",
        "Loop",
        "",
        linear(0.0, 1.0),
        1.0,
    ),
    spec(
        PARAM_CROSSFADE,
        "Crossfade",
        "Loop",
        "%",
        linear(0.0, 100.0),
        0.0,
    ),
];

const FILTER_MODULE: [ParamSpec; 4] = [
    spec(
        PARAM_FILTER_TYPE,
        "Filter Type",
        "Filter",
        "",
        Kind::Enum(FILTER_TYPES),
        0.0,
    ),
    spec(
        PARAM_CUTOFF,
        "Cutoff",
        "Filter",
        "Hz",
        log(20.0, 20_000.0),
        1_000.0,
    ),
    spec(
        PARAM_RESONANCE,
        "Resonance",
        "Filter",
        "%",
        linear(0.0, 100.0),
        0.0,
    ),
    spec(
        PARAM_FILTER_KEY_TRACK,
        "Filter Key Track",
        "Filter",
        "%",
        linear(0.0, 100.0),
        0.0,
    ),
];

const PARAM_COUNT: usize = 24;
const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[
    &AMP_MODULE,
    &PITCH_MODULE,
    &PLAYBACK_MODULE,
    &LOOP_MODULE,
    &FILTER_MODULE,
]);
const SLOTS: [u8; 34] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Playback mode: one-shot ignores note-off; gated fades out on note-off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PlayMode {
    OneShot,
    Gated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LoopMode {
    Off,
    On,
    PingPong,
}

impl LoopMode {
    fn from_index(index: usize) -> Self {
        match index {
            0 => LoopMode::Off,
            1 => LoopMode::On,
            _ => LoopMode::PingPong,
        }
    }
}

/// Decoded (real-valued) parameters.
#[derive(Clone, Copy, Debug)]
struct Params {
    volume: f32,
    /// Semitones.
    tune: f32,
    /// Cents.
    fine: f32,
    /// Playback rate multiplier (1 = native).
    speed: f32,
    root: u8,
    key_track: bool,
    play_mode: PlayMode,
    velocity_amount: f32,
    start: f32,
    end: f32,
    reverse: bool,
    loop_mode: LoopMode,
    loop_start: f32,
    loop_end: f32,
    /// Crossfade as a fraction of the loop length.
    crossfade: f32,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
    voices: usize,
    filter: Option<FilterMode>,
    cutoff_hz: f32,
    /// 0..1.
    resonance: f32,
    /// 0..1.
    filter_key_track: f32,
}

impl Params {
    fn from_values(values: &ParamValues<PARAM_COUNT>) -> Self {
        let mut p = Self {
            volume: 1.0,
            tune: 0.0,
            fine: 0.0,
            speed: 1.0,
            root: DEFAULT_ROOT,
            key_track: false,
            play_mode: PlayMode::OneShot,
            velocity_amount: 1.0,
            start: 0.0,
            end: 1.0,
            reverse: false,
            loop_mode: LoopMode::Off,
            loop_start: 0.0,
            loop_end: 1.0,
            crossfade: 0.0,
            attack: DEFAULT_ATTACK,
            decay: DEFAULT_DECAY,
            sustain: DEFAULT_SUSTAIN,
            release: DEFAULT_RELEASE,
            voices: DEFAULT_VOICES,
            filter: None,
            cutoff_hz: 1_000.0,
            resonance: 0.0,
            filter_key_track: 0.0,
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
            PARAM_VOLUME => self.volume = real,
            PARAM_TUNE => self.tune = real,
            PARAM_FINE => self.fine = real,
            PARAM_SPEED => self.speed = real * 0.01,
            PARAM_ROOT => self.root = real.round().clamp(0.0, 127.0) as u8,
            PARAM_KEY_TRACK => self.key_track = real >= 0.5,
            PARAM_PLAY_MODE => {
                self.play_mode = if real >= 0.5 {
                    PlayMode::Gated
                } else {
                    PlayMode::OneShot
                }
            }
            PARAM_VELOCITY => self.velocity_amount = real,
            PARAM_START => self.start = real,
            PARAM_END => self.end = real,
            PARAM_REVERSE => self.reverse = real >= 0.5,
            PARAM_LOOP_MODE => self.loop_mode = LoopMode::from_index(real as usize),
            PARAM_LOOP_START => self.loop_start = real,
            PARAM_LOOP_END => self.loop_end = real,
            PARAM_CROSSFADE => self.crossfade = real * 0.01,
            PARAM_ATTACK => self.attack = real,
            PARAM_DECAY => self.decay = real,
            PARAM_SUSTAIN => self.sustain = real,
            PARAM_RELEASE => self.release = real,
            PARAM_VOICES => self.voices = (real.round() as usize).clamp(VOICES_MIN, MAX_VOICES),
            PARAM_FILTER_TYPE => {
                self.filter = match real as usize {
                    1 => Some(FilterMode::Lp12),
                    2 => Some(FilterMode::Lp24),
                    3 => Some(FilterMode::Bp12),
                    4 => Some(FilterMode::Bp24),
                    5 => Some(FilterMode::Hp12),
                    6 => Some(FilterMode::Hp24),
                    _ => None,
                }
            }
            PARAM_CUTOFF => self.cutoff_hz = real,
            PARAM_RESONANCE => self.resonance = real * 0.01,
            PARAM_FILTER_KEY_TRACK => self.filter_key_track = real * 0.01,
            _ => {}
        }
    }
}

/// Decoded interleaved PCM. `sample_rate` is the buffer rate, which may differ from the device.
struct SampleBuffer {
    samples: Vec<f32>,
    channels: usize,
    frames: usize,
    sample_rate: f32,
}

impl SampleBuffer {
    fn new(samples: Vec<f32>, channels: usize, sample_rate: u32) -> Self {
        let channels = channels.max(1);
        Self {
            frames: samples.len() / channels,
            samples,
            channels,
            sample_rate: (sample_rate as f32).max(1.0),
        }
    }
}

/// Play region, loop and crossfade lengths in sample frames, ordered and clamped.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Regions {
    /// `[start, end)`.
    pub play: (f64, f64),
    /// `[start, end)`, inside `play`.
    pub loop_: (f64, f64),
    /// Forward crossfade length: capped by half the loop and by the material before Loop Start.
    pub xfade_fwd: f64,
    /// Reverse crossfade length: capped by half the loop and by the material after Loop End.
    pub xfade_rev: f64,
}

impl Regions {
    const EMPTY: Regions = Regions {
        play: (0.0, 0.0),
        loop_: (0.0, 0.0),
        xfade_fwd: 0.0,
        xfade_rev: 0.0,
    };

    fn loop_len(&self) -> f64 {
        self.loop_.1 - self.loop_.0
    }
}

fn ordered(a: f32, b: f32) -> (f64, f64) {
    let (a, b) = (a.clamp(0.0, 1.0) as f64, b.clamp(0.0, 1.0) as f64);
    (a.min(b), a.max(b))
}

/// Order and clamp the raw points: `start < end`, the loop inside `[start, end]` with a minimum
/// length, and the crossfade (`crossfade` is a fraction of the loop) capped per direction.
pub fn resolve_regions(
    frames: usize,
    start: f32,
    end: f32,
    loop_start: f32,
    loop_end: f32,
    crossfade: f32,
) -> Regions {
    if frames == 0 {
        return Regions::EMPTY;
    }
    let max = frames as f64;
    let (s, e) = ordered(start, end);
    let (mut a, mut b) = (s * max, e * max);
    if b - a < MIN_REGION_FRAMES {
        b = (a + MIN_REGION_FRAMES).min(max);
        a = (b - MIN_REGION_FRAMES).max(0.0);
    }
    let (ls, le) = ordered(loop_start, loop_end);
    let mut l0 = (ls * max).clamp(a, b);
    let mut l1 = (le * max).clamp(a, b);
    let min_loop = MIN_LOOP_FRAMES.min(b - a);
    if l1 - l0 < min_loop {
        l1 = l0 + min_loop;
        if l1 > b {
            l1 = b;
            l0 = b - min_loop;
        }
    }
    let len = l1 - l0;
    let wanted = (crossfade.clamp(0.0, 1.0) as f64 * len).min(len * 0.5);
    Regions {
        play: (a, b),
        loop_: (l0, l1),
        xfade_fwd: wanted.min(l0),
        xfade_rev: wanted.min(max - l1),
    }
}

/// One playable sample and everything a voice reads from it besides the device-wide settings.
struct Zone {
    /// Godot's zone id (unused for the single-mode zone).
    id: u32,
    sample: Option<SampleBuffer>,
    regions: Regions,
    /// Raw points, 0–1 over the file, resolved into `regions`.
    start: f32,
    end: f32,
    loop_start: f32,
    loop_end: f32,
    /// Fraction of the loop.
    crossfade: f32,
    loop_mode: LoopMode,
    reverse: bool,
    root: u8,
    /// Semitones, fine tune included.
    tune: f32,
    key_track: bool,
    gain: f32,
    ranges: ZoneRanges,
    group_id: u32,
    /// Index of `group_id` in `SamplerDevice::groups`, or 0 (Ungrouped) while it's missing.
    group_index: usize,
    /// Load in flight, so stale AFS completions can be ignored.
    req_id: String,
    /// Last state sent on `loading_state` (`zone/{zid}/loading_state` for a multisample zone).
    loading_state: String,
}

impl Zone {
    fn empty(id: u32) -> Self {
        Self {
            id,
            sample: None,
            regions: Regions::EMPTY,
            start: 0.0,
            end: 1.0,
            loop_start: 0.0,
            loop_end: 1.0,
            crossfade: 0.0,
            loop_mode: LoopMode::Off,
            reverse: false,
            root: DEFAULT_ROOT,
            tune: 0.0,
            key_track: false,
            gain: 1.0,
            ranges: ZoneRanges::default(),
            group_id: UNGROUPED,
            group_index: 0,
            req_id: String::new(),
            loading_state: "idle".to_string(),
        }
    }

    fn frames(&self) -> usize {
        self.sample.as_ref().map_or(0, |s| s.frames)
    }

    /// Re-resolve the play region, loop and crossfade from the raw points.
    fn resolve_regions(&mut self) {
        self.regions = resolve_regions(
            self.frames(),
            self.start,
            self.end,
            self.loop_start,
            self.loop_end,
            self.crossfade,
        );
    }

    /// Take a multisample zone's settings. Key tracking follows the device Key Track parameter.
    fn apply_settings(&mut self, s: &ZoneSettings) {
        self.ranges = s.ranges;
        self.root = s.root;
        self.tune = s.tune;
        self.gain = s.gain;
        self.start = s.start;
        self.end = s.end;
        self.reverse = s.reverse;
        self.loop_mode = LoopMode::from_index(s.loop_mode as usize);
        self.loop_start = s.loop_start;
        self.loop_end = s.loop_end;
        self.crossfade = s.crossfade;
        self.group_id = s.group_id;
        self.resolve_regions();
    }
}

impl SelectableZone for Zone {
    fn ranges(&self) -> &ZoneRanges {
        &self.ranges
    }

    fn group_index(&self) -> usize {
        self.group_index
    }

    fn is_playable(&self) -> bool {
        self.sample.is_some()
    }
}

/// The zone a voice plays: `single` for [`SINGLE_ZONE`], else `zones[index]`.
fn zone_at<'a>(single: &'a Zone, zones: &'a [Zone], index: u16) -> Option<&'a Zone> {
    if index == SINGLE_ZONE {
        Some(single)
    } else {
        zones.get(index as usize)
    }
}

/// One voice reading its zone's sample through a filter and an ADSR amplitude envelope.
#[derive(Clone, Copy)]
struct Voice {
    active: bool,
    note: u8,
    /// [`SINGLE_ZONE`] or an index into `SamplerDevice::zones`.
    zone: u16,
    /// The note-on that started it: a note-off releases all of one note-on's stacked voices.
    trigger: u64,
    position: f64,
    /// Frames of PCM per output frame, always positive; `direction` gives the sign.
    increment: f64,
    /// +1 or −1 (flips on a Ping-Pong bounce).
    direction: f64,
    in_loop: bool,
    /// Hit the end of a non-looping region: holding there while `fade` runs to 0.
    ending: bool,
    fade: f32,
    gain: f32,
    envelope: AdsrEnvelope,
    filters: [Svf; 2],
    age: u64,
}

impl Voice {
    /// Idle voice with no playback, sized for `sample_rate`.
    fn idle(sample_rate: f32) -> Self {
        Self {
            active: false,
            note: 0,
            zone: SINGLE_ZONE,
            trigger: 0,
            position: 0.0,
            increment: 1.0,
            direction: 1.0,
            in_loop: false,
            ending: false,
            fade: 1.0,
            gain: 0.0,
            envelope: AdsrEnvelope::new(sample_rate),
            filters: [Svf::new(); 2],
            age: 0,
        }
    }

    /// True while the voice is sounding and not yet in release.
    fn is_held(&self) -> bool {
        self.active && !matches!(self.envelope.state(), AdsrState::Idle | AdsrState::Release)
    }
}

/// Is `pos` inside the loop for a voice moving in `direction`?
fn inside_loop(pos: f64, direction: f64, l: (f64, f64)) -> bool {
    if direction > 0.0 {
        pos >= l.0 && pos < l.1
    } else {
        pos > l.0 && pos <= l.1
    }
}

/// Move `v` by one output frame and apply the loop / region boundary rules.
fn advance(v: &mut Voice, r: &Regions, mode: LoopMode) {
    if v.ending {
        return;
    }
    v.position += v.increment * v.direction;
    if mode != LoopMode::Off {
        let l = r.loop_;
        if !v.in_loop && inside_loop(v.position, v.direction, l) {
            v.in_loop = true;
        }
        if v.in_loop {
            match mode {
                LoopMode::On => {
                    let outside = if v.direction > 0.0 {
                        v.position >= l.1 || v.position < l.0
                    } else {
                        v.position > l.1 || v.position < l.0
                    };
                    if outside {
                        v.position = l.0 + (v.position - l.0).rem_euclid(r.loop_len());
                    }
                }
                _ => {
                    if v.direction > 0.0 && v.position >= l.1 {
                        v.position = 2.0 * l.1 - v.position;
                        v.direction = -1.0;
                    } else if v.direction < 0.0 && v.position < l.0 {
                        v.position = 2.0 * l.0 - v.position;
                        v.direction = 1.0;
                    }
                    v.position = v.position.clamp(l.0, l.1);
                }
            }
            return;
        }
    }
    if v.direction > 0.0 && v.position >= r.play.1 {
        v.ending = true;
        v.position = (r.play.1 - 1.0).max(r.play.0);
    } else if v.direction < 0.0 && v.position <= r.play.0 {
        v.ending = true;
        v.position = r.play.0;
    }
}

/// The voice's stereo output frame at its position, with the loop crossfade applied.
fn read_voice(sample: &SampleBuffer, v: &Voice, r: &Regions, mode: LoopMode) -> (f32, f32) {
    let (l, rt) = interpolate_frame(sample, v.position);
    if mode != LoopMode::On || !v.in_loop {
        return (l, rt);
    }
    let len = r.loop_len();
    let (xf, dist, other) = if v.direction > 0.0 {
        (r.xfade_fwd, r.loop_.1 - v.position, v.position - len)
    } else {
        (r.xfade_rev, v.position - r.loop_.0, v.position + len)
    };
    if xf <= 0.0 || dist >= xf {
        return (l, rt);
    }
    let t = (1.0 - dist / xf).clamp(0.0, 1.0) as f32 * FRAC_PI_2;
    let (out_gain, in_gain) = (t.cos(), t.sin());
    let (l2, r2) = interpolate_frame(sample, other);
    (l * out_gain + l2 * in_gain, rt * out_gain + r2 * in_gain)
}

/// Cutoff for `note`: `cutoff * 2^(key_track * (note - root) / 12)`.
pub fn tracked_cutoff(cutoff_hz: f32, key_track: f32, note: u8, root: u8) -> f32 {
    cutoff_hz * 2.0_f32.powf(key_track * (note as f32 - root as f32) / 12.0)
}

/// Everything the voice renderer needs besides the voices themselves.
struct RenderCtx<'a> {
    single: &'a Zone,
    zones: &'a [Zone],
    filter: Option<FilterMode>,
    filter_key_track: f32,
    sample_rate: f32,
    fade_step: f32,
}

/// Pitch/speed ratio: `speed * 2^((tune + keytrack*(note-root))/12)`.
pub fn playback_increment(speed: f32, tune: f32, key_track: bool, note: u8, root: u8) -> f64 {
    let key_delta = if key_track {
        note as f32 - root as f32
    } else {
        0.0
    };
    let semitones = tune + key_delta;
    (speed as f64) * 2.0_f64.powf(semitones as f64 / 12.0)
}

/// Frames of sample PCM to advance per device output frame so pitch stays native.
pub fn sample_rate_ratio(sample_rate: f32, device_sample_rate: f32) -> f64 {
    sample_rate.max(1.0) as f64 / device_sample_rate.max(1.0) as f64
}

/// Mix active voices into `outputs` for `len` frames starting at `start`, in filter chunks.
fn render_active_voices(
    ctx: &RenderCtx,
    voices: &mut [Voice],
    cutoff: &mut SmoothedParam,
    resonance: &mut SmoothedParam,
    outputs: &mut [f32],
    start: usize,
    len: usize,
) {
    let mut done = 0;
    while done < len {
        let n = FILTER_CHUNK.min(len - done);
        for _ in 1..n {
            cutoff.next();
            resonance.next();
        }
        let (cut, res) = (cutoff.next(), resonance.next());
        for voice in voices.iter_mut().filter(|v| v.active) {
            let Some((zone, sample)) = zone_at(ctx.single, ctx.zones, voice.zone)
                .and_then(|z| z.sample.as_ref().map(|s| (z, s)))
            else {
                voice.active = false;
                continue;
            };
            let filter = ctx.filter.map(|mode| {
                let hz = tracked_cutoff(cut, ctx.filter_key_track, voice.note, zone.root);
                let coefs = SvfCoefs::new(
                    cutoff_to_g(hz, ctx.sample_rate),
                    resonance_to_k(res, mode),
                    mode,
                );
                (mode, coefs, compensation_coef(hz * 0.5, ctx.sample_rate))
            });
            for i in 0..n {
                if !voice.active {
                    break;
                }
                let env = voice.envelope.process_sample();
                let (mut l, mut r) = read_voice(sample, voice, &zone.regions, zone.loop_mode);
                if let Some((mode, coefs, comp)) = &filter {
                    l = voice.filters[0].process(l, *mode, coefs, *comp, res);
                    r = voice.filters[1].process(r, *mode, coefs, *comp, res);
                }
                let g = voice.gain * env * voice.fade;
                let idx = (start + done + i) * 2;
                if idx + 1 < outputs.len() {
                    outputs[idx] += l * g;
                    outputs[idx + 1] += r * g;
                }
                advance(voice, &zone.regions, zone.loop_mode);
                if voice.ending {
                    voice.fade -= ctx.fade_step;
                    if voice.fade <= 0.0 {
                        voice.active = false;
                    }
                }
                if !voice.envelope.is_active() {
                    voice.active = false;
                }
            }
        }
        done += n;
    }
}

/// Built-in Sampler: MIDI-triggered playback of one audio file, or of zones in multisample mode.
pub struct SamplerDevice {
    /// The single-sample mode zone, rebuilt from the parameters.
    single: Zone,
    multisample: bool,
    /// Multisample zones. Capacity [`MAX_ZONES`] is reserved when the mode turns on, so the
    /// audio thread never sees it grow.
    zones: Vec<Zone>,
    /// Zone groups, Ungrouped first. Reserved to [`MAX_GROUPS`] with the zones.
    groups: Vec<ZoneGroup>,
    any_solo: bool,
    /// Zone indices matching the current note-on, capacity [`MAX_ZONES`].
    match_scratch: Vec<u16>,
    /// xorshift state for Random groups.
    rng: u32,
    /// Zone id whose voices the `"playheads"` stream reports in multisample mode.
    focused_zone: u32,
    trigger_counter: u64,
    voices: [Voice; MAX_VOICES],
    voice_count: usize,
    /// (frame_offset, key, velocity or release, is_note_on)
    queued_midi: Vec<(usize, u8, f32, bool)>,
    midi_scratch: Vec<(usize, u8, f32, bool)>,
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,
    p: Params,
    cutoff: SmoothedParam,
    resonance: SmoothedParam,
    /// A pitch parameter changed: recompute the increment of sounding voices next block.
    pitch_dirty: bool,
    enabled: bool,
    sleep_state: DeviceSleepState,
    channel_id: usize,
    device_path: DevicePath,
    status_tx: Option<Sender<EngineStatus>>,
    time_counter: u64,
    playheads_subscribed: bool,
    frames_since_poll: usize,
    /// The last `"playheads"` record had voices, so an empty one still has to go out.
    playheads_sent_voices: bool,
}

/// Linearly interpolate one stereo frame from interleaved PCM.
fn interpolate_frame(sample: &SampleBuffer, position: f64) -> (f32, f32) {
    if sample.frames == 0 || sample.channels == 0 {
        return (0.0, 0.0);
    }
    let last = (sample.frames - 1) as f64;
    let pos = position.clamp(0.0, last);
    let i0 = pos.floor() as usize;
    let i1 = (i0 + 1).min(sample.frames - 1);
    let frac = (pos - i0 as f64) as f32;
    let ch = sample.channels;
    let read = |frame: usize, channel: usize| -> f32 {
        let idx = frame * ch + channel.min(ch - 1);
        sample.samples.get(idx).copied().unwrap_or(0.0)
    };
    if ch == 1 {
        let a = read(i0, 0);
        let b = read(i1, 0);
        let v = a + (b - a) * frac;
        (v, v)
    } else {
        let l0 = read(i0, 0);
        let l1 = read(i1, 0);
        let r0 = read(i0, 1);
        let r1 = read(i1, 1);
        (l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac)
    }
}

impl SamplerDevice {
    /// Create a sampler that reports loading state for `channel_id` / `device_path`.
    pub fn new(
        sample_rate: f32,
        channel_id: usize,
        device_path: DevicePath,
        status_tx: Option<Sender<EngineStatus>>,
    ) -> Self {
        let sample_rate = sample_rate.max(1.0);
        let values = ParamValues::new(&TABLE);
        let p = Params::from_values(&values);
        let mut device = Self {
            single: Zone::empty(0),
            multisample: false,
            zones: Vec::new(),
            groups: Vec::new(),
            any_solo: false,
            match_scratch: Vec::new(),
            rng: 0x9e37_79b9,
            focused_zone: 0,
            trigger_counter: 0,
            voices: [Voice::idle(sample_rate); MAX_VOICES],
            voice_count: p.voices,
            queued_midi: Vec::with_capacity(MIDI_EVENT_CAP),
            midi_scratch: Vec::with_capacity(MIDI_EVENT_CAP),
            sample_rate,
            values,
            p,
            cutoff: SmoothedParam::new(p.cutoff_hz, sample_rate, FILTER_RAMP_MS),
            resonance: SmoothedParam::new(p.resonance, sample_rate, FILTER_RAMP_MS),
            pitch_dirty: false,
            enabled: true,
            sleep_state: DeviceSleepState::new(),
            channel_id,
            device_path,
            status_tx,
            time_counter: 0,
            playheads_subscribed: false,
            frames_since_poll: 0,
            playheads_sent_voices: false,
        };
        device.refresh_single_zone();
        device
    }

    /// Metadata-only instance used when advertising built-ins.
    pub fn new_for_metadata() -> Self {
        Self::new(48_000.0, 0, DevicePath::root(0), None)
    }

    /// Mark this device as loading `req_id` so stale AFS completions can be ignored.
    pub fn begin_sample_load(&mut self, req_id: String) {
        info!(
            "Sampler begin load channel={} path={} req={}",
            self.channel_id, self.device_path, req_id
        );
        self.single.req_id = req_id;
        self.emit_loading("loading");
    }

    /// Replace the single-mode buffer. Voices are killed because they pointed at the old PCM.
    pub fn set_sample(
        &mut self,
        req_id: &str,
        samples: Vec<f32>,
        channels: usize,
        sample_rate: u32,
    ) {
        if !self.single.req_id.is_empty() && self.single.req_id != req_id {
            warn!(
                "Ignoring stale sampler load (expected {}, got {})",
                self.single.req_id, req_id
            );
            return;
        }
        let sample = SampleBuffer::new(samples, channels, sample_rate);
        info!(
            "Sampler ready: {} frames, {} ch, {} Hz ({} samples)",
            sample.frames,
            sample.channels,
            sample_rate,
            sample.samples.len()
        );
        self.reset_voices();
        self.single.sample = Some(sample);
        self.single.resolve_regions();
        self.sleep_state.mark_activity();
        self.emit_loading("ready");
    }

    /// Record a failed load without dropping a previously ready sample.
    pub fn fail_sample_load(&mut self, req_id: &str, message: &str) {
        if !self.single.req_id.is_empty() && self.single.req_id != req_id {
            return;
        }
        warn!("Sampler load failed: {}", message);
        self.emit_loading(&format!("failed:{}", message));
    }

    fn emit_loading(&mut self, state: &str) {
        self.single.loading_state = state.to_string();
        if let Some(tx) = &self.status_tx {
            let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                state: state.to_string(),
            });
        }
    }

    // === Multisample mode ===

    /// Switch modes. Voices are killed either way. On reserves the zone, group and match
    /// capacity; off drops the zones and groups (and their PCM).
    pub fn set_multisample(&mut self, on: bool) {
        if on == self.multisample {
            return;
        }
        info!(
            "Sampler channel={} path={} multisample={}",
            self.channel_id, self.device_path, on
        );
        self.reset_voices();
        self.multisample = on;
        self.any_solo = false;
        if on {
            self.zones = Vec::with_capacity(MAX_ZONES);
            self.groups = Vec::with_capacity(MAX_GROUPS);
            self.groups.push(ZoneGroup::new(UNGROUPED));
            self.match_scratch = Vec::with_capacity(MAX_ZONES);
        } else {
            self.zones = Vec::new();
            self.groups = Vec::new();
            self.match_scratch = Vec::new();
        }
    }

    fn zone_index(&self, id: u32) -> Option<usize> {
        self.zones.iter().position(|z| z.id == id)
    }

    fn group_index_of(&self, id: u32) -> usize {
        self.groups.iter().position(|g| g.id == id).unwrap_or(0)
    }

    /// Point every zone at its group's index again after groups were added or removed.
    fn relink_groups(&mut self) {
        for i in 0..self.zones.len() {
            self.zones[i].group_index = self.group_index_of(self.zones[i].group_id);
        }
    }

    /// Kill the voices playing zone `index` (before its PCM is replaced or it is removed).
    fn kill_zone_voices(&mut self, index: u16) {
        let sample_rate = self.sample_rate;
        for voice in self
            .voices
            .iter_mut()
            .filter(|v| v.active && v.zone == index)
        {
            *voice = Voice::idle(sample_rate);
        }
    }

    /// Create or replace zone `id`'s settings. Its PCM, if any, is kept.
    pub fn set_zone(&mut self, id: u32, settings: &ZoneSettings) {
        if !self.multisample {
            warn!("Sampler zone {} set ignored: not in multisample mode", id);
            return;
        }
        let settings = settings.sanitized();
        let group_index = self.group_index_of(settings.group_id);
        let zone = match self.zone_index(id) {
            Some(index) => &mut self.zones[index],
            None if self.zones.len() >= MAX_ZONES => {
                warn!("Sampler zone {} dropped: already {} zones", id, MAX_ZONES);
                return;
            }
            None => {
                self.zones.push(Zone::empty(id));
                self.zones.last_mut().expect("just pushed")
            }
        };
        zone.apply_settings(&settings);
        zone.group_index = group_index;
        self.pitch_dirty = true;
    }

    /// Remove zone `id` and its voices. The last zone moves into its index.
    pub fn remove_zone(&mut self, id: u32) {
        let Some(index) = self.zone_index(id) else {
            warn!("Sampler zone {} remove ignored: no such zone", id);
            return;
        };
        let (removed, last) = (index as u16, (self.zones.len() - 1) as u16);
        self.kill_zone_voices(removed);
        for voice in self.voices.iter_mut().filter(|v| v.zone == last) {
            voice.zone = removed;
        }
        for group in &mut self.groups {
            group.remap_zone(removed, last);
        }
        self.zones.swap_remove(index);
    }

    /// Create or replace group `id`.
    pub fn set_zone_group(
        &mut self,
        id: u32,
        gain: f32,
        mute: bool,
        solo: bool,
        play_mode: GroupPlayMode,
    ) {
        if !self.multisample {
            warn!("Sampler group {} set ignored: not in multisample mode", id);
            return;
        }
        match self.groups.iter().position(|g| g.id == id) {
            Some(index) => self.groups[index].set(gain, mute, solo, play_mode),
            None if self.groups.len() >= MAX_GROUPS => {
                warn!(
                    "Sampler group {} dropped: already {} groups",
                    id, MAX_GROUPS
                );
                return;
            }
            None => {
                let mut group = ZoneGroup::new(id);
                group.set(gain, mute, solo, play_mode);
                self.groups.push(group);
                self.relink_groups();
            }
        }
        self.any_solo = self.groups.iter().any(|g| g.solo);
    }

    /// Remove group `id`. Its zones fall back to Ungrouped, which can't be removed.
    pub fn remove_zone_group(&mut self, id: u32) {
        if id == UNGROUPED {
            warn!("Sampler: Ungrouped can't be removed");
            return;
        }
        let Some(index) = self.groups.iter().position(|g| g.id == id) else {
            return;
        };
        self.groups.remove(index);
        for zone in self.zones.iter_mut().filter(|z| z.group_id == id) {
            zone.group_id = UNGROUPED;
        }
        self.relink_groups();
        self.any_solo = self.groups.iter().any(|g| g.solo);
    }

    /// Report only zone `id`'s voices on the `"playheads"` stream.
    pub fn set_focus(&mut self, id: u32) {
        self.focused_zone = id;
    }

    /// Mark zone `id` as loading `req_id`.
    pub fn begin_zone_load(&mut self, id: u32, req_id: String) {
        let Some(index) = self.zone_index(id) else {
            warn!("Sampler zone {} load ignored: no such zone", id);
            return;
        };
        info!(
            "Sampler begin zone load channel={} path={} zone={} req={}",
            self.channel_id, self.device_path, id, req_id
        );
        self.zones[index].req_id = req_id;
        self.emit_zone_loading(index, "loading".to_string());
    }

    /// Replace zone `id`'s PCM. Stale requests and unknown zones are ignored, and the old PCM
    /// is freed here, on the command thread.
    pub fn set_zone_sample(
        &mut self,
        id: u32,
        req_id: &str,
        samples: Vec<f32>,
        channels: usize,
        sample_rate: u32,
    ) {
        let Some(index) = self.zone_index(id) else {
            warn!("Ignoring sampler zone load for unknown zone {}", id);
            return;
        };
        let zone = &self.zones[index];
        if !zone.req_id.is_empty() && zone.req_id != req_id {
            warn!(
                "Ignoring stale sampler zone {} load (expected {}, got {})",
                id, zone.req_id, req_id
            );
            return;
        }
        self.kill_zone_voices(index as u16);
        let zone = &mut self.zones[index];
        zone.sample = Some(SampleBuffer::new(samples, channels, sample_rate));
        zone.resolve_regions();
        let bytes: usize = self
            .zones
            .iter()
            .filter_map(|z| z.sample.as_ref())
            .map(|s| s.samples.len() * std::mem::size_of::<f32>())
            .sum();
        info!(
            "Sampler zone {} ready: {} frames; {} zones hold {:.1} MB of PCM",
            id,
            self.zones[index].frames(),
            self.zones.len(),
            bytes as f64 / 1_000_000.0
        );
        self.sleep_state.mark_activity();
        self.emit_zone_loading(index, "ready".to_string());
    }

    /// Record a failed zone load. The zone stays (silent if it never loaded, REQ-028).
    pub fn fail_zone_load(&mut self, id: u32, req_id: &str, message: &str) {
        let Some(index) = self.zone_index(id) else {
            return;
        };
        let zone = &self.zones[index];
        if !zone.req_id.is_empty() && zone.req_id != req_id {
            return;
        }
        warn!("Sampler zone {} load failed: {}", id, message);
        self.emit_zone_loading(index, format!("failed:{}", message));
    }

    fn emit_zone_loading(&mut self, index: usize, state: String) {
        let zone = &mut self.zones[index];
        zone.loading_state = state.clone();
        if let Some(tx) = &self.status_tx {
            let _ = tx.send(EngineStatus::SamplerZoneLoadingState {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                zone_id: zone.id,
                state,
            });
        }
    }

    /// Send every zone's loading state again (Godot's `state/get`).
    pub fn resend_zone_states(&self) {
        let Some(tx) = &self.status_tx else {
            return;
        };
        for zone in &self.zones {
            let _ = tx.send(EngineStatus::SamplerZoneLoadingState {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                zone_id: zone.id,
                state: zone.loading_state.clone(),
            });
        }
    }

    // === Voices ===

    fn reset_voices(&mut self) {
        self.voices = [Voice::idle(self.sample_rate); MAX_VOICES];
    }

    fn any_voice_active(&self) -> bool {
        self.voices[..self.voice_count].iter().any(|v| v.active)
    }

    /// Apply the device ADSR settings to every voice, including notes already sounding.
    fn apply_envelope_params(&mut self) {
        for voice in &mut self.voices {
            voice
                .envelope
                .set_adsr(self.p.attack, self.p.decay, self.p.sustain, self.p.release);
        }
    }

    /// Copy the per-sample parameters into the single-mode zone and re-resolve its regions.
    fn refresh_single_zone(&mut self) {
        let (p, zone) = (&self.p, &mut self.single);
        zone.start = p.start;
        zone.end = p.end;
        zone.loop_start = p.loop_start;
        zone.loop_end = p.loop_end;
        zone.crossfade = p.crossfade;
        zone.loop_mode = p.loop_mode;
        zone.reverse = p.reverse;
        zone.root = p.root;
        zone.tune = p.tune + p.fine / 100.0;
        zone.key_track = p.key_track;
        zone.resolve_regions();
    }

    /// Sample frames per output frame for `note` played from `zone`, 0 without PCM.
    fn increment_for(&self, note: u8, zone: &Zone) -> f64 {
        let Some(sample) = zone.sample.as_ref() else {
            return 0.0;
        };
        playback_increment(self.p.speed, zone.tune, self.p.key_track, note, zone.root)
            * sample_rate_ratio(sample.sample_rate, self.sample_rate)
    }

    /// Recompute the pitch of sounding voices after Speed or a zone's pitch settings moved.
    fn refresh_pitch(&mut self) {
        for i in 0..self.voice_count {
            let voice = self.voices[i];
            if !voice.active {
                continue;
            }
            let Some(zone) = zone_at(&self.single, &self.zones, voice.zone) else {
                continue;
            };
            let inc = self.increment_for(voice.note, zone);
            if inc > 0.0 {
                self.voices[i].increment = inc;
            }
        }
    }

    /// Apply a decoded parameter value and its side effects.
    fn apply(&mut self, id: ParamId, real: f32) {
        self.p.apply(id, real);
        match id {
            PARAM_TUNE | PARAM_FINE | PARAM_SPEED | PARAM_ROOT | PARAM_KEY_TRACK => {
                self.refresh_single_zone();
                self.pitch_dirty = true
            }
            PARAM_START | PARAM_END | PARAM_LOOP_START | PARAM_LOOP_END | PARAM_CROSSFADE
            | PARAM_REVERSE | PARAM_LOOP_MODE => self.refresh_single_zone(),
            PARAM_ATTACK | PARAM_DECAY | PARAM_SUSTAIN | PARAM_RELEASE => {
                self.apply_envelope_params()
            }
            PARAM_VOICES => self.set_voice_count(self.p.voices),
            PARAM_CUTOFF => self.cutoff.set_target(self.p.cutoff_hz),
            PARAM_RESONANCE => self.resonance.set_target(self.p.resonance),
            _ => {}
        }
    }

    /// Limit polyphony and silence slots that fall outside the new count.
    fn set_voice_count(&mut self, count: usize) {
        let count = count.clamp(VOICES_MIN, MAX_VOICES);
        if count < self.voice_count {
            for voice in &mut self.voices[count..self.voice_count] {
                *voice = Voice::idle(self.sample_rate);
            }
        }
        self.voice_count = count;
    }

    /// Free slot in the polyphony pool, or steal a releasing then oldest voice.
    fn allocate_voice(&self) -> Option<usize> {
        let pool = &self.voices[..self.voice_count];
        pool.iter().position(|v| !v.active).or_else(|| {
            pool.iter()
                .enumerate()
                .min_by_key(|(_, v)| {
                    let releasing = matches!(v.envelope.state(), AdsrState::Release);
                    (if releasing { 0u8 } else { 1u8 }, v.age)
                })
                .map(|(i, _)| i)
        })
    }

    fn note_on(&mut self, note: u8, velocity: f32) {
        let vel_gain = (1.0 - self.p.velocity_amount) + self.p.velocity_amount * velocity;
        self.trigger_counter = self.trigger_counter.wrapping_add(1);
        if !self.multisample {
            self.start_voice(
                SINGLE_ZONE,
                note,
                self.p.volume * vel_gain,
                self.trigger_counter,
            );
            return;
        }
        let vel = velocity_to_midi(velocity);
        select_zones(
            &self.zones,
            &mut self.groups,
            self.any_solo,
            note,
            vel,
            &mut self.rng,
            &mut self.match_scratch,
        );
        for k in 0..self.match_scratch.len() {
            let index = self.match_scratch[k];
            let zone = &self.zones[index as usize];
            let fade = zone.ranges.gain(note, vel);
            if fade <= 0.0 {
                continue;
            }
            let group_gain = self.groups.get(zone.group_index).map_or(1.0, |g| g.gain);
            let gain = self.p.volume * vel_gain * zone.gain * group_gain * fade;
            self.start_voice(index, note, gain, self.trigger_counter);
        }
    }

    /// Start a voice playing `zone_index` ([`SINGLE_ZONE`] or a zone index), unless the zone has
    /// no PCM.
    fn start_voice(&mut self, zone_index: u16, note: u8, gain: f32, trigger: u64) {
        let Some(idx) = self.allocate_voice() else {
            return;
        };
        let Some(zone) = zone_at(&self.single, &self.zones, zone_index) else {
            return;
        };
        if zone.sample.is_none() {
            return;
        }
        let increment = self.increment_for(note, zone);
        let r = zone.regions;
        let direction = if zone.reverse { -1.0 } else { 1.0 };
        let position = if zone.reverse {
            (r.play.1 - 1.0).max(r.play.0)
        } else {
            r.play.0
        };
        if increment <= 0.0 {
            return;
        }
        let mut envelope = AdsrEnvelope::new(self.sample_rate);
        envelope.set_adsr(self.p.attack, self.p.decay, self.p.sustain, self.p.release);
        envelope.gate_on();
        self.time_counter = self.time_counter.wrapping_add(1);
        self.voices[idx] = Voice {
            active: true,
            note,
            zone: zone_index,
            trigger,
            position,
            increment,
            direction,
            in_loop: inside_loop(position, direction, r.loop_),
            ending: false,
            fade: 1.0,
            gain,
            envelope,
            filters: [Svf::new(); 2],
            age: self.time_counter,
        };
        self.sleep_state.mark_activity();
    }

    /// Fade every sounding voice out over the declick time (Drum Machine choke).
    fn choke_voices(&mut self) {
        for voice in self.voices[..self.voice_count]
            .iter_mut()
            .filter(|v| v.active)
        {
            voice.ending = true;
        }
    }

    /// Release the held voices of `note`'s oldest note-on that note-off applies to: Gated, or
    /// a zone with a loop.
    fn note_off(&mut self, note: u8) {
        let gated = self.p.play_mode == PlayMode::Gated;
        let (single, zones) = (&self.single, &self.zones);
        let releases = |v: &Voice| {
            v.is_held()
                && v.note == note
                && (gated
                    || zone_at(single, zones, v.zone).is_some_and(|z| z.loop_mode != LoopMode::Off))
        };
        let pool = &self.voices[..self.voice_count];
        let Some(trigger) = pool.iter().filter(|v| releases(v)).map(|v| v.trigger).min() else {
            return;
        };
        for i in 0..self.voice_count {
            if self.voices[i].trigger == trigger && releases(&self.voices[i]) {
                self.voices[i].envelope.gate_off();
            }
        }
    }

    fn render_voices(&mut self, outputs: &mut [f32], start: usize, len: usize) {
        if !self.multisample && self.single.sample.is_none() {
            return;
        }
        let ctx = RenderCtx {
            single: &self.single,
            zones: &self.zones,
            filter: self.p.filter,
            filter_key_track: self.p.filter_key_track,
            sample_rate: self.sample_rate,
            fade_step: 1.0 / (DECLICK_SECONDS * self.sample_rate).max(1.0),
        };
        let limit = self.voice_count;
        render_active_voices(
            &ctx,
            &mut self.voices[..limit],
            &mut self.cutoff,
            &mut self.resonance,
            outputs,
            start,
            len,
        );
    }

    /// Apply a queued event. The sampler has no use for release velocity yet.
    fn apply_midi(&mut self, note: u8, value: f32, is_on: bool) {
        if note == CHOKE_KEY {
            self.choke_voices();
        } else if is_on {
            self.note_on(note, value);
        } else {
            self.note_off(note);
        }
    }

    /// One `"playheads"` record per sounding voice of the shown zone (see the module docs).
    fn playheads_payload(&self) -> Vec<u8> {
        let (shown, frames) = if self.multisample {
            match self.zone_index(self.focused_zone) {
                Some(index) => (index as u16, self.zones[index].frames()),
                // No voice plays SINGLE_ZONE in multisample mode.
                None => (SINGLE_ZONE, 0),
            }
        } else {
            (SINGLE_ZONE, self.single.frames())
        };
        let frames = frames.max(1) as f64;
        let rate_ratio = self.sample_rate as f64;
        let voices = || {
            self.voices[..self.voice_count]
                .iter()
                .filter(move |v| v.active && v.zone == shown)
        };
        let count = voices().count();
        let mut bytes = Vec::with_capacity(4 + count * PLAYHEAD_RECORD_BYTES);
        bytes.extend_from_slice(&(count as u32).to_le_bytes());
        for v in voices() {
            let position = (v.position / frames).clamp(0.0, 1.0) as f32;
            let moving = if v.ending { 0.0 } else { v.direction };
            let velocity = (moving * v.increment * rate_ratio / frames) as f32;
            let level = (v.envelope.value() * v.gain * v.fade).clamp(0.0, 1.0);
            for value in [position, velocity, level] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        bytes
    }
}

impl AudioDevice for SamplerDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let interleaved = (sample_count * 2).min(outputs.len());
        outputs[..interleaved].fill(0.0);

        if !self.enabled {
            return;
        }
        if self.pitch_dirty {
            self.pitch_dirty = false;
            self.refresh_pitch();
        }
        self.frames_since_poll = self.frames_since_poll.saturating_add(sample_count);

        std::mem::swap(&mut self.queued_midi, &mut self.midi_scratch);
        self.queued_midi.clear();
        self.midi_scratch.sort_unstable_by_key(|e| e.0);

        let mut cursor = 0usize;
        let mut idx = 0usize;
        while idx < self.midi_scratch.len() {
            let span_end = self.midi_scratch[idx].0.min(sample_count);
            if span_end > cursor {
                self.render_voices(outputs, cursor, span_end - cursor);
                cursor = span_end;
            }
            let this_ofs = self.midi_scratch[idx].0;
            while idx < self.midi_scratch.len() && self.midi_scratch[idx].0 == this_ofs {
                let (_ofs, note, velocity, is_on) = self.midi_scratch[idx];
                self.apply_midi(note, velocity, is_on);
                idx += 1;
            }
        }
        if cursor < sample_count {
            self.render_voices(outputs, cursor, sample_count - cursor);
        }
        self.midi_scratch.clear();
        self.time_counter = self.time_counter.wrapping_add(1);

        let active = self.any_voice_active();
        self.sleep_state
            .check_activity(active || has_audio_signal(&outputs[..interleaved]));
    }

    fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
        let queued = match *event {
            NoteEvent::On { key, velocity, .. } => (frame_offset, key, velocity, true),
            NoteEvent::Off { key, release, .. } => (frame_offset, key, release, false),
            NoteEvent::Expression { .. } => return,
        };
        if self.queued_midi.len() >= MIDI_EVENT_CAP {
            return;
        }
        self.queued_midi.push(queued);
        self.sleep_state.mark_activity();
    }

    fn choke(&mut self, frame_offset: usize) {
        if self.queued_midi.len() < MIDI_EVENT_CAP {
            self.queued_midi.push((frame_offset, CHOKE_KEY, 0.0, false));
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        let Some((_, real)) = self.values.set(param_id, value) else {
            return;
        };
        self.sleep_state.mark_activity();
        self.apply(param_id, real);
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        let Some((_, real)) = self.values.set_offset(param_id, offset) else {
            return;
        };
        self.sleep_state.mark_activity();
        self.apply(param_id, real);
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.values.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.sampler"
    }

    fn device_name(&self) -> &str {
        "Sampler"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Instrument
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn midi_ports(&self) -> Vec<MidiPort> {
        vec![MidiPort {
            id: 0,
            name: "MIDI In".to_string(),
            flow: PortFlow::Input,
        }]
    }

    fn accepts_note_input(&self) -> bool {
        true
    }

    fn loading_state(&self) -> Option<String> {
        Some(self.single.loading_state.clone())
    }

    fn file_loading_support(&self) -> Option<FileLoadingSupport> {
        Some(FileLoadingSupport {
            description: "Audio Sample".to_string(),
            extensions: vec![
                ".wav".to_string(),
                ".mp3".to_string(),
                ".ogg".to_string(),
                ".WAV".to_string(),
                ".MP3".to_string(),
                ".OGG".to_string(),
            ],
        })
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        TABLE.infos()
    }

    fn reset(&mut self) {
        self.reset_voices();
        self.queued_midi.clear();
        self.midi_scratch.clear();
    }

    /// Adopt the new rate. The loaded sample keeps its own rate: playback already compensates
    /// through `sample_rate_ratio`, so it doesn't need decoding again.
    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate.max(1.0);
        self.voices = [Voice::idle(self.sample_rate); MAX_VOICES];
        self.cutoff.set_ramp(self.sample_rate, FILTER_RAMP_MS);
        self.resonance.set_ramp(self.sample_rate, FILTER_RAMP_MS);
        self.queued_midi.clear();
        self.midi_scratch.clear();
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.reset_voices();
        }
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn is_sleeping(&self) -> bool {
        self.sleep_state.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.sleep_state.mark_activity();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        self.sleep_state.check_activity(has_audio_activity)
    }

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if data_type != "playheads" {
            return Err(format!("Sampler does not support '{data_type}' data"));
        }
        if !self.playheads_subscribed {
            self.playheads_subscribed = true;
            self.frames_since_poll = 0;
            self.playheads_sent_voices = false;
        }
        self.sleep_state.mark_activity();
        Ok(())
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "playheads" {
            self.playheads_subscribed = false;
        }
    }

    /// See the module docs for the payload. A record with no voices goes out once, after the
    /// last voice ended.
    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        let interval = (self.sample_rate * PLAYHEAD_INTERVAL_SECONDS) as usize;
        if !self.playheads_subscribed || self.frames_since_poll < interval {
            return None;
        }
        self.frames_since_poll = 0;
        let bytes = self.playheads_payload();
        let has_voices = bytes[0] != 0;
        if !has_voices && !self.playheads_sent_voices {
            return None;
        }
        self.playheads_sent_voices = has_voices;
        Some(("playheads".to_string(), bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Reference mappings the table must keep (saved projects store these normalized values).
    fn speed_from_normalized(value: f32) -> f32 {
        SPEED_MIN * (SPEED_MAX / SPEED_MIN).powf(value.clamp(0.0, 1.0))
    }
    fn time_from_normalized(value: f32) -> f32 {
        TIME_MIN + value.clamp(0.0, 1.0) * (TIME_MAX - TIME_MIN)
    }
    fn voices_from_normalized(value: f32) -> usize {
        let span = (MAX_VOICES - VOICES_MIN) as f32;
        (value.clamp(0.0, 1.0) * span).round() as usize + VOICES_MIN
    }
    fn voices_to_normalized(count: usize) -> f32 {
        (count - VOICES_MIN) as f32 / (MAX_VOICES - VOICES_MIN) as f32
    }
    fn norm_of(id: ParamId, real: f32) -> f32 {
        TABLE.spec(id).unwrap().to_norm(real)
    }

    fn device() -> SamplerDevice {
        SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None)
    }

    /// Mono ramp `frame / frames` loaded at the device rate.
    fn ramp_device(frames: usize) -> SamplerDevice {
        let mut d = device();
        let samples = (0..frames).map(|i| i as f32 / frames as f32).collect();
        d.set_sample("r", samples, 1, 48_000);
        d
    }

    fn render(d: &mut SamplerDevice, frames: usize) -> Vec<f32> {
        let mut out = Vec::with_capacity(frames * 2);
        let mut left = frames;
        while left > 0 {
            let n = left.min(256);
            let mut block = vec![0.0; n * 2];
            d.process_block(&[], &mut block, n);
            out.extend_from_slice(&block);
            left -= n;
        }
        out
    }

    fn rms(interleaved: &[f32]) -> f32 {
        (interleaved.iter().map(|x| x * x).sum::<f32>() / interleaved.len() as f32).sqrt()
    }

    fn voice_at(position: f64, direction: f64) -> Voice {
        let mut v = Voice::idle(48_000.0);
        v.active = true;
        v.position = position;
        v.direction = direction;
        v
    }

    // === Pre-existing behavior ===

    #[test]
    fn key_track_transposes_from_root() {
        let at_root = playback_increment(1.0, 0.0, true, 60, 60);
        let up_octave = playback_increment(1.0, 0.0, true, 72, 60);
        assert!((at_root - 1.0).abs() < 1e-9);
        assert!((up_octave - 2.0).abs() < 1e-9);
    }

    #[test]
    fn key_track_off_ignores_note() {
        let a = playback_increment(1.0, 0.0, false, 36, 60);
        let b = playback_increment(1.0, 12.0, false, 80, 60);
        assert!((a - 1.0).abs() < 1e-9);
        assert!((b - 2.0).abs() < 1e-9);
    }

    #[test]
    fn speed_compounds_with_tune() {
        let rate = playback_increment(2.0, 12.0, false, 60, 60);
        assert!((rate - 4.0).abs() < 1e-9);
    }

    #[test]
    fn default_speed_normalized_is_log_midpoint() {
        let sampler = SamplerDevice::new_for_metadata();
        let normalized = sampler.get_parameter(PARAM_SPEED).unwrap();
        assert!(
            (normalized - 0.5).abs() < 1e-5,
            "unity speed must be OSC 0.5 (log), not linear (1.0-0.25)/(4-0.25)=0.2"
        );
        assert!((sampler.p.speed - 1.0).abs() < 1e-5);
    }

    #[test]
    fn preexisting_ids_keep_their_normalized_mapping() {
        let mut d = SamplerDevice::new_for_metadata();
        for n in [0.0_f32, 0.2, 0.5, 0.8, 1.0] {
            d.set_parameter(PARAM_VOLUME, n);
            assert!((d.p.volume - n * 2.0).abs() < 1e-5);
            d.set_parameter(PARAM_TUNE, n);
            assert!((d.p.tune - (n * 48.0 - 24.0)).abs() < 1e-4);
            d.set_parameter(PARAM_SPEED, n);
            let want = speed_from_normalized(n);
            assert!((d.p.speed - want).abs() < 1e-4 * want.max(1.0), "{n}");
            d.set_parameter(PARAM_ROOT, n);
            assert_eq!(d.p.root, (n * 127.0).round() as u8);
            d.set_parameter(PARAM_VELOCITY, n);
            assert!((d.p.velocity_amount - n).abs() < 1e-6);
            d.set_parameter(PARAM_VOICES, n);
            assert_eq!(d.p.voices, voices_from_normalized(n));
            assert_eq!(d.voice_count, voices_from_normalized(n));
            for id in [PARAM_ATTACK, PARAM_DECAY, PARAM_RELEASE] {
                d.set_parameter(id, n);
            }
            let want = time_from_normalized(n);
            assert!((d.p.attack - want).abs() < 1e-5);
            assert!((d.p.decay - want).abs() < 1e-5);
            assert!((d.p.release - want).abs() < 1e-5);
            d.set_parameter(PARAM_SUSTAIN, n);
            assert!((d.p.sustain - n).abs() < 1e-6);
            d.set_parameter(PARAM_PLAY_MODE, n);
            assert_eq!(d.p.play_mode == PlayMode::Gated, n >= 0.5);
            d.set_parameter(PARAM_KEY_TRACK, n);
            assert_eq!(d.p.key_track, n >= 0.5);
            for id in [
                PARAM_VOLUME,
                PARAM_TUNE,
                PARAM_SPEED,
                PARAM_VELOCITY,
                PARAM_SUSTAIN,
            ] {
                assert!((d.get_parameter(id).unwrap() - n).abs() < 1e-6);
            }
        }
    }

    #[test]
    fn sample_rate_ratio_compensates_44k_on_48k_device() {
        let ratio = sample_rate_ratio(44_100.0, 48_000.0);
        assert!((ratio - 44_100.0 / 48_000.0).abs() < 1e-12);
    }

    #[test]
    fn mismatched_sample_rate_slows_or_speeds_root_playback() {
        let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        sampler.set_sample("r", vec![0.5; 8], 2, 44_100);
        sampler.note_on(60, 1.0);
        let voice = sampler.voices.iter().find(|v| v.active).unwrap();
        let expected = 44_100.0 / 48_000.0;
        assert!((voice.increment - expected).abs() < 1e-9);
    }

    #[test]
    fn one_shot_ignores_note_off() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 1.0);
        sampler.note_off(60);
        assert!(sampler.voices.iter().any(|v| v.is_held()));
    }

    #[test]
    fn gated_releases_on_note_off() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_parameter(PARAM_PLAY_MODE, 1.0);
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 1.0);
        sampler.note_off(60);
        assert!(sampler
            .voices
            .iter()
            .any(|v| v.active && v.envelope.state() == AdsrState::Release));
    }

    #[test]
    fn attack_fades_in_from_silence() {
        let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        sampler.set_sample("r", vec![1.0; 256], 2, 48_000);
        sampler.note_on(60, 1.0);
        let mut out = vec![0.0; 16];
        sampler.process_block(&[], &mut out, 8);
        assert!(out[0].abs() < 0.1, "first sample should be near silence");
        assert!(
            out[0].abs() < out[14].abs(),
            "attack should rise across the block"
        );
    }

    #[test]
    fn adsr_params_roundtrip() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_parameter(PARAM_ATTACK, 0.5);
        sampler.set_parameter(PARAM_DECAY, 0.25);
        sampler.set_parameter(PARAM_SUSTAIN, 0.8);
        sampler.set_parameter(PARAM_RELEASE, 0.1);
        assert!((sampler.get_parameter(PARAM_ATTACK).unwrap() - 0.5).abs() < 1e-5);
        assert!((sampler.get_parameter(PARAM_DECAY).unwrap() - 0.25).abs() < 1e-5);
        assert!((sampler.get_parameter(PARAM_SUSTAIN).unwrap() - 0.8).abs() < 1e-5);
        assert!((sampler.get_parameter(PARAM_RELEASE).unwrap() - 0.1).abs() < 1e-5);
    }

    #[test]
    fn voices_roundtrip_and_default() {
        let mut sampler = SamplerDevice::new_for_metadata();
        assert_eq!(sampler.voice_count, DEFAULT_VOICES);
        sampler.set_parameter(PARAM_VOICES, voices_to_normalized(1));
        assert_eq!(sampler.voice_count, 1);
        sampler.set_parameter(PARAM_VOICES, 1.0);
        assert_eq!(sampler.voice_count, MAX_VOICES);
        assert!((sampler.get_parameter(PARAM_VOICES).unwrap() - 1.0).abs() < 1e-5);
    }

    #[test]
    fn retrigger_overlaps_until_voice_limit() {
        let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 1.0);
        sampler.note_on(60, 1.0);
        assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 2);

        sampler.set_parameter(PARAM_VOICES, voices_to_normalized(1));
        assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 1);

        sampler.note_on(60, 1.0);
        assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 1);
    }

    #[test]
    fn choke_fades_sounding_voices_to_silence() {
        let mut d = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        d.set_sample("c", vec![0.5; 48_000], 1, 48_000);
        d.note_on(60, 1.0);
        render(&mut d, 256);
        d.choke(0);
        let out = render(&mut d, 512);
        assert!(out[out.len() - 64..].iter().all(|s| *s == 0.0));
        assert!(!d.any_voice_active());
    }

    // === New parameters ===

    #[test]
    fn key_track_defaults_off_and_fine_is_a_cent_per_hundredth() {
        let mut d = ramp_device(100);
        assert!(!d.p.key_track);
        assert_eq!(d.get_parameter(PARAM_KEY_TRACK), Some(0.0));
        d.note_on(72, 1.0);
        let plain = d.voices.iter().find(|v| v.active).unwrap().increment;
        assert!(
            (plain - 1.0).abs() < 1e-9,
            "off: the note doesn't transpose"
        );

        d.set_parameter(PARAM_FINE, norm_of(PARAM_FINE, 100.0));
        d.note_on(60, 1.0);
        let fine = d
            .voices
            .iter()
            .filter(|v| v.active)
            .last()
            .unwrap()
            .increment;
        assert!((fine - 2.0_f64.powf(1.0 / 12.0)).abs() < 1e-6, "{fine}");
    }

    #[test]
    fn new_params_have_their_documented_defaults() {
        let d = SamplerDevice::new_for_metadata();
        let infos = d.parameters();
        let default_of = |id| infos.iter().find(|i| i.id == id).unwrap().default;
        assert_eq!(default_of(PARAM_ROOT), 60.0);
        assert_eq!(default_of(PARAM_CUTOFF), 1_000.0);
        assert_eq!(default_of(PARAM_SPEED), 100.0);
        assert_eq!(d.p.loop_mode, LoopMode::Off);
        assert!(d.p.filter.is_none());
        assert_eq!(infos.len(), PARAM_COUNT);
        assert_eq!(
            infos.iter().find(|i| i.id == PARAM_ROOT).unwrap().unit,
            "note"
        );
    }

    // === Regions ===

    #[test]
    fn start_end_restore_is_order_independent() {
        let mut d = ramp_device(1000);
        d.set_parameter(PARAM_START, 0.5);
        d.set_parameter(PARAM_END, 0.6);
        d.set_parameter(PARAM_START, 0.7);
        d.set_parameter(PARAM_END, 0.9);
        assert_eq!(d.get_parameter(PARAM_START), Some(0.7));
        assert!((d.single.regions.play.0 - 700.0).abs() < 1e-3);
        assert!((d.single.regions.play.1 - 900.0).abs() < 1e-3);
    }

    #[test]
    fn region_rejects_inverted_start_end() {
        let r = resolve_regions(100, 0.8, 0.2, 0.0, 1.0, 0.0);
        assert!(r.play.1 > r.play.0);
        assert!((r.play.0 - 20.0).abs() < 1e-3 && (r.play.1 - 80.0).abs() < 1e-3);
        let tiny = resolve_regions(100, 0.5, 0.5, 0.0, 1.0, 0.0);
        assert!(tiny.play.1 - tiny.play.0 >= MIN_REGION_FRAMES);
    }

    #[test]
    fn loop_is_clamped_into_the_play_region() {
        let r = resolve_regions(1000, 0.2, 0.8, 0.0, 1.0, 0.0);
        assert!((r.loop_.0 - 200.0).abs() < 1e-3 && (r.loop_.1 - 800.0).abs() < 1e-3);
        let r = resolve_regions(1000, 0.2, 0.8, 0.9, 0.95, 0.0);
        assert!(r.loop_.0 >= r.play.0 && r.loop_.1 <= r.play.1);
        assert!(r.loop_len() >= MIN_LOOP_FRAMES);
        let r = resolve_regions(1000, 0.2, 0.8, 0.6, 0.4, 0.0);
        assert!(
            (r.loop_.0 - 400.0).abs() < 1e-3 && (r.loop_.1 - 600.0).abs() < 1e-3,
            "inverted loop points are ordered"
        );
    }

    // === Voice state machine ===

    #[test]
    fn loop_off_stops_at_the_boundary_without_reading_past() {
        let r = resolve_regions(100, 0.2, 0.5, 0.0, 1.0, 0.0);
        let mut v = voice_at(r.play.0, 1.0);
        for _ in 0..100 {
            advance(&mut v, &r, LoopMode::Off);
            assert!(v.position < r.play.1);
        }
        assert!(v.ending);

        let mut v = voice_at(r.play.1 - 1.0, -1.0);
        for _ in 0..100 {
            advance(&mut v, &r, LoopMode::Off);
            assert!(v.position >= r.play.0);
        }
        assert!(v.ending);
    }

    #[test]
    fn sample_end_declicks_and_ends_the_voice() {
        let mut d = device();
        d.set_sample("r", vec![0.5, 0.5], 2, 48_000);
        d.note_on(60, 1.0);
        render(&mut d, 8);
        assert!(d.voices.iter().any(|v| v.active && v.ending));
        render(&mut d, 400);
        assert!(!d.voices.iter().any(|v| v.active), "ended after the fade");
    }

    #[test]
    fn loop_on_wraps_forward_and_reverse() {
        let r = resolve_regions(100, 0.0, 1.0, 0.3, 0.4, 0.0);
        let mut v = voice_at(20.0, 1.0);
        let mut entered = false;
        for _ in 0..200 {
            advance(&mut v, &r, LoopMode::On);
            entered |= v.in_loop;
            if v.in_loop {
                assert!(
                    v.position >= 29.999 && v.position < 40.001,
                    "{}",
                    v.position
                );
            }
            assert!(!v.ending);
        }
        assert!(entered);

        let mut v = voice_at(99.0, -1.0);
        let mut entered = false;
        for _ in 0..200 {
            advance(&mut v, &r, LoopMode::On);
            entered |= v.in_loop;
            if v.in_loop {
                assert!(
                    v.position >= 29.999 && v.position <= 40.001,
                    "{}",
                    v.position
                );
            }
            assert!(!v.ending && v.direction < 0.0);
        }
        assert!(entered);
    }

    #[test]
    fn ping_pong_bounces_between_the_loop_points() {
        for start_dir in [1.0, -1.0] {
            let r = resolve_regions(100, 0.0, 1.0, 0.3, 0.4, 0.0);
            let mut v = voice_at(if start_dir > 0.0 { 20.0 } else { 99.0 }, start_dir);
            let mut flips = 0;
            let mut last = v.direction;
            for _ in 0..200 {
                advance(&mut v, &r, LoopMode::PingPong);
                if v.in_loop {
                    assert!(v.position >= 29.999 && v.position <= 40.001);
                }
                if v.direction != last {
                    flips += 1;
                    last = v.direction;
                }
                assert!(!v.ending);
            }
            assert!(flips >= 3, "dir {start_dir}: {flips} bounces");
        }
    }

    #[test]
    fn loop_survives_shrinking_and_catches_a_late_voice() {
        // A voice past a shrunk loop end wraps back inside with rem_euclid.
        let r = resolve_regions(100, 0.0, 1.0, 0.3, 0.4, 0.0);
        let mut v = voice_at(39.5, 1.0);
        v.in_loop = true;
        let small = resolve_regions(100, 0.0, 1.0, 0.3, 0.34, 0.0);
        advance(&mut v, &small, LoopMode::On);
        assert!(v.position >= 30.0 && v.position < 34.0, "{}", v.position);
        // A voice before the loop plays into it when the loop turns on.
        let mut v = voice_at(10.0, 1.0);
        for _ in 0..30 {
            advance(&mut v, &r, LoopMode::On);
        }
        assert!(v.in_loop);
    }

    #[test]
    fn note_off_releases_a_looping_one_shot_and_the_loop_runs_through_release() {
        let mut d = ramp_device(100);
        d.set_parameter(PARAM_LOOP_MODE, 0.5);
        d.set_parameter(PARAM_RELEASE, norm_of(PARAM_RELEASE, 0.5));
        d.note_on(60, 1.0);
        render(&mut d, 256);
        d.note_off(60);
        let tail = render(&mut d, 4_800);
        let v = d.voices.iter().find(|v| v.active).unwrap();
        assert_eq!(v.envelope.state(), AdsrState::Release);
        assert!(!v.ending, "still looping, not ended");
        assert!(rms(&tail[tail.len() - 400..]) > 0.0);
    }

    #[test]
    fn reverse_starts_at_the_end_and_plays_backwards() {
        let mut d = ramp_device(1000);
        d.set_parameter(PARAM_REVERSE, 1.0);
        d.note_on(60, 1.0);
        let out = render(&mut d, 300);
        // The ramp falls: the later (post-attack) output is lower than the earlier.
        assert!(out[2 * 200] > out[2 * 290]);
        assert!(out[2 * 290] > 0.0);
    }

    // === Crossfade ===

    fn max_step_across_wrap(mode: LoopMode, xfade: f32) -> f32 {
        let frames = 1000;
        let samples: Vec<f32> = (0..frames).map(|i| i as f32 / frames as f32).collect();
        let s = SampleBuffer {
            samples,
            channels: 1,
            frames,
            sample_rate: 48_000.0,
        };
        let r = resolve_regions(frames, 0.0, 1.0, 0.4, 0.6, xfade);
        let mut v = voice_at(450.0, 1.0);
        v.in_loop = true;
        let mut last = read_voice(&s, &v, &r, mode).0;
        let mut worst = 0.0f32;
        for _ in 0..600 {
            advance(&mut v, &r, mode);
            let now = read_voice(&s, &v, &r, mode).0;
            worst = worst.max((now - last).abs());
            last = now;
        }
        worst
    }

    #[test]
    fn crossfade_zero_is_a_hard_jump_and_positive_is_continuous() {
        assert!(max_step_across_wrap(LoopMode::On, 0.0) > 0.15);
        assert!(max_step_across_wrap(LoopMode::On, 0.5) < 0.02);
    }

    #[test]
    fn crossfade_is_capped_by_the_loop_and_the_material_outside_it() {
        let r = resolve_regions(1000, 0.0, 1.0, 0.0, 0.5, 1.0);
        assert_eq!(r.xfade_fwd, 0.0, "nothing before frame 0");
        assert_eq!(r.xfade_rev, 250.0, "half the loop");
        let r = resolve_regions(1000, 0.0, 1.0, 0.1, 0.9, 1.0);
        assert!((r.xfade_fwd - 100.0).abs() < 1e-3);
        assert!((r.xfade_rev - 100.0).abs() < 1e-3);
    }

    #[test]
    fn ping_pong_ignores_the_crossfade() {
        assert!(max_step_across_wrap(LoopMode::PingPong, 1.0) < 0.005);
        let s = SampleBuffer {
            samples: (0..100).map(|i| i as f32).collect(),
            channels: 1,
            frames: 100,
            sample_rate: 48_000.0,
        };
        let r = resolve_regions(100, 0.0, 1.0, 0.2, 0.8, 1.0);
        let mut v = voice_at(79.0, 1.0);
        v.in_loop = true;
        assert_eq!(read_voice(&s, &v, &r, LoopMode::PingPong).0, 79.0);
    }

    // === Live pitch ===

    #[test]
    fn pitch_params_move_sounding_voices() {
        let mut d = ramp_device(10_000);
        d.note_on(60, 1.0);
        render(&mut d, 16);
        assert!((d.voices[0].increment - 1.0).abs() < 1e-9);
        d.set_parameter(PARAM_TUNE, 1.0);
        render(&mut d, 16);
        assert!((d.voices[0].increment - 4.0).abs() < 1e-6);
        d.set_parameter(PARAM_SPEED, norm_of(PARAM_SPEED, 200.0));
        render(&mut d, 16);
        assert!((d.voices[0].increment - 8.0).abs() < 1e-4);
    }

    // === Filter ===

    fn sine_device(hz: f32) -> SamplerDevice {
        let mut d = device();
        let samples = (0..48_000)
            .map(|i| (std::f32::consts::TAU * hz * i as f32 / 48_000.0).sin())
            .collect();
        d.set_sample("r", samples, 1, 48_000);
        d
    }

    #[test]
    fn lp12_attenuates_a_high_sine_and_off_is_a_bypass() {
        let mut dry = sine_device(5_000.0);
        dry.note_on(60, 1.0);
        let dry_out = render(&mut dry, 9_600);

        let mut wet = sine_device(5_000.0);
        wet.set_parameter(PARAM_FILTER_TYPE, 1.0 / 6.0);
        wet.set_parameter(PARAM_CUTOFF, norm_of(PARAM_CUTOFF, 200.0));
        wet.note_on(60, 1.0);
        let wet_out = render(&mut wet, 9_600);
        let (dry_rms, wet_rms) = (rms(&dry_out[9_600..]), rms(&wet_out[9_600..]));
        assert!(dry_rms > 0.3, "{dry_rms}");
        assert!(wet_rms < dry_rms * 0.05, "{wet_rms} vs {dry_rms}");
    }

    #[test]
    fn filter_key_track_follows_the_pitch_from_the_root() {
        assert!((tracked_cutoff(1_000.0, 1.0, 72, 60) - 2_000.0).abs() < 0.5);
        assert!((tracked_cutoff(1_000.0, 1.0, 48, 60) - 500.0).abs() < 0.5);
        assert!((tracked_cutoff(1_000.0, 0.5, 72, 60) - 1_414.2).abs() < 1.0);
        assert!((tracked_cutoff(1_000.0, 0.0, 96, 60) - 1_000.0).abs() < 1e-3);
    }

    #[test]
    fn switching_filter_types_while_sounding_stays_finite() {
        let mut d = device();
        let mut rng = 1u32;
        let noise: Vec<f32> = (0..48_000)
            .map(|_| {
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                rng as i32 as f32 / i32::MAX as f32
            })
            .collect();
        d.set_sample("r", noise, 1, 48_000);
        d.set_parameter(PARAM_RESONANCE, 1.0);
        d.set_parameter(PARAM_LOOP_MODE, 0.5);
        for n in 0..8 {
            d.note_on(48 + n * 3, 1.0);
        }
        for step in 0..64 {
            d.set_parameter(PARAM_FILTER_TYPE, (step % 7) as f32 / 6.0);
            d.set_parameter(PARAM_CUTOFF, (step % 5) as f32 / 4.0);
            let out = render(&mut d, 64);
            assert!(
                out.iter().all(|x| x.is_finite() && x.abs() < 100.0),
                "{step}"
            );
        }
    }

    /// Worst case: 64 looping voices through LP24. Run with `--release -- --ignored`.
    #[test]
    #[ignore]
    fn sixty_four_voice_filter_cost() {
        let mut d = sine_device(220.0);
        d.set_parameter(PARAM_VOICES, 1.0);
        d.set_parameter(PARAM_LOOP_MODE, 0.5);
        d.set_parameter(PARAM_FILTER_TYPE, 2.0 / 6.0);
        d.set_parameter(PARAM_FILTER_KEY_TRACK, 1.0);
        for n in 0..64 {
            d.note_on(30 + n, 1.0);
        }
        let blocks = 1_000;
        let mut out = vec![0.0; 512 * 2];
        let t = std::time::Instant::now();
        for _ in 0..blocks {
            d.process_block(&[], &mut out, 512);
        }
        let per_block = t.elapsed().as_secs_f64() / blocks as f64;
        let budget = 512.0 / 48_000.0;
        println!(
            "64 voices: {:.1}% of the block budget",
            100.0 * per_block / budget
        );
        assert!(per_block < budget * 0.5);
    }

    // === Playheads stream ===

    fn decode(bytes: &[u8]) -> Vec<[f32; 3]> {
        let count = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
        assert_eq!(bytes.len(), 4 + count * PLAYHEAD_RECORD_BYTES);
        (0..count)
            .map(|i| {
                let f = |k: usize| {
                    let at = 4 + i * PLAYHEAD_RECORD_BYTES + k * 4;
                    f32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
                };
                [f(0), f(1), f(2)]
            })
            .collect()
    }

    fn poll_after(d: &mut SamplerDevice, frames: usize) -> Option<Vec<u8>> {
        render(d, frames);
        d.poll_device_data().map(|(kind, bytes)| {
            assert_eq!(kind, "playheads");
            bytes
        })
    }

    #[test]
    fn playheads_stream_reports_every_voice() {
        let mut d = ramp_device(48_000);
        assert!(d.subscribe_data("spectrum").is_err());
        d.subscribe_data("playheads").unwrap();
        d.note_on(60, 1.0);
        d.note_on(64, 1.0);
        let first = decode(&poll_after(&mut d, 2_048).expect("record"));
        assert_eq!(first.len(), 2);
        let second = decode(&poll_after(&mut d, 2_048).expect("record"));
        for (a, b) in first.iter().zip(&second) {
            assert!(b[0] > a[0], "positions advance: {a:?} -> {b:?}");
            assert!(a[1] > 0.0 && (0.0..=1.0).contains(&a[2]));
        }
        d.unsubscribe_data("playheads");
        assert!(poll_after(&mut d, 2_048).is_none());
    }

    #[test]
    fn playheads_stream_sends_one_empty_record_when_the_last_voice_ends() {
        let mut d = device();
        d.set_sample("r", vec![0.5; 3_000], 1, 48_000);
        d.subscribe_data("playheads").unwrap();
        assert!(poll_after(&mut d, 2_048).is_none(), "nothing to say yet");
        d.note_on(60, 1.0);
        let playing = decode(&poll_after(&mut d, 2_048).expect("record"));
        assert_eq!(playing.len(), 1);
        let ended = decode(&poll_after(&mut d, 2_048).expect("empty record"));
        assert!(ended.is_empty());
        assert!(poll_after(&mut d, 2_048).is_none(), "only once");
    }

    // === Multisample (spec 023) ===

    fn multi() -> SamplerDevice {
        let mut d = device();
        d.set_multisample(true);
        d
    }

    fn zone_settings(key: (i32, i32), vel: (i32, i32), root: u8) -> ZoneSettings {
        ZoneSettings {
            ranges: ZoneRanges::new(key, vel, (0, 0), (0, 0)),
            root,
            ..ZoneSettings::default()
        }
    }

    /// Zone `id` with `frames` of constant `value`, loaded at the device rate.
    fn add_zone(d: &mut SamplerDevice, id: u32, settings: ZoneSettings, frames: usize) {
        d.set_zone(id, &settings);
        d.set_zone_sample(id, "", vec![0.5; frames], 1, 48_000);
    }

    /// Zone ids of the sounding voices, in voice order.
    fn sounding(d: &SamplerDevice) -> Vec<u32> {
        d.voices
            .iter()
            .filter(|v| v.active)
            .map(|v| d.zones[v.zone as usize].id)
            .collect()
    }

    #[test]
    fn multisample_plays_matching_zone_only() {
        // REQ-016: A = C3–B3 @ 1–64, B = C3–B3 @ 65–127.
        let mut d = multi();
        add_zone(&mut d, 1, zone_settings((60, 71), (1, 64), 60), 48_000);
        add_zone(&mut d, 2, zone_settings((60, 71), (65, 127), 60), 48_000);
        d.note_on(64, 40.0 / 127.0);
        assert_eq!(sounding(&d), vec![1]);
        d.reset();
        d.note_on(64, 100.0 / 127.0);
        assert_eq!(sounding(&d), vec![2]);
        d.reset();
        d.note_on(40, 1.0);
        assert!(sounding(&d).is_empty(), "outside every zone");
        d.note_on(60, 1.0);
        assert!(rms(&render(&mut d, 512)) > 0.1);
    }

    #[test]
    fn zone_key_track_follows_device_param() {
        // REQ-018: Key Track defaults off, so a zone plays at its natural pitch; switched on, a
        // zone with root C3 plays E3 four semitones up.
        let mut d = multi();
        assert!(!d.p.key_track);
        add_zone(&mut d, 1, zone_settings((60, 64), (1, 127), 60), 1_000);
        d.note_on(64, 1.0);
        let inc = |d: &SamplerDevice| d.voices.iter().find(|v| v.active).unwrap().increment;
        assert!((inc(&d) - 1.0).abs() < 1e-9, "{}", inc(&d));
        d.set_parameter(PARAM_KEY_TRACK, 1.0);
        render(&mut d, 16);
        assert!(
            (inc(&d) - 2.0_f64.powf(4.0 / 12.0)).abs() < 1e-9,
            "{}",
            inc(&d)
        );
    }

    #[test]
    fn device_tune_ignored_in_multisample() {
        // REQ-017: device Root/Tune/Fine don't reach a zone; its own tune and the device-wide
        // Speed do, also on sounding voices.
        let mut d = multi();
        d.set_parameter(PARAM_TUNE, 1.0);
        d.set_parameter(PARAM_FINE, 1.0);
        d.set_parameter(PARAM_ROOT, 0.0);
        let mut s = zone_settings((0, 127), (1, 127), 60);
        s.tune = 0.5;
        add_zone(&mut d, 1, s, 48_000);
        d.note_on(60, 1.0);
        let inc = |d: &SamplerDevice| d.voices.iter().find(|v| v.active).unwrap().increment;
        assert!((inc(&d) - 2.0_f64.powf(0.5 / 12.0)).abs() < 1e-6);
        d.set_parameter(PARAM_TUNE, 0.0);
        d.set_parameter(PARAM_SPEED, norm_of(PARAM_SPEED, 200.0));
        render(&mut d, 16);
        assert!((inc(&d) - 2.0 * 2.0_f64.powf(0.5 / 12.0)).abs() < 1e-4);
        s.tune = 12.0;
        d.set_zone(1, &s);
        render(&mut d, 16);
        assert!(
            (inc(&d) - 4.0).abs() < 1e-4,
            "zone edits move sounding voices"
        );
    }

    #[test]
    fn note_off_releases_all_stacked_voices() {
        let mut d = multi();
        d.set_parameter(PARAM_PLAY_MODE, 1.0);
        add_zone(&mut d, 1, zone_settings((0, 127), (1, 127), 60), 48_000);
        add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
        d.note_on(60, 1.0);
        d.note_on(60, 1.0);
        assert_eq!(sounding(&d).len(), 4);
        d.note_off(60);
        let released = |d: &SamplerDevice| {
            d.voices
                .iter()
                .filter(|v| v.active && v.envelope.state() == AdsrState::Release)
                .map(|v| v.trigger)
                .collect::<Vec<_>>()
        };
        let first = released(&d);
        assert_eq!(first.len(), 2, "both voices of the first note-on");
        assert_eq!(first[0], first[1]);
        d.note_off(60);
        assert_eq!(released(&d).len(), 4);
    }

    #[test]
    fn note_off_releases_a_looping_zone_in_one_shot() {
        let mut d = multi();
        let mut looping = zone_settings((0, 127), (1, 127), 60);
        looping.loop_mode = 1;
        add_zone(&mut d, 1, looping, 48_000);
        add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
        d.note_on(60, 1.0);
        d.note_off(60);
        let states: Vec<(u32, AdsrState)> = d
            .voices
            .iter()
            .filter(|v| v.active)
            .map(|v| (d.zones[v.zone as usize].id, v.envelope.state()))
            .collect();
        assert!(states.contains(&(1, AdsrState::Release)), "{states:?}");
        assert!(states
            .iter()
            .any(|&(id, st)| id == 2 && st != AdsrState::Release));
    }

    #[test]
    fn voices_cap_counts_zone_voices() {
        // REQ-019: Voices = 2, two stacked zones: the second note steals both older voices.
        let mut d = multi();
        d.set_parameter(PARAM_VOICES, voices_to_normalized(2));
        add_zone(&mut d, 1, zone_settings((0, 127), (1, 127), 60), 48_000);
        add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
        d.note_on(60, 1.0);
        assert_eq!(sounding(&d).len(), 2);
        d.note_on(62, 1.0);
        let notes: Vec<u8> = d
            .voices
            .iter()
            .filter(|v| v.active)
            .map(|v| v.note)
            .collect();
        assert_eq!(notes, vec![62, 62]);
    }

    #[test]
    fn remove_zone_remaps_voices() {
        let mut d = multi();
        for (id, key) in [(10, 60), (11, 62), (12, 64)] {
            add_zone(
                &mut d,
                id,
                zone_settings((key, key), (1, 127), key as u8),
                48_000,
            );
        }
        for key in [60, 62, 64] {
            d.note_on(key, 1.0);
        }
        d.remove_zone(10);
        assert_eq!(d.zones.len(), 2);
        let mut playing: Vec<(u32, u8)> = d
            .voices
            .iter()
            .filter(|v| v.active)
            .map(|v| (d.zones[v.zone as usize].id, v.note))
            .collect();
        playing.sort();
        assert_eq!(
            playing,
            vec![(11, 62), (12, 64)],
            "voices follow the moved zone"
        );
        assert!(rms(&render(&mut d, 256)) > 0.0);
        d.remove_zone(12);
        d.remove_zone(99);
        assert_eq!(sounding(&d), vec![11]);
    }

    #[test]
    fn mode_switch_kills_voices() {
        let mut d = ramp_device(48_000);
        d.note_on(60, 1.0);
        d.set_multisample(true);
        assert!(!d.any_voice_active());
        add_zone(&mut d, 1, zone_settings((0, 127), (1, 127), 60), 48_000);
        d.note_on(60, 1.0);
        d.set_multisample(true);
        assert!(d.any_voice_active(), "same mode again is a no-op");
        d.set_multisample(false);
        assert!(!d.any_voice_active());
        assert!(d.zones.is_empty() && d.groups.is_empty());
        d.set_zone(1, &zone_settings((0, 127), (1, 127), 60));
        assert!(d.zones.is_empty(), "zones need multisample mode");
        d.note_on(60, 1.0);
        assert_eq!(d.voices.iter().filter(|v| v.active).count(), 1);
        assert_eq!(
            d.voices.iter().find(|v| v.active).unwrap().zone,
            SINGLE_ZONE
        );
    }

    #[test]
    fn groups_gain_mute_and_removal() {
        let mut d = multi();
        let mut soft = zone_settings((0, 127), (1, 127), 60);
        soft.group_id = 3;
        add_zone(&mut d, 1, soft, 48_000);
        add_zone(&mut d, 2, zone_settings((0, 127), (1, 127), 60), 48_000);
        assert_eq!(
            d.zones[0].group_index, 0,
            "missing group falls back to Ungrouped"
        );
        d.set_zone_group(3, 0.5, false, false, GroupPlayMode::All);
        assert_eq!(d.zones[0].group_index, 1, "relinked when the group arrives");
        d.note_on(60, 1.0);
        let gains: Vec<(u32, f32)> = d
            .voices
            .iter()
            .filter(|v| v.active)
            .map(|v| (d.zones[v.zone as usize].id, v.gain))
            .collect();
        assert_eq!(gains, vec![(1, 0.5), (2, 1.0)]);
        d.reset();
        d.set_zone_group(3, 0.5, false, true, GroupPlayMode::All);
        d.note_on(60, 1.0);
        assert_eq!(sounding(&d), vec![1], "solo");
        d.reset();
        d.remove_zone_group(3);
        assert!(!d.any_solo);
        assert_eq!(
            (d.zones[0].group_id, d.zones[0].group_index),
            (UNGROUPED, 0)
        );
        d.note_on(60, 1.0);
        assert_eq!(sounding(&d), vec![1, 2]);
        d.remove_zone_group(UNGROUPED);
        assert_eq!(d.groups.len(), 1);
    }

    #[test]
    fn velocity_fade_scales_the_voice() {
        // REQ-030 example: velocity 1–80 with a fade-out of 20, hit at 70.
        let mut d = multi();
        let mut s = zone_settings((0, 127), (1, 80), 60);
        s.ranges = ZoneRanges::new((0, 127), (1, 80), (0, 0), (0, 20));
        add_zone(&mut d, 1, s, 48_000);
        d.note_on(60, 70.0 / 127.0);
        let v = d.voices.iter().find(|v| v.active).unwrap();
        assert!((v.gain - (FRAC_PI_2 * 0.5).cos() * (70.0 / 127.0)).abs() < 1e-5);
        d.reset();
        d.note_on(60, 80.0 / 127.0);
        assert!(!d.any_voice_active(), "silent at the faded edge: no voice");
    }

    /// 512 zones (four per key) and 64 note-ons stay far inside one block's budget.
    #[test]
    fn many_zones_note_on_is_bounded() {
        let mut d = multi();
        d.set_parameter(PARAM_VOICES, 1.0);
        for id in 0..MAX_ZONES as u32 {
            let key = (id / 4) as i32;
            add_zone(
                &mut d,
                id,
                zone_settings((key, key), (1, 127), key as u8),
                64,
            );
        }
        assert_eq!(d.zones.len(), MAX_ZONES);
        let cap = d.match_scratch.capacity();
        let t = std::time::Instant::now();
        for n in 0..64u8 {
            d.note_on(n * 2, 1.0);
        }
        let elapsed = t.elapsed();
        assert_eq!(d.match_scratch.capacity(), cap);
        assert_eq!(d.voices.iter().filter(|v| v.active).count(), MAX_VOICES);
        // Generous for debug builds; release is orders of magnitude faster.
        assert!(elapsed.as_millis() < 50, "{elapsed:?}");
    }

    #[test]
    fn stale_zone_load_ignored() {
        let mut d = multi();
        d.set_zone(1, &zone_settings((0, 127), (1, 127), 60));
        d.begin_zone_load(1, "new".to_string());
        d.set_zone_sample(1, "old", vec![0.5; 100], 1, 48_000);
        assert!(d.zones[0].sample.is_none(), "stale request ignored");
        d.set_zone_sample(7, "new", vec![0.5; 100], 1, 48_000);
        assert_eq!(d.zones.len(), 1, "unknown zone ignored");
        d.set_zone_sample(1, "new", vec![0.5; 100], 1, 48_000);
        assert_eq!(d.zones[0].frames(), 100);
        assert_eq!(d.zones[0].loading_state, "ready");
    }

    #[test]
    fn playheads_only_focused_zone() {
        // REQ-024: a chord across two zones shows only the focused zone's voices.
        let mut d = multi();
        add_zone(&mut d, 1, zone_settings((0, 63), (1, 127), 60), 24_000);
        add_zone(&mut d, 2, zone_settings((64, 127), (1, 127), 72), 48_000);
        d.subscribe_data("playheads").unwrap();
        d.note_on(60, 1.0);
        d.note_on(62, 1.0);
        d.note_on(72, 1.0);
        d.set_focus(1);
        let heads = decode(&poll_after(&mut d, 2_048).expect("record"));
        assert_eq!(heads.len(), 2);
        // ~2_048 frames into a 24_000-frame zone, not normalized over zone 2's 48_000.
        assert!((heads[0][0] - 2_048.0 / 24_000.0).abs() < 0.01, "{heads:?}");
        d.set_focus(2);
        assert_eq!(decode(&poll_after(&mut d, 2_048).unwrap()).len(), 1);
        d.set_focus(9);
        assert!(decode(&poll_after(&mut d, 2_048).unwrap()).is_empty());
    }

    #[test]
    fn failed_zone_is_silent_others_play() {
        let (tx, rx) = crossbeam::channel::unbounded();
        let mut d = SamplerDevice::new(48_000.0, 2, DevicePath::root(0), Some(tx));
        d.set_multisample(true);
        d.set_zone(1, &zone_settings((0, 63), (1, 127), 60));
        d.set_zone(2, &zone_settings((64, 127), (1, 127), 72));
        d.begin_zone_load(1, "a".to_string());
        d.begin_zone_load(2, "b".to_string());
        d.fail_zone_load(1, "a", "file not found");
        d.set_zone_sample(2, "b", vec![0.5; 48_000], 1, 48_000);
        let states: Vec<(u32, String)> = rx
            .try_iter()
            .filter_map(|s| match s {
                EngineStatus::SamplerZoneLoadingState { zone_id, state, .. } => {
                    Some((zone_id, state))
                }
                _ => None,
            })
            .collect();
        assert!(states.contains(&(1, "failed:file not found".to_string())));
        assert!(states.contains(&(2, "ready".to_string())));
        d.note_on(60, 1.0);
        assert!(!d.any_voice_active(), "the failed zone is silent");
        d.note_on(72, 1.0);
        assert_eq!(sounding(&d), vec![2]);
        d.resend_zone_states();
        assert_eq!(rx.try_iter().count(), 2, "state/get resends every zone");
    }

    // === Single-mode fixture (spec 023 T-005) ===

    /// Per-block (bit hash, RMS) of a fixed single-mode render: two scenarios covering a
    /// reversed crossfaded loop through LP24 with key tracking and a mid-note pitch change, and
    /// a forward Ping-Pong loop in a trimmed region with a gated release. Recorded on the code
    /// before the zone refactor, so the zone path must reproduce it bit for bit.
    fn single_mode_fixture() -> Vec<(u64, f32)> {
        let on = |key, velocity| NoteEvent::On {
            note_id: 0,
            key,
            velocity,
        };
        let off = |key| NoteEvent::Off {
            note_id: 0,
            key,
            release: 0.5,
        };
        let samples: Vec<f32> = (0..24_000)
            .flat_map(|i| {
                let t = i as f32 / 48_000.0;
                let l = (std::f32::consts::TAU * 220.0 * t).sin() * 0.6 + (i % 97) as f32 / 400.0;
                let r = (std::f32::consts::TAU * 331.0 * t).sin() * 0.5 - (i % 53) as f32 / 300.0;
                [l, r]
            })
            .collect();
        let mut blocks = Vec::new();
        let mut run = |d: &mut SamplerDevice, step: &dyn Fn(&mut SamplerDevice, usize)| {
            for block in 0..24 {
                step(d, block);
                let mut out = vec![0.0f32; 256 * 2];
                d.process_block(&[], &mut out, 256);
                let mut hash = 0xcbf2_9ce4_8422_2325u64;
                for x in &out {
                    hash = (hash ^ x.to_bits() as u64).wrapping_mul(0x100_0000_01b3);
                }
                blocks.push((hash, rms(&out)));
            }
        };

        let mut a = device();
        a.set_sample("a", samples.clone(), 2, 44_100);
        a.set_parameter(PARAM_KEY_TRACK, 1.0);
        a.set_parameter(PARAM_REVERSE, 1.0);
        a.set_parameter(PARAM_LOOP_MODE, 0.5);
        a.set_parameter(PARAM_LOOP_START, 0.3);
        a.set_parameter(PARAM_LOOP_END, 0.6);
        a.set_parameter(PARAM_CROSSFADE, norm_of(PARAM_CROSSFADE, 30.0));
        a.set_parameter(PARAM_FILTER_TYPE, 2.0 / 6.0);
        a.set_parameter(PARAM_CUTOFF, norm_of(PARAM_CUTOFF, 2_000.0));
        a.set_parameter(PARAM_RESONANCE, 0.4);
        a.set_parameter(PARAM_FILTER_KEY_TRACK, 0.5);
        a.set_parameter(PARAM_ROOT, norm_of(PARAM_ROOT, 57.0));
        run(&mut a, &|d, block| match block {
            0 => {
                d.send_note_event(&on(60, 0.8), 17);
                d.send_note_event(&on(67, 0.5), 130);
            }
            6 => d.set_parameter(PARAM_TUNE, norm_of(PARAM_TUNE, 3.0)),
            9 => d.set_parameter(PARAM_FINE, norm_of(PARAM_FINE, -40.0)),
            12 => d.send_note_event(&off(60), 64),
            14 => d.set_parameter(PARAM_CUTOFF, norm_of(PARAM_CUTOFF, 600.0)),
            _ => {}
        });

        let mut b = device();
        b.set_sample("b", samples, 2, 48_000);
        b.set_parameter(PARAM_PLAY_MODE, 1.0);
        b.set_parameter(PARAM_START, 0.1);
        b.set_parameter(PARAM_END, 0.7);
        b.set_parameter(PARAM_LOOP_MODE, 1.0);
        b.set_parameter(PARAM_LOOP_START, 0.2);
        b.set_parameter(PARAM_LOOP_END, 0.25);
        b.set_parameter(PARAM_VELOCITY, 0.5);
        b.set_parameter(PARAM_RELEASE, norm_of(PARAM_RELEASE, 0.05));
        run(&mut b, &|d, block| match block {
            0 => d.send_note_event(&on(48, 1.0), 0),
            3 => d.send_note_event(&on(72, 0.3), 200),
            8 => d.set_parameter(PARAM_SPEED, norm_of(PARAM_SPEED, 150.0)),
            10 => d.send_note_event(&off(48), 10),
            16 => d.send_note_event(&off(72), 0),
            _ => {}
        });
        blocks
    }

    /// Block hashes of [`single_mode_fixture`], recorded before the zone refactor.
    const SINGLE_MODE_FIXTURE: [u64; 48] = [
        14206959556813367124,
        17739970396413959311,
        16375157930753748474,
        7602148075931357404,
        6082375776345269119,
        15203502640084660737,
        15949397729668078016,
        6042357849161996924,
        852704725007154123,
        670701819617410879,
        12734231012316984580,
        9561008414411622059,
        15775830726042474405,
        420039192125132452,
        13113945623445414435,
        17631944859054756961,
        11536535370512420425,
        1208451133442155396,
        3431255463954417967,
        17325285220867068646,
        17479275945307132020,
        18140119704573567085,
        17017164475258079043,
        16355768676671113191,
        6492222591069766020,
        5825699738955252143,
        13718680342333316252,
        6719355808529577290,
        17381493052313732927,
        4591614688271898581,
        5731359738487504240,
        52773419609060268,
        16372273707863486210,
        4576185814297321848,
        12237556130485292987,
        15237157378695495744,
        3298634046225823811,
        130937475898819506,
        4757032436453216695,
        15448315486338422620,
        18275370344189011179,
        13458987673212643287,
        13340110937421438874,
        11029006805787110254,
        2295699601456801913,
        6090403448540165059,
        16384491379877320832,
        6305337554215224320,
    ];

    #[test]
    fn single_mode_unchanged_through_zone_path() {
        let blocks = single_mode_fixture();
        assert!(blocks.iter().any(|b| b.1 > 0.01), "the fixture makes sound");
        for (i, ((hash, rms), want)) in blocks.iter().zip(SINGLE_MODE_FIXTURE).enumerate() {
            assert_eq!(*hash, want, "block {i} changed (rms now {rms})");
        }
        assert_eq!(blocks.len(), SINGLE_MODE_FIXTURE.len());
    }
}
