//! Single-sample MIDI instrument: pitch, speed, key-track, and a playback region.

use super::container::{gain_to_normalized, normalized_to_gain};
use super::{
    has_audio_signal, AudioDevice, DeviceCategory, DevicePath, DeviceSleepState, DeviceVariant,
    FileLoadingSupport, MidiPort, ParamId, ParamInfo, ParamType, ParamValue, PortFlow,
};
use crate::audio::commands::EngineStatus;
use crossbeam::channel::Sender;
use tracing::{info, warn};

const VOICE_COUNT: usize = 16;
const FADE_SAMPLES: f32 = 64.0;
const MIDI_EVENT_CAP: usize = 64;
const DEFAULT_ROOT: u8 = 60;
const TUNE_RANGE: f32 = 24.0;
const SPEED_MIN: f32 = 0.25;
const SPEED_MAX: f32 = 4.0;
const PARAM_VOLUME: ParamId = 0;
const PARAM_TUNE: ParamId = 1;
const PARAM_SPEED: ParamId = 2;
const PARAM_ROOT: ParamId = 3;
const PARAM_KEY_TRACK: ParamId = 4;
const PARAM_PLAY_MODE: ParamId = 5;
const PARAM_VELOCITY: ParamId = 6;
const PARAM_START: ParamId = 7;
const PARAM_END: ParamId = 8;

/// Playback mode: one-shot ignores note-off; gated fades out on note-off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PlayMode {
    OneShot,
    Gated,
}

/// Decoded interleaved PCM owned by the sampler (device sample rate).
struct SampleBuffer {
    samples: Vec<f32>,
    channels: usize,
    frames: usize,
}

/// One voice reading the loaded sample.
#[derive(Clone, Copy)]
struct Voice {
    active: bool,
    fading: bool,
    note: u8,
    position: f64,
    increment: f64,
    gain: f32,
    fade: f32,
    fade_step: f32,
    age: u64,
}

impl Voice {
    /// Idle voice with no playback.
    fn idle() -> Self {
        Self {
            active: false,
            fading: false,
            note: 0,
            position: 0.0,
            increment: 1.0,
            gain: 0.0,
            fade: 1.0,
            fade_step: 1.0 / FADE_SAMPLES,
            age: 0,
        }
    }

    /// Begin a short gain ramp so note-off and voice-steal do not click.
    fn start_fade(&mut self) {
        if !self.active {
            return;
        }
        self.fading = true;
        if self.fade_step <= 0.0 {
            self.fade_step = 1.0 / FADE_SAMPLES;
        }
    }
}

/// Built-in Sampler: MIDI-triggered playback of one loaded audio file.
pub struct SamplerDevice {
    sample: Option<SampleBuffer>,
    voices: [Voice; VOICE_COUNT],
    queued_midi: Vec<(usize, u8, u8, bool)>,
    midi_scratch: Vec<(usize, u8, u8, bool)>,
    volume: f32,
    tune: f32,
    speed: f32,
    root: u8,
    key_track: bool,
    play_mode: PlayMode,
    velocity_amount: f32,
    start: f32,
    end: f32,
    enabled: bool,
    sleep_state: DeviceSleepState,
    channel_id: usize,
    device_path: DevicePath,
    status_tx: Option<Sender<EngineStatus>>,
    current_req_id: String,
    time_counter: u64,
}

/// Playback rate: `speed * 2^((tune + keytrack*(note-root))/12)`.
pub fn playback_increment(speed: f32, tune: f32, key_track: bool, note: u8, root: u8) -> f64 {
    let key_delta = if key_track {
        note as f32 - root as f32
    } else {
        0.0
    };
    let semitones = tune + key_delta;
    (speed as f64) * 2.0_f64.powf(semitones as f64 / 12.0)
}

/// Map a normalized 0–1 value onto a logarithmic speed range.
fn speed_from_normalized(value: f32) -> f32 {
    let t = value.clamp(0.0, 1.0);
    SPEED_MIN * (SPEED_MAX / SPEED_MIN).powf(t)
}

