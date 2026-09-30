//! PolySynth: two band-limited oscillators with unison, noise, a drive + state-variable filter,
//! amp and filter envelopes, two LFOs, Poly/Mono/Legato voice modes, glide, and per-voice
//! modulation routes.
//!
//! - One shared [`SynthParams`] block; voices read it every control block, so knob moves reach
//!   held notes.
//! - A preallocated pool of 64 note slots. A note costs `max(Osc 1 unison, Osc 2 unison)` voices
//!   out of a budget of 64, and notes are further limited by Polyphony.
//! - Stealing takes a releasing voice (quietest first), else the oldest held note. The stolen
//!   voice fades for a few ms and then starts the queued note.
//! - Modulation routes (`modulation.rs`) are device state. Each voice evaluates them once per
//!   control block; the default patch routes Filter Env → Cutoff.

mod modulation;
mod params;
mod voice;

use super::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ModRoute, ModSourceInfo, ParamId,
    ParamInfo, ParamValue, PortFlow,
};
use crate::audio::dsp::SmoothedParam;
use modulation::ModSource;
use params::{Changed, SynthParams, VoiceMode, CUTOFF, MAX_POLYPHONY, SPECS};
use voice::{Mods, PendingNote, RenderCtx, StartCtx, Voice};

/// Voices (unison sub-voices) all sounding notes may use together.
const VOICE_BUDGET: usize = 64;
/// Scratch size used until `prepare` supplies the real block size.
const DEFAULT_MAX_FRAMES: usize = 4096;
/// Tempo synced LFOs use until the first transport arrives.
const DEFAULT_TEMPO: f64 = 120.0;
/// The default patch's Filter Env → Cutoff amount.
const DEFAULT_FILTER_ENV_AMOUNT: f32 = 0.35;

/// Held keys in press order, for Mono/Legato: releasing the top key returns to the one below.
struct NoteStack {
    notes: [u8; 128],
    len: usize,
}

impl NoteStack {
    fn new() -> Self {
        Self {
            notes: [0; 128],
            len: 0,
        }
    }

    fn remove(&mut self, note: u8) {
        if let Some(i) = self.notes[..self.len].iter().position(|&n| n == note) {
            self.notes.copy_within(i + 1..self.len, i);
            self.len -= 1;
        }
    }

    fn push(&mut self, note: u8) {
        self.remove(note);
        if self.len < self.notes.len() {
            self.notes[self.len] = note;
            self.len += 1;
        }
    }

    fn top(&self) -> Option<u8> {
        self.len.checked_sub(1).map(|i| self.notes[i])
    }

    fn clear(&mut self) {
        self.len = 0;
    }
}

pub struct PolySynthDevice {
    sample_rate: f32,
    params: SynthParams,
    voices: Vec<Voice>,
    /// Incremented per note-on; orders notes for stealing.
    note_counter: u64,
    /// Pitch of the last note played, where a new Poly voice glides from.
    last_note: Option<f32>,
    held: NoteStack,
    /// Envelope settings changed (or envelope routes went away): push them to every voice.
    env_dirty: bool,
    mods: Mods,
    /// Free-running LFO phases that voices with Retrigger Free start from.
    lfo_phase: [f64; 2],
    tempo: f64,
    playing: bool,
    song_pos_beats: f64,

    level_smoothed: [SmoothedParam; 2],
    noise_smoothed: SmoothedParam,
    /// Normalized, so it glides in octaves.
    cutoff_smoothed: SmoothedParam,
    volume_smoothed: SmoothedParam,

    is_active: bool,
    is_enabled: bool,
    sleep_state: super::DeviceSleepState,

    /// Queued MIDI for frame-accurate scheduling within the next block.
    queued_midi: Vec<(usize, u8, u8, bool)>,

    // Scratch, sized in `prepare`.
    mix_l: Vec<f32>,
    mix_r: Vec<f32>,
    level_buf: [Vec<f32>; 2],
    noise_buf: Vec<f32>,
    cutoff_buf: Vec<f32>,
}

fn smoothed(value: f32, sample_rate: f32) -> SmoothedParam {
    SmoothedParam::new(value, sample_rate, SmoothedParam::DEFAULT_RAMP_MS)
}

impl PolySynthDevice {
    pub fn new(sample_rate: f32) -> Self {
        let params = SynthParams::new();
        let mut dev = Self {
            sample_rate,
            voices: Vec::new(),
            note_counter: 0,
            last_note: None,
            held: NoteStack::new(),
            env_dirty: true,
            mods: Mods::new(),
            lfo_phase: [0.0; 2],
            tempo: DEFAULT_TEMPO,
            playing: false,
            song_pos_beats: 0.0,
            level_smoothed: [
                smoothed(params.osc[0].level, sample_rate),
                smoothed(params.osc[1].level, sample_rate),
            ],
            noise_smoothed: smoothed(params.noise_level, sample_rate),
            cutoff_smoothed: smoothed(params.get(CUTOFF).unwrap_or(1.0), sample_rate),
            volume_smoothed: smoothed(params.volume_gain, sample_rate),
            params,
            is_active: true,
            is_enabled: true,
            sleep_state: super::DeviceSleepState::new(),
            queued_midi: Vec::with_capacity(128),
            mix_l: Vec::new(),
            mix_r: Vec::new(),
            level_buf: [Vec::new(), Vec::new()],
            noise_buf: Vec::new(),
            cutoff_buf: Vec::new(),
        };
        dev.allocate(sample_rate, DEFAULT_MAX_FRAMES);
        dev.set_mod_route(ModSource::FilterEnv.id(), CUTOFF, DEFAULT_FILTER_ENV_AMOUNT)
            .expect("default route");
        dev
    }

    /// Build the voice pool and scratch. Off the audio thread only.
    fn allocate(&mut self, sample_rate: f32, frames: usize) {
        self.voices = (0..MAX_POLYPHONY)
            .map(|i| Voice::new(sample_rate, i as u32 + 1))
            .collect();
        let [level0, level1] = &mut self.level_buf;
        for buf in [
            &mut self.mix_l,
            &mut self.mix_r,
            level0,
            level1,
            &mut self.noise_buf,
            &mut self.cutoff_buf,
        ] {
            buf.clear();
            buf.resize(frames, 0.0);
        }
        self.env_dirty = true;
    }

