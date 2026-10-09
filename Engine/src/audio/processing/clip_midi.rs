//! Clip MIDI stage: turns the ticks crossed in a buffer into note-ons and note-offs from the
//! tracks' clip instances and sends them to the track's channel at the exact frame.
//!
//! Reads: tracks (clip instances), clips (notes), the buffer's tick events and loop wraps.
//! Writes: channels (clip note state and device note input) and the note-event scratch list.

use std::collections::HashMap;

use crate::audio::channel::Channel;
use crate::audio::clip::{Clip, ClipInstance};
use crate::audio::render_scratch::ClipNoteEvent;
use crate::audio::track::Track;
use crate::audio::types::*;

/// Dispatch clip MIDI for each tick event at its frame offset.
///
/// `loop_wraps` holds indices into `tick_events` of the first event after each loop wrap. A wrap
/// ends every clip note still sounding, at the wrap frame, before the note-ons at the loop
/// start. `note_events` is preallocated scratch, cleared per tick.
pub(super) fn dispatch_clip_midi(
    tracks: &HashMap<TrackId, Track>,
    clips: &HashMap<ClipId, Clip>,
    channels: &mut HashMap<ChannelId, Channel>,
    tick_events: &[(Tick, usize)],
    loop_wraps: &[usize],
    note_events: &mut Vec<ClipNoteEvent>,
) {
    let mut next_wrap = 0;
    for (event_idx, &(current_tick, frame_offset)) in tick_events.iter().enumerate() {
        // A loop wrap ends every clip note still sounding, at the wrap frame, before the
        // note-ons at the loop start
        if loop_wraps.get(next_wrap) == Some(&event_idx) {
            next_wrap += 1;
            for channel in channels.values_mut() {
                channel.release_clip_notes_at(frame_offset);
            }
        }

        // Collect note on/off events from clip instances
        note_events.clear();

        for (track_id, track) in tracks {
            for instance in &track.clip_instances {
                if instance.muted {
                    continue;
                }

                // Allow processing at instance end tick for note off events
                // but not for note on events (which require being strictly within the instance)
                let is_within_instance =
                    current_tick >= instance.start_tick && current_tick < instance.end_tick();
                let is_at_instance_end = current_tick == instance.end_tick();

                if is_within_instance || is_at_instance_end {
                    if let Some(clip) = clips.get(&instance.clip_id) {
                        collect_instance_note_events(
                            *track_id,
                            instance,
                            clip,
                            current_tick,
                            is_within_instance,
                            is_at_instance_end,
                            note_events,
                        );
                    }
                }
            }
        }

        for event in note_events.iter() {
            if let Some(track) = tracks.get(&event.track_id) {
                if let Some(channel) = channels.get_mut(&track.channel_id) {
                    channel.send_clip_note(event, frame_offset);
                }
            }
        }
    }
}

