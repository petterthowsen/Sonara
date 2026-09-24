//! Plugin state and audio processing
//!
//! Manages the plugin instance state and handles audio processing
//! from shared memory ring buffers.

use std::collections::HashMap;
use std::sync::Arc;
use tracing::{info, warn};

use clack_extensions::params::{ParamInfoBuffer, PluginParams};

use clack_host::events::event_types::{NoteOffEvent, NoteOnEvent, ParamValueEvent};
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
use clack_host::events::{Pckn, UnknownEvent};
use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;

use crate::audio::ipc::{InstanceId, SharedMemory};

use crate::plugin_host::host::{SubprocessHost, SubprocessHostShared};

/// A parameter's CLAP id and range, found by the engine's index for it.
#[derive(Debug, Clone, Copy)]
pub struct ParamEntry {
    pub clap_id: ClapId,
    pub min: f64,
    pub max: f64,
}

impl ParamEntry {
    /// Plugin value to the engine's 0.0-1.0.
    pub fn normalize(&self, value: f64) -> f32 {
        let range = self.max - self.min;
        if range.abs() > f64::EPSILON {
            ((value - self.min) / range).clamp(0.0, 1.0) as f32
        } else {
            0.5
        }
    }

    /// The engine's 0.0-1.0 to a plugin value.
    pub fn denormalize(&self, value: f32) -> f64 {
        self.min + value as f64 * (self.max - self.min)
    }
}

/// Maps between the engine's parameter indices and CLAP ids. Built once from the params
/// extension, and rebuilt after the plugin rescans its parameter list.
#[derive(Debug, Default)]
pub struct ParamMap {
    /// By CLAP parameter index, which is the engine's parameter id. None where the plugin
    /// reported no info for an index.
    entries: Vec<Option<ParamEntry>>,
    index_by_id: HashMap<ClapId, u32>,
}

impl ParamMap {
    pub fn build(instance: &mut PluginInstance<SubprocessHost>) -> Self {
        let mut handle = instance.plugin_handle();
        let Some(params) = handle.get_extension::<PluginParams>() else {
            return Self::default();
        };
        let count = params.count(&mut handle);
        let mut map = Self {
            entries: Vec::with_capacity(count as usize),
            index_by_id: HashMap::with_capacity(count as usize),
        };
        for index in 0..count {
            let mut buffer = ParamInfoBuffer::new();
            let entry = params
                .get_info(&mut handle, index, &mut buffer)
                .map(|info| ParamEntry {
                    clap_id: info.id,
                    min: info.min_value,
                    max: info.max_value,
                });
            if let Some(entry) = entry {
                map.index_by_id.insert(entry.clap_id, index);
            }
            map.entries.push(entry);
        }
        map
    }

    pub fn get(&self, index: u32) -> Option<ParamEntry> {
        self.entries.get(index as usize).copied().flatten()
    }

    /// The engine's index for a CLAP parameter id, with its entry.
    pub fn find(&self, clap_id: ClapId) -> Option<(u32, ParamEntry)> {
        let index = *self.index_by_id.get(&clap_id)?;
        Some((index, self.get(index)?))
    }
}

/// Plugin state container
pub struct PluginState {
    pub instance_id: InstanceId,
    pub bundle: PluginBundle,
    pub instance: PluginInstance<SubprocessHost>,
    pub shared: Arc<SubprocessHostShared>,
    pub gui_open: bool,
    pub activated: bool,
    pub processing: bool,
    pub sample_rate: f32,
    pub max_buffer_size: usize,
    pub audio_processor: Option<PluginAudioProcessorEnum<SubprocessHost>>,
    pub shared_memory: Option<SharedMemory>,

    // Audio processing buffers
    pub input_buffers: Vec<Vec<f32>>,
    pub output_buffers: Vec<Vec<f32>>,

    // Event buffer for plugin output events (parameter changes, etc.)
    pub output_event_buffer: EventBuffer,

    // Parameter changes to report to the engine: (clap_id, plugin value)
    pub pending_param_changes: Vec<(ClapId, f64)>,

    /// None until first needed, and again after the plugin rescans its parameters
    pub param_map: Option<ParamMap>,
}

impl PluginState {
    /// The parameter map, built on first use.
    pub fn param_map(&mut self) -> &ParamMap {
        if self.param_map.is_none() {
            self.param_map = Some(ParamMap::build(&mut self.instance));
        }
        self.param_map.as_ref().expect("built above")
    }
}

/// Process output events from the plugin (parameter changes, etc.)
pub fn process_output_events(state: &mut PluginState) {
    // Iterate through events in the output buffer
    for event in state.output_event_buffer.iter() {
        // Check if this is a parameter value event
        if let Some(param_event) = event.as_event::<ParamValueEvent>() {
            let Some(clap_id) = param_event.param_id() else {
                continue; // Skip events without valid param ID
            };
            let value = param_event.value();

            // Store for sending to main process
            state.pending_param_changes.push((clap_id, value));

            info!(
                "Plugin changed parameter (CLAP ID: {:?}) to {:.4}",
                clap_id, value
            );
        }
    }
}

/// Check if there's audio data available to process
pub fn has_audio_to_process(state: &PluginState) -> bool {
    let Some(ref shm) = state.shared_memory else {
        return false;
    };

    // Process if we have any reasonable amount of data (at least 64 samples = ~1.5ms at 44.1kHz)
    let min_samples = 64 * 2; // Stereo

    let input_buffer = shm.input_buffer();
    let available = input_buffer.available();

    // Process eagerly to avoid buffer overflow
    available >= min_samples
}

