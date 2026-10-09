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
//! Every message addresses a plugin **instance**, not a process, so several instances can share
//! one host process (hosting modes, `hosting.rs`). `Shutdown` is the only command that addresses
//! the whole process.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Identifies one plugin instance across all host processes. Allocated by `ProcessManager`.
pub type InstanceId = u32;

/// Matches a response to its request. Unique per host process.
pub type RequestId = u32;

/// `request_id` of a command that wants no reply. The host may still answer with an error,
/// which the engine logs.
pub const NO_REPLY: RequestId = 0;

/// File name of a plugin host's log (`<log dir>/<this>`): its host key made safe for a file
/// name, then its pid. The host names its file this way and the engine reports the path.
pub fn log_file_name(host_key: &str, pid: u32) -> String {
    let key: String = host_key
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect();
    format!("{}-{}.log", key, pid)
}

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
    /// A WARN or ERROR line from the host's log, forwarded so it reaches the engine log and
    /// Godot's `/log`. `instance_id` is 0 for a line that isn't about one instance; `plugin` is
    /// the instance's plugin name ("" when unknown).
    Log {
        instance_id: InstanceId,
        plugin: String,
        level: LogLevel,
        message: String,
    },
}

/// Severity of a forwarded host log line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LogLevel {
    Warn,
    Error,
}

/// The plugin format an instance is loaded as (spec 028). The two formats share the IPC
/// protocol and the shared-memory block; the host dispatches on this at `Initialize`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum PluginFormat {
    #[default]
    Clap,
    Vst3,
}

impl PluginFormat {
    /// The lowercase name used in device type strings and `/plugin/info`.
    pub fn as_str(self) -> &'static str {
        match self {
            PluginFormat::Clap => "clap",
            PluginFormat::Vst3 => "vst3",
        }
    }
}

