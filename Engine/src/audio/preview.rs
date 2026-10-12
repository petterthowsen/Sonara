//! Browser sample preview (spec 037): one decoded file played straight to the hardware output.
//!
//! The preview bypasses the mixer: it is added to hardware outputs 1/2 after the whole mix, with
//! a fixed gain and no fader or master FX. Decoding happens in the `AudioFileService`; the
//! player only receives finished PCM. The command thread owns every state change except the end
//! of the file, which the audio thread reports itself, so [`PreviewPlayer::mix_into`] never
//! allocates, blocks or logs.

use std::sync::Arc;

use crate::audio::commands::{CommandEffects, EngineStatus};

/// Fixed preview gain, -6 dB.
pub const PREVIEW_GAIN: f32 = 0.501_187_2;
/// Fade for start, stop and seek, so a preview never clicks.
const FADE_SECONDS: f32 = 0.003;

/// What `/preview/status` reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreviewState {
    Stopped,
    Loading,
    Playing,
    Failed,
}

impl PreviewState {
    /// The `i` argument of `/preview/status`.
    pub fn osc_value(self) -> i32 {
        match self {
            PreviewState::Stopped => 0,
            PreviewState::Loading => 1,
            PreviewState::Playing => 2,
            PreviewState::Failed => 3,
        }
    }
}

/// Decoded PCM, interleaved, at the rate the file service decoded it to (the device rate).
pub struct PreviewBuffer {
    /// File this PCM was decoded from.
    path: Arc<str>,
    samples: Vec<f32>,
    channels: usize,
    frames: usize,
    sample_rate: u32,
}

impl PreviewBuffer {
    pub fn new(path: Arc<str>, samples: Vec<f32>, channels: usize, sample_rate: u32) -> Self {
        let channels = channels.max(1);
        let frames = samples.len() / channels;
        Self {
            path,
            samples,
            channels,
            frames,
            sample_rate: sample_rate.max(1),
        }
    }
}

/// The browser preview player, part of `EngineState`.
pub struct PreviewPlayer {
    buffer: Option<PreviewBuffer>,
    /// File the player is about to play, or plays: what `/preview/status` names. The buffer may
    /// still hold an older file while a load is in flight.
    path: Arc<str>,
    /// Request id of the decode this player waits for; a result with another id is stale.
    request: String,
    state: PreviewState,
    pos_frames: usize,
    /// Start position of a load in flight, in seconds.
    start_s: f32,
    /// Fade gain 0..1, ramping toward 1 while playing and toward 0 otherwise.
    fade: f32,
    /// A seek that waits for the fade-out to reach silence.
    pending_seek: Option<usize>,
}

impl Default for PreviewPlayer {
    fn default() -> Self {
        Self {
            buffer: None,
            path: Arc::from(""),
            request: String::new(),
            state: PreviewState::Stopped,
            pos_frames: 0,
            start_s: 0.0,
            fade: 0.0,
            pending_seek: None,
        }
    }
}

impl PreviewPlayer {
    pub fn state(&self) -> PreviewState {
        self.state
    }

    pub fn is_playing(&self) -> bool {
        self.state == PreviewState::Playing
    }

    /// True when the buffer in memory is `path`'s (so a play needs no decode).
    pub fn has_loaded(&self, path: &str) -> bool {
        self.buffer.as_ref().is_some_and(|b| &*b.path == path)
    }

    /// The buffer when it belongs to the file the player is about to play or plays.
    fn current_buffer(&self) -> Option<&PreviewBuffer> {
        self.buffer.as_ref().filter(|b| b.path == self.path)
    }

    pub fn position_seconds(&self) -> f32 {
        match self.current_buffer() {
            Some(buffer) if self.state != PreviewState::Loading => {
                self.pos_frames as f32 / buffer.sample_rate as f32
            }
            _ => self.start_s,
        }
    }

    pub fn duration_seconds(&self) -> f32 {
        match self.current_buffer() {
            Some(buffer) => buffer.frames as f32 / buffer.sample_rate as f32,
            None => 0.0,
        }
    }

    /// The `/preview/status` for the current state. Cloning the path is a refcount bump, so the
    /// audio thread can call this.
    pub fn status(&self) -> EngineStatus {
        EngineStatus::PreviewStatus {
            path: Arc::clone(&self.path),
            state: self.state,
            pos_s: self.position_seconds(),
            duration_s: self.duration_seconds(),
        }
    }

