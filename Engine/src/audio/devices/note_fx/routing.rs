//! How notes move through a device chain (spec 027 REQ-001, REQ-002, REQ-013).
//!
//! The channel root, every Chain and every slot chain use these helpers, so the routing rule
//! lives in one place: a note goes to each device in chain order until the first note effect,
//! which queues it. The **note phase** then runs each note effect in order and routes its
//! output to the devices after it, again stopping at the next note effect. With no note effect
//! in a chain this is the plain broadcast it replaces.

use super::{NoteBuffer, TimedNote};
use crate::audio::devices::AudioDevice;
use crate::audio::midi_types::NoteEvent;

/// Deliver `event` to `devices` in order, waking those that take note input, and stop after
/// the first note effect. Returns true when no note effect took it (it fell off the end).
pub fn route_note(
    devices: &mut [Box<dyn AudioDevice>],
    event: &NoteEvent,
    frame_offset: usize,
) -> bool {
    for device in devices.iter_mut() {
        if device.accepts_note_input() {
            device.mark_activity();
        }
        device.send_note_event(event, frame_offset);
        if device.is_note_effect() {
            return false;
        }
    }
    true
}

/// Route a note effect's output into the devices after it; notes falling off the end go to
/// `sink` (a note branch's collected output) or are dropped.
fn route_output(
    notes: &[TimedNote],
    downstream: &mut [Box<dyn AudioDevice>],
    sink: &mut Option<&mut NoteBuffer>,
) {
    for note in notes {
        if route_note(downstream, &note.event, note.frame) {
            if let Some(sink) = sink.as_deref_mut() {
                if !sink.push(*note) {
                    tracing::warn!("note branch output full, note dropped");
                }
            }
        }
    }
}

/// Audio thread, before the chain renders: run each note effect's `process_notes` in chain
/// order and route its output downstream. Notes that pass every note effect and fall off the
/// end go to `sink` when given.
pub fn run_note_phase(
    devices: &mut [Box<dyn AudioDevice>],
    sample_count: usize,
    mut sink: Option<&mut NoteBuffer>,
) {
    for i in 0..devices.len() {
        if !devices[i].is_note_effect() {
            continue;
        }
        let (head, downstream) = devices.split_at_mut(i + 1);
        let notes = head[i].process_notes(sample_count);
        route_output(notes, downstream, &mut sink);
    }
}

/// Command thread, before removing or moving devices in `devices`: every note effect in it
/// sends note-offs for what it has sounding to the devices after it, and drops its schedule
/// (REQ-006). Returns how many note effects were released.
pub fn release_note_effects(devices: &mut [Box<dyn AudioDevice>]) -> usize {
    let mut released = 0;
    for i in 0..devices.len() {
        released += release_note_effect_at(devices, i) as usize;
    }
    released
}

/// Like [`release_note_effects`] for the one device at `index`, if it is a note effect.
pub fn release_note_effect_at(devices: &mut [Box<dyn AudioDevice>], index: usize) -> bool {
    if index >= devices.len() || !devices[index].is_note_effect() {
        return false;
    }
    let (head, downstream) = devices.split_at_mut(index + 1);
    let notes = head[index].release_notes_now();
    route_output(notes, downstream, &mut None);
    true
}

/// Test doubles shared by the routing, chain, layer and modulation tests.
#[cfg(test)]
pub mod test_devices {
    use super::super::{NoteBuffer, TimedNote};
    use crate::audio::devices::{
        AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
    };
    use crate::audio::midi_types::NoteEvent;
    use std::sync::{Arc, Mutex};

    /// Records every note it receives, as `(frame, event)`.
    pub struct Recorder {
        pub log: Arc<Mutex<Vec<(usize, NoteEvent)>>>,
    }

    impl Recorder {
        pub fn new() -> (Self, Arc<Mutex<Vec<(usize, NoteEvent)>>>) {
            let log = Arc::new(Mutex::new(Vec::new()));
            (Self { log: log.clone() }, log)
        }
    }

