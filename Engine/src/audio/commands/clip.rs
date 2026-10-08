//! Clip commands: the clip pool, MIDI notes, audio clip loading, and clip instances on tracks.

use crate::audio::clip::{Clip, ClipInstance, ClipLoadState, ClipNote};
use crate::audio::commands::{CommandEffects, EngineStatus};
use crate::audio::state::EngineState;
use crate::audio::types::{ClipId, ClipInstanceId, MidiNote, NoteId, Tick, TrackId};
use tracing::{info, warn};

/// Create an empty clip; an unknown type string becomes a MIDI clip.
pub(super) fn create_clip(state: &mut EngineState, id: ClipId, name: String, clip_type: String) {
    use crate::audio::clip::ClipType;
    let clip_type_enum = match clip_type.as_str() {
        "midi" | "Midi" => ClipType::Midi,
        "audio" | "Audio" => ClipType::Audio,
        _ => {
            warn!("Unknown clip type: {}, defaulting to Midi", clip_type);
            ClipType::Midi
        }
    };
    let clip = Clip::new(id.clone(), name.clone(), clip_type_enum);
    state.clips.insert(id.clone(), clip);
    info!("Clip created: {} ({})", name, id);
}

/// Remove a clip from the pool.
pub(super) fn remove_clip(state: &mut EngineState, id: ClipId, effects: &mut CommandEffects) {
    if let Some(clip) = state.clips.remove(&id) {
        // Dropping the decoded PCM frees memory, so it waits until the lock is released.
        effects.discard(clip);
        info!("Clip removed: {}", id);
    } else {
        warn!("Clip not found for removal: {}", id);
    }
}

/// Add a note to a MIDI clip, ignoring a duplicate note id, and grow the content length.
pub(super) fn add_note_to_clip(
    state: &mut EngineState,
    clip_id: ClipId,
    note_id: NoteId,
    note: MidiNote,
    start_tick: Tick,
    duration_ticks: Tick,
    velocity: f32,
    release: f32,
) {
    if let Some(clip) = state.clips.get_mut(&clip_id) {
        // Check if note with this ID already exists (protect against duplicate OSC messages)
        if clip.midi_notes.iter().any(|n| n.id == note_id) {
            warn!(
                "Note {} already exists in clip {} - ignoring duplicate add command",
                note_id, clip_id
            );
        } else {
            let clip_note = ClipNote {
                id: note_id,
                note,
                velocity,
                release,
                start_tick,
                duration_ticks,
            };
            clip.midi_notes.push(clip_note);
            // Update content length if needed
            let note_end = start_tick + duration_ticks;
            if note_end > clip.content_length_ticks {
                clip.content_length_ticks = note_end;
            }
            info!(
                "Note {} added to clip {}: note={} start={} dur={}",
                note_id, clip_id, note, start_tick, duration_ticks
            );
        }
    } else {
        warn!("Clip not found for add note: {}", clip_id);
    }
}

/// Remove a note from a MIDI clip and recompute the content length.
pub(super) fn remove_note_from_clip(state: &mut EngineState, clip_id: ClipId, note_id: NoteId) {
    if let Some(clip) = state.clips.get_mut(&clip_id) {
        let initial_len = clip.midi_notes.len();
        clip.midi_notes.retain(|n| n.id != note_id);
        if clip.midi_notes.len() != initial_len {
            info!("Note {} removed from clip {}", note_id, clip_id);
            // Recalculate content length
            clip.content_length_ticks = clip
                .midi_notes
                .iter()
                .map(|n| n.start_tick + n.duration_ticks)
                .max()
                .unwrap_or(0);
        } else {
            warn!("Note {} not found in clip {}", note_id, clip_id);
        }
    } else {
        warn!("Clip not found for remove note: {}", clip_id);
    }
}

