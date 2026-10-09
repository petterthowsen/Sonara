//! Voice allocation, note handling, parameter application and block rendering.

use super::params::{
    LoopMode, PlayMode, MAX_VOICES, PARAM_ATTACK, PARAM_CROSSFADE, PARAM_CUTOFF, PARAM_DECAY,
    PARAM_END, PARAM_FINE, PARAM_KEY_TRACK, PARAM_LOOP_END, PARAM_LOOP_MODE, PARAM_LOOP_START,
    PARAM_RELEASE, PARAM_RESONANCE, PARAM_REVERSE, PARAM_ROOT, PARAM_SPEED, PARAM_START,
    PARAM_SUSTAIN, PARAM_TUNE, PARAM_VOICES, VOICES_MIN,
};
use super::regions::{zone_at, Zone, SINGLE_ZONE};
use super::voice::{
    inside_loop, playback_increment, render_active_voices, sample_rate_ratio, RenderCtx, Voice,
    CHOKE_KEY, DECLICK_SECONDS,
};
use super::zones::{select_zones, velocity_to_midi};
use super::{SamplerDevice, PLAYHEAD_RECORD_BYTES};
use crate::audio::devices::ParamId;
use crate::audio::dsp::svf::Svf;
use crate::audio::modulation::envelope::{AdsrEnvelope, AdsrState};

impl SamplerDevice {
    pub(super) fn reset_voices(&mut self) {
        self.voices = [Voice::idle(self.sample_rate); MAX_VOICES];
    }

    pub(super) fn any_voice_active(&self) -> bool {
        self.voices[..self.voice_count].iter().any(|v| v.active)
    }

    /// Apply the device ADSR settings to every voice, including notes already sounding.
    pub(super) fn apply_envelope_params(&mut self) {
        for voice in &mut self.voices {
            voice
                .envelope
                .set_adsr(self.p.attack, self.p.decay, self.p.sustain, self.p.release);
        }
    }

    /// Copy the per-sample parameters into the single-mode zone and re-resolve its regions.
    pub(super) fn refresh_single_zone(&mut self) {
        let (p, zone) = (&self.p, &mut self.single);
        zone.start = p.start;
        zone.end = p.end;
        zone.loop_start = p.loop_start;
        zone.loop_end = p.loop_end;
        zone.crossfade = p.crossfade;
        zone.loop_mode = p.loop_mode;
        zone.reverse = p.reverse;
        zone.root = p.root;
        zone.tune = p.tune + p.fine / 100.0;
        zone.key_track = p.key_track;
        zone.resolve_regions();
    }

    /// Sample frames per output frame for `note` played from `zone`, 0 without PCM.
    pub(super) fn increment_for(&self, note: u8, zone: &Zone) -> f64 {
        let Some(sample) = zone.sample.as_ref() else {
            return 0.0;
        };
        playback_increment(self.p.speed, zone.tune, self.p.key_track, note, zone.root)
            * sample_rate_ratio(sample.sample_rate, self.sample_rate)
    }

    /// Recompute the pitch of sounding voices after Speed or a zone's pitch settings moved.
    pub(super) fn refresh_pitch(&mut self) {
        for i in 0..self.voice_count {
            let voice = self.voices[i];
            if !voice.active {
                continue;
            }
            let Some(zone) = zone_at(&self.single, &self.zones, voice.zone) else {
                continue;
            };
            let inc = self.increment_for(voice.note, zone);
            if inc > 0.0 {
                self.voices[i].increment = inc;
            }
        }
    }

    /// Apply a decoded parameter value and its side effects.
    pub(super) fn apply(&mut self, id: ParamId, real: f32) {
        self.p.apply(id, real);
        match id {
            PARAM_TUNE | PARAM_FINE | PARAM_SPEED | PARAM_ROOT | PARAM_KEY_TRACK => {
                self.refresh_single_zone();
                self.pitch_dirty = true
            }
            PARAM_START | PARAM_END | PARAM_LOOP_START | PARAM_LOOP_END | PARAM_CROSSFADE
            | PARAM_REVERSE | PARAM_LOOP_MODE => self.refresh_single_zone(),
            PARAM_ATTACK | PARAM_DECAY | PARAM_SUSTAIN | PARAM_RELEASE => {
                self.apply_envelope_params()
            }
            PARAM_VOICES => self.set_voice_count(self.p.voices),
            PARAM_CUTOFF => self.cutoff.set_target(self.p.cutoff_hz),
            PARAM_RESONANCE => self.resonance.set_target(self.p.resonance),
            _ => {}
        }
    }

    /// Limit polyphony and silence slots that fall outside the new count.
    pub(super) fn set_voice_count(&mut self, count: usize) {
        let count = count.clamp(VOICES_MIN, MAX_VOICES);
        if count < self.voice_count {
            for voice in &mut self.voices[count..self.voice_count] {
                *voice = Voice::idle(self.sample_rate);
            }
        }
        self.voice_count = count;
    }

