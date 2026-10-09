//! Note-routed parallel container: each child is assigned a MIDI note.

use super::container::{
    copy_interleaved, insert_into_vec, move_in_vec, remove_from_vec, DeviceContainer,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use crate::audio::midi_types::NoteEvent;

/// Default first pad note (C1).
const FIRST_PAD_NOTE: u8 = 36;

/// One drum-machine child plus the MIDI note that triggers it.
pub struct DrumSlot {
    /// Nested device mixed in parallel with sibling pads.
    pub device: Box<dyn AudioDevice>,
    /// MIDI note that routes to this child. Unique within the drum machine.
    pub note: u8,
    /// Choke targets as a note mask: bit *k* set means a note-on on this slot chokes the slot on
    /// note *k*. Directed (A choking B does not make B choke A) and note-based, so it survives
    /// slot reorders. The slot's own bit is ignored.
    pub choke_targets: u128,
}

impl DrumSlot {
    /// Wrap `device` and assign `note`; the slot starts with no choke targets.
    pub fn new(device: Box<dyn AudioDevice>, note: u8) -> Self {
        Self {
            device,
            note,
            choke_targets: 0,
        }
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

    /// The choke target mask of slot `index`, or `None` if there is no such slot.
    pub fn slot_choke_targets(&self, index: usize) -> Option<u128> {
        self.slots.get(index).map(|s| s.choke_targets)
    }

    /// Set slot `index`'s choke target note mask; returns false if the slot does not exist.
    pub fn set_slot_choke_targets(&mut self, index: usize, mask: u128) -> bool {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.choke_targets = mask;
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

    fn extra_output_bus_count(&self) -> usize {
        self.slots.len()
    }

    fn process_block_with_extra(
        &mut self,
        inputs: &[f32],
        outputs: &mut [f32],
        extra_outs: &mut [Vec<f32>],
        sample_count: usize,
    ) {
        let interleaved = (sample_count * 2)
            .min(inputs.len())
            .min(outputs.len())
            .min(self.child_buffer.len());

        if !self.enabled {
            copy_interleaved(inputs, outputs, sample_count);
            for buf in extra_outs.iter_mut() {
                let n = interleaved.min(buf.len());
                buf[..n].fill(0.0);
            }
            return;
        }

        outputs[..interleaved].fill(0.0);
        for (i, slot) in self.slots.iter_mut().enumerate() {
            slot.device
                .process_block(inputs, &mut self.child_buffer, sample_count);
            if i < extra_outs.len() {
                let n = interleaved.min(extra_outs[i].len());
                extra_outs[i][..n].copy_from_slice(&self.child_buffer[..n]);
            } else {
                for j in 0..interleaved {
                    outputs[j] += self.child_buffer[j];
                }
            }
        }
    }

    fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
        let note = event.key();
        let Some(index) = self.slots.iter().position(|s| s.note == note) else {
            return;
        };
        // A note-on chokes every other slot whose note is in this slot's target mask, at the
        // same offset.
        if matches!(event, NoteEvent::On { .. }) {
            let mask = self.slots[index].choke_targets;
            if mask != 0 {
                for (i, slot) in self.slots.iter_mut().enumerate() {
                    if i != index && mask & (1u128 << slot.note.min(127)) != 0 {
                        slot.device.choke(frame_offset);
                    }
                }
            }
        }
        let slot = &mut self.slots[index];
        slot.device.mark_activity();
        slot.device.send_note_event(event, frame_offset);
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

    fn accepts_note_input(&self) -> bool {
        true
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
        hits: Vec<NoteEvent>,
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

        fn send_note_event(&mut self, event: &NoteEvent, _f: usize) {
            if matches!(event, NoteEvent::On { .. }) {
                self.hits.push(*event);
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
        let hit = NoteEvent::On {
            note_id: 9,
            key: 38,
            velocity: 0.5039,
        };
        dm.send_note_event(&hit, 0);
        let child = dm
            .child_mut(1)
            .unwrap()
            .as_any_mut()
            .downcast_mut::<NoteCapture>()
            .unwrap();
        // Forwarded unchanged, sounding-note id included.
        assert_eq!(child.hits, vec![hit]);
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

    #[test]
    fn extra_outs_write_each_pad_and_silence_main() {
        let mut dm = DrumMachineDevice::new(8);
        dm.insert_child(0, Box::new(NoteCapture::new()));
        dm.insert_child(1, Box::new(NoteCapture::new()));
        let inputs = vec![0.0f32; 4];
        let mut outputs = vec![9.0f32; 4];
        let mut extras = [vec![0.0f32; 4], vec![0.0f32; 4]];
        dm.process_block_with_extra(&inputs, &mut outputs, &mut extras, 2);
        assert_eq!(outputs[0], 0.0);
        assert!((extras[0][0] - 0.1).abs() < 1e-6);
        assert!((extras[1][0] - 0.1).abs() < 1e-6);
    }

    /// A device that records the notes and choke offsets it receives.
    struct ChokeCapture {
        hits: Vec<u8>,
        choked: Vec<usize>,
    }

    impl ChokeCapture {
        fn new() -> Self {
            Self {
                hits: Vec::new(),
                choked: Vec::new(),
            }
        }
    }

    impl AudioDevice for ChokeCapture {
        fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            let count = (sample_count * 2).min(outputs.len());
            outputs[..count].fill(0.1);
        }

        fn send_note_event(&mut self, event: &NoteEvent, _f: usize) {
            if matches!(event, NoteEvent::On { .. }) {
                self.hits.push(event.key());
            }
        }

        fn choke(&mut self, frame_offset: usize) {
            self.choked.push(frame_offset);
        }

        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}

        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }

        fn device_id(&self) -> &str {
            "test.choke_capture"
        }

        fn device_name(&self) -> &str {
            "Choke Capture"
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

    fn capture(dm: &mut DrumMachineDevice, index: usize) -> &ChokeCapture {
        dm.child_mut(index)
            .unwrap()
            .as_any_mut()
            .downcast_mut::<ChokeCapture>()
            .unwrap()
    }

    fn note_on(dm: &mut DrumMachineDevice, key: u8, frame_offset: usize) {
        dm.send_note_event(
            &NoteEvent::On {
                note_id: 1,
                key,
                velocity: 0.8,
            },
            frame_offset,
        );
    }

    fn mask(notes: &[u8]) -> u128 {
        notes.iter().fold(0u128, |m, n| m | (1u128 << n))
    }

    /// Three capture pads on notes 36, 38 and 40.
    fn three_pads() -> DrumMachineDevice {
        let mut dm = DrumMachineDevice::new(8);
        dm.insert_child(0, Box::new(ChokeCapture::new()));
        dm.insert_child(1, Box::new(ChokeCapture::new()));
        dm.insert_child(2, Box::new(ChokeCapture::new()));
        // `insert_child` auto-assigns 36/37/38, so reassign from the top to avoid a temporary clash.
        assert!(dm.set_slot_note(2, 40));
        assert!(dm.set_slot_note(1, 38));
        assert!(dm.set_slot_note(0, 36));
        dm
    }

    #[test]
    fn note_on_chokes_only_targets_at_the_trigger_offset() {
        let mut dm = three_pads();
        assert_eq!(dm.slot_choke_targets(0), Some(0));
        assert!(dm.set_slot_choke_targets(0, mask(&[38])));
        assert!(!dm.set_slot_choke_targets(5, mask(&[38])));

        note_on(&mut dm, 36, 5);

        assert_eq!(capture(&mut dm, 0).hits, vec![36]);
        assert!(capture(&mut dm, 0).choked.is_empty());
        assert!(capture(&mut dm, 1).hits.is_empty());
        assert_eq!(capture(&mut dm, 1).choked, vec![5]);
        assert!(capture(&mut dm, 2).choked.is_empty());
    }

    #[test]
    fn choke_targets_are_directed() {
        let mut dm = three_pads();
        assert!(dm.set_slot_choke_targets(0, mask(&[38])));

        // B (38) does not target A (36), so B's note-on leaves A alone.
        note_on(&mut dm, 38, 2);
        assert!(capture(&mut dm, 0).choked.is_empty());

        // Once B targets A, it chokes it.
        assert!(dm.set_slot_choke_targets(1, mask(&[36])));
        note_on(&mut dm, 38, 4);
        assert_eq!(capture(&mut dm, 0).choked, vec![4]);
    }

    #[test]
    fn own_bit_is_ignored_and_note_off_never_chokes() {
        let mut dm = three_pads();
        assert!(dm.set_slot_choke_targets(0, mask(&[36, 38])));

        note_on(&mut dm, 36, 1);
        assert!(capture(&mut dm, 0).choked.is_empty());
        assert_eq!(capture(&mut dm, 1).choked, vec![1]);

        dm.send_note_event(
            &NoteEvent::Off {
                note_id: 1,
                key: 36,
                release: 0.5,
            },
            7,
        );
        assert_eq!(capture(&mut dm, 1).choked, vec![1]);
    }

    #[test]
    fn choke_masks_survive_slot_reorder() {
        let mut dm = three_pads();
        // Pad on 36 targets the pad on 40.
        assert!(dm.set_slot_choke_targets(0, mask(&[40])));
        // Move the 40 pad to the front: indices change, notes do not.
        dm.move_child(2, 0);
        assert_eq!(dm.slot(0).unwrap().note, 40);
        assert_eq!(dm.slot(1).unwrap().note, 36);

        note_on(&mut dm, 36, 3);
        assert_eq!(capture(&mut dm, 0).choked, vec![3]);
        assert!(capture(&mut dm, 2).choked.is_empty());
    }

    #[test]
    fn choke_reaches_a_sampler_inside_a_pad_chain() {
        use crate::audio::devices::ChainDevice;
        use crate::audio::devices::DevicePath;
        use crate::audio::devices::SamplerDevice;

        // Pads as Godot builds them: a chain per slot holding a Sampler.
        let mut dm = DrumMachineDevice::new(256);
        for i in 0..2 {
            let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
            sampler.set_sample("hat", vec![0.5; 96_000], 1, 48_000);
            let mut chain = ChainDevice::new(256);
            chain.insert_child(0, Box::new(sampler));
            dm.insert_child(i, Box::new(chain));
        }
        assert!(dm.set_slot_note(1, 46));
        assert!(dm.set_slot_note(0, 42));
        assert!(dm.set_slot_choke_targets(0, mask(&[46])));
        let peak = |dm: &mut DrumMachineDevice| {
            let mut out = vec![0.0f32; 512];
            dm.process_block(&[0.0; 512], &mut out, 256);
            out.iter().fold(0.0f32, |m, x| m.max(x.abs()))
        };

        note_on(&mut dm, 46, 0);
        assert!(peak(&mut dm) > 0.1, "open hat sounds");
        note_on(&mut dm, 42, 0);
        for _ in 0..4 {
            peak(&mut dm);
        }
        let mut open = vec![0.0f32; 512];
        dm.child_mut(1)
            .unwrap()
            .process_block(&[0.0; 512], &mut open, 256);
        assert!(
            open.iter().all(|s| *s == 0.0),
            "closed hat choked the open hat"
        );
    }
}
