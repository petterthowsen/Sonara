//! Device chain and note processing for a channel.

use super::Channel;
use crate::audio::active_notes::NoteSource;
use crate::audio::devices::container::{ChainCursor, ChainStep};
use crate::audio::devices::AudioDevice;
use crate::audio::dsp::interleave::{deinterleave_stereo, interleave_stereo};
use crate::audio::midi_types::{NoteEvent, DEFAULT_RELEASE};
use crate::audio::render_scratch::ClipNoteEvent;

/// Send a note event through `devices` in chain order, waking those that take note input. It
/// stops at the first note effect, which hands it on in the note phase (spec 027).
fn send_note_event_to(
    devices: &mut [Box<dyn AudioDevice>],
    event: &NoteEvent,
    frame_offset: usize,
) {
    crate::audio::devices::note_fx::routing::route_note(devices, event, frame_offset);
}

impl Channel {
    /// Turn this buffer's scheduled live MIDI into note events for the channel's devices.
    ///
    /// A note-on with velocity > 0 starts a note at `v/127`. A note-off ends it with release
    /// `v/127`, and a note-on with velocity 0 ends it with `DEFAULT_RELEASE`.
    fn dispatch_scheduled_midi(&mut self) {
        use crate::audio::midi_types::MidiMessageType;

        for i in 0..self.scheduled_midi_events.len() {
            let event = &self.scheduled_midi_events[i];
            let source = NoteSource::Live {
                midi_channel: event.midi_channel,
            };
            let (key, frame_offset) = (event.note, event.frame_offset);
            let value = event.velocity as f32 / 127.0;
            // `None` starts a note; `Some(release)` ends one.
            let ends_with = match (event.message_type, event.velocity) {
                (MidiMessageType::NoteOn, 0) => Some(DEFAULT_RELEASE),
                (MidiMessageType::NoteOn, _) => None,
                (MidiMessageType::NoteOff, _) => Some(value),
                _ => continue,
            };
            match ends_with {
                None => {
                    let (evicted, on) =
                        self.active_notes
                            .note_on(source, key, value, DEFAULT_RELEASE);
                    if let Some(off) = evicted {
                        self.send_note_event_to_devices(&off, frame_offset);
                    }
                    self.send_note_event_to_devices(&on, frame_offset);
                }
                Some(release) => {
                    if let Some(off) = self.active_notes.note_off(source, key, Some(release)) {
                        self.send_note_event_to_devices(&off, frame_offset);
                    }
                }
            }
        }
    }

    /// Process channel audio through the top-level device chain. Sleep state changes are
    /// appended to `sleep_changes`.
    #[cfg(test)]
    pub fn process_device_chain(&mut self, sample_count: usize) {
        let mut step = self.begin_device_chain(0, sample_count);
        while step == ChainStep::Parked {
            step = self.resume_device_chain(sample_count);
        }
    }

    /// Dispatch this buffer's live MIDI, then run the note phase: each note effect in the
    /// chain hands its output to the devices after it, before any device renders.
    pub fn dispatch_notes(&mut self, sample_count: usize) {
        self.dispatch_scheduled_midi();
        crate::audio::devices::note_fx::routing::run_note_phase(
            &mut self.devices,
            sample_count,
            None,
        );
    }

    /// Index of the device that feeds the extra-out buses: the first one that isn't a note
    /// effect (note effects pass audio through, so they can't be the source; amends spec 006
    /// REQ-007). Equals the device count when there is none.
    pub fn aux_source_index(&self) -> usize {
        self.devices
            .iter()
            .position(|d| !d.is_note_effect())
            .unwrap_or(self.devices.len())
    }