    impl AudioDevice for Recorder {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            crate::audio::devices::container::copy_interleaved(inputs, outputs, sample_count);
        }
        fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
            self.log.lock().unwrap().push((frame_offset, *event));
        }
        fn accepts_note_input(&self) -> bool {
            true
        }
        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.recorder"
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

    /// A minimal note effect: queues input, shifts note-ons and note-offs by `semitones` and
    /// keeps the id. Stateless, so a note-off follows only while `semitones` is unchanged.
    pub struct Shift {
        pub semitones: i32,
        /// Every note-on leaves with this velocity when set.
        pub velocity: Option<f32>,
        input: NoteBuffer,
        output: NoteBuffer,
    }

    impl Shift {
        pub fn new(semitones: i32) -> Self {
            Self {
                semitones,
                velocity: None,
                input: NoteBuffer::new(64),
                output: NoteBuffer::new(64),
            }
        }
    }

    impl AudioDevice for Shift {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            crate::audio::devices::container::copy_interleaved(inputs, outputs, sample_count);
        }
        fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
            self.input.push(TimedNote {
                frame: frame_offset,
                event: *event,
            });
        }
        fn accepts_note_input(&self) -> bool {
            true
        }
        fn is_note_effect(&self) -> bool {
            true
        }
        fn process_notes(&mut self, _sample_count: usize) -> &[TimedNote] {
            self.output.clear();
            for note in self.input.as_slice() {
                let key = note.event.key() as i32 + self.semitones;
                if (0..=127).contains(&key) {
                    let mut event = note.event.with_key(key as u8);
                    if let (NoteEvent::On { velocity, .. }, Some(fixed)) =
                        (&mut event, self.velocity)
                    {
                        *velocity = fixed;
                    }
                    self.output.push(TimedNote {
                        frame: note.frame,
                        event,
                    });
                }
            }
            self.input.clear();
            self.output.as_slice()
        }
        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.shift"
        }
        fn device_name(&self) -> &str {
            "Shift"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::NoteEffect
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

    /// The keys a recorder saw, note-ons only.
    pub fn on_keys(log: &Arc<Mutex<Vec<(usize, NoteEvent)>>>) -> Vec<u8> {
        log.lock()
            .unwrap()
            .iter()
            .filter(|(_, e)| matches!(e, NoteEvent::On { .. }))
            .map(|(_, e)| e.key())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::test_devices::{on_keys, Recorder, Shift};
    use super::*;
    use crate::audio::midi_types::NoteEvent;

    fn on(key: u8) -> NoteEvent {
        NoteEvent::On {
            note_id: key as u32 + 1,
            key,
            velocity: 0.8,
        }
    }

    #[test]
    fn note_effect_stops_routing_and_feeds_only_later_devices() {
        let (a, log_a) = Recorder::new();
        let (b, log_b) = Recorder::new();
        let mut devices: Vec<Box<dyn AudioDevice>> =
            vec![Box::new(a), Box::new(Shift::new(12)), Box::new(b)];

        assert!(!route_note(&mut devices, &on(60), 7));
        assert_eq!(on_keys(&log_a), vec![60]);
        assert!(on_keys(&log_b).is_empty(), "queued in the note effect");

        run_note_phase(&mut devices, 64, None);
        assert_eq!(on_keys(&log_a), vec![60], "A never sees the output");
        assert_eq!(on_keys(&log_b), vec![72]);
        assert_eq!(log_b.lock().unwrap()[0].0, 7, "frame offset kept");
    }

    #[test]
    fn chained_note_effects_compose_in_order() {
        let (r, log) = Recorder::new();
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![
            Box::new(Shift::new(12)),
            Box::new(Shift::new(-5)),
            Box::new(r),
        ];
        route_note(&mut devices, &on(60), 0);
        run_note_phase(&mut devices, 64, None);
        assert_eq!(on_keys(&log), vec![67]);
    }

    #[test]
    fn events_past_the_end_go_to_the_sink() {
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![Box::new(Shift::new(1))];
        let mut sink = NoteBuffer::new(8);
        assert!(!route_note(&mut devices, &on(60), 3));
        run_note_phase(&mut devices, 64, Some(&mut sink));
        assert_eq!(sink.len(), 1);
        assert_eq!(sink.as_slice()[0].event.key(), 61);
        assert_eq!(sink.as_slice()[0].frame, 3);

        let mut empty: Vec<Box<dyn AudioDevice>> = Vec::new();
        assert!(
            route_note(&mut empty, &on(60), 0),
            "an empty chain lets it fall off"
        );
    }

    #[test]
    fn without_note_effects_routing_is_a_broadcast() {
        let (a, log_a) = Recorder::new();
        let (b, log_b) = Recorder::new();
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![Box::new(a), Box::new(b)];
        assert!(route_note(&mut devices, &on(60), 0));
        assert_eq!(on_keys(&log_a), vec![60]);
        assert_eq!(on_keys(&log_b), vec![60]);
    }
}
