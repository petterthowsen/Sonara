//! Single-sample MIDI instrument: pitch, speed, polyphony, region, and ADSR.

use super::container::{gain_to_normalized, normalized_to_gain};
use super::{
    has_audio_signal, AudioDevice, DeviceCategory, DevicePath, DeviceSleepState, DeviceVariant,
    FileLoadingSupport, MidiPort, ParamId, ParamInfo, ParamType, ParamValue, PortFlow,
};
use crate::audio::commands::EngineStatus;
use crate::audio::dsp::{AdsrEnvelope, AdsrState};
use crossbeam::channel::Sender;
use tracing::{info, warn};

const MAX_VOICES: usize = 64;
const VOICES_MIN: usize = 1;
const DEFAULT_VOICES: usize = 16;
const MIDI_EVENT_CAP: usize = 64;
const DEFAULT_ROOT: u8 = 60;
const TUNE_RANGE: f32 = 24.0;
const SPEED_MIN: f32 = 0.25;
const SPEED_MAX: f32 = 4.0;
const TIME_MIN: f32 = 0.001;
const TIME_MAX: f32 = 2.0;
const DEFAULT_ATTACK: f32 = 0.001;
const DEFAULT_DECAY: f32 = 0.001;
const DEFAULT_SUSTAIN: f32 = 1.0;
const DEFAULT_RELEASE: f32 = 0.01;
const PARAM_VOLUME: ParamId = 0;
const PARAM_TUNE: ParamId = 1;
const PARAM_SPEED: ParamId = 2;
const PARAM_ROOT: ParamId = 3;
const PARAM_KEY_TRACK: ParamId = 4;
const PARAM_PLAY_MODE: ParamId = 5;
const PARAM_VELOCITY: ParamId = 6;
const PARAM_START: ParamId = 7;
const PARAM_END: ParamId = 8;
const PARAM_ATTACK: ParamId = 9;
const PARAM_DECAY: ParamId = 10;
const PARAM_SUSTAIN: ParamId = 11;
const PARAM_RELEASE: ParamId = 12;
const PARAM_VOICES: ParamId = 13;

/// Playback mode: one-shot ignores note-off; gated fades out on note-off.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PlayMode {
    OneShot,
    Gated,
}

/// Decoded interleaved PCM. `sample_rate` is the buffer rate, which may differ from the device.
struct SampleBuffer {
    samples: Vec<f32>,
    channels: usize,
    frames: usize,
    sample_rate: f32,
}

/// One voice reading the loaded sample through an ADSR amplitude envelope.
#[derive(Clone, Copy)]
struct Voice {
    active: bool,
    note: u8,
    position: f64,
    increment: f64,
    gain: f32,
    envelope: AdsrEnvelope,
    age: u64,
}

impl Voice {
    /// Idle voice with no playback, sized for `sample_rate`.
    fn idle(sample_rate: f32) -> Self {
        Self {
            active: false,
            note: 0,
            position: 0.0,
            increment: 1.0,
            gain: 0.0,
            envelope: AdsrEnvelope::new(sample_rate),
            age: 0,
        }
    }

    /// True while the voice is sounding and not yet in release.
    fn is_held(&self) -> bool {
        self.active && !matches!(self.envelope.state(), AdsrState::Idle | AdsrState::Release)
    }
}

/// Built-in Sampler: MIDI-triggered playback of one loaded audio file.
pub struct SamplerDevice {
    sample: Option<SampleBuffer>,
    voices: [Voice; MAX_VOICES],
    voice_count: usize,
    queued_midi: Vec<(usize, u8, u8, bool)>,
    midi_scratch: Vec<(usize, u8, u8, bool)>,
    sample_rate: f32,
    volume: f32,
    tune: f32,
    speed: f32,
    root: u8,
    key_track: bool,
    play_mode: PlayMode,
    velocity_amount: f32,
    start: f32,
    end: f32,
    attack: f32,
    decay: f32,
    sustain: f32,
    release: f32,
    enabled: bool,
    sleep_state: DeviceSleepState,
    channel_id: usize,
    device_path: DevicePath,
    status_tx: Option<Sender<EngineStatus>>,
    current_req_id: String,
    time_counter: u64,
}

/// Pitch/speed ratio: `speed * 2^((tune + keytrack*(note-root))/12)`.
pub fn playback_increment(speed: f32, tune: f32, key_track: bool, note: u8, root: u8) -> f64 {
    let key_delta = if key_track {
        note as f32 - root as f32
    } else {
        0.0
    };
    let semitones = tune + key_delta;
    (speed as f64) * 2.0_f64.powf(semitones as f64 / 12.0)
}

