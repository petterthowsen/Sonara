//! IPC Protocol for Plugin Subprocess Communication
//!
//! This module defines the message types for communication between the main
//! Sonara engine process and individual plugin host subprocesses.
//!
//! **Communication Model:**
//! - Commands: Engine → Plugin (via Unix socket)
//! - Responses: Plugin → Engine (via Unix socket)  
//! - Audio: Bidirectional via shared memory ring buffers
//! - MIDI: Engine → Plugin via shared memory event queue
//! - Parameters: Bidirectional via Unix socket (not real-time critical)

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Commands sent from engine to plugin subprocess
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PluginCommand {
    /// Initialize plugin (sent once at startup)
    Initialize {
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
        /// Shared memory file descriptor (passed separately via Unix socket)
        /// For now, we use a name-based approach where subprocess recreates the FD
        shm_name: String,
    },

    /// Activate plugin for audio processing
    Activate,

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
    LoadState { state_base64: String },

    /// Reset plugin (clear buffers, stop voices)
    Reset,

    /// Shutdown subprocess gracefully
    Shutdown,
}

/// Responses sent from plugin subprocess to engine
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

    /// Activation result
    ActivateResult {
        success: bool,
        error: Option<String>,
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
    StateSaved { state_base64: String },

    /// State load result
    StateLoadResult {
        success: bool,
        error: Option<String>,
    },

    /// Plugin reset complete
    ResetComplete,

    /// Generic error response
    Error { command: String, error: String },

    /// Subprocess shutting down
    ShutdownAck,

    /// Parameter value changed (unsolicited, from plugin GUI/modulation)
    ParameterValueChanged {
        param_id: u32,
        value: f32, // Normalized 0.0-1.0
    },

    /// GUI resize requested (unsolicited, from plugin)
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
}

/// Shared memory layout for audio and MIDI data
///
/// Memory layout:
/// ```
/// [AudioRingBuffer: input]   - Input audio from engine
/// [AudioRingBuffer: output]  - Output audio to engine
/// [MidiEventQueue]           - MIDI events from engine
/// [ControlData]              - Control/status info
/// ```
#[derive(Debug, Clone, Copy)]
pub struct SharedMemoryLayout {
    /// Size of input audio ring buffer (in samples)
    pub input_buffer_size: usize,

    /// Size of output audio ring buffer (in samples)
    pub output_buffer_size: usize,

    /// Number of MIDI event slots
    pub midi_queue_size: usize,

    /// Offset to input audio buffer
    pub input_offset: usize,

    /// Offset to output audio buffer
    pub output_offset: usize,

    /// Offset to MIDI queue
    pub midi_offset: usize,

    /// Offset to control data
    pub control_offset: usize,
}

impl SharedMemoryLayout {
    /// Create a new layout with standard sizes
    pub fn new(max_buffer_size: usize) -> Self {
        // Allocate just 2 buffers worth of data for low latency
        // Any more causes noticeable delay
        let input_buffer_size = max_buffer_size * 2 * 2; // Stereo * 2 buffers
        let output_buffer_size = max_buffer_size * 2 * 2;
        let midi_queue_size = 256; // 256 MIDI events

        let input_offset = 0;
        let output_offset = input_offset + input_buffer_size * std::mem::size_of::<f32>();
        let midi_offset = output_offset + output_buffer_size * std::mem::size_of::<f32>();
        let control_offset = midi_offset + midi_queue_size * std::mem::size_of::<MidiEvent>();

        Self {
            input_buffer_size,
            output_buffer_size,
            midi_queue_size,
            input_offset,
            output_offset,
            midi_offset,
            control_offset,
        }
    }

    /// Calculate total shared memory size
    pub fn total_size(&self) -> usize {
        self.control_offset + std::mem::size_of::<ControlData>()
    }
}

/// MIDI event stored in shared memory queue
#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct MidiEvent {
    /// Sample offset within buffer
    pub sample_offset: u32,

    /// Note number (0-127)
    pub note: u8,

    /// Velocity (0-127)
    pub velocity: u8,

    /// 1 = note on, 0 = note off
    pub is_note_on: u8,

    /// Padding for alignment
    pub _padding: u8,
}

/// Control data shared between engine and plugin
#[derive(Debug)]
#[repr(C)]
pub struct ControlData {
    /// Write position in input ring buffer (samples)
    pub input_write_pos: std::sync::atomic::AtomicUsize,

    /// Read position in input ring buffer (samples)
    pub input_read_pos: std::sync::atomic::AtomicUsize,

    /// Write position in output ring buffer (samples)
    pub output_write_pos: std::sync::atomic::AtomicUsize,

    /// Read position in output ring buffer (samples)
    pub output_read_pos: std::sync::atomic::AtomicUsize,

    /// Write position in MIDI queue (events)
    pub midi_write_pos: std::sync::atomic::AtomicUsize,

    /// Read position in MIDI queue (events)
    pub midi_read_pos: std::sync::atomic::AtomicUsize,

    /// Plugin is processing (1 = yes, 0 = no)
    pub is_processing: std::sync::atomic::AtomicU8,

    /// Request shutdown (1 = yes, 0 = no)
    pub shutdown_requested: std::sync::atomic::AtomicU8,

    /// Padding for alignment
    _padding: [u8; 6],
}

impl Default for ControlData {
    fn default() -> Self {
        Self {
            input_write_pos: std::sync::atomic::AtomicUsize::new(0),
            input_read_pos: std::sync::atomic::AtomicUsize::new(0),
            output_write_pos: std::sync::atomic::AtomicUsize::new(0),
            output_read_pos: std::sync::atomic::AtomicUsize::new(0),
            midi_write_pos: std::sync::atomic::AtomicUsize::new(0),
            midi_read_pos: std::sync::atomic::AtomicUsize::new(0),
            is_processing: std::sync::atomic::AtomicU8::new(0),
            shutdown_requested: std::sync::atomic::AtomicU8::new(0),
            _padding: [0; 6],
        }
    }
}

/// Ring buffer statistics for debugging
#[derive(Debug, Clone, Copy)]
pub struct RingBufferStats {
    pub available_samples: usize,
    pub capacity: usize,
    pub utilization_percent: f32,
}