    /// A play of a file that needs decoding: stop what plays and wait for request `request`.
    pub fn begin_load(
        &mut self,
        request: String,
        path: &str,
        start_s: f32,
        effects: &mut CommandEffects,
    ) {
        effects.discard(std::mem::replace(&mut self.request, request));
        if &*self.path != path {
            let old = std::mem::replace(&mut self.path, Arc::from(path));
            effects.discard(old);
        }
        // The buffer may hold the old file; its fade-out tail still reads it, so it is replaced
        // only when the new PCM arrives.
        self.start_s = start_s.max(0.0);
        self.pending_seek = None;
        self.state = PreviewState::Loading;
    }

    /// Decoded PCM for request `request`. Returns false (and discards the PCM) when the request
    /// is stale, i.e. a newer play or a stop replaced it.
    pub fn finish_load(
        &mut self,
        request: &str,
        samples: Vec<f32>,
        channels: usize,
        sample_rate: u32,
        effects: &mut CommandEffects,
    ) -> bool {
        if self.state != PreviewState::Loading || self.request != request {
            effects.discard(samples);
            return false;
        }
        let buffer = PreviewBuffer::new(Arc::clone(&self.path), samples, channels, sample_rate);
        if buffer.frames == 0 {
            effects.discard(buffer);
            self.state = PreviewState::Failed;
            return true;
        }
        if let Some(old) = self.buffer.replace(buffer) {
            effects.discard(old);
        }
        let buffer = self.buffer.as_ref().expect("just set");
        self.pos_frames = ((self.start_s * buffer.sample_rate as f32) as usize).min(buffer.frames);
        self.fade = 0.0;
        self.pending_seek = None;
        // A start at the very end would finish at once; play from the top instead.
        if self.pos_frames >= buffer.frames {
            self.pos_frames = 0;
        }
        self.state = PreviewState::Playing;
        true
    }

    /// The decode for request `request` failed.
    pub fn fail_load(&mut self, request: &str) -> bool {
        if self.state != PreviewState::Loading || self.request != request {
            return false;
        }
        self.state = PreviewState::Failed;
        true
    }

    /// Play the buffer already in memory from `start_s`. False when it isn't `path`'s.
    pub fn play_loaded(&mut self, path: &str, start_s: f32) -> bool {
        if !self.has_loaded(path) {
            return false;
        }
        self.seek_seconds(start_s);
        self.state = PreviewState::Playing;
        true
    }

    /// Stop with a fade. The position stays for the next play. Also cancels a load in flight
    /// by making its result stale.
    pub fn stop(&mut self, effects: &mut CommandEffects) {
        if self.state == PreviewState::Loading {
            effects.discard(std::mem::take(&mut self.request));
        }
        self.state = PreviewState::Stopped;
    }

    /// Jump to `pos_s`. While a load is in flight it moves the start position instead.
    pub fn seek_seconds(&mut self, pos_s: f32) {
        let pos_s = pos_s.max(0.0);
        let Some(buffer) = self.buffer.as_ref().filter(|b| b.path == self.path) else {
            self.start_s = pos_s;
            return;
        };
        if self.state == PreviewState::Loading {
            self.start_s = pos_s;
            return;
        }
        let target = ((pos_s * buffer.sample_rate as f32) as usize).min(buffer.frames);
        if self.fade > 0.0 {
            // Audible: fade out first, then jump.
            self.pending_seek = Some(target);
        } else {
            self.pos_frames = target;
        }
    }

