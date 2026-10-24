//! Per-buffer audio processing: live MIDI, automation, transport, clip MIDI and audio clips.

mod clip_audio;
mod clip_midi;
mod live_midi;
mod timeline;

use std::time::Instant;

pub use timeline::frames_before_tick;

use clip_audio::{render_audio_clips, BufferSpan};
use clip_midi::dispatch_clip_midi;
use live_midi::schedule_live_midi_events;
use timeline::collect_tick_events_looped;

use super::devices::apply_transport;
use super::rt_debug;
use super::state::EngineState;
use super::tempo_map::fill_tick_rates;
use super::transport::Transport;

/// Process audio for one buffer. `callback_start` is when the audio callback fired and is
/// used to place live MIDI within the buffer.
pub fn process_audio(
    state: &mut EngineState,
    frames: usize,
    sample_rate: f32,
    callback_start: Instant,
) {
    // Always schedule incoming MIDI events (even when not playing)
    // This allows live MIDI input to play instruments without transport running
    rt_debug::section("live MIDI scheduling", || {
        schedule_live_midi_events(&mut state.channels, callback_start, frames, sample_rate)
    });

    // Resolve automation before the transport check, so a seek while stopped still applies
    // (REQ-008). When the tick has not moved the per-lane dedup makes this nearly free.
    let automation_tick = state.get_current_tick();
    rt_debug::section("automation", || {
        super::automation::apply_automation(&mut state.tracks, &mut state.channels, automation_tick)
    });

    let is_playing = state.get_is_playing();
    let start_tick = state.get_current_tick();
    let acc = state.get_fractional_tick_accumulator();
    let start_acc = acc;

    // Devices see the transport every block, playing or not
    let mut transport = Transport::at(
        &state.tempo_map,
        &state.time_signature_map,
        &state.settings,
        start_tick as f64 + acc,
        sample_rate,
        is_playing,
    );
    // Mask at the block's first frame, from the integer playhead tick — playing or stopped, so a
    // seek while stopped puts the keyboard on the playhead's key (spec 034, Gotcha 5).
    transport.scale_mask = state
        .scale_map
        .mask_at(start_tick, state.settings.scale_mask);

    // Collect the tick events before apply_transport (Gotcha 3): the transport must carry the key
    // changes those events fall on before any device sees it. Nothing in between (fill_tick_rates,
    // playhead dispatch) depends on devices having the transport.
    let mut tick_rates = std::mem::take(&mut state.render_scratch.frame_tick_rates);
    let mut tick_events = std::mem::take(&mut state.render_scratch.tick_events);
    let mut loop_wraps = std::mem::take(&mut state.render_scratch.loop_wraps);
    let mut note_events = std::mem::take(&mut state.render_scratch.note_events);
    let loop_region = state.loop_region;
    if is_playing {
        // Per-frame tick rates from the tempo map. Uses the real device rate, not the project's.
        // Frames past the preallocated capacity reuse the last rate rather than allocating.
        let rate_frames = frames.min(tick_rates.capacity());
        fill_tick_rates(
            &state.tempo_map,
            &state.settings,
            start_tick as f64 + start_acc,
            rate_frames,
            sample_rate,
            &mut tick_rates,
        );

        // Precompute tick boundaries within this buffer with frame offsets.
        // Reuse preallocated scratch lists so the audio thread doesn't allocate.
        let emit_playhead = state.take_playhead_midi_dispatch();
        let (tick_cursor, acc) = rt_debug::section("tick events", || {
            collect_tick_events_looped(
                start_tick,
                start_acc,
                frames,
                &tick_rates,
                emit_playhead,
                loop_region,
                &mut tick_events,
                &mut loop_wraps,
            )
        });

        // Update global tick and carry fractional forward
        state.set_current_tick(tick_cursor);
        state.set_fractional_tick_accumulator(acc);

        // The block-start resolve above saw the loop end. Resolve again at each wrap, stamped at
        // its frame, so the notes at the loop start meet the loop start's values instead of
        // waiting a whole buffer for them.
        for &index in loop_wraps.iter() {
            let (wrap_tick, wrap_frame) = tick_events[index];
            super::automation::apply_automation_at(
                &mut state.tracks,
                &mut state.channels,
                wrap_tick,
                wrap_frame,
            );
        }
    } else {
        // Nothing plays while stopped, so no in-block key changes apply this block.
        tick_events.clear();
    }

    // Fill the per-block key-change timeline (no-op while the map is empty), then hand the
    // transport to the devices exactly once.
    timeline::fill_scale_changes(
        &state.scale_map,
        state.settings.scale_mask,
        &tick_events,
        &mut transport,
    );
    for channel in state.channels.values_mut() {
        apply_transport(&mut channel.devices, &transport);
    }

    // Only advance playhead and process clips when playing
    if !is_playing {
        state.render_scratch.frame_tick_rates = tick_rates;
        state.render_scratch.tick_events = tick_events;
        state.render_scratch.loop_wraps = loop_wraps;
        state.render_scratch.note_events = note_events;
        return;
    }

    // Dispatch MIDI for each tick event at its exact frame offset
    rt_debug::section("clip MIDI", || {
        dispatch_clip_midi(
            &state.tracks,
            &state.clips,
            &mut state.channels,
            &tick_events,
            &loop_wraps,
            &mut note_events,
        )
    });
    state.render_scratch.tick_events = tick_events;
    state.render_scratch.loop_wraps = loop_wraps;
    state.render_scratch.note_events = note_events;

    // Generate audio clip content per frame while advancing a local tick cursor
    rt_debug::section("audio clip render", || {
        render_audio_clips(
            &mut state.tracks,
            &state.clips,
            &mut state.channels,
            &state.settings,
            &state.tempo_map,
            state.device_sample_rate,
            &tick_rates,
            BufferSpan {
                start_tick,
                start_acc,
                frames,
                loop_region,
                sample_rate,
            },
        )
    });
    state.render_scratch.frame_tick_rates = tick_rates;
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::audio::channel::Channel;

    use crate::audio::devices::{DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};

    /// Device that records the last transport it was given.
    struct TransportRecorder {
        seen: std::sync::Arc<std::sync::Mutex<Option<Transport>>>,
    }

    impl crate::audio::devices::AudioDevice for TransportRecorder {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            None
        }
        fn set_transport(&mut self, transport: &Transport) {
            *self.seen.lock().unwrap() = Some(*transport);
        }
        fn device_id(&self) -> &str {
            "test.transport"
        }
        fn device_name(&self) -> &str {
            "Transport"
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

    /// End-to-end key change (spec 034 E-006): base C major, D minor from bar 3 (tick 7680).
    /// A B (71) sits on bar 2 beat 1 and on bar 3 beat 1 — B is a bad probe in C# (it would snap
    /// to C in both keys); here B stays B under C major and snaps down to Bb under D minor.
    /// Identical at every block size, including one where the change lands mid-block (2048).
    #[test]
    fn key_change_snaps_clip_notes_at_all_block_sizes() {
        use crate::audio::clip::{Clip, ClipInstance, ClipNote, ClipType};
        use crate::audio::devices::note_fx::scale::mask_for;
        use crate::audio::devices::note_fx::transpose::Transpose;
        use crate::audio::devices::note_fx::transpose::SCALE;
        use crate::audio::devices::note_fx::NoteFxHost;
        use crate::audio::devices::{AudioDevice, DeviceCategory, DeviceVariant};
        use crate::audio::midi_types::NoteEvent;
        use crate::audio::scale_map::ScaleMap;
        use crate::audio::track::Track;

        const C_MAJOR: u16 = 2741; // mask_for(0, 0)
        const D_MINOR: u16 = 1717; // mask_for(2, 1)
        const CHANGE_TICK: i64 = 7680; // bar 3, beat 1 (4/4, 960 PPQ)

        let run = |block: usize| -> Vec<(u8, bool, i64)> {
            let mut state = EngineState::default();
            state.settings.scale_mask = C_MAJOR;
            state.scale_map = ScaleMap::from_changes(vec![(CHANGE_TICK, D_MINOR)]);

            let mut channel = Channel::new(2, "Inst".to_string(), block, 48_000.0);
            let mut fx = NoteFxHost::<Transpose>::new(48_000.0);
            // "Follow Project" is choice 1 of 3, so norm = 1/2.
            fx.set_parameter(SCALE, 0.5);
            channel.devices.push(Box::new(fx));
            // Records the transposed notes the note effect routes downstream.
            let (tx, rx) = std::sync::mpsc::channel::<(usize, NoteEvent)>();
            struct Recorder {
                tx: std::sync::mpsc::Sender<(usize, NoteEvent)>,
            }
            impl crate::audio::devices::AudioDevice for Recorder {
                fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], n: usize) {
                    crate::audio::devices::container::copy_interleaved(inputs, outputs, n);
                }
                fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
                    let _ = self.tx.send((frame_offset, *event));
                }
                fn set_parameter(&mut self, _id: ParamId, _v: ParamValue) {}
                fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
                    None
                }
                fn device_id(&self) -> &str {
                    "test.key_change"
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
            channel.devices.push(Box::new(Recorder { tx }));
            state.channels.insert(2, channel);

            let mut clip = Clip::new("c".to_string(), "c".to_string(), ClipType::Midi);
            clip.midi_notes = vec![
                ClipNote {
                    id: 1,
                    note: 71, // B
                    velocity: 0.8,
                    release: crate::audio::DEFAULT_RELEASE,
                    start_tick: 3840, // bar 2 beat 1
                    duration_ticks: 480,
                },
                ClipNote {
                    id: 2,
                    note: 71,
                    velocity: 0.8,
                    release: crate::audio::DEFAULT_RELEASE,
                    start_tick: 7680, // bar 3 beat 1: D minor from here
                    duration_ticks: 480,
                },
            ];
            clip.content_length_ticks = 9600;
            state.clips.insert("c".to_string(), clip);
            let mut track = Track::new(1, 2);
            track.clip_instances.push(ClipInstance::new(
                "i".to_string(),
                "c".to_string(),
                0,
                15360,
            ));
            state.tracks.insert(1, track);

            state.set_is_playing(true);
            state.request_playhead_midi_dispatch();
            state.ensure_master_channel(block);
            let (status_tx, _status_rx) = crossbeam::channel::unbounded();
            let mut out = vec![0.0f32; block * 2];
            let mut seen: Vec<(u8, bool, i64)> = Vec::new();
            let mut frames_played = 0i64;
            while state.get_current_tick() < 9600 {
                process_audio(&mut state, block, 48_000.0, Instant::now());
                crate::audio::mixing::mix_and_output(&mut state, &mut out, 2, block, &status_tx);
                while let Ok((frame, event)) = rx.try_recv() {
                    seen.push((
                        event.key(),
                        matches!(event, NoteEvent::On { .. }),
                        frames_played + frame as i64,
                    ));
                }
                frames_played += block as i64;
            }

            let ons: Vec<(u8, i64)> = seen
                .iter()
                .filter(|(_, on, _)| *on)
                .map(|&(k, _, f)| (k, f))
                .collect();
            assert_eq!(ons.len(), 2, "block {block}: {seen:?}");
            // Bar 2: B in C major. Bar 3: the same B snaps down to Bb in D minor.
            assert_eq!(ons[0].0, 71, "block {block}");
            assert_eq!(ons[1].0, 70, "block {block}");
            // The key change tick is at frame 192000: the note-on must land there (the
            // accumulator can round to one sample early), with the correct key, whatever the
            // block size.
            assert!(
                (ons[1].1 - 192_000).abs() <= 1,
                "block {block}: {}",
                ons[1].1
            );
            seen
        };

        for block in [64usize, 512, 2048] {
            run(block);
        }
    }

    /// A loop wrap inside the block resolves automation again at the loop start, stamped at the
    /// wrap's frame: the notes there must not hear the loop end's value for the rest of the block.
    #[test]
    fn loop_wrap_reapplies_automation_at_the_wrap_frame() {
        use crate::audio::automation::{
            AutomationLane, AutomationPoint, AutomationTarget, CurveKind,
        };
        use crate::audio::devices::DevicePath;
        use crate::audio::track::Track;

        type Applied = std::sync::Arc<std::sync::Mutex<Vec<(f32, usize)>>>;
        struct Stamped {
            value: f32,
            applied: Applied,
        }
        impl crate::audio::devices::AudioDevice for Stamped {
            fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _n: usize) {}
            fn set_parameter(&mut self, _id: ParamId, value: ParamValue) {
                self.value = value;
            }
            fn set_parameter_at(&mut self, _id: ParamId, value: ParamValue, frame: usize) {
                self.value = value;
                self.applied.lock().unwrap().push((value, frame));
            }
            fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
                Some(self.value)
            }
            fn device_id(&self) -> &str {
                "test.stamped"
            }
            fn device_name(&self) -> &str {
                "Stamped"
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

        const BLOCK: usize = 2048;
        let mut state = EngineState::default();
        let applied = Applied::default();
        let mut channel = Channel::new(2, "Inst".to_string(), BLOCK, 48_000.0);
        channel.devices.push(Box::new(Stamped {
            value: 0.5,
            applied: applied.clone(),
        }));
        state.channels.insert(2, channel);

        // Cutoff-style ramp: low at the loop start, high at its end.
        let mut lane = AutomationLane::new(
            "cutoff".to_string(),
            AutomationTarget::DeviceParam {
                device_path: DevicePath::root(0),
                param_id: 0,
            },
        );
        for (id, tick, value) in [(1, 0, 0.0), (2, 3840, 1.0)] {
            lane.insert_point(AutomationPoint::new(
                id,
                tick,
                value,
                CurveKind::Linear,
                0.0,
            ));
        }
        let mut track = Track::new(1, 2);
        track.automation_lanes.push(lane);
        state.tracks.insert(1, track);

        // 120 BPM: 2048 frames is ~82 ticks, so a block starting 40 ticks before the loop end
        // wraps about halfway through.
        state.loop_region = Some((0, 3840));
        state.set_current_tick(3800);
        state.set_is_playing(true);
        process_audio(&mut state, BLOCK, 48_000.0, Instant::now());

        let applied = applied.lock().unwrap().clone();
        assert_eq!(applied.len(), 2, "{applied:?}");
        assert_eq!(applied[0].1, 0, "block start: {applied:?}");
        assert!(applied[0].0 > 0.9, "the loop end is high: {applied:?}");
        let (value, frame) = applied[1];
        assert!(value < 0.01, "the loop start is low: {applied:?}");
        assert!(
            frame > 0 && frame < BLOCK,
            "stamped at the wrap: {applied:?}"
        );
    }
}
