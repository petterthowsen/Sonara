//! PolySynth: two band-limited oscillators with unison, noise, a drive + state-variable filter,
//! an amp envelope, Poly/Mono/Legato voice modes, glide, per-voice modulators, and two-op
//! phase modulation (FM) on the Osc 1 carrier.
//!
//! - One shared [`SynthParams`] block; voices read it every control block, so knob moves reach
//!   held notes.
//! - A preallocated pool of 64 note slots. A note costs `max(Osc 1 unison, Osc 2 unison)` voices
//!   out of a budget of 64, and notes are further limited by Polyphony.
//! - Stealing takes a releasing voice (quietest first), else the oldest held note. The stolen
//!   voice fades for a few ms and then starts the queued note.
//! - Modulators belong to the device *instance* (spec 018 Phase 6): the `ModulatedDevice`
//!   wrapper owns them and hands over a [`VoiceModSpec`]; each voice runs one [`ModulatorState`]
//!   per modulator and evaluates the routes into this device's own parameters. Routes into
//!   PolySynth from an enclosing container arrive as a mono offset on [`SynthParams`].

mod params;
mod voice;

use super::{
    AudioDevice, DefaultModulator, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo,
    ParamValue, PortFlow,
};
use crate::audio::dsp::SmoothedParam;
use crate::audio::modulation::kinds::{
    ModulatorKind, ENV_ATTACK, ENV_DECAY, ENV_RELEASE, ENV_SUSTAIN, LFO_RATE, LFO_RETRIGGER,
};
use crate::audio::modulation::{ModulatorState, VoiceModSpec, MAX_MODULATORS};
use crate::audio::transport::Transport;
use params::{Changed, SynthParams, VoiceMode, CUTOFF, MAX_POLYPHONY};
use voice::{PendingNote, RenderCtx, StartCtx, Voice};

