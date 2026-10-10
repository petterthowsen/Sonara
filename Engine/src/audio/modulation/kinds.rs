//! The modulator kinds and their parameter tables.
//!
//! Each kind owns a `ParamTable` (the same machinery the built-in devices use) with parameter
//! IDs grouped in blocks of ten, so a kind can grow without renumbering. A modulator's
//! parameters are *real* parameters: automatable as `device/{path}/mod/{mod_id}/param/{id}`, and
//! (later) targets of other modulators.
//!
//! [`ModParams`] mirrors `ParamValues` for a table whose length varies by kind: it is a fixed
//! `MAX_KIND_PARAMS`-slot block, so a [`ModulatorState`](super::state::ModulatorState) is `Copy`
//! and preallocated.

use super::lfo::LFO_SHAPES;
use crate::audio::devices::param_table::{
    linear, log, skewed, slot_table, spec, Kind, ParamSpec, ParamTable,
};
use crate::audio::devices::ParamId;
use crate::audio::dsp::tempo_sync::SYNC_CHOICES;

// === LFO parameter IDs (block of ten each) ===

pub const LFO_SHAPE: ParamId = 0;
pub const LFO_RATE: ParamId = 10;
pub const LFO_SYNC: ParamId = 20;
pub const LFO_RETRIGGER: ParamId = 30;
pub const LFO_PHASE: ParamId = 40;

/// LFO Retrigger choices; index 1 is "Note".
pub const LFO_RETRIGGERS: &[&str] = &["Free", "Note"];

// === MIDI CC parameter IDs ===

/// The controller number (0–119; 120–127 are channel-mode messages, excluded as in spec 030).
pub const CC_NUMBER: ParamId = 0;
/// One-pole lag time on the CC value; 0 (the default) snaps the change in this step.
pub const CC_SMOOTH: ParamId = 10;

// === Envelope parameter IDs ===

pub const ENV_ATTACK: ParamId = 0;
pub const ENV_DECAY: ParamId = 10;
pub const ENV_SUSTAIN: ParamId = 20;
pub const ENV_RELEASE: ParamId = 30;

/// Envelope times run 0.5 ms to 10 s on a skew-4 curve (625 ms at mid-knob), as in PolySynth.
const ENV_TIME: Kind = skewed(0.0005, 10.0, 4.0);

/// Largest parameter table of any kind (the LFO's five).
pub const MAX_KIND_PARAMS: usize = 5;

const LFO_SPECS: [ParamSpec; 5] = [
    spec(LFO_SHAPE, "Shape", "LFO", "", Kind::Enum(LFO_SHAPES), 0.0),
    spec(LFO_RATE, "Rate", "LFO", "Hz", log(0.02, 40.0), 2.0),
    spec(LFO_SYNC, "Sync", "LFO", "", Kind::Enum(SYNC_CHOICES), 0.0),
    spec(
        LFO_RETRIGGER,
        "Retrigger",
        "LFO",
        "",
        Kind::Enum(LFO_RETRIGGERS),
        0.0,
    ),
    spec(LFO_PHASE, "Phase", "LFO", "°", linear(0.0, 360.0), 0.0),
];
const LFO_SLOTS: [u8; 50] = slot_table(&LFO_SPECS);
static LFO_TABLE: ParamTable = ParamTable::new(&LFO_SPECS, &LFO_SLOTS);

const ADSR_SPECS: [ParamSpec; 4] = [
    spec(ENV_ATTACK, "Attack", "Envelope", "s", ENV_TIME, 0.005),
    spec(ENV_DECAY, "Decay", "Envelope", "s", ENV_TIME, 0.3),
    spec(
        ENV_SUSTAIN,
        "Sustain",
        "Envelope",
        "",
        linear(0.0, 1.0),
        0.5,
    ),
    spec(ENV_RELEASE, "Release", "Envelope", "s", ENV_TIME, 0.3),
];
const ADSR_SLOTS: [u8; 40] = slot_table(&ADSR_SPECS);
static ADSR_TABLE: ParamTable = ParamTable::new(&ADSR_SPECS, &ADSR_SLOTS);

const AD_SPECS: [ParamSpec; 2] = [
    spec(ENV_ATTACK, "Attack", "Envelope", "s", ENV_TIME, 0.005),
    spec(ENV_DECAY, "Decay", "Envelope", "s", ENV_TIME, 0.3),
];
const AD_SLOTS: [u8; 20] = slot_table(&AD_SPECS);
static AD_TABLE: ParamTable = ParamTable::new(&AD_SPECS, &AD_SLOTS);

/// A controller number, linear 0–119. 120–127 are channel-mode messages and stay out of reach.
const CC_NUMBER_RANGE: Kind = linear(0.0, 119.0);
/// One-pole lag: 0 (off) to 500 ms, skewed so small times get knob travel (it must reach 0).
const CC_SMOOTH_TIME: Kind = skewed(0.0, 0.5, 4.0);

