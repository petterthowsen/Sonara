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

// === Shared parameter IDs ===

/// Output amount, 0–100 %, scaling the modulator's value. Every kind but the sidechain has it at
/// this ID (the sidechain predates it and keeps its own [`SC_AMOUNT`]; see
/// [`ModulatorKind::amount_id`]). Being a real parameter, another modulator can route into it.
pub const MOD_AMOUNT: ParamId = 90;

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

// === Knob parameter IDs (block of ten each) ===

/// The knob's value, linear 0–1; the whole point of the kind (spec 036).
pub const KNOB_VALUE: ParamId = 0;
/// Polarity: Unipolar routes `x`, Bipolar routes `2x − 1` while the stored value stays 0–1.
pub const KNOB_POLARITY: ParamId = 10;

/// Knob Polarity choices; index 1 is "Bipolar".
pub const KNOB_POLARITIES: &[&str] = &["Unipolar", "Bipolar"];

// === XY parameter IDs ===

/// The pad position of both XY axes, linear 0–1, centred (0.5) by default (spec 036 D7).
pub const XY_POS: ParamId = 0;

// === Sidechain parameter IDs (block of ten each) ===

/// High-pass before the follower; bypassed at its 20 Hz extreme (spec 036 REQ-007).
pub const SC_LOW_CUT: ParamId = 0;
/// Low-pass before the follower; bypassed at its 20 kHz extreme (spec 036 REQ-007).
pub const SC_HIGH_CUT: ParamId = 10;
/// Follower attack, 0–500 ms.
pub const SC_ATTACK: ParamId = 20;
/// Follower release, 5–2000 ms.
pub const SC_RELEASE: ParamId = 30;
/// The tapped source as a channel id (stepped; consumers round): 0 = Device In, 1 = master,
/// 2–999 user channels. Hardware outputs (≥ 1000) are not sources (spec 036 D2).
pub const SC_SOURCE: ParamId = 40;
/// Input gain in dB, applied before the cuts and the follower (spec 044 REQ-001).
pub const SC_GAIN: ParamId = 50;
/// Output amount, 0–100 %, scaling the follower value (spec 044 REQ-002).
pub const SC_AMOUNT: ParamId = 60;

// === Envelope parameter IDs ===

pub const ENV_ATTACK: ParamId = 0;
pub const ENV_DECAY: ParamId = 10;
pub const ENV_SUSTAIN: ParamId = 20;
pub const ENV_RELEASE: ParamId = 30;

/// Envelope times run 0.5 ms to 10 s on a skew-4 curve (625 ms at mid-knob), as in PolySynth.
const ENV_TIME: Kind = skewed(0.0005, 10.0, 4.0);

/// Largest parameter table of any kind (the sidechain's seven; the LFO's six with Amount).
pub const MAX_KIND_PARAMS: usize = 7;

/// The Amount every kind but the sidechain carries; 100 % leaves the value untouched, which is
/// what projects saved before the parameter existed load as.
const AMOUNT_SPEC: ParamSpec = spec(
    MOD_AMOUNT,
    "Amount",
    "Modulator",
    "%",
    linear(0.0, 100.0),
    100.0,
);
/// Highest parameter ID of the kinds that carry `MOD_AMOUNT`, plus one.
const AMOUNT_IDS: usize = MOD_AMOUNT as usize + 1;

const LFO_SPECS: [ParamSpec; 6] = [
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
    AMOUNT_SPEC,
];
const LFO_SLOTS: [u8; AMOUNT_IDS] = slot_table(&LFO_SPECS);
static LFO_TABLE: ParamTable = ParamTable::new(&LFO_SPECS, &LFO_SLOTS);

const ADSR_SPECS: [ParamSpec; 5] = [
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
    AMOUNT_SPEC,
];
const ADSR_SLOTS: [u8; AMOUNT_IDS] = slot_table(&ADSR_SPECS);
static ADSR_TABLE: ParamTable = ParamTable::new(&ADSR_SPECS, &ADSR_SLOTS);

const AD_SPECS: [ParamSpec; 3] = [
    spec(ENV_ATTACK, "Attack", "Envelope", "s", ENV_TIME, 0.005),
    spec(ENV_DECAY, "Decay", "Envelope", "s", ENV_TIME, 0.3),
    AMOUNT_SPEC,
];
const AD_SLOTS: [u8; AMOUNT_IDS] = slot_table(&AD_SPECS);
static AD_TABLE: ParamTable = ParamTable::new(&AD_SPECS, &AD_SLOTS);

