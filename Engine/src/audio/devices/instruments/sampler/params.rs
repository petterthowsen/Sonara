//! The Sampler's parameter table: ids, modules, ranges and the decoded `Params`.

use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::ParamId;
use crate::audio::dsp::svf::FilterMode;

pub(super) const MAX_VOICES: usize = 64;

pub(super) const VOICES_MIN: usize = 1;

pub(super) const DEFAULT_VOICES: usize = 16;

pub(super) const MIDI_EVENT_CAP: usize = 64;

pub(super) const DEFAULT_ROOT: u8 = 60;

pub(super) const TUNE_RANGE: f32 = 24.0;

pub(super) const SPEED_MIN: f32 = 0.25;

pub(super) const SPEED_MAX: f32 = 4.0;

pub(super) const TIME_MIN: f32 = 0.001;

pub(super) const TIME_MAX: f32 = 2.0;

pub(super) const DEFAULT_ATTACK: f32 = 0.001;

pub(super) const DEFAULT_DECAY: f32 = 0.001;

pub(super) const DEFAULT_SUSTAIN: f32 = 1.0;

pub(super) const DEFAULT_RELEASE: f32 = 0.01;

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

pub(super) const PLAY_MODES: &[&str] = &["One-shot", "Gated"];
pub(super) const LOOP_MODES: &[&str] = &["Off", "On", "Ping-Pong"];
pub(super) const FILTER_TYPES: &[&str] = &["Off", "LP12", "LP24", "BP12", "BP24", "HP12", "HP24"];

pub(super) const AMP_MODULE: [ParamSpec; 6] = [
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

pub(super) const PITCH_MODULE: [ParamSpec; 4] = [
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

pub(super) const PLAYBACK_MODULE: [ParamSpec; 6] = [
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

pub(super) const LOOP_MODULE: [ParamSpec; 4] = [
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

pub(super) const FILTER_MODULE: [ParamSpec; 4] = [
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

pub(super) const PARAM_COUNT: usize = 24;
pub(super) const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[
    &AMP_MODULE,
    &PITCH_MODULE,
    &PLAYBACK_MODULE,
    &LOOP_MODULE,
    &FILTER_MODULE,
]);
pub(super) const SLOTS: [u8; 34] = slot_table(&SPECS);
pub(super) static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Playback mode: one-shot ignores note-off; gated fades out on note-off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PlayMode {
    OneShot,
    Gated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum LoopMode {
    Off,
    On,
    PingPong,
}

impl LoopMode {
    pub(super) fn from_index(index: usize) -> Self {
        match index {
            0 => LoopMode::Off,
            1 => LoopMode::On,
            _ => LoopMode::PingPong,
        }
    }
}

/// Decoded (real-valued) parameters.
#[derive(Clone, Copy, Debug)]
pub(super) struct Params {
    pub(super) volume: f32,
    /// Semitones.
    pub(super) tune: f32,
    /// Cents.
    pub(super) fine: f32,
    /// Playback rate multiplier (1 = native).
    pub(super) speed: f32,
    pub(super) root: u8,
    pub(super) key_track: bool,
    pub(super) play_mode: PlayMode,
    pub(super) velocity_amount: f32,
    pub(super) start: f32,
    pub(super) end: f32,
    pub(super) reverse: bool,
    pub(super) loop_mode: LoopMode,
    pub(super) loop_start: f32,
    pub(super) loop_end: f32,
    /// Crossfade as a fraction of the loop length.
    pub(super) crossfade: f32,
    pub(super) attack: f32,
    pub(super) decay: f32,
    pub(super) sustain: f32,
    pub(super) release: f32,
    pub(super) voices: usize,
    pub(super) filter: Option<FilterMode>,
    pub(super) cutoff_hz: f32,
    /// 0..1.
    pub(super) resonance: f32,
    /// 0..1.
    pub(super) filter_key_track: f32,
}

impl Params {
    pub(super) fn from_values(values: &ParamValues<PARAM_COUNT>) -> Self {
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

    pub(super) fn apply(&mut self, id: ParamId, real: f32) {
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
