//! Parallel device container: children share input, outputs mix with per-slot volume/mute/solo.

use super::container::{
    apply_gain, copy_interleaved, insert_into_vec, move_in_vec, normalized_to_gain, remove_from_vec,
    DeviceContainer,
};
use super::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};

/// One Layer child plus its mix controls.
pub struct LayerSlot {
    /// Nested device processed in parallel with sibling slots.
    pub device: Box<dyn AudioDevice>,
    /// Linear gain in `[0, 2]` (1.0 = unity).
    pub volume: f32,
    /// When true this slot contributes no audio (MIDI is still forwarded).
    pub mute: bool,
    /// When any slot is soloed, only soloed slots contribute audio.
    pub solo: bool,
}

impl LayerSlot {
    /// Create a slot wrapping `device` at unity gain, unmuted and unsoloed.
    pub fn new(device: Box<dyn AudioDevice>) -> Self {
        Self {
            device,
            volume: 1.0,
            mute: false,
            solo: false,
        }
    }
}

/// Built-in Layer: each child renders the same input, then outputs are mixed.
pub struct LayerDevice {
    slots: Vec<LayerSlot>,
    enabled: bool,
    mix_buffer: Vec<f32>,
    child_buffer: Vec<f32>,
}

impl LayerDevice {
    /// Create an empty layer whose mix buffers hold `max_buffer_size` stereo frames.
    pub fn new(max_buffer_size: usize) -> Self {
        let interleaved = max_buffer_size.saturating_mul(2);
        Self {
            slots: Vec::new(),
            enabled: true,
            mix_buffer: vec![0.0; interleaved],
            child_buffer: vec![0.0; interleaved],
        }
    }

    /// Immutable slot at `index`.
    pub fn slot(&self, index: usize) -> Option<&LayerSlot> {
        self.slots.get(index)
    }

    /// Mutable slot at `index`.
    pub fn slot_mut(&mut self, index: usize) -> Option<&mut LayerSlot> {
        self.slots.get_mut(index)
    }

    /// Set a slot's linear gain from a normalized 0–1 value (0.5 = unity).
    pub fn set_slot_volume_normalized(&mut self, index: usize, normalized: f32) -> bool {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.volume = normalized_to_gain(normalized);
            true
        } else {
            false
        }
    }

    /// Mute or unmute a slot.
    pub fn set_slot_mute(&mut self, index: usize, mute: bool) -> bool {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.mute = mute;
            true
        } else {
            false
        }
    }

    /// Solo or unsolo a slot.
    pub fn set_slot_solo(&mut self, index: usize, solo: bool) -> bool {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.solo = solo;
            true
        } else {
            false
        }
    }

    /// True when at least one slot is soloed.
    fn any_solo(&self) -> bool {
        self.slots.iter().any(|s| s.solo)
    }
}

impl DeviceContainer for LayerDevice {
    fn child_count(&self) -> usize {
        self.slots.len()
    }

    fn child(&self, index: usize) -> Option<&dyn AudioDevice> {
        self.slots.get(index).map(|s| s.device.as_ref())
    }

    fn child_mut(&mut self, index: usize) -> Option<&mut dyn AudioDevice> {
        self.slots
            .get_mut(index)
            .map(|s| s.device.as_mut() as &mut dyn AudioDevice)
    }

    fn insert_child(&mut self, index: usize, device: Box<dyn AudioDevice>) {
        insert_into_vec(&mut self.slots, index, LayerSlot::new(device));
    }

    fn remove_child(&mut self, index: usize) -> Option<Box<dyn AudioDevice>> {
        remove_from_vec(&mut self.slots, index).map(|s| s.device)
    }

    fn move_child(&mut self, from: usize, to: usize) {
        move_in_vec(&mut self.slots, from, to);
    }
}

impl AudioDevice for LayerDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let interleaved = (sample_count * 2)
            .min(inputs.len())
            .min(outputs.len())
            .min(self.mix_buffer.len())
            .min(self.child_buffer.len());

        if !self.enabled {
            copy_interleaved(inputs, outputs, sample_count);
            return;
        }

        outputs[..interleaved].fill(0.0);
        if self.slots.is_empty() {
            return;
        }

        self.mix_buffer[..interleaved].fill(0.0);
        let any_solo = self.any_solo();

        for slot in &mut self.slots {
            let audible = !slot.mute && (!any_solo || slot.solo);
            slot.device
                .process_block(inputs, &mut self.child_buffer, sample_count);
            if !audible {
                continue;
            }
            apply_gain(&mut self.child_buffer, sample_count, slot.volume);
            for i in 0..interleaved {
                self.mix_buffer[i] += self.child_buffer[i];
            }
        }

        outputs[..interleaved].copy_from_slice(&self.mix_buffer[..interleaved]);
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        for slot in &mut self.slots {
            slot.device.mark_activity();
            slot.device
                .send_midi_event(note, velocity, is_note_on, frame_offset);
        }
    }

    fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}

    fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
        None
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.layer"
    }

    fn device_name(&self) -> &str {
        "Layer"
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
        Vec::new()
    }

    fn reset(&mut self) {
        for slot in &mut self.slots {
            slot.device.reset();
        }
        self.mix_buffer.fill(0.0);
        self.child_buffer.fill(0.0);
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
        for slot in &mut self.slots {
            slot.device.mark_activity();
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
    }

    impl GainDevice {
        fn new(gain: f32) -> Self {
            Self { gain }
        }
    }

    impl AudioDevice for GainDevice {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            let count = (sample_count * 2).min(inputs.len()).min(outputs.len());
            for i in 0..count {
                outputs[i] = inputs[i] * self.gain;
            }
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

    fn render(layer: &mut LayerDevice, input: f32) -> f32 {
        let inputs = vec![input; 4];
        let mut outputs = vec![0.0f32; 4];
        layer.process_block(&inputs, &mut outputs, 2);
        outputs[0]
    }

    #[test]
    fn empty_layer_is_silence() {
        let mut layer = LayerDevice::new(8);
        assert_eq!(render(&mut layer, 1.0), 0.0);
    }

    #[test]
    fn mixes_parallel_children() {
        let mut layer = LayerDevice::new(8);
        layer.insert_child(0, Box::new(GainDevice::new(0.5)));
        layer.insert_child(1, Box::new(GainDevice::new(0.25)));
        assert!((render(&mut layer, 1.0) - 0.75).abs() < 1e-6);
    }

    #[test]
    fn mute_excludes_slot() {
        let mut layer = LayerDevice::new(8);
        layer.insert_child(0, Box::new(GainDevice::new(1.0)));
        layer.insert_child(1, Box::new(GainDevice::new(1.0)));
        layer.set_slot_mute(0, true);
        assert!((render(&mut layer, 1.0) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn solo_plays_only_soloed_slots() {
        let mut layer = LayerDevice::new(8);
        layer.insert_child(0, Box::new(GainDevice::new(1.0)));
        layer.insert_child(1, Box::new(GainDevice::new(0.5)));
        layer.set_slot_solo(1, true);
        assert!((render(&mut layer, 1.0) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn bypass_passes_input() {
        let mut layer = LayerDevice::new(8);
        layer.insert_child(0, Box::new(GainDevice::new(0.0)));
        layer.set_enabled(false);
        assert!((render(&mut layer, 0.8) - 0.8).abs() < 1e-6);
    }
}