/// Push the note-ons and note-offs that one clip instance produces at `current_tick`.
///
/// `is_within_instance` is true strictly inside the instance (note-ons allowed);
/// `is_at_instance_end` is true on its end tick (only note-offs).
fn collect_instance_note_events(
    track_id: TrackId,
    instance: &ClipInstance,
    clip: &Clip,
    current_tick: Tick,
    is_within_instance: bool,
    is_at_instance_end: bool,
    note_events: &mut Vec<ClipNoteEvent>,
) {
    let offset_in_instance = current_tick - instance.start_tick;

    // Position in the clip's content: loop points live in content
    // space (like audio), so `clip_offset` is added before wrapping.
    // At the instance end, read the position the last tick ends at rather
    // than wrapping it: an end on a loop boundary would otherwise fold to
    // the loop start, and notes sounding up to the end never get a note-off.
    let unwrapped_pos = instance.clip_offset + offset_in_instance;
    let content_pos = if is_within_instance {
        instance.wrap_content_tick(unwrapped_pos)
    } else {
        instance.wrap_content_tick(unwrapped_pos - 1) + 1
    };
    let just_wrapped = content_pos != unwrapped_pos && content_pos == instance.loop_start_ticks;

    // A loop wrap ends every note still sounding at the loop end. Sent
    // before the note-ons so a note restarting on the same pitch wins.
    if just_wrapped && is_within_instance {
        let loop_end = instance.loop_start_ticks + instance.loop_length_ticks;
        for clip_note in &clip.midi_notes {
            if clip_note.start_tick < loop_end
                && clip_note.start_tick + clip_note.duration_ticks >= loop_end
            {
                let transposed_note =
                    (clip_note.note as i16 + instance.transpose as i16).clamp(0, 127) as MidiNote;
                note_events.push(ClipNoteEvent {
                    track_id,
                    clip_note_id: clip_note.id,
                    key: transposed_note,
                    velocity: clip_note.velocity,
                    release: clip_note.release,
                    is_on: false,
                });
            }
        }
    }

    for clip_note in &clip.midi_notes {
        let note_end = clip_note.start_tick + clip_note.duration_ticks;

        // Entirely before the trimmed start
        if note_end <= instance.clip_offset {
            continue;
        }

        // Apply transpose
        let transposed_note =
            (clip_note.note as i16 + instance.transpose as i16).clamp(0, 127) as MidiNote;

        // Note On
        if is_within_instance && clip_note.start_tick == content_pos {
            note_events.push(ClipNoteEvent {
                track_id,
                clip_note_id: clip_note.id,
                key: transposed_note,
                velocity: clip_note.velocity,
                release: clip_note.release,
                is_on: true,
            });
        }

        // Note Off at the written end, or clipped to the instance right edge
        // so notes longer than the clip don't hang forever.
        let note_off_at_written_end = note_end == content_pos;
        let note_off_clipped_to_instance =
            is_at_instance_end && clip_note.start_tick < content_pos && note_end > content_pos;
        if note_off_at_written_end || note_off_clipped_to_instance {
            note_events.push(ClipNoteEvent {
                track_id,
                clip_note_id: clip_note.id,
                key: transposed_note,
                velocity: clip_note.velocity,
                release: clip_note.release,
                is_on: false,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::clip::{ClipNote, ClipType};
    use crate::audio::devices::{DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
    use crate::audio::midi_types::NoteEvent;
    use crate::audio::processing::process_audio;
    use crate::audio::state::EngineState;
    use std::time::Instant;

    /// Instrument that records the notes it receives as (key, is_note_on).
    struct NoteRecorder {
        notes: std::sync::Arc<std::sync::Mutex<Vec<(u8, bool)>>>,
    }

    impl crate::audio::devices::AudioDevice for NoteRecorder {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn send_note_event(&mut self, event: &NoteEvent, _offset: usize) {
            let is_note_on = matches!(event, NoteEvent::On { .. });
            self.notes.lock().unwrap().push((event.key(), is_note_on));
        }
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
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
        fn reset(&mut self) {
            panic!("stopping must release notes, not reset devices");
        }
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    fn clip_event(clip_note_id: NoteId, key: u8, is_on: bool) -> ClipNoteEvent {
        ClipNoteEvent {
            track_id: 1,
            clip_note_id,
            key,
            velocity: 100.0 / 127.0,
            release: crate::audio::DEFAULT_RELEASE,
            is_on,
        }
    }

    #[test]
    fn releasing_clip_notes_sends_one_note_off_per_held_note() {
        let notes = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut channel = Channel::new(2, "Synth".to_string(), 64, 48_000.0);
        channel.devices.push(Box::new(NoteRecorder {
            notes: notes.clone(),
        }));

        // Two overlapping instances of clip note 1 (key 60), and note 2 (key 64) that already ended
        channel.send_clip_note(&clip_event(1, 60, true), 0);
        channel.send_clip_note(&clip_event(1, 60, true), 0);
        channel.send_clip_note(&clip_event(2, 64, true), 0);
        channel.send_clip_note(&clip_event(2, 64, false), 0);
        notes.lock().unwrap().clear();

        channel.release_clip_notes();
        assert_eq!(*notes.lock().unwrap(), vec![(60, false), (60, false)]);

        // The clip's own note-off after a stop is dropped, and a second release sends nothing
        notes.lock().unwrap().clear();
        channel.send_clip_note(&clip_event(1, 60, false), 0);
        channel.release_clip_notes();
        assert!(notes.lock().unwrap().is_empty());
    }

    /// Instrument that records every note event it receives with its frame offset.
    struct NoteProbe {
        events: std::sync::Arc<std::sync::Mutex<Vec<(NoteEvent, usize)>>>,
    }

    impl crate::audio::devices::AudioDevice for NoteProbe {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
            self.events.lock().unwrap().push((*event, frame_offset));
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

    /// Play `instances` of one clip holding `note` on a probe channel until `until_tick`,
    /// returning every event with its absolute frame.
    fn play_clip_to_probe(
        note: ClipNote,
        instances: &[(Tick, Tick)],
        until_tick: Tick,
    ) -> Vec<(NoteEvent, usize)> {
        const BLOCK: usize = 64;
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut state = EngineState::default();
        let mut channel = Channel::new(2, "Probe".to_string(), BLOCK, 48_000.0);
        channel.devices.push(Box::new(NoteProbe {
            events: events.clone(),
        }));
        state.channels.insert(2, channel);

        let mut clip = Clip::new("c".to_string(), "c".to_string(), ClipType::Midi);
        clip.content_length_ticks = note.start_tick + note.duration_ticks;
        clip.midi_notes.push(note);
        state.clips.insert("c".to_string(), clip);
        let mut track = Track::new(1, 2);
        for (i, &(start, duration)) in instances.iter().enumerate() {
            track.clip_instances.push(ClipInstance::new(
                format!("i{i}"),
                "c".to_string(),
                start,
                duration,
            ));
        }
        state.tracks.insert(1, track);

        state.set_is_playing(true);
        state.request_playhead_midi_dispatch();
        let mut absolute = Vec::new();
        let mut block_start = 0;
        while state.get_current_tick() < until_tick {
            process_audio(&mut state, BLOCK, 48_000.0, Instant::now());
            for (event, offset) in events.lock().unwrap().drain(..) {
                absolute.push((event, block_start + offset));
            }
            block_start += BLOCK;
        }
        absolute
    }

    #[test]
    fn clip_note_reaches_device_with_float_values() {
        let note = ClipNote {
            id: 7,
            note: 60,
            velocity: 0.5039,
            release: 0.25,
            start_tick: 0,
            duration_ticks: 480,
        };
        let events = play_clip_to_probe(note, &[(0, 960)], 960);
        assert_eq!(events.len(), 2, "{events:?}");

        let (on, on_frame) = events[0];
        let (off, off_frame) = events[1];
        assert!(matches!(on, NoteEvent::On { key: 60, velocity, .. } if velocity == 0.5039));
        assert!(matches!(off, NoteEvent::Off { key: 60, release, .. } if release == 0.25));
        assert_eq!(on.note_id(), off.note_id());
        assert_ne!(on.note_id(), 0);
        // 120 BPM at 48 kHz: 960 ticks per 24000 frames, so tick 480 lands on frame 12000.
        assert_eq!(on_frame, 0);
        assert!(
            off_frame.abs_diff(12_000) <= 1,
            "note-off at frame {off_frame}"
        );
    }

    #[test]
    fn overlapping_instances_get_distinct_note_ids() {
        let note = ClipNote {
            id: 1,
            note: 60,
            velocity: 0.8,
            release: 0.5,
            start_tick: 0,
            duration_ticks: 960,
        };
        // The second instance starts while the first instance's note still sounds.
        let events = play_clip_to_probe(note, &[(0, 960), (480, 960)], 1500);
        let ons: Vec<_> = events
            .iter()
            .filter(|(e, _)| matches!(e, NoteEvent::On { .. }))
            .collect();
        let offs: Vec<_> = events
            .iter()
            .filter(|(e, _)| matches!(e, NoteEvent::Off { .. }))
            .collect();
        assert_eq!((ons.len(), offs.len()), (2, 2), "{events:?}");
        assert_ne!(ons[0].0.note_id(), ons[1].0.note_id());
        // The first instance ends first, so each off pairs with its own on.
        assert_eq!(offs[0].0.note_id(), ons[0].0.note_id());
        assert_eq!(offs[1].0.note_id(), ons[1].0.note_id());
        assert!(offs[0].1 < offs[1].1);
    }

    #[test]
    fn looped_instance_ending_on_loop_boundary_releases_last_note() {
        let notes = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut state = EngineState::default();
        let mut channel = Channel::new(2, "Synth".to_string(), 64, 48_000.0);
        channel.devices.push(Box::new(NoteRecorder {
            notes: notes.clone(),
        }));
        state.channels.insert(2, channel);

        // Four back-to-back beats, the last one held right up to the loop end
        let mut clip = Clip::new("c".to_string(), "c".to_string(), ClipType::Midi);
        for (i, note) in [60u8, 62, 64, 65].into_iter().enumerate() {
            clip.midi_notes.push(ClipNote {
                id: i as _,
                note,
                velocity: 100.0 / 127.0,
                release: crate::audio::DEFAULT_RELEASE,
                start_tick: i as Tick * 960,
                duration_ticks: 960,
            });
        }
        clip.content_length_ticks = 3840;
        state.clips.insert("c".to_string(), clip);

        // Two full passes; the instance ends exactly where the loop would wrap again
        let mut instance = ClipInstance::new("i".to_string(), "c".to_string(), 960, 7680);
        instance.loop_enabled = true;
        instance.loop_length_ticks = 3840;
        let mut track = Track::new(1, 2);
        track.clip_instances.push(instance);
        state.tracks.insert(1, track);

        state.set_is_playing(true);
        state.request_playhead_midi_dispatch();
        while state.get_current_tick() < 10_000 {
            process_audio(&mut state, 64, 48_000.0, Instant::now());
        }

        let notes = notes.lock().unwrap();
        let ons = notes.iter().filter(|(_, on)| *on).count();
        let offs = notes.iter().filter(|(_, on)| !*on).count();
        assert_eq!(ons, 8, "two passes of four notes, nothing past the end");
        assert_eq!(offs, 8, "every note is released, including the last");
        assert_eq!(notes.last(), Some(&(65, false)));
    }
}
