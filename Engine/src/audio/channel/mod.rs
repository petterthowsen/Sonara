//! The mixer channel: buffers, fader and pan state, send list and device chain.
//!
//! `Channel` is defined here; its behavior is split across child modules, each an `impl Channel`
//! block (pan, metering, the device chain and note processing).

mod chain;
mod meter;
mod pan;
mod send;

pub(crate) use meter::fader_gain;
pub use pan::{PanCoefficients, PanMode};
pub use send::Send;

use crate::audio::active_notes::ActiveNotes;
use crate::audio::devices::AudioDevice;
use crate::audio::midi_types::{create_midi_queue, MidiEvent, MidiEventQueue, MidiRouting};
use crate::audio::render_scratch::MixBuffers;
use crate::audio::types::ChannelId;
use meter::gain_smoothing_alpha;

/// Sleep changes one channel can report in a buffer without growing `Channel::sleep_changes`.
const MAX_SLEEP_CHANGES: usize = 64;

/// Audio channel for mixing
pub struct Channel {
    pub id: ChannelId,
    pub name: String,
    pub volume_db: f32, // dB (-60.0 to +12.0)
    pub pan: f32,       // -1.0 (left) to +1.0 (right) for STEREO_COMBINED/MONO/BALANCE
    /// Normalized 0.0-1.0 automation override for the fader. `None` means the base `volume_db` is
    /// used. Written only by the automation pass on the audio callback; never writes `volume_db`.
    pub automation_volume: Option<f32>,
    /// Normalized 0.0-1.0 automation override for `pan`, with the same ownership as
    /// `automation_volume`. Ignored in `PanMode::StereoDual`, which has two independent controls
    /// and so no single automatable pan target.
    pub automation_pan: Option<f32>,
    pub pan_left: f32,  // For STEREO_DUAL mode
    pub pan_right: f32, // For STEREO_DUAL mode
    /// Spread of the two handles around `pan` in `PanMode::StereoCombined`, -1.0..1.0. Negative
    /// swaps the sides. Not automatable.
    pub pan_width: f32,
    pub pan_mode: PanMode, // Pan mode (combined, dual, balance, mono)
    pub mute: bool,
    pub solo: bool,
    pub output_channel_id: Option<ChannelId>, // None for master/no output

    // Sends (parallel routing to BUS channels)
    pub send_channels: Vec<Send>,

    // Runtime state (stereo)
    pub buffer_left: Vec<f32>,
    pub buffer_right: Vec<f32>,
    pub peak_left: f32,
    pub peak_right: f32,
    pub rms_left: f32,
    pub rms_right: f32,
    // Running mean square behind `rms_left`/`rms_right` (internal)
    mean_square_left: f32,
    mean_square_right: f32,

    // Parameter smoothing (prevents clicks/pops when changing volume)
    current_gain: f32,    // Smoothed gain value (internal)
    smoothing_alpha: f32, // Smoothing coefficient (internal)

    // Device chain for processing (instruments or effects)
    pub devices: Vec<Box<dyn AudioDevice>>,

    /// Notes sounding on this channel (clip and live), each with its sounding-note id. Stop,
    /// pause and seek release the clip notes with note-offs instead of resetting devices, so
    /// releases and tails ring out.
    pub active_notes: ActiveNotes,

    // MIDI routing configuration
    pub midi_routing: MidiRouting,

    // Incoming MIDI event queue (non-audio thread writes, audio thread reads)
    pub midi_queue: MidiEventQueue,

    // Scheduled MIDI events for current audio buffer (sorted by frame_offset)
    pub scheduled_midi_events: Vec<MidiEvent>,

    // Temporary interleaved buffer for device processing
    device_input_buffer: Vec<f32>,
    device_output_buffer: Vec<f32>,

    /// Child channel IDs that receive extra device buses (index = bus). 0 = unmapped.
    pub extra_out_targets: Vec<ChannelId>,
    /// Preallocated interleaved stereo extra-out buses (audio thread must not grow these).
    pub extra_out_buffers: Vec<Vec<f32>>,

