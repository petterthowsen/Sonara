//! Sampler MIDI instrument: pitch, speed, polyphony, region, loop, per-voice filter, ADSR.
//!
//! - Every voice plays a [`Zone`]: PCM, resolved regions and per-sample settings. Single-sample
//!   mode has one implicit zone, `single`, rebuilt from the device parameters. Multisample mode
//!   (spec 023) holds up to [`MAX_ZONES`] zones sent by Godot as real-unit snapshots; at note-on
//!   [`select_zones`] picks the matching ones (ranges, group mute/solo, round robin/random) and
//!   each starts a voice keyed from the zone's root. A note-off releases every voice its note-on
//!   started. Device Root/Tune/Fine/Start/End/Reverse/Loop/Crossfade only feed `single`.
//! - Start, End, Loop Start and Loop End are stored raw (normalized over the whole file) and
//!   ordered/clamped at use time by [`resolve_regions`], so restoring a state where several of
//!   them move at once doesn't depend on the order the values arrive in.
//! - Loop Off plays Start→End (End→Start when Reverse) and ends with a short declick; it never
//!   reads past the boundary. Loop On wraps inside the loop; Ping-Pong bounces. With any loop on,
//!   note-off releases even in One-shot. Points stay in file space whatever the direction.
//! - The crossfade blends the loop's tail with the material just before Loop Start (just after
//!   Loop End when reversed). Ping-Pong is already continuous, so it ignores the crossfade.
//! - The filter runs per voice (key tracking is per note) in chunks of [`FILTER_CHUNK`] frames.
//! - Data stream `"playheads"`: `u32 count` then `count` × (`f32 position` 0–1 over the whole
//!   file, `f32 velocity` signed file-fractions per second, `f32 level` 0–1), every ~33 ms of
//!   audio, plus one `count = 0` frame when the last voice ends. In multisample mode only the
//!   focused zone's voices are listed, normalized over that zone's file.

mod multisample;
mod params;
mod playback;
mod regions;
#[cfg(test)]
mod tests;
mod voice;
pub mod zones;

