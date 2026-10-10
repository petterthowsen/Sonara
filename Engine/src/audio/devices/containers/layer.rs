//! Parallel device container: children share input, outputs mix with per-slot volume/mute/solo.

use super::container::{
    apply_gain, copy_interleaved, insert_into_vec, move_in_vec, normalized_to_gain,
    remove_from_vec, DeviceContainer,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use crate::audio::midi_types::{NoteEvent, SoundingNoteId, AUDITION_NOTE_ID};

/// Slot note map entry for an input note the slot ignores (and an empty `held` entry).
pub const NOTE_NONE: u8 = 255;

/// `held` entry for an input note with nothing sounding.
const NOT_HELD: (u8, SoundingNoteId) = (NOTE_NONE, 0);

/// Identity note map: every input note goes to the same output note.
fn full_note_map() -> [u8; 128] {
    std::array::from_fn(|i| i as u8)
}

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
    /// Input note -> output note sent to `device` (`NOTE_NONE` = not mapped).
    pub note_map: [u8; 128],
    /// Input note -> (output note, sounding-note id) of its sounding note-on (`NOTE_NONE` = not
    /// held). Note-offs route through this, so remapping mid-note can't strand a note, and a
    /// retrigger releases the earlier note with its own id.
    pub held: [(u8, SoundingNoteId); 128],
    /// When true (and the Layer is a multi-out source), audio goes to this slot's extra bus.
    pub separate_out: bool,
}

impl LayerSlot {
    /// Create a slot wrapping `device` at unity gain, unmuted and unsoloed.
    pub fn new(device: Box<dyn AudioDevice>) -> Self {
        Self {
            device,
            volume: 1.0,
            mute: false,
            solo: false,
            note_map: full_note_map(),
            held: [NOT_HELD; 128],
            separate_out: false,
        }
    }

    /// True when this slot contributes audio given the Layer's solo state.
    fn is_audible(&self, any_solo: bool) -> bool {
        !self.mute && (!any_solo || self.solo)
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

    /// Replace a slot's note map (input note -> output note, `NOTE_NONE` = unmapped).
    /// Held notes keep their old output until released.
    pub fn set_slot_note_map(&mut self, index: usize, map: &[u8; 128]) -> bool {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.note_map = *map;
            true
        } else {
            false
        }
    }