/// A controller number, linear 0–119. 120–127 are channel-mode messages and stay out of reach.
const CC_NUMBER_RANGE: Kind = linear(0.0, 119.0);
/// One-pole lag: 0 (off) to 500 ms, skewed so small times get knob travel (it must reach 0).
const CC_SMOOTH_TIME: Kind = skewed(0.0, 0.5, 4.0);

const CC_SPECS: [ParamSpec; 3] = [
    spec(CC_NUMBER, "CC Number", "MIDI CC", "", CC_NUMBER_RANGE, 0.0),
    spec(CC_SMOOTH, "Smooth", "MIDI CC", "s", CC_SMOOTH_TIME, 0.0),
    AMOUNT_SPEC,
];
const CC_SLOTS: [u8; AMOUNT_IDS] = slot_table(&CC_SPECS);
static CC_TABLE: ParamTable = ParamTable::new(&CC_SPECS, &CC_SLOTS);

/// Follower times in milliseconds, skewed so short times get knob travel (both reach their
/// minimum exactly), as in the envelope kinds.
const SC_ATTACK_TIME: Kind = skewed(0.0, 500.0, 4.0);
const SC_RELEASE_TIME: Kind = skewed(5.0, 2_000.0, 4.0);

const KNOB_SPECS: [ParamSpec; 3] = [
    spec(KNOB_VALUE, "Value", "Knob", "", linear(0.0, 1.0), 0.0),
    spec(
        KNOB_POLARITY,
        "Polarity",
        "Knob",
        "",
        Kind::Enum(KNOB_POLARITIES),
        0.0,
    ),
    AMOUNT_SPEC,
];
const KNOB_SLOTS: [u8; AMOUNT_IDS] = slot_table(&KNOB_SPECS);
static KNOB_TABLE: ParamTable = ParamTable::new(&KNOB_SPECS, &KNOB_SLOTS);

/// One table for both XY axes: each slot is a plain position (spec 036 D7).
const XY_SPECS: [ParamSpec; 2] = [
    spec(XY_POS, "Position", "XY Pad", "", linear(0.0, 1.0), 0.5),
    AMOUNT_SPEC,
];
const XY_SLOTS: [u8; AMOUNT_IDS] = slot_table(&XY_SPECS);
static XY_TABLE: ParamTable = ParamTable::new(&XY_SPECS, &XY_SLOTS);

const SC_SPECS: [ParamSpec; 7] = [
    spec(
        SC_LOW_CUT,
        "Low Cut",
        "Sidechain",
        "Hz",
        log(20.0, 20_000.0),
        20.0,
    ),
    spec(
        SC_HIGH_CUT,
        "High Cut",
        "Sidechain",
        "Hz",
        log(20.0, 20_000.0),
        20_000.0,
    ),
    spec(SC_ATTACK, "Attack", "Sidechain", "ms", SC_ATTACK_TIME, 5.0),
    spec(
        SC_RELEASE,
        "Release",
        "Sidechain",
        "ms",
        SC_RELEASE_TIME,
        150.0,
    ),
    spec(
        SC_SOURCE,
        "Source",
        "Sidechain",
        "",
        linear(0.0, 999.0),
        0.0,
    ),
    spec(SC_GAIN, "Gain", "Sidechain", "dB", linear(-24.0, 24.0), 0.0),
    spec(
        SC_AMOUNT,
        "Amount",
        "Sidechain",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
];
const SC_SLOTS: [u8; 70] = slot_table(&SC_SPECS);
static SC_TABLE: ParamTable = ParamTable::new(&SC_SPECS, &SC_SLOTS);

/// Velocity, release, keytrack and random have no settings beyond Amount.
const AMOUNT_ONLY_SPECS: [ParamSpec; 1] = [AMOUNT_SPEC];
const AMOUNT_ONLY_SLOTS: [u8; AMOUNT_IDS] = slot_table(&AMOUNT_ONLY_SPECS);
static AMOUNT_ONLY_TABLE: ParamTable = ParamTable::new(&AMOUNT_ONLY_SPECS, &AMOUNT_ONLY_SLOTS);

/// The kinds a modulator can be. The polarity (bipolar vs unipolar) is fixed per kind, except
/// `knob`, whose Polarity is a per-instance parameter (spec 036 D1).
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
    /// A plain macro knob: its Value parameter is the output, no DSP behind it (spec 036).
    /// Polarity is a per-instance parameter (D1), so `bipolar()` stays false.
    Knob,
    /// The XY pad's X axis: the pair's shared Position mapped to −1..1 (spec 036, D7).
    XyX,
    /// The XY pad's Y axis, as `XyX`. Godot pairs the two by array adjacency.
    XyY,
    /// An audio-driven peak follower (spec 036): Device In or another channel's post-fader
    /// output, filtered and mapped −60…0 dBFS → 0…1. Channel-level, so mono-path only.
    Sidechain,
}