/// Change a MIDI clip note in place (dropping duplicate ids) and recompute the content length.
pub(super) fn update_clip_note(
    state: &mut EngineState,
    clip_id: ClipId,
    note_id: NoteId,
    note: MidiNote,
    start_tick: Tick,
    duration_ticks: Tick,
    velocity: f32,
    release: f32,
) {
    if let Some(clip) = state.clips.get_mut(&clip_id) {
        // Check for duplicate notes with same ID (shouldn't happen but let's be defensive)
        let matching_notes: Vec<_> = clip.midi_notes.iter().filter(|n| n.id == note_id).collect();

        if matching_notes.len() > 1 {
            warn!(
                "Found {} duplicate notes with ID {} in clip {} - removing duplicates",
                matching_notes.len(),
                note_id,
                clip_id
            );
            // Keep only the first one
            let mut found_first = false;
            clip.midi_notes.retain(|n| {
                if n.id == note_id {
                    if found_first {
                        return false; // Remove duplicate
                    }
                    found_first = true;
                }
                true
            });
        }

        if let Some(clip_note) = clip.midi_notes.iter_mut().find(|n| n.id == note_id) {
            clip_note.note = note;
            clip_note.start_tick = start_tick;
            clip_note.duration_ticks = duration_ticks;
            clip_note.velocity = velocity;
            clip_note.release = release;
            // Recalculate content length
            clip.content_length_ticks = clip
                .midi_notes
                .iter()
                .map(|n| n.start_tick + n.duration_ticks)
                .max()
                .unwrap_or(0);
            info!(
                "Note {} updated in clip {}: note={} start={} dur={}",
                note_id, clip_id, note, start_tick, duration_ticks
            );
        } else {
            warn!("Note {} not found in clip {}", note_id, clip_id);
        }
    } else {
        warn!("Clip not found for update note: {}", clip_id);
    }
}

/// Mark an audio clip as loading and report the new load state.
pub(super) fn begin_load_audio_clip(
    state: &mut EngineState,
    clip_id: ClipId,
    req_id: String,
    source_path: String,
    effects: &mut CommandEffects,
) -> Option<EngineStatus> {
    if let Some(clip) = state.clips.get_mut(&clip_id) {
        info!(
            "Begin loading audio clip {} from {} (req_id={})",
            clip_id, source_path, req_id
        );

        clip.audio_source_path = Some(source_path.clone());
        clip.waveform_cache_key = None;
        effects.discard(std::mem::take(&mut clip.audio_samples));
        clip.content_length_ticks = 0;
        clip.load_state = ClipLoadState::Loading {
            req_id: req_id.clone(),
        };

        return Some(EngineStatus::ClipLoadStateChanged {
            clip_id,
            state: clip.load_state.clone(),
            source_path: clip.audio_source_path.clone(),
            cache_key: clip.waveform_cache_key.clone(),
            sample_rate: None,
            channels: None,
        });
    } else {
        warn!("Clip not found for begin load: {}", clip_id);
    }

    None
}

/// Install decoded PCM into an audio clip and report it ready; stale `req_id`s are ignored.
pub(super) fn load_audio_clip(
    state: &mut EngineState,
    clip_id: ClipId,
    req_id: String,
    source_path: String,
    cache_key: Option<String>,
    samples: Vec<f32>,
    sample_rate: u32,
    channels: usize,
    effects: &mut CommandEffects,
) -> Option<EngineStatus> {
    if let Some(clip) = state.clips.get_mut(&clip_id) {
        if let ClipLoadState::Loading {
            req_id: current_req,
        } = &clip.load_state
        {
            if current_req != &req_id {
                warn!(
                    "Stale clip load event for {} (expected req_id {}, got {})",
                    clip_id, current_req, req_id
                );
                effects.discard(samples);
                return None;
            }
        }

        info!(
            "Audio clip {} ready ({} samples, {} Hz, {} channels)",
            clip_id,
            samples.len(),
            sample_rate,
            channels
        );

        // Move rather than clone: decoded files can be hundreds of MB, and this runs
        // with the state lock held
        let total_samples = samples.len();
        effects.discard(std::mem::replace(&mut clip.audio_samples, samples));
        clip.audio_sample_rate = sample_rate;
        clip.audio_channels = channels;
        clip.audio_source_path = Some(source_path.clone());
        clip.waveform_cache_key = cache_key.clone();
        clip.load_state = ClipLoadState::Ready {
            req_id: req_id.clone(),
        };

        // Calculate content length in ticks
        if channels > 0 && sample_rate > 0 {
            let sample_count = total_samples / channels;
            let duration_seconds = sample_count as f32 / sample_rate as f32;
            // Assuming 120 BPM = 2 beats per second, PPQ = 960 ticks per beat
            let beats = duration_seconds * 2.0;
            clip.content_length_ticks = (beats * 960.0) as i64;
        } else {
            clip.content_length_ticks = 0;
        }

        return Some(EngineStatus::ClipLoadStateChanged {
            clip_id,
            state: clip.load_state.clone(),
            source_path: clip.audio_source_path.clone(),
            cache_key: clip.waveform_cache_key.clone(),
            sample_rate: Some(sample_rate),
            channels: Some(channels),
        });
    } else {
        warn!("Clip not found for load audio: {}", clip_id);
        effects.discard(samples);
    }

    None
}