    /// Process the aux-source device into this channel plus extra-out buses (no remaining FX).
    /// Leading note effects only get their note phase: their audio is a pass-through of the
    /// silent input.
    pub fn process_aux_source(&mut self, sample_count: usize) {
        self.dispatch_notes(sample_count);
        let src = self.aux_source_index();
        if src >= self.devices.len() {
            return;
        }

        let has_input_activity =
            crate::audio::devices::has_audio_signal(&self.buffer_left[..sample_count])
                || crate::audio::devices::has_audio_signal(&self.buffer_right[..sample_count]);

        let interleaved_count = sample_count * 2;
        self.device_input_buffer[..interleaved_count].fill(0.0);
        self.device_output_buffer[..interleaved_count].fill(0.0);

        interleave_stereo(
            &self.buffer_left[..sample_count],
            &self.buffer_right[..sample_count],
            &mut self.device_input_buffer[..sample_count * 2],
        );

        let mut extras = std::mem::take(&mut self.extra_out_buffers);
        let extra_count = self.devices[src].extra_output_bus_count().min(extras.len());
        let section = crate::audio::rt_debug::device_name(
            "process_block_with_extra",
            self.devices[src].device_id(),
        );
        crate::audio::rt_debug::device_section(section, || {
            self.devices[src].process_block_with_extra(
                &self.device_input_buffer,
                &mut self.device_output_buffer,
                &mut extras[..extra_count],
                sample_count,
            )
        });
        self.extra_out_buffers = extras;

        deinterleave_stereo(
            &self.device_output_buffer[..sample_count * 2],
            &mut self.buffer_left[..sample_count],
            &mut self.buffer_right[..sample_count],
        );

        let has_output_activity = crate::audio::devices::has_audio_signal(
            &self.device_output_buffer[..interleaved_count.min(self.device_output_buffer.len())],
        );
        if self.devices[src].update_sleep_state(has_input_activity || has_output_activity) {
            self.sleep_changes.push((
                crate::audio::devices::DevicePath::root(src),
                self.devices[src].is_sleeping(),
            ));
        }
    }

    /// Start the device chain from `start`, running devices until one begins a block
    /// asynchronously (`Parked`; finish with `resume_device_chain`) or the chain ends. Scheduled
    /// MIDI is dispatched and the note phase runs when `start` is 0. The channel buffers hold the result once `Done`.
    pub fn begin_device_chain(&mut self, start: usize, sample_count: usize) -> ChainStep {
        if start == 0 {
            crate::audio::rt_debug::section("device MIDI dispatch", || {
                self.dispatch_notes(sample_count)
            });
        }
        self.begin_chain_from(start, sample_count)
    }

    /// `begin_device_chain` without MIDI dispatch.
    fn begin_chain_from(&mut self, start: usize, sample_count: usize) -> ChainStep {
        if start >= self.devices.len() {
            return ChainStep::Done {
                result_in_output: false,
            };
        }

        let has_input_activity =
            crate::audio::devices::has_audio_signal(&self.buffer_left[..sample_count])
                || crate::audio::devices::has_audio_signal(&self.buffer_right[..sample_count]);

        let interleaved_count = sample_count * 2;
        self.device_input_buffer[..interleaved_count].fill(0.0);
        self.device_output_buffer[..interleaved_count].fill(0.0);

        interleave_stereo(
            &self.buffer_left[..sample_count],
            &self.buffer_right[..sample_count],
            &mut self.device_input_buffer[..sample_count * 2],
        );

        self.mix.chain_start = start;
        self.mix.cursor = ChainCursor::start(has_input_activity);
        let sleep_changes = &mut self.sleep_changes;
        let step = crate::audio::devices::container::run_chain(
            &mut self.devices[start..],
            &mut self.device_input_buffer,
            &mut self.device_output_buffer,
            sample_count,
            &mut self.mix.cursor,
            &mut |idx, sleeping| {
                sleep_changes.push((
                    crate::audio::devices::DevicePath::root(start + idx),
                    sleeping,
                ))
            },
        );
        self.complete_chain_step(step, sample_count)
    }

    /// Finish the plugin this channel's chain parked at (waiting for it), then run the rest of
    /// the chain until it parks again or ends.
    pub fn resume_device_chain(&mut self, sample_count: usize) -> ChainStep {
        let start = self.mix.chain_start;
        let sleep_changes = &mut self.sleep_changes;
        let step = crate::audio::devices::container::resume_chain(
            &mut self.devices[start..],
            &mut self.device_input_buffer,
            &mut self.device_output_buffer,
            sample_count,
            &mut self.mix.cursor,
            &mut |idx, sleeping| {
                sleep_changes.push((
                    crate::audio::devices::DevicePath::root(start + idx),
                    sleeping,
                ))
            },
        );
        self.complete_chain_step(step, sample_count)
    }

    /// Copy a finished chain's result back into the channel buffers.
    fn complete_chain_step(&mut self, step: ChainStep, sample_count: usize) -> ChainStep {
        if let ChainStep::Done { result_in_output } = step {
            let final_output = if result_in_output {
                &self.device_output_buffer
            } else {
                &self.device_input_buffer
            };

            deinterleave_stereo(
                &final_output[..sample_count * 2],
                &mut self.buffer_left[..sample_count],
                &mut self.buffer_right[..sample_count],
            );
        }
        step
    }

