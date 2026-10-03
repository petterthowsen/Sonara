//! PolySynth parameter table and the shared, decoded parameter block voices read from.
//!
//! IDs are grouped in blocks of ten per module: Osc 1 = 0.., Osc 2 = 10.., Noise = 20..,
//! Filter = 30.., Amp Env = 40.., Filter Env = 50.., LFO 1 = 60.., LFO 2 = 70.., Voice = 80..,
//! Output = 90.
//!
//! Every parameter also has a *slot*: its index in [`SPECS`]. Modulation routes and the
//! normalized value array are indexed by slot.

use super::super::param_table::{flatten, linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use super::super::{ParamId, ParamInfo};
use crate::audio::dsp::tempo_sync::{sync_beats, SYNC_CHOICES};
use crate::audio::dsp::FilterMode;
pub use crate::audio::modulation::lfo::LfoShape;
use crate::audio::modulation::lfo::LFO_SHAPES;

pub const OSC1: ParamId = 0;
pub const OSC2: ParamId = 10;
// Offsets inside an oscillator block.
pub const WAVE: ParamId = 0;
pub const PULSE_WIDTH: ParamId = 1;
pub const OCTAVE: ParamId = 2;
pub const SEMI: ParamId = 3;
pub const FINE: ParamId = 4;
pub const LEVEL: ParamId = 5;
pub const UNISON: ParamId = 6;
pub const UNISON_DETUNE: ParamId = 7;
pub const UNISON_SPREAD: ParamId = 8;

pub const NOISE_LEVEL: ParamId = 20;
pub const NOISE_COLOR: ParamId = 21;

pub const FILTER_TYPE: ParamId = 30;
pub const CUTOFF: ParamId = 31;
pub const RESONANCE: ParamId = 32;
pub const DRIVE: ParamId = 33;
pub const KEY_TRACK: ParamId = 34;

pub const AMP_ENV: ParamId = 40;
pub const FILTER_ENV: ParamId = 50;
// Offsets inside an envelope block.
pub const ATTACK: ParamId = 0;
pub const DECAY: ParamId = 1;
pub const SUSTAIN: ParamId = 2;
pub const RELEASE: ParamId = 3;
#[cfg(test)]
pub const AMP_ATTACK: ParamId = AMP_ENV + ATTACK;
#[cfg(test)]
pub const AMP_DECAY: ParamId = AMP_ENV + DECAY;
#[cfg(test)]
pub const AMP_SUSTAIN: ParamId = AMP_ENV + SUSTAIN;
#[cfg(test)]
pub const AMP_RELEASE: ParamId = AMP_ENV + RELEASE;

pub const LFO1: ParamId = 60;
pub const LFO2: ParamId = 70;
// Offsets inside an LFO block.
pub const LFO_SHAPE: ParamId = 0;
pub const LFO_RATE: ParamId = 1;
pub const LFO_SYNC: ParamId = 2;
pub const LFO_RETRIGGER: ParamId = 3;

pub const VOICE_MODE: ParamId = 80;
pub const POLYPHONY: ParamId = 81;
pub const GLIDE: ParamId = 82;
pub const VELOCITY: ParamId = 83;

pub const VOLUME: ParamId = 90;

/// Upper bounds the voice pool is sized for.
pub const MAX_UNISON: usize = 16;
pub const MAX_POLYPHONY: usize = 64;

/// Envelope times run 0.5 ms to 10 s on a skew-4 curve (625 ms at mid-knob).
const TIME_MIN: f32 = 0.0005;
const TIME_MAX: f32 = 10.0;
const TIME_SKEW: f32 = 4.0;
/// Volume below this is silence (the knob's bottom reads −inf).
pub const VOLUME_MIN_DB: f32 = -60.0;
pub const CUTOFF_MIN: f32 = 20.0;
pub const CUTOFF_MAX: f32 = 20_000.0;

const WAVES: &[&str] = &["Sine", "Triangle", "Saw", "Pulse"];
/// `Oscillator::process_block` code for each entry of `WAVES`.
const WAVE_CODES: [u8; 4] = [0, 3, 2, 1];
const OCTAVES: &[&str] = &["-3", "-2", "-1", "0", "+1", "+2", "+3"];
const SEMIS: &[&str] = &[
    "-12", "-11", "-10", "-9", "-8", "-7", "-6", "-5", "-4", "-3", "-2", "-1", "0", "+1", "+2",
    "+3", "+4", "+5", "+6", "+7", "+8", "+9", "+10", "+11", "+12",
];
const UNISON_COUNTS: &[&str] = &[
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16",
];
const FILTER_TYPES: &[&str] = &["LP 12", "LP 24", "HP 12", "BP 12"];
const FILTER_MODES: [FilterMode; 4] = [
    FilterMode::Lp12,
    FilterMode::Lp24,
    FilterMode::Hp12,
    FilterMode::Bp12,
];
const LFO_RETRIGGERS: &[&str] = &["Free", "Note"];
const MODES: &[&str] = &["Poly", "Mono", "Legato"];
const POLYPHONY_COUNTS: &[&str] = &[
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17",
    "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31", "32", "33",
    "34", "35", "36", "37", "38", "39", "40", "41", "42", "43", "44", "45", "46", "47", "48", "49",
    "50", "51", "52", "53", "54", "55", "56", "57", "58", "59", "60", "61", "62", "63", "64",
];

const TIME: Kind = Kind::Float {
    min: TIME_MIN,
    max: TIME_MAX,
    log: false,
    skew: TIME_SKEW,
};

macro_rules! osc_specs {
    ($base:expr, $module:literal, $wave:expr, $fine:expr, $level:expr) => {
        [
            spec(
                $base + WAVE,
                concat!($module, " Wave"),
                $module,
                "",
                Kind::Enum(WAVES),
                $wave,
            ),
            spec(
                $base + PULSE_WIDTH,
                concat!($module, " Pulse Width"),
                $module,
                "%",
                linear(5.0, 95.0),
                50.0,
            ),
            spec(
                $base + OCTAVE,
                concat!($module, " Octave"),
                $module,
                "",
                Kind::Enum(OCTAVES),
                3.0,
            ),
            spec(
                $base + SEMI,
                concat!($module, " Semi"),
                $module,
                "",
                Kind::Enum(SEMIS),
                12.0,
            ),
            spec(
                $base + FINE,
                concat!($module, " Fine"),
                $module,
                "cents",
                linear(-100.0, 100.0),
                $fine,
            ),
            spec(
                $base + LEVEL,
                concat!($module, " Level"),
                $module,
                "",
                linear(0.0, 1.0),
                $level,
            ),
            spec(
                $base + UNISON,
                concat!($module, " Unison"),
                $module,
                "",
                Kind::Enum(UNISON_COUNTS),
                0.0,
            ),
            spec(
                $base + UNISON_DETUNE,
                concat!($module, " Unison Detune"),
                $module,
                "cents",
                linear(0.0, 100.0),
                20.0,
            ),
            spec(
                $base + UNISON_SPREAD,
                concat!($module, " Unison Spread"),
                $module,
                "%",
                linear(0.0, 100.0),
                50.0,
            ),
        ]
    };
}

macro_rules! env_specs {
    ($base:expr, $prefix:literal, $module:literal, $a:expr, $d:expr, $s:expr, $r:expr) => {
        [
            spec(
                $base + ATTACK,
                concat!($prefix, " Attack"),
                $module,
                "s",
                TIME,
                $a,
            ),
            spec(
                $base + DECAY,
                concat!($prefix, " Decay"),
                $module,
                "s",
                TIME,
                $d,
            ),
            spec(
                $base + SUSTAIN,
                concat!($prefix, " Sustain"),
                $module,
                "",
                linear(0.0, 1.0),
                $s,
            ),
            spec(
                $base + RELEASE,
                concat!($prefix, " Release"),
                $module,
                "s",
                TIME,
                $r,
            ),
        ]
    };
}

macro_rules! lfo_specs {
    ($base:expr, $module:literal) => {
        [
            spec(
                $base + LFO_SHAPE,
                concat!($module, " Shape"),
                $module,
                "",
                Kind::Enum(LFO_SHAPES),
                0.0,
            ),
            spec(
                $base + LFO_RATE,
                concat!($module, " Rate"),
                $module,
                "Hz",
                Kind::Float {
                    min: 0.02,
                    max: 40.0,
                    log: true,
                    skew: 1.0,
                },
                5.0,
            ),
            spec(
                $base + LFO_SYNC,
                concat!($module, " Sync"),
                $module,
                "",
                Kind::Enum(SYNC_CHOICES),
                0.0,
            ),
            spec(
                $base + LFO_RETRIGGER,
                concat!($module, " Retrigger"),
                $module,
                "",
                Kind::Enum(LFO_RETRIGGERS),
                1.0,
            ),
        ]
    };
}

#[rustfmt::skip]
const OSC1_SPECS: [ParamSpec; 9] = osc_specs!(OSC1, "Osc 1", 2.0, 0.0, 0.8);
#[rustfmt::skip]
const OSC2_SPECS: [ParamSpec; 9] = osc_specs!(OSC2, "Osc 2", 3.0, 7.0, 0.0);
#[rustfmt::skip]
const NOISE_FILTER_SPECS: [ParamSpec; 7] = [
    spec(NOISE_LEVEL, "Noise Level", "Noise", "", linear(0.0, 1.0), 0.0),
    spec(NOISE_COLOR, "Noise Color", "Noise", "%", linear(0.0, 100.0), 50.0),
    spec(FILTER_TYPE, "Filter Type", "Filter", "", Kind::Enum(FILTER_TYPES), 1.0),
    spec(CUTOFF, "Filter Cutoff", "Filter", "Hz", Kind::Float { min: CUTOFF_MIN, max: CUTOFF_MAX, log: true, skew: 1.0 }, 2_000.0),
    spec(RESONANCE, "Filter Resonance", "Filter", "", linear(0.0, 1.0), 0.2),
    spec(DRIVE, "Filter Drive", "Filter", "dB", linear(0.0, 24.0), 0.0),
    spec(KEY_TRACK, "Filter Key Track", "Filter", "%", linear(0.0, 100.0), 0.0),
];
#[rustfmt::skip]
const AMP_ENV_SPECS: [ParamSpec; 4] = env_specs!(AMP_ENV, "Amp", "Amp Env", 0.002, 0.3, 1.0, 0.2);
#[rustfmt::skip]
const FILTER_ENV_SPECS: [ParamSpec; 4] = env_specs!(FILTER_ENV, "Filter Env", "Filter Env", 0.002, 0.4, 0.0, 0.3);
#[rustfmt::skip]
const LFO1_SPECS: [ParamSpec; 4] = lfo_specs!(LFO1, "LFO 1");
#[rustfmt::skip]
const LFO2_SPECS: [ParamSpec; 4] = lfo_specs!(LFO2, "LFO 2");
#[rustfmt::skip]
const VOICE_OUTPUT_SPECS: [ParamSpec; 5] = [
    spec(VOICE_MODE, "Voice Mode", "Voice", "", Kind::Enum(MODES), 0.0),
    spec(POLYPHONY, "Polyphony", "Voice", "", Kind::Enum(POLYPHONY_COUNTS), 15.0),
    spec(GLIDE, "Glide", "Voice", "s", Kind::Float { min: 0.0, max: 1.0, log: false, skew: 3.0 }, 0.0),
    spec(VELOCITY, "Velocity", "Voice", "%", linear(0.0, 100.0), 70.0),
    spec(VOLUME, "Volume", "Output", "dB", Kind::Float { min: VOLUME_MIN_DB, max: 6.0, log: false, skew: 0.5 }, -6.0),
];

/// Number of real parameters.
pub const PARAM_COUNT: usize = 9 + 9 + 7 + 4 + 4 + 4 + 4 + 5;

/// Every parameter, in display order. A parameter's index here is its slot.
pub const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[
    &OSC1_SPECS,
    &OSC2_SPECS,
    &NOISE_FILTER_SPECS,
    &AMP_ENV_SPECS,
    &FILTER_ENV_SPECS,
    &LFO1_SPECS,
    &LFO2_SPECS,
    &VOICE_OUTPUT_SPECS,
]);

