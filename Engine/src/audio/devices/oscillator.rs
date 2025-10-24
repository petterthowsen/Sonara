use super::{AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow};

/// Oscillator instrument device
///
/// Generates audio from MIDI note voices using phase accumulator synthesis.
/// Supports multiple waveforms (sine, square, sawtooth, triangle).
///
/// **Note**: This is a monophonic proof-of-concept. Full polyphony would be managed
/// at the channel level with multiple Voice instances.
#[derive(Debug, Clone)]
pub struct OscillatorDevice {
    sample_rate: f32,

    // Waveform selection (0=sine, 1=square, 2=sawtooth, 3=triangle)
    waveform: u8,

    // Master amplitude/volume
    amplitude: f32,

    // Phase accumulator for current voice
    current_phase: f32,
    current_frequency: f32,

    // Track if a note is currently playing
    note_active: bool,
    
    // Lifecycle state
    is_active: bool,
    is_enabled: bool,
}


impl OscillatorDevice {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            waveform: 0,  // Default sine
            amplitude: 0.3,
            current_phase: 0.0,
            current_frequency: 440.0,
            note_active: false,
            is_active: true,
            is_enabled: true,
        }
    }

    /// Generate waveform sample at given phase
    fn generate_waveform(&self, phase: f32) -> f32 {
        // Phase is in [0.0, 1.0) range
        match self.waveform {
            0 => {
                // Sine
                let radians = phase * 2.0 * std::f32::consts::PI;
                radians.sin()
            }
            1 => {
                // Square (with anti-aliasing hint for lower freqs)
                if phase < 0.5 {
                    1.0
                } else {
                    -1.0
                }
            }
            2 => {
                // Sawtooth (ramp 0 to 1 becomes -1 to 1)
                phase * 2.0 - 1.0
            }
            3 => {
                // Triangle
                let t = phase * 4.0;
                if t < 1.0 {
                    t
                } else if t < 2.0 {
                    2.0 - t
                } else if t < 3.0 {
                    t - 2.0 - 2.0
                } else {
                    4.0 - t
                }
            }
            _ => 0.0, // Unknown waveform
        }
    }
}


impl AudioDevice for OscillatorDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Handle inactive state (device not loaded)
        if !self.is_active {
            // Output silence
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }
        
        // Handle disabled state (bypassed - pass through silence for instruments)
        if !self.is_enabled {
            // Instruments output silence when bypassed (no input to pass through)
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }
        
        // Only generate audio if a note is active
        if !self.note_active {
            // Fill output buffer with silence
            for sample in outputs.iter_mut() {
                *sample = 0.0;
            }
            return;
        }

        // Iterate through stereo samples (interleaved: L, R, L, R, ...)
        for i in (0..sample_count * 2).step_by(2) {
            // Generate sample
            let sample = self.amplitude * self.generate_waveform(self.current_phase);

            // Increment phase
            let phase_increment = self.current_frequency / self.sample_rate;
            self.current_phase += phase_increment;
            if self.current_phase >= 1.0 {
                self.current_phase -= 1.0;
            }

            // Output to both channels
            if i < outputs.len() {
                outputs[i] = sample;      // Left
            }
            if i + 1 < outputs.len() {
                outputs[i + 1] = sample;  // Right
            }
        }
    }

    fn send_midi_event(&mut self, note: u8, _velocity: u8, is_note_on: bool) {
        if is_note_on {
            // Note On: set frequency and mark as active
            self.current_frequency = 440.0 * 2.0_f32.powf((note as f32 - 69.0) / 12.0);
            self.note_active = true;
        } else {
            // Note Off: stop generating audio
            self.note_active = false;
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        match param_id {
            0 => {
                // Waveform (0-1.0 mapped to 0-3)
                self.waveform = ((value * 3.99) as u8).min(3);
            }
            1 => {
                // Amplitude (0-1.0 directly)
                self.amplitude = value.clamp(0.0, 1.0);
            }
            _ => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        match param_id {
            0 => Some((self.waveform as f32) / 4.0),
            1 => Some(self.amplitude),
            _ => None,
        }
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.oscillator"
    }

    fn device_name(&self) -> &str {
        "Oscillator"
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
                name: "Amplitude".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.3,
                is_automation_safe: true,
            },
        ]
    }

    fn reset(&mut self) {
        self.current_phase = 0.0;
        self.current_frequency = 440.0;
        self.note_active = false;
    }
    
    // === Lifecycle Management ===
    
    fn is_active(&self) -> bool {
        self.is_active
    }
    
    fn activate(&mut self) -> Result<(), String> {
        self.is_active = true;
        Ok(())
    }
    
    fn deactivate(&mut self) -> Result<(), String> {
        self.is_active = false;
        // Clear state when deactivating
        self.reset();
        Ok(())
    }
    
    // === Bypass Control ===
    
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