    /// (voices used, notes) counted against the budget. A dying voice (fading with nothing
    /// queued) is gone within a few ms and no longer counts; a stolen one counts its queued note.
    fn usage(&self) -> (usize, usize) {
        self.voices
            .iter()
            .filter(|v| (v.active && !v.is_dying()) || v.pending.is_some())
            .fold((0, 0), |(cost, notes), v| (cost + v.cost(), notes + 1))
    }

    /// The voice to steal: a releasing one (quietest first), else the oldest held note.
    /// Voices already fading are never picked twice.
    fn pick_victim(&self) -> Option<usize> {
        let candidates = || {
            self.voices
                .iter()
                .enumerate()
                .filter(|(_, v)| v.active && !v.is_fading())
        };
        candidates()
            .filter(|(_, v)| !v.gate)
            .min_by(|(_, a), (_, b)| a.amp_env.value().total_cmp(&b.amp_env.value()))
            .or_else(|| candidates().min_by_key(|(_, v)| v.age))
            .map(|(i, _)| i)
    }

    fn next_age(&mut self) -> u64 {
        self.note_counter += 1;
        self.note_counter
    }

    fn unison_counts(&self) -> [usize; 2] {
        [self.params.osc[0].unison, self.params.osc[1].unison]
    }

    /// What a note starting now needs from the device.
    fn start_ctx(&self) -> StartCtx {
        let phase = |i: usize| {
            if self.params.lfo[i].retrigger {
                0.0
            } else {
                self.lfo_phase[i]
            }
        };
        StartCtx {
            glide: self.params.glide,
            lfo_phase: [phase(0), phase(1)],
        }
    }

    fn glide_from(&self) -> Option<f32> {
        if self.params.glide > 0.0 {
            self.last_note
        } else {
            None
        }
    }

    fn note_on(&mut self, note: u8, velocity: u8) {
        let velocity = velocity as f32 / 127.0;
        match self.params.mode {
            VoiceMode::Poly => self.note_on_poly(note, velocity),
            VoiceMode::Mono | VoiceMode::Legato => self.note_on_mono(note, velocity),
        }
        self.last_note = Some(note as f32);
    }

    fn note_on_poly(&mut self, note: u8, velocity: f32) {
        let age = self.next_age();
        let start = self.start_ctx();

        // The same key again: retrigger its voice in place (from its current level).
        if let Some(v) = self
            .voices
            .iter_mut()
            .find(|v| v.active && !v.is_fading() && v.note == note)
        {
            v.retrigger(note, velocity, age, 0.0, true);
            return;
        }

        let unison = self.unison_counts();
        let pending = PendingNote {
            note,
            velocity,
            age,
            glide_from: self.glide_from(),
            unison,
            released: false,
        };
        let cost = unison[0].max(unison[1]);
        let polyphony = self.params.polyphony;

        // Steal until the new note fits both the voice budget and Polyphony. The first victim
        // hosts the new note after its fade; further victims just fade out.
        let mut host = None;
        loop {
            let (used, notes) = self.usage();
            let (add_cost, add_note) = if host.is_some() { (0, 0) } else { (cost, 1) };
            if used + add_cost <= VOICE_BUDGET && notes + add_note <= polyphony {
                break;
            }
            let Some(victim) = self.pick_victim() else {
                break;
            };
            if host.is_none() {
                self.voices[victim].steal(pending);
                host = Some(victim);
            } else {
                self.voices[victim].kill();
            }
        }
        if host.is_some() {
            return;
        }

        // Room in the budget: take an idle slot, or a dying one (queue behind its fade).
        if let Some(v) = self
            .voices
            .iter_mut()
            .find(|v| !v.active && v.pending.is_none())
        {
            v.start(pending, &start);
        } else if let Some(v) = self.voices.iter_mut().find(|v| v.is_dying()) {
            v.steal(pending);
        }
    }

    fn note_on_mono(&mut self, note: u8, velocity: f32) {
        let was_held = self.held.top().is_some();
        self.held.push(note);
        let age = self.next_age();
        let glide = self.params.glide;
        let legato = self.params.mode == VoiceMode::Legato;
        let start = self.start_ctx();
        let voice = &mut self.voices[0];
        if voice.active && !voice.is_fading() {
            // Legato only slides while another key is held; Mono always retriggers.
            voice.retrigger(note, velocity, age, glide, !(legato && was_held));
        } else {
            let pending = PendingNote {
                note,
                velocity,
                age,
                glide_from: if glide > 0.0 { self.last_note } else { None },
                unison: [self.params.osc[0].unison, self.params.osc[1].unison],
                released: false,
            };
            if voice.active {
                voice.steal(pending);
            } else {
                voice.start(pending, &start);
            }
        }
    }

    fn note_off(&mut self, note: u8) {
        match self.params.mode {
            VoiceMode::Poly => {
                for v in self.voices.iter_mut() {
                    if let Some(p) = v.pending.as_mut().filter(|p| p.note == note) {
                        p.released = true;
                    } else if v.gate && !v.is_fading() && v.note == note {
                        v.release();
                    }
                }
            }
            VoiceMode::Mono | VoiceMode::Legato => {
                self.held.remove(note);
                let retrigger_env = self.params.mode == VoiceMode::Mono;
                let glide = self.params.glide;
                let age = self.next_age();
                let voice = &mut self.voices[0];
                if let Some(p) = voice.pending.as_mut().filter(|p| p.note == note) {
                    match self.held.top() {
                        Some(top) => p.note = top,
                        None => p.released = true,
                    }
                    return;
                }
                if !voice.gate || voice.note != note {
                    return; // not the sounding key
                }
                match self.held.top() {
                    Some(top) => {
                        let velocity = voice.velocity;
                        voice.retrigger(top, velocity, age, glide, retrigger_env);
                    }
                    None => voice.release(),
                }
            }
        }
    }

    fn apply_envelopes(&mut self) {
        let (a, f) = (self.params.amp_env, self.params.filter_env);
        for v in self.voices.iter_mut() {
            v.amp_env.set_adsr(a.attack, a.decay, a.sustain, a.release);
            v.filter_env
                .set_adsr(f.attack, f.decay, f.sustain, f.release);
        }
        self.env_dirty = false;
    }