use crate::audio::commands::EngineStatus;
use crate::audio::devices::param_table::ParamValues;
use crate::audio::devices::{
    has_audio_signal, AudioDevice, DeviceCategory, DevicePath, DeviceSleepState, DeviceVariant,
    FileLoadingSupport, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::midi_types::NoteEvent;
use crossbeam::channel::Sender;
use params::{Params, MAX_VOICES, MIDI_EVENT_CAP, PARAM_COUNT, TABLE};
use regions::{SampleBuffer, Zone};
use tracing::{info, warn};
use voice::{Voice, CHOKE_KEY, FILTER_RAMP_MS};
use zones::ZoneGroup;

/// Audio between `"playheads"` records.
const PLAYHEAD_INTERVAL_SECONDS: f32 = 0.033;

const PLAYHEAD_RECORD_BYTES: usize = 12;

/// Built-in Sampler: MIDI-triggered playback of one audio file, or of zones in multisample mode.
pub struct SamplerDevice {
    /// The single-sample mode zone, rebuilt from the parameters.
    single: Zone,
    multisample: bool,
    /// Multisample zones. Capacity [`MAX_ZONES`] is reserved when the mode turns on, so the
    /// audio thread never sees it grow.
    zones: Vec<Zone>,
    /// Zone groups, Ungrouped first. Reserved to [`MAX_GROUPS`] with the zones.
    groups: Vec<ZoneGroup>,
    any_solo: bool,
    /// Zone indices matching the current note-on, capacity [`MAX_ZONES`].
    match_scratch: Vec<u16>,
    /// xorshift state for Random groups.
    rng: u32,
    /// Zone id whose voices the `"playheads"` stream reports in multisample mode.
    focused_zone: u32,
    trigger_counter: u64,
    voices: [Voice; MAX_VOICES],
    voice_count: usize,
    /// (frame_offset, key, velocity or release, is_note_on)
    queued_midi: Vec<(usize, u8, f32, bool)>,
    midi_scratch: Vec<(usize, u8, f32, bool)>,
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,
    p: Params,
    cutoff: SmoothedParam,
    resonance: SmoothedParam,
    /// A pitch parameter changed: recompute the increment of sounding voices next block.
    pitch_dirty: bool,
    enabled: bool,
    sleep_state: DeviceSleepState,
    channel_id: usize,
    device_path: DevicePath,
    status_tx: Option<Sender<EngineStatus>>,
    time_counter: u64,
    playheads_subscribed: bool,
    frames_since_poll: usize,
    /// The last `"playheads"` record had voices, so an empty one still has to go out.
    playheads_sent_voices: bool,
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
        let values = ParamValues::new(&TABLE);
        let p = Params::from_values(&values);
        let mut device = Self {
            single: Zone::empty(0),
            multisample: false,
            zones: Vec::new(),
            groups: Vec::new(),
            any_solo: false,
            match_scratch: Vec::new(),
            rng: 0x9e37_79b9,
            focused_zone: 0,
            trigger_counter: 0,
            voices: [Voice::idle(sample_rate); MAX_VOICES],
            voice_count: p.voices,
            queued_midi: Vec::with_capacity(MIDI_EVENT_CAP),
            midi_scratch: Vec::with_capacity(MIDI_EVENT_CAP),
            sample_rate,
            values,
            p,
            cutoff: SmoothedParam::new(p.cutoff_hz, sample_rate, FILTER_RAMP_MS),
            resonance: SmoothedParam::new(p.resonance, sample_rate, FILTER_RAMP_MS),
            pitch_dirty: false,
            enabled: true,
            sleep_state: DeviceSleepState::new(),
            channel_id,
            device_path,
            status_tx,
            time_counter: 0,
            playheads_subscribed: false,
            frames_since_poll: 0,
            playheads_sent_voices: false,
        };
        device.refresh_single_zone();
        device
    }

    /// Metadata-only instance used when advertising built-ins.
    pub fn new_for_metadata() -> Self {
        Self::new(48_000.0, 0, DevicePath::root(0), None)
    }

    /// Mark this device as loading `req_id` so stale AFS completions can be ignored.
    pub fn begin_sample_load(&mut self, req_id: String) {
        info!(
            "Sampler begin load channel={} path={} req={}",
            self.channel_id, self.device_path, req_id
        );
        self.single.req_id = req_id;
        self.emit_loading("loading");
    }

    /// Replace the single-mode buffer. Voices are killed because they pointed at the old PCM.
    pub fn set_sample(
        &mut self,
        req_id: &str,
        samples: Vec<f32>,
        channels: usize,
        sample_rate: u32,
    ) {
        if !self.single.req_id.is_empty() && self.single.req_id != req_id {
            warn!(
                "Ignoring stale sampler load (expected {}, got {})",
                self.single.req_id, req_id
            );
            return;
        }
        let sample = SampleBuffer::new(samples, channels, sample_rate);
        info!(
            "Sampler ready: {} frames, {} ch, {} Hz ({} samples)",
            sample.frames,
            sample.channels,
            sample_rate,
            sample.samples.len()
        );
        self.reset_voices();
        self.single.sample = Some(sample);
        self.single.resolve_regions();
        self.sleep_state.mark_activity();
        self.emit_loading("ready");
    }

    /// Record a failed load without dropping a previously ready sample.
    pub fn fail_sample_load(&mut self, req_id: &str, message: &str) {
        if !self.single.req_id.is_empty() && self.single.req_id != req_id {
            return;
        }
        warn!("Sampler load failed: {}", message);
        self.emit_loading(&format!("failed:{}", message));
    }

    fn emit_loading(&mut self, state: &str) {
        self.single.loading_state = state.to_string();
        if let Some(tx) = &self.status_tx {
            let _ = tx.send(EngineStatus::DeviceLoadingStateChanged {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                state: state.to_string(),
            });
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
        if self.pitch_dirty {
            self.pitch_dirty = false;
            self.refresh_pitch();
        }
        self.frames_since_poll = self.frames_since_poll.saturating_add(sample_count);

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

    fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
        let queued = match *event {
            NoteEvent::On { key, velocity, .. } => (frame_offset, key, velocity, true),
            NoteEvent::Off { key, release, .. } => (frame_offset, key, release, false),
            NoteEvent::Expression { .. } => return,
        };
        if self.queued_midi.len() >= MIDI_EVENT_CAP {
            return;
        }
        self.queued_midi.push(queued);
        self.sleep_state.mark_activity();
    }

    fn choke(&mut self, frame_offset: usize) {
        if self.queued_midi.len() < MIDI_EVENT_CAP {
            self.queued_midi.push((frame_offset, CHOKE_KEY, 0.0, false));
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        let Some((_, real)) = self.values.set(param_id, value) else {
            return;
        };
        self.sleep_state.mark_activity();
        self.apply(param_id, real);
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        let Some((_, real)) = self.values.set_offset(param_id, offset) else {
            return;
        };
        self.sleep_state.mark_activity();
        self.apply(param_id, real);
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.values.get(param_id)
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

    fn accepts_note_input(&self) -> bool {
        true
    }

    fn loading_state(&self) -> Option<String> {
        Some(self.single.loading_state.clone())
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
        TABLE.infos()
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
        self.cutoff.set_ramp(self.sample_rate, FILTER_RAMP_MS);
        self.resonance.set_ramp(self.sample_rate, FILTER_RAMP_MS);
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

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if data_type != "playheads" {
            return Err(format!("Sampler does not support '{data_type}' data"));
        }
        if !self.playheads_subscribed {
            self.playheads_subscribed = true;
            self.frames_since_poll = 0;
            self.playheads_sent_voices = false;
        }
        self.sleep_state.mark_activity();
        Ok(())
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "playheads" {
            self.playheads_subscribed = false;
        }
    }

    /// See the module docs for the payload. A record with no voices goes out once, after the
    /// last voice ended.
    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        let interval = (self.sample_rate * PLAYHEAD_INTERVAL_SECONDS) as usize;
        if !self.playheads_subscribed || self.frames_since_poll < interval {
            return None;
        }
        self.frames_since_poll = 0;
        let bytes = self.playheads_payload();
        let has_voices = bytes[0] != 0;
        if !has_voices && !self.playheads_sent_voices {
            return None;
        }
        self.playheads_sent_voices = has_voices;
        Some(("playheads".to_string(), bytes))
    }
}
