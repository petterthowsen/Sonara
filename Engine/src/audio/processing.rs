use std::time::Instant;

use super::clip::AudioPlayback;
use super::commands::EngineState;
use super::devices::apply_transport;
use super::dsp::gain::db_to_gain;
use super::render_scratch::ClipNoteEvent;
use super::rt_debug;
use super::tempo_map::fill_tick_rates;
use super::transport::Transport;
use super::types::*;

/// Drain each channel's live MIDI queue into `scheduled_midi_events` with frame offsets.
///
/// Live input plays with a fixed latency of one buffer: an event that arrived `dt` before
/// this callback fired lands `dt` before the end of this buffer. This keeps the spacing
/// between events instead of snapping them all to frame 0. Events older than one buffer
/// (held up on the way in) play at frame 0.
fn schedule_live_midi_events(
    state: &mut EngineState,
    callback_start: Instant,
    frame_count: usize,
    sample_rate: f32,
) {
    let last_frame = frame_count.saturating_sub(1);

    for channel in state.channels.values_mut() {
        channel.scheduled_midi_events.clear();

        // Queue order is arrival order, so offsets come out ascending and need no sort
        while let Some(mut event) = channel.midi_queue.pop() {
            let age_frames = callback_start
                .saturating_duration_since(event.received_at)
                .as_secs_f64()
                * sample_rate as f64;
            let frame_offset = (frame_count as f64 - age_frames).round().max(0.0) as usize;
            event.frame_offset = frame_offset.min(last_frame);
            channel.scheduled_midi_events.push(event);
        }
    }
}

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
        schedule_live_midi_events(state, callback_start, frames, sample_rate)
    });

    // Resolve automation before the transport check, so a seek while stopped still applies
    // (REQ-008). When the tick has not moved the per-lane dedup makes this nearly free.
    rt_debug::section("automation", || {
        super::automation::apply_automation(state, state.get_current_tick())
    });

    let is_playing = state.get_is_playing();
    let start_tick = state.get_current_tick();
    let acc = state.get_fractional_tick_accumulator();
    let start_acc = acc;

    // Devices see the transport every block, playing or not
    let transport = Transport::at(
        &state.tempo_map,
        &state.time_signature_map,
        &state.settings,
        start_tick as f64 + acc,
        sample_rate,
        is_playing,
    );
    for channel in state.channels.values_mut() {
        apply_transport(&mut channel.devices, &transport);
    }

    // Only advance playhead and process clips when playing
    if !is_playing {
        return;
    }

    // Per-frame tick rates from the tempo map. Uses the real device rate, not the project's.
    // Frames past the preallocated capacity reuse the last rate rather than allocating.
    let mut tick_rates = std::mem::take(&mut state.render_scratch.frame_tick_rates);
    let rate_frames = frames.min(tick_rates.capacity());
    fill_tick_rates(
        &state.tempo_map,
        &state.settings,
        start_tick as f64 + acc,
        rate_frames,
        sample_rate,
        &mut tick_rates,
    );

    // Precompute tick boundaries within this buffer with frame offsets
    // Reuse preallocated scratch lists so the audio thread doesn't allocate
    let mut tick_events = std::mem::take(&mut state.render_scratch.tick_events);
    let mut note_events = std::mem::take(&mut state.render_scratch.note_events);
    let emit_playhead = state.take_playhead_midi_dispatch();
    let loop_region = state.loop_region;
    let mut loop_wraps = std::mem::take(&mut state.render_scratch.loop_wraps);
    let (tick_cursor, acc) = rt_debug::section("tick events", || {
        collect_tick_events_looped(
            start_tick,
            acc,
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

    // Dispatch MIDI for each tick event at its exact frame offset
    rt_debug::section("clip MIDI", || {
        let mut next_wrap = 0;
        for (event_idx, &(current_tick, frame_offset)) in tick_events.iter().enumerate() {
            // A loop wrap ends every clip note still sounding, at the wrap frame, before the
            // note-ons at the loop start
            if loop_wraps.get(next_wrap) == Some(&event_idx) {
                next_wrap += 1;
                for channel in state.channels.values_mut() {
                    channel.release_clip_notes_at(frame_offset);
                }
            }

            // Collect note on/off events from clip instances
            note_events.clear();

            for (track_id, track) in &state.tracks {
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
                        if let Some(clip) = state.clips.get(&instance.clip_id) {
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
                            let just_wrapped = content_pos != unwrapped_pos
                                && content_pos == instance.loop_start_ticks;

                            // A loop wrap ends every note still sounding at the loop end. Sent
                            // before the note-ons so a note restarting on the same pitch wins.
                            if just_wrapped && is_within_instance {
                                let loop_end =
                                    instance.loop_start_ticks + instance.loop_length_ticks;
                                for clip_note in &clip.midi_notes {
                                    if clip_note.start_tick < loop_end
                                        && clip_note.start_tick + clip_note.duration_ticks
                                            >= loop_end
                                    {
                                        let transposed_note = (clip_note.note as i16
                                            + instance.transpose as i16)
                                            .clamp(0, 127)
                                            as MidiNote;
                                        note_events.push(ClipNoteEvent {
                                            track_id: *track_id,
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
                                let transposed_note = (clip_note.note as i16
                                    + instance.transpose as i16)
                                    .clamp(0, 127)
                                    as MidiNote;

                                // Note On
                                if is_within_instance && clip_note.start_tick == content_pos {
                                    note_events.push(ClipNoteEvent {
                                        track_id: *track_id,
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
                                let note_off_clipped_to_instance = is_at_instance_end
                                    && clip_note.start_tick < content_pos
                                    && note_end > content_pos;
                                if note_off_at_written_end || note_off_clipped_to_instance {
                                    note_events.push(ClipNoteEvent {
                                        track_id: *track_id,
                                        clip_note_id: clip_note.id,
                                        key: transposed_note,
                                        velocity: clip_note.velocity,
                                        release: clip_note.release,
                                        is_on: false,
                                    });
                                }
                            }
                        }
                    }
                }
            }

            for event in &note_events {
                if let Some(track) = state.tracks.get_mut(&event.track_id) {
                    if let Some(channel) = state.channels.get_mut(&track.channel_id) {
                        channel.send_clip_note(event, frame_offset);
                    }
                }
            }
        }
    });
    state.render_scratch.tick_events = tick_events;
    state.render_scratch.loop_wraps = loop_wraps;
    state.render_scratch.note_events = note_events;

    // Generate audio clip content per frame while advancing a local tick cursor
    rt_debug::section("audio clip render", || {
        let mut render_tick = start_tick;
        let mut render_acc = start_acc;
        for frame_idx in 0..frames {
            // Advance local tick based on ticks_per_sample
            let frame_rate = frame_rate_at(&tick_rates, frame_idx);
            render_acc += frame_rate;
            if render_acc >= 1.0 {
                let inc = render_acc.floor() as Tick;
                let (next, wrapped) = advance_tick(render_tick, inc, loop_region);
                render_tick = next;
                render_acc -= inc as f64;
                if wrapped {
                    // Audio clips re-seat at the loop start like after a seek
                    for track in state.tracks.values_mut() {
                        for instance in &mut track.clip_instances {
                            instance.playback_position = None;
                        }
                    }
                }
            }

            let current_tick = render_tick;
            let frame_bpm = frame_rate * 60.0 * sample_rate as f64 / state.settings.ppq as f64;

            // Generate audio from each track
            for track in state.tracks.values_mut() {
                let mut sample_left = 0.0;
                let mut sample_right = 0.0;

                // Note: MIDI audio is now generated by the channel's instrument device (if present)
                // Tracks no longer hold active voices - they only route MIDI to channels

                // Process audio clips on this track
                for instance in track.clip_instances.iter_mut() {
                    if instance.muted {
                        continue;
                    }

                    if let Some(clip) = state.clips.get(&instance.clip_id) {
                        if clip.clip_type == super::clip::ClipType::Audio
                            && !clip.audio_samples.is_empty()
                        {
                            let current_pos_in_instance = current_tick - instance.start_tick;
                            // A clip without a recorded BPM plays 1:1 at the project tempo
                            let recorded_bpm = if clip.recorded_bpm > 0.0 {
                                clip.recorded_bpm
                            } else {
                                state.settings.tempo
                            };

                            // Check if we're in the playback range for this instance
                            if current_pos_in_instance >= 0
                                && current_pos_in_instance < instance.duration_ticks
                            {
                                // Initialize playback position for this clip instance if not yet started
                                // Apply clip_offset: start reading from the offset position in the clip
                                // PLUS account for seeking into the middle of the instance
                                if instance.playback_position.is_none() {
                                    // Total offset = clip_offset (trim) + current position in instance (seek)
                                    let total_offset_ticks = instance.wrap_content_tick(
                                        instance.clip_offset + current_pos_in_instance,
                                    );

                                    // Convert total offset (ticks) to sample index in the clip's sample-rate domain
                                    instance.playback_position =
                                        Some(AudioPlayback::clip_source_frame(
                                            total_offset_ticks,
                                            recorded_bpm,
                                            state.settings.ppq,
                                            clip.audio_sample_rate as f64,
                                        ));
                                }

                                // Get mutable reference to playback position
                                let Some(playback_pos) = instance.playback_position.as_mut() else {
                                    continue;
                                };

                                // Source frames to advance this frame at the tempo playing now
                                let advance_per_sample = AudioPlayback::clip_advance_per_frame(
                                    frame_bpm,
                                    recorded_bpm,
                                    clip.audio_sample_rate as f64,
                                    state.device_sample_rate as f64,
                                );

                                let clip_sample_len =
                                    (clip.audio_samples.len() / clip.audio_channels) as f64;

                                // A reversed instance reads the source mirrored around its centre,
                                // while the playback position (and any loop wrap) still advances
                                // forward in content time.
                                let read_pos = if instance.reverse {
                                    AudioPlayback::reverse_source_frame(
                                        *playback_pos,
                                        clip_sample_len,
                                    )
                                } else {
                                    *playback_pos
                                };

                                // Get the current interpolated sample
                                let sample_idx = read_pos.floor() as usize;
                                let frac = (read_pos.fract()) as f32;

                                if sample_idx < clip_sample_len as usize {
                                    let interleaved_idx = sample_idx * clip.audio_channels;
                                    let next_idx = sample_idx + 1;
                                    let interleaved_idx_next =
                                        if next_idx < clip_sample_len as usize {
                                            next_idx * clip.audio_channels
                                        } else {
                                            interleaved_idx
                                        };

                                    // Linear interpolation for left channel
                                    if interleaved_idx < clip.audio_samples.len() {
                                        let s0_left = clip.audio_samples[interleaved_idx];
                                        let s1_left = if interleaved_idx_next
                                            < clip.audio_samples.len()
                                            && interleaved_idx_next != interleaved_idx
                                        {
                                            clip.audio_samples[interleaved_idx_next]
                                        } else {
                                            s0_left
                                        };
                                        sample_left += s0_left + frac * (s1_left - s0_left);
                                    }

                                    // Linear interpolation for right channel
                                    if clip.audio_channels > 1
                                        && interleaved_idx + 1 < clip.audio_samples.len()
                                    {
                                        let s0_right = clip.audio_samples[interleaved_idx + 1];
                                        let s1_right = if interleaved_idx_next + 1
                                            < clip.audio_samples.len()
                                            && interleaved_idx_next != interleaved_idx
                                        {
                                            clip.audio_samples[interleaved_idx_next + 1]
                                        } else {
                                            s0_right
                                        };
                                        sample_right += s0_right + frac * (s1_right - s0_right);
                                    } else if clip.audio_channels == 1 {
                                        // Mono: duplicate the interpolated left sample for right
                                        sample_right += sample_left;
                                    }

                                    // Apply gain offset
                                    let gain_linear = db_to_gain(instance.gain_offset);
                                    sample_left *= gain_linear;
                                    sample_right *= gain_linear;
                                }

                                // Advance playback position for next frame
                                *playback_pos += advance_per_sample;

                                // Handle looping
                                if instance.loop_enabled && instance.loop_length_ticks > 0 {
                                    let clip_sr = clip.audio_sample_rate as f64;
                                    let ppq = state.settings.ppq;
                                    let loop_start_samples = AudioPlayback::clip_source_frame(
                                        instance.loop_start_ticks,
                                        recorded_bpm,
                                        ppq,
                                        clip_sr,
                                    );
                                    let loop_length_samples = AudioPlayback::clip_source_frame(
                                        instance.loop_length_ticks,
                                        recorded_bpm,
                                        ppq,
                                        clip_sr,
                                    );

                                    if loop_length_samples > 0.0
                                        && *playback_pos >= loop_start_samples + loop_length_samples
                                    {
                                        let offset_in_loop = *playback_pos - loop_start_samples;
                                        *playback_pos = loop_start_samples
                                            + (offset_in_loop % loop_length_samples);
                                    }
                                }
                            } else if current_pos_in_instance < 0 {
                                // Not yet at clip start, ensure position is reset
                                instance.playback_position = None;
                            } else {
                                // Past clip end, remove position tracking
                                instance.playback_position = None;
                            }
                        }
                    }
                }

                // Write to track's channel
                if let Some(channel) = state.channels.get_mut(&track.channel_id) {
                    if frame_idx < channel.buffer_left.len() {
                        channel.buffer_left[frame_idx] += sample_left;
                        channel.buffer_right[frame_idx] += sample_right;
                    }
                }
            }
        }

        // Log playhead position every bar for debugging - disabled for real-time safety
        // let ticks_per_bar = state.settings.ppq as i64 * state.settings.time_numerator as i64;
        // let final_tick = state.get_current_tick();
    });
    state.render_scratch.frame_tick_rates = tick_rates;
}

/// Frames the transport can play from the current playhead (at most `max_frames`) before
/// `target`'s MIDI would be dispatched. Runs the same tick arithmetic as `process_audio`, so
/// stopping after that many frames plays everything before `target` and nothing at it. The
/// offline renderer uses it to end a range exactly; it allocates into the given scratch.
pub fn frames_before_tick(
    state: &EngineState,
    target: Tick,
    max_frames: usize,
    sample_rate: f32,
    rates: &mut Vec<f64>,
    events: &mut Vec<(Tick, usize)>,
) -> usize {
    let start_tick = state.get_current_tick();
    if start_tick >= target {
        return 0;
    }
    let acc = state.get_fractional_tick_accumulator();
    fill_tick_rates(
        &state.tempo_map,
        &state.settings,
        start_tick as f64 + acc,
        max_frames,
        sample_rate,
        rates,
    );
    // The start tick itself is below `target`, so whether it's re-emitted doesn't matter.
    collect_tick_events(start_tick, acc, max_frames, rates, false, events);
    events
        .iter()
        .find(|&&(tick, _)| tick >= target)
        .map_or(max_frames, |&(_, frame)| frame)
}

/// Tick rate for `frame_idx`, holding the last rate for frames past the preallocated slice.
fn frame_rate_at(rates: &[f64], frame_idx: usize) -> f64 {
    rates
        .get(frame_idx)
        .or_else(|| rates.last())
        .copied()
        .unwrap_or(0.0)
}

/// Record each newly crossed tick and its sample offset inside this buffer.
///
/// The playhead tick is only emitted after play/seek (`emit_start_tick`). Later buffers must
/// not emit it again: it was already the last tick of the previous buffer, and re-firing it
/// double-triggers note on/off at buffer boundaries.
fn collect_tick_events(
    start_tick: Tick,
    acc: f64,
    frame_count: usize,
    tick_rates: &[f64],
    emit_start_tick: bool,
    tick_events: &mut Vec<(Tick, usize)>,
) -> (Tick, f64) {
    collect_tick_events_looped(
        start_tick,
        acc,
        frame_count,
        tick_rates,
        emit_start_tick,
        None,
        tick_events,
        &mut Vec::new(),
    )
}

/// Advance `tick` by `inc`, folding a crossing of the loop end back to the loop start. A
/// playhead already at or past the loop end plays on without wrapping. Returns the new tick
/// and whether it wrapped. `process_audio` and the per-frame clip render both use this, so
/// they always agree on where the loop wraps.
fn advance_tick(tick: Tick, inc: Tick, loop_region: Option<(Tick, Tick)>) -> (Tick, bool) {
    let next = tick + inc;
    match loop_region {
        Some((start, end)) if tick < end && next >= end => (start + (next - end), true),
        _ => (next, false),
    }
}

/// `collect_tick_events` that also wraps at `loop_region`. The first event after each wrap
/// is the loop start; its index in `tick_events` goes into `loop_wraps` (extras past the
/// vec's capacity are dropped, so nothing allocates).
fn collect_tick_events_looped(
    start_tick: Tick,
    mut acc: f64,
    frame_count: usize,
    tick_rates: &[f64],
    emit_start_tick: bool,
    loop_region: Option<(Tick, Tick)>,
    tick_events: &mut Vec<(Tick, usize)>,
    loop_wraps: &mut Vec<usize>,
) -> (Tick, f64) {
    tick_events.clear();
    loop_wraps.clear();
    if emit_start_tick {
        tick_events.push((start_tick, 0));
    }
    let mut tick_cursor = start_tick;
    for frame_idx in 0..frame_count {
        acc += frame_rate_at(tick_rates, frame_idx);
        while acc >= 1.0 {
            acc -= 1.0;
            let (next, wrapped) = advance_tick(tick_cursor, 1, loop_region);
            tick_cursor = next;
            if wrapped && loop_wraps.len() < loop_wraps.capacity() {
                loop_wraps.push(tick_events.len());
            }
            tick_events.push((tick_cursor, frame_idx));
        }
    }
    (tick_cursor, acc)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::channel::Channel;
    use crate::audio::clip::{Clip, ClipInstance, ClipNote, ClipType};
    use crate::audio::commands::AudioCommand;
    use crate::audio::devices::{DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
    use crate::audio::midi_types::{MidiEvent, NoteEvent};
    use crate::audio::project::ProjectSettings;
    use crate::audio::tempo_map::TempoMap;
    use crate::audio::track::Track;
    use std::time::Duration;

    /// Build a state with one channel holding note-ons that arrived `ages_ms` before `now`.
    fn state_with_events(now: Instant, ages_ms: &[u64]) -> EngineState {
        let mut state = EngineState::default();
        let channel = Channel::new(2, "Synth".to_string(), 1024, 48_000.0);
        for &age in ages_ms {
            let received_at = now - Duration::from_millis(age);
            channel
                .midi_queue
                .push(MidiEvent::note_on(0, 60, 100, received_at));
        }
        state.channels.insert(2, channel);
        state
    }

    /// Offsets of the events scheduled on the test channel.
    fn scheduled_offsets(state: &EngineState) -> Vec<usize> {
        state.channels[&2]
            .scheduled_midi_events
            .iter()
            .map(|e| e.frame_offset)
            .collect()
    }

    fn looped_ticks(
        start: Tick,
        frames: usize,
        loop_region: Option<(Tick, Tick)>,
    ) -> (Vec<Tick>, Vec<usize>, Tick) {
        let mut events = Vec::with_capacity(64);
        let mut wraps = Vec::with_capacity(8);
        let (end, _) = collect_tick_events_looped(
            start,
            0.0,
            frames,
            &[1.0],
            true,
            loop_region,
            &mut events,
            &mut wraps,
        );
        (events.iter().map(|e| e.0).collect(), wraps, end)
    }

    #[test]
    fn loop_wraps_on_the_exact_frame_and_never_reaches_the_end() {
        let (ticks, wraps, end) = looped_ticks(0, 8, Some((0, 4)));
        assert_eq!(ticks, vec![0, 1, 2, 3, 0, 1, 2, 3, 0]);
        assert_eq!(wraps, vec![4, 8]);
        assert_eq!(end, 0);
    }

    #[test]
    fn loop_wrap_events_carry_the_frame_of_the_wrap() {
        let mut events = Vec::with_capacity(64);
        let mut wraps = Vec::with_capacity(8);
        collect_tick_events_looped(
            0,
            0.0,
            8,
            &[1.0],
            false,
            Some((2, 5)),
            &mut events,
            &mut wraps,
        );
        // Tick 5 is reached on frame 4 and folds to the loop start
        assert_eq!(events[wraps[0]], (2, 4));
    }

    #[test]
    fn playhead_past_the_loop_end_plays_on_and_loop_off_never_wraps() {
        let (ticks, wraps, _) = looped_ticks(10, 3, Some((0, 4)));
        assert_eq!(ticks, vec![10, 11, 12, 13]);
        assert!(wraps.is_empty());

        let (ticks, wraps, _) = looped_ticks(0, 6, None);
        assert_eq!(ticks, vec![0, 1, 2, 3, 4, 5, 6]);
        assert!(wraps.is_empty());
    }

    #[test]
    fn advance_tick_keeps_the_overshoot_after_a_multi_tick_step() {
        assert_eq!(advance_tick(3, 1, Some((0, 5))), (4, false));
        assert_eq!(advance_tick(3, 4, Some((1, 5))), (3, true));
    }

    #[test]
    fn set_loop_command_enables_and_clears_the_region() {
        let mut state = EngineState::default();
        let (tx, _rx) = crossbeam::channel::unbounded();
        let apply = |state: &mut EngineState, enabled, start, end| {
            crate::audio::commands::process_command(
                state,
                AudioCommand::SetLoop {
                    enabled,
                    start,
                    end,
                },
                64,
                &tx,
            );
        };
        apply(&mut state, true, 960, 1920);
        assert_eq!(state.loop_region, Some((960, 1920)));
        apply(&mut state, false, 960, 1920);
        assert_eq!(state.loop_region, None);
        apply(&mut state, true, 960, 960);
        assert_eq!(state.loop_region, None);
    }

    #[test]
    fn live_midi_keeps_spacing_within_buffer() {
        let now = Instant::now();
        // 480 frames = 10 ms at 48 kHz
        let mut state = state_with_events(now, &[10, 5, 1]);
        schedule_live_midi_events(&mut state, now, 480, 48_000.0);
        assert_eq!(scheduled_offsets(&state), vec![0, 240, 432]);
    }

    #[test]
    fn stale_and_just_arrived_live_midi_are_clamped() {
        let now = Instant::now();
        let mut state = state_with_events(now, &[50, 0]);
        schedule_live_midi_events(&mut state, now, 480, 48_000.0);
        assert_eq!(scheduled_offsets(&state), vec![0, 479]);
    }

    #[test]
    fn consecutive_buffers_do_not_redispatch_the_boundary_tick() {
        // 0.04 ticks/sample × 256 frames = 10.24 ticks, matching 120 BPM / 960 PPQ / 48 kHz.
        let frames = 256;
        let rates = vec![0.04; frames];
        let mut events = Vec::new();

        let (tick1, acc1) = collect_tick_events(0, 0.0, frames, &rates, true, &mut events);
        let first: Vec<Tick> = events.iter().map(|(t, _)| *t).collect();
        assert_eq!(first.first().copied(), Some(0));
        assert_eq!(*first.last().unwrap(), tick1);

        let (tick2, _acc2) = collect_tick_events(tick1, acc1, frames, &rates, false, &mut events);
        let second: Vec<Tick> = events.iter().map(|(t, _)| *t).collect();
        assert!(
            !second.contains(&tick1),
            "boundary tick {tick1} was dispatched again"
        );
        assert!(tick2 > tick1);
        assert_eq!(second.first().copied(), Some(tick1 + 1));
    }

    #[test]
    fn playhead_tick_is_only_emitted_when_requested() {
        let mut events = Vec::new();
        collect_tick_events(7680, 0.0, 1, &[0.04], false, &mut events);
        assert!(events.is_empty());

        collect_tick_events(7680, 0.0, 1, &[0.04], true, &mut events);
        assert_eq!(events[0], (7680, 0));
    }

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

    /// Run buffers of `chunk` frames through the tempo map until the playhead reaches
    /// `target_tick`, returning the frames used and every emitted tick.
    fn frames_to_reach(
        map: &TempoMap,
        settings: &ProjectSettings,
        target_tick: Tick,
    ) -> (usize, Vec<Tick>) {
        let chunk = 256;
        let (mut tick, mut acc, mut frames, mut first) = (0, 0.0, 0, true);
        let (mut rates, mut events, mut ticks) = (Vec::new(), Vec::new(), Vec::new());
        while tick < target_tick {
            fill_tick_rates(
                map,
                settings,
                tick as f64 + acc,
                chunk,
                48_000.0,
                &mut rates,
            );
            (tick, acc) = collect_tick_events(tick, acc, chunk, &rates, first, &mut events);
            first = false;
            ticks.extend(events.iter().map(|(t, _)| *t));
            frames += chunk;
        }
        (frames, ticks)
    }

    #[test]
    fn constant_60_bpm_beat_takes_48000_frames() {
        let settings = ProjectSettings {
            tempo: 60.0,
            ..ProjectSettings::default()
        };
        let (frames, _) = frames_to_reach(&TempoMap::default(), &settings, 960);
        assert!((frames as i64 - 48_000).abs() <= 256, "{frames}");
    }

    #[test]
    fn ramp_duration_matches_integral() {
        let map = TempoMap::from_points(vec![(0, 120.0), (3840, 60.0)]);
        let (frames, _) = frames_to_reach(&map, &ProjectSettings::default(), 3840);
        // 4 ln 2 s at 48 kHz = 133 084.6 frames, rounded up to whole 256-frame buffers
        assert!((frames as i64 - 133_084).abs() <= 256 + 4, "{frames}");
    }

    #[test]
    fn ramp_ticks_are_contiguous() {
        let map = TempoMap::from_points(vec![(0, 120.0), (3840, 60.0)]);
        let (_, ticks) = frames_to_reach(&map, &ProjectSettings::default(), 3840);
        assert!(ticks.windows(2).all(|w| w[1] == w[0] + 1));
    }

    #[test]
    fn clip_seek_is_tempo_independent() {
        // 960 ticks into a clip recorded at 120 BPM, whatever the project tempo
        for _project_bpm in [60.0, 120.0, 200.0] {
            assert_eq!(
                AudioPlayback::clip_source_frame(960, 120.0, 960, 48_000.0),
                24_000.0
            );
        }
    }

    #[test]
    fn reverse_reads_the_file_backwards() {
        // Position 0 is the last frame; the end clamps to the first frame.
        assert_eq!(AudioPlayback::reverse_source_frame(0.0, 1_000.0), 999.0);
        assert_eq!(AudioPlayback::reverse_source_frame(999.0, 1_000.0), 0.0);
        assert_eq!(AudioPlayback::reverse_source_frame(1_000.0, 1_000.0), 0.0);
    }

    /// One 64-frame buffer of a mono ramp clip on track 2, played at 1:1 (120 BPM, 48 kHz).
    fn render_ramp(reverse: bool) -> Vec<f32> {
        let mut state = EngineState::default();

        let mut clip = Clip::new("c".to_string(), "Ramp".to_string(), ClipType::Audio);
        clip.audio_samples = (0..200).map(|i| i as f32).collect();
        clip.audio_channels = 1;
        clip.audio_sample_rate = 48_000;
        clip.recorded_bpm = 120.0;
        clip.content_length_ticks = 960;
        state.clips.insert("c".to_string(), clip);

        let mut instance = ClipInstance::new("i".to_string(), "c".to_string(), 0, 960);
        instance.reverse = reverse;
        let mut track = Track::new(2, 2);
        track.clip_instances.push(instance);
        state.tracks.insert(2, track);
        state
            .channels
            .insert(2, Channel::new(2, "Audio".to_string(), 64, 48_000.0));

        state.set_is_playing(true);
        state.set_current_tick(0);
        state.set_fractional_tick_accumulator(0.0);
        process_audio(&mut state, 64, 48_000.0, Instant::now());
        state.channels.get(&2).unwrap().buffer_left.clone()
    }

    #[test]
    fn reverse_instance_plays_the_clip_backwards() {
        let forward = render_ramp(false);
        let backward = render_ramp(true);
        // 1:1 playback, so frame i reads source frame i forwards and 199 - i reversed.
        assert_eq!(forward[0], 0.0);
        assert_eq!(forward[63], 63.0);
        assert_eq!(backward[0], 199.0);
        assert_eq!(backward[63], 136.0);
    }

    #[test]
    fn clip_loop_bounds_on_clip_timeline() {
        // A one-beat loop of a 120 BPM clip wraps at 24 000 frames at 60 and 200 BPM alike
        let loop_len = AudioPlayback::clip_source_frame(960, 120.0, 960, 48_000.0);
        assert_eq!(loop_len, 24_000.0);
    }

    #[test]
    fn clip_rate_follows_tempo() {
        assert_eq!(
            AudioPlayback::clip_advance_per_frame(120.0, 120.0, 48_000.0, 48_000.0),
            1.0
        );
        assert_eq!(
            AudioPlayback::clip_advance_per_frame(60.0, 120.0, 48_000.0, 48_000.0),
            0.5
        );
        assert!(
            (AudioPlayback::clip_advance_per_frame(200.0, 120.0, 48_000.0, 48_000.0) - 5.0 / 3.0)
                .abs()
                < 1e-12
        );
    }

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

    #[test]
    fn devices_in_containers_receive_transport() {
        use crate::audio::devices::{ChainDevice, DeviceContainer};
        let seen = std::sync::Arc::new(std::sync::Mutex::new(None));
        let mut chain = ChainDevice::new(64);
        chain.insert_child(0, Box::new(TransportRecorder { seen: seen.clone() }));
        let mut state = EngineState::default();
        let mut channel = Channel::new(2, "Fx".to_string(), 64, 48_000.0);
        channel.devices.push(Box::new(chain));
        state.channels.insert(2, channel);
        state.set_current_tick(1920);

        // Stopped: the transport still arrives, with playing = false
        process_audio(&mut state, 64, 48_000.0, Instant::now());
        let t = seen.lock().unwrap().expect("transport delivered");
        assert!(!t.playing);
        assert!((t.song_pos_beats - 2.0).abs() < 1e-9);
        assert!((t.song_pos_seconds - 1.0).abs() < 1e-9);
    }
}
