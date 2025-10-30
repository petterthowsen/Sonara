use super::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use fundsp::hacker32::*;
use std::sync::atomic::{AtomicU8, Ordering};

const MAX_VOICES: usize = 16;
const VOICE_SILENCE_THRESHOLD: f32 = 0.001;

/// Voice state for polyphonic synthesis
struct Voice {
    /// MIDI note number
    midi_note: u8,
    /// Note velocity (0.0-1.0)
    velocity: f32,
    /// Frequency in Hz
    frequency: f32,
    /// Voice active flag
    is_active: bool,
    /// Time when note was triggered (for voice stealing)
    note_on_time: u64,
    /// Trigger signal for ADSR (1.0 = note on, 0.0 = note off)
    trigger: Shared,
    /// FunDSP graph for this voice (stored as AudioUnit for flexibility)
    dsp_graph: Option<Box<dyn AudioUnit>>,
    /// Sample counter for silence detection
    silent_samples: usize,
}

impl Voice {
    fn new() -> Self {
        Self {
            midi_note: 0,
            velocity: 0.0,
            frequency: 440.0,
            is_active: false,
            note_on_time: 0,
            trigger: shared(0.0),
            dsp_graph: None,
            silent_samples: 0,
        }
    }

    /// Build the DSP graph for this voice
    /// Uses Shared vars for smooth parameter changes without rebuilding
    fn build_graph(
        &mut self,
        sample_rate: f32,
        waveform: u8,
        attack_shared: &Shared,
        decay_shared: &Shared,
        sustain_shared: &Shared,
        release_shared: &Shared,
        master_volume_shared: &Shared,
    ) {
        // Use shared vars with follow() smoothing for smooth parameter changes
        // ADSR envelope uses constants at build time (envelope shape per voice stays constant)
        // but volume uses shared var for real-time smooth changes
        let envelope = var(&self.trigger) >> adsr_live(
            attack_shared.value(),
            decay_shared.value(),
            sustain_shared.value(),
            release_shared.value(),
        );
        
        // Master volume with smoothing (10ms response time for smooth changes)
        let volume_smooth = var(master_volume_shared) >> follow(0.01);

        // Create graph based on waveform type
        let graph: Box<dyn AudioUnit> = match waveform {
            0 => {
                let mut g = envelope * sine_hz(self.frequency) * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            1 => {
                let mut g = envelope * square_hz(self.frequency) * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            2 => {
                let mut g = envelope * saw_hz(self.frequency) * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            3 => {
                let mut g = envelope * triangle_hz(self.frequency) * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
            _ => {
                let mut g = envelope * sine_hz(self.frequency) * volume_smooth * dc(self.velocity);
                g.set_sample_rate(sample_rate as f64);
                g.allocate();
                Box::new(g)
            }
        };

        self.dsp_graph = Some(graph);
    }

    /// Trigger note on
    fn note_on(&mut self, note: u8, velocity: u8, time: u64) {
        self.midi_note = note;
        self.velocity = velocity as f32 / 127.0;
        self.frequency = midi_note_to_hz(note);
        self.is_active = true;
        self.note_on_time = time;
        self.trigger.set_value(1.0);
        self.silent_samples = 0;
    }

    /// Trigger note off
    fn note_off(&mut self) {
        self.trigger.set_value(0.0);
        // Don't set is_active = false yet, let the release phase complete
    }

    /// Reset voice to default state
    fn reset(&mut self) {
        self.is_active = false;
        self.trigger.set_value(0.0);
        self.velocity = 0.0;
        self.silent_samples = 0;
        if let Some(ref mut graph) = self.dsp_graph {
            graph.reset();
        }
    }
}

/// Polyphonic synthesizer device powered by FunDSP
///
/// Features:
/// - Polyphonic voice management (up to 16 voices)
/// - Multiple waveforms (sine, square, saw, triangle)
/// - ADSR amplitude envelope
/// - Master volume control
/// - Voice stealing when voices are exhausted
pub struct PolySynthDevice {
    sample_rate: f32,
    voices: Vec<Voice>,
    time_counter: u64,

    // Parameters (using atomics for thread-safe access)
    waveform: AtomicU8,
    attack: Shared,
    decay: Shared,
    sustain: Shared,
    release: Shared,
    master_volume: Shared,

    // Parameter change tracking
    params_dirty: bool,

    // Lifecycle state
    is_active: bool,
    is_enabled: bool,

    // Queued MIDI for frame-accurate scheduling within next block
    queued_midi: Vec<(usize, u8, u8, bool)>,
}

impl PolySynthDevice {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            voices: (0..MAX_VOICES).map(|_| Voice::new()).collect(),
            time_counter: 0,
            waveform: AtomicU8::new(0),
            attack: shared(0.01),
            decay: shared(0.1),
            sustain: shared(0.7),
            release: shared(0.3),
            master_volume: shared(0.3),
            params_dirty: true,
            is_active: true,
            is_enabled: true,
            queued_midi: Vec::with_capacity(128),
        }
    }

    /// Find a free voice, or None if all voices are in use
    fn find_free_voice(&self) -> Option<usize> {
        self.voices.iter().position(|v| !v.is_active)
    }

    /// Find the voice playing a specific MIDI note
    fn find_voice_for_note(&self, note: u8) -> Option<usize> {
        self.voices
            .iter()
            .position(|v| v.is_active && v.midi_note == note && v.trigger.value() > 0.0)
    }

    /// Steal the oldest voice (voice with earliest note_on_time)
    fn steal_voice(&self) -> Option<usize> {
        self.voices
            .iter()
            .enumerate()
            .filter(|(_, v)| v.is_active)
            .min_by_key(|(_, v)| v.note_on_time)
            .map(|(idx, _)| idx)
    }

    /// Rebuild DSP graphs only for waveform changes (topology change)
    /// Smooth parameters (ADSR, volume) use Shared vars and don't need rebuilds
    fn rebuild_graphs_if_needed(&mut self) {
        if !self.params_dirty {
            return;
        }

        let waveform = self.waveform.load(Ordering::Relaxed);

        // Only rebuild voices that are inactive (will get new waveform on next note-on)
        // Active voices keep their current waveform until released
        // This prevents retrigger artifacts during playback
        for voice in self.voices.iter_mut() {
            if !voice.is_active || voice.dsp_graph.is_none() {
                voice.build_graph(
                    self.sample_rate,
                    waveform,
                    &self.attack,
                    &self.decay,
                    &self.sustain,
                    &self.release,
                    &self.master_volume,
                );
            }
        }

        self.params_dirty = false;
    }
}

impl AudioDevice for PolySynthDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Handle inactive state
        if !self.is_active {
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }

        // Handle disabled state (bypassed)
        if !self.is_enabled {
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }

        // Rebuild graphs if parameters changed
        self.rebuild_graphs_if_needed();

        // Clear output buffer
        outputs[..sample_count * 2].fill(0.0);

        // Sort queued MIDI by offset
        let mut events = core::mem::take(&mut self.queued_midi);
        events.sort_unstable_by_key(|e| e.0);
        let mut next_event_idx = 0usize;

        // Render sample-by-sample to honor event offsets
        for i in 0..sample_count {
            // Apply all events scheduled for this sample index
            while next_event_idx < events.len() && events[next_event_idx].0 == i {
                let (_ofs, note, velocity, is_on) = events[next_event_idx];
                next_event_idx += 1;

                if is_on && velocity > 0 {
                    if let Some(idx) = self.find_voice_for_note(note) {
                        self.voices[idx].note_on(note, velocity, self.time_counter);
                        self.voices[idx].build_graph(
                            self.sample_rate,
                            self.waveform.load(Ordering::Relaxed),
                            &self.attack,
                            &self.decay,
                            &self.sustain,
                            &self.release,
                            &self.master_volume,
                        );
                    } else if let Some(idx) = self.find_free_voice().or_else(|| self.steal_voice())
                    {
                        self.voices[idx].note_on(note, velocity, self.time_counter);
                        self.voices[idx].build_graph(
                            self.sample_rate,
                            self.waveform.load(Ordering::Relaxed),
                            &self.attack,
                            &self.decay,
                            &self.sustain,
                            &self.release,
                            &self.master_volume,
                        );
                    }
                } else {
                    if let Some(idx) = self.find_voice_for_note(note) {
                        self.voices[idx].note_off();
                    }
                }
            }

            // Sum all active voices for this sample
            let mut sample_sum = 0.0f32;
            for voice in self.voices.iter_mut() {
                if !voice.is_active {
                    continue;
                }
                if let Some(ref mut graph) = voice.dsp_graph {
                    let s = graph.get_mono();
                    if s.abs() < VOICE_SILENCE_THRESHOLD {
                        voice.silent_samples += 1;
                        if voice.silent_samples > 1000 && voice.trigger.value() <= 0.0 {
                            voice.reset();
                            continue;
                        }
                    } else {
                        voice.silent_samples = 0;
                    }
                    sample_sum += s;
                }
            }

            let idx = i * 2;
            if idx < outputs.len() {
                outputs[idx] += sample_sum;
            }
            if idx + 1 < outputs.len() {
                outputs[idx + 1] += sample_sum;
            }
        }

        // Clear any leftover queued events
        self.queued_midi.clear();

        // Increment time counter for voice stealing priority
        self.time_counter = self.time_counter.wrapping_add(1);
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        // Queue for next block
        self.queued_midi.push((
            std::cmp::min(frame_offset, usize::MAX),
            note,
            velocity,
            is_note_on,
        ));
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        match param_id {
            0 => {
                // Waveform (0-1.0 mapped to 0-3)
                let waveform = std::cmp::min(((value * 3.99) as u8), 3);
                self.waveform.store(waveform, Ordering::Relaxed);
                self.params_dirty = true;
            }
            1 => {
                // Attack (0.001-2.0s) - smooth parameter, no rebuild needed
                // Note: ADSR params only affect new voices (existing voices keep their envelope shape)
                let attack = 0.001 + value * 1.999;
                self.attack.set_value(attack);
            }
            2 => {
                // Decay (0.001-2.0s) - smooth parameter, no rebuild needed
                let decay = 0.001 + value * 1.999;
                self.decay.set_value(decay);
            }
            3 => {
                // Sustain (0.0-1.0) - smooth parameter, no rebuild needed
                self.sustain.set_value(value);
            }
            4 => {
                // Release (0.001-3.0s) - smooth parameter, no rebuild needed
                let release = 0.001 + value * 2.999;
                self.release.set_value(release);
            }
            5 => {
                // Master Volume (0.0-1.0) - smooth parameter with Shared var + follow(), no rebuild needed
                self.master_volume.set_value(value);
            }
            _ => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        match param_id {
            0 => Some((self.waveform.load(Ordering::Relaxed) as f32) / 4.0),
            1 => Some((self.attack.value() - 0.001) / 1.999),
            2 => Some((self.decay.value() - 0.001) / 1.999),
            3 => Some(self.sustain.value()),
            4 => Some((self.release.value() - 0.001) / 2.999),
            5 => Some(self.master_volume.value()),
            _ => None,
        }
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.polysynth"
    }

    fn device_name(&self) -> &str {
        "PolySynth"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Instrument
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn midi_ports(&self) -> Vec<MidiPort> {
        vec![MidiPort {
            id: 0,
            name: "MIDI In".to_string(),
            flow: PortFlow::Input,
        }]
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        vec![
            ParamInfo {
                id: 0,
                name: "Waveform".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.0,
                is_automation_safe: true,
            },
            ParamInfo {
                id: 1,
                name: "Attack".to_string(),
                unit: "s".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.005,
                is_automation_safe: true,
            },
            ParamInfo {
                id: 2,
                name: "Decay".to_string(),
                unit: "s".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.05,
                is_automation_safe: true,
            },
            ParamInfo {
                id: 3,
                name: "Sustain".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.7,
                is_automation_safe: true,
            },
            ParamInfo {
                id: 4,
                name: "Release".to_string(),
                unit: "s".to_string(),
                min: 0.0,
                max: 1.0,
                default: 0.1,
                is_automation_safe: true,
            },
            ParamInfo {
                id: 5,
                name: "Master Volume".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.3,
                is_automation_safe: true,
            },
        ]
    }

    fn reset(&mut self) {
        for voice in self.voices.iter_mut() {
            voice.reset();
        }
        self.time_counter = 0;
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        self.is_active = true;
        self.params_dirty = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.is_active = false;
        self.reset();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// Convert MIDI note number to frequency in Hz
fn midi_note_to_hz(note: u8) -> f32 {
    440.0 * 2.0_f32.powf((note as f32 - 69.0) / 12.0)
}
