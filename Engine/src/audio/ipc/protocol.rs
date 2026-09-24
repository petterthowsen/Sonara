//! Protocol between the engine and `plugin_host` processes. Both binaries use this module.
//!
//! **Communication model:**
//! - Control channel: a Unix socketpair carrying length-prefixed bincode frames (`wire.rs`).
//!   The engine sends `HostRequest`s; the host answers with `HostMessage::Response` (matched by
//!   `request_id`) and sends `HostMessage::Event`s on its own (parameter changes from the plugin
//!   GUI, GUI resize requests).
//! - File descriptors (the shared-memory memfd) ride along with a frame as `SCM_RIGHTS`.
//! - Audio and MIDI travel through shared memory, never over the socket.
//!
//! Every message addresses a plugin **instance**, not a process, so several instances can later
//! share one host process (hosting modes) without a protocol change.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Identifies one plugin instance across all host processes. Allocated by `ProcessManager`.
pub type InstanceId = u32;

/// Matches a response to its request. Unique per host process.
pub type RequestId = u32;

/// `request_id` of a command that wants no reply. The host may still answer with an error,
/// which the engine logs.
pub const NO_REPLY: RequestId = 0;

/// Engine → host.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostRequest {
    pub instance_id: InstanceId,
    pub request_id: RequestId,
    pub command: PluginCommand,
}

/// Host → engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum HostMessage {
    /// Reply to the `HostRequest` with the same `request_id`.
    Response {
        instance_id: InstanceId,
        request_id: RequestId,
        response: PluginResponse,
    },
    /// Sent by the host on its own.
    Event {
        instance_id: InstanceId,
        event: PluginEvent,
    },
}

/// Commands sent from engine to a plugin instance
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginCommand {
    /// Load the plugin into a new instance. The frame carries the instance's shared-memory FD.
    Initialize {
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
    },

    /// Activate (or re-activate at a new rate) the plugin for audio processing. Re-activation
    /// deactivates first, which is the sample-rate change path Phase 7 uses.
    Activate { sample_rate: f32 },

    /// Deactivate plugin (stop processing, free buffers)
    Deactivate,

    /// Start audio processing
    StartProcessing,

    /// Stop audio processing
    StopProcessing,

    /// Set parameter value (normalized 0.0-1.0)
    SetParameter { param_id: u32, value: f32 },

    /// Get current parameter value
    GetParameter { param_id: u32 },

    /// Get all parameter info
    GetParameterInfo,

    /// Open plugin GUI
    OpenGui {
        /// X11 window handle for embedded mode (None = use floating mode)
        window_handle: Option<u64>,
    },

    /// Close plugin GUI
    CloseGui,

    /// Check if GUI is supported
    HasGui,

    /// Save plugin state
    SaveState,

    /// Load plugin state
    LoadState { state: Vec<u8> },

    /// Reset plugin (clear buffers, stop voices)
    Reset,

    /// Shut down the whole host process
    Shutdown,
}

/// Responses sent from a plugin instance to engine requests
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginResponse {
    /// Initialization successful
    InitializeSuccess {
        device_name: String,
        device_vendor: String,
        device_version: String,
        category: String,
    },

    /// Initialization failed
    InitializeError { error: String },

    /// Activation result. `latency_frames` is the plugin's reported latency at this sample rate
    /// (0 when the plugin has no latency extension).
    ActivateResult {
        success: bool,
        error: Option<String>,
        latency_frames: u32,
    },

    /// Deactivation result
    DeactivateResult {
        success: bool,
        error: Option<String>,
    },

    /// Processing started
    ProcessingStarted,

    /// Processing stopped
    ProcessingStopped,

    /// Parameter value response
    ParameterValue { param_id: u32, value: f32 },

    /// Parameter info response
    ParameterInfo { params: Vec<PluginParameterInfo> },

    /// GUI opened successfully
    GuiOpened {
        width: u32,
        height: u32,
        is_resizable: bool,
    },

    /// GUI closed
    GuiClosed,

    /// GUI support status
    HasGuiResponse { supported: bool },

    /// GUI error
    GuiError { error: String },

    /// Plugin state saved
    StateSaved { state: Vec<u8> },

    /// State load result
    StateLoadResult {
        success: bool,
        error: Option<String>,
    },

    /// Plugin reset complete
    ResetComplete,

    /// Generic error response
    Error { command: String, error: String },
}

