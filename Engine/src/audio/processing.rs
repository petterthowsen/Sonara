use std::time::Instant;

use super::commands::EngineState;
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
    // IMPORTANT: Use actual device sample rate for timing, not project setting
    let ticks_per_sample =
        (state.settings.tempo as f64 * state.settings.ppq as f64) / (60.0 * sample_rate as f64);

    // Always schedule incoming MIDI events (even when not playing)
    // This allows live MIDI input to play instruments without transport running
    schedule_live_midi_events(state, callback_start, frames, sample_rate);

    // Only advance playhead and process clips when playing
    if !state.get_is_playing() {
        return;
    }

    // Precompute tick boundaries within this buffer with frame offsets
    let start_tick = state.get_current_tick();
    let mut tick_events: Vec<(Tick, usize)> = Vec::new();
    tick_events.push((start_tick, 0));

    let mut acc = state.get_fractional_tick_accumulator();
    let start_acc = acc;
    let mut tick_cursor = start_tick;
    for frame_idx in 0..frames {
        acc += ticks_per_sample;
        while acc >= 1.0 {
            acc -= 1.0;
            tick_cursor += 1;
            tick_events.push((tick_cursor, frame_idx));
        }
    }

    // Update global tick and carry fractional forward
    state.set_current_tick(tick_cursor);
    state.set_fractional_tick_accumulator(acc);

    // Dispatch MIDI for each tick event at its exact frame offset
    for (current_tick, frame_offset) in tick_events.into_iter() {
        // Collect note on/off events from clip instances
        let mut note_events: Vec<(TrackId, MidiNote, MidiVelocity, bool)> = Vec::new();

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
                        let mut offset_in_instance = current_tick - instance.start_tick;

                        // Debug: log when we're processing an instance
                        if current_tick % 960 == 0 {
                            // Log once per beat - disabled for real-time safety
                            // info!("Processing instance {} at tick {}: offset_in_instance={}, clip has {} notes",
                            //     instance.id, current_tick, offset_in_instance, clip.midi_notes.len());
                        }

                        // Handle looping
                        if instance.loop_enabled && instance.loop_length_ticks > 0 {
                            if offset_in_instance >= instance.loop_start_ticks {
                                let loop_offset = offset_in_instance - instance.loop_start_ticks;
                                offset_in_instance = instance.loop_start_ticks
                                    + (loop_offset % instance.loop_length_ticks);
                            }
                        }

                        for clip_note in &clip.midi_notes {
                            // Apply clip_offset
                            let note_start_in_instance =
                                clip_note.start_tick - instance.clip_offset;
                            let note_end_in_instance =
                                note_start_in_instance + clip_note.duration_ticks;

                            if note_end_in_instance <= 0 {
                                continue;
                            }

                            // Apply transpose
                            let transposed_note =
                                (clip_note.note as i16 + instance.transpose as i16).clamp(0, 127)
                                    as MidiNote;

                            // Note On
                            if is_within_instance && note_start_in_instance == offset_in_instance {
                                note_events.push((
                                    *track_id,
                                    transposed_note,
                                    clip_note.velocity,
                                    true,
                                ));
                            }

                            // Note Off (allow at instance end)
                            if note_end_in_instance == offset_in_instance {
                                note_events.push((
                                    *track_id,
                                    transposed_note,
                                    clip_note.velocity,
                                    false,
                                ));
                            }
                        }
                    }
                }
            }
        }

        for (track_id, note, velocity, is_on) in note_events {
            if let Some(track) = state.tracks.get_mut(&track_id) {
                if let Some(channel) = state.channels.get_mut(&track.channel_id) {
                    channel.send_midi_event_to_devices(note, velocity, is_on, frame_offset);
                }
            }
        }
    }

    // Generate audio clip content per frame while advancing a local tick cursor
    let mut render_tick = start_tick;
    let mut render_acc = start_acc;
    for frame_idx in 0..frames {
        // Advance local tick based on ticks_per_sample
        render_acc += ticks_per_sample;
        if render_acc >= 1.0 {
            let inc = render_acc.floor() as Tick;
            render_tick += inc;
            render_acc -= inc as f64;
        }

        let current_tick = render_tick;

        // Generate audio from each track
        for track in state.tracks.values_mut() {
            let mut sample_left = 0.0;
            let mut sample_right = 0.0;

            // Note: MIDI audio is now generated by the channel's instrument device (if present)
            // Tracks no longer hold active voices - they only route MIDI to channels

            // Process audio clips on this track
            for instance in &track.clip_instances {
                if instance.muted {
                    continue;
                }

                if let Some(clip) = state.clips.get(&instance.clip_id) {
                    if clip.clip_type == super::types::ClipType::Audio
                        && !clip.audio_samples.is_empty()
                    {
                        let current_pos_in_instance = current_tick - instance.start_tick;

                        // Check if we're in the playback range for this instance
                        if current_pos_in_instance >= 0
                            && current_pos_in_instance < instance.duration_ticks
                        {
                            // Initialize playback position for this clip instance if not yet started
                            // Apply clip_offset: start reading from the offset position in the clip
                            // PLUS account for seeking into the middle of the instance
                            if !track.audio_playback_positions.contains_key(&instance.id) {
                                // Total offset = clip_offset (trim) + current position in instance (seek)
                                let total_offset_ticks = instance.clip_offset + current_pos_in_instance;

                                // Convert total offset (ticks) to sample index in the clip's sample-rate domain
                                let offset_samples = state.settings.ticks_to_samples(
                                    total_offset_ticks,
                                    clip.audio_sample_rate as f32,
                                ) as f64;
                                track
                                    .audio_playback_positions
                                    .insert(instance.id.clone(), offset_samples);
                            }

                            // Get mutable reference to playback position
                            let playback_pos = track
                                .audio_playback_positions
                                .get_mut(&instance.id)
                                .unwrap();

                            // Calculate BPM stretch factor
                            let stretch_factor = AudioPlayback::calculate_stretch_factor(
                                state.settings.tempo,
                                clip.recorded_bpm,
                            );

                            // Calculate samples to advance this frame
                            // stretch_factor * device_sample_rate / clip_sample_rate
                            let advance_per_sample = (stretch_factor as f64)
                                * (state.device_sample_rate as f64)
                                / (clip.audio_sample_rate as f64);

                            let clip_sample_len =
                                (clip.audio_samples.len() / clip.audio_channels) as f64;

                            // Get the current interpolated sample
                            let sample_idx = playback_pos.floor() as usize;
                            let frac = (playback_pos.fract()) as f32;

                            if sample_idx < clip_sample_len as usize {
                                let interleaved_idx = sample_idx * clip.audio_channels;
                                let next_idx = sample_idx + 1;
                                let interleaved_idx_next = if next_idx < clip_sample_len as usize {
                                    next_idx * clip.audio_channels
                                } else {
                                    interleaved_idx
                                };

                                // Linear interpolation for left channel
                                if interleaved_idx < clip.audio_samples.len() {
                                    let s0_left = clip.audio_samples[interleaved_idx];
                                    let s1_left = if interleaved_idx_next < clip.audio_samples.len()
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
                                let gain_linear = 10.0_f32.powf(instance.gain_offset / 20.0);
                                sample_left *= gain_linear;
                                sample_right *= gain_linear;
                            }

                            // Advance playback position for next frame
                            *playback_pos += advance_per_sample;

                            // Handle looping
                            if instance.loop_enabled && instance.loop_length_ticks > 0 {
                                let seconds_per_tick = 60.0
                                    / (state.settings.tempo as f64 * state.settings.ppq as f64);
                                let loop_start_seconds =
                                    instance.loop_start_ticks as f64 * seconds_per_tick;
                                let loop_length_seconds =
                                    instance.loop_length_ticks as f64 * seconds_per_tick;
                                let clip_sr = clip.audio_sample_rate as f64;
                                let loop_start_samples =
                                    loop_start_seconds * clip_sr * stretch_factor as f64;
                                let loop_length_samples =
                                    loop_length_seconds * clip_sr * stretch_factor as f64;

                                if loop_length_samples > 0.0
                                    && *playback_pos >= loop_start_samples + loop_length_samples
                                {
                                    let offset_in_loop = *playback_pos - loop_start_samples;
                                    *playback_pos =
                                        loop_start_samples + (offset_in_loop % loop_length_samples);
                                }
                            }
                        } else if current_pos_in_instance < 0 {
                            // Not yet at clip start, ensure position is reset
                            track.audio_playback_positions.remove(&instance.id);
                        } else {
                            // Past clip end, remove position tracking
                            track.audio_playback_positions.remove(&instance.id);
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
    // let final_bar = final_tick / ticks_per_bar;
    //
    // // Log every bar boundary
    // static mut LAST_LOGGED_BAR: i64 = -1;
    // unsafe {
    //     if final_bar != LAST_LOGGED_BAR {
    //         LAST_LOGGED_BAR = final_bar;
    //         let position = state.settings.format_tick_position(final_tick);
    //         info!("Playhead: {}", position);
    //     }
    // }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::midi_types::MidiEvent;
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
}