/// Mark an audio clip load as failed and report it.
pub(super) fn fail_audio_clip_load(
    state: &mut EngineState,
    clip_id: ClipId,
    req_id: String,
    message: String,
    effects: &mut CommandEffects,
) -> Option<EngineStatus> {
    if let Some(clip) = state.clips.get_mut(&clip_id) {
        warn!(
            "Audio clip {} failed to load (req_id={}): {}",
            clip_id, req_id, message
        );

        effects.discard(std::mem::take(&mut clip.audio_samples));
        clip.content_length_ticks = 0;
        clip.waveform_cache_key = None;
        clip.load_state = ClipLoadState::Failed {
            req_id: Some(req_id.clone()),
            message: message.clone(),
        };

        return Some(EngineStatus::ClipLoadStateChanged {
            clip_id,
            state: clip.load_state.clone(),
            source_path: clip.audio_source_path.clone(),
            cache_key: clip.waveform_cache_key.clone(),
            sample_rate: None,
            channels: None,
        });
    } else {
        warn!(
            "Clip not found for fail audio load: {} (req_id={}, msg={})",
            clip_id, req_id, message
        );
    }

    None
}

/// Place a clip on a track at `start_tick`.
pub(super) fn create_clip_instance(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
    clip_id: ClipId,
    start_tick: Tick,
    duration_ticks: Tick,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        let instance = ClipInstance::new(
            instance_id.clone(),
            clip_id.clone(),
            start_tick,
            duration_ticks,
        );
        track.clip_instances.push(instance);
        info!(
            "ClipInstance {} created on track {}: clip={} start={} dur={}",
            instance_id, track_id, clip_id, start_tick, duration_ticks
        );
    } else {
        warn!("Track not found for create instance: {}", track_id);
    }
}

/// Remove a clip instance from a track.
pub(super) fn remove_clip_instance(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        let initial_len = track.clip_instances.len();
        track.clip_instances.retain(|i| i.id != instance_id);
        if track.clip_instances.len() != initial_len {
            info!(
                "ClipInstance {} removed from track {}",
                instance_id, track_id
            );
        } else {
            warn!(
                "ClipInstance {} not found on track {}",
                instance_id, track_id
            );
        }
    } else {
        warn!("Track not found for remove instance: {}", track_id);
    }
}

/// Move or trim a clip instance; resets its playback position.
pub(super) fn update_clip_instance_position(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
    start_tick: Tick,
    duration_ticks: Tick,
    clip_offset: Tick,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        if let Some(instance) = track
            .clip_instances
            .iter_mut()
            .find(|i| i.id == instance_id)
        {
            instance.start_tick = start_tick;
            instance.duration_ticks = duration_ticks;
            instance.clip_offset = clip_offset;

            // Reset playback position when clip_offset changes
            // (will be re-initialized with new offset on next playback)
            instance.playback_position = None;

            info!(
                "ClipInstance {} position updated: start={} dur={} offset={}",
                instance_id, start_tick, duration_ticks, clip_offset
            );
        } else {
            warn!(
                "ClipInstance {} not found on track {}",
                instance_id, track_id
            );
        }
    } else {
        warn!("Track not found for update instance position: {}", track_id);
    }
}

/// Set a clip instance's transpose in semitones.
pub(super) fn update_clip_instance_transpose(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
    transpose: i8,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        if let Some(instance) = track
            .clip_instances
            .iter_mut()
            .find(|i| i.id == instance_id)
        {
            instance.transpose = transpose;
            info!(
                "ClipInstance {} transpose updated: {}",
                instance_id, transpose
            );
        } else {
            warn!(
                "ClipInstance {} not found on track {}",
                instance_id, track_id
            );
        }
    } else {
        warn!(
            "Track not found for update instance transpose: {}",
            track_id
        );
    }
}