    /// Send a slot's audio to its extra bus instead of the main mix (multi-out source only).
    pub fn set_slot_separate_out(&mut self, index: usize, separate: bool) -> bool {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.separate_out = separate;
            true
        } else {
            false
        }
    }

    /// Play `note` on one slot's device directly, bypassing its note map and held notes.
    /// Called from the command thread under the state lock; the device queues the event.
    pub fn audition_slot(
        &mut self,
        index: usize,
        note: u8,
        velocity: u8,
        is_note_on: bool,
    ) -> bool {
        if let Some(slot) = self.slots.get_mut(index) {
            let event = if is_note_on && velocity > 0 {
                NoteEvent::On {
                    note_id: AUDITION_NOTE_ID,
                    key: note,
                    velocity: velocity as f32 / 127.0,
                }
            } else {
                NoteEvent::Off {
                    note_id: AUDITION_NOTE_ID,
                    key: note,
                    release: crate::audio::midi_types::DEFAULT_RELEASE,
                }
            };
            slot.device.mark_activity();
            slot.device.send_note_event(&event, 0);
            true
        } else {
            false
        }
    }

    /// Render every slot into `mix_buffer`, or into its extra bus when it is separate and
    /// `extra_outs` holds a bus for it.
    fn render_slots(
        &mut self,
        inputs: &[f32],
        extra_outs: &mut [Vec<f32>],
        sample_count: usize,
        interleaved: usize,
    ) {
        self.mix_buffer[..interleaved].fill(0.0);
        let any_solo = self.any_solo();

        for (i, slot) in self.slots.iter_mut().enumerate() {
            let audible = slot.is_audible(any_solo);
            slot.device
                .process_block(inputs, &mut self.child_buffer, sample_count);
            let bus = if slot.separate_out {
                extra_outs.get_mut(i)
            } else {
                None
            };
            match bus {
                Some(buf) => {
                    let n = interleaved.min(buf.len());
                    if audible {
                        apply_gain(&mut self.child_buffer, sample_count, slot.volume);
                        buf[..n].copy_from_slice(&self.child_buffer[..n]);
                    } else {
                        buf[..n].fill(0.0);
                    }
                }
                None => {
                    if !audible {
                        continue;
                    }
                    apply_gain(&mut self.child_buffer, sample_count, slot.volume);
                    for j in 0..interleaved {
                        self.mix_buffer[j] += self.child_buffer[j];
                    }
                }
            }
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

        // Not a multi-out source here: separate slots mix in so no audio is lost.
        self.render_slots(inputs, &mut [], sample_count, interleaved);
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
            .min(self.mix_buffer.len())
            .min(self.child_buffer.len());

        // Buses of non-separate (or missing) slots stay silent.
        for buf in extra_outs.iter_mut() {
            let n = interleaved.min(buf.len());
            buf[..n].fill(0.0);
        }

        if !self.enabled {
            copy_interleaved(inputs, outputs, sample_count);
            return;
        }

        outputs[..interleaved].fill(0.0);
        if self.slots.is_empty() {
            return;
        }

        self.render_slots(inputs, extra_outs, sample_count, interleaved);
        outputs[..interleaved].copy_from_slice(&self.mix_buffer[..interleaved]);
    }

    fn choke(&mut self, frame_offset: usize) {
        for slot in &mut self.slots {
            slot.device.choke(frame_offset);
        }
    }

    fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
        let input = (event.key() & 0x7f) as usize;
        let note_id = event.note_id();
        for slot in &mut self.slots {
            match *event {
                NoteEvent::On { .. } => {
                    let out = slot.note_map[input];
                    if out == NOTE_NONE {
                        continue;
                    }
                    slot.device.mark_activity();
                    // Retrigger while held: release the earlier note first, with its own id.
                    let (prev_key, prev_id) = slot.held[input];
                    if prev_key != NOTE_NONE {
                        let release = NoteEvent::Off {
                            note_id: prev_id,
                            key: prev_key,
                            release: crate::audio::midi_types::DEFAULT_RELEASE,
                        };
                        slot.device.send_note_event(&release, frame_offset);
                    }
                    slot.held[input] = (out, note_id);
                    slot.device
                        .send_note_event(&event.with_key(out), frame_offset);
                }
                NoteEvent::Off { .. } | NoteEvent::Expression { .. } => {
                    // Only the note that's held: an earlier note was released at the retrigger.
                    let (out, held_id) = slot.held[input];
                    if out == NOTE_NONE || held_id != note_id {
                        continue;
                    }
                    if matches!(event, NoteEvent::Off { .. }) {
                        slot.held[input] = NOT_HELD;
                    }
                    slot.device.mark_activity();
                    slot.device
                        .send_note_event(&event.with_key(out), frame_offset);
                }
            }
        }
    }

    fn send_cc(&mut self, cc: u8, value14: u16, frame_offset: usize) {
        for slot in &mut self.slots {
            slot.device.send_cc(cc, value14, frame_offset);
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

    fn accepts_note_input(&self) -> bool {
        true
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        Vec::new()
    }

    fn reset(&mut self) {
        for slot in &mut self.slots {
            slot.device.reset();
            slot.held = [NOT_HELD; 128];
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
    use crate::audio::midi_types::DEFAULT_RELEASE;

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

    /// (event, frame_offset) as the slot device received it.
    type MidiLog = std::sync::Arc<std::sync::Mutex<Vec<(NoteEvent, usize)>>>;

    fn on(note_id: SoundingNoteId, key: u8, velocity: f32) -> NoteEvent {
        NoteEvent::On {
            note_id,
            key,
            velocity,
        }
    }

    fn off(note_id: SoundingNoteId, key: u8, release: f32) -> NoteEvent {
        NoteEvent::Off {
            note_id,
            key,
            release,
        }
    }

    /// Records note events and outputs silence.
    struct MidiRecorder {
        log: MidiLog,
    }

    impl AudioDevice for MidiRecorder {
        fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            let n = (sample_count * 2).min(outputs.len());
            outputs[..n].fill(0.0);
        }

        fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
            self.log.lock().unwrap().push((*event, frame_offset));
        }

        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}

        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }

        fn device_id(&self) -> &str {
            "test.midi_recorder"
        }

        fn device_name(&self) -> &str {
            "Recorder"
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

    /// Insert a MidiRecorder at `index` and return its log.
    fn add_recorder(layer: &mut LayerDevice, index: usize) -> MidiLog {
        let log = MidiLog::default();
        layer.insert_child(index, Box::new(MidiRecorder { log: log.clone() }));
        log
    }

    fn events(log: &MidiLog) -> Vec<(NoteEvent, usize)> {
        log.lock().unwrap().clone()
    }

    /// A map with only the given input -> output pairs.
    fn map_of(pairs: &[(u8, u8)]) -> [u8; 128] {
        let mut map = [NOTE_NONE; 128];
        for &(input, output) in pairs {
            map[input as usize] = output;
        }
        map
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

    #[test]
    fn layer_fresh_slot_is_full_map() {
        let mut layer = LayerDevice::new(8);
        let log = add_recorder(&mut layer, 0);
        for n in 0..128u8 {
            layer.send_note_event(&on(n as u32 + 1, n, 0.8), 0);
        }
        let got: Vec<u8> = events(&log).iter().map(|e| e.0.key()).collect();
        assert_eq!(got, (0..128u8).collect::<Vec<_>>());
    }

    #[test]
    fn layer_routes_note_through_slot_maps() {
        let mut layer = LayerDevice::new(8);
        let a = add_recorder(&mut layer, 0);
        let b = add_recorder(&mut layer, 1);
        let c = add_recorder(&mut layer, 2);
        layer.set_slot_note_map(0, &map_of(&[(36, 36)]));
        layer.set_slot_note_map(1, &map_of(&[(36, 49)]));
        layer.set_slot_note_map(2, &map_of(&[]));
        layer.send_note_event(&on(1, 36, 0.7), 17);
        assert_eq!(events(&a), vec![(on(1, 36, 0.7), 17)]);
        assert_eq!(events(&b), vec![(on(1, 49, 0.7), 17)]);
        assert!(events(&c).is_empty());
    }

    #[test]
    fn layer_cc_reaches_every_slot() {
        use crate::audio::devices::note_fx::routing::test_devices::CcRecorder;
        let mut layer = LayerDevice::new(8);
        let (a, log_a, _) = CcRecorder::new(true);
        let (b, log_b, _) = CcRecorder::new(true);
        layer.insert_child(0, Box::new(a));
        layer.insert_child(1, Box::new(b));
        layer.send_cc(74, 4096, 2);
        assert_eq!(*log_a.lock().unwrap(), vec![(74, 4096, 2)]);
        assert_eq!(*log_b.lock().unwrap(), vec![(74, 4096, 2)]);
    }

    #[test]
    fn layer_keeps_note_id_through_remap() {
        let mut layer = LayerDevice::new(8);
        let b = add_recorder(&mut layer, 0);
        layer.set_slot_note_map(0, &map_of(&[(60, 36)]));
        layer.send_note_event(&on(42, 60, 0.5039), 0);
        layer.send_note_event(&off(42, 60, 0.25), 9);
        assert_eq!(
            events(&b),
            vec![(on(42, 36, 0.5039), 0), (off(42, 36, 0.25), 9)]
        );
    }

    #[test]
    fn layer_note_off_follows_held_note_after_remap() {
        let mut layer = LayerDevice::new(8);
        let b = add_recorder(&mut layer, 0);
        layer.set_slot_note_map(0, &map_of(&[(36, 49)]));
        layer.send_note_event(&on(1, 36, 0.8), 0);
        layer.set_slot_note_map(0, &map_of(&[(36, 51)]));
        layer.send_note_event(&off(1, 36, 0.5), 5);
        assert_eq!(events(&b), vec![(on(1, 49, 0.8), 0), (off(1, 49, 0.5), 5)]);
    }

    #[test]
    fn layer_note_off_reaches_slot_unmapped_mid_note() {
        let mut layer = LayerDevice::new(8);
        let b = add_recorder(&mut layer, 0);
        layer.send_note_event(&on(1, 40, 0.8), 0);
        layer.set_slot_note_map(0, &map_of(&[]));
        layer.send_note_event(&off(1, 40, 0.5), 0);
        assert_eq!(events(&b), vec![(on(1, 40, 0.8), 0), (off(1, 40, 0.5), 0)]);
    }

    #[test]
    fn layer_note_off_follows_held_note_after_move() {
        let mut layer = LayerDevice::new(8);
        let a = add_recorder(&mut layer, 0);
        let b = add_recorder(&mut layer, 1);
        layer.set_slot_note_map(1, &map_of(&[(36, 49)]));
        layer.send_note_event(&on(1, 36, 0.8), 0);
        layer.move_child(1, 0);
        layer.set_slot_note_map(0, &map_of(&[(36, 60)]));
        layer.send_note_event(&off(1, 36, 0.5), 0);
        assert_eq!(events(&b), vec![(on(1, 49, 0.8), 0), (off(1, 49, 0.5), 0)]);
        assert_eq!(events(&a), vec![(on(1, 36, 0.8), 0), (off(1, 36, 0.5), 0)]);
    }

    #[test]
    fn layer_retrigger_releases_held_id() {
        let mut layer = LayerDevice::new(8);
        let b = add_recorder(&mut layer, 0);
        layer.set_slot_note_map(0, &map_of(&[(36, 49)]));
        layer.send_note_event(&on(1, 36, 0.8), 0);
        layer.set_slot_note_map(0, &map_of(&[(36, 51)]));
        layer.send_note_event(&on(2, 36, 0.6), 3);
        // The first note's own off was already sent at the retrigger, so it's dropped.
        layer.send_note_event(&off(1, 36, 0.9), 4);
        layer.send_note_event(&off(2, 36, 0.2), 5);
        assert_eq!(
            events(&b),
            vec![
                (on(1, 49, 0.8), 0),
                (off(1, 49, DEFAULT_RELEASE), 3),
                (on(2, 51, 0.6), 3),
                (off(2, 51, 0.2), 5)
            ]
        );
    }

    #[test]
    fn layer_forwards_expression_for_held_note_only() {
        let mut layer = LayerDevice::new(8);
        let b = add_recorder(&mut layer, 0);
        layer.set_slot_note_map(0, &map_of(&[(60, 36)]));
        let expression = |note_id| NoteEvent::Expression {
            note_id,
            key: 60,
            kind: crate::audio::midi_types::NoteExpression::Pressure,
            value: 0.3,
        };
        layer.send_note_event(&expression(1), 0);
        layer.send_note_event(&on(1, 60, 0.8), 0);
        layer.send_note_event(&expression(1), 2);
        layer.send_note_event(&expression(7), 2);
        assert_eq!(
            events(&b),
            vec![(on(1, 36, 0.8), 0), (expression(1).with_key(36), 2)]
        );
    }

    #[test]
    fn layer_reset_forgets_held_notes() {
        let mut layer = LayerDevice::new(8);
        let b = add_recorder(&mut layer, 0);
        layer.send_note_event(&on(1, 36, 0.8), 0);
        layer.reset();
        layer.send_note_event(&off(1, 36, 0.5), 0);
        assert_eq!(events(&b), vec![(on(1, 36, 0.8), 0)]);
    }

    #[test]
    fn layer_audition_bypasses_map() {
        let mut layer = LayerDevice::new(8);
        let b = add_recorder(&mut layer, 0);
        layer.set_slot_note_map(0, &map_of(&[]));
        assert!(layer.audition_slot(0, 49, 127, true));
        assert!(layer.audition_slot(0, 49, 0, false));
        assert!(!layer.audition_slot(3, 49, 100, true));
        assert_eq!(
            events(&b),
            vec![
                (on(AUDITION_NOTE_ID, 49, 1.0), 0),
                (off(AUDITION_NOTE_ID, 49, DEFAULT_RELEASE), 0)
            ]
        );
        // Auditioning doesn't touch held notes: a Layer note-off on 49 reaches nothing.
        layer.send_note_event(&off(AUDITION_NOTE_ID, 49, 0.5), 0);
        assert_eq!(events(&b).len(), 2);
    }

    /// Render with `bus_count` extra buses; returns (main L, bus L per bus).
    fn render_extra(layer: &mut LayerDevice, input: f32, bus_count: usize) -> (f32, Vec<f32>) {
        let inputs = vec![input; 4];
        let mut outputs = vec![0.0f32; 4];
        let mut extras = vec![vec![9.0f32; 4]; bus_count];
        layer.process_block_with_extra(&inputs, &mut outputs, &mut extras, 2);
        (outputs[0], extras.iter().map(|b| b[0]).collect())
    }

    #[test]
    fn layer_separate_slot_writes_extra_bus() {
        let mut layer = LayerDevice::new(8);
        layer.insert_child(0, Box::new(GainDevice::new(0.5)));
        layer.insert_child(1, Box::new(GainDevice::new(0.25)));
        layer.insert_child(2, Box::new(GainDevice::new(0.125)));
        assert_eq!(layer.extra_output_bus_count(), 3);
        layer.set_slot_separate_out(1, true);
        layer.set_slot_separate_out(2, true);

        // Buses for slots 0 and 1 only: slot 2 has no bus and falls back to main.
        let (main, buses) = render_extra(&mut layer, 1.0, 2);
        assert!((main - 0.625).abs() < 1e-6);
        assert_eq!(buses[0], 0.0);
        assert!((buses[1] - 0.25).abs() < 1e-6);

        // A muted separate slot leaves its bus silent.
        layer.set_slot_mute(1, true);
        let (_, buses) = render_extra(&mut layer, 1.0, 3);
        assert_eq!(buses[1], 0.0);
        assert!((buses[2] - 0.125).abs() < 1e-6);
    }

    #[test]
    fn layer_process_block_ignores_separate_flag() {
        let mut layer = LayerDevice::new(8);
        layer.insert_child(0, Box::new(GainDevice::new(0.5)));
        layer.insert_child(1, Box::new(GainDevice::new(0.25)));
        layer.set_slot_separate_out(1, true);
        assert!((render(&mut layer, 1.0) - 0.75).abs() < 1e-6);
    }

    #[test]
    fn note_effect_in_one_slot_only() {
        use crate::audio::devices::note_fx::routing::test_devices::{on_keys, Recorder, Shift};
        use crate::audio::devices::ChainDevice;
        let (a, log_a) = Recorder::new();
        let (b, log_b) = Recorder::new();
        let mut slot_a = ChainDevice::new(8);
        slot_a.insert_child(0, Box::new(Shift::new(12)));
        slot_a.insert_child(1, Box::new(a));
        let mut slot_b = ChainDevice::new(8);
        slot_b.insert_child(0, Box::new(b));
        let mut layer = LayerDevice::new(8);
        layer.insert_child(0, Box::new(slot_a));
        layer.insert_child(1, Box::new(slot_b));

        layer.send_note_event(&NoteEvent::test_on(60, 100), 0);
        render(&mut layer, 0.0);
        assert_eq!(on_keys(&log_a), vec![72]);
        assert_eq!(on_keys(&log_b), vec![60]);
    }
}