const CC_SPECS: [ParamSpec; 2] = [
    spec(CC_NUMBER, "CC Number", "MIDI CC", "", CC_NUMBER_RANGE, 0.0),
    spec(CC_SMOOTH, "Smooth", "MIDI CC", "s", CC_SMOOTH_TIME, 0.0),
];
const CC_SLOTS: [u8; 20] = slot_table(&CC_SPECS);
static CC_TABLE: ParamTable = ParamTable::new(&CC_SPECS, &CC_SLOTS);

/// Velocity, release, keytrack and random have no settings.
static EMPTY_TABLE: ParamTable = ParamTable::new(&[], &[]);

/// The kinds a modulator can be. The polarity (bipolar vs unipolar) is fixed per kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModulatorKind {
    Lfo,
    Adsr,
    Ad,
    Velocity,
    Keytrack,
    Random,
    /// The note-off's release velocity: `DEFAULT_RELEASE` until the note is released.
    Release,
    /// A MIDI controller value, latched from the channel's CC stream (spec 032). Channel-level,
    /// so it is evaluated on the mono path only (`is_mono_only`).
    MidiCc,
}

impl ModulatorKind {
    pub const COUNT: usize = 8;
    pub const ALL: [ModulatorKind; Self::COUNT] = [
        ModulatorKind::Lfo,
        ModulatorKind::Adsr,
        ModulatorKind::Ad,
        ModulatorKind::Velocity,
        ModulatorKind::Keytrack,
        ModulatorKind::Random,
        ModulatorKind::Release,
        ModulatorKind::MidiCc,
    ];

    /// Stable id used over OSC and in saved projects.
    pub fn id(self) -> &'static str {
        match self {
            ModulatorKind::Lfo => "lfo",
            ModulatorKind::Adsr => "adsr",
            ModulatorKind::Ad => "ad",
            ModulatorKind::Velocity => "velocity",
            ModulatorKind::Keytrack => "keytrack",
            ModulatorKind::Random => "random",
            ModulatorKind::Release => "release",
            ModulatorKind::MidiCc => "cc",
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            ModulatorKind::Lfo => "LFO",
            ModulatorKind::Adsr => "Envelope",
            ModulatorKind::Ad => "Decay Env",
            ModulatorKind::Velocity => "Velocity",
            ModulatorKind::Keytrack => "Keytrack",
            ModulatorKind::Random => "Random",
            ModulatorKind::Release => "Release",
            ModulatorKind::MidiCc => "MIDI CC",
        }
    }

    /// Runs −1..1 (else 0..1).
    pub fn bipolar(self) -> bool {
        matches!(
            self,
            ModulatorKind::Lfo | ModulatorKind::Keytrack | ModulatorKind::Random
        )
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.id() == id)
    }

    /// Position in `ALL`.
    pub fn index(self) -> usize {
        self as usize
    }

    /// The kind's parameter table, in slot order.
    pub fn table(self) -> &'static ParamTable {
        match self {
            ModulatorKind::Lfo => &LFO_TABLE,
            ModulatorKind::Adsr => &ADSR_TABLE,
            ModulatorKind::Ad => &AD_TABLE,
            ModulatorKind::Velocity
            | ModulatorKind::Keytrack
            | ModulatorKind::Random
            | ModulatorKind::Release => &EMPTY_TABLE,
            ModulatorKind::MidiCc => &CC_TABLE,
        }
    }

    /// True for the note-driven envelopes (they retrigger and release with the note stream).
    pub fn is_envelope(self) -> bool {
        matches!(self, ModulatorKind::Adsr | ModulatorKind::Ad)
    }

    /// True when the kind is channel-level and must never be evaluated per voice: it is
    /// excluded from the `VoiceModSpec` and applied on the mono path even for a
    /// voice-modulating device (the `cc` kind; spec 032).
    pub fn is_mono_only(self) -> bool {
        matches!(self, ModulatorKind::MidiCc)
    }
}

/// Normalized parameter values for one modulator, indexed by its kind's table slots.
///
/// A `Copy`, fixed-capacity mirror of `ParamValues` for the per-kind tables, whose lengths
/// differ. The unused tail stays at its default and is never read.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ModParams {
    kind: ModulatorKind,
    norm: [f32; MAX_KIND_PARAMS],
}

impl ModParams {
    /// Every parameter at its kind's default.
    pub fn new(kind: ModulatorKind) -> Self {
        let mut norm = [0.0; MAX_KIND_PARAMS];
        for (value, spec) in norm.iter_mut().zip(kind.table().specs) {
            *value = spec.default_norm();
        }
        Self { kind, norm }
    }