/// Set a clip instance's gain offset in dB.
pub(super) fn update_clip_instance_gain(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
    gain_db: f32,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        if let Some(instance) = track
            .clip_instances
            .iter_mut()
            .find(|i| i.id == instance_id)
        {
            instance.gain_offset = gain_db;
            info!("ClipInstance {} gain updated: {} dB", instance_id, gain_db);
        } else {
            warn!(
                "ClipInstance {} not found on track {}",
                instance_id, track_id
            );
        }
    } else {
        warn!("Track not found for update instance gain: {}", track_id);
    }
}

/// Mute or unmute a clip instance.
pub(super) fn update_clip_instance_mute(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
    muted: bool,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        if let Some(instance) = track
            .clip_instances
            .iter_mut()
            .find(|i| i.id == instance_id)
        {
            instance.muted = muted;
            info!("ClipInstance {} mute updated: {}", instance_id, muted);
        } else {
            warn!(
                "ClipInstance {} not found on track {}",
                instance_id, track_id
            );
        }
    } else {
        warn!("Track not found for update instance mute: {}", track_id);
    }
}

/// Set a clip instance's loop region.
pub(super) fn update_clip_instance_loop(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
    enabled: bool,
    start_tick: Tick,
    length_ticks: Tick,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        if let Some(instance) = track
            .clip_instances
            .iter_mut()
            .find(|i| i.id == instance_id)
        {
            instance.loop_enabled = enabled;
            instance.loop_start_ticks = start_tick;
            instance.loop_length_ticks = length_ticks;
            info!(
                "ClipInstance {} loop updated: enabled={} start={} length={}",
                instance_id, enabled, start_tick, length_ticks
            );
        } else {
            warn!(
                "ClipInstance {} not found on track {}",
                instance_id, track_id
            );
        }
    } else {
        warn!("Track not found for update instance loop: {}", track_id);
    }
}

/// Play a clip instance backwards or forwards.
pub(super) fn update_clip_instance_reverse(
    state: &mut EngineState,
    track_id: TrackId,
    instance_id: ClipInstanceId,
    reverse: bool,
) {
    if let Some(track) = state.tracks.get_mut(&track_id) {
        if let Some(instance) = track
            .clip_instances
            .iter_mut()
            .find(|i| i.id == instance_id)
        {
            instance.reverse = reverse;
            info!("ClipInstance {} reverse updated: {}", instance_id, reverse);
        } else {
            warn!(
                "ClipInstance {} not found on track {}",
                instance_id, track_id
            );
        }
    } else {
        warn!("Track not found for update instance reverse: {}", track_id);
    }
}

#[cfg(test)]
mod tests {
    use crate::audio::commands::{process_command, AudioCommand, CommandEffects};
    use crate::audio::state::EngineState;

    #[test]
    fn clip_note_command_stores_float_values() {
        let mut state = EngineState::default();
        let mut effects = CommandEffects::default();
        let clip_id = "c".to_string();
        process_command(
            &mut state,
            AudioCommand::CreateClip {
                id: clip_id.clone(),
                name: "C".to_string(),
                clip_type: "midi".to_string(),
            },
            128,
            &mut effects,
        );
        process_command(
            &mut state,
            AudioCommand::AddNoteToClip {
                clip_id: clip_id.clone(),
                note_id: 1,
                note: 60,
                start_tick: 0,
                duration_ticks: 480,
                velocity: 0.5039,
                release: 0.25,
            },
            128,
            &mut effects,
        );
        let note = &state.clips[&clip_id].midi_notes[0];
        assert_eq!((note.velocity, note.release), (0.5039, 0.25));

        process_command(
            &mut state,
            AudioCommand::UpdateClipNote {
                clip_id: clip_id.clone(),
                note_id: 1,
                note: 62,
                start_tick: 0,
                duration_ticks: 480,
                velocity: 0.75,
                release: 0.9,
            },
            128,
            &mut effects,
        );
        let note = &state.clips[&clip_id].midi_notes[0];
        assert_eq!((note.note, note.velocity, note.release), (62, 0.75, 0.9));
    }
}
