mod chain;
pub mod clap_host;
pub mod container;
mod delay;
mod drum_machine;
pub mod effect;
#[cfg(test)]
mod effect_conformance;
mod factory;
mod layer;
pub mod param_table;
mod polysynth;
mod sampler;
mod sfizz_device;
mod spectrum_analyzer;
mod reverb;

pub use chain::ChainDevice;
pub use clap_host::{ClapDeviceAdapter, PluginDescriptor, PluginScanner};
pub use container::{parse_osc_device_addr, DeviceContainer, DevicePath};
pub use delay::DelayDevice;
pub use drum_machine::DrumMachineDevice;
pub use factory::{create_effect, DeviceFactory, EFFECT_IDS};
pub use layer::LayerDevice;
pub use polysynth::PolySynthDevice;
pub use sampler::SamplerDevice;
pub use sfizz_device::SfizzDevice;
pub use spectrum_analyzer::SpectrumAnalyzerDevice;
pub use reverb::ReverbDevice;

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

/// Normalized value of enum choice `index` out of `count` choices (`0.0..=1.0`, evenly spaced).
///
/// Use this pair for every enum parameter so `get_parameter` and `set_parameter` always agree.
pub fn enum_to_norm(index: usize, count: usize) -> ParamValue {
    if count <= 1 {
        return 0.0;
    }
    index.min(count - 1) as f32 / (count - 1) as f32
}

/// Map a normalized `0..=1` value to a real one: `min * (max/min)^n` when `is_logarithmic`
/// (needs `min > 0`), otherwise `min + (max - min) * n^skew`.
pub fn norm_to_real(norm: f32, min: f32, max: f32, is_logarithmic: bool, skew: f32) -> f32 {
    let n = norm.clamp(0.0, 1.0);
    if is_logarithmic && min > 0.0 && max > min {
        min * (max / min).powf(n)
    } else {
        let curved = if skew == 1.0 {
            n
        } else {
            n.powf(skew.max(f32::EPSILON))
        };
        min + (max - min) * curved
    }
}

/// Inverse of [`norm_to_real`]. The result is clamped to `0..=1`.
pub fn real_to_norm(real: f32, min: f32, max: f32, is_logarithmic: bool, skew: f32) -> f32 {
    if max <= min {
        return 0.0;
    }
    if is_logarithmic && min > 0.0 {
        if real <= min {
            return 0.0;
        }
        return ((real / min).ln() / (max / min).ln()).clamp(0.0, 1.0);
    }
    ((real - min) / (max - min))
        .clamp(0.0, 1.0)
        .powf(1.0 / skew.max(f32::EPSILON))
}

/// Enum choice index for a normalized value: the nearest of `count` evenly spaced choices.
pub fn norm_to_enum(norm: ParamValue, count: usize) -> usize {
    if count <= 1 {
        return 0;
    }
    (norm.clamp(0.0, 1.0) * (count - 1) as f32).round() as usize
}
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
    pub is_hidden: bool,
    pub is_read_only: bool,
    pub is_bypass: bool,
    /// CLAP module path, e.g. "Early/Size"; "" if none
    pub module: String,
    /// Real value is `min * (max/min)^n` (Hz-like values). Requires `min > 0`; ignores `skew`.
    pub is_logarithmic: bool,
    /// Power curve for the normalized value: `real = min + (max - min) * n^skew`. 1.0 is linear.
    pub skew: f32,
}

/// A modulation source a device offers (for the UI's source strip).
#[derive(Debug, Clone, PartialEq)]
pub struct ModSourceInfo {
    /// Stable id used over OSC and in saved projects, e.g. `"lfo1"`.
    pub id: String,
    pub name: String,
    /// Runs −1..1 (else 0..1).
    pub bipolar: bool,
}

/// One modulation route: `amount` (−1..1, normalized units per unit of source) from `source`
/// to parameter `param_id`. Routes are device state, not parameters.
#[derive(Debug, Clone, PartialEq)]
pub struct ModRoute {
    pub source: String,
    pub param_id: ParamId,
    pub amount: f32,
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

    /// Audio thread. Start processing a block without waiting for the result. Returns false when
    /// the device can't split a block; the caller then uses `process_block`. `inputs` must stay
    /// unchanged until `finish_block`.
    fn begin_block(&mut self, _inputs: &[f32], _sample_count: usize) -> bool {
        false
    }

