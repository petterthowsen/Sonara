//! Generic host for one drum voice (spec 013, Phase 0).
//!
//! - A preallocated event queue (capacity 64) splits the block at each `frame_offset`, so
//!   triggers are sample-accurate; `frame_offset` is used directly and never turned back into
//!   ticks.
//! - Two voice slots: a trigger starts the idle slot and moves the sounding one to a 3 ms
//!   linear fade, so a retrigger never clicks and CPU is capped at two voices.
//! - Mono synthesis is copied to both outputs and passed through `soft_clip` as a safety stage.
//! - The device sleeps once its voices are idle and the output has stayed below −90 dBFS for
//!   100 ms (decision 7). MIDI or a parameter change wakes it.

use super::params::GlobalParams;
use super::{DrumParams, DrumVoice};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use crate::audio::dsp::gain::db_to_gain;
use crate::audio::dsp::saturate::soft_clip;
use crate::audio::dsp::{Rng, SmoothedParam};

/// Trigger events queued for a single block.
const EVENT_CAPACITY: usize = 64;
/// Choke requests queued for a single block (Drum Machine choke groups).
const CHOKE_CAPACITY: usize = 16;
/// Crossfade of the previous voice after a retrigger.
const FADE_SECONDS: f32 = 0.003;
/// Output below this (about −90 dBFS) counts as silent for sleep.
const SLEEP_THRESHOLD: f32 = 3.16e-5;
/// The output must stay below [`SLEEP_THRESHOLD`] this long before the host sleeps.
const SLEEP_SECONDS: f32 = 0.1;

/// A drum voice plus the host machinery: MIDI scheduling, retrigger crossfade, shared global
/// parameters, mono → stereo and sleep.
pub struct DrumHost<V: DrumVoice + 'static> {
    voices: [V; 2],
    /// Slot the last trigger started.
    active: usize,
    /// Slot fading out after a retrigger, and the fade gain it is at.
    fading: Option<usize>,
    fade_gain: f32,
    fade_step: f32,
    /// Velocity curve gain per slot, fixed when the slot was triggered.
    velocity_gain: [f32; 2],

    sample_rate: f32,
    globals: GlobalParams,
    params: DrumParams,
    output_gain: SmoothedParam,

    /// Queued MIDI: `(frame_offset, note, velocity, is_on)`.
    events: [(usize, u8, u8, bool); EVENT_CAPACITY],
    event_count: usize,

    /// Choke requests queued for this block (frame offsets within the coming block).
    chokes: [usize; CHOKE_CAPACITY],
    choke_count: usize,
    /// While set, the final mix is faded to silence by [`Self::choke_fade_gain`].
    choke_fading: bool,
    choke_fade_gain: f32,
    choke_step: f32,

    rng: Rng,
    /// Mono scratch: the block mix, and one voice's output before it is added in.
    mix: Vec<f32>,
    slot: Vec<f32>,

    enabled: bool,
    active_flag: bool,
    quiet_samples: u64,
    sleeping: bool,
    /// Whether the sleeping state has been reported to the host since it last changed.
    sleep_reported: bool,
}