/// Process audio from shared memory through the plugin
/// Called periodically from main event loop
pub fn process_audio(state: &mut PluginState) {
    // Only process if we have an active processor and shared memory
    let Some(ref mut processor) = state.audio_processor else {
        return;
    };

    let Some(ref mut shm) = state.shared_memory else {
        return;
    };

    // Only process if in Started state
    let PluginAudioProcessorEnum::Started(ref mut started_processor) = processor else {
        return;
    };

    // Process whatever is available, up to a reasonable chunk size
    let max_chunk_size = 512.min(state.max_buffer_size);

    // Check how much data is available
    let mut input_buffer = shm.input_buffer();
    let available = input_buffer.available();

    if available < 128 {
        // Too little data, skip to avoid overhead
        return;
    }

    // Process up to max_chunk_size samples, but no more than what's available
    let samples_to_process = available.min(max_chunk_size * 2); // Stereo
    let chunk_size = samples_to_process / 2; // Convert back to mono samples

    // Read input audio from shared memory ring buffer (interleaved stereo)
    let mut interleaved_input = vec![0.0f32; samples_to_process];
    let read = input_buffer.read(&mut interleaved_input);
    drop(input_buffer); // Release borrow

    if read < samples_to_process {
        // Fill remainder with silence if we didn't get enough
        interleaved_input[read..].fill(0.0);
    }

    // Deinterleave: convert interleaved (L, R, L, R) to separate channels
    for i in 0..chunk_size {
        state.input_buffers[0][i] = interleaved_input[i * 2]; // Left
        state.input_buffers[1][i] = interleaved_input[i * 2 + 1]; // Right
    }

    // Clear output buffers
    for channel in &mut state.output_buffers {
        channel[..chunk_size].fill(0.0);
    }

    // Build CLAP audio structures (need to store ports in state for proper lifetime)
    // For now, create temporary ports each time (not ideal but works)
    let mut input_ports = AudioPorts::with_capacity(2, 1); // 2 channels, 1 port
    let mut output_ports = AudioPorts::with_capacity(2, 1);

    let input_audio = input_ports.with_input_buffers([AudioPortBuffer {
        latency: 0,
        channels: AudioPortBufferType::f32_input_only(
            state
                .input_buffers
                .iter_mut()
                .map(|b| InputChannel::constant(&mut b[..chunk_size])),
        ),
    }]);

    let mut output_audio = output_ports.with_output_buffers([AudioPortBuffer {
        latency: 0,
        channels: AudioPortBufferType::f32_output_only(
            state
                .output_buffers
                .iter_mut()
                .map(|b| &mut b[..chunk_size]),
        ),
    }]);

    // Read MIDI events from shared memory queue
    let mut midi_queue = shm.midi_queue();
    let mut note_on_events = Vec::new();
    let mut note_off_events = Vec::new();

    // Read all available MIDI events
    while let Some(midi_event) = midi_queue.read() {
        if midi_event.is_note_on == 1 {
            // Note On
            let event = NoteOnEvent::new(
                midi_event.sample_offset,
                Pckn::new(0u16, 0u16, midi_event.note as u16, midi_event.note as u32),
                midi_event.velocity as f64 / 127.0,
            );
            note_on_events.push(event);
            info!(
                "Plugin receiving Note ON: {} vel={} at sample {}",
                midi_event.note, midi_event.velocity, midi_event.sample_offset
            );
        } else {
            // Note Off
            let event = NoteOffEvent::new(
                midi_event.sample_offset,
                Pckn::new(0u16, 0u16, midi_event.note as u16, midi_event.note as u32),
                midi_event.velocity as f64 / 127.0,
            );
            note_off_events.push(event);
            info!(
                "Plugin receiving Note OFF: {} vel={} at sample {}",
                midi_event.note, midi_event.velocity, midi_event.sample_offset
            );
        }
    }
    drop(midi_queue); // Release borrow

    // Create event references (must live as long as InputEvents)
    let event_refs: Vec<&UnknownEvent> = note_on_events
        .iter()
        .map(|e| e.as_unknown())
        .chain(note_off_events.iter().map(|e| e.as_unknown()))
        .collect();

    // Create InputEvents with our MIDI events
    let input_events = if event_refs.is_empty() {
        InputEvents::empty()
    } else {
        InputEvents::from_buffer(&event_refs)
    };

    let mut output_events = OutputEvents::from_buffer(&mut state.output_event_buffer);

    // Process audio through plugin
    match started_processor.process(
        &input_audio,
        &mut output_audio,
        &input_events,
        &mut output_events,
        None,
        None,
    ) {
        Ok(_) => {
            // Interleave output: convert separate channels to interleaved (L, R, L, R)
            let mut interleaved_output = vec![0.0f32; samples_to_process];
            for i in 0..chunk_size {
                interleaved_output[i * 2] = state.output_buffers[0][i]; // Left
                interleaved_output[i * 2 + 1] = state.output_buffers[1][i]; // Right
            }

            // Write output audio to shared memory ring buffer
            let mut output_buffer = shm.output_buffer();
            let written = output_buffer.write(&interleaved_output);

            if written < interleaved_output.len() {
                // Output buffer is full, this might cause audio glitches
                warn!(
                    "Output buffer full: wrote {}/{} samples",
                    written,
                    interleaved_output.len()
                );
            }
        }
        Err(e) => {
            warn!("Plugin processing error: {:?}", e);
        }
    }

    // Process output events to detect parameter changes
    // These are sent back to the main process for UI updates
    process_output_events(state);

    // Clear event buffer for next iteration
    state.output_event_buffer.clear();
}