/// IDs are all below this.
const ID_SPACE: usize = 100;

/// Slot of each ID, or `param_table::NO_SLOT`.
const SLOT_OF: [u8; ID_SPACE] = slot_table(&SPECS);

pub static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOT_OF);

/// Slot of parameter `id`, if it exists.
pub fn slot(id: ParamId) -> Option<usize> {
    TABLE.slot(id)
}

/// Slot of a parameter known to exist (for the constants above).
pub const fn slot_of(id: ParamId) -> usize {
    SLOT_OF[id as usize] as usize
}

pub fn param_infos() -> Vec<ParamInfo> {
    TABLE.infos()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VoiceMode {
    Poly,
    Mono,
    Legato,
}

/// One oscillator's decoded settings.
#[derive(Clone, Copy, Debug)]
pub struct OscParams {
    /// `Oscillator::process_block` waveform code.
    pub wave: u8,
    /// 0.05–0.95.
    pub pulse_width: f64,
    /// Octave, semi and fine combined, in semitones.
    pub transpose: f32,
    pub level: f32,
    pub unison: usize,
    pub detune_cents: f32,
    /// 0–1.
    pub spread: f32,
}

/// Envelope times in seconds, sustain 0–1.
#[derive(Clone, Copy, Debug)]
pub struct EnvParams {
    pub attack: f32,
    pub decay: f32,
    pub sustain: f32,
    pub release: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct LfoParams {
    pub shape: LfoShape,
    pub rate_hz: f32,
    /// Tempo-synced period in quarter-note beats; `None` runs at `rate_hz`.
    pub sync_beats: Option<f64>,
    /// Reset the phase on note-on (else voices pick up the device's free-running phase).
    pub retrigger: bool,
}

impl LfoParams {
    /// Rate in Hz at `tempo` BPM.
    pub fn hz(&self, tempo: f64) -> f64 {
        match self.sync_beats {
            Some(beats) => tempo / 60.0 / beats,
            None => self.rate_hz as f64,
        }
    }
}

/// What a `set` touched, so the device only does the follow-up work that change needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Changed {
    None,
    Other,
    Envelope,
    Mode,
}

/// The device's single parameter block. Voices read it by reference every control block; there
/// are no per-voice copies. A modulated voice decodes a stack copy with its modulated values.
#[derive(Clone, Copy)]
pub struct SynthParams {
    norm: [f32; PARAM_COUNT],
    /// Normalized modulation offset per slot; the effective value is `clamp(norm + offset)`.
    offset: [f32; PARAM_COUNT],
    pub osc: [OscParams; 2],
    pub noise_level: f32,
    /// 0 = dark, 0.5 = white, 1 = bright.
    pub noise_color: f32,
    pub filter_mode: FilterMode,
    pub cutoff_hz: f32,
    /// 0–1.
    pub resonance: f32,
    pub drive_db: f32,
    /// 0–1: octaves of cutoff per octave of pitch, pivoting on C3 (60).
    pub key_track: f32,
    pub amp_env: EnvParams,
    pub filter_env: EnvParams,
    pub lfo: [LfoParams; 2],
    pub mode: VoiceMode,
    pub polyphony: usize,
    /// Seconds; 0 is off.
    pub glide: f32,
    /// Amp velocity sensitivity, 0–1.
    pub velocity_sens: f32,
    pub volume_db: f32,
    /// Linear output gain (0 at the bottom of the range).
    pub volume_gain: f32,
}

impl SynthParams {
    pub fn new() -> Self {
        let osc = OscParams {
            wave: 0,
            pulse_width: 0.5,
            transpose: 0.0,
            level: 0.0,
            unison: 1,
            detune_cents: 0.0,
            spread: 0.0,
        };
        let env = EnvParams {
            attack: 0.0,
            decay: 0.0,
            sustain: 0.0,
            release: 0.0,
        };
        let lfo = LfoParams {
            shape: LfoShape::Sine,
            rate_hz: 1.0,
            sync_beats: None,
            retrigger: true,
        };
        let mut params = Self {
            norm: [0.0; PARAM_COUNT],
            offset: [0.0; PARAM_COUNT],
            osc: [osc; 2],
            noise_level: 0.0,
            noise_color: 0.5,
            filter_mode: FilterMode::Lp24,
            cutoff_hz: CUTOFF_MAX,
            resonance: 0.0,
            drive_db: 0.0,
            key_track: 0.0,
            amp_env: env,
            filter_env: env,
            lfo: [lfo; 2],
            mode: VoiceMode::Poly,
            polyphony: 16,
            glide: 0.0,
            velocity_sens: 0.0,
            volume_db: 0.0,
            volume_gain: 1.0,
        };
        for spec in SPECS.iter() {
            params.set(spec.id, spec.to_norm(spec.default));
        }
        params
    }

    /// Normalized value of `id`, as last set.
    pub fn get(&self, id: ParamId) -> Option<f32> {
        slot(id).map(|s| self.norm[s])
    }

    /// Normalized value at `slot`.
    #[inline]
    pub fn norm_at(&self, slot: usize) -> f32 {
        self.norm[slot]
    }

    /// Store a normalized value and decode it into the real field it drives.
    pub fn set(&mut self, id: ParamId, norm: f32) -> Changed {
        match slot(id) {
            Some(s) => self.set_slot(s, norm),
            None => Changed::None,
        }
    }

    /// `set` by slot: store the base value and decode it into the real field it drives.
    pub fn set_slot(&mut self, slot: usize, norm: f32) -> Changed {
        let norm = SPECS[slot].canonical(norm);
        self.norm[slot] = norm;
        self.decode_slot(slot, norm)
    }

    /// Set the modulation offset of `id` and decode the effective value into its real field.
    /// Unknown IDs and non-modulatable parameters (enums and bools) change nothing.
    pub fn set_offset(&mut self, id: ParamId, offset: f32) -> Changed {
        match slot(id) {
            Some(s) if SPECS[s].is_modulatable() => {
                self.offset[s] = offset;
                self.decode_slot(s, self.effective_norm_at(s))
            }
            _ => Changed::None,
        }
    }

    /// Effective normalized value at `slot`: the base plus its modulation offset, clamped.
    pub fn effective_norm_at(&self, slot: usize) -> f32 {
        (self.norm[slot] + self.offset[slot]).clamp(0.0, 1.0)
    }

    /// Decode `norm` into the real field it drives, without storing the base.
    fn decode_slot(&mut self, slot: usize, norm: f32) -> Changed {
        let spec = &SPECS[slot];
        let norm = spec.canonical(norm);
        let real = spec.to_real(norm);
        let id = spec.id;

        if id < OSC2 + 10 {
            let o = (id / 10) as usize;
            match id % 10 {
                WAVE => self.osc[o].wave = WAVE_CODES[real as usize],
                PULSE_WIDTH => self.osc[o].pulse_width = real as f64 / 100.0,
                LEVEL => self.osc[o].level = real,
                UNISON => self.osc[o].unison = real as usize + 1,
                UNISON_DETUNE => self.osc[o].detune_cents = real,
                UNISON_SPREAD => self.osc[o].spread = real / 100.0,
                _ => self.osc[o].transpose = self.transpose(id - id % 10), // octave, semi, fine
            }
            return Changed::Other;
        }

        let block = id - id % 10;
        if block == AMP_ENV || block == FILTER_ENV {
            let env = if block == AMP_ENV {
                &mut self.amp_env
            } else {
                &mut self.filter_env
            };
            match id % 10 {
                ATTACK => env.attack = real,
                DECAY => env.decay = real,
                SUSTAIN => env.sustain = real,
                _ => env.release = real,
            }
            return Changed::Envelope;
        }
        if block == LFO1 || block == LFO2 {
            let lfo = &mut self.lfo[((block - LFO1) / 10) as usize];
            match id % 10 {
                LFO_SHAPE => lfo.shape = LfoShape::from_index(real as usize),
                LFO_RATE => lfo.rate_hz = real,
                LFO_SYNC => lfo.sync_beats = sync_beats(real as usize),
                _ => lfo.retrigger = real as usize == 1,
            }
            return Changed::Other;
        }

        match id {
            NOISE_LEVEL => self.noise_level = real,
            NOISE_COLOR => self.noise_color = real / 100.0,
            FILTER_TYPE => self.filter_mode = FILTER_MODES[real as usize],
            CUTOFF => self.cutoff_hz = real,
            RESONANCE => self.resonance = real,
            DRIVE => self.drive_db = real,
            KEY_TRACK => self.key_track = real / 100.0,
            VOICE_MODE => {
                let mode = match real as usize {
                    0 => VoiceMode::Poly,
                    1 => VoiceMode::Mono,
                    _ => VoiceMode::Legato,
                };
                let changed = mode != self.mode;
                self.mode = mode;
                return if changed {
                    Changed::Mode
                } else {
                    Changed::None
                };
            }
            POLYPHONY => self.polyphony = real as usize + 1,
            GLIDE => self.glide = real,
            VELOCITY => self.velocity_sens = real / 100.0,
            VOLUME => {
                self.volume_db = real;
                self.volume_gain = if real <= VOLUME_MIN_DB {
                    0.0
                } else {
                    10f32.powf(real / 20.0)
                }
            }
            _ => {}
        }
        Changed::Other
    }

    /// Octave + semi + fine for the oscillator block at `base`, in semitones.
    fn transpose(&self, base: ParamId) -> f32 {
        let real = |offset: ParamId| {
            let s = slot_of(base + offset);
            SPECS[s].to_real(self.effective_norm_at(s))
        };
        (real(OCTAVE) - 3.0) * 12.0 + (real(SEMI) - 12.0) + real(FINE) / 100.0
    }
}

impl Default for SynthParams {
    fn default() -> Self {
        Self::new()
    }
}
