use super::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamType, ParamValue,
};
use tracing::info;

/// Delay effect device
///
/// Simple delay with time (ms) and wet/dry mix.
/// Uses a fixed pre-allocated ring buffer for real-time safety.
#[derive(Debug, Clone)]
pub struct DelayDevice {
    sample_rate: f32,
    max_delay_ms: f32,

    // Ring buffer for delay (stereo, interleaved)
    buffer: Vec<f32>,
    write_pos: usize,

    // Parameters
    delay_ms: f32,
    wet_amount: f32, // 0.0 = dry only, 1.0 = 100% wet
    feedback: f32,   // 0.0-0.99

    // Lifecycle state
    is_active: bool,
    is_enabled: bool,
}

impl DelayDevice {
    /// Create delay with maximum delay time (in ms)
    pub fn new(sample_rate: f32, max_delay_ms: f32) -> Self {
        // Calculate buffer size for stereo (L, R interleaved)
        let samples_per_frame = ((max_delay_ms / 1000.0) * sample_rate).ceil() as usize;
        let buffer_size = samples_per_frame * 2; // Stereo

        Self {
            sample_rate,
            max_delay_ms,
            buffer: vec![0.0; buffer_size],
            write_pos: 0,
            delay_ms: 250.0,
            wet_amount: 0.5,
            feedback: 0.6,
            is_active: true,
            is_enabled: true,
        }
    }

    pub fn set_delay_ms(&mut self, ms: f32) {
        // Ensure delay_samples stays less than buffer_size/4 to prevent read_pos catching write_pos
        // Max safe delay = (buffer_size / 8) frames (since buffer_size is for stereo pairs)
        // This keeps the delay at 1/4 of the total buffer duration
        let max_delay_frames = (self.buffer.len() / 8).saturating_sub(1);
        let max_ms = (max_delay_frames as f32 / self.sample_rate) * 1000.0;
        self.delay_ms = ms.clamp(0.1, max_ms);
    }

    pub fn set_wet_amount(&mut self, wet: f32) {
        self.wet_amount = wet.clamp(0.0, 1.0);
    }

    pub fn set_feedback(&mut self, feedback: f32) {
        self.feedback = feedback.clamp(0.0, 0.99);
    }
}

