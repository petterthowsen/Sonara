//! Static parameter tables for built-in devices.
//!
//! A device declares its parameters once, as a `const` array of [`ParamSpec`], and derives the
//! rest from it: `parameters()`, normalized get/set, defaults and the slot of each ID.
//!
//! - IDs are grouped in blocks of ten per module by convention (Osc 1 = 0.., Filter = 30.., …),
//!   so a module can grow without renumbering its neighbours.
//! - A parameter's *slot* is its index in the table. Per-parameter arrays (normalized values,
//!   modulation routes) are indexed by slot, not by ID.
//! - Build the table with [`flatten`] (one array per module) and the ID → slot lookup with
//!   [`slot_table`]; both run at compile time and assert on duplicate or out-of-range IDs.

use super::{
    enum_to_norm, norm_to_enum, norm_to_real, real_to_norm, ParamId, ParamInfo, ParamType,
};

/// How a parameter's normalized 0..1 value maps to a real one.
#[derive(Clone, Copy, Debug)]
pub enum Kind {
    /// `min * (max/min)^n` when `log` (needs `min > 0`), else `min + (max - min) * n^skew`.
    Float {
        min: f32,
        max: f32,
        log: bool,
        skew: f32,
    },
    /// Evenly spaced choices; the real value is the choice index.
    Enum(&'static [&'static str]),
    /// Off (0) or on (1).
    Bool,
}

/// A linear float range.
pub const fn linear(min: f32, max: f32) -> Kind {
    Kind::Float {
        min,
        max,
        log: false,
        skew: 1.0,
    }
}

/// A logarithmic float range (Hz, ms): equal knob travel per octave. `min` must be above 0.
pub const fn log(min: f32, max: f32) -> Kind {
    Kind::Float {
        min,
        max,
        log: true,
        skew: 1.0,
    }
}

/// A power-curve float range: `min + (max - min) * n^skew`. Skew above 1 gives the low end more
/// travel and still reaches `min` exactly (times that must reach 0).
pub const fn skewed(min: f32, max: f32, skew: f32) -> Kind {
    Kind::Float {
        min,
        max,
        log: false,
        skew,
    }
}

/// One parameter's metadata. `default` is a real value: a choice index for enums, 0 or 1 for
/// bools.
#[derive(Clone, Copy, Debug)]
pub struct ParamSpec {
    pub id: ParamId,
    pub name: &'static str,
    pub module: &'static str,
    pub unit: &'static str,
    pub kind: Kind,
    pub default: f32,
    /// Shown in parameter lists and generated views.
    pub visible: bool,
    /// Can be automated and modulated.
    pub automatable: bool,
}

/// A visible, automatable parameter. Chain [`ParamSpec::hidden`] or
/// [`ParamSpec::not_automatable`] for the exceptions.
pub const fn spec(
    id: ParamId,
    name: &'static str,
    module: &'static str,
    unit: &'static str,
    kind: Kind,
    default: f32,
) -> ParamSpec {
    ParamSpec {
        id,
        name,
        module,
        unit,
        kind,
        default,
        visible: true,
        automatable: true,
    }
}

impl ParamSpec {
    /// Hidden from parameter lists and generated views (a custom view drives it).
    pub const fn hidden(mut self) -> Self {
        self.visible = false;
        self
    }

    /// Excluded from automation (momentary UI state such as a listen switch).
    pub const fn not_automatable(mut self) -> Self {
        self.automatable = false;
        self
    }

    /// Normalized value for a real one.
    pub fn to_norm(&self, real: f32) -> f32 {
        match self.kind {
            Kind::Float {
                min,
                max,
                log,
                skew,
            } => real_to_norm(real, min, max, log, skew),
            Kind::Enum(values) => enum_to_norm(real.max(0.0) as usize, values.len()),
            Kind::Bool => bool_norm(real >= 0.5),
        }
    }

    /// Real value for a normalized one (a choice index for enums, 0 or 1 for bools).
    pub fn to_real(&self, norm: f32) -> f32 {
        match self.kind {
            Kind::Float {
                min,
                max,
                log,
                skew,
            } => norm_to_real(norm, min, max, log, skew),
            Kind::Enum(values) => norm_to_enum(norm, values.len()) as f32,
            Kind::Bool => bool_norm(norm >= 0.5),
        }
    }