    /// Free slot in the polyphony pool, or steal a releasing then oldest voice.
    pub(super) fn allocate_voice(&self) -> Option<usize> {
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

    pub(super) fn note_on(&mut self, note: u8, velocity: f32) {
        let vel_gain = (1.0 - self.p.velocity_amount) + self.p.velocity_amount * velocity;
        self.trigger_counter = self.trigger_counter.wrapping_add(1);
        if !self.multisample {
            self.start_voice(
                SINGLE_ZONE,
                note,
                self.p.volume * vel_gain,
                self.trigger_counter,
            );
            return;
        }
        let vel = velocity_to_midi(velocity);
        select_zones(
            &self.zones,
            &mut self.groups,
            self.any_solo,
            note,
            vel,
            &mut self.rng,
            &mut self.match_scratch,
        );
        for k in 0..self.match_scratch.len() {
            let index = self.match_scratch[k];
            let zone = &self.zones[index as usize];
            let fade = zone.ranges.gain(note, vel);
            if fade <= 0.0 {
                continue;
            }
            let group_gain = self.groups.get(zone.group_index).map_or(1.0, |g| g.gain);
            let gain = self.p.volume * vel_gain * zone.gain * group_gain * fade;
            self.start_voice(index, note, gain, self.trigger_counter);
        }
    }

    /// Start a voice playing `zone_index` ([`SINGLE_ZONE`] or a zone index), unless the zone has
    /// no PCM.
    pub(super) fn start_voice(&mut self, zone_index: u16, note: u8, gain: f32, trigger: u64) {
        let Some(idx) = self.allocate_voice() else {
            return;
        };
        let Some(zone) = zone_at(&self.single, &self.zones, zone_index) else {
            return;
        };
        if zone.sample.is_none() {
            return;
        }
        let increment = self.increment_for(note, zone);
        let r = zone.regions;
        let direction = if zone.reverse { -1.0 } else { 1.0 };
        let position = if zone.reverse {
            (r.play.1 - 1.0).max(r.play.0)
        } else {
            r.play.0
        };
        if increment <= 0.0 {
            return;
        }
        let mut envelope = AdsrEnvelope::new(self.sample_rate);
        envelope.set_adsr(self.p.attack, self.p.decay, self.p.sustain, self.p.release);
        envelope.gate_on();
        self.time_counter = self.time_counter.wrapping_add(1);
        self.voices[idx] = Voice {
            active: true,
            note,
            zone: zone_index,
            trigger,
            position,
            increment,
            direction,
            in_loop: inside_loop(position, direction, r.loop_),
            ending: false,
            fade: 1.0,
            gain,
            envelope,
            filters: [Svf::new(); 2],
            age: self.time_counter,
        };
        self.sleep_state.mark_activity();
    }

    /// Fade every sounding voice out over the declick time (Drum Machine choke).
    pub(super) fn choke_voices(&mut self) {
        for voice in self.voices[..self.voice_count]
            .iter_mut()
            .filter(|v| v.active)
        {
            voice.ending = true;
        }
    }

    /// Release the held voices of `note`'s oldest note-on that note-off applies to: Gated, or
    /// a zone with a loop.
    pub(super) fn note_off(&mut self, note: u8) {
        let gated = self.p.play_mode == PlayMode::Gated;
        let (single, zones) = (&self.single, &self.zones);
        let releases = |v: &Voice| {
            v.is_held()
                && v.note == note
                && (gated
                    || zone_at(single, zones, v.zone).is_some_and(|z| z.loop_mode != LoopMode::Off))
        };
        let pool = &self.voices[..self.voice_count];
        let Some(trigger) = pool.iter().filter(|v| releases(v)).map(|v| v.trigger).min() else {
            return;
        };
        for i in 0..self.voice_count {
            if self.voices[i].trigger == trigger && releases(&self.voices[i]) {
                self.voices[i].envelope.gate_off();
            }
        }
    }

    pub(super) fn render_voices(&mut self, outputs: &mut [f32], start: usize, len: usize) {
        if !self.multisample && self.single.sample.is_none() {
            return;
        }
        let ctx = RenderCtx {
            single: &self.single,
            zones: &self.zones,
            filter: self.p.filter,
            filter_key_track: self.p.filter_key_track,
            sample_rate: self.sample_rate,
            fade_step: 1.0 / (DECLICK_SECONDS * self.sample_rate).max(1.0),
        };
        let limit = self.voice_count;
        render_active_voices(
            &ctx,
            &mut self.voices[..limit],
            &mut self.cutoff,
            &mut self.resonance,
            outputs,
            start,
            len,
        );
    }

    /// Apply a queued event. The sampler has no use for release velocity yet.
    pub(super) fn apply_midi(&mut self, note: u8, value: f32, is_on: bool) {
        if note == CHOKE_KEY {
            self.choke_voices();
        } else if is_on {
            self.note_on(note, value);
        } else {
            self.note_off(note);
        }
    }

    /// One `"playheads"` record per sounding voice of the shown zone (see the module docs).
    pub(super) fn playheads_payload(&self) -> Vec<u8> {
        let (shown, frames) = if self.multisample {
            match self.zone_index(self.focused_zone) {
                Some(index) => (index as u16, self.zones[index].frames()),
                // No voice plays SINGLE_ZONE in multisample mode.
                None => (SINGLE_ZONE, 0),
            }
        } else {
            (SINGLE_ZONE, self.single.frames())
        };
        let frames = frames.max(1) as f64;
        let rate_ratio = self.sample_rate as f64;
        let voices = || {
            self.voices[..self.voice_count]
                .iter()
                .filter(move |v| v.active && v.zone == shown)
        };
        let count = voices().count();
        let mut bytes = Vec::with_capacity(4 + count * PLAYHEAD_RECORD_BYTES);
        bytes.extend_from_slice(&(count as u32).to_le_bytes());
        for v in voices() {
            let position = (v.position / frames).clamp(0.0, 1.0) as f32;
            let moving = if v.ending { 0.0 } else { v.direction };
            let velocity = (moving * v.increment * rate_ratio / frames) as f32;
            let level = (v.envelope.value() * v.gain * v.fade).clamp(0.0, 1.0);
            for value in [position, velocity, level] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
        bytes
    }
}
