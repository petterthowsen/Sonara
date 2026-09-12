//! Note-routed parallel container: each child is assigned a MIDI note.

use super::container::{
    copy_interleaved, insert_into_vec, move_in_vec, remove_from_vec, DeviceContainer,
};
use super::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};

/// Default first pad note (C1).
const FIRST_PAD_NOTE: u8 = 36;

/// One drum-machine child plus the MIDI note that triggers it.
pub struct DrumSlot {
    /// Nested device mixed in parallel with sibling pads.
    pub device: Box<dyn AudioDevice>,
    /// MIDI note that routes to this child. Unique within the drum machine.
    pub note: u8,
}

impl DrumSlot {
    /// Wrap `device` and assign `note`.
    pub fn new(device: Box<dyn AudioDevice>, note: u8) -> Self {
        Self { device, note }
    }
}

/// Built-in Drum Machine: Layer-like mix with per-child MIDI note routing.
pub struct DrumMachineDevice {
    slots: Vec<DrumSlot>,
    enabled: bool,
    mix_buffer: Vec<f32>,
    child_buffer: Vec<f32>,
}

impl DrumMachineDevice {
    /// Create an empty drum machine whose mix buffers hold `max_buffer_size` stereo frames.
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
    pub fn slot(&self, index: usize) -> Option<&DrumSlot> {
        self.slots.get(index)
    }

    /// Assign `note` to `index` if no other slot already uses it.
    pub fn set_slot_note(&mut self, index: usize, note: u8) -> bool {
        if self
            .slots
            .iter()
            .enumerate()
            .any(|(i, s)| i != index && s.note == note)
        {
            return false;
        }
        if let Some(slot) = self.slots.get_mut(index) {
            slot.note = note;
            true
        } else {
            false
        }
    }

    /// Next unused MIDI note, searching upward from C1 then wrapping.
    fn next_free_note(&self) -> u8 {
        let is_free = |n: u8| self.slots.iter().all(|s| s.note != n);
        for n in FIRST_PAD_NOTE..=127 {
            if is_free(n) {
                return n;
            }
        }
        for n in 0..FIRST_PAD_NOTE {
            if is_free(n) {
                return n;
            }
        }
        FIRST_PAD_NOTE
    }
}

impl DeviceContainer for DrumMachineDevice {
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
        let note = self.next_free_note();
        insert_into_vec(&mut self.slots, index, DrumSlot::new(device, note));
    }

    fn remove_child(&mut self, index: usize) -> Option<Box<dyn AudioDevice>> {
        remove_from_vec(&mut self.slots, index).map(|s| s.device)
    }

    fn move_child(&mut self, from: usize, to: usize) {
        move_in_vec(&mut self.slots, from, to);
    }
}

impl AudioDevice for DrumMachineDevice {
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
        for slot in &mut self.slots {
            slot.device
                .process_block(inputs, &mut self.child_buffer, sample_count);
            for i in 0..interleaved {
                self.mix_buffer[i] += self.child_buffer[i];
            }
        }
        outputs[..interleaved].copy_from_slice(&self.mix_buffer[..interleaved]);
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        if let Some(slot) = self.slots.iter_mut().find(|s| s.note == note) {
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
        "sonara.builtin.drum_machine"
    }

    fn device_name(&self) -> &str {
        "Drum Machine"
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

    struct NoteCapture {
        hits: Vec<u8>,
    }

    impl NoteCapture {
        fn new() -> Self {
            Self { hits: Vec::new() }
        }
    }

    impl AudioDevice for NoteCapture {
        fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            let count = (sample_count * 2).min(outputs.len());
            outputs[..count].fill(0.1);
        }

        fn send_midi_event(&mut self, note: u8, _v: u8, is_on: bool, _f: usize) {
            if is_on {
                self.hits.push(note);
            }
        }

        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}

        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }

        fn device_id(&self) -> &str {
            "test.capture"
        }

        fn device_name(&self) -> &str {
            "Capture"
        }

        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Instrument
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
    fn routes_midi_to_matching_child_only() {
        let mut dm = DrumMachineDevice::new(8);
        dm.insert_child(0, Box::new(NoteCapture::new()));
        dm.insert_child(1, Box::new(NoteCapture::new()));
        assert!(dm.set_slot_note(0, 36));
        assert!(dm.set_slot_note(1, 38));
        dm.send_midi_event(38, 100, true, 0);
        let child = dm
            .child_mut(1)
            .unwrap()
            .as_any_mut()
            .downcast_mut::<NoteCapture>()
            .unwrap();
        assert_eq!(child.hits, vec![38]);
        let child0 = dm
            .child_mut(0)
            .unwrap()
            .as_any_mut()
            .downcast_mut::<NoteCapture>()
            .unwrap();
        assert!(child0.hits.is_empty());
    }

    #[test]
    fn rejects_duplicate_notes() {
        let mut dm = DrumMachineDevice::new(8);
        dm.insert_child(0, Box::new(NoteCapture::new()));
        dm.insert_child(1, Box::new(NoteCapture::new()));
        assert!(dm.set_slot_note(0, 40));
        assert!(!dm.set_slot_note(1, 40));
    }

    #[test]
    fn empty_is_silence() {
        let mut dm = DrumMachineDevice::new(8);
        let inputs = vec![1.0f32; 4];
        let mut outputs = vec![9.0f32; 4];
        dm.process_block(&inputs, &mut outputs, 2);
        assert_eq!(outputs[0], 0.0);
    }
}