/// Inverse of [`speed_from_normalized`].
fn speed_to_normalized(speed: f32) -> f32 {
    let clamped = speed.clamp(SPEED_MIN, SPEED_MAX);
    (clamped / SPEED_MIN).log(SPEED_MAX / SPEED_MIN)
}

/// Inclusive start frame and exclusive end frame for the playback region.
fn region_frames(frames: usize, start: f32, end: f32) -> (f64, f64) {
    if frames == 0 {
        return (0.0, 0.0);
    }
    let max = frames as f64;
    let mut a = (start.clamp(0.0, 1.0) as f64) * max;
    let mut b = (end.clamp(0.0, 1.0) as f64) * max;
    if b <= a {
        b = (a + 1.0).min(max);
        if b <= a {
            a = (b - 1.0).max(0.0);
        }
    }
    (a, b)
}

/// Mix active voices into `outputs` for `len` frames starting at `start`.
fn render_active_voices(
    sample: &SampleBuffer,
    voices: &mut [Voice],
    region_end: f64,
    outputs: &mut [f32],
    start: usize,
    len: usize,
) {
    for voice in voices {
        if !voice.active {
            continue;
        }
        for i in 0..len {
            if !voice.active {
                break;
            }
            let (l, r) = interpolate_frame(sample, voice.position);
            let g = voice.gain * voice.fade;
            let idx = (start + i) * 2;
            if idx + 1 < outputs.len() {
                outputs[idx] += l * g;
                outputs[idx + 1] += r * g;
            }
            voice.position += voice.increment;
            if voice.fading {
                voice.fade -= voice.fade_step;
                if voice.fade <= 0.0 {
                    voice.active = false;
                    voice.fade = 0.0;
                }
            } else if voice.position >= region_end {
                voice.start_fade();
            }
        }
    }
}

/// Linearly interpolate one stereo frame from interleaved PCM.
fn interpolate_frame(sample: &SampleBuffer, position: f64) -> (f32, f32) {
    if sample.frames == 0 || sample.channels == 0 {
        return (0.0, 0.0);
    }
    let last = (sample.frames - 1) as f64;
    let pos = position.clamp(0.0, last);
    let i0 = pos.floor() as usize;
    let i1 = (i0 + 1).min(sample.frames - 1);
    let frac = (pos - i0 as f64) as f32;
    let ch = sample.channels;
    let read = |frame: usize, channel: usize| -> f32 {
        let idx = frame * ch + channel.min(ch - 1);
        sample.samples.get(idx).copied().unwrap_or(0.0)
    };
    if ch == 1 {
        let a = read(i0, 0);
        let b = read(i1, 0);
        let v = a + (b - a) * frac;
        (v, v)
    } else {
        let l0 = read(i0, 0);
        let l1 = read(i1, 0);
        let r0 = read(i0, 1);
        let r1 = read(i1, 1);
        (l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac)
    }
}

impl SamplerDevice {
    /// Create a sampler that reports loading state for `channel_id` / `device_path`.
    pub fn new(
        _sample_rate: f32,
        channel_id: usize,
        device_path: DevicePath,
        status_tx: Option<Sender<EngineStatus>>,
    ) -> Self {
        Self {
            sample: None,
            voices: [Voice::idle(); VOICE_COUNT],
            queued_midi: Vec::with_capacity(MIDI_EVENT_CAP),
            midi_scratch: Vec::with_capacity(MIDI_EVENT_CAP),
            volume: 1.0,
            tune: 0.0,
            speed: 1.0,
            root: DEFAULT_ROOT,
            key_track: true,
            play_mode: PlayMode::OneShot,
            velocity_amount: 1.0,
            start: 0.0,
            end: 1.0,
            enabled: true,
            sleep_state: DeviceSleepState::new(),
            channel_id,
            device_path,
            status_tx,
            current_req_id: String::new(),
            time_counter: 0,
        }
    }