/// Messages a plugin instance sends without being asked
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginEvent {
    /// Parameter value changed from the plugin GUI or internal modulation
    ParameterValueChanged {
        param_id: u32,
        /// Normalized 0.0-1.0
        value: f32,
    },

    /// The plugin asked for its GUI window to be resized
    GuiResizeRequest { width: u32, height: u32 },
}

/// Parameter metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginParameterInfo {
    pub id: u32,
    pub name: String,
    pub unit: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub is_automation_safe: bool,
    pub is_stepped: bool,
    pub is_hidden: bool,
    pub is_read_only: bool,
    pub is_bypass: bool,
    /// CLAP module path, e.g. "Early/Size"; "" if none
    pub module: String,
    /// Per-step display labels, only when `is_stepped` and (max-min+1) <= 64; else empty
    pub step_labels: Vec<String>,
}

/// Audio channels carried by one instance's shared block (planar input and output).
pub const MAX_PLUGIN_CHANNELS: usize = 2;

/// Events one side may send per block (input events from the engine, output events from the
/// plugin).
pub const MAX_BLOCK_EVENTS: usize = 256;

/// Shared memory layout for one plugin instance's audio block.
///
/// The engine fills the input audio and the input events, publishes `request_seq`, then rings the
/// host process's doorbell. The host processes exactly that block, writes the output audio and
/// its output events, and sets `done_seq`. Offsets are byte offsets into the mapping.
///
/// ```text
/// [input audio:  max_frames × max_channels f32, planar]
/// [output audio: max_frames × max_channels f32, planar]
/// [input events: max_events × BlockEvent]
/// [output events: max_events × BlockEvent]
/// [BlockControl]
/// ```
#[derive(Debug, Clone, Copy)]
pub struct SharedMemoryLayout {
    /// Frames per block (per channel).
    pub max_frames: usize,
    /// Audio channels per plane.
    pub max_channels: usize,
    /// Events per direction.
    pub max_events: usize,

    pub input_offset: usize,
    pub output_offset: usize,
    pub input_events_offset: usize,
    pub output_events_offset: usize,
    pub control_offset: usize,
}

impl SharedMemoryLayout {
    /// Layout for stereo blocks of up to `max_frames` frames.
    pub fn new(max_frames: usize) -> Self {
        Self::with_channels(max_frames, MAX_PLUGIN_CHANNELS)
    }

    pub fn with_channels(max_frames: usize, max_channels: usize) -> Self {
        let max_frames = max_frames.max(1);
        let max_channels = max_channels.max(1);
        let plane_bytes = max_frames * max_channels * std::mem::size_of::<f32>();
        let events_bytes = MAX_BLOCK_EVENTS * std::mem::size_of::<BlockEvent>();

        let input_offset = 0;
        let output_offset = align_up(input_offset + plane_bytes, 64);
        let input_events_offset = align_up(output_offset + plane_bytes, 64);
        let output_events_offset = align_up(input_events_offset + events_bytes, 64);
        let control_offset = align_up(output_events_offset + events_bytes, 64);

        Self {
            max_frames,
            max_channels,
            max_events: MAX_BLOCK_EVENTS,
            input_offset,
            output_offset,
            input_events_offset,
            output_events_offset,
            control_offset,
        }
    }

    /// Total shared memory size in bytes.
    pub fn total_size(&self) -> usize {
        self.control_offset + std::mem::size_of::<BlockControl>()
    }
}

