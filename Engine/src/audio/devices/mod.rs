mod chain;
pub mod clap_host;
pub mod container;
mod delay;
mod drum_machine;
mod factory;
mod layer;
mod polysynth;
mod sampler;
mod sfizz_device;
mod spectrum_analyzer;

pub use chain::ChainDevice;
pub use clap_host::{ClapDeviceAdapter, PluginDescriptor, PluginScanner};
pub use container::{parse_osc_device_addr, DeviceContainer, DevicePath};
pub use delay::DelayDevice;
pub use drum_machine::DrumMachineDevice;
pub use factory::DeviceFactory;
pub use layer::LayerDevice;
pub use polysynth::PolySynthDevice;
pub use sampler::SamplerDevice;
pub use sfizz_device::SfizzDevice;
pub use spectrum_analyzer::SpectrumAnalyzerDevice;

use std::time::{Duration, Instant};

/// Audio silence threshold for sleep detection (-60dB)
const SLEEP_THRESHOLD: f32 = 0.001;

/// Default sleep timeout (3 seconds of inactivity)
const DEFAULT_SLEEP_TIMEOUT: Duration = Duration::from_secs(3);

/// Helper struct for tracking device sleep state (CPU optimization)
///
/// Usage:
/// 1. Call `mark_activity()` when MIDI/parameter changes occur
/// 2. Call `check_activity(has_audio)` before processing
/// 3. Use `is_sleeping()` to skip expensive processing
pub struct DeviceSleepState {
    last_activity_time: Instant,
    is_sleeping: bool,
    sleep_timeout: Duration,
}

impl DeviceSleepState {
    pub fn new() -> Self {
        Self {
            last_activity_time: Instant::now(),
            is_sleeping: false,
            sleep_timeout: DEFAULT_SLEEP_TIMEOUT,
        }
    }

    /// Mark activity (MIDI input, parameter change, etc.)
    /// Wakes device immediately
    pub fn mark_activity(&mut self) {
        self.last_activity_time = Instant::now();
        self.is_sleeping = false;
    }

    /// Check if device has had recent activity
    /// Returns true if state changed (for status events)
    pub fn check_activity(&mut self, has_audio_activity: bool) -> bool {
        let old_sleeping = self.is_sleeping;

        if has_audio_activity {
            // Audio activity detected - mark activity
            self.last_activity_time = Instant::now();
            self.is_sleeping = false;
        } else {
            // No audio - check if timeout elapsed
            let elapsed = self.last_activity_time.elapsed();
            if elapsed >= self.sleep_timeout {
                self.is_sleeping = true;
            }
        }

        // Return true if state changed
        old_sleeping != self.is_sleeping
    }

    pub fn is_sleeping(&self) -> bool {
        self.is_sleeping
    }

    pub fn set_sleep_timeout(&mut self, timeout: Duration) {
        self.sleep_timeout = timeout;
    }
}

impl Default for DeviceSleepState {
    fn default() -> Self {
        Self::new()
    }
}

/// Check if audio buffer has signal above sleep threshold
pub fn has_audio_signal(buffer: &[f32]) -> bool {
    buffer.iter().any(|&sample| sample.abs() > SLEEP_THRESHOLD)
}

/// Parameter ID (normalized 0.0-1.0, host/device agnostic)
pub type ParamId = u32;

/// Parameter value (always 0.0-1.0, device interprets range)
pub type ParamValue = f32;
/// Parameter type for metadata/UI
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParamType {
    Float,
    Bool,
    Enum,
}

/// Device variant: built-in or future plugin
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceVariant {
    BuiltIn,
    Lv2, // Future: LV2 plugin
    Clap,
}

/// Device category for plugin discovery
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceCategory {
    Instrument,
    Effect,
    Utility,
}

/// Port flow direction (for future plugin support)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortFlow {
    Input,
    Output,
}

/// Port type
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortType {
    Audio,
    Midi,
    Control, // Parameter/automation
}

/// Audio port specification (for plugin compatibility)
#[derive(Debug, Clone)]
pub struct AudioPort {
    pub id: u32,
    pub name: String,
    pub flow: PortFlow,
    pub channels: usize, // 1=mono, 2=stereo, etc.
}