    pub fn table(&self) -> &'static ParamTable {
        self.kind.table()
    }

    /// Normalized value of `id`, as last set.
    pub fn get(&self, id: ParamId) -> Option<f32> {
        self.table().slot(id).map(|s| self.norm[s])
    }

    /// Real value of `id` (a choice index for enums, 0 or 1 for bools).
    pub fn real(&self, id: ParamId) -> Option<f32> {
        self.table()
            .slot(id)
            .map(|s| self.table().specs[s].to_real(self.norm[s]))
    }

    /// Store `norm` (canonicalized) and return the slot and the real value it decodes to, or
    /// None for an unknown ID.
    pub fn set(&mut self, id: ParamId, norm: f32) -> Option<(usize, f32)> {
        let table = self.table();
        let slot = table.slot(id)?;
        let spec = &table.specs[slot];
        let norm = spec.canonical(norm);
        self.norm[slot] = norm;
        Some((slot, spec.to_real(norm)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_ids_round_trip() {
        for kind in ModulatorKind::ALL {
            assert_eq!(ModulatorKind::from_id(kind.id()), Some(kind));
            assert_eq!(ModulatorKind::ALL[kind.index()], kind);
        }
        assert_eq!(ModulatorKind::from_id("nope"), None);
    }

    #[test]
    fn polarity_follows_the_kind() {
        let bipolar: Vec<&str> = ModulatorKind::ALL
            .iter()
            .filter(|k| k.bipolar())
            .map(|k| k.id())
            .collect();
        assert_eq!(bipolar, ["lfo", "keytrack", "random"]);
    }

    #[test]
    fn cc_kind_round_trips_and_keeps_old_indices() {
        // Appending must not shift the existing kinds' positions (saved projects index by slot).
        for (i, kind) in ModulatorKind::ALL.iter().enumerate() {
            assert_eq!(kind.index(), i);
        }
        let cc = ModulatorKind::from_id("cc").expect("cc kind");
        assert_eq!(cc, ModulatorKind::MidiCc);
        assert_eq!(cc.index(), ModulatorKind::COUNT - 1);
        assert!(!cc.bipolar(), "a normalized CC is unipolar");
        assert!(!cc.is_envelope());
        assert!(cc.is_mono_only());
        assert!(!ModulatorKind::Release.is_mono_only());

        let params = ModParams::new(cc);
        assert_eq!(params.table().len(), 2);
        assert_eq!(params.real(CC_NUMBER), Some(0.0));
        assert_eq!(params.real(CC_SMOOTH), Some(0.0));
        // Real range 0–119: norm 1.0 is controller 119, not 127.
        let spec = &cc.table().specs[cc.table().slot(CC_NUMBER).unwrap()];
        assert_eq!(spec.to_real(1.0), 119.0);
        assert_eq!(spec.to_norm(119.0), 1.0);
        // Smooth tops out at 500 ms.
        let spec = &cc.table().specs[cc.table().slot(CC_SMOOTH).unwrap()];
        assert_eq!(spec.to_real(1.0), 0.5);
    }

    #[test]
    fn tables_fit_the_fixed_block_and_defaults_decode() {
        let lfo = ModParams::new(ModulatorKind::Lfo);
        assert_eq!(lfo.table().len(), 5);
        assert_eq!(lfo.get(LFO_SHAPE), Some(0.0));
        assert!((lfo.real(LFO_RATE).unwrap() - 2.0).abs() < 1e-6);
        assert_eq!(lfo.real(LFO_SYNC), Some(0.0), "Off");
        assert_eq!(lfo.real(LFO_RETRIGGER), Some(0.0), "Free");
        assert_eq!(lfo.real(LFO_PHASE), Some(0.0));

        let adsr = ModParams::new(ModulatorKind::Adsr);
        assert_eq!(adsr.table().len(), 4);
        assert!((adsr.real(ENV_ATTACK).unwrap() - 0.005).abs() < 1e-6);
        assert!((adsr.real(ENV_SUSTAIN).unwrap() - 0.5).abs() < 1e-6);

        let ad = ModParams::new(ModulatorKind::Ad);
        assert_eq!(ad.table().len(), 2);

        for kind in [
            ModulatorKind::Velocity,
            ModulatorKind::Keytrack,
            ModulatorKind::Random,
            ModulatorKind::Release,
        ] {
            let mut p = ModParams::new(kind);
            assert!(p.table().is_empty());
            assert_eq!(p.set(ENV_ATTACK, 0.5), None);
        }
    }

    #[test]
    fn set_canonicalizes_and_rejects_unknown_ids() {
        let mut p = ModParams::new(ModulatorKind::Lfo);
        // Enums snap to the nearest choice: norm 0.04 is closest to choice 1 of 25.
        assert_eq!(p.set(LFO_SYNC, 0.04).map(|(_, real)| real), Some(1.0));
        assert!((p.get(LFO_SYNC).unwrap() - 1.0 / 24.0).abs() < 1e-6);
        assert_eq!(p.set(99, 0.5), None, "not an LFO parameter");
        // Floats clamp to 0..1.
        p.set(LFO_RATE, 1.3);
        assert_eq!(p.get(LFO_RATE), Some(1.0));
        p.set(LFO_RATE, -0.5);
        assert_eq!(p.get(LFO_RATE), Some(0.0));
        // An out-of-range norm clamps to the last choice.
        p.set(LFO_SHAPE, 999.0);
        assert_eq!(p.real(LFO_SHAPE), Some(4.0), "S&H");
    }
}