    /// Render every sounding voice over `[start, end)` of the block into the mix buffers.
    fn render_span(&mut self, start: usize, end: usize) {
        let ctx = RenderCtx {
            params: &self.params,
            mods: &self.mods,
            levels: [&self.level_buf[0], &self.level_buf[1]],
            noise_level: &self.noise_buf,
            cutoff: &self.cutoff_buf,
            start: self.start_ctx(),
            tempo: self.tempo,
        };
        for voice in self.voices.iter_mut() {
            if voice.active || voice.pending.is_some() {
                voice.render(&ctx, start, end, &mut self.mix_l, &mut self.mix_r);
            }
        }
    }

    /// Advance the free-running LFO phases past a block of `frames`. Synced LFOs follow the song
    /// position while the transport plays.
    fn advance_lfo_phases(&mut self, frames: usize) {
        for i in 0..2 {
            let lfo = &self.params.lfo[i];
            let phase = &mut self.lfo_phase[i];
            match lfo.sync_beats {
                Some(beats) if self.playing => {
                    *phase = (self.song_pos_beats / beats).rem_euclid(1.0);
                }
                _ => {
                    *phase = (*phase
                        + lfo.hz(self.tempo) * frames as f64 / self.sample_rate as f64)
                        .fract();
                }
            }
        }
    }
}

fn retarget(smoother: &mut SmoothedParam, value: f32) {
    // Only on change: retargeting every block would restart the ramp and never arrive.
    if smoother.target() != value {
        smoother.set_target(value);
    }
}