    /// `(device_path, is_sleeping)` for devices whose sleep state changed this buffer. Filled by
    /// the device chain, drained by `mix_and_output`. Preallocated: only a buffer where more
    /// than `MAX_SLEEP_CHANGES` devices change at once would grow it.
    pub sleep_changes: Vec<(crate::audio::devices::DevicePath, bool)>,

    /// Scratch buffers and flags used by `mix_and_output`
    pub mix: MixBuffers,
}

impl Channel {
    pub fn new(id: ChannelId, name: String, buffer_size: usize, sample_rate: f32) -> Self {
        let smoothing_alpha = gain_smoothing_alpha(sample_rate);

        let initial_gain = if id == 1 {
            // Master channel defaults to 0 dB
            1.0
        } else {
            // Other channels default to -6 dB for headroom
            10.0_f32.powf(-6.0 / 20.0)
        };

        Self {
            id,
            name,
            volume_db: if id == 1 { 0.0 } else { -6.0 },
            pan: 0.0,
            automation_volume: None,
            automation_pan: None,
            pan_left: 0.0,
            pan_right: 0.0,
            pan_width: 1.0,
            pan_mode: PanMode::default(),
            mute: false,
            solo: false,
            output_channel_id: Some(1), // Default to master (ID 1)
            send_channels: Vec::new(),
            buffer_left: vec![0.0; buffer_size],
            buffer_right: vec![0.0; buffer_size],
            peak_left: 0.0,
            peak_right: 0.0,
            rms_left: 0.0,
            rms_right: 0.0,
            mean_square_left: 0.0,
            mean_square_right: 0.0,
            current_gain: initial_gain,
            smoothing_alpha,
            devices: Vec::new(),
            active_notes: ActiveNotes::new(),
            midi_routing: MidiRouting::default(),
            midi_queue: create_midi_queue(),
            // Preallocated so the audio thread doesn't allocate while scheduling
            scheduled_midi_events: Vec::with_capacity(256),
            device_input_buffer: vec![0.0; buffer_size * 2],
            device_output_buffer: vec![0.0; buffer_size * 2],
            extra_out_targets: Vec::new(),
            extra_out_buffers: Vec::new(),
            sleep_changes: Vec::with_capacity(MAX_SLEEP_CHANGES),
            mix: MixBuffers::new(buffer_size),
        }
    }

    /// Adopt a new device sample rate (the stream is stopped while this runs).
    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.smoothing_alpha = gain_smoothing_alpha(sample_rate);
    }

    /// Clear the channel buffers
    pub fn clear_buffers(&mut self) {
        self.buffer_left.fill(0.0);
        self.buffer_right.fill(0.0);
    }

    /// Map extra device bus `bus_index` to `target_id` (0 clears). Allocates on the command thread.
    pub fn set_aux_out(&mut self, bus_index: usize, target_id: ChannelId) {
        let interleaved = self.buffer_left.len().saturating_mul(2);
        while self.extra_out_targets.len() <= bus_index {
            self.extra_out_targets.push(0);
            self.extra_out_buffers.push(vec![0.0; interleaved]);
        }
        self.extra_out_targets[bus_index] = target_id;
    }

    /// The device list `parent_path` names, when it is a plain chain (the channel root, a
    /// Chain, a slot chain). Note effects only ever sit in these.
    pub fn chain_list_mut(
        &mut self,
        parent_path: &crate::audio::devices::DevicePath,
    ) -> Option<&mut Vec<Box<dyn AudioDevice>>> {
        if parent_path.is_empty() {
            return Some(&mut self.devices);
        }
        crate::audio::devices::container::device_at_path_mut(&mut self.devices, parent_path)?
            .as_container_mut()?
            .chain_children_mut()
    }

    /// Mutable device at `path`, including nested container children.
    pub fn device_at_path_mut(
        &mut self,
        path: &crate::audio::devices::DevicePath,
    ) -> Option<&mut dyn crate::audio::devices::AudioDevice> {
        crate::audio::devices::container::device_at_path_mut(&mut self.devices, path)
    }

    /// Immutable device at `path`, including nested container children.
    pub fn device_at_path(
        &self,
        path: &crate::audio::devices::DevicePath,
    ) -> Option<&dyn crate::audio::devices::AudioDevice> {
        crate::audio::devices::container::device_at_path(&self.devices, path)
    }
}
