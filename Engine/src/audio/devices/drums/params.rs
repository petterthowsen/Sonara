//! Shared parameter block for the drum instruments (spec 013, IDs 90–99).
//!
//! Every drum's parameter table includes [`GLOBAL_SPECS`]; [`GlobalParams`] keeps their
//! normalized values and decodes the [`DrumParams`] view the voices read once per block.

use super::DrumParams;
use crate::audio::devices::param_table::{
    linear, slot_table, spec, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::ParamId;

pub const VELOCITY: ParamId = 90;
pub const OUTPUT: ParamId = 91;
pub const HUMANIZE: ParamId = 92;

/// Exclusive upper bound of the shared ID block, for the slot lookup.
const GLOBAL_IDS: usize = 99;

/// Velocity sensitivity, output gain and humanize, in ID order.
pub const GLOBAL_SPECS: [ParamSpec; 3] = [
    spec(
        VELOCITY,
        "Velocity",
        "Global",
        "%",
        linear(0.0, 100.0),
        50.0,
    ),
    spec(OUTPUT, "Output", "Global", "dB", linear(-60.0, 12.0), 0.0),
    spec(HUMANIZE, "Humanize", "Global", "%", linear(0.0, 100.0), 0.0),
];
const GLOBAL_SLOTS: [u8; GLOBAL_IDS] = slot_table(&GLOBAL_SPECS);
static GLOBAL_TABLE: ParamTable = ParamTable::new(&GLOBAL_SPECS, &GLOBAL_SLOTS);

/// The shared drum parameters at their own normalized values.
#[derive(Clone, Copy)]
pub struct GlobalParams {
    values: ParamValues<3>,
}

impl GlobalParams {
    pub fn new() -> Self {
        Self {
            values: ParamValues::new(&GLOBAL_TABLE),
        }
    }

    /// The table these three parameters live in.
    pub fn table() -> &'static ParamTable {
        &GLOBAL_TABLE
    }

    /// Store `norm` if `id` is a shared parameter; false otherwise.
    pub fn set(&mut self, id: ParamId, norm: f32) -> bool {
        self.values.set(id, norm).is_some()
    }

    /// Normalized value of a shared parameter.
    pub fn get(&self, id: ParamId) -> Option<f32> {
        self.values.get(id)
    }

    /// The decoded view the voices read.
    pub fn params(&self) -> DrumParams {
        DrumParams {
            // Velocity is a 0–100 % linear range, so the normalized value is the 0–1 amount.
            velocity_sens: self.values.norm_at(0),
            output_db: self.values.real(OUTPUT).unwrap_or(0.0),
            humanize: self.values.norm_at(2),
        }
    }
}

impl Default for GlobalParams {
    fn default() -> Self {
        Self::new()
    }
}