impl ModulatorKind {
    pub const COUNT: usize = 12;
    pub const ALL: [ModulatorKind; Self::COUNT] = [
        ModulatorKind::Lfo,
        ModulatorKind::Adsr,
        ModulatorKind::Ad,
        ModulatorKind::Velocity,
        ModulatorKind::Keytrack,
        ModulatorKind::Random,
        ModulatorKind::Release,
        ModulatorKind::MidiCc,
        ModulatorKind::Knob,
        ModulatorKind::XyX,
        ModulatorKind::XyY,
        ModulatorKind::Sidechain,
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
            ModulatorKind::Knob => "knob",
            ModulatorKind::XyX => "xyx",
            ModulatorKind::XyY => "xyy",
            ModulatorKind::Sidechain => "sidechain",
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
            ModulatorKind::Knob => "Knob",
            ModulatorKind::XyX => "XY X",
            ModulatorKind::XyY => "XY Y",
            ModulatorKind::Sidechain => "Sidechain",
        }
    }

    /// Runs −1..1 (else 0..1). Kind-fixed: a knob's polarity is per instance (D1).
    pub fn bipolar(self) -> bool {
        matches!(
            self,
            ModulatorKind::Lfo
                | ModulatorKind::Keytrack
                | ModulatorKind::Random
                | ModulatorKind::XyX
                | ModulatorKind::XyY
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
            | ModulatorKind::Release => &AMOUNT_ONLY_TABLE,
            ModulatorKind::MidiCc => &CC_TABLE,
            ModulatorKind::Knob => &KNOB_TABLE,
            ModulatorKind::XyX | ModulatorKind::XyY => &XY_TABLE,
            ModulatorKind::Sidechain => &SC_TABLE,
        }
    }

    /// The ID of the kind's Amount parameter: [`SC_AMOUNT`] for the sidechain, else
    /// [`MOD_AMOUNT`].
    pub fn amount_id(self) -> ParamId {
        match self {
            ModulatorKind::Sidechain => SC_AMOUNT,
            _ => MOD_AMOUNT,
        }
    }

    /// True for the note-driven envelopes (they retrigger and release with the note stream).
    pub fn is_envelope(self) -> bool {
        matches!(self, ModulatorKind::Adsr | ModulatorKind::Ad)
    }

    /// True when the kind is channel-level and must never be evaluated per voice: it is
    /// excluded from the `VoiceModSpec` and applied on the mono path even for a
    /// voice-modulating device (the `cc` kind; spec 032 — and the `sidechain` kind, which
    /// follows audio, not voices).
    pub fn is_mono_only(self) -> bool {
        matches!(self, ModulatorKind::MidiCc | ModulatorKind::Sidechain)
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
        assert_eq!(bipolar, ["lfo", "keytrack", "random", "xyx", "xyy"]);
    }

    #[test]
    fn the_spec_036_kinds_advertise_their_tables() {
        // Appended after `cc`, in the order the design fixes; the older kinds' ids and
        // indices are unchanged (see `cc_kind_round_trips_and_keeps_old_indices`).
        for (i, expected) in [
            ("knob", "Knob"),
            ("xyx", "XY X"),
            ("xyy", "XY Y"),
            ("sidechain", "Sidechain"),
        ]
        .iter()
        .enumerate()
        {
            let kind = ModulatorKind::ALL[8 + i];
            assert_eq!(kind.id(), expected.0);
            assert_eq!(kind.name(), expected.1);
            assert_eq!(ModulatorKind::from_id(expected.0), Some(kind));
        }
        assert_eq!(ModulatorKind::COUNT, 12);

        let knob = ModParams::new(ModulatorKind::Knob);
        assert!(knob.table().len() <= MAX_KIND_PARAMS);
        assert_eq!(knob.table().len(), 3, "Value, Polarity, Amount");
        assert_eq!(knob.real(KNOB_VALUE), Some(0.0));
        assert_eq!(knob.real(KNOB_POLARITY), Some(0.0), "Unipolar");
        assert!(
            !ModulatorKind::Knob.bipolar(),
            "polarity is per instance (D1)"
        );
        let polarity = &ModulatorKind::Knob.table().specs[1];
        assert_eq!(polarity.to_real(1.0), 1.0, "Bipolar");

        for kind in [ModulatorKind::XyX, ModulatorKind::XyY] {
            let xy = ModParams::new(kind);
            assert!(xy.table().len() <= MAX_KIND_PARAMS);
            assert_eq!(xy.table().len(), 2, "Position and Amount");
            assert_eq!(xy.real(XY_POS), Some(0.5), "centred pad (D7)");
            assert!(kind.bipolar(), "a centred pad applies no offset (D7)");
            assert!(!kind.is_mono_only());
        }

        let sc = ModParams::new(ModulatorKind::Sidechain);
        assert!(sc.table().len() <= MAX_KIND_PARAMS);
        assert_eq!(sc.table().len(), 7);
        assert_eq!(sc.real(SC_LOW_CUT), Some(20.0));
        assert_eq!(sc.real(SC_HIGH_CUT), Some(20_000.0));
        // The skewed times round-trip through a powf; hold a tolerance.
        let attack = sc.real(SC_ATTACK).unwrap();
        assert!((attack - 5.0).abs() < 1e-3, "attack default {attack}");
        let release = sc.real(SC_RELEASE).unwrap();
        assert!((release - 150.0).abs() < 1e-2, "release default {release}");
        assert_eq!(sc.real(SC_SOURCE), Some(0.0), "Device In");
        assert_eq!(sc.real(SC_GAIN), Some(0.0), "0 dB");
        assert_eq!(sc.real(SC_AMOUNT), Some(100.0), "100 %");
        assert!(ModulatorKind::Sidechain.is_mono_only());
        assert!(!ModulatorKind::Sidechain.bipolar());
        // The Source stores a channel id in 0..=999.
        let source = &ModulatorKind::Sidechain.table().specs[4];
        assert_eq!(source.to_real(1.0), 999.0);
        assert_eq!(source.to_norm(7.0), 7.0 / 999.0);
    }

    #[test]
    fn cc_kind_round_trips_and_keeps_old_indices() {
        // Appending must not shift the existing kinds' positions (saved projects index by slot).
        for (i, kind) in ModulatorKind::ALL.iter().enumerate() {
            assert_eq!(kind.index(), i);
        }
        let cc = ModulatorKind::from_id("cc").expect("cc kind");
        assert_eq!(cc, ModulatorKind::MidiCc);
        // Spec 036 appended after it; the cc index itself is unchanged.
        assert_eq!(cc.index(), 7);
        assert!(!cc.bipolar(), "a normalized CC is unipolar");
        assert!(!cc.is_envelope());
        assert!(cc.is_mono_only());
        assert!(!ModulatorKind::Release.is_mono_only());

        let params = ModParams::new(cc);
        assert_eq!(params.table().len(), 3, "Number, Smooth, Amount");
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
        assert_eq!(lfo.table().len(), 6, "five settings and Amount");
        assert_eq!(lfo.get(LFO_SHAPE), Some(0.0));
        assert!((lfo.real(LFO_RATE).unwrap() - 2.0).abs() < 1e-6);
        assert_eq!(lfo.real(LFO_SYNC), Some(0.0), "Off");
        assert_eq!(lfo.real(LFO_RETRIGGER), Some(0.0), "Free");
        assert_eq!(lfo.real(LFO_PHASE), Some(0.0));

        let adsr = ModParams::new(ModulatorKind::Adsr);
        assert_eq!(adsr.table().len(), 5);
        assert!((adsr.real(ENV_ATTACK).unwrap() - 0.005).abs() < 1e-6);
        assert!((adsr.real(ENV_SUSTAIN).unwrap() - 0.5).abs() < 1e-6);

        let ad = ModParams::new(ModulatorKind::Ad);
        assert_eq!(ad.table().len(), 3);

        for kind in [
            ModulatorKind::Velocity,
            ModulatorKind::Keytrack,
            ModulatorKind::Random,
            ModulatorKind::Release,
        ] {
            let mut p = ModParams::new(kind);
            assert_eq!(p.table().len(), 1, "Amount only");
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