    /// Add the preview to the interleaved hardware `data` (outputs 1/2). Returns true when the
    /// file ended in this block; the caller then sends [`status`](Self::status). Audio thread:
    /// no allocation, no locks.
    pub fn mix_into(&mut self, data: &mut [f32], out_channels: usize, sample_rate: f32) -> bool {
        let Some(buffer) = &self.buffer else {
            return false;
        };
        if self.state != PreviewState::Playing && self.fade <= 0.0 {
            return false;
        }
        if out_channels == 0 {
            return false;
        }
        let step = 1.0 / (FADE_SECONDS * sample_rate.max(1.0));
        let out_frames = data.len() / out_channels;
        let mut finished = false;
        for frame in 0..out_frames {
            let wants_sound = self.state == PreviewState::Playing && self.pending_seek.is_none();
            if wants_sound {
                self.fade = (self.fade + step).min(1.0);
            } else {
                self.fade = (self.fade - step).max(0.0);
            }
            if self.fade <= 0.0 {
                if let Some(target) = self.pending_seek.take() {
                    self.pos_frames = target;
                    continue;
                }
                if self.state != PreviewState::Playing {
                    break;
                }
            }
            if self.pos_frames >= buffer.frames {
                self.state = PreviewState::Stopped;
                self.pos_frames = buffer.frames;
                self.fade = 0.0;
                finished = true;
                break;
            }
            let base = self.pos_frames * buffer.channels;
            let left = buffer.samples[base];
            let right = if buffer.channels > 1 {
                buffer.samples[base + 1]
            } else {
                left
            };
            let gain = PREVIEW_GAIN * self.fade;
            let out = frame * out_channels;
            if out_channels >= 2 {
                data[out] = (data[out] + left * gain).clamp(-1.0, 1.0);
                data[out + 1] = (data[out + 1] + right * gain).clamp(-1.0, 1.0);
            } else {
                data[out] = (data[out] + (left + right) * 0.5 * gain).clamp(-1.0, 1.0);
            }
            self.pos_frames += 1;
        }
        // Played the last frame of the file exactly at the end of the block.
        if !finished && self.state == PreviewState::Playing && self.pos_frames >= buffer.frames {
            self.state = PreviewState::Stopped;
            self.fade = 0.0;
            finished = true;
        }
        finished
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f32 = 48_000.0;

    fn effects() -> CommandEffects {
        CommandEffects::default()
    }

    /// A player with a loaded constant-1.0 buffer, playing from `start_s`.
    fn playing(channels: usize, frames: usize, start_s: f32) -> PreviewPlayer {
        let mut player = PreviewPlayer::default();
        let mut fx = effects();
        player.begin_load("preview:1".into(), "/a.wav", start_s, &mut fx);
        assert!(player.finish_load(
            "preview:1",
            vec![1.0; channels * frames],
            channels,
            RATE as u32,
            &mut fx
        ));
        player
    }

    fn block(player: &mut PreviewPlayer, frames: usize) -> (Vec<f32>, bool) {
        let mut data = vec![0.0; frames * 2];
        let finished = player.mix_into(&mut data, 2, RATE);
        (data, finished)
    }

    #[test]
    fn plays_the_buffer_with_the_preview_gain_after_a_fade_in() {
        let mut player = playing(2, 4800, 0.0);
        let (data, finished) = block(&mut player, 512);
        assert!(!finished);
        assert!(data[0] < 0.01, "starts from silence, got {}", data[0]);
        assert!((data[2 * 300] - PREVIEW_GAIN).abs() < 1e-4);
        assert!((data[2 * 300 + 1] - PREVIEW_GAIN).abs() < 1e-4);
        assert_eq!(player.state(), PreviewState::Playing);
    }

    #[test]
    fn mono_plays_on_both_sides() {
        let mut player = playing(1, 4800, 0.0);
        let (data, _) = block(&mut player, 512);
        assert!((data[2 * 400] - PREVIEW_GAIN).abs() < 1e-4);
        assert!((data[2 * 400 + 1] - PREVIEW_GAIN).abs() < 1e-4);
    }

    #[test]
    fn more_than_two_channels_play_the_first_two() {
        let mut player = PreviewPlayer::default();
        let mut fx = effects();
        player.begin_load("r".into(), "/a.wav", 0.0, &mut fx);
        let mut samples = Vec::new();
        for _ in 0..4800 {
            samples.extend_from_slice(&[1.0, 0.5, -1.0, -1.0]);
        }
        player.finish_load("r", samples, 4, RATE as u32, &mut fx);
        let (data, _) = block(&mut player, 512);
        assert!((data[2 * 400] - PREVIEW_GAIN).abs() < 1e-4);
        assert!((data[2 * 400 + 1] - 0.5 * PREVIEW_GAIN).abs() < 1e-4);
    }

    #[test]
    fn it_adds_to_what_is_already_in_the_output() {
        let mut player = playing(2, 4800, 0.0);
        let mut data = vec![0.25; 1024];
        player.mix_into(&mut data, 2, RATE);
        assert!((data[2 * 400] - (0.25 + PREVIEW_GAIN)).abs() < 1e-4);
    }

    #[test]
    fn output_is_unchanged_when_nothing_is_loaded() {
        let mut player = PreviewPlayer::default();
        let mut data = vec![0.25; 256];
        assert!(!player.mix_into(&mut data, 2, RATE));
        assert!(data.iter().all(|&s| s == 0.25));
    }

    #[test]
    fn reaching_the_end_stops_and_reports_the_full_duration() {
        let mut player = playing(2, 100, 0.0);
        let (_, finished) = block(&mut player, 512);
        assert!(finished);
        assert_eq!(player.state(), PreviewState::Stopped);
        assert_eq!(player.position_seconds(), player.duration_seconds());
        let (data, finished) = block(&mut player, 512);
        assert!(!finished, "a stopped player stays quiet");
        assert!(data.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn a_play_that_starts_at_the_end_plays_from_the_top() {
        let player = playing(2, 4800, 10.0);
        assert_eq!(player.position_seconds(), 0.0);
    }

    #[test]
    fn seek_while_stopped_keeps_the_position_for_the_next_play() {
        let mut player = playing(2, 48_000, 0.0);
        let mut fx = effects();
        player.stop(&mut fx);
        block(&mut player, 512);
        player.seek_seconds(0.5);
        assert!((player.position_seconds() - 0.5).abs() < 1e-4);
        assert!(player.play_loaded("/a.wav", 0.5));
        let (data, _) = block(&mut player, 512);
        assert!(data[2 * 400] > 0.4);
        assert!((player.position_seconds() - (0.5 + 512.0 / RATE)).abs() < 1e-4);
    }

    #[test]
    fn seek_while_playing_fades_out_then_jumps() {
        let mut player = playing(2, 48_000, 0.0);
        block(&mut player, 512);
        player.seek_seconds(0.5);
        let (data, _) = block(&mut player, 1024);
        assert!(
            player.position_seconds() > 0.5,
            "jumped to the new position"
        );
        assert!(player.position_seconds() < 0.6);
        let min = data.iter().cloned().fold(f32::MAX, f32::min);
        assert!(min.abs() < 0.01, "went through silence, min {min}");
        assert!(
            (data[2 * 1000] - PREVIEW_GAIN).abs() < 1e-4,
            "back at full gain"
        );
    }

    #[test]
    fn stop_fades_out_in_a_few_milliseconds() {
        let mut player = playing(2, 48_000, 0.0);
        block(&mut player, 512);
        let mut fx = effects();
        player.stop(&mut fx);
        assert_eq!(player.state(), PreviewState::Stopped);
        let (data, _) = block(&mut player, 512);
        assert!(
            data[0] > 0.0 && data[0] < PREVIEW_GAIN,
            "fading, got {}",
            data[0]
        );
        assert!(data[2 * 300] == 0.0, "silent after the fade");
    }

    #[test]
    fn a_stale_decode_result_is_ignored() {
        let mut player = PreviewPlayer::default();
        let mut fx = effects();
        player.begin_load("preview:1".into(), "/a.wav", 0.0, &mut fx);
        player.begin_load("preview:2".into(), "/b.wav", 0.0, &mut fx);
        assert!(!player.finish_load("preview:1", vec![1.0; 200], 2, RATE as u32, &mut fx));
        assert_eq!(player.state(), PreviewState::Loading);
        assert!(!player.has_loaded("/a.wav"));
        assert!(
            !fx.trash.is_empty(),
            "the stale PCM is dropped after the lock"
        );
        assert!(player.finish_load("preview:2", vec![1.0; 200], 2, RATE as u32, &mut fx));
        assert_eq!(player.state(), PreviewState::Playing);
        assert!(player.has_loaded("/b.wav"));
    }

    #[test]
    fn a_stop_during_loading_makes_the_result_stale() {
        let mut player = PreviewPlayer::default();
        let mut fx = effects();
        player.begin_load("preview:1".into(), "/a.wav", 0.0, &mut fx);
        player.stop(&mut fx);
        assert!(!player.finish_load("preview:1", vec![1.0; 200], 2, RATE as u32, &mut fx));
        assert_eq!(player.state(), PreviewState::Stopped);
    }

    #[test]
    fn a_failed_decode_reports_failed_only_for_the_current_request() {
        let mut player = PreviewPlayer::default();
        let mut fx = effects();
        player.begin_load("preview:1".into(), "/a.wav", 0.0, &mut fx);
        assert!(!player.fail_load("preview:0"));
        assert!(player.fail_load("preview:1"));
        assert_eq!(player.state(), PreviewState::Failed);
    }

    #[test]
    fn a_seek_during_loading_moves_the_start() {
        let mut player = PreviewPlayer::default();
        let mut fx = effects();
        player.begin_load("preview:1".into(), "/a.wav", 0.0, &mut fx);
        player.seek_seconds(0.25);
        player.finish_load("preview:1", vec![1.0; 2 * 48_000], 2, RATE as u32, &mut fx);
        assert!((player.position_seconds() - 0.25).abs() < 1e-4);
    }
}