impl AudioDevice for DelayDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Handle inactive state (device not loaded - pass through to save RAM)
        if !self.is_active {
            // Pass audio through unprocessed (effects are transparent when not loaded)
            let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }

        // Handle disabled state (bypassed - pass through)
        if !self.is_enabled {
            // Pass audio through unprocessed
            let copy_len = (sample_count * 2).min(inputs.len()).min(outputs.len());
            outputs[..copy_len].copy_from_slice(&inputs[..copy_len]);
            return;
        }

        let buffer_size = self.buffer.len();
        // Convert delay time to buffer positions (samples per channel * 2 for stereo interleaved)
        let delay_frames = ((self.delay_ms / 1000.0) * self.sample_rate).ceil() as usize;
        // CRITICAL: delay_samples must be < buffer_size/4 to prevent read_pos from catching write_pos
        let delay_samples = (delay_frames * 2).min(buffer_size / 4 - 2).max(2);

        // Debug logging on first frame only
        static mut FIRST_FRAME: bool = true;
        unsafe {
            if FIRST_FRAME {
                info!("DelayDevice::process_block - buffer_size={} delay_ms={} delay_frames={} delay_samples={} sample_rate={}",
                    buffer_size, self.delay_ms, delay_frames, delay_samples, self.sample_rate);
                FIRST_FRAME = false;
            }
        }

        for i in (0..sample_count * 2).step_by(2) {
            if i + 1 >= inputs.len() || i + 1 >= outputs.len() {
                break;
            }

            let left_in = inputs[i];
            let right_in = inputs[i + 1];

            // Calculate read position (delay_samples ago)
            let read_pos = if self.write_pos >= delay_samples {
                self.write_pos - delay_samples
            } else {
                buffer_size - (delay_samples - self.write_pos)
            };

            // Read delayed samples
            let left_delayed = self.buffer.get(read_pos).copied().unwrap_or(0.0);
            let right_delayed = self.buffer.get(read_pos + 1).copied().unwrap_or(0.0);

            // Debug first non-zero input
            static mut DEBUG_LOGGED: bool = false;
            unsafe {
                if !DEBUG_LOGGED && (left_in.abs() > 0.001 || right_in.abs() > 0.001) {
                    info!("DelayDevice: First audio input - left_in={:.6} right_in={:.6} left_delayed={:.6} right_delayed={:.6} write_pos={} read_pos={}",
                        left_in, right_in, left_delayed, right_delayed, self.write_pos, read_pos);
                    DEBUG_LOGGED = true;
                }
            }

            // Mix input with delayed signal
            let left_out = left_in * (1.0 - self.wet_amount) + left_delayed * self.wet_amount;
            let right_out = right_in * (1.0 - self.wet_amount) + right_delayed * self.wet_amount;

            // Write input + feedback to buffer (not just read position, write from write_pos directly!)
            if self.write_pos < buffer_size {
                self.buffer[self.write_pos] = left_in + left_delayed * self.feedback;
            }
            if self.write_pos + 1 < buffer_size {
                self.buffer[self.write_pos + 1] = right_in + right_delayed * self.feedback;
            }

            // Output
            outputs[i] = left_out;
            outputs[i + 1] = right_out;

            // Advance write position
            self.write_pos = (self.write_pos + 2) % buffer_size;
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        match param_id {
            0 => {
                // Delay time: logarithmic scaling from 1-1250ms
                // Matches DeviceParameter.gd's normalized_to_value: min * pow(max/min, value)
                let ms = 1.0_f32 * (1250.0_f32 / 1.0_f32).powf(value);
                self.set_delay_ms(ms);
            }
            1 => {
                // Wet amount: 0-1 directly (linear)
                self.set_wet_amount(value);
            }
            2 => {
                // Feedback: 0-0.99 directly (linear)
                self.set_feedback(value);
            }
            _ => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        match param_id {
            0 => {
                // Inverse logarithmic: log(value/min) / log(max/min)
                // Matches DeviceParameter.gd's value_to_normalized
                let normalized = (self.delay_ms / 1.0_f32).ln() / (1250.0_f32 / 1.0_f32).ln();
                Some(normalized.clamp(0.0, 1.0))
            }
            1 => Some(self.wet_amount),
            2 => Some(self.feedback),
            _ => None,
        }
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.delay"
    }

    fn device_name(&self) -> &str {
        "Delay"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Effect
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        vec![
            ParamInfo {
                id: 0,
                name: "Delay Time".to_string(),
                unit: "ms".to_string(),
                min: 1.0,
                max: 5000.0,
                default: 250.0,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 1,
                name: "Wet Amount".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.5,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: 2,
                name: "Feedback".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 0.99,
                default: 0.6,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
        ]
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.write_pos = 0;
    }

    /// Resize the ring for the same maximum delay time at the new rate (clears the tail).
    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        let frames = ((self.max_delay_ms / 1000.0) * sample_rate).ceil() as usize;
        self.sample_rate = sample_rate;
        self.buffer = vec![0.0; frames * 2];
        self.write_pos = 0;
        self.set_delay_ms(self.delay_ms);
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
        // Clear buffers when deactivating
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prepare_keeps_the_maximum_delay_time_at_the_new_rate() {
        let mut delay = DelayDevice::new(48_000.0, 1000.0);
        delay.set_delay_ms(200.0);
        assert_eq!(delay.buffer.len(), 96_000);

        delay.prepare(96_000.0, 1024);
        assert_eq!(
            delay.buffer.len(),
            192_000,
            "one second of stereo at 96 kHz"
        );
        assert_eq!(delay.sample_rate, 96_000.0);
        assert!((delay.delay_ms - 200.0).abs() < 1e-3);
        assert!(delay.buffer.iter().all(|&s| s == 0.0));
    }
}