impl AudioDevice for PolySynthDevice {
    fn process_block(&mut self, _inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        outputs[..sample_count * 2].fill(0.0);
        if !self.is_active || !self.is_enabled {
            return;
        }

        // Scratch is sized in `prepare`; never grow it here. A block larger than that renders
        // only what fits and leaves the rest silent.
        let sample_count = sample_count.min(self.mix_l.len());

        if self.env_dirty {
            self.apply_envelopes();
        }

        // Smoothed levels for the whole block, shared by every voice.
        for o in 0..2 {
            retarget(&mut self.level_smoothed[o], self.params.osc[o].level);
            self.level_smoothed[o].fill(&mut self.level_buf[o][..sample_count]);
        }
        retarget(&mut self.noise_smoothed, self.params.noise_level);
        self.noise_smoothed
            .fill(&mut self.noise_buf[..sample_count]);
        retarget(
            &mut self.cutoff_smoothed,
            self.params.get(CUTOFF).unwrap_or(1.0),
        );
        self.cutoff_smoothed
            .fill(&mut self.cutoff_buf[..sample_count]);
        retarget(&mut self.volume_smoothed, self.params.volume_gain);

        // Sort queued MIDI by offset. Taken so voices can be borrowed while iterating; put back
        // (cleared) at the end so the queue keeps its preallocated capacity.
        let mut events = core::mem::take(&mut self.queued_midi);
        events.sort_by_key(|e| e.0);

        self.mix_l[..sample_count].fill(0.0);
        self.mix_r[..sample_count].fill(0.0);

        // Render in spans between event offsets so note on/off are applied with sample accuracy
        let mut cursor = 0usize;
        for &(offset, note, velocity, is_on) in events.iter() {
            let span_end = offset.min(sample_count);
            if span_end > cursor {
                self.render_span(cursor, span_end);
                cursor = span_end;
            }
            if is_on && velocity > 0 {
                self.note_on(note, velocity);
            } else {
                self.note_off(note);
            }
        }
        if cursor < sample_count {
            self.render_span(cursor, sample_count);
        }

        for i in 0..sample_count {
            let gain = self.volume_smoothed.next();
            outputs[i * 2] = self.mix_l[i] * gain;
            outputs[i * 2 + 1] = self.mix_r[i] * gain;
        }

        self.advance_lfo_phases(sample_count);

        // Return the (cleared) queue so the next `send_midi_event` doesn't allocate
        events.clear();
        self.queued_midi = events;
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        self.queued_midi
            .push((frame_offset, note, velocity, is_note_on));
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.sleep_state.mark_activity(); // Wake on parameter change
        match self.params.set(param_id, value) {
            Changed::Envelope => self.env_dirty = true,
            Changed::Mode => {
                // Switching modes mid-note would strand voices: fade everything out.
                for v in self.voices.iter_mut() {
                    v.kill();
                }
                self.held.clear();
            }
            Changed::Other | Changed::None => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.params.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.polysynth"
    }

    fn device_name(&self) -> &str {
        "PolySynth"
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

    fn parameters(&self) -> Vec<ParamInfo> {
        params::param_infos()
    }

    fn mod_sources(&self) -> Vec<ModSourceInfo> {
        ModSource::ALL
            .iter()
            .map(|s| ModSourceInfo {
                id: s.id().to_string(),
                name: s.name().to_string(),
                bipolar: s.bipolar(),
            })
            .collect()
    }

    fn set_mod_route(
        &mut self,
        source: &str,
        param_id: ParamId,
        amount: f32,
    ) -> Result<(), String> {
        let src = ModSource::from_id(source)
            .ok_or_else(|| format!("PolySynth has no modulation source '{source}'"))?;
        let slot = params::slot(param_id)
            .ok_or_else(|| format!("PolySynth has no parameter {param_id}"))?;
        if !SPECS[slot].is_modulatable() {
            return Err(format!(
                "PolySynth parameter {param_id} ({}) is not modulatable",
                SPECS[slot].name
            ));
        }
        self.mods
            .set(src.index(), param_id, slot, amount)
            .map_err(str::to_string)?;
        // A voice may have been running modulated envelopes: restore the base settings (they are
        // re-modulated on the next block if routes remain).
        self.env_dirty = true;
        Ok(())
    }

    fn clear_mod_routes(&mut self) {
        self.mods.clear();
        self.env_dirty = true;
    }

    fn mod_routes(&self) -> Vec<ModRoute> {
        self.mods
            .routes()
            .iter()
            .map(|r| ModRoute {
                source: ModSource::ALL[r.source].id().to_string(),
                param_id: r.param_id,
                amount: r.amount,
            })
            .collect()
    }

    fn set_transport(&mut self, transport: &crate::audio::transport::Transport) {
        if transport.tempo > 0.0 {
            self.tempo = transport.tempo;
        }
        self.playing = transport.playing;
        self.song_pos_beats = transport.song_pos_beats;
    }

    fn reset(&mut self) {
        for voice in self.voices.iter_mut() {
            voice.reset();
        }
        self.held.clear();
        self.note_counter = 0;
        self.last_note = None;
    }

    /// Rebuild the voices and scratch at the new rate (sounding notes stop).
    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        self.sample_rate = sample_rate;
        self.allocate(sample_rate, max_frames.max(DEFAULT_MAX_FRAMES));
        let p = &self.params;
        self.level_smoothed = [
            smoothed(p.osc[0].level, sample_rate),
            smoothed(p.osc[1].level, sample_rate),
        ];
        self.noise_smoothed = smoothed(p.noise_level, sample_rate);
        self.cutoff_smoothed = smoothed(p.get(CUTOFF).unwrap_or(1.0), sample_rate);
        self.volume_smoothed = smoothed(p.volume_gain, sample_rate);
        self.held.clear();
        self.note_counter = 0;
        self.last_note = None;
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        self.is_active = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.is_active = false;
        self.reset();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    // === Sleep/Wake System ===

    fn is_sleeping(&self) -> bool {
        self.sleep_state.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.sleep_state.mark_activity();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        self.sleep_state.check_activity(has_audio_activity)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::params::*;
    use super::*;
    use crate::audio::devices::{enum_to_norm, real_to_norm, ParamType};

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 256;

    fn synth() -> PolySynthDevice {
        let mut dev = PolySynthDevice::new(SR);
        dev.prepare(SR, BLOCK);
        dev
    }

    fn set_real(dev: &mut PolySynthDevice, id: ParamId, real: f32) {
        let info = dev.parameters().into_iter().find(|p| p.id == id).unwrap();
        let norm = match info.param_type {
            ParamType::Enum => enum_to_norm(real as usize, info.enum_values.len()),
            _ => real_to_norm(real, info.min, info.max, info.is_logarithmic, info.skew),
        };
        dev.set_parameter(id, norm);
    }

    /// Render `blocks` blocks; returns interleaved output.
    fn render(dev: &mut PolySynthDevice, blocks: usize) -> Vec<f32> {
        let mut all = Vec::with_capacity(blocks * BLOCK * 2);
        let mut out = vec![0.0; BLOCK * 2];
        for _ in 0..blocks {
            dev.process_block(&[], &mut out, BLOCK);
            all.extend_from_slice(&out);
        }
        all
    }

    fn peak(samples: &[f32]) -> f32 {
        samples.iter().fold(0.0f32, |m, s| m.max(s.abs()))
    }

    fn sounding_notes(dev: &PolySynthDevice) -> Vec<u8> {
        let mut notes: Vec<u8> = dev
            .voices
            .iter()
            .filter(|v| v.active && !v.is_fading())
            .map(|v| v.note)
            .collect();
        notes.sort();
        notes
    }

    #[test]
    fn get_set_round_trips_every_parameter() {
        let mut dev = PolySynthDevice::new(SR);
        for info in dev.parameters() {
            // Enums only have discrete values; floats are checked at a few points.
            let probes: Vec<f32> = if info.param_type == ParamType::Enum {
                (0..info.enum_values.len())
                    .map(|i| enum_to_norm(i, info.enum_values.len()))
                    .collect()
            } else {
                vec![0.0, 0.25, 0.5, 1.0]
            };
            for v in probes {
                dev.set_parameter(info.id, v);
                let got = dev.get_parameter(info.id).unwrap();
                assert!(
                    (got - v).abs() < 1e-4,
                    "param {} ({}): set {} but got {}",
                    info.id,
                    info.name,
                    v,
                    got
                );
            }
        }
    }

    #[test]
    fn param_info_defaults_match_initial_values() {
        let dev = PolySynthDevice::new(SR);
        for info in dev.parameters() {
            // `default` is a real value (an index for enums); `get_parameter` is normalized.
            let expected = match info.param_type {
                ParamType::Enum => enum_to_norm(info.default as usize, info.enum_values.len()),
                _ => real_to_norm(
                    info.default,
                    info.min,
                    info.max,
                    info.is_logarithmic,
                    info.skew,
                ),
            };
            let actual = dev.get_parameter(info.id).unwrap();
            assert!(
                (actual - expected).abs() < 1e-4,
                "param {} ({}): default {} but initial {}",
                info.id,
                info.name,
                expected,
                actual
            );
        }
    }

    #[test]
    fn parameter_ids_and_names_are_unique() {
        let infos = PolySynthDevice::new(SR).parameters();
        for (i, a) in infos.iter().enumerate() {
            for b in &infos[i + 1..] {
                assert_ne!(a.id, b.id);
                assert_ne!(a.name, b.name);
            }
        }
    }

    #[test]
    fn defaults_decode_to_the_documented_patch() {
        let p = SynthParams::new();
        assert_eq!(p.osc[0].wave, 2, "Osc 1 saw");
        assert_eq!(p.osc[1].wave, 1, "Osc 2 pulse");
        assert!((p.osc[1].transpose - 0.07).abs() < 1e-4, "Osc 2 +7 cents");
        assert_eq!(p.osc[0].unison, 1);
        assert_eq!(p.polyphony, 16);
        assert_eq!(p.mode, VoiceMode::Poly);
        assert!((p.volume_gain - 0.501).abs() < 0.01, "-6 dB");
    }

    #[test]
    fn note_renders_then_releases_to_silence() {
        let mut dev = synth();
        dev.set_parameter(AMP_RELEASE, 0.0); // shortest release
        dev.send_midi_event(60, 100, true, 0);
        assert!(
            peak(&render(&mut dev, 8)) > 0.01,
            "note on should be audible"
        );

        dev.send_midi_event(60, 0, false, 0);
        render(&mut dev, 16); // let the release finish
        assert_eq!(peak(&render(&mut dev, 4)), 0.0, "silent after release");
    }

    #[test]
    fn oversized_block_does_not_grow_scratch() {
        let mut dev = synth();
        let cap = dev.mix_l.len();
        let frames = cap + 100;
        let mut out = vec![0.0; frames * 2];
        dev.send_midi_event(60, 100, true, 0);
        dev.process_block(&[], &mut out, frames);
        assert_eq!(dev.mix_l.len(), cap);
    }

    #[test]
    fn voice_budget_counts_unison_and_caps_a_big_chord() {
        let mut dev = synth();
        set_real(&mut dev, OSC1 + UNISON, 6.0); // 7 voices
        set_real(&mut dev, OSC2 + UNISON, 2.0); // 3 voices; cost is the max
        set_real(&mut dev, POLYPHONY, 63.0);
        dev.send_midi_event(40, 100, true, 0);
        render(&mut dev, 1);
        assert_eq!(dev.usage(), (7, 1));

        for note in 41..56 {
            dev.send_midi_event(note, 100, true, 0);
        }
        // Check at every block while stolen voices hand over.
        for _ in 0..8 {
            render(&mut dev, 1);
            let (used, _) = dev.usage();
            assert!(used <= VOICE_BUDGET, "{used} voices in use");
        }
        // 64 / 7 = 9 notes fit; the newest nine are the ones held.
        assert_eq!(sounding_notes(&dev), (47..56).collect::<Vec<u8>>());
        let total_oscillators: usize = dev
            .voices
            .iter()
            .filter(|v| v.active)
            .map(|v| v.unison[0] + v.unison[1])
            .sum();
        assert!(total_oscillators <= VOICE_BUDGET * 2);
    }

    #[test]
    fn polyphony_limits_notes() {
        let mut dev = synth();
        set_real(&mut dev, POLYPHONY, 3.0); // 4 notes
        for note in 60..66 {
            dev.send_midi_event(note, 100, true, 0);
        }
        render(&mut dev, 4);
        assert_eq!(sounding_notes(&dev), vec![62, 63, 64, 65]);
    }

    #[test]
    fn steal_prefers_releasing_voices() {
        let mut dev = synth();
        set_real(&mut dev, POLYPHONY, 3.0); // 4 notes
        set_real(&mut dev, AMP_RELEASE, 5.0);
        for note in [60, 62, 64, 65] {
            dev.send_midi_event(note, 100, true, 0);
            render(&mut dev, 1);
        }
        // 62 is released (and quieter than the held notes); 60 is the oldest held.
        dev.send_midi_event(62, 0, false, 0);
        render(&mut dev, 4);
        dev.send_midi_event(67, 100, true, 0);
        render(&mut dev, 4);
        assert_eq!(sounding_notes(&dev), vec![60, 64, 65, 67]);

        // With nothing releasing, the oldest held note goes.
        dev.send_midi_event(69, 100, true, 0);
        render(&mut dev, 4);
        assert_eq!(sounding_notes(&dev), vec![64, 65, 67, 69]);
    }

    #[test]
    fn stolen_voice_fades_instead_of_jumping() {
        let mut dev = synth();
        set_real(&mut dev, POLYPHONY, 0.0); // 1 note
        dev.send_midi_event(48, 127, true, 0);
        render(&mut dev, 8);
        dev.send_midi_event(60, 127, true, 0);
        let out = render(&mut dev, 2);
        // Largest sample-to-sample step stays that of a steady saw at these levels; a hard cut
        // would jump by the full amplitude.
        let left: Vec<f32> = out.iter().step_by(2).copied().collect();
        let steady = peak(&left) * 2.0;
        let max_step = left
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max);
        assert!(max_step <= steady, "step {max_step} vs {steady}");
        assert_eq!(sounding_notes(&dev), vec![60]);
    }

    #[test]
    fn note_order_counts_notes_not_blocks() {
        let mut dev = synth();
        set_real(&mut dev, POLYPHONY, 1.0); // 2 notes
                                            // Three notes inside one block: the first is the oldest and gets stolen.
        dev.send_midi_event(60, 100, true, 0);
        dev.send_midi_event(64, 100, true, 10);
        dev.send_midi_event(67, 100, true, 20);
        render(&mut dev, 2);
        assert_eq!(sounding_notes(&dev), vec![64, 67]);
    }

    #[test]
    fn legato_note_stack_survives_out_of_order_releases() {
        let mut dev = synth();
        set_real(&mut dev, VOICE_MODE, 2.0);
        for note in [60, 64, 67] {
            dev.send_midi_event(note, 100, true, 0);
            render(&mut dev, 1);
        }
        assert_eq!(dev.voices[0].note, 67);
        // Releasing a key that isn't sounding changes nothing audible.
        dev.send_midi_event(64, 0, false, 0);
        render(&mut dev, 1);
        assert_eq!(dev.voices[0].note, 67);
        assert!(dev.voices[0].gate);

        // Releasing the top returns to 60 (not the released 64), without an envelope restart.
        dev.send_midi_event(67, 0, false, 0);
        render(&mut dev, 1);
        let v = &dev.voices[0];
        assert_eq!(v.note, 60);
        assert!(v.gate);
        assert_ne!(v.amp_env.state(), crate::audio::dsp::AdsrState::Attack);

        dev.send_midi_event(60, 0, false, 0);
        render(&mut dev, 1);
        assert!(!dev.voices[0].gate);
        assert!(
            dev.voices[1..].iter().all(|v| !v.active),
            "mono uses one voice"
        );
    }

    #[test]
    fn mono_retriggers_and_legato_does_not() {
        for (mode, expect_attack) in [(1.0, true), (2.0, false)] {
            let mut dev = synth();
            set_real(&mut dev, VOICE_MODE, mode);
            set_real(&mut dev, AMP_ATTACK, 0.05);
            set_real(&mut dev, AMP_DECAY, 0.01);
            set_real(&mut dev, AMP_SUSTAIN, 0.3); // below 1, so an attack has somewhere to go
            dev.send_midi_event(60, 100, true, 0);
            render(&mut dev, 20); // into sustain
            dev.send_midi_event(62, 100, true, 0);
            render(&mut dev, 1);
            let attacking = dev.voices[0].amp_env.state() == crate::audio::dsp::AdsrState::Attack;
            assert_eq!(attacking, expect_attack, "mode {mode}");
        }
    }

    #[test]
    fn glide_reaches_the_target_in_the_set_time() {
        let mut dev = synth();
        set_real(&mut dev, VOICE_MODE, 1.0);
        set_real(&mut dev, GLIDE, 0.1);
        dev.send_midi_event(48, 100, true, 0);
        render(&mut dev, 1);
        assert_eq!(dev.voices[0].pitch, 48.0);

        dev.send_midi_event(60, 100, true, 0);
        let glide_frames = (0.1 * SR) as usize; // 4800
        let mut frames = 0;
        let mut out = vec![0.0; 64 * 2];
        while frames + 64 <= glide_frames - 64 {
            dev.process_block(&[], &mut out, 64);
            frames += 64;
        }
        let almost = dev.voices[0].pitch;
        assert!(
            almost > 58.0 && almost < 60.0,
            "pitch {almost} near the end"
        );
        dev.process_block(&[], &mut out, 64);
        dev.process_block(&[], &mut out, 64);
        assert_eq!(dev.voices[0].pitch, 60.0);
    }

    #[test]
    fn poly_glides_from_the_last_note_and_zero_glide_jumps() {
        let mut dev = synth();
        set_real(&mut dev, GLIDE, 0.2);
        dev.send_midi_event(48, 100, true, 0);
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 1);
        let v = dev
            .voices
            .iter()
            .find(|v| v.active && v.note == 60)
            .unwrap();
        assert!(v.pitch > 48.0 && v.pitch < 49.0, "pitch {}", v.pitch);

        let mut dev = synth();
        dev.send_midi_event(48, 100, true, 0);
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 1);
        let v = dev
            .voices
            .iter()
            .find(|v| v.active && v.note == 60)
            .unwrap();
        assert_eq!(v.pitch, 60.0);
    }

