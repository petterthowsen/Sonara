//! The `AudioDevice` trait and the types devices describe themselves with.

use crate::audio::midi_types::NoteEvent;

use super::containers::DeviceContainer;
use super::note_fx;
use super::params::{ParamId, ParamInfo, ParamValue};

/// Off-lock work requested by [`AudioDevice::configure_data`]: the command thread runs it with
/// the state lock released and passes its product to [`AudioDevice::apply_data_build`].
pub type DataBuild = Box<dyn FnOnce() -> Box<dyn std::any::Any + Send> + Send>;

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
    /// Takes notes in and sends notes on; audio passes through untouched (spec 027).
    NoteEffect,
}

impl DeviceCategory {
    /// The category string sent to Godot (`/builtin/info`, `/plugin/info`).
    pub fn as_str(&self) -> &'static str {
        match self {
            DeviceCategory::Instrument => "instrument",
            DeviceCategory::Effect => "effect",
            DeviceCategory::Utility => "utility",
            DeviceCategory::NoteEffect => "note_effect",
        }
    }
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
/// A modulator a fresh device instance starts with: its kind, display name, normalized
/// parameters (by the kind's parameter IDs) and its routes (`target string`, amount). Devices
/// advertise these through `/builtin/info`, so Godot seeds a new instance's modulators from
/// them. A device without a default patch returns an empty list.
#[derive(Debug, Clone, PartialEq)]
pub struct DefaultModulator {
    pub kind: crate::audio::modulation::ModulatorKind,
    pub name: String,
    pub params: Vec<(ParamId, f32)>,
    pub routes: Vec<(String, f32)>,
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

    /// A note event taking effect `frame_offset` samples into the coming block
    /// (0 <= frame_offset < sample_count of the next `process_block`). Devices queue it and
    /// apply it while generating audio.
    ///
    /// Velocity and release are normalized 0–1. Containers forward the event with the same
    /// `note_id` (only `key` may change). Devices that don't handle expressions drop them, and
    /// effects ignore notes altogether (the default).
    fn send_note_event(&mut self, _event: &NoteEvent, _frame_offset: usize) {}

    /// A MIDI controller value taking effect `frame_offset` samples into the coming block.
    /// `value14` is the full 14-bit value (0–16383); a device that only understands 7 bits
    /// takes the MSB with [`cc14_msb`](crate::audio::midi_types::cc14_msb). Default: ignored.
    fn send_cc(&mut self, _cc: u8, _value14: u16, _frame_offset: usize) {}

    /// The current 14-bit value of controller `cc` this device would report, or `None` when
    /// it has none. Read on the audio thread when an automation lane takes over a controller
    /// (its base value), so it must be cheap — a busy lock returns `None`.
    fn cc_value(&self, _cc: u8) -> Option<u16> {
        None
    }

    // === Note effects (spec 027) ===

    /// True for a note effect: notes routed through a chain stop here, and the chain's note
    /// phase hands what [`process_notes`](Self::process_notes) returns to the devices after it.
    fn is_note_effect(&self) -> bool {
        false
    }

    /// Audio thread, once per block before the chain renders: consume the queued input notes
    /// and return this block's output notes, sorted by frame offset.
    fn process_notes(&mut self, _sample_count: usize) -> &[note_fx::TimedNote] {
        &[]
    }

    /// Command thread, before a structural edit (remove, move): note-offs at frame 0 for
    /// everything this effect has sounding downstream. The schedule is dropped.
    fn release_notes_now(&mut self) -> &[note_fx::TimedNote] {
        &[]
    }

    /// Transport stopped, paused or seeked: drop the clip-origin schedule and release
    /// clip-origin outputs at the next `process_notes`. Live notes keep playing.
    fn note_discontinuity(&mut self) {}

    /// Fade out any sounding voice over ~3 ms starting `frame_offset` samples into the coming
    /// block (Drum Machine choke groups). Default: no-op.
    ///
    /// The offset keeps the choke sample-accurate; the Drum Machine calls it with the same
    /// `frame_offset` as the triggering note.
    fn choke(&mut self, _frame_offset: usize) {}

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

    /// Add a normalized modulation offset to `param_id`. The effective value is
    /// `clamp(base + offset, 0, 1)`; the base is never written (ADR-0014). Called on the audio
    /// thread for every control step while a route is active, and with 0 when the last route to
    /// the parameter goes away. Default: the device is not modulatable.
    fn set_param_mod(&mut self, _param_id: ParamId, _offset: f32) {}

