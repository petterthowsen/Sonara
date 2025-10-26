use tracing::info;

use super::types::*;
use super::commands::EngineState;

/// Process audio for one buffer
pub fn process_audio(state: &mut EngineState, frames: usize, sample_rate: f32) {
    // Only process MIDI and advance playhead when playing
    if !state.is_playing {
        return;
    }
    
    // IMPORTANT: Use actual device sample rate for timing, not project setting
    let ticks_per_sample = (state.settings.tempo as f64 * state.settings.ppq as f64) / (60.0 * sample_rate as f64);
    let mut tick_accumulator = 0.0;

    for frame_idx in 0..frames {
        let previous_tick = state.current_tick;

        // Advance playhead with fractional accumulation
        tick_accumulator += ticks_per_sample;
        let ticks_to_add = tick_accumulator.floor() as Tick;

        // Collect ALL ticks to process in this frame
        let mut ticks_in_this_frame: Vec<Tick> = vec![];

        if ticks_to_add > 0 {
            // We crossed at least one tick boundary - process all crossed ticks
            for t in 1..=ticks_to_add {
                ticks_in_this_frame.push(previous_tick + t);
            }
            state.current_tick += ticks_to_add;
            tick_accumulator -= ticks_to_add as f64;
        } else if frame_idx == 0 {
            // Special case: first frame, check current tick for note events
            // (handles notes that start exactly at playback position)
            ticks_in_this_frame.push(previous_tick);
        }

        // Process MIDI events for ALL ticks in this frame
        for current_tick in &ticks_in_this_frame {
            let current_tick = *current_tick;

            // Collect note on/off events from clip instances
            let mut note_events: Vec<(TrackId, MidiNote, MidiVelocity, bool)> = Vec::new();

            for (track_id, track) in &state.tracks {
                for instance in &track.clip_instances {
                    if instance.muted {
                        continue;
                    }

                    // Allow processing at instance end tick for note off events
                    // but not for note on events (which require being strictly within the instance)
                    let is_within_instance = current_tick >= instance.start_tick && current_tick < instance.end_tick();
                    let is_at_instance_end = current_tick == instance.end_tick();

                    if is_within_instance || is_at_instance_end {
                        if let Some(clip) = state.clips.get(&instance.clip_id) {
                            let mut offset_in_instance = current_tick - instance.start_tick;

                            // Handle looping
                            if instance.loop_enabled && instance.loop_length_ticks > 0 {
                                if offset_in_instance >= instance.loop_start_ticks {
                                    let loop_offset = offset_in_instance - instance.loop_start_ticks;
                                    offset_in_instance = instance.loop_start_ticks + (loop_offset % instance.loop_length_ticks);
                                }
                            }

                            for clip_note in &clip.midi_notes {
                                // Apply clip_offset: only play notes at or after the offset
                                // Translate clip note position to instance local time
                                let note_start_in_instance = clip_note.start_tick - instance.clip_offset;
                                let note_end_in_instance = note_start_in_instance + clip_note.duration_ticks;
                                
                                // Skip notes that are before the clip_offset
                                if note_end_in_instance <= 0 {
                                    continue;
                                }

                                // Apply transpose
                                let transposed_note = (clip_note.note as i16 + instance.transpose as i16)
                                    .clamp(0, 127) as MidiNote;

                                // Note On (only within instance, not at end)
                                if is_within_instance && note_start_in_instance == offset_in_instance {
                                    note_events.push((*track_id, transposed_note, clip_note.velocity, true));
                                }

                                // Note Off (allow at instance end)
                                if note_end_in_instance == offset_in_instance {
                                    note_events.push((*track_id, transposed_note, clip_note.velocity, false));
                                }
                            }
                        }
                    }
                }
            }

            // Apply collected note events by routing to channel's instrument device
            for (track_id, note, velocity, is_on) in note_events {
                if let Some(track) = state.tracks.get_mut(&track_id) {
                    // Route MIDI to the track's target channel (instrument device)
                    if let Some(channel) = state.channels.get_mut(&track.channel_id) {
                        channel.send_midi_event_to_devices(note, velocity, is_on);
                        if is_on {
                            info!("Note ON (clip): {} at tick {}", note, current_tick);
                        } else {
                            info!("Note OFF (clip): {} at tick {}", note, current_tick);
                        }
                    }
                }
            }
        }

        let current_tick = state.current_tick;

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
                    if clip.clip_type == super::types::ClipType::Audio && !clip.audio_samples.is_empty() {
                        let current_pos_in_instance = current_tick - instance.start_tick;

                        // Check if we're in the playback range for this instance
                        if current_pos_in_instance >= 0 && current_pos_in_instance < instance.duration_ticks {
                            // Initialize playback position for this clip instance if not yet started
                            // Apply clip_offset: start reading from the offset position in the clip
                            if !track.audio_playback_positions.contains_key(&instance.id) {
                                // Convert clip_offset (in ticks) to sample position
                                // Formula: samples = (ticks / PPQ) * (60 / tempo) * sample_rate
                                let ticks_to_beats = instance.clip_offset as f64 / state.settings.ppq as f64;
                                let beats_to_seconds = ticks_to_beats * 60.0 / state.settings.tempo as f64;
                                let offset_samples = beats_to_seconds * clip.audio_sample_rate as f64;
                                track.audio_playback_positions.insert(instance.id.clone(), offset_samples);
                            }

                            // Get mutable reference to playback position
                            let playback_pos = track.audio_playback_positions.get_mut(&instance.id).unwrap();

                            // Calculate BPM stretch factor
                            let stretch_factor = AudioPlayback::calculate_stretch_factor(state.settings.tempo, clip.recorded_bpm);

                            // Calculate samples to advance this frame
                            // stretch_factor * device_sample_rate / clip_sample_rate
                            let advance_per_sample = (stretch_factor as f64) * (state.device_sample_rate as f64) / (clip.audio_sample_rate as f64);

                            let clip_sample_len = (clip.audio_samples.len() / clip.audio_channels) as f64;

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
                                    let s1_left = if interleaved_idx_next < clip.audio_samples.len() && interleaved_idx_next != interleaved_idx {
                                        clip.audio_samples[interleaved_idx_next]
                                    } else {
                                        s0_left
                                    };
                                    sample_left += s0_left + frac * (s1_left - s0_left);
                                }

                                // Linear interpolation for right channel
                                if clip.audio_channels > 1 && interleaved_idx + 1 < clip.audio_samples.len() {
                                    let s0_right = clip.audio_samples[interleaved_idx + 1];
                                    let s1_right = if interleaved_idx_next + 1 < clip.audio_samples.len() && interleaved_idx_next != interleaved_idx {
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
                                let seconds_per_tick = 60.0 / (state.settings.tempo as f64 * state.settings.ppq as f64);
                                let loop_start_seconds = instance.loop_start_ticks as f64 * seconds_per_tick;
                                let loop_length_seconds = instance.loop_length_ticks as f64 * seconds_per_tick;
                                let clip_sr = clip.audio_sample_rate as f64;
                                let loop_start_samples = loop_start_seconds * clip_sr * stretch_factor as f64;
                                let loop_length_samples = loop_length_seconds * clip_sr * stretch_factor as f64;

                                if loop_length_samples > 0.0 && *playback_pos >= loop_start_samples + loop_length_samples {
                                    let offset_in_loop = *playback_pos - loop_start_samples;
                                    *playback_pos = loop_start_samples + (offset_in_loop % loop_length_samples);
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

    // Log playhead position every bar for debugging
    let ticks_per_bar = state.settings.ppq as i64 * state.settings.time_numerator as i64;
    let final_tick = state.current_tick;
    let final_bar = final_tick / ticks_per_bar;

    // Log every bar boundary
    static mut LAST_LOGGED_BAR: i64 = -1;
    unsafe {
        if final_bar != LAST_LOGGED_BAR {
            LAST_LOGGED_BAR = final_bar;
            let position = state.settings.format_tick_position(final_tick);
            info!("Playhead: {}", position);
        }
    }
}