/// Voices (unison sub-voices) all sounding notes may use together.
const VOICE_BUDGET: usize = 64;
/// Scratch size used until `prepare` supplies the real block size.
const DEFAULT_MAX_FRAMES: usize = 4096;
/// The default Filter Env → Cutoff amount (real PolySynth's default patch).
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

    fn contains(&self, note: u8) -> bool {
        self.notes[..self.len].contains(&note)
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
    /// The wrapper's modulator definitions and self-targeting routes.
    voice_spec: VoiceModSpec,
    /// Device-level free-running LFOs: one per modulator slot that is a Free LFO. A new voice
    /// seeds its own LFO from `free_phase`, so free LFOs stay phase-locked across voices.
    free_lfo: [Option<ModulatorState>; MAX_MODULATORS],
    free_phase: [f64; MAX_MODULATORS],
    /// Transport as of the coming block, for synced modulator rates.
    transport: Transport,

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
            voice_spec: VoiceModSpec::empty(),
            free_lfo: [None; MAX_MODULATORS],
            free_phase: [0.0; MAX_MODULATORS],
            transport: Transport::default(),
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
        dev
    }

    /// Build the voice pool and scratch. Off the audio thread only.
    fn allocate(&mut self, sample_rate: f32, frames: usize) {
        self.voices = (0..MAX_POLYPHONY)
            .map(|i| Voice::new(sample_rate, i as u32 + 1))
            .collect();
        self.configure_voices();
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
        StartCtx {
            glide: self.params.glide,
            free_lfo: self.free_phase,
        }
    }

    /// Point every voice's modulators at the current spec (used after `allocate`).
    fn configure_voices(&mut self) {
        let spec = self.voice_spec;
        let sample_rate = self.sample_rate;
        for voice in self.voices.iter_mut() {
            voice.configure_mods(&spec, sample_rate);
        }
    }

    /// Rebuild the device-level free LFOs from the spec, preserving the phase of a slot that is
    /// still a free LFO (so automating an LFO's rate does not reset it).
    fn rebuild_free_lfos(&mut self) {
        for slot in 0..MAX_MODULATORS {
            let wants_free = self
                .voice_spec
                .kind(slot)
                .is_some_and(|k| k == ModulatorKind::Lfo)
                && self
                    .voice_spec
                    .params(slot)
                    .map(|p| p.real(LFO_RETRIGGER).unwrap_or(0.0) < 0.5)
                    .unwrap_or(false);
            if !wants_free {
                self.free_lfo[slot] = None;
                continue;
            }
            let params = *self.voice_spec.params(slot).expect("checked above");
            match &mut self.free_lfo[slot] {
                Some(state) => {
                    state.prepare(self.sample_rate);
                    for spec in state.kind().table().specs {
                        if let Some(norm) = params.get(spec.id) {
                            state.set_param(spec.id, norm);
                        }
                    }
                    self.free_phase[slot] = state.lfo_phase();
                }
                None => {
                    self.free_lfo[slot] =
                        Some(ModulatorState::new(ModulatorKind::Lfo, self.sample_rate));
                    let state = self.free_lfo[slot].as_mut().unwrap();
                    for spec in state.kind().table().specs {
                        if let Some(norm) = params.get(spec.id) {
                            state.set_param(spec.id, norm);
                        }
                    }
                    self.free_phase[slot] = state.lfo_phase();
                }
            }
        }
    }

    /// Where a new note glides from. With Glide Scope `Connected`, only when the previous
    /// note was still held when this one started; a detached note-on jumps straight in.
    fn glide_from(&self, connected: bool) -> Option<f32> {
        if self.params.glide > 0.0 && (connected || !self.params.glide_only_connected) {
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

        // Poly tracks held keys too, so "connected" (the previous note still held) can gate
        // glide just as the Mono/Legato note stack does.
        let connected = self.last_note.is_some_and(|n| self.held.contains(n as u8));
        self.held.push(note);
        let unison = self.unison_counts();
        let pending = PendingNote {
            note,
            velocity,
            age,
            glide_from: self.glide_from(connected),
            unison,
            released: false,
        };

        // The same key again: fade the sounding voice out over the steal fade and give the
        // repeat a fresh voice with a full attack — the drum retrigger crossfade (spec 013).
        // Retriggering in place would restart the amp envelope from its current level, which
        // is at the peak while the note sounds, so the attack would be skipped entirely.
        if let Some(v) = self
            .voices
            .iter_mut()
            .find(|v| v.active && !v.is_fading() && v.note == note)
        {
            v.steal(pending);
            return;
        }

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
        // With Glide Scope `Connected`, a press that arrives while nothing is held starts on
        // its own pitch instead of sliding from wherever the releasing voice is.
        let glide_secs = if was_held || !self.params.glide_only_connected {
            glide
        } else {
            0.0
        };
        let start = self.start_ctx();
        let voice = &mut self.voices[0];
        if voice.active && !voice.is_fading() {
            // Legato only slides while another key is held; Mono always retriggers.
            voice.retrigger(
                note,
                velocity,
                age,
                glide_secs,
                !(legato && was_held),
                &start,
            );
        } else {
            let pending = PendingNote {
                note,
                velocity,
                age,
                glide_from: if glide > 0.0 && (was_held || !self.params.glide_only_connected) {
                    self.last_note
                } else {
                    None
                },
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
                self.held.remove(note);
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
                let retrigger = self.params.mode == VoiceMode::Mono;
                let glide = self.params.glide;
                let age = self.next_age();
                let start = self.start_ctx();
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
                        voice.retrigger(top, velocity, age, glide, retrigger, &start);
                    }
                    None => voice.release(),
                }
            }
        }
    }

    /// Follow up on what a parameter change touched (shared by `set_parameter` and
    /// `set_param_mod`).
    fn apply_change(&mut self, changed: Changed) {
        match changed {
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

    fn apply_envelopes(&mut self) {
        let a = self.params.amp_env;
        for v in self.voices.iter_mut() {
            v.amp_env.set_adsr(a.attack, a.decay, a.sustain, a.release);
        }
        self.env_dirty = false;
    }

    /// Render every sounding voice over `[start, end)` of the block into the mix buffers, in
    /// control blocks so the free LFOs advance in lockstep with the voices.
    fn render_span(&mut self, start: usize, end: usize) {
        let mut pos = start;
        while pos < end {
            let chunk_end = (pos + voice::CONTROL_BLOCK).min(end);
            self.advance_free_lfos(chunk_end - pos);
            let start_ctx = self.start_ctx();
            let ctx = RenderCtx {
                params: &self.params,
                spec: &self.voice_spec,
                levels: [&self.level_buf[0], &self.level_buf[1]],
                noise_level: &self.noise_buf,
                cutoff: &self.cutoff_buf,
                start: start_ctx,
                transport: self.transport,
            };
            for voice in self.voices.iter_mut() {
                if !voice.ensure_started(&ctx.start) {
                    continue;
                }
                voice.render_chunk(&ctx, pos, chunk_end, &mut self.mix_l, &mut self.mix_r);
                voice.finish_chunk(&ctx.start);
            }
            // Keep the block-start transport moving so synced LFOs follow the song position.
            self.transport.advance(chunk_end - pos, self.sample_rate);
            pos = chunk_end;
        }
    }

    /// Advance the device-level free LFOs one control block and remember their phases, which a
    /// fresh voice copies so free LFOs stay phase-locked across voices.
    fn advance_free_lfos(&mut self, frames: usize) {
        for slot in 0..MAX_MODULATORS {
            if let Some(state) = self.free_lfo[slot].as_mut() {
                state.advance(frames, &self.transport);
                self.free_phase[slot] = state.lfo_phase();
            }
        }
    }

    /// Effective normalized value of `slot` on one voice: the base (mono offset included) plus
    /// the voice's own routed modulators, clamped, as the `modulation` data stream reports it.
    fn voice_mod_value(&self, voice: &Voice, param_id: ParamId, slot: usize, base: f32) -> f32 {
        let mut sum = 0.0;
        for route in self.voice_spec.routes() {
            if route.param_id != param_id {
                continue;
            }
            if let Some(state) = voice.mods.get(route.mod_slot).and_then(|s| s.as_ref()) {
                sum += route.amount * state.value();
            }
        }
        (base + sum).clamp(0.0, 1.0)
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
        // The cutoff smoother carries the *effective* base (mono offset from an enclosing
        // wrapper included); a voice adds its own poly offset on top.
        let cutoff_slot = params::slot_of(CUTOFF);
        retarget(
            &mut self.cutoff_smoothed,
            self.params.effective_norm_at(cutoff_slot),
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
        let changed = self.params.set(param_id, value);
        self.apply_change(changed);
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        self.sleep_state.mark_activity();
        let changed = self.params.set_offset(param_id, offset);
        self.apply_change(changed);
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

    fn accepts_note_input(&self) -> bool {
        true
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        params::param_infos()
    }

    fn supports_voice_modulation(&self) -> bool {
        true
    }

    fn set_voice_modulation(&mut self, spec: &VoiceModSpec) {
        // A route-only change just needs the new route list; the per-voice states and the free
        // LFOs keep their phase and are re-read every block.
        let definitions_changed = !self.voice_spec.same_definitions(spec);
        self.voice_spec = *spec;
        if definitions_changed {
            self.rebuild_free_lfos();
            self.configure_voices();
        }
    }

    fn live_voice_mod_values(&self, param_id: ParamId, values: &mut [f32]) -> usize {
        let Some(slot) = params::slot(param_id) else {
            return 0;
        };
        // The mono offset an enclosing wrapper pushed in is part of the base, exactly as
        // `render_chunk` sees it.
        let base = self.params.effective_norm_at(slot);
        // One pass to find the newest voice (largest note-on age); it is reported last, as
        // the value a knob's arc follows.
        let mut newest = usize::MAX;
        let mut newest_age = 0;
        for (i, v) in self.voices.iter().enumerate() {
            if v.active && v.age >= newest_age {
                newest_age = v.age;
                newest = i;
            }
        }
        let mut written = 0;
        if values.is_empty() {
            return 0;
        }
        // Leave the last slot for the newest voice, so it always survives the cap.
        for (i, v) in self.voices.iter().enumerate() {
            if !v.active || i == newest || written + 1 >= values.len() {
                continue;
            }
            values[written] = self.voice_mod_value(v, param_id, slot, base);
            written += 1;
        }
        if newest != usize::MAX {
            values[written] = self.voice_mod_value(&self.voices[newest], param_id, slot, base);
            written += 1;
        }
        written
    }

    fn default_modulators(&self) -> Vec<DefaultModulator> {
        let mut out = Vec::new();

        // "Filter Env": a short pluck (A 2 ms, D 400 ms, S 0, R 300 ms) sweeping the cutoff.
        let adsr = ModulatorKind::Adsr;
        let mut params = Vec::new();
        for (id, real) in [
            (ENV_ATTACK, 0.002),
            (ENV_DECAY, 0.4),
            (ENV_SUSTAIN, 0.0),
            (ENV_RELEASE, 0.3),
        ] {
            if let Some(spec) = adsr.table().specs.iter().find(|s| s.id == id) {
                params.push((id, spec.to_norm(real)));
            }
        }
        out.push(DefaultModulator {
            kind: adsr,
            name: "Filter Env".to_string(),
            params,
            routes: vec![(format!("param/{CUTOFF}"), DEFAULT_FILTER_ENV_AMOUNT)],
        });

        // "LFO 1" and "LFO 2": 5 Hz, keyed per note, unrouted.
        for name in ["LFO 1", "LFO 2"] {
            let mut params = Vec::new();
            for (id, real) in [(LFO_RATE, 5.0), (LFO_RETRIGGER, 1.0)] {
                if let Some(spec) = ModulatorKind::Lfo.table().specs.iter().find(|s| s.id == id) {
                    params.push((id, spec.to_norm(real)));
                }
            }
            out.push(DefaultModulator {
                kind: ModulatorKind::Lfo,
                name: name.to_string(),
                params,
                routes: Vec::new(),
            });
        }
        out
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.transport = *transport;
    }

    fn reset(&mut self) {
        for voice in self.voices.iter_mut() {
            voice.reset();
        }
        for state in self.free_lfo.iter_mut().flatten() {
            state.reset();
        }
        self.free_phase = [0.0; MAX_MODULATORS];
        self.held.clear();
        self.note_counter = 0;
        self.last_note = None;
    }

    /// Rebuild the voices and scratch at the new rate (sounding notes stop).
    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        self.sample_rate = sample_rate;
        self.allocate(sample_rate, max_frames.max(DEFAULT_MAX_FRAMES));
        self.rebuild_free_lfos();
        let p = &self.params;
        let cutoff_slot = params::slot_of(CUTOFF);
        self.level_smoothed = [
            smoothed(p.osc[0].level, sample_rate),
            smoothed(p.osc[1].level, sample_rate),
        ];
        self.noise_smoothed = smoothed(p.noise_level, sample_rate);
        self.cutoff_smoothed = smoothed(p.effective_norm_at(cutoff_slot), sample_rate);
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

    use crate::audio::dsp::tempo_sync::index_of;
    use crate::audio::modulation::kinds::{ModParams, LFO_SHAPE, LFO_SYNC};
    use crate::audio::modulation::voice::VoiceRoute;

    /// A modulator's normalized parameter block, from `(id, real value)` pairs.
    fn mod_params(kind: ModulatorKind, values: &[(ParamId, f32)]) -> ModParams {
        let mut state = ModulatorState::new(kind, SR);
        for &(id, real) in values {
            let spec = kind.table().specs.iter().find(|s| s.id == id).unwrap();
            state.set_param(id, spec.to_norm(real));
        }
        *state.params()
    }

    /// Install a `VoiceModSpec` on the device, as the wrapper would.
    fn set_spec(
        dev: &mut PolySynthDevice,
        mods: &[(usize, ModulatorKind, &[(ParamId, f32)])],
        routes: &[(usize, ParamId, f32)],
    ) {
        let mut spec = VoiceModSpec::empty();
        for &(slot, kind, values) in mods {
            spec.kinds[slot] = Some(kind);
            spec.params[slot] = mod_params(kind, values);
        }
        for &(mod_slot, param_id, amount) in routes {
            spec.routes[spec.route_len] = VoiceRoute {
                mod_slot,
                param_id,
                amount,
            };
            spec.route_len += 1;
        }
        dev.set_voice_modulation(&spec);
    }

    /// A voice's LFO phase for modulator `slot`, if that slot is an LFO.
    fn lfo_phase(dev: &PolySynthDevice, voice: usize, slot: usize) -> f64 {
        dev.voices[voice].mods[slot]
            .as_ref()
            .expect("modulator")
            .lfo_phase()
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
        assert_ne!(
            v.amp_env.state(),
            crate::audio::modulation::envelope::AdsrState::Attack
        );

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
            let attacking = dev.voices[0].amp_env.state()
                == crate::audio::modulation::envelope::AdsrState::Attack;
            assert_eq!(attacking, expect_attack, "mode {mode}");
        }
    }

    #[test]
    fn poly_same_note_repeat_gets_a_fresh_attack() {
        use crate::audio::modulation::envelope::AdsrState;
        let mut dev = synth();
        set_real(&mut dev, AMP_ATTACK, 0.05);
        set_real(&mut dev, AMP_SUSTAIN, 1.0); // worst case: the level sits at the peak
        set_real(&mut dev, FM_INDEX, 4.0); // the reported repro: two-op FM on Osc 1
        set_real(&mut dev, FM_RATIO, 6.0); // enum index of "2", a carrier-frequency multiple
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 20); // into sustain
        assert_eq!(
            dev.voices
                .iter()
                .find(|v| v.active && !v.is_fading() && v.note == 60)
                .unwrap()
                .amp_env
                .value(),
            1.0
        );

        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 1); // the 4 ms steal fade completes, the queued note starts
        let v = dev
            .voices
            .iter()
            .find(|v| v.active && !v.is_fading() && v.note == 60)
            .unwrap();
        assert_eq!(v.amp_env.state(), AdsrState::Attack);
        assert!(
            v.amp_env.value() < 0.2,
            "attack should start over, not continue from the peak: {}",
            v.amp_env.value()
        );
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

    #[test]
    fn glide_scope_connected_gates_poly_glide() {
        let mut dev = synth();
        set_real(&mut dev, GLIDE, 0.2);
        set_real(&mut dev, GLIDE_SCOPE, 1.0);
        dev.send_midi_event(48, 100, true, 0);
        render(&mut dev, 1);
        dev.send_midi_event(60, 100, true, 0); // 48 still held: connected
        render(&mut dev, 1);
        let v = dev
            .voices
            .iter()
            .find(|v| v.active && v.note == 60)
            .unwrap();
        assert!(
            v.pitch > 48.0 && v.pitch < 49.0,
            "overlapping press should glide: {}",
            v.pitch
        );

        dev.send_midi_event(48, 0, false, 0);
        dev.send_midi_event(60, 0, false, 0);
        render(&mut dev, 1);
        dev.send_midi_event(67, 100, true, 0); // nothing held: detached
        render(&mut dev, 1);
        let v = dev
            .voices
            .iter()
            .find(|v| v.active && v.note == 67)
            .unwrap();
        assert_eq!(
            v.pitch, 67.0,
            "detached press should start on its own pitch, not glide from 60"
        );
    }

    #[test]
    fn glide_scope_connected_first_mono_press_jumps() {
        let mut dev = synth();
        set_real(&mut dev, VOICE_MODE, 1.0);
        set_real(&mut dev, GLIDE, 0.2);
        set_real(&mut dev, GLIDE_SCOPE, 1.0);
        dev.send_midi_event(48, 100, true, 0);
        render(&mut dev, 1);
        dev.send_midi_event(48, 0, false, 0);
        render(&mut dev, 40); // release (200 ms) finishes, the voice goes idle
        dev.send_midi_event(67, 100, true, 0);
        render(&mut dev, 1);
        let v = &dev.voices[0];
        assert!(v.active, "voice should sound");
        assert_eq!(
            v.pitch, 67.0,
            "a press from silence should jump, not glide from the old note"
        );
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
    fn default_modulators_define_the_default_patch() {
        let dev = synth();
        let mods = dev.default_modulators();
        assert_eq!(mods.len(), 3);

        let filter = &mods[0];
        assert_eq!(filter.kind, ModulatorKind::Adsr);
        assert_eq!(filter.name, "Filter Env");
        assert_eq!(filter.routes, vec![(format!("param/{CUTOFF}"), 0.35)]);
        let get = |id: ParamId| {
            filter
                .params
                .iter()
                .find(|(p, _)| *p == id)
                .map(|(_, v)| *v)
                .unwrap()
        };
        let real = |id: ParamId| {
            ModulatorKind::Adsr
                .table()
                .specs
                .iter()
                .find(|s| s.id == id)
                .unwrap()
                .to_real(get(id))
        };
        assert!((real(ENV_ATTACK) - 0.002).abs() < 1e-5);
        assert!((real(ENV_DECAY) - 0.4).abs() < 1e-5);
        assert_eq!(real(ENV_SUSTAIN), 0.0);
        assert!((real(ENV_RELEASE) - 0.3).abs() < 1e-5);

        for (i, name) in [(1, "LFO 1"), (2, "LFO 2")] {
            let lfo = &mods[i];
            assert_eq!(lfo.kind, ModulatorKind::Lfo);
            assert_eq!(lfo.name, name);
            assert!(lfo.routes.is_empty());
        }
    }

    #[test]
    fn filter_env_to_cutoff_gives_a_decaying_centroid() {
        // The "done when" pluck: short envelope decay, sustain 0, some resonance.
        let mut dev = synth();
        set_spec(
            &mut dev,
            &[(
                0,
                ModulatorKind::Adsr,
                &[
                    (ENV_ATTACK, 0.005),
                    (ENV_DECAY, 0.15),
                    (ENV_SUSTAIN, 0.0),
                    (ENV_RELEASE, 0.3),
                ],
            )],
            &[(0, CUTOFF, 0.6)],
        );
        set_real(&mut dev, CUTOFF, 400.0);
        set_real(&mut dev, RESONANCE, 0.5);
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
    fn default_modulators_through_the_wrapper_sweep_the_filter() {
        // The "done when" path: a PolySynth whose instance text (as Godot would create it) is
        // installed on the wrapper, driven exactly like the app drives it.
        use crate::audio::devices::DevicePath;
        use crate::audio::modulation::wrap_at_path;

        let defaults = PolySynthDevice::new(SR).default_modulators();
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![Box::new(PolySynthDevice::new(SR))];
        devices[0].prepare(SR, BLOCK);
        wrap_at_path(&mut devices, &DevicePath::root(0), SR).unwrap();
        {
            let m = devices[0].as_modulated_mut().unwrap();
            for (i, d) in defaults.iter().enumerate() {
                let id = i as u8;
                m.add_modulator(id, d.kind).unwrap();
                for &(param_id, norm) in &d.params {
                    m.set_modulator_param(id, param_id, norm).unwrap();
                }
                for (target, amount) in &d.routes {
                    m.set_modulator_route(id, target, *amount).unwrap();
                }
            }
        }
        devices[0].set_parameter(
            CUTOFF,
            real_to_norm(400.0, CUTOFF_MIN, CUTOFF_MAX, true, 1.0),
        );
        devices[0].set_parameter(RESONANCE, 0.5);
        devices[0].send_midi_event(48, 110, true, 0);

        let mut out = vec![0.0; BLOCK * 2];
        let mut samples = Vec::new();
        for _ in 0..80 {
            devices[0].process_block(&[], &mut out, BLOCK);
            samples.extend_from_slice(&out);
        }
        let mono = left(&samples);
        let window = 2048;
        let early = centroid(&mono[512..512 + window]);
        let middle = centroid(&mono[6_000..6_000 + window]);
        let late = centroid(&mono[16_000..16_000 + window]);
        assert!(
            early > middle * 1.3 && middle > late,
            "centroid should fall: {early:.0} → {middle:.0} → {late:.0} Hz"
        );
    }

    #[test]
    fn cutoff_and_filter_type_shape_the_sound() {
        let brightness = |cutoff: f32, filter_type: f32| {
            let mut dev = synth();
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
        // The appended types: LP 6 (index 4) rolls off more gently than LP 12 (index 0),
        // and BP 6 (index 5) keeps the band around the cutoff.

        assert!(
            brightness(300.0, 4.0) > brightness(300.0, 0.0),
            "LP 6 brighter than LP 12 at a low cutoff"
        );
        let bp6 = brightness(1_000.0, 5.0);
        assert!(bp6 > 0.0 && bp6.is_finite(), "BP 6 renders: {bp6}");
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

        // Every kind into many float parameters at ±1 still renders finite, bounded audio.
        for sr in [44_100.0, 96_000.0, 192_000.0] {
            let mut dev = PolySynthDevice::new(sr);
            dev.prepare(sr, BLOCK);
            let floats: Vec<ParamId> = dev
                .parameters()
                .into_iter()
                .filter(|p| p.param_type == ParamType::Float)
                .map(|p| p.id)
                .collect();
            let mut spec = VoiceModSpec::empty();
            for kind in [
                ModulatorKind::Lfo,
                ModulatorKind::Adsr,
                ModulatorKind::Ad,
                ModulatorKind::Velocity,
                ModulatorKind::Keytrack,
                ModulatorKind::Random,
            ] {
                let slot = kind.index();
                spec.kinds[slot] = Some(kind);
                spec.params[slot] = mod_params(kind, &[]);
            }
            // LFO at 40 Hz, S&H, so it steps through values.
            spec.params[0] = mod_params(ModulatorKind::Lfo, &[(LFO_RATE, 40.0), (LFO_SHAPE, 4.0)]);
            let slots = [0usize, 1, 2, 3, 4, 5];
            'outer: for (i, &slot) in slots.iter().enumerate() {
                for (j, &id) in floats.iter().enumerate() {
                    if spec.route_len == crate::audio::modulation::MAX_ROUTES {
                        break 'outer;
                    }
                    if (i + j) % 3 == 0 {
                        let amount = if (i + j) % 2 == 0 { 1.0 } else { -1.0 };
                        spec.routes[spec.route_len] = VoiceRoute {
                            mod_slot: slot,
                            param_id: id,
                            amount,
                        };
                        spec.route_len += 1;
                    }
                }
            }
            assert!(spec.route_len > 0);
            dev.set_voice_modulation(&spec);
            set_real(&mut dev, RESONANCE, 1.0);
            for note in [24, 60, 96, 127] {
                dev.send_midi_event(note, 127, true, 0);
            }
            let out = render(&mut dev, 40);
            assert!(out.iter().all(|s| s.is_finite()), "non-finite at {sr}");
            assert!(peak(&out) < 20.0, "peak {} at {sr}", peak(&out));
        }
    }

    #[test]
    fn lfo_sync_period_is_the_beat_length_at_120_bpm() {
        let mut dev = synth();
        dev.set_transport(&crate::audio::transport::Transport {
            tempo: 120.0,
            ..Default::default()
        });
        set_spec(
            &mut dev,
            &[(
                0,
                ModulatorKind::Lfo,
                &[(LFO_SYNC, index_of("1/4") as f32), (LFO_RETRIGGER, 1.0)],
            )],
            &[(0, CUTOFF, 0.5)],
        );
        dev.send_midi_event(60, 100, true, 0);
        // A quarter note at 120 BPM is 0.5 s: the retriggered LFO is back at phase 0 then,
        // and half-way at 0.25 s.
        let quarter = (SR * 0.5) as usize;
        let mut out = vec![0.0; 2 * 200];
        for _ in 0..quarter / 400 {
            dev.process_block(&[], &mut out, 200);
        }
        let phase = lfo_phase(&dev, 0, 0);
        assert!((phase - 0.5).abs() < 1e-6, "{phase}");
        for _ in 0..quarter / 400 {
            dev.process_block(&[], &mut out, 200);
        }
        let phase = lfo_phase(&dev, 0, 0);
        assert!(
            phase < 1e-6 || phase > 1.0 - 1e-6,
            "phase {phase} after one beat"
        );
    }

    #[test]
    fn free_lfo_keeps_voices_in_phase_and_note_retrigger_resets() {
        let free = |retrigger: f32| {
            let mut dev = synth();
            set_spec(
                &mut dev,
                &[(
                    0,
                    ModulatorKind::Lfo,
                    &[(LFO_RATE, 5.0), (LFO_RETRIGGER, retrigger)],
                )],
                &[(0, CUTOFF, 0.5)],
            );
            dev.send_midi_event(60, 100, true, 0);
            render(&mut dev, 7);
            dev.send_midi_event(64, 100, true, 0);
            render(&mut dev, 3);
            dev.voices
                .iter()
                .enumerate()
                .filter(|(_, v)| v.active)
                .map(|(i, _)| lfo_phase(&dev, i, 0))
                .collect::<Vec<f64>>()
        };

        // Free: the second voice joins the first's phase.
        let phases = free(0.0);
        assert_eq!(phases.len(), 2);
        assert!((phases[0] - phases[1]).abs() < 1e-3, "{phases:?}");

        // Retrigger Note: each voice starts its own phase.
        let phases = free(1.0);
        assert!((phases[0] - phases[1]).abs() > 0.1, "{phases:?}");
    }

    #[test]
    fn voices_started_apart_hold_different_envelope_values() {
        // Each voice runs its own modulator state: a note started 100 ms later is at a
        // different point of the filter-envelope decay.
        let mut dev = synth();
        set_spec(
            &mut dev,
            &[(
                0,
                ModulatorKind::Adsr,
                &[
                    (ENV_ATTACK, 0.002),
                    (ENV_DECAY, 0.4),
                    (ENV_SUSTAIN, 0.0),
                    (ENV_RELEASE, 0.3),
                ],
            )],
            &[(0, CUTOFF, 0.35)],
        );
        dev.send_midi_event(60, 100, true, 0);
        render(&mut dev, 18); // ~96 ms
        dev.send_midi_event(64, 100, true, 0);
        render(&mut dev, 1);

        let values: Vec<f32> = dev
            .voices
            .iter()
            .filter(|v| v.active && !v.is_fading())
            .map(|v| v.mods[0].as_ref().expect("filter env").value())
            .collect();
        assert_eq!(values.len(), 2, "{values:?}");
        assert!(
            (values[0] - values[1]).abs() > 0.05,
            "both voices share one envelope: {values:?}"
        );
    }

    #[test]
    fn retrigger_restarts_note_lfo_in_poly_and_mono() {
        // Re-triggering the same note (Poly) or a new note while one sounds (Mono) must restart
        // a Retrigger = Note LFO, just like a fresh voice does.
        for (mode, label) in [(0.0, "poly"), (1.0, "mono")] {
            let mut dev = synth();
            set_real(&mut dev, VOICE_MODE, mode);
            set_spec(
                &mut dev,
                &[(
                    0,
                    ModulatorKind::Lfo,
                    &[(LFO_RATE, 5.0), (LFO_RETRIGGER, 1.0)],
                )],
                &[(0, CUTOFF, 0.5)],
            );
            dev.send_midi_event(60, 100, true, 0);
            render(&mut dev, 4);
            let before = lfo_phase(&dev, 0, 0);
            assert!(before > 0.05, "{label}: LFO should be running: {before}");

            dev.send_midi_event(60, 100, true, 0);
            render(&mut dev, 1);
            let after = lfo_phase(&dev, 0, 0);
            assert!(
                after < 0.05,
                "{label}: retrigger should restart the LFO, {before} -> {after}"
            );
        }
    }

    #[test]
    fn lfo_to_pitch_wobbles_without_steps() {
        // LFO 1 → Osc 1 Fine: a sine's instantaneous frequency must move smoothly (pitch is
        // interpolated across control blocks, not stepped).
        let mut dev = synth();
        set_real(&mut dev, CUTOFF, 20_000.0);
        set_real(&mut dev, OSC1 + WAVE, 0.0); // sine
        set_spec(
            &mut dev,
            &[(
                0,
                ModulatorKind::Lfo,
                &[(LFO_RATE, 6.0), (LFO_RETRIGGER, 1.0)],
            )],
            &[(0, OSC1 + FINE, 0.5)], // ±100 cents
        );
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

    #[test]
    fn fm_index_changes_the_render_and_ratio_changes_it_further() {
        let play = |ratio: f32, index: f32| {
            let mut dev = synth();
            set_real(&mut dev, FM_RATIO, ratio);
            set_real(&mut dev, FM_INDEX, index);
            dev.send_midi_event(60, 100, true, 0);
            render(&mut dev, 8)
        };
        let off = play(1.0, 0.0);
        let fm = play(1.0, 4.0);
        let other_ratio = play(2.0, 4.0);
        assert!(
            peak(&off) > 0.01 && peak(&fm) > 0.01,
            "both should be audible"
        );
        let diff = |a: &[f32], b: &[f32]| a.iter().zip(b).map(|(x, y)| (x - y).abs()).sum::<f32>();
        assert!(diff(&off, &fm) > 0.1, "FM index should change the render");
        assert!(
            diff(&fm, &other_ratio) > 0.1,
            "FM ratio should change the render"
        );
    }

    #[test]
    fn fm_index_zero_matches_fm_off() {
        let play = |fm_on: bool| {
            let mut dev = synth();
            set_real(&mut dev, FM_RATIO, 3.0);
            if fm_on {
                set_real(&mut dev, FM_INDEX, 0.0);
            }
            dev.send_midi_event(60, 100, true, 0);
            render(&mut dev, 8)
        };
        let (off, zero) = (play(false), play(true));
        // A lone unison voice is deterministic (phase starts at 0), so the renders are identical.
        assert_eq!(off, zero);
    }
}

#[cfg(test)]
mod bench {
    use super::params::*;
    use super::*;
    use crate::audio::modulation::voice::VoiceRoute;

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
        // Eight routes, touching every interpolated kind of destination (cutoff, pitch, level)
        // and some block-constant ones. Routes that switch on extra DSP (noise, drive) are left
        // out; together they add about 0.5 % more.
        let mut spec = VoiceModSpec::empty();
        for (slot, kind) in [
            (0, ModulatorKind::Lfo),
            (1, ModulatorKind::Lfo),
            (2, ModulatorKind::Adsr),
            (3, ModulatorKind::Velocity),
            (4, ModulatorKind::Keytrack),
        ] {
            spec.kinds[slot] = Some(kind);
            spec.params[slot] = *ModulatorState::new(kind, SR).params();
        }
        for (mod_slot, param_id) in [
            (0, CUTOFF),
            (1, OSC1 + FINE),
            (1, OSC2 + FINE),
            (3, OSC1 + LEVEL),
            (0, OSC2 + LEVEL),
            (2, OSC2 + PULSE_WIDTH),
            (4, RESONANCE),
            (4, CUTOFF),
        ] {
            spec.routes[spec.route_len] = VoiceRoute {
                mod_slot,
                param_id,
                amount: 0.3,
            };
            spec.route_len += 1;
        }
        assert_eq!(spec.route_len, 8);
        dev.set_voice_modulation(&spec);
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