    fn rms(samples: impl Iterator<Item = f32>) -> f32 {
        let (sum, n) = samples.fold((0.0f64, 0usize), |(s, n), x| (s + (x * x) as f64, n + 1));
        (sum / n as f64).sqrt() as f32
    }

    fn render_unison(spread_percent: f32) -> Vec<f32> {
        let mut dev = synth();
        set_real(&mut dev, OSC1 + UNISON, 6.0);
        set_real(&mut dev, OSC1 + UNISON_SPREAD, spread_percent);
        dev.send_midi_event(57, 100, true, 0);
        render(&mut dev, 2); // skip the attack
        render(&mut dev, 40)
    }

    #[test]
    fn unison_is_stereo_and_mono_sums_without_cancelling() {
        let wide = render_unison(100.0);
        let left: Vec<f32> = wide.iter().step_by(2).copied().collect();
        let right: Vec<f32> = wide.iter().skip(1).step_by(2).copied().collect();
        let diff = rms(left.iter().zip(&right).map(|(l, r)| l - r));
        assert!(
            diff > 0.1 * rms(left.iter().copied()),
            "L and R should differ"
        );

        let centred = render_unison(0.0);
        let mono = |s: &[f32]| rms(s.chunks(2).map(|f| (f[0] + f[1]) * 0.5));
        let ratio = mono(&wide) / mono(&centred);
        assert!(
            ratio > 0.6,
            "mono sum at 100% spread is {ratio:.2} of centred"
        );
    }