/// MIDI port specification (future plugin MIDI input support)
#[derive(Debug, Clone)]
pub struct MidiPort {
    pub id: u32,
    pub name: String,
    pub flow: PortFlow,
}

/// Describes file loading support for a device
#[derive(Debug, Clone)]
pub struct FileLoadingSupport {
    pub description: String,
    pub extensions: Vec<String>,
}

/// Parameter metadata (for UI and parameter automation)
#[derive(Debug, Clone)]
pub struct ParamInfo {
    pub id: ParamId,
    pub name: String,
    pub unit: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub is_automation_safe: bool,
    pub param_type: ParamType,
    pub syncable: bool,
    pub enum_values: Vec<String>,
}

/// Base trait for all audio devices (instruments and effects)
///
/// Designed to support:
/// - Built-in devices (Oscillator, Delay)
/// - Future LV2/CLAP plugins (port-based architecture)
///
/// Devices are **stateful** audio processors that:
/// - Process audio in fixed-size blocks (real-time safe)
/// - Handle MIDI events between blocks (for plugin support)
/// - Accept parameter changes via `set_parameter()`
/// - Can be chained on channels
///
/// **Thread Safety**: All processing happens in the audio thread.
/// Parameter changes are serialized via the command channel.
pub trait AudioDevice: Send {
    /// Process audio block (samples per frame)
    ///
    /// **CRITICAL**: This must be real-time safe:
    /// - No allocations
    /// - No blocking calls
    /// - Predictable performance
    ///
    /// For stereo devices: inputs/outputs are interleaved [L, R, L, R, ...]
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize);

    /// Extra stereo output buses beyond the main stereo pair (drum pads, plugin extra outs).
    fn extra_output_bus_count(&self) -> usize {
        0
    }

    /// Process the main stereo pair and write extra stereo buses into `extra_outs`.
    ///
    /// Each `extra_outs[i]` is a preallocated interleaved stereo buffer. The audio thread
    /// must not grow these vectors. Unmapped extra buses should stay silent.
    fn process_block_with_extra(
        &mut self,
        inputs: &[f32],
        outputs: &mut [f32],
        extra_outs: &mut [Vec<f32>],
        sample_count: usize,
    ) {
        self.process_block(inputs, outputs, sample_count);
        let n = sample_count.saturating_mul(2);
        for buf in extra_outs.iter_mut() {
            let count = n.min(buf.len());
            buf[..count].fill(0.0);
        }
    }

    /// Send a MIDI event to this device with a frame offset within the upcoming block
    ///
    /// The `frame_offset` is the sample index in the current processing block at which the
    /// event must take effect (0 <= frame_offset < sample_count of the next `process_block`).
    /// Devices should queue these events and apply them when generating audio.
    fn send_midi_event(
        &mut self,
        _note: u8,
        _velocity: u8,
        _is_note_on: bool,
        _frame_offset: usize,
    ) {
        // Default: ignore MIDI (effects don't need it)
    }

    /// Set a parameter value (normalized 0.0-1.0)
    ///
    /// Called between audio blocks, not during processing.
    /// Device maps normalized range to meaningful values.
    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue);

    /// Set a parameter value (normalized 0.0-1.0) taking effect at `frame_offset` samples into
    /// the upcoming block.
    ///
    /// This is the seam for sample-accurate automation: the automation pass always calls this
    /// rather than `set_parameter`, so a device that can stamp its parameter events (CLAP, and
    /// `polysynth`) only has to override this one method. The default ignores the offset and
    /// applies the value between blocks, which is what every device does today.
    fn set_parameter_at(&mut self, param_id: ParamId, value: ParamValue, _frame_offset: usize) {
        self.set_parameter(param_id, value);
    }

    /// Get current parameter value (normalized 0.0-1.0)
    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue>;

    /// Get device metadata
    fn device_id(&self) -> &str; // Unique identifier (e.g., "com.example.oscillator")
    fn device_name(&self) -> &str; // Human-readable name
    fn device_category(&self) -> DeviceCategory;
    fn device_variant(&self) -> DeviceVariant;

    /// Get list of audio ports (for plugin compatibility)
    fn audio_ports(&self) -> Vec<AudioPort> {
        // Default: stereo in/out
        vec![
            AudioPort {
                id: 0,
                name: "Input".to_string(),
                flow: PortFlow::Input,
                channels: 2,
            },
            AudioPort {
                id: 1,
                name: "Output".to_string(),
                flow: PortFlow::Output,
                channels: 2,
            },
        ]
    }

    /// Get list of MIDI ports (future plugin support)
    fn midi_ports(&self) -> Vec<MidiPort> {
        vec![] // Default: no MIDI ports
    }

    /// Get list of parameters
    fn parameters(&self) -> Vec<ParamInfo>;

    /// UI group for a parameter: `"param"` (P tab) or `"cc"` (C tab).
    fn parameter_group(&self, _param_id: ParamId) -> &'static str {
        "param"
    }

    /// Describe file loading capabilities, if any
    fn file_loading_support(&self) -> Option<FileLoadingSupport> {
        None
    }

    /// Reset device to default state (clear buffers, stop voices, etc.)
    fn reset(&mut self);

    /// Get version string (for compatibility checking with LV2/CLAP)
    fn version(&self) -> &str {
        "1.0"
    }

    // === Lifecycle Management ===

    /// Check if device is active (buffers allocated, ready for processing)
    /// Active=false means device is dormant to save RAM/CPU
    fn is_active(&self) -> bool {
        true // Default: always active for built-in devices
    }

    /// Activate device (allocate buffers, prepare for processing)
    /// For plugins: calls CLAP activate(), exposes parameters
    fn activate(&mut self) -> Result<(), String> {
        Ok(()) // Default: no-op for built-in devices
    }

    /// Deactivate device (free buffers, minimal memory footprint)
    /// For plugins: calls CLAP deactivate(), hides parameters
    fn deactivate(&mut self) -> Result<(), String> {
        Ok(()) // Default: no-op for built-in devices
    }

    // === Bypass Control ===

    /// Check if device is enabled (processing audio vs bypassed)
    /// Enabled=false means audio passes through unprocessed
    fn is_enabled(&self) -> bool {
        true // Default: always enabled for built-in devices
    }

    /// Set device enabled state (bypass control)
    /// No buffer reallocation, instant switching
    fn set_enabled(&mut self, _enabled: bool) {
        // Default: no-op for built-in devices
    }

    // === Type Downcasting ===

    /// Get mutable reference to self as `Any` for downcasting
    /// Used to access device-specific methods (e.g. CLAP GUI)
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any;

    // === Sleep/Wake System (CPU optimization) ===

    /// Check if device is currently sleeping (skipping processing to save CPU)
    fn is_sleeping(&self) -> bool {
        false // Default: never sleep (for simple devices)
    }

    /// Mark activity on this device (wakes from sleep)
    /// Called when: MIDI received, parameter changed, non-silent input detected
    fn mark_activity(&mut self) {
        // Default: no-op (device doesn't track sleep state)
    }

    /// Update sleep state based on audio input/output activity
    /// Called before processing with input peak, after processing with output peak
    /// Returns true if sleep state changed (for status events)
    fn update_sleep_state(&mut self, _has_audio_activity: bool) -> bool {
        false // Default: no sleep state changes
    }

    // === Device Data Subscriptions ===

    /// Subscribe to a data stream (e.g., "spectrum", "oscilloscope", "phase")
    /// Returns error if device doesn't support this data type
    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        Err(format!(
            "Device '{}' does not support '{}' data stream",
            self.device_name(),
            data_type
        ))
    }

    /// Unsubscribe from a data stream
    fn unsubscribe_data(&mut self, _data_type: &str) {
        // Default: no-op (device doesn't support subscriptions)
    }

    /// Poll for device data (called periodically from audio thread if subscribed)
    /// Returns (data_type, binary_payload) if data is ready to send
    ///
    /// **CRITICAL**: This must be real-time safe (no allocations in hot path)
    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        None // Default: no data to send
    }

    /// Immutable view of this device as a nested container, if it owns children.
    fn as_container(&self) -> Option<&dyn DeviceContainer> {
        None
    }

    /// Mutable view of this device as a nested container, if it owns children.
    fn as_container_mut(&mut self) -> Option<&mut dyn DeviceContainer> {
        None
    }

    /// True when this device can own child devices (Chain, Layer).
    fn is_container(&self) -> bool {
        false
    }
}