    /// Send a note from clip playback. The note-on gets a sounding-note id from `active_notes`,
    /// and the note-off finds it by clip-note id. A note-off with no sounding note (already
    /// released by stop or seek) is dropped.
    pub fn send_clip_note(&mut self, event: &ClipNoteEvent, frame_offset: usize) {
        let source = NoteSource::Clip {
            clip_note_id: event.clip_note_id,
        };
        if event.is_on {
            let (evicted, on) =
                self.active_notes
                    .note_on(source, event.key, event.velocity, event.release);
            if let Some(off) = evicted {
                self.send_note_event_to_devices(&off, frame_offset);
            }
            self.send_note_event_to_devices(&on, frame_offset);
        } else if let Some(off) = self
            .active_notes
            .note_off(source, event.key, Some(event.release))
        {
            self.send_note_event_to_devices(&off, frame_offset);
        }
    }

    /// Send a note-off for every clip note still sounding, with the release it started with.
    /// Live MIDI isn't touched, so keys held on a controller keep playing.
    pub fn release_clip_notes(&mut self) {
        self.release_clip_notes_at(0);
    }

    /// Transport stop, pause or seek: release the clip notes, then tell every note effect,
    /// which releases what it generated from clip notes at its next note phase (spec 027
    /// REQ-007). Loop wraps use `release_clip_notes_at` instead, so echoes and latched notes
    /// ring across the loop point.
    pub fn stop_clip_notes(&mut self) {
        self.release_clip_notes();
        crate::audio::devices::container::visit_devices_mut(&mut self.devices, &mut |_, device| {
            if device.is_note_effect() {
                device.note_discontinuity();
            }
        });
    }

    /// Command thread, before a device at `path` is removed: if it is a note effect, its
    /// sounding notes are released to the devices after it, so none is left hanging (REQ-006).
    pub fn release_note_effect_at(&mut self, path: &crate::audio::devices::DevicePath) {
        let Some(index) = path.leaf_index() else {
            return;
        };
        if let Some(list) = self.chain_list_mut(&path.parent()) {
            crate::audio::devices::note_fx::routing::release_note_effect_at(list, index);
        }
    }

    /// Command thread, before devices in the list at `parent_path` move: every note effect in
    /// it releases its sounding notes, since its downstream devices are about to change.
    pub fn release_note_effects_in(&mut self, parent_path: &crate::audio::devices::DevicePath) {
        if let Some(list) = self.chain_list_mut(parent_path) {
            crate::audio::devices::note_fx::routing::release_note_effects(list);
        }
    }

    /// Like `release_clip_notes`, with the note-offs placed `frame_offset` frames into the buffer.
    pub fn release_clip_notes_at(&mut self, frame_offset: usize) {
        let devices = &mut self.devices;
        self.active_notes
            .release_clip(|off| send_note_event_to(devices, &off, frame_offset));
    }