    /// Canonical normalized value: floats clamp, enums and bools snap to their nearest choice.
    pub fn canonical(&self, norm: f32) -> f32 {
        match self.kind {
            Kind::Float { .. } => norm.clamp(0.0, 1.0),
            Kind::Enum(values) => enum_to_norm(norm_to_enum(norm, values.len()), values.len()),
            Kind::Bool => bool_norm(norm >= 0.5),
        }
    }

    /// Normalized default.
    pub fn default_norm(&self) -> f32 {
        self.to_norm(self.default)
    }

    /// Floats are modulation destinations; enums and bools are not.
    pub fn is_modulatable(&self) -> bool {
        self.automatable && matches!(self.kind, Kind::Float { .. })
    }

    pub fn info(&self) -> ParamInfo {
        let (min, max, log, skew, param_type, enum_values) = match self.kind {
            Kind::Float {
                min,
                max,
                log,
                skew,
            } => (min, max, log, skew, ParamType::Float, Vec::new()),
            Kind::Enum(values) => (
                0.0,
                1.0,
                false,
                1.0,
                ParamType::Enum,
                values.iter().map(|v| v.to_string()).collect(),
            ),
            Kind::Bool => (0.0, 1.0, false, 1.0, ParamType::Bool, Vec::new()),
        };
        ParamInfo {
            id: self.id,
            name: self.name.to_string(),
            unit: self.unit.to_string(),
            min,
            max,
            default: self.default,
            is_automation_safe: self.automatable,
            param_type,
            syncable: true,
            enum_values,
            is_hidden: !self.visible,
            is_read_only: false,
            is_bypass: false,
            is_modulatable: self.is_modulatable(),
            module: self.module.to_string(),
            is_logarithmic: log,
            skew,
            display: Vec::new(),
        }
    }
}

fn bool_norm(on: bool) -> f32 {
    if on {
        1.0
    } else {
        0.0
    }
}

/// Concatenate per-module arrays into one table (at compile time). `N` must equal the total
/// length.
pub const fn flatten<const N: usize>(parts: &[&[ParamSpec]]) -> [ParamSpec; N] {
    assert!(!parts.is_empty() && !parts[0].is_empty());
    let mut out = [parts[0][0]; N];
    let mut n = 0;
    let mut p = 0;
    while p < parts.len() {
        let mut i = 0;
        while i < parts[p].len() {
            out[n] = parts[p][i];
            n += 1;
            i += 1;
        }
        p += 1;
    }
    assert!(n == N, "flatten: N doesn't match the parts' total length");
    out
}

/// Marks an ID with no parameter in a [`slot_table`].
pub const NO_SLOT: u8 = u8::MAX;

/// ID → slot lookup for IDs below `IDS` (at compile time). Asserts every ID is in range and
/// unique.
pub const fn slot_table<const IDS: usize>(specs: &[ParamSpec]) -> [u8; IDS] {
    assert!(specs.len() < NO_SLOT as usize);
    let mut table = [NO_SLOT; IDS];
    let mut i = 0;
    while i < specs.len() {
        let id = specs[i].id as usize;
        assert!(id < IDS, "slot_table: parameter ID out of range");
        assert!(table[id] == NO_SLOT, "slot_table: duplicate parameter ID");
        table[id] = i as u8;
        i += 1;
    }
    table
}

/// A device's parameter table: the specs in slot order plus the ID → slot lookup.
#[derive(Clone, Copy)]
pub struct ParamTable {
    pub specs: &'static [ParamSpec],
    slots: &'static [u8],
}

impl ParamTable {
    pub const fn new(specs: &'static [ParamSpec], slots: &'static [u8]) -> Self {
        Self { specs, slots }
    }

    pub const fn len(&self) -> usize {
        self.specs.len()
    }

    pub const fn is_empty(&self) -> bool {
        self.specs.is_empty()
    }

    /// Slot of parameter `id`, if it exists.
    pub fn slot(&self, id: ParamId) -> Option<usize> {
        match self.slots.get(id as usize) {
            Some(&s) if s != NO_SLOT => Some(s as usize),
            _ => None,
        }
    }