/// Frames of sample PCM to advance per device output frame so pitch stays native.
pub fn sample_rate_ratio(sample_rate: f32, device_sample_rate: f32) -> f64 {
    sample_rate.max(1.0) as f64 / device_sample_rate.max(1.0) as f64
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

/// Map a normalized 0–1 value onto the ADSR time range in seconds.
fn time_from_normalized(value: f32) -> f32 {
    TIME_MIN + value.clamp(0.0, 1.0) * (TIME_MAX - TIME_MIN)
}

/// Inverse of [`time_from_normalized`].
fn time_to_normalized(seconds: f32) -> f32 {
    ((seconds - TIME_MIN) / (TIME_MAX - TIME_MIN)).clamp(0.0, 1.0)
}

/// Map a normalized 0–1 value onto the integer Voices range.
fn voices_from_normalized(value: f32) -> usize {
    let span = (MAX_VOICES - VOICES_MIN) as f32;
    let n = (value.clamp(0.0, 1.0) * span).round() as usize + VOICES_MIN;
    n.clamp(VOICES_MIN, MAX_VOICES)
}

/// Inverse of [`voices_from_normalized`].
fn voices_to_normalized(count: usize) -> f32 {
    let c = count.clamp(VOICES_MIN, MAX_VOICES);
    (c - VOICES_MIN) as f32 / (MAX_VOICES - VOICES_MIN) as f32
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
            let env = voice.envelope.process_sample();
            let (l, r) = interpolate_frame(sample, voice.position);
            let g = voice.gain * env;
            let idx = (start + i) * 2;
            if idx + 1 < outputs.len() {
                outputs[idx] += l * g;
                outputs[idx + 1] += r * g;
            }
            voice.position += voice.increment;
            if voice.position >= region_end {
                voice.envelope.gate_off();
            }
            if !voice.envelope.is_active() {
                voice.active = false;
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
        sample_rate: f32,
        channel_id: usize,
        device_path: DevicePath,
        status_tx: Option<Sender<EngineStatus>>,
    ) -> Self {
        let sample_rate = sample_rate.max(1.0);
        Self {
            sample: None,
            voices: [Voice::idle(sample_rate); MAX_VOICES],
            voice_count: DEFAULT_VOICES,
            queued_midi: Vec::with_capacity(MIDI_EVENT_CAP),
            midi_scratch: Vec::with_capacity(MIDI_EVENT_CAP),
            sample_rate,
            volume: 1.0,
            tune: 0.0,
            speed: 1.0,
            root: DEFAULT_ROOT,
            key_track: true,
            play_mode: PlayMode::OneShot,
            velocity_amount: 1.0,
            start: 0.0,
            end: 1.0,
            attack: DEFAULT_ATTACK,
            decay: DEFAULT_DECAY,
            sustain: DEFAULT_SUSTAIN,
            release: DEFAULT_RELEASE,
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
            sample_rate: (sample_rate as f32).max(1.0),
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
        self.voices = [Voice::idle(self.sample_rate); MAX_VOICES];
    }

    fn any_voice_active(&self) -> bool {
        self.voices[..self.voice_count].iter().any(|v| v.active)
    }

    /// Apply the device ADSR settings to every voice, including notes already sounding.
    fn apply_envelope_params(&mut self) {
        for voice in &mut self.voices {
            voice
                .envelope
                .set_adsr(self.attack, self.decay, self.sustain, self.release);
        }
    }

    /// Limit polyphony and silence slots that fall outside the new count.
    fn set_voice_count(&mut self, count: usize) {
        let count = count.clamp(VOICES_MIN, MAX_VOICES);
        if count < self.voice_count {
            for voice in &mut self.voices[count..self.voice_count] {
                *voice = Voice::idle(self.sample_rate);
            }
        }
        self.voice_count = count;
    }

    /// Oldest held voice playing `note`, so gated note-off pairs with note-on.
    fn find_held_voice_for_note(&self, note: u8) -> Option<usize> {
        self.voices[..self.voice_count]
            .iter()
            .enumerate()
            .filter(|(_, v)| v.is_held() && v.note == note)
            .min_by_key(|(_, v)| v.age)
            .map(|(i, _)| i)
    }

    /// Free slot in the polyphony pool, or steal a releasing then oldest voice.
    fn allocate_voice(&self) -> Option<usize> {
        let pool = &self.voices[..self.voice_count];
        pool.iter().position(|v| !v.active).or_else(|| {
            pool.iter()
                .enumerate()
                .min_by_key(|(_, v)| {
                    let releasing = matches!(v.envelope.state(), AdsrState::Release);
                    (if releasing { 0u8 } else { 1u8 }, v.age)
                })
                .map(|(i, _)| i)
        })
    }

    fn note_on(&mut self, note: u8, velocity: u8) {
        let Some(idx) = self.allocate_voice() else {
            return;
        };
        let Some(sample) = self.sample.as_ref() else {
            return;
        };
        let (region_start, _) = region_frames(sample.frames, self.start, self.end);
        let increment = playback_increment(self.speed, self.tune, self.key_track, note, self.root)
            * sample_rate_ratio(sample.sample_rate, self.sample_rate);
        let vel = (velocity as f32) / 127.0;
        let vel_gain = (1.0 - self.velocity_amount) + self.velocity_amount * vel;
        if increment <= 0.0 {
            return;
        }
        let mut envelope = AdsrEnvelope::new(self.sample_rate);
        envelope.set_adsr(self.attack, self.decay, self.sustain, self.release);
        envelope.gate_on();
        self.time_counter = self.time_counter.wrapping_add(1);
        self.voices[idx] = Voice {
            active: true,
            note,
            position: region_start,
            increment,
            gain: self.volume * vel_gain,
            envelope,
            age: self.time_counter,
        };
        self.sleep_state.mark_activity();
    }

    fn note_off(&mut self, note: u8) {
        if self.play_mode != PlayMode::Gated {
            return;
        }
        if let Some(idx) = self.find_held_voice_for_note(note) {
            self.voices[idx].envelope.gate_off();
        }
    }

    fn render_voices(&mut self, outputs: &mut [f32], start: usize, len: usize) {
        let Some(sample) = self.sample.as_ref() else {
            return;
        };
        let region_end = region_frames(sample.frames, self.start, self.end).1;
        let limit = self.voice_count;
        render_active_voices(
            sample,
            &mut self.voices[..limit],
            region_end,
            outputs,
            start,
            len,
        );
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
            // Speed: logarithmic 0.25–4x. Matches DeviceParameter.gd when is_logarithmic.
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
            PARAM_VOICES => self.set_voice_count(voices_from_normalized(value)),
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
            PARAM_ATTACK => {
                self.attack = time_from_normalized(value);
                self.apply_envelope_params();
            }
            PARAM_DECAY => {
                self.decay = time_from_normalized(value);
                self.apply_envelope_params();
            }
            PARAM_SUSTAIN => {
                self.sustain = value.clamp(0.0, 1.0);
                self.apply_envelope_params();
            }
            PARAM_RELEASE => {
                self.release = time_from_normalized(value);
                self.apply_envelope_params();
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
            PARAM_VOICES => Some(voices_to_normalized(self.voice_count)),
            PARAM_VELOCITY => Some(self.velocity_amount),
            PARAM_START => Some(self.start),
            PARAM_END => Some(self.end),
            PARAM_ATTACK => Some(time_to_normalized(self.attack)),
            PARAM_DECAY => Some(time_to_normalized(self.decay)),
            PARAM_SUSTAIN => Some(self.sustain),
            PARAM_RELEASE => Some(time_to_normalized(self.release)),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Enum,
                syncable: true,
                enum_values: vec!["One-shot".to_string(), "Gated".to_string()],
            },
            ParamInfo {
                id: PARAM_VOICES,
                name: "Voices".to_string(),
                unit: String::new(),
                min: VOICES_MIN as f32,
                max: MAX_VOICES as f32,
                default: DEFAULT_VOICES as f32,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_VELOCITY,
                name: "Velocity".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 1.0,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_ATTACK,
                name: "Attack".to_string(),
                unit: "s".to_string(),
                min: TIME_MIN,
                max: TIME_MAX,
                default: DEFAULT_ATTACK,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_DECAY,
                name: "Decay".to_string(),
                unit: "s".to_string(),
                min: TIME_MIN,
                max: TIME_MAX,
                default: DEFAULT_DECAY,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_SUSTAIN,
                name: "Sustain".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: DEFAULT_SUSTAIN,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
                param_type: ParamType::Float,
                syncable: true,
                enum_values: Vec::new(),
            },
            ParamInfo {
                id: PARAM_RELEASE,
                name: "Release".to_string(),
                unit: "s".to_string(),
                min: TIME_MIN,
                max: TIME_MAX,
                default: DEFAULT_RELEASE,
                is_automation_safe: true,
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                module: String::new(),
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

    /// Adopt the new rate. The loaded sample keeps its own rate: playback already compensates
    /// through `sample_rate_ratio`, so it doesn't need decoding again.
    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate.max(1.0);
        self.voices = [Voice::idle(self.sample_rate); MAX_VOICES];
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
    fn default_speed_normalized_is_log_midpoint() {
        let sampler = SamplerDevice::new_for_metadata();
        let normalized = sampler.get_parameter(PARAM_SPEED).unwrap();
        assert!(
            (normalized - 0.5).abs() < 1e-5,
            "unity speed must be OSC 0.5 (log), not linear (1.0-0.25)/(4-0.25)=0.2"
        );
        assert!((speed_from_normalized(0.5) - 1.0).abs() < 1e-5);
        let linear_of_default = (1.0 - SPEED_MIN) / (SPEED_MAX - SPEED_MIN);
        assert!((speed_from_normalized(linear_of_default) - 1.0).abs() > 0.4);
    }

    #[test]
    fn sample_rate_ratio_compensates_44k_on_48k_device() {
        let ratio = sample_rate_ratio(44_100.0, 48_000.0);
        assert!((ratio - 44_100.0 / 48_000.0).abs() < 1e-12);
    }

    #[test]
    fn mismatched_sample_rate_slows_or_speeds_root_playback() {
        let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        sampler.set_sample("r", vec![0.5; 8], 2, 44_100);
        sampler.note_on(60, 127);
        let voice = sampler.voices.iter().find(|v| v.active).unwrap();
        let expected = 44_100.0 / 48_000.0;
        assert!((voice.increment - expected).abs() < 1e-9);
    }

    #[test]
    fn one_shot_ignores_note_off() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 127);
        sampler.note_off(60);
        assert!(sampler.voices.iter().any(|v| v.is_held()));
    }

    #[test]
    fn gated_releases_on_note_off() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_parameter(PARAM_PLAY_MODE, 1.0);
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 127);
        sampler.note_off(60);
        assert!(sampler
            .voices
            .iter()
            .any(|v| v.active && v.envelope.state() == AdsrState::Release));
    }

    #[test]
    fn region_rejects_inverted_start_end() {
        let (a, b) = region_frames(100, 0.8, 0.2);
        assert!(b > a);
    }

    #[test]
    fn attack_fades_in_from_silence() {
        let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        sampler.set_sample("r", vec![1.0; 256], 2, 48_000);
        sampler.note_on(60, 127);
        let mut out = vec![0.0; 16];
        sampler.process_block(&[], &mut out, 8);
        assert!(out[0].abs() < 0.1, "first sample should be near silence");
        assert!(
            out[0].abs() < out[14].abs(),
            "attack should rise across the block"
        );
    }

    #[test]
    fn sample_end_triggers_release() {
        let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        sampler.set_parameter(PARAM_RELEASE, 1.0);
        sampler.set_sample("r", vec![0.5, 0.5], 2, 48_000);
        sampler.note_on(60, 127);
        let mut out = vec![0.0; 8];
        sampler.process_block(&[], &mut out, 4);
        assert!(sampler
            .voices
            .iter()
            .any(|v| v.active && v.envelope.state() == AdsrState::Release));
    }

    #[test]
    fn adsr_params_roundtrip() {
        let mut sampler = SamplerDevice::new_for_metadata();
        sampler.set_parameter(PARAM_ATTACK, 0.5);
        sampler.set_parameter(PARAM_DECAY, 0.25);
        sampler.set_parameter(PARAM_SUSTAIN, 0.8);
        sampler.set_parameter(PARAM_RELEASE, 0.1);
        assert!((sampler.get_parameter(PARAM_ATTACK).unwrap() - 0.5).abs() < 1e-5);
        assert!((sampler.get_parameter(PARAM_DECAY).unwrap() - 0.25).abs() < 1e-5);
        assert!((sampler.get_parameter(PARAM_SUSTAIN).unwrap() - 0.8).abs() < 1e-5);
        assert!((sampler.get_parameter(PARAM_RELEASE).unwrap() - 0.1).abs() < 1e-5);
    }

    #[test]
    fn voices_roundtrip_and_default() {
        let mut sampler = SamplerDevice::new_for_metadata();
        assert_eq!(sampler.voice_count, DEFAULT_VOICES);
        sampler.set_parameter(PARAM_VOICES, voices_to_normalized(1));
        assert_eq!(sampler.voice_count, 1);
        sampler.set_parameter(PARAM_VOICES, 1.0);
        assert_eq!(sampler.voice_count, MAX_VOICES);
        assert!((sampler.get_parameter(PARAM_VOICES).unwrap() - 1.0).abs() < 1e-5);
    }

    #[test]
    fn retrigger_overlaps_until_voice_limit() {
        let mut sampler = SamplerDevice::new(48_000.0, 0, DevicePath::root(0), None);
        sampler.set_sample("r", vec![0.5; 8], 2, 48_000);
        sampler.note_on(60, 127);
        sampler.note_on(60, 127);
        assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 2);

        sampler.set_parameter(PARAM_VOICES, voices_to_normalized(1));
        assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 1);

        sampler.note_on(60, 127);
        assert_eq!(sampler.voices.iter().filter(|v| v.active).count(), 1);
    }
}