impl<V: DrumVoice + 'static> DrumHost<V> {
    /// Build a drum host with room for blocks of up to `max_frames` stereo frames.
    pub fn new(sample_rate: f32, max_frames: usize) -> Self {
        let globals = GlobalParams::new();
        let params = globals.params();
        let frames = max_frames.max(1);
        let mut host = Self {
            voices: [V::new(sample_rate), V::new(sample_rate)],
            active: 0,
            fading: None,
            fade_gain: 0.0,
            fade_step: 1.0,
            velocity_gain: [1.0, 1.0],
            sample_rate,
            globals,
            params,
            output_gain: SmoothedParam::new(
                db_to_gain(params.output_db),
                sample_rate,
                SmoothedParam::DEFAULT_RAMP_MS,
            ),
            events: [(0, 0, 0, false); EVENT_CAPACITY],
            event_count: 0,
            chokes: [0; CHOKE_CAPACITY],
            choke_count: 0,
            choke_fading: false,
            choke_fade_gain: 1.0,
            choke_step: 1.0,
            rng: Rng::new(0x5eed_0130),
            mix: vec![0.0; frames],
            slot: vec![0.0; frames],
            enabled: true,
            active_flag: true,
            quiet_samples: 0,
            sleeping: false,
            sleep_reported: false,
        };
        host.set_sample_rate(sample_rate);
        host
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(1.0);
        self.fade_step = 1.0 / (FADE_SECONDS * self.sample_rate).max(1.0);
        self.choke_step = self.fade_step;
        for voice in self.voices.iter_mut() {
            voice.set_sample_rate(self.sample_rate);
        }
        self.output_gain
            .set_ramp(self.sample_rate, SmoothedParam::DEFAULT_RAMP_MS);
        self.output_gain.snap(db_to_gain(self.params.output_db));
    }

    fn any_voice_active(&self) -> bool {
        self.voices.iter().any(|v| v.is_active()) || self.fading.is_some()
    }

    /// Start a hit in the idle slot; the sounding slot fades out.
    fn trigger(&mut self, note: u8, velocity: u8) {
        let v = velocity as f32 / 127.0;
        // A stale fading slot is done: reuse it.
        if let Some(previous) = self.fading.take() {
            self.voices[previous].reset();
        }
        if self.voices[self.active].is_active() {
            self.fading = Some(self.active);
            self.fade_gain = 1.0;
        }
        self.active = 1 - self.active;
        self.voices[self.active].reset();
        // A new hit cancels a choke fade carried over from an earlier block (a choke queued for
        // this same block still applies, and re-enables the fade below).
        self.choke_fading = false;
        self.choke_fade_gain = 1.0;
        // `gain = 1 − sens · (1 − v²)`: sens 0 leaves the peak alone, sens 1 makes it follow `v²`.
        self.velocity_gain[self.active] = 1.0 - self.params.velocity_sens * (1.0 - v * v);
        self.voices[self.active].trigger(note, v, &mut self.rng);
        self.wake();
    }

    fn release(&mut self) {
        self.voices[self.active].release();
        if let Some(fading) = self.fading {
            self.voices[fading].release();
        }
    }

    fn wake(&mut self) {
        self.quiet_samples = 0;
        self.sleeping = false;
    }

    /// Queue a choke (Drum Machine choke group): the mix fades to silence over ~3 ms starting
    /// `frame_offset` samples into the coming block. Real-time safe (fixed-capacity queue).
    fn queue_choke(&mut self, frame_offset: usize) {
        if self.sleeping || self.choke_count >= CHOKE_CAPACITY {
            return;
        }
        self.chokes[self.choke_count] = frame_offset;
        self.choke_count += 1;
    }

    /// Render `[start, end)` of the block into [`Self::mix`].
    fn render_span(&mut self, start: usize, end: usize) {
        if end <= start {
            return;
        }
        let n = end - start;

        // An idle voice can still emit a residual (a filter or DC-blocker ring on its tail);
        // skip it so a finished drum reports exact silence instead of a −120 dB whisper.
        let active = self.active;
        let active_gain = self.velocity_gain[active];
        if self.voices[active].is_active() {
            self.slot[..n].fill(0.0);
            self.voices[active].render(&mut self.slot[..n]);
            for i in 0..n {
                self.mix[start + i] += self.slot[i] * active_gain;
            }
        }

        if let Some(fading) = self.fading {
            if !self.voices[fading].is_active() {
                self.voices[fading].reset();
                self.fading = None;
            }
        }
        if let Some(fading) = self.fading {
            let fading_gain = self.velocity_gain[fading];
            self.slot[..n].fill(0.0);
            self.voices[fading].render(&mut self.slot[..n]);
            let mut fade = self.fade_gain;
            for i in 0..n {
                self.mix[start + i] += self.slot[i] * fading_gain * fade;
                fade = (fade - self.fade_step).max(0.0);
            }
            self.fade_gain = fade;
            if fade <= 0.0 {
                self.voices[fading].reset();
                self.fading = None;
            }
        }
    }
}