    #[test]
    fn single_oscillator_is_centred() {
        let mut dev = synth();
        dev.send_midi_event(60, 100, true, 0);
        let out = render(&mut dev, 4);
        assert!(out.chunks(2).all(|f| (f[0] - f[1]).abs() < 1e-6));
    }

    #[test]
    fn pitch_knobs_reach_held_notes() {
        let mut dev = synth();
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 1);
        let before = dev.voices[0].pitch + dev.params.osc[0].transpose;
        set_real(&mut dev, OSC1 + SEMI, 19.0); // +7
        render(&mut dev, 1);
        let after = dev.voices[0].pitch + dev.params.osc[0].transpose;
        assert_eq!(after - before, 7.0);
    }

    #[test]
    fn noise_alone_is_audible_at_every_color() {
        for color in [0.0, 50.0, 100.0] {
            let mut dev = synth();
            set_real(&mut dev, OSC1 + LEVEL, 0.0);
            set_real(&mut dev, NOISE_LEVEL, 1.0);
            set_real(&mut dev, NOISE_COLOR, color);
            dev.send_midi_event(60, 100, true, 0);
            let out = render(&mut dev, 8);
            let level = rms(out.iter().copied());
            assert!(level > 0.02 && level < 1.0, "color {color}: rms {level}");
        }
    }

    #[test]
    fn mode_change_silences_held_notes() {
        let mut dev = synth();
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 2);
        set_real(&mut dev, VOICE_MODE, 1.0);
        render(&mut dev, 2);
        assert!(dev.voices.iter().all(|v| !v.active));
    }
    /// Spectral centroid (Hz) of `samples` (mono), Hann-windowed.
    fn centroid(samples: &[f32]) -> f32 {
        use realfft::RealFftPlanner;
        let n = samples.len();
        let mut input: Vec<f32> = samples
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let w = 0.5 - 0.5 * (std::f32::consts::TAU * i as f32 / n as f32).cos();
                s * w
            })
            .collect();
        let fft = RealFftPlanner::<f32>::new().plan_fft_forward(n);
        let mut spectrum = fft.make_output_vec();
        fft.process(&mut input, &mut spectrum).unwrap();
        let (weighted, total) =
            spectrum
                .iter()
                .enumerate()
                .fold((0.0f64, 0.0f64), |(w, t), (k, c)| {
                    let m = c.norm() as f64;
                    (w + k as f64 * m, t + m)
                });
        (weighted / total.max(1e-12)) as f32 * SR / n as f32
    }

    fn left(interleaved: &[f32]) -> Vec<f32> {
        interleaved.iter().step_by(2).copied().collect()
    }

    #[test]
    fn default_patch_routes_filter_env_to_cutoff() {
        let dev = synth();
        let routes = dev.mod_routes();
        assert_eq!(routes.len(), 1);
        assert_eq!(routes[0].source, "filter_env");
        assert_eq!(routes[0].param_id, CUTOFF);
        assert!((routes[0].amount - 0.35).abs() < 1e-6);
        let sources: Vec<String> = dev.mod_sources().into_iter().map(|s| s.id).collect();
        assert_eq!(
            sources,
            [
                "filter_env",
                "amp_env",
                "lfo1",
                "lfo2",
                "velocity",
                "keytrack"
            ]
        );
    }

    #[test]
    fn filter_env_to_cutoff_gives_a_decaying_centroid() {
        // The "done when" pluck: short Filter Env decay, sustain 0, some resonance.
        let mut dev = synth();
        set_real(&mut dev, FILTER_ENV + DECAY, 0.15);
        set_real(&mut dev, CUTOFF, 400.0);
        set_real(&mut dev, RESONANCE, 0.5);
        dev.set_mod_route("filter_env", CUTOFF, 0.6).unwrap();
        dev.send_midi_event(48, 110, true, 0);
        let out = left(&render(&mut dev, 80)); // ~427 ms
        let window = 2048;
        let early = centroid(&out[512..512 + window]);
        let middle = centroid(&out[6_000..6_000 + window]);
        let late = centroid(&out[16_000..16_000 + window]);
        assert!(
            early > middle * 1.3 && middle > late,
            "centroid should fall: {early:.0} → {middle:.0} → {late:.0} Hz"
        );

        // Without the route the tone doesn't move.
        let mut dev = synth();
        dev.clear_mod_routes();
        set_real(&mut dev, CUTOFF, 400.0);
        dev.send_midi_event(48, 110, true, 0);
        let out = left(&render(&mut dev, 80));
        let (a, b) = (
            centroid(&out[512..512 + window]),
            centroid(&out[16_000..16_000 + window]),
        );
        assert!(
            (a / b - 1.0).abs() < 0.15,
            "static filter: {a:.0} vs {b:.0} Hz"
        );
    }

    #[test]
    fn cutoff_and_filter_type_shape_the_sound() {
        let brightness = |cutoff: f32, filter_type: f32| {
            let mut dev = synth();
            dev.clear_mod_routes();
            set_real(&mut dev, CUTOFF, cutoff);
            set_real(&mut dev, FILTER_TYPE, filter_type);
            dev.send_midi_event(48, 110, true, 0);
            render(&mut dev, 4);
            centroid(&left(&render(&mut dev, 16)))
        };
        assert!(brightness(300.0, 1.0) < brightness(5_000.0, 1.0) * 0.5);
        assert!(
            brightness(2_000.0, 2.0) > brightness(2_000.0, 1.0) * 2.0,
            "HP brighter than LP"
        );
    }

    #[test]
    fn modulated_values_clamp_and_stay_finite() {
        // Decoding clamps: base + Σ outside 0..1 lands on the range ends.
        let mut p = SynthParams::new();
        let level = params::slot(OSC1 + LEVEL).unwrap();
        p.set_slot(level, 0.8 + 1.0);
        assert_eq!(p.osc[0].level, 1.0);
        p.set_slot(level, 0.8 - 2.0);
        assert_eq!(p.osc[0].level, 0.0);

        // Every source into every float parameter at ±1 still renders finite, bounded audio.
        for sr in [44_100.0, 96_000.0, 192_000.0] {
            let mut dev = PolySynthDevice::new(sr);
            dev.prepare(sr, BLOCK);
            let floats: Vec<ParamId> = dev
                .parameters()
                .into_iter()
                .filter(|p| p.param_type == ParamType::Float)
                .map(|p| p.id)
                .collect();
            let mut added = 0;
            for (i, source) in ModSource::ALL.iter().enumerate() {
                for (j, &id) in floats.iter().enumerate() {
                    if added < modulation::MAX_ROUTES && (i + j) % 3 == 0 {
                        let amount = if (i + j) % 2 == 0 { 1.0 } else { -1.0 };
                        dev.set_mod_route(source.id(), id, amount).unwrap();
                        added += 1;
                    }
                }
            }
            set_real(&mut dev, RESONANCE, 1.0);
            set_real(&mut dev, LFO1 + LFO_RATE, 40.0);
            set_real(&mut dev, LFO1 + LFO_SHAPE, 4.0); // S&H
            for note in [24, 60, 96, 127] {
                dev.send_midi_event(note, 127, true, 0);
            }
            let out = render(&mut dev, 40);
            assert!(out.iter().all(|s| s.is_finite()), "non-finite at {sr}");
            assert!(peak(&out) < 20.0, "peak {} at {sr}", peak(&out));
        }
    }

    #[test]
    fn mod_routes_reject_enums_and_unknown_ids() {
        let mut dev = synth();
        assert!(dev.set_mod_route("lfo1", FILTER_TYPE, 0.5).is_err(), "enum");
        assert!(dev.set_mod_route("lfo1", 99, 0.5).is_err(), "unknown param");
        assert!(
            dev.set_mod_route("mod_wheel", CUTOFF, 0.5).is_err(),
            "unknown source"
        );
        dev.set_mod_route("lfo1", CUTOFF, 0.25).unwrap();
        dev.set_mod_route("lfo1", CUTOFF, -0.5).unwrap(); // update
        assert_eq!(dev.mod_routes().len(), 2);
        assert_eq!(dev.mod_routes()[1].amount, -0.5);
        dev.set_mod_route("lfo1", CUTOFF, 0.0).unwrap(); // remove
        assert_eq!(dev.mod_routes().len(), 1);
        dev.clear_mod_routes();
        assert!(dev.mod_routes().is_empty());
    }

    #[test]
    fn lfo_sync_period_is_the_beat_length_at_120_bpm() {
        let mut dev = synth();
        dev.set_transport(&crate::audio::transport::Transport {
            tempo: 120.0,
            ..Default::default()
        });
        set_real(&mut dev, LFO1 + LFO_SYNC, 13.0); // 1/4
        assert_eq!(dev.params.lfo[0].hz(120.0), 2.0);
        set_real(&mut dev, LFO1 + LFO_SYNC, 14.0); // 1/4 dotted
        assert!((dev.params.lfo[0].hz(120.0) - 2.0 / 1.5).abs() < 1e-9);
        set_real(&mut dev, LFO1 + LFO_SYNC, 15.0); // 1/4 triplet
        assert!((dev.params.lfo[0].hz(120.0) - 3.0).abs() < 1e-9);

        set_real(&mut dev, LFO1 + LFO_SYNC, 13.0);
        dev.send_midi_event(60, 100, true, 0);
        // A quarter note at 120 BPM is 0.5 s: the retriggered LFO is back at phase 0 then,
        // and half-way at 0.25 s.
        let quarter = (SR * 0.5) as usize;
        let mut out = vec![0.0; 2 * 200];
        for _ in 0..quarter / 400 {
            dev.process_block(&[], &mut out, 200);
        }
        assert!(
            (dev.voices[0].lfo[0].phase - 0.5).abs() < 1e-6,
            "{}",
            dev.voices[0].lfo[0].phase
        );
        for _ in 0..quarter / 400 {
            dev.process_block(&[], &mut out, 200);
        }
        let phase = dev.voices[0].lfo[0].phase;
        assert!(
            phase < 1e-6 || phase > 1.0 - 1e-6,
            "phase {phase} after one beat"
        );
    }

    #[test]
    fn free_lfo_keeps_voices_in_phase_and_note_retrigger_resets() {
        let mut dev = synth();
        set_real(&mut dev, LFO1 + LFO_RETRIGGER, 0.0); // Free
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 7);
        dev.send_midi_event(64, 100, true, 0);
        render(&mut dev, 3);
        let phases: Vec<f64> = dev
            .voices
            .iter()
            .filter(|v| v.active)
            .map(|v| v.lfo[0].phase)
            .collect();
        assert_eq!(phases.len(), 2);
        assert!((phases[0] - phases[1]).abs() < 1e-3, "{phases:?}");

        let mut dev = synth(); // Retrigger Note (default)
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 7);
        dev.send_midi_event(64, 100, true, 0);
        render(&mut dev, 3);
        let phases: Vec<f64> = dev
            .voices
            .iter()
            .filter(|v| v.active)
            .map(|v| v.lfo[0].phase)
            .collect();
        assert!((phases[0] - phases[1]).abs() > 0.1, "{phases:?}");
    }

    #[test]
    fn lfo_to_pitch_wobbles_without_steps() {
        // LFO 1 → Osc 1 Fine: a sine's instantaneous frequency must move smoothly (pitch is
        // interpolated across control blocks, not stepped).
        let mut dev = synth();
        dev.clear_mod_routes();
        set_real(&mut dev, CUTOFF, 20_000.0);
        set_real(&mut dev, OSC1 + WAVE, 0.0); // sine
        set_real(&mut dev, LFO1 + LFO_RATE, 6.0);
        dev.set_mod_route("lfo1", OSC1 + FINE, 0.5).unwrap(); // ±100 cents
        dev.send_midi_event(69, 127, true, 0);
        render(&mut dev, 4);
        let out = left(&render(&mut dev, 40));
        // Zero-crossing intervals (in samples) vary, but neighbouring ones barely differ.
        let crossings: Vec<f32> = out
            .windows(2)
            .enumerate()
            .filter(|(_, w)| w[0] <= 0.0 && w[1] > 0.0)
            .map(|(i, w)| i as f32 + w[0] / (w[0] - w[1]))
            .collect();
        let periods: Vec<f32> = crossings.windows(2).map(|w| w[1] - w[0]).collect();
        let (lo, hi) = periods
            .iter()
            .fold((f32::MAX, 0.0f32), |(l, h), &p| (l.min(p), h.max(p)));
        assert!(hi / lo > 1.08, "vibrato depth {lo}..{hi}");
        // A smooth 6 Hz vibrato changes the period by up to ~0.55 samples per cycle, and that
        // change itself drifts slowly; a stepped pitch would show up as jerks in it.
        let changes: Vec<f32> = periods.windows(2).map(|w| w[1] - w[0]).collect();
        let max_jerk = changes
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max);
        assert!(max_jerk < 0.2, "period change jerks by {max_jerk} samples");
    }

    #[test]
    fn key_track_raises_cutoff_for_high_notes() {
        let brightness_ratio = |key_track: f32| {
            let render_note = |note: u8| {
                let mut dev = synth();
                dev.clear_mod_routes();
                set_real(&mut dev, CUTOFF, 500.0);
                set_real(&mut dev, KEY_TRACK, key_track);
                dev.send_midi_event(note, 110, true, 0);
                render(&mut dev, 4);
                rms(render(&mut dev, 16).into_iter())
            };
            render_note(84) / render_note(48)
        };
        // Tracking lets more of the high note through the same filter.
        assert!(brightness_ratio(100.0) > brightness_ratio(0.0) * 2.0);
    }
}

