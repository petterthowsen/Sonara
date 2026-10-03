//! Device modulators: sources that belong to a device instance and drive parameters of that
//! device or of devices nested inside it.
//!
//! - [`kinds`] defines the modulator kinds (`lfo`, `adsr`, `ad`, `velocity`, `keytrack`,
//!   `random`), each with its own parameter table, and [`kinds::ModParams`], the fixed-capacity
//!   normalized value block a modulator holds.
//! - [`state::ModulatorState`] is one modulator's runtime: its kind, parameters and the
//!   note-driven DSP state.
//! - [`lfo`] and [`envelope`] are the shared LFO and envelope DSP the modulators (and, for the
//!   envelope, the sampler) run on.
//! - [`matrix`] is the fixed-capacity route matrix: routes point at a modulator slot and a
//!   target parameter.
//!
//! Evaluation is host-side (mono) or device-internal (poly): see ADR-0014. The mono path lives
//! in [`host`], and [`voice::VoiceModSpec`] is the snapshot a poly-capable device receives.

pub mod envelope;
pub mod host;
pub mod kinds;
pub mod lfo;
pub mod matrix;
pub mod state;
pub mod voice;

/// Modulators one device instance can hold.
pub const MAX_MODULATORS: usize = 8;

/// Modulation routes one device instance can hold.
pub const MAX_ROUTES: usize = matrix::MAX_ROUTES;

pub use host::{unwrap_at_path, wrap_at_path, Modulated, ModulatedDevice, CONTROL_STEP};
pub use kinds::{ModParams, ModulatorKind, MAX_KIND_PARAMS};
pub use state::ModulatorState;
pub use voice::VoiceModSpec;
