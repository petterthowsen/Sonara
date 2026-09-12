//! Serial device container: children process in order, then a single volume is applied.

use super::container::{
    apply_gain, copy_interleaved, gain_to_normalized, insert_into_vec, move_in_vec,
    normalized_to_gain, process_serial_chain, remove_from_vec, DeviceContainer,
};
use super::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamType,
    ParamValue, PortFlow,
};

/// Built-in Chain: sequential child processing plus a post-chain volume.
pub struct ChainDevice {
    children: Vec<Box<dyn AudioDevice>>,
    /// Linear gain in `[0, 2]` (1.0 = unity).
    volume: f32,
    enabled: bool,
    buf_a: Vec<f32>,
    buf_b: Vec<f32>,
}

impl ChainDevice {
    /// Create an empty chain whose ping-pong buffers hold `max_buffer_size` stereo frames.
    pub fn new(max_buffer_size: usize) -> Self {
        let interleaved = max_buffer_size.saturating_mul(2);
        Self {
            children: Vec::new(),
            volume: 1.0,
            enabled: true,
            buf_a: vec![0.0; interleaved],
            buf_b: vec![0.0; interleaved],
        }
    }

    /// Linear gain applied after the child chain (1.0 = unity).
    pub fn volume(&self) -> f32 {
        self.volume
    }
}

impl DeviceContainer for ChainDevice {
    fn child_count(&self) -> usize {
        self.children.len()
    }

    fn child(&self, index: usize) -> Option<&dyn AudioDevice> {
        self.children.get(index).map(|d| d.as_ref())
    }

    fn child_mut(&mut self, index: usize) -> Option<&mut dyn AudioDevice> {
        self.children.get_mut(index).map(|d| d.as_mut() as _)
    }

    fn insert_child(&mut self, index: usize, device: Box<dyn AudioDevice>) {
        insert_into_vec(&mut self.children, index, device);
    }

    fn remove_child(&mut self, index: usize) -> Option<Box<dyn AudioDevice>> {
        remove_from_vec(&mut self.children, index)
    }

    fn move_child(&mut self, from: usize, to: usize) {
        move_in_vec(&mut self.children, from, to);
    }
}

impl AudioDevice for ChainDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.enabled {
            copy_interleaved(inputs, outputs, sample_count);
            return;
        }

        let interleaved = (sample_count * 2)
            .min(inputs.len())
            .min(outputs.len())
            .min(self.buf_a.len())
            .min(self.buf_b.len());
        if interleaved == 0 {
            return;
        }

        self.buf_a[..interleaved].copy_from_slice(&inputs[..interleaved]);
        let (result_in_b, _) = process_serial_chain(
            &mut self.children,
            &mut self.buf_a,
            &mut self.buf_b,
            sample_count,
            true,
        );
        let src = if result_in_b {
            &mut self.buf_b[..interleaved]
        } else {
            &mut self.buf_a[..interleaved]
        };
        apply_gain(src, sample_count, self.volume);
        outputs[..interleaved].copy_from_slice(src);
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        for child in &mut self.children {
            child.mark_activity();
            child.send_midi_event(note, velocity, is_note_on, frame_offset);
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        if param_id == 0 {
            self.volume = normalized_to_gain(value);
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        if param_id == 0 {
            Some(gain_to_normalized(self.volume))
        } else {
            None
        }
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.chain"
    }

    fn device_name(&self) -> &str {
        "Chain"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Utility
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
        vec![ParamInfo {
            id: 0,
            name: "Volume".to_string(),
            unit: String::new(),
            min: 0.0,
            max: 2.0,
            default: 1.0,
            is_automation_safe: true,
            param_type: ParamType::Float,
            syncable: true,
            enum_values: Vec::new(),
        }]
    }

    fn reset(&mut self) {
        for child in &mut self.children {
            child.reset();
        }
        self.buf_a.fill(0.0);
        self.buf_b.fill(0.0);
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn mark_activity(&mut self) {
        for child in &mut self.children {
            child.mark_activity();
        }
    }

    fn as_container(&self) -> Option<&dyn DeviceContainer> {
        Some(self)
    }

    fn as_container_mut(&mut self) -> Option<&mut dyn DeviceContainer> {
        Some(self)
    }

    fn is_container(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::{DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};

    struct GainDevice {
        gain: f32,
        midi_hits: usize,
    }

    impl GainDevice {
        fn new(gain: f32) -> Self {
            Self { gain, midi_hits: 0 }
        }
    }

    impl AudioDevice for GainDevice {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            let count = (sample_count * 2).min(inputs.len()).min(outputs.len());
            for i in 0..count {
                outputs[i] = inputs[i] * self.gain;
            }
        }

        fn send_midi_event(&mut self, _n: u8, _v: u8, _on: bool, _f: usize) {
            self.midi_hits += 1;
        }

        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}

        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }

        fn device_id(&self) -> &str {
            "test.gain"
        }

        fn device_name(&self) -> &str {
            "Gain"
        }

        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Effect
        }

        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }

        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }

        fn reset(&mut self) {}

        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    #[test]
    fn empty_chain_passes_through_then_applies_volume() {
        let mut chain = ChainDevice::new(16);
        chain.volume = 0.5;
        let inputs = vec![1.0f32; 8];
        let mut outputs = vec![0.0f32; 8];
        chain.process_block(&inputs, &mut outputs, 4);
        for sample in &outputs {
            assert!((sample - 0.5).abs() < 1e-6);
        }
    }

    #[test]
    fn serial_children_then_volume() {
        let mut chain = ChainDevice::new(16);
        chain.insert_child(0, Box::new(GainDevice::new(0.5)));
        chain.insert_child(1, Box::new(GainDevice::new(4.0)));
        chain.volume = 0.5;
        let inputs = vec![1.0f32; 8];
        let mut outputs = vec![0.0f32; 8];
        chain.process_block(&inputs, &mut outputs, 4);
        // 1 * 0.5 * 4 * 0.5 = 1.0
        for sample in &outputs {
            assert!((sample - 1.0).abs() < 1e-6);
        }
    }

    #[test]
    fn bypass_skips_children() {
        let mut chain = ChainDevice::new(16);
        chain.insert_child(0, Box::new(GainDevice::new(0.0)));
        chain.set_enabled(false);
        let inputs = vec![0.75f32; 4];
        let mut outputs = vec![0.0f32; 4];
        chain.process_block(&inputs, &mut outputs, 2);
        assert_eq!(outputs, inputs);
    }

    #[test]
    fn midi_reaches_every_child() {
        let mut chain = ChainDevice::new(8);
        chain.insert_child(0, Box::new(GainDevice::new(1.0)));
        chain.insert_child(1, Box::new(GainDevice::new(1.0)));
        chain.send_midi_event(60, 100, true, 0);
        let hits: Vec<usize> = (0..2)
            .map(|i| {
                chain
                    .child_mut(i)
                    .unwrap()
                    .as_any_mut()
                    .downcast_mut::<GainDevice>()
                    .unwrap()
                    .midi_hits
            })
            .collect();
        assert_eq!(hits, vec![1, 1]);
    }
}