    /// Slot of a parameter known to exist (for a device's ID constants).
    pub const fn slot_of(&self, id: ParamId) -> usize {
        let s = self.slots[id as usize];
        assert!(s != NO_SLOT, "slot_of: no such parameter");
        s as usize
    }

    pub fn spec(&self, id: ParamId) -> Option<&'static ParamSpec> {
        self.slot(id).map(|s| &self.specs[s])
    }

    /// `ParamInfo` for every parameter, in slot order.
    pub fn infos(&self) -> Vec<ParamInfo> {
        self.specs.iter().map(ParamSpec::info).collect()
    }
}

/// Canonical normalized values for every parameter of one table, starting at the defaults.
/// Effects keep one of these as their source of truth for `get_parameter`, and decode real
/// values from what [`ParamValues::set`] returns.
#[derive(Clone, Copy)]
pub struct ParamValues<const N: usize> {
    table: &'static ParamTable,
    norm: [f32; N],
    /// Normalized modulation offset per slot. The base in `norm` is never written by modulation;
    /// the effective value is `clamp(norm + offset)` (ADR-0014).
    offset: [f32; N],
}

impl<const N: usize> ParamValues<N> {
    /// Every parameter at its default. `N` must equal the table's length.
    pub fn new(table: &'static ParamTable) -> Self {
        assert_eq!(table.len(), N, "ParamValues: N doesn't match the table");
        let mut norm = [0.0; N];
        for (value, spec) in norm.iter_mut().zip(table.specs) {
            *value = spec.default_norm();
        }
        Self {
            table,
            norm,
            offset: [0.0; N],
        }
    }