    /// Audio thread. Complete a block started by `begin_block`: wait (bounded by the callback
    /// deadline) and write `outputs`. On a miss, write dry input (effect) or silence (instrument).
    fn finish_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}

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
    /// and later `polysynth`) only has to override this one method. The default ignores the offset and
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

    // === Modulation (device-internal, per voice) ===

    /// Modulation sources this device offers. Default: none.
    fn mod_sources(&self) -> Vec<ModSourceInfo> {
        Vec::new()
    }

    /// Add, update or (amount 0) remove the route from `source` to `param_id`. Called on the
    /// command thread under the state lock, so it must be cheap and must not allocate on the
    /// success path. Default: the device has no modulation.
    fn set_mod_route(
        &mut self,
        source: &str,
        _param_id: ParamId,
        _amount: f32,
    ) -> Result<(), String> {
        Err(format!(
            "Device '{}' has no modulation source '{}'",
            self.device_name(),
            source
        ))
    }

    /// Remove every modulation route. Default: nothing to clear.
    fn clear_mod_routes(&mut self) {}

    /// The current routes (for state/get and tests). Default: none.
    fn mod_routes(&self) -> Vec<ModRoute> {
        Vec::new()
    }

    /// UI group for a parameter: `"param"` (P tab) or `"cc"` (C tab).
    fn parameter_group(&self, _param_id: ParamId) -> &'static str {
        "param"
    }

    /// True when the parameter list comes from loaded content (an SFZ file, a CLAP plugin)
    /// instead of being fixed, so Godot learns it from `param/info` rather than its registry.
    fn has_dynamic_parameters(&self) -> bool {
        false
    }

    /// Describe file loading capabilities, if any
    fn file_loading_support(&self) -> Option<FileLoadingSupport> {
        None
    }

    /// Current `{device}/loading_state` value (`loading`, `ready`, `failed:{error}`, ...), or None
    /// for a device without a load lifecycle. Lets Godot recover a transition it missed
    /// (`{device}/state/get`). Called on the command thread, so it must be cheap.
    fn loading_state(&self) -> Option<String> {
        None
    }

    /// Reset device to default state (clear buffers, stop voices, etc.)
    fn reset(&mut self);

    /// Transport state at the start of the coming block, pushed every callback whether the
    /// transport is playing or stopped. Real-time: keep it to a copy. Default: ignore.
    fn set_transport(&mut self, _transport: &super::transport::Transport) {}

    /// Get version string (for compatibility checking with LV2/CLAP)
    fn version(&self) -> &str {
        "1.0"
    }

    /// Latency this device adds, in frames at the device sample rate. Zero for everything that
    /// processes in place; plugin adapters report what the plugin told them (Phase 3).
    fn latency_frames(&self) -> u32 {
        0
    }

    /// Adopt a new device sample rate. Runs on the command thread while the output stream is
    /// stopped, so it may allocate. `max_frames` is the largest block `process_block` will get.
    /// Devices whose processing doesn't depend on the rate keep the default no-op; containers
    /// don't forward it, because the command thread visits nested devices itself.
    fn prepare(&mut self, _sample_rate: f32, _max_frames: usize) {}

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

/// Hand the block's transport to every device in `devices`, including nested children.
pub fn apply_transport(
    devices: &mut [Box<dyn AudioDevice>],
    transport: &super::transport::Transport,
) {
    for device in devices {
        apply_transport_to(device.as_mut(), transport);
    }
}

fn apply_transport_to(device: &mut dyn AudioDevice, transport: &super::transport::Transport) {
    device.set_transport(transport);
    if let Some(container) = device.as_container_mut() {
        for i in 0..container.child_count() {
            if let Some(child) = container.child_mut(i) {
                apply_transport_to(child, transport);
            }
        }
    }
}

#[cfg(test)]
mod curve_tests {
    use super::*;

    #[test]
    fn norm_real_round_trips_for_linear_skewed_and_log() {
        let cases = [
            (0.0, 1.0, false, 1.0),
            (0.0005, 10.0, false, 4.0),
            (0.0, 1.0, false, 3.0),
            (20.0, 20_000.0, true, 1.0),
        ];
        for (min, max, log, skew) in cases {
            for n in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let real = norm_to_real(n, min, max, log, skew);
                let back = real_to_norm(real, min, max, log, skew);
                assert!(
                    (back - n).abs() < 1e-4,
                    "{min}..{max} log={log} skew={skew} n={n}: {back}"
                );
            }
            assert_eq!(norm_to_real(0.0, min, max, log, skew), min);
            assert!((norm_to_real(1.0, min, max, log, skew) - max).abs() < max * 1e-5);
        }
    }

    #[test]
    fn skew_four_puts_625ms_at_mid_knob_and_zero_is_exact() {
        assert!((norm_to_real(0.5, 0.0, 10.0, false, 4.0) - 0.625).abs() < 1e-5);
        assert_eq!(norm_to_real(0.0, 0.0, 1.0, false, 3.0), 0.0);
    }

    #[test]
    fn log_ignores_skew() {
        assert_eq!(
            norm_to_real(0.5, 20.0, 20_000.0, true, 4.0),
            norm_to_real(0.5, 20.0, 20_000.0, true, 1.0)
        );
    }

    #[test]
    fn enum_helpers_round_trip() {
        for count in 2..8 {
            for i in 0..count {
                assert_eq!(norm_to_enum(enum_to_norm(i, count), count), i);
            }
        }
    }
}