    /// Sample-accurate modulation offset: like [`set_param_mod`](Self::set_param_mod), but the
    /// offset takes effect at `frame_offset` samples into the upcoming block. Devices that stamp
    /// events into the block (CLAP plugins) override this; the default ignores the offset and
    /// goes through `set_param_mod`. The base value is never written (ADR-0014).
    fn set_param_mod_at(&mut self, param_id: ParamId, offset: f32, _frame_offset: usize) {
        self.set_param_mod(param_id, offset);
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

    /// True when this device accepts note input. The allocation-free companion to
    /// `midi_ports()` used on the audio thread: a note wakes the device only when this is
    /// true, or when it carries a note-driven modulator. Devices that report MIDI ports must
    /// override this with `true`.
    fn accepts_note_input(&self) -> bool {
        false
    }

    /// True when `begin_block` can park (the device processes asynchronously, e.g. a
    /// subprocess plugin). The modulation wrapper won't split this device's block when it is
    /// true, so batch processing and frame-stamped parameter events stay intact.
    fn has_async_blocks(&self) -> bool {
        false
    }

    /// Get list of parameters
    fn parameters(&self) -> Vec<ParamInfo>;

    // === Modulation (device-internal, per voice) ===

    /// True when this device evaluates its own modulators per voice (PolySynth, spec 018
    /// Phase 6). The `ModulatedDevice` wrapper then hands it the modulator definitions and
    /// skips those routes on the mono path. Default: modulation is mono only.
    fn supports_voice_modulation(&self) -> bool {
        false
    }

    /// Hand over the modulator definitions and the routes that target this device's own
    /// parameters. Called on the command thread whenever a modulator or route changes, so it
    /// must be cheap. Default: the device is not voice-modulated.
    fn set_voice_modulation(&mut self, _spec: &crate::audio::modulation::VoiceModSpec) {}

    /// Fill `values` with the current effective (modulated) normalized value of `param_id`,
    /// one entry per sounding voice, the newest voice last, and return how many were written.
    /// Only devices that evaluate their own modulators per voice
    /// ([`Self::supports_voice_modulation`]) report values; the `ModulatedDevice` wrapper asks
    /// at the `modulation` data stream's rate, on the audio thread, so this must not allocate.
    /// Default: no values.
    fn live_voice_mod_values(&self, _param_id: ParamId, _values: &mut [f32]) -> usize {
        0
    }

    /// A mono-only modulator's (the `cc` kind) offset onto the parameter of another
    /// modulator (spec 033): the source has no per-voice state, so an enclosing
    /// [`ModulatedDevice`](crate::audio::modulation::ModulatedDevice) hands the summed offset
    /// in here once per control step and a voice-modulating device adds it to every voice's
    /// evaluation of that parameter. `mod_slot` indexes the device's modulator slots.
    /// Default: no-op (like `set_param_mod`).
    fn set_voice_mod_param_offset(&mut self, _mod_slot: usize, _param_id: ParamId, _offset: f32) {}

    /// Modulators a fresh instance starts with (the device's default patch, advertised in
    /// `/builtin/info`). Default: none.
    fn default_modulators(&self) -> Vec<DefaultModulator> {
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
    fn set_transport(&mut self, _transport: &crate::audio::transport::Transport) {}

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

    /// Mutable view of this device as a modulation wrapper, if it is one. The wrapper's
    /// `as_any_mut` deliberately returns the inner device's, so this is the seam the command
    /// thread and the automation path use to reach a device's modulators.
    fn as_modulated_mut(&mut self) -> Option<&mut dyn crate::audio::modulation::Modulated> {
        None
    }

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

    /// Set an option of a data stream (e.g. the EQ analyser's `"resolution"`), from the
    /// `/data/configure` OSC message. Runs on the command thread under the state lock, so it must
    /// be quick: an option that needs new buffers returns a [`DataBuild`] instead of allocating
    /// them here. Returns an error for an unknown stream, key or value.
    fn configure_data(
        &mut self,
        data_type: &str,
        key: &str,
        _value: f32,
    ) -> Result<Option<DataBuild>, String> {
        Err(format!(
            "Device '{}' has no option '{}' for '{}' data",
            self.device_name(),
            key,
            data_type
        ))
    }

    /// Install what a [`DataBuild`] from `configure_data` produced (under the state lock).
    /// Returns what it replaced (or `built` itself if it doesn't fit), which the caller drops
    /// after releasing the lock.
    fn apply_data_build(
        &mut self,
        built: Box<dyn std::any::Any + Send>,
    ) -> Option<Box<dyn std::any::Any + Send>> {
        Some(built)
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
    transport: &crate::audio::transport::Transport,
) {
    for device in devices {
        apply_transport_to(device.as_mut(), transport);
    }
}

fn apply_transport_to(
    device: &mut dyn AudioDevice,
    transport: &crate::audio::transport::Transport,
) {
    device.set_transport(transport);
    if let Some(container) = device.as_container_mut() {
        for i in 0..container.child_count() {
            if let Some(child) = container.child_mut(i) {
                apply_transport_to(child, transport);
            }
        }
    }
}