fn align_up(value: usize, align: usize) -> usize {
    (value + align - 1) & !(align - 1)
}

/// Note on / note off inside a block's event array.
pub const EVENT_NOTE_ON: u16 = 1;
pub const EVENT_NOTE_OFF: u16 = 2;
/// Parameter change inside a block's event array.
pub const EVENT_PARAM: u16 = 3;

/// One event in a block's input or output event array.
///
/// `sample_offset` is relative to the block start, which makes notes and parameter changes
/// sample-accurate. `value` is a note velocity or a normalized (0.0–1.0) parameter value; `id` is
/// the engine's parameter index for parameter events and 0 for notes.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct BlockEvent {
    pub sample_offset: u32,
    pub kind: u16,
    pub note: u8,
    pub _reserved: u8,
    pub value: f32,
    pub id: u32,
}

impl BlockEvent {
    pub fn note(sample_offset: u32, note: u8, velocity_01: f32, is_note_on: bool) -> Self {
        Self {
            sample_offset,
            kind: if is_note_on {
                EVENT_NOTE_ON
            } else {
                EVENT_NOTE_OFF
            },
            note,
            _reserved: 0,
            value: velocity_01,
            id: 0,
        }
    }

    pub fn param(sample_offset: u32, param_id: u32, value_01: f32) -> Self {
        Self {
            sample_offset,
            kind: EVENT_PARAM,
            note: 0,
            _reserved: 0,
            value: value_01,
            id: param_id,
        }
    }
}

/// Per-instance control block for the block handshake.
///
/// Ordering: the engine writes the input and the input events, then stores `request_seq` with
/// `Release`. The host loads it with `Acquire`, processes, writes the output and its output
/// events, then stores `done_seq` (the processed `request_seq`) with `Release`. The engine loads
/// `done_seq` with `Acquire`. The counters in between are plain `Relaxed` atomics ordered by the
/// two sequence numbers.
#[repr(C)]
pub struct BlockControl {
    /// Incremented by the engine for every block it publishes.
    pub request_seq: std::sync::atomic::AtomicU64,
    /// The `request_seq` value the host has finished processing.
    pub done_seq: std::sync::atomic::AtomicU64,
    /// Frames the engine wrote into the input planes.
    pub input_frames: std::sync::atomic::AtomicU32,
    /// Frames the host wrote into the output planes.
    pub output_frames: std::sync::atomic::AtomicU32,
    /// Input events the engine wrote.
    pub input_event_count: std::sync::atomic::AtomicU32,
    /// Output events the host wrote.
    pub output_event_count: std::sync::atomic::AtomicU32,
    /// 0 = ok, 1 = the plugin's `process()` failed on the last block.
    pub status: std::sync::atomic::AtomicU32,
    pub _reserved: [u8; 24],
}

impl Default for BlockControl {
    fn default() -> Self {
        Self {
            request_seq: std::sync::atomic::AtomicU64::new(0),
            done_seq: std::sync::atomic::AtomicU64::new(0),
            input_frames: std::sync::atomic::AtomicU32::new(0),
            output_frames: std::sync::atomic::AtomicU32::new(0),
            input_event_count: std::sync::atomic::AtomicU32::new(0),
            output_event_count: std::sync::atomic::AtomicU32::new(0),
            status: std::sync::atomic::AtomicU32::new(0),
            _reserved: [0; 24],
        }
    }
}

/// One word shared by a host process and the engine: the engine rings it for any of its
/// instances, and the host rings it back when a block is finished.
#[repr(C)]
pub struct Doorbell {
    pub word: std::sync::atomic::AtomicU32,
    pub _reserved: [u8; 60],
}

impl Default for Doorbell {
    fn default() -> Self {
        Self {
            word: std::sync::atomic::AtomicU32::new(0),
            _reserved: [0; 60],
        }
    }
}
