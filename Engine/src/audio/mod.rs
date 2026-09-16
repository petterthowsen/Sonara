pub mod automation;
pub mod command_worker;
pub mod commands;
pub mod devices;
pub mod dsp;
pub mod engine;
pub mod io;
pub mod ipc;
pub mod midi_types;
pub mod mixing;
pub mod processing;
pub mod render_scratch;
pub mod types;

pub use automation::{
    apply_tension, evaluate_segment, AutomationLane, AutomationLaneId, AutomationPoint,
    AutomationPointId, AutomationTarget, CurveKind,
};
pub use devices::{AudioDevice, DelayDevice, ParamId, ParamValue};
pub use engine::{AudioCommand, AudioEngine, EngineStatus};
pub use midi_types::*;
pub use types::*;