/// Commands sent from engine to a plugin instance
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginCommand {
    /// Load the plugin into a new instance. The frame carries the instance's shared-memory FD.
    /// For VST3, `plugin_path` is the `.vst3` bundle and `plugin_id` the class ID as 32 hex
    /// characters.
    Initialize {
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
        #[serde(default)]
        format: PluginFormat,
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

    /// Show or hide an open GUI (CLAP `gui.show()`/`gui.hide()`). Answered with `GuiSize`.
    SetGuiVisible { visible: bool },

    /// Ask a resizable GUI to take this size: `adjust_size`, then `set_size`. Answered with
    /// `GuiSize` carrying the size the plugin settled on.
    SetGuiSize { width: u32, height: u32 },

    /// Check if GUI is supported
    HasGui,

    /// Save plugin state
    SaveState,

    /// Load plugin state
    LoadState { state: Vec<u8> },

    /// Reset plugin (clear buffers, stop voices)
    Reset,

    /// Tell the plugin whether it renders offline (export) or in real time, through the CLAP
    /// render extension. Answered with `RenderModeSet`.
    SetRenderMode { offline: bool },

    /// Remove this instance from its host, which keeps running for its other instances: close
    /// its GUI, deactivate it and drop it. Answered with `Unloaded`.
    Unload,

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
        /// The plugin runs in its own window: it was asked to embed but only supports floating.
        floating: bool,
    },

    /// Current GUI size (answer to `SetGuiVisible` and `SetGuiSize`)
    GuiSize { width: u32, height: u32 },

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

    /// Answer to `SetRenderMode`: false when the plugin has no render extension or declined.
    RenderModeSet { applied: bool },

    /// The instance was removed from its host (`Unload`)
    Unloaded,

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

    /// The plugin called `mark_dirty`: its saved state no longer matches what was loaded. The
    /// engine refreshes its state blob from this (crash recovery, project save).
    StateDirty,
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
    /// CLAP `PARAM_IS_MODULATABLE`: can a modulator drive this parameter? (spec 018 Phase 5)
    pub is_modulatable: bool,
    /// CLAP module path, e.g. "Early/Size"; "" if none
    pub module: String,
    /// Per-step display labels, only when `is_stepped` and (max-min+1) <= 64; else empty
    pub step_labels: Vec<String>,
    /// Real display values at `value_text::DISPLAY_POINTS` evenly spaced plain values, parsed from
    /// the plugin's value text (in `unit`); NaN where a label didn't parse. Empty when the text
    /// gave no usable curve or the parameter is stepped.
    #[serde(default)]
    pub display: Vec<f32>,
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
/// [BlockTransport]
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
    pub transport_offset: usize,
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
        let transport_offset = align_up(output_events_offset + events_bytes, 64);
        let control_offset = align_up(transport_offset + std::mem::size_of::<BlockTransport>(), 64);

        Self {
            max_frames,
            max_channels,
            max_events: MAX_BLOCK_EVENTS,
            input_offset,
            output_offset,
            input_events_offset,
            output_events_offset,
            transport_offset,
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
/// Modulation offset inside a block's event array (spec 018 Phase 5). The host turns it into a
/// CLAP `PARAM_MOD` event; `value` is the offset in normalized units and the base value is never
/// written (ADR-0014).
pub const EVENT_PARAM_MOD: u16 = 4;
/// Choke every sounding note (Drum Machine choke targets). The host turns it into a CLAP
/// `NOTE_CHOKE` with a wildcard Pckn; `note`, `value` and `id` are unused.
pub const EVENT_NOTE_CHOKE: u16 = 5;

/// One event in a block's input or output event array.
///
/// `sample_offset` is relative to the block start, which makes notes and parameter changes
/// sample-accurate. `value` is a note's velocity (note-on) or release velocity (note-off), a
/// normalized (0.0–1.0) parameter value or a normalized modulation offset; `id` is the engine's
/// parameter index for parameter events and the sounding-note id for notes (the CLAP
/// `note_id`). Note expressions aren't sent over IPC yet.
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
    /// A note-on (`value` = velocity) or note-off (`value` = release velocity), both 0–1.
    pub fn note(
        sample_offset: u32,
        note_id: u32,
        key: u8,
        value_01: f32,
        is_note_on: bool,
    ) -> Self {
        Self {
            sample_offset,
            kind: if is_note_on {
                EVENT_NOTE_ON
            } else {
                EVENT_NOTE_OFF
            },
            note: key,
            _reserved: 0,
            value: value_01,
            id: note_id,
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

    /// Choke every sounding note at `sample_offset`.
    pub fn choke(sample_offset: u32) -> Self {
        Self {
            sample_offset,
            kind: EVENT_NOTE_CHOKE,
            note: 0,
            _reserved: 0,
            value: 0.0,
            id: 0,
        }
    }

    /// A modulation offset (normalized units) for `param_id`, taking effect at `sample_offset`.
    pub fn param_mod(sample_offset: u32, param_id: u32, offset_norm: f32) -> Self {
        Self {
            sample_offset,
            kind: EVENT_PARAM_MOD,
            note: 0,
            _reserved: 0,
            value: offset_norm,
            id: param_id,
        }
    }
}

/// `BlockTransport::flags` bit 0: the transport is playing.
pub const TRANSPORT_FLAG_PLAYING: u32 = 1;

/// Transport state for one block (engine writes, host reads), ordered by the same
/// `request_seq` Release/Acquire pair as the events. The host always sets the tempo, beats,
/// seconds and time-signature flags on the CLAP event, so only `playing` is carried.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct BlockTransport {
    pub tempo: f64,
    /// BPM change per sample.
    pub tempo_inc: f64,
    pub song_pos_beats: f64,
    pub song_pos_seconds: f64,
    pub bar_start_beats: f64,
    pub bar_number: i32,
    pub flags: u32,
    pub tsig_num: i16,
    pub tsig_den: i16,
    pub _reserved: [u8; 20],
}

impl From<&crate::audio::transport::Transport> for BlockTransport {
    fn from(t: &crate::audio::transport::Transport) -> Self {
        Self {
            tempo: t.tempo,
            tempo_inc: t.tempo_inc,
            song_pos_beats: t.song_pos_beats,
            song_pos_seconds: t.song_pos_seconds,
            bar_start_beats: t.bar_start_beats,
            bar_number: t.bar_number,
            flags: if t.playing { TRANSPORT_FLAG_PLAYING } else { 0 },
            tsig_num: t.time_sig_num as i16,
            tsig_den: t.time_sig_den as i16,
            _reserved: [0; 20],
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
    /// Nanoseconds the plugin's `process()` took on the last block, measured by the host
    /// (saturates at `u32::MAX`, about 4 s). Per-plugin stats (Phase 6).
    pub process_ns: std::sync::atomic::AtomicU32,
    pub _reserved: [u8; 20],
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
            process_ns: std::sync::atomic::AtomicU32::new(0),
            _reserved: [0; 20],
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_event_note_round_trips_id() {
        let on = BlockEvent::note(12, 4321, 60, 0.5039, true);
        assert_eq!(
            (on.sample_offset, on.kind, on.note, on.value, on.id),
            (12, EVENT_NOTE_ON, 60, 0.5039, 4321)
        );
        let off = BlockEvent::note(40, 4321, 60, 0.25, false);
        assert_eq!(
            (off.sample_offset, off.kind, off.note, off.value, off.id),
            (40, EVENT_NOTE_OFF, 60, 0.25, 4321)
        );
        // The layout the plugin host reads is unchanged.
        assert_eq!(std::mem::size_of::<BlockEvent>(), 16);
    }

    #[test]
    fn log_file_names_are_safe() {
        assert_eq!(
            log_file_name("vendor:Michael Willis", 42),
            "vendor_Michael_Willis-42.log"
        );
        assert_eq!(
            log_file_name("plugin:com.lsp/comp", 7),
            "plugin_com.lsp_comp-7.log"
        );
    }
}