    /// Metadata-only instance used when advertising built-ins.
    pub fn new_for_metadata() -> Self {
        Self::new(48_000.0, 0, DevicePath::root(0), None)
    }

    /// Mark this device as loading `req_id` so stale AFS completions can be ignored.
    pub fn begin_sample_load(&mut self, req_id: String) {
        self.current_req_id = req_id.clone();
        info!(
            "Sampler begin load channel={} path={} req={}",
            self.channel_id, self.device_path, req_id
        );
        self.emit_loading("loading", &req_id);
    }

    /// Replace the playable buffer. Voices are killed because they pointed at the old PCM.
    pub fn set_sample(
        &mut self,
        req_id: &str,
        samples: Vec<f32>,
        channels: usize,
        sample_rate: u32,
    ) {
        if !self.current_req_id.is_empty() && self.current_req_id != req_id {
            warn!(
                "Ignoring stale sampler load (expected {}, got {})",
                self.current_req_id, req_id
            );
            return;
        }
        let ch = channels.max(1);
        let frames = if ch > 0 { samples.len() / ch } else { 0 };
        info!(
            "Sampler ready: {} frames, {} ch, {} Hz ({} samples)",
            frames,
            ch,
            sample_rate,
            samples.len()
        );
        self.reset_voices();
        self.sample = Some(SampleBuffer {
            samples,
            channels: ch,
            frames,
        });
        self.sleep_state.mark_activity();
        self.emit_loading("ready", req_id);
    }

    /// Record a failed load without dropping a previously ready sample.
    pub fn fail_sample_load(&mut self, req_id: &str, message: &str) {
        if !self.current_req_id.is_empty() && self.current_req_id != req_id {
            return;
        }
        warn!("Sampler load failed: {}", message);
        self.emit_loading(&format!("failed:{}", message), req_id);
    }

    fn emit_loading(&self, state: &str, req_id: &str) {
        if let Some(tx) = &self.status_tx {
            let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                state: state.to_string(),
            });
            let _ = req_id;
        }
    }

    fn reset_voices(&mut self) {
        self.voices = [Voice::idle(); VOICE_COUNT];
    }

    fn any_voice_active(&self) -> bool {
        self.voices.iter().any(|v| v.active)
    }

    fn find_voice_for_note(&self, note: u8) -> Option<usize> {
        self.voices
            .iter()
            .position(|v| v.active && !v.fading && v.note == note)
    }

    fn find_free_voice(&self) -> Option<usize> {
        self.voices.iter().position(|v| !v.active)
    }

    fn steal_voice(&self) -> Option<usize> {
        self.voices
            .iter()
            .enumerate()
            .min_by_key(|(_, v)| v.age)
            .map(|(i, _)| i)
    }

    fn note_on(&mut self, note: u8, velocity: u8) {
        let idx = self
            .find_voice_for_note(note)
            .or_else(|| self.find_free_voice())
            .or_else(|| self.steal_voice());
        let Some(idx) = idx else {
            return;
        };
        let Some(sample) = self.sample.as_ref() else {
            return;
        };
        let (region_start, _) = region_frames(sample.frames, self.start, self.end);
        let vel = (velocity as f32) / 127.0;
        let vel_gain = (1.0 - self.velocity_amount) + self.velocity_amount * vel;
        let increment = playback_increment(self.speed, self.tune, self.key_track, note, self.root);
        if increment <= 0.0 {
            return;
        }
        let voice = &mut self.voices[idx];
        *voice = Voice {
            active: true,
            fading: false,
            note,
            position: region_start,
            increment,
            gain: self.volume * vel_gain,
            fade: 1.0,
            fade_step: 1.0 / FADE_SAMPLES,
            age: self.time_counter,
        };
        self.sleep_state.mark_activity();
    }

    fn note_off(&mut self, note: u8) {
        if self.play_mode != PlayMode::Gated {
            return;
        }
        if let Some(idx) = self.find_voice_for_note(note) {
            self.voices[idx].start_fade();
        }
    }

    fn render_voices(&mut self, outputs: &mut [f32], start: usize, len: usize) {
        let Some(sample) = self.sample.as_ref() else {
            return;
        };
        let region_end = region_frames(sample.frames, self.start, self.end).1;
        render_active_voices(sample, &mut self.voices, region_end, outputs, start, len);
    }

    fn apply_midi(&mut self, note: u8, velocity: u8, is_on: bool) {
        if is_on && velocity > 0 {
            self.note_on(note, velocity);
        } else {
            self.note_off(note);
        }
    }
}