    /// Send a note event to every top-level device with a frame offset, like scheduled notes.
    ///
    /// Audio effects ignore notes (the trait default); containers forward to their children.
    /// Only a device that accepts note input, or carries a note-driven modulator, is woken, so
    /// a sleeping reverb stays asleep (ADR-0014).
    pub fn send_note_event_to_devices(&mut self, event: &NoteEvent, frame_offset: usize) {
        send_note_event_to(&mut self.devices, event, frame_offset);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::{DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
    use crate::audio::midi_types::MidiEvent;
    use crate::audio::midi_types::MidiMessageType;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    /// Instrument that records every note event it receives.
    struct NoteProbe {
        events: Arc<Mutex<Vec<NoteEvent>>>,
    }

    impl AudioDevice for NoteProbe {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn send_note_event(&mut self, event: &NoteEvent, _frame_offset: usize) {
            self.events.lock().unwrap().push(*event);
        }
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.note_probe"
        }
        fn device_name(&self) -> &str {
            "Note Probe"
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

    /// Dispatch `midi` as one buffer of live MIDI and return what the probe received.
    fn dispatch_live(midi: &[(MidiMessageType, u8, u8)]) -> Vec<NoteEvent> {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut channel = Channel::new(2, "Probe".to_string(), 64, 48_000.0);
        channel.devices.push(Box::new(NoteProbe {
            events: events.clone(),
        }));
        for &(message_type, note, velocity) in midi {
            channel.scheduled_midi_events.push(MidiEvent {
                message_type,
                midi_channel: 0,
                note,
                velocity,
                received_at: Instant::now(),
                frame_offset: 0,
            });
        }
        channel.dispatch_scheduled_midi();
        let received = events.lock().unwrap().clone();
        received
    }

    #[test]
    fn stop_releases_generated_clip_notes_only() {
        use crate::audio::devices::note_fx::host::tests::test_host;
        use crate::audio::devices::note_fx::routing::test_devices::Recorder;
        use crate::audio::render_scratch::ClipNoteEvent;
        let mut channel = Channel::new(2, "test".to_string(), 128, 48_000.0);
        // Each note plus one generated copy an octave up, 32 frames later.
        channel.devices.push(Box::new(test_host(0.0, 32.0, 1.0)));
        let (recorder, log) = Recorder::new();
        channel.devices.push(Box::new(recorder));

        channel.send_clip_note(
            &ClipNoteEvent {
                track_id: 1,
                clip_note_id: 7,
                key: 60,
                velocity: 0.8,
                release: DEFAULT_RELEASE,
                is_on: true,
            },
            0,
        );
        channel
            .scheduled_midi_events
            .push(MidiEvent::note_on(0, 48, 100, Instant::now()));
        channel.dispatch_notes(64);
        channel.scheduled_midi_events.clear();
        log.lock().unwrap().clear();

        channel.stop_clip_notes();
        channel.dispatch_notes(64);
        let offs: Vec<u8> = log
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, e)| matches!(e, NoteEvent::Off { .. }))
            .map(|(_, e)| e.key())
            .collect();
        // The clip note and its copy end; the live 48 and its copy (60) keep sounding.
        let mut sorted = offs.clone();
        sorted.sort();
        assert_eq!(sorted, vec![60, 72], "{offs:?}");
        let ids: Vec<u32> = log
            .lock()
            .unwrap()
            .iter()
            .map(|(_, e)| e.note_id())
            .collect();
        assert!(ids
            .iter()
            .all(|&id| crate::audio::midi_types::is_clip_note(id)));
    }

    #[test]
    fn latch_keeps_instrument_awake() {
        use crate::audio::devices::note_fx::latch::Latch;
        use crate::audio::devices::note_fx::NoteFxHost;
        use crate::audio::devices::PolySynthDevice;
        const SR: f32 = 48_000.0;
        const BLOCK: usize = 256;
        let mut channel = Channel::new(2, "test".to_string(), BLOCK, SR);
        channel.devices.push(Box::new(NoteFxHost::<Latch>::new(SR)));
        channel.devices.push(Box::new(PolySynthDevice::new(SR)));
        // A sustaining amp envelope: the held note keeps sounding instead of decaying away.
        let sustain = channel.devices[1]
            .parameters()
            .into_iter()
            .find(|p| p.name == "Amp Sustain")
            .expect("amp sustain parameter");
        channel.devices[1].set_parameter(sustain.id, 1.0);
        // One live note-on held for the whole run: the latch swallows its note-off.
        channel.send_note_event_to_devices(
            &NoteEvent::On {
                note_id: 1,
                key: 60,
                velocity: 0.8,
            },
            0,
        );
        let blocks = (10.0 * SR / BLOCK as f32).ceil() as usize;
        for _ in 0..blocks {
            channel.process_device_chain(BLOCK);
        }
        // The note is still sounding (the latch never passed a note-off): the instrument's
        // audio keeps it awake and neither device ever slept.
        assert!(!channel.devices[0].is_sleeping());
        assert!(!channel.devices[1].is_sleeping());
        assert!(
            channel.sleep_changes.iter().all(|(_, sleeping)| !*sleeping),
            "{:?}",
            channel.sleep_changes
        );
    }

    #[test]
    fn live_note_off_carries_release() {
        let events = dispatch_live(&[
            (MidiMessageType::NoteOn, 60, 127),
            (MidiMessageType::NoteOff, 60, 32),
        ]);
        assert_eq!(events.len(), 2, "{events:?}");
        assert!(matches!(events[0], NoteEvent::On { key: 60, velocity, .. } if velocity == 1.0));
        assert_eq!(
            events[1],
            NoteEvent::Off {
                note_id: events[0].note_id(),
                key: 60,
                release: 32.0 / 127.0
            }
        );
    }

    #[test]
    fn live_note_on_zero_is_release_default() {
        let events = dispatch_live(&[
            (MidiMessageType::NoteOn, 60, 100),
            (MidiMessageType::NoteOn, 60, 0),
            // A note-off with nothing sounding on its key is dropped.
            (MidiMessageType::NoteOff, 61, 64),
        ]);
        assert_eq!(events.len(), 2, "{events:?}");
        assert_eq!(
            events[1],
            NoteEvent::Off {
                note_id: events[0].note_id(),
                key: 60,
                release: DEFAULT_RELEASE
            }
        );
    }
}
