pub mod active_notes;
pub mod analysis;
pub mod automation;
pub mod block_clock;
pub mod channel;
pub mod clip;
pub mod command_worker;
pub mod commands;
pub mod devices;
pub mod dsp;
pub mod engine;
pub mod io;
pub mod ipc;
pub mod midi_types;
pub mod mixing;
pub mod modulation;
pub mod pipewire;
pub mod processing;
pub mod project;
pub mod render;
pub mod render_scratch;
pub mod rt_debug;
pub mod state;
pub mod stream;
pub mod tempo_map;
pub mod time_signature_map;
pub mod track;
pub mod transport;
pub mod types;

pub use automation::{
    apply_tension, evaluate_segment, AutomationLane, AutomationLaneId, AutomationPoint,
    AutomationPointId, AutomationTarget, CurveKind,
};
pub use channel::{Channel, PanCoefficients, PanMode, Send};
pub use clip::{AudioPlayback, Clip, ClipInstance, ClipLoadState, ClipNote, ClipType};
pub use devices::{AudioDevice, DelayDevice, ParamId, ParamValue};
pub use engine::{AudioCommand, AudioEngine, EngineStatus};
pub use midi_types::*;
pub use project::ProjectSettings;
pub use track::Track;
pub use types::*;