impl AudioDevice for SamplerDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let interleaved = (sample_count * 2).min(outputs.len());
        outputs[..interleaved].fill(0.0);

        if !self.enabled {
            return;
        }

        std::mem::swap(&mut self.queued_midi, &mut self.midi_scratch);
        self.queued_midi.clear();
        self.midi_scratch.sort_unstable_by_key(|e| e.0);

        let mut cursor = 0usize;
        let mut idx = 0usize;
        while idx < self.midi_scratch.len() {
            let span_end = self.midi_scratch[idx].0.min(sample_count);
            if span_end > cursor {
                self.render_voices(outputs, cursor, span_end - cursor);
                cursor = span_end;
            }
            let this_ofs = self.midi_scratch[idx].0;
            while idx < self.midi_scratch.len() && self.midi_scratch[idx].0 == this_ofs {
                let (_ofs, note, velocity, is_on) = self.midi_scratch[idx];
                self.apply_midi(note, velocity, is_on);
                idx += 1;
            }
        }
        if cursor < sample_count {
            self.render_voices(outputs, cursor, sample_count - cursor);
        }
        self.midi_scratch.clear();
        self.time_counter = self.time_counter.wrapping_add(1);

        let active = self.any_voice_active();
        self.sleep_state
            .check_activity(active || has_audio_signal(&outputs[..interleaved]));
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        if self.queued_midi.len() >= MIDI_EVENT_CAP {
            return;
        }
        self.queued_midi
            .push((frame_offset, note, velocity, is_note_on));
        self.sleep_state.mark_activity();
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.sleep_state.mark_activity();
        match param_id {
            PARAM_VOLUME => self.volume = normalized_to_gain(value),
            PARAM_TUNE => self.tune = value.clamp(0.0, 1.0) * (TUNE_RANGE * 2.0) - TUNE_RANGE,
            PARAM_SPEED => self.speed = speed_from_normalized(value),
            PARAM_ROOT => self.root = (value.clamp(0.0, 1.0) * 127.0).round() as u8,
            PARAM_KEY_TRACK => self.key_track = value >= 0.5,
            PARAM_PLAY_MODE => {
                self.play_mode = if value >= 0.5 {
                    PlayMode::Gated
                } else {
                    PlayMode::OneShot
                };
            }
            PARAM_VELOCITY => self.velocity_amount = value.clamp(0.0, 1.0),
            PARAM_START => {
                self.start = value.clamp(0.0, 1.0);
                if self.start >= self.end {
                    self.start = (self.end - 0.001).max(0.0);
                }
            }
            PARAM_END => {
                self.end = value.clamp(0.0, 1.0);
                if self.end <= self.start {
                    self.end = (self.start + 0.001).min(1.0);
                }
            }
            _ => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        match param_id {
            PARAM_VOLUME => Some(gain_to_normalized(self.volume)),
            PARAM_TUNE => Some((self.tune + TUNE_RANGE) / (TUNE_RANGE * 2.0)),
            PARAM_SPEED => Some(speed_to_normalized(self.speed)),
            PARAM_ROOT => Some(self.root as f32 / 127.0),
            PARAM_KEY_TRACK => Some(if self.key_track { 1.0 } else { 0.0 }),
            PARAM_PLAY_MODE => Some(match self.play_mode {
                PlayMode::OneShot => 0.0,
                PlayMode::Gated => 1.0,
            }),
            PARAM_VELOCITY => Some(self.velocity_amount),
            PARAM_START => Some(self.start),
            PARAM_END => Some(self.end),
            _ => None,
        }
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.sampler"
    }

    fn device_name(&self) -> &str {
        "Sampler"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Instrument
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn midi_ports(&self) -> Vec<MidiPort> {
        vec![MidiPort {
            id: 0,
            name: "MIDI In".to_string(),
            flow: PortFlow::Input,
        }]
    }

    fn file_loading_support(&self) -> Option<FileLoadingSupport> {
        Some(FileLoadingSupport {
            description: "Audio Sample".to_string(),
            extensions: vec![
                ".wav".to_string(),
                ".mp3".to_string(),
                ".ogg".to_string(),
                ".WAV".to_string(),
                ".MP3".to_string(),
                ".OGG".to_string(),
            ],
        })
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        vec![
            ParamInfo {
                id: PARAM_VOLUME,
                name: "Volume".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 2.0,
                default: 1.0,
                is_automation_safe: true,
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_TUNE,
                name: "Tune".to_string(),
                unit: "st".to_string(),
                min: -TUNE_RANGE,
                max: TUNE_RANGE,
                default: 0.0,
                is_automation_safe: true,
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_SPEED,
                name: "Speed".to_string(),
                unit: "x".to_string(),
                min: SPEED_MIN,
                max: SPEED_MAX,
                default: 1.0,
                is_automation_safe: true,
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_ROOT,
                name: "Root".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 127.0,
                default: DEFAULT_ROOT as f32,
                is_automation_safe: true,
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_KEY_TRACK,
                name: "Key Track".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 1.0,
                is_automation_safe: true,
                param_type: ParamType::Bool,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_PLAY_MODE,
                name: "Play Mode".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.0,
                is_automation_safe: true,
                param_type: ParamType::Enum,
                syncable: true,
                enum_values: vec!["One-shot".to_string(), "Gated".to_string()],
            },
            ParamInfo {
                id: PARAM_VELOCITY,
                name: "Velocity".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 1.0,
                is_automation_safe: true,
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_START,
                name: "Start".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.0,
                is_automation_safe: true,
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_END,
                name: "End".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 1.0,
                is_automation_safe: true,
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
        ]
    }

    fn reset(&mut self) {
        self.reset_voices();
        self.queued_midi.clear();
        self.midi_scratch.clear();
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.reset_voices();
        }
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn is_sleeping(&self) -> bool {
        self.sleep_state.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.sleep_state.mark_activity();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        self.sleep_state.check_activity(has_audio_activity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_track_transposes_from_root() {
        let at_root = playback_increment(1.0, 0.0, true, 60, 60);
        let up_octave = playback_increment(1.0, 0.0, true, 72, 60);
        assert!((at_root - 1.0).abs() < 1e-9);
        assert!((up_octave - 2.0).abs() < 1e-9);
    }

    #[test]
    fn key_track_off_ignores_note() {
        let a = playback_increment(1.0, 0.0, false, 36, 60);
        let b = playback_increment(1.0, 12.0, false, 80, 60);
        assert!((a - 1.0).abs() < 1e-9);
        assert!((b - 2.0).abs() < 1e-9);
    }

    #[test]
    fn speed_compounds_with_tune() {
        let rate = playback_increment(2.0, 12.0, false, 60, 60);
        assert!((rate - 4.0).abs() < 1e-9);
    }

    #[test]
    fn one_shot_ignores_note_off() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 127);
        sampler.note_off(60);
        assert!(sampler.voices.iter().any(|v| v.active && !v.fading));
    }

    #[test]
    fn gated_fades_on_note_off() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_parameter(PARAM_PLAY_MODE, 1.0);
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 127);
        sampler.note_off(60);
        assert!(sampler.voices.iter().any(|v| v.active && v.fading));
    }

    #[test]
    fn region_rejects_inverted_start_end() {
        let (a, b) = region_frames(100, 0.8, 0.2);
        assert!(b > a);
    }
}