    pub fn table(&self) -> &'static ParamTable {
        self.table
    }

    /// Base (unmodulated) normalized value at `slot`.
    pub fn norm_at(&self, slot: usize) -> f32 {
        self.norm[slot]
    }

    /// Base normalized value of `id`, ignoring any modulation offset.
    pub fn get(&self, id: ParamId) -> Option<f32> {
        self.table.slot(id).map(|s| self.norm[s])
    }

    /// Effective normalized value of `id`: the base plus its modulation offset, clamped.
    pub fn effective_norm(&self, id: ParamId) -> Option<f32> {
        self.table.slot(id).map(|s| self.effective_norm_at(s))
    }

    /// Effective normalized value at `slot`: the base plus its modulation offset, clamped.
    pub fn effective_norm_at(&self, slot: usize) -> f32 {
        (self.norm[slot] + self.offset[slot]).clamp(0.0, 1.0)
    }

    /// Modulation offset at `slot`, in normalized units.
    pub fn offset_at(&self, slot: usize) -> f32 {
        self.offset[slot]
    }

    /// Real value of `id` with its modulation offset applied (a choice index for enums, 0 or 1
    /// for bools). Modulation never changes an enum or a bool, so those stay at the base.
    pub fn real(&self, id: ParamId) -> Option<f32> {
        let slot = self.table.slot(id)?;
        Some(self.table.specs[slot].to_real(self.effective_norm_at(slot)))
    }

    /// Store `norm` (canonicalized) as the base and return the slot and the effective real value
    /// (base plus any modulation offset) it decodes to, or None for an unknown ID.
    pub fn set(&mut self, id: ParamId, norm: f32) -> Option<(usize, f32)> {
        let slot = self.table.slot(id)?;
        let spec = &self.table.specs[slot];
        self.norm[slot] = spec.canonical(norm);
        Some((slot, spec.to_real(self.effective_norm_at(slot))))
    }

    /// Set the modulation offset of `id` and return the slot and the resulting effective real
    /// value. Returns None for an unknown ID or a parameter that isn't modulatable (enums and
    /// bools never are), so callers skip their `apply`. Offsets are absolute, not additive; the
    /// base is left untouched.
    pub fn set_offset(&mut self, id: ParamId, offset: f32) -> Option<(usize, f32)> {
        let slot = self.table.slot(id)?;
        let spec = &self.table.specs[slot];
        if !spec.is_modulatable() {
            return None;
        }
        self.offset[slot] = offset;
        Some((slot, spec.to_real(self.effective_norm_at(slot))))
    }

    /// Drop every modulation offset (back to the base).
    pub fn clear_offsets(&mut self) {
        self.offset.fill(0.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHOICES: &[&str] = &["A", "B", "C"];
    const PART_A: [ParamSpec; 2] = [
        spec(0, "Freq", "Main", "Hz", log(20.0, 20_000.0), 1_000.0),
        spec(1, "Mode", "Main", "", Kind::Enum(CHOICES), 2.0),
    ];
    const PART_B: [ParamSpec; 2] = [
        spec(10, "Link", "Other", "", Kind::Bool, 1.0),
        spec(11, "Listen", "Other", "", Kind::Bool, 0.0)
            .hidden()
            .not_automatable(),
    ];
    const SPECS: [ParamSpec; 4] = flatten(&[&PART_A, &PART_B]);
    const SLOTS: [u8; 20] = slot_table(&SPECS);
    static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

    #[test]
    fn flatten_keeps_order_and_slots_follow_it() {
        let ids: Vec<ParamId> = SPECS.iter().map(|s| s.id).collect();
        assert_eq!(ids, vec![0, 1, 10, 11]);
        assert_eq!(TABLE.slot(10), Some(2));
        assert_eq!(TABLE.slot_of(11), 3);
        assert_eq!(TABLE.slot(5), None);
        assert_eq!(TABLE.slot(99), None);
    }

    #[test]
    fn values_start_at_defaults_and_round_trip() {
        let mut values = ParamValues::<4>::new(&TABLE);
        assert!((values.real(0).unwrap() - 1_000.0).abs() < 0.1);
        assert_eq!(values.real(1), Some(2.0));
        assert_eq!(values.get(10), Some(1.0));

        // Enums and bools snap; floats clamp.
        assert_eq!(values.set(1, 0.3), Some((1, 1.0)));
        assert_eq!(values.get(1), Some(0.5));
        assert_eq!(values.set(10, 0.2), Some((2, 0.0)));
        assert_eq!(values.get(10), Some(0.0));
        values.set(0, 1.5);
        assert_eq!(values.get(0), Some(1.0));
        assert_eq!(values.set(42, 0.5), None);
    }

    #[test]
    fn info_carries_flags_and_types() {
        let infos = TABLE.infos();
        assert_eq!(infos[2].param_type, ParamType::Bool);
        assert!(infos[0].is_logarithmic);
        assert!(!infos[0].is_hidden && infos[0].is_automation_safe);
        assert!(infos[3].is_hidden && !infos[3].is_automation_safe);
        assert!(!SPECS[3].is_modulatable());
        assert!(SPECS[0].is_modulatable());
    }

    #[test]
    fn offsets_move_the_effective_value_without_touching_the_base() {
        let mut values = ParamValues::<4>::new(&TABLE);
        values.set(0, 0.5);
        let base = values.get(0).unwrap();
        let real_base = values.real(0).unwrap();

        let (slot, real) = values.set_offset(0, 0.25).unwrap();
        assert_eq!(slot, 0);
        assert_eq!(values.get(0), Some(base), "base is untouched");
        assert!(real > real_base, "the offset raises the effective value");
        assert!((values.effective_norm_at(0) - (base + 0.25)).abs() < 1e-6);
        assert_eq!(values.offset_at(0), 0.25);

        values.set_offset(0, 0.0);
        assert_eq!(
            values.real(0),
            Some(real_base),
            "offset 0 restores the base"
        );

        // Offsets clamp at the top, and set() returns the effective real.
        values.set(0, 0.9);
        let (_, clamped) = values.set_offset(0, 0.5).unwrap();
        assert_eq!(values.effective_norm_at(0), 1.0);
        assert_eq!(clamped, TABLE.spec(0).unwrap().to_real(1.0));

        values.clear_offsets();
        assert_eq!(values.offset_at(0), 0.0);
        assert_eq!(values.set_offset(42, 0.5), None, "unknown ID");
        assert_eq!(values.set_offset(1, 0.5), None, "enum is not modulatable");
        assert_eq!(values.set_offset(10, 0.5), None, "bool is not modulatable");
    }
}