#[cfg(test)]
mod bench {
    use super::params::*;
    use super::*;

    /// Worst case for the budget: 16 notes × unison 4 on both oscillators = 64 voices,
    /// 128 PolyBLEP oscillators, LP 24 (stereo, since unison spreads) and 8 modulation routes.
    /// `cargo test --release cpu_full_budget -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn cpu_full_budget() {
        const SR: f32 = 48_000.0;
        const FRAMES: usize = 256;
        let mut dev = PolySynthDevice::new(SR);
        dev.prepare(SR, FRAMES);
        let set = |dev: &mut PolySynthDevice, id, index| {
            let n = dev.parameters().into_iter().find(|p| p.id == id).unwrap();
            dev.set_parameter(
                id,
                crate::audio::devices::enum_to_norm(index, n.enum_values.len()),
            );
        };
        set(&mut dev, OSC1 + UNISON, 3);
        set(&mut dev, OSC2 + UNISON, 3);
        dev.set_parameter(OSC2 + LEVEL, 0.5);
        // The default Filter Env → Cutoff plus seven more, touching every interpolated kind of
        // destination (cutoff, pitch, level) and some block-constant ones. Routes that switch on
        // extra DSP (noise, drive) are left out; together they add about 0.5 % more.
        for (source, id) in [
            ("lfo1", CUTOFF),
            ("lfo2", OSC1 + FINE),
            ("lfo2", OSC2 + FINE),
            ("velocity", OSC1 + LEVEL),
            ("lfo1", OSC2 + LEVEL),
            ("amp_env", OSC2 + PULSE_WIDTH),
            ("keytrack", RESONANCE),
        ] {
            dev.set_mod_route(source, id, 0.3).unwrap();
        }
        assert_eq!(dev.mod_routes().len(), 8);
        for note in 48..64 {
            dev.send_midi_event(note, 100, true, 0);
        }
        let mut out = vec![0.0; FRAMES * 2];
        let blocks = (SR as usize * 10) / FRAMES; // 10 s of audio
        let start = std::time::Instant::now();
        for _ in 0..blocks {
            dev.process_block(&[], &mut out, FRAMES);
        }
        let elapsed = start.elapsed().as_secs_f64();
        assert_eq!(dev.usage().0, 64);
        println!(
            "10 s rendered in {:.3} s: {:.2} % of one core",
            elapsed,
            elapsed / 10.0 * 100.0
        );
    }
}