impl<V: DrumVoice + 'static> AudioDevice for DrumHost<V> {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let stereo = sample_count * 2;
        outputs[..stereo].fill(0.0);
        if !self.enabled || !self.active_flag || self.sleeping {
            return;
        }

        // Scratch is sized in `prepare`; a larger block renders only what fits.
        let frames = sample_count.min(self.mix.len());
        if frames == 0 {
            return;
        }

        self.params = self.globals.params();
        for voice in self.voices.iter_mut() {
            voice.set_params(&self.params);
        }
        self.output_gain
            .set_target(db_to_gain(self.params.output_db));

        self.mix[..frames].fill(0.0);

        // Sample-accurate spans between the queued events.
        let count = self.event_count;
        self.events[..count].sort_unstable_by_key(|event| event.0);
        let mut cursor = 0usize;
        for i in 0..count {
            let (offset, note, velocity, is_on) = self.events[i];
            let end = offset.min(frames);
            if end > cursor {
                self.render_span(cursor, end);
                cursor = end;
            }
            if is_on && velocity > 0 {
                self.trigger(note, velocity);
            } else if !is_on {
                self.release();
            }
        }
        if cursor < frames {
            self.render_span(cursor, frames);
        }
        self.event_count = 0;

        // Chokes queued for this block. The fade starts at the earliest offset (0 if a fade is
        // already running) and runs to silence over ~3 ms.
        let mut choke_start = if self.choke_fading { 0 } else { usize::MAX };
        let choke_count = self.choke_count;
        if choke_count > 0 {
            for k in 0..choke_count {
                choke_start = choke_start.min(self.chokes[k].min(frames));
            }
            self.choke_count = 0;
            if !self.choke_fading {
                self.choke_fading = true;
                self.choke_fade_gain = 1.0;
            }
        }

        // Mono → stereo, output gain, and a soft clip so a hot drum cannot go over full scale.
        // A running choke fades this final mix; once it reaches 0 the voices are reset and the
        // output stays silent so the host can sleep.
        let mut peak = 0.0f32;
        for i in 0..frames {
            let mut x = soft_clip(self.mix[i]) * self.output_gain.next();
            if self.choke_fading && i >= choke_start {
                x *= self.choke_fade_gain;
                if self.choke_fade_gain > 0.0 {
                    self.choke_fade_gain = (self.choke_fade_gain - self.choke_step).max(0.0);
                    if self.choke_fade_gain <= 0.0 {
                        self.voices[0].reset();
                        self.voices[1].reset();
                        self.fading = None;
                        self.fade_gain = 0.0;
                    }
                }
            }
            peak = peak.max(x.abs());
            outputs[i * 2] = x;
            outputs[i * 2 + 1] = x;
        }

        // Sleep once the voices are idle and the output has been quiet long enough.
        if !self.any_voice_active() && peak < SLEEP_THRESHOLD {
            self.quiet_samples += frames as u64;
        } else {
            self.quiet_samples = 0;
        }
        self.sleeping = self.quiet_samples as f32 >= SLEEP_SECONDS * self.sample_rate;
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        if self.event_count < EVENT_CAPACITY {
            self.events[self.event_count] = (frame_offset, note, velocity, is_note_on);
            self.event_count += 1;
        }
        if is_note_on && velocity > 0 {
            self.wake();
        }
    }

    fn choke(&mut self, frame_offset: usize) {
        self.queue_choke(frame_offset);
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.wake();
        if self.globals.set(param_id, value) {
            self.params = self.globals.params();
            self.output_gain
                .set_target(db_to_gain(self.params.output_db));
        } else {
            for voice in self.voices.iter_mut() {
                voice.set_parameter(param_id, value);
            }
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        match self.globals.get(param_id) {
            Some(value) => Some(value),
            None => self.voices[self.active].get_parameter(param_id),
        }
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        V::specs().iter().map(|spec| spec.info()).collect()
    }

    fn device_id(&self) -> &str {
        V::device_id()
    }

    fn device_name(&self) -> &str {
        V::device_name()
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

    fn reset(&mut self) {
        for voice in self.voices.iter_mut() {
            voice.reset();
        }
        self.fading = None;
        self.fade_gain = 0.0;
        self.event_count = 0;
        self.choke_count = 0;
        self.choke_fading = false;
        self.choke_fade_gain = 1.0;
        self.wake();
        self.sleep_reported = false;
        self.output_gain.snap(db_to_gain(self.params.output_db));
    }

    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        let frames = max_frames.max(1);
        self.mix.resize(frames, 0.0);
        self.slot.resize(frames, 0.0);
        self.set_sample_rate(sample_rate);
        for voice in self.voices.iter_mut() {
            voice.reset();
        }
        self.fading = None;
        self.event_count = 0;
        self.choke_count = 0;
        self.choke_fading = false;
        self.choke_fade_gain = 1.0;
    }

    fn is_active(&self) -> bool {
        self.active_flag
    }

    fn activate(&mut self) -> Result<(), String> {
        self.active_flag = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.active_flag = false;
        self.reset();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    fn is_sleeping(&self) -> bool {
        self.sleeping
    }

    fn mark_activity(&mut self) {
        self.wake();
    }

    /// Sleeping is decided from the host's own output level in `process_block`; this only
    /// reports the change (the chain copies silent input to the output while asleep).
    fn update_sleep_state(&mut self, _has_audio_activity: bool) -> bool {
        let changed = self.sleeping != self.sleep_reported;
        self.sleep_reported = self.sleeping;
        changed
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::{DrumHost, DrumParams, DrumVoice, FADE_SECONDS};
    use crate::audio::devices::drums::params::GLOBAL_SPECS;
    use crate::audio::devices::param_table::ParamSpec;
    use crate::audio::devices::{AudioDevice, ParamId, ParamValue};
    use crate::audio::dsp::Rng;

    /// A voice that holds a steady level while active, so any drop to silence must come from
    /// the choke fade, not the voice's own envelope.
    struct TestVoice {
        active: bool,
        level: f32,
    }

    impl DrumVoice for TestVoice {
        fn new(_sample_rate: f32) -> Self {
            Self {
                active: false,
                level: 0.0,
            }
        }

        fn set_sample_rate(&mut self, _sample_rate: f32) {}

        fn specs() -> &'static [ParamSpec] {
            &GLOBAL_SPECS
        }

        fn set_parameter(&mut self, _id: ParamId, _norm: ParamValue) {}

        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }

        fn set_params(&mut self, _params: &DrumParams) {}

        fn trigger(&mut self, _note: u8, velocity: f32, _rng: &mut Rng) {
            self.active = true;
            self.level = velocity;
        }

        fn render(&mut self, out: &mut [f32]) {
            if self.active {
                for x in out.iter_mut() {
                    *x += 0.3 * self.level;
                }
            }
        }

        fn release(&mut self) {}

        fn is_active(&self) -> bool {
            self.active
        }

        fn reset(&mut self) {
            self.active = false;
            self.level = 0.0;
        }

        fn device_id() -> &'static str {
            "test.choke_voice"
        }

        fn device_name() -> &'static str {
            "Choke Test Voice"
        }
    }

    #[test]
    fn choke_fades_to_silence_and_sleeps() {
        let sr = 48_000.0;
        let block = 256usize;
        let mut host = DrumHost::<TestVoice>::new(sr, block);
        host.prepare(sr, block);

        // A hit at frame 0, then a choke at the same offset.
        host.send_midi_event(36, 127, true, 0);
        host.choke(0);

        let total_blocks = sr as usize / block + 2; // just over one second
        let mut out = vec![0.0f32; block * 2];
        let mut left: Vec<f32> = Vec::with_capacity(total_blocks * block);
        for _ in 0..total_blocks {
            host.process_block(&[], &mut out, block);
            left.extend(out.chunks_exact(2).map(|s| s[0]));
        }

        assert!(left[0].abs() > 0.0, "the hit should sound before the fade");
        let fade_samples = (FADE_SECONDS * sr) as usize + 1;
        for (i, &s) in left.iter().enumerate() {
            if i >= fade_samples {
                assert_eq!(s, 0.0, "sample {i} not silent after the choke fade");
            }
        }
        // The fade itself reaches exactly zero within 3 ms + 1 sample.
        assert_eq!(left[fade_samples], 0.0);
        assert!(!host.any_voice_active());
        assert!(host.is_sleeping(), "host should sleep after the choke");
    }
}
