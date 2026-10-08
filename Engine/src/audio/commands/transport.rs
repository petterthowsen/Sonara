//! Transport and project-level commands: init, play/pause/stop/seek, loop, tempo, time signature, scale.

use crate::audio::commands::EngineStatus;
use crate::audio::project::ProjectSettings;
use crate::audio::state::EngineState;
use crate::audio::types::Tick;
use crossbeam::channel::Sender;
use std::sync::atomic::Ordering;
use tracing::info;

/// Start a project with `settings`, forcing the sample rate to the device rate, and make sure the master channel exists.
pub(super) fn init_project(
    state: &mut EngineState,
    mut settings: ProjectSettings,
    buffer_size: usize,
) {
    let device_sr = state.device_sample_rate.round() as i32;
    if (settings.sample_rate - device_sr).abs() > 1 {
        info!(
            "Project sample rate {} overridden to match device {}",
            settings.sample_rate, device_sr
        );
    }
    settings.sample_rate = device_sr;
    state.settings = settings;
    state.ensure_master_channel(buffer_size);
    info!(
        "Project initialized: {}bpm, {}/{}, PPQ={}, SR={} (device)",
        state.settings.tempo,
        state.settings.time_numerator,
        state.settings.time_denominator,
        state.settings.ppq,
        device_sr
    );
}

/// Start playback and ask the next callback to fire the clip MIDI at the playhead.
pub(super) fn play(state: &mut EngineState) -> Option<EngineStatus> {
    state.set_is_playing(true);
    state.request_playhead_midi_dispatch();
    let position = state
        .settings
        .format_tick_position(state.get_current_tick());
    info!("Playback started at {}", position);
    Some(EngineStatus::PlayingStateChanged(true))
}

/// Stop the transport where it is and release the clip notes so tails ring out.
pub(super) fn pause(state: &mut EngineState) -> Option<EngineStatus> {
    state.set_is_playing(false);
    let position = state
        .settings
        .format_tick_position(state.get_current_tick());
    // Release clip notes; devices keep running so releases and effect tails ring out
    for channel in state.channels.values_mut() {
        channel.stop_clip_notes();
    }
    info!("Playback paused at {}", position);
    Some(EngineStatus::PlayingStateChanged(false))
}

/// Stop the transport, rewind to tick 0 and release the clip notes.
pub(super) fn stop(
    state: &mut EngineState,
    status_tx: &Sender<EngineStatus>,
) -> Option<EngineStatus> {
    let position = state
        .settings
        .format_tick_position(state.get_current_tick());
    state.set_is_playing(false);
    state.set_current_tick(0);
    state.set_fractional_tick_accumulator(0.0);
    state.dispatch_playhead_tick.store(false, Ordering::Release);
    // Release clip notes; devices keep running so releases and effect tails ring out
    for channel in state.channels.values_mut() {
        channel.stop_clip_notes();
    }
    for track in state.tracks.values_mut() {
        for instance in &mut track.clip_instances {
            instance.playback_position = None;
        }
    }
    info!("Playback stopped (was at {})", position);
    // Send both playing state change and playhead reset
    // Note: only one status can be returned, so we'll send playhead via the channel
    // and return playing state
    let _ = status_tx.send(EngineStatus::PlayheadUpdate(0));
    Some(EngineStatus::PlayingStateChanged(false))
}

/// Move the playhead to `tick` and release the clip notes of the old position.
pub(super) fn seek(state: &mut EngineState, tick: Tick) {
    state.set_current_tick(tick);
    state.set_fractional_tick_accumulator(0.0);
    state.request_playhead_midi_dispatch();
    // Release clip notes from the old position; tails keep ringing
    for channel in state.channels.values_mut() {
        channel.stop_clip_notes();
    }
    for track in state.tracks.values_mut() {
        for instance in &mut track.clip_instances {
            instance.playback_position = None;
        }
    }
    info!("Seeked to tick {}", tick);
}

/// Set the loop region; it is off unless `enabled` and `start..end` is a non-empty range.
pub(super) fn set_loop(state: &mut EngineState, enabled: bool, start: Tick, end: Tick) {
    state.loop_region = if enabled && start >= 0 && end > start {
        Some((start, end))
    } else {
        None
    };
    info!("Loop {:?}", state.loop_region);
}

/// Set the static project tempo.
pub(super) fn set_tempo(state: &mut EngineState, tempo: f32) {
    state.settings.tempo = tempo;
    info!("Tempo set to {}", tempo);
}

/// Set the project time signature.
pub(super) fn set_time_signature(state: &mut EngineState, num: i32, den: i32) {
    state.settings.time_numerator = num;
    state.settings.time_denominator = den;
    info!("Time signature set to {}/{}", num, den);
}

/// Set the project scale as a 12-bit pitch-class mask.
pub(super) fn set_project_scale(state: &mut EngineState, mask: u16) {
    state.settings.scale_mask = mask & 0x0FFF;
    info!(
        "Project scale mask set to {:#05x}",
        state.settings.scale_mask
    );
}
