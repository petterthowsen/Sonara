//! One modulator instance's runtime state.
//!
//! [`ModulatorState`] is a `Copy`, fixed-size block: the kind, its [`ModParams`] and the DSP
//! state that kind needs (LFO phase and sample-and-hold, envelope stage and level, the held-note
//! count, the last note and velocity, and the current random value). It is evaluated once per
//! control step by [`advance`](ModulatorState::advance), which returns the value at the end of
//! the step and never allocates.
//!
//! Note-driven modulators follow the device's note stream: envelopes retrigger on every note-on
//! and release when the last note is released (an `ad` is one-shot and ignores note-off), while
//! velocity and keytrack take the last note. LFO phase comes from the transport when synced, so
//! it stays locked across seeks.

use super::envelope::AdsrEnvelope;
use super::kinds::{
    ModParams, ModulatorKind, CC_NUMBER, CC_SMOOTH, ENV_ATTACK, ENV_DECAY, ENV_RELEASE,
    ENV_SUSTAIN, LFO_PHASE, LFO_RATE, LFO_RETRIGGER, LFO_SHAPE, LFO_SYNC, MAX_KIND_PARAMS,
};
use super::lfo::{Lfo, LfoShape};
use crate::audio::devices::ParamId;
use crate::audio::dsp::tempo_sync::sync_beats;
use crate::audio::midi_types::DEFAULT_RELEASE;
use crate::audio::transport::Transport;

/// The keytrack source reaches ±1 this many semitones either side of C3 (60), as in PolySynth.
const KEYTRACK_RANGE: f32 = 60.0;
/// Sample rate used until `prepare` supplies the real one (RT-safe default).
const DEFAULT_SAMPLE_RATE: f32 = 48_000.0;

/// Smallest modulator-parameter offset change worth applying (below it the parameter would
/// just be re-applied for nothing). Shared with the wrapper's offset bookkeeping.
pub const OFFSET_EPSILON: f32 = 1e-7;

#[derive(Clone, Copy, Debug)]
pub struct ModulatorState {
    kind: ModulatorKind,
    params: ModParams,
    /// Offsets other modulators push onto this one's parameters, indexed by the kind's
    /// parameter-table slot (spec 033 mod→mod, one control step of delay).
    mod_offset: [f32; MAX_KIND_PARAMS],
    sample_rate: f32,
    /// LFO phase and sample-and-hold value.
    lfo: Lfo,
    /// Whole cycle count of a synced LFO at the last step, so S&H draws on each new cycle.
    synced_cycle: f64,
    /// Envelope stage and level (`adsr` and `ad`).
    env: AdsrEnvelope,
    /// Notes currently held, so an envelope releases on the last note-off.
    held: u16,
    last_note: f32,
    velocity: f32,
    /// The latched release velocity (`release` kind).
    release: f32,
    random: f32,
    /// xorshift state; never zero.
    rng: u32,
    /// Last latched normalized CC value for the configured controller (`cc` kind).
    cc_target: f32,
    /// Smoothed CC output (`cc` kind).
    cc_value: f32,
}

impl ModulatorState {
    pub fn new(kind: ModulatorKind, sample_rate: f32) -> Self {
        let mut state = Self {
            kind,
            params: ModParams::new(kind),
            mod_offset: [0.0; MAX_KIND_PARAMS],
            sample_rate: sample_rate.max(1.0),
            lfo: Lfo::default(),
            synced_cycle: f64::NAN,
            env: AdsrEnvelope::new(sample_rate),
            held: 0,
            last_note: 60.0,
            velocity: 0.0,
            release: DEFAULT_RELEASE,
            random: 0.0,
            rng: (kind.index() as u32 + 1).wrapping_mul(0x9E37_79B9) | 1,
            cc_target: 0.0,
            cc_value: 0.0,
        };
        state.apply_params();
        state
    }

    pub fn kind(&self) -> ModulatorKind {
        self.kind
    }

    pub fn params(&self) -> &ModParams {
        &self.params
    }

    pub fn get_param(&self, id: ParamId) -> Option<f32> {
        self.params.get(id)
    }

    /// The effective normalized value of `id` for evaluation: the base plus the offset other
    /// modulators pushed in, clamped to 0..1 (`get_param` still reports the base).
    fn real_eff(&self, id: ParamId) -> Option<f32> {
        let slot = self.params.table().slot(id)?;
        let norm = (self.params.get(id)? + self.mod_offset[slot]).clamp(0.0, 1.0);
        Some(self.params.table().specs[slot].to_real(norm))
    }

    /// Push a mod→mod offset (normalized units) onto `param_id`. The offset is stored per
    /// table slot; `apply_params` re-runs (envelope times are cached) only when the offset
    /// actually moved, so a held offset costs nothing per control step. Real-time safe.
    pub fn set_mod_offset(&mut self, param_id: ParamId, offset: f32) {
        let Some(slot) = self.params.table().slot(param_id) else {
            return;
        };
        if (self.mod_offset[slot] - offset).abs() <= OFFSET_EPSILON {
            return;
        }
        self.mod_offset[slot] = offset;
        self.apply_params();
    }

    /// Store a normalized parameter value and apply it to the runtime (envelope times). Returns
    /// the slot and real value, as `ParamValues::set` does, or None for an unknown ID.
    pub fn set_param(&mut self, id: ParamId, norm: f32) -> Option<(usize, f32)> {
        let applied = self.params.set(id, norm)?;
        self.apply_params();
        Some(applied)
    }

    /// Rebuild the envelope for a new sample rate. Off the audio thread only.
    pub fn prepare(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(1.0);
        self.env = AdsrEnvelope::new(self.sample_rate);
        self.apply_params();
    }

    /// Push the kind's parameters into the runtime state that caches them.
    fn apply_params(&mut self) {
        if !self.kind.is_envelope() {
            return;
        }
        let attack = self.real_eff(ENV_ATTACK).unwrap_or(0.005);
        let decay = self.real_eff(ENV_DECAY).unwrap_or(0.3);
        let (sustain, release) = if self.kind == ModulatorKind::Adsr {
            (
                self.real_eff(ENV_SUSTAIN).unwrap_or(0.5),
                self.real_eff(ENV_RELEASE).unwrap_or(0.3),
            )
        } else {
            // `ad` is one-shot: sustain 0 so decay reaches silence, and note-off is ignored.
            (0.0, 0.3)
        };
        self.env.set_adsr(attack, decay, sustain, release);
    }

    /// A note-on: retrigger the kind's note-driven state. The held count drives the mono path's
    /// "release on the last note-off" rule; a per-voice instance uses
    /// [`gate_voice_on`](Self::gate_voice_on) instead.
    pub fn note_on(&mut self, note: u8, velocity: f32, _frame: usize) {
        self.held = self.held.saturating_add(1);
        self.trigger(note, velocity);
    }

    fn trigger(&mut self, note: u8, velocity: f32) {
        match self.kind {
            ModulatorKind::Lfo => {
                if self.params.real(LFO_RETRIGGER).unwrap_or(0.0) >= 0.5 {
                    let phase = self.params.real(LFO_PHASE).unwrap_or(0.0) / 360.0;
                    self.lfo.phase = phase.rem_euclid(1.0) as f64;
                    let held = self.next_noise();
                    self.lfo.set_held(held);
                }
            }
            ModulatorKind::Adsr | ModulatorKind::Ad => self.env.gate_on(),
            ModulatorKind::Velocity => self.velocity = velocity,
            ModulatorKind::Keytrack => self.last_note = note as f32,
            ModulatorKind::Random => self.random = self.next_noise(),
            ModulatorKind::Release => self.release = DEFAULT_RELEASE,
            // Channel-level: the note stream is irrelevant (see `set_cc`).
            ModulatorKind::MidiCc => {}
        }
    }

    /// A note-off: an envelope releases once the last held note is released, and a `release`
    /// modulator latches this note-off's release velocity.
    pub fn note_off(&mut self, _note: u8, release: f32, _frame: usize) {
        if self.kind == ModulatorKind::Release {
            self.release = release;
            return;
        }
        if !self.kind.is_envelope() {
            return;
        }
        self.held = self.held.saturating_sub(1);
        if self.held == 0 && self.kind == ModulatorKind::Adsr {
            self.env.gate_off();
        }
    }

    /// Per-voice note-on: this instance follows one voice, so exactly one note is held. Two
    /// successive calls (a poly same-note repeat, a mono retrigger) restart the envelopes
    /// without inflating the held count, so a single note-off still releases.
    pub fn gate_voice_on(&mut self, note: u8, velocity: f32) {
        self.held = 1;
        self.trigger(note, velocity);
    }

    /// Per-voice note-off: gate the envelope off (an `ad` ignores it), as
    /// [`gate_voice_on`](Self::gate_voice_on) is the per-voice companion to `note_on`.
    pub fn gate_voice_off(&mut self, release: f32) {
        self.held = 0;
        match self.kind {
            ModulatorKind::Adsr => self.env.gate_off(),
            ModulatorKind::Release => self.release = release,
            _ => {}
        }
    }

    /// Follow a new note without retriggering (a legato slide): velocity and keytrack update,
    /// envelopes and LFOs are left running.
    pub fn update_note(&mut self, note: u8, velocity: f32) {
        match self.kind {
            ModulatorKind::Velocity => self.velocity = velocity,
            ModulatorKind::Keytrack => self.last_note = note as f32,
            _ => {}
        }
    }

    /// Latch a controller value (normalized 0–1) into a `cc` modulator whose `CC_NUMBER` is
    /// `cc`. Other kinds (and other controllers) ignore it. With smoothing off (`CC_SMOOTH` 0)
    /// the change lands on this control step; otherwise the one-pole in `advance` catches up.
    /// Audio-thread safe: fixed-capacity, no locks.
    pub fn set_cc(&mut self, cc: u8, unit_value: f32) {
        if self.kind != ModulatorKind::MidiCc {
            return;
        }
        let configured = self.params.real(CC_NUMBER).unwrap_or(0.0).round() as u8;
        if configured != cc {
            return;
        }
        self.cc_target = unit_value.clamp(0.0, 1.0);
        if self.params.real(CC_SMOOTH).unwrap_or(0.0) <= 0.0 {
            self.cc_value = self.cc_target;
        }
    }

    /// The LFO phase (0 for a non-LFO kind). Used to seed a voice's free-running LFO.
    pub fn lfo_phase(&self) -> f64 {
        self.lfo.phase
    }

    /// Seed a free-running LFO's phase and draw a fresh sample-and-hold value, so every voice
    /// that joins has the same phase but its own S&H. Other kinds are left alone.
    pub fn seed_lfo_phase(&mut self, phase: f64) {
        if self.kind != ModulatorKind::Lfo {
            return;
        }
        self.lfo.phase = phase.rem_euclid(1.0);
        let held = self.next_noise();
        self.lfo.set_held(held);
    }

    /// Advance `frames` samples and return the value at the end of the step.
    pub fn advance(&mut self, frames: usize, transport: &Transport) -> f32 {
        match self.kind {
            ModulatorKind::Lfo => {
                let shape = LfoShape::from_index(self.real_eff(LFO_SHAPE).unwrap_or(0.0) as usize);
                let sync = sync_beats(self.real_eff(LFO_SYNC).unwrap_or(0.0) as usize);
                match sync {
                    Some(beats) if transport.playing => {
                        // `transport` is the position at the step's start; the value is the one
                        // at its end.
                        let seconds = frames as f64 / self.sample_rate as f64;
                        let pos = transport.song_pos_beats + seconds * transport.tempo / 60.0;
                        let cycle = pos / beats;
                        let phase = cycle.rem_euclid(1.0);
                        // A new cycle (or a seek) draws a new sample-and-hold value.
                        if cycle.floor() != self.synced_cycle {
                            self.synced_cycle = cycle.floor();
                            let held = self.next_noise();
                            self.lfo.set_held(held);
                        }
                        self.lfo.phase = phase;
                    }
                    _ => {
                        let hz = match sync {
                            Some(beats) => transport.tempo / 60.0 / beats,
                            None => self.real_eff(LFO_RATE).unwrap_or(2.0) as f64,
                        };
                        if self
                            .lfo
                            .advance(hz * frames as f64 / self.sample_rate as f64)
                        {
                            let held = self.next_noise();
                            self.lfo.set_held(held);
                        }
                    }
                }
                self.lfo.value(shape)
            }
            ModulatorKind::Adsr | ModulatorKind::Ad => {
                for _ in 0..frames {
                    self.env.process_sample();
                }
                self.env.value()
            }
            ModulatorKind::Velocity => self.velocity,
            ModulatorKind::Keytrack => self.keytrack(),
            ModulatorKind::Random => self.random,
            ModulatorKind::Release => self.release,
            ModulatorKind::MidiCc => {
                // One-pole lag toward the latched target over this step; 0 snaps.
                let lag = self.real_eff(CC_SMOOTH).unwrap_or(0.0);
                if lag > 0.0 {
                    let alpha = 1.0 - (-(frames as f32) / (lag * self.sample_rate)).exp();
                    self.cc_value += (self.cc_target - self.cc_value) * alpha;
                }
                self.cc_value
            }
        }
    }

    /// The current value, without advancing.
    pub fn value(&self) -> f32 {
        match self.kind {
            ModulatorKind::Lfo => {
                let shape = LfoShape::from_index(self.real_eff(LFO_SHAPE).unwrap_or(0.0) as usize);
                self.lfo.value(shape)
            }
            ModulatorKind::Adsr | ModulatorKind::Ad => self.env.value(),
            ModulatorKind::Velocity => self.velocity,
            ModulatorKind::Keytrack => self.keytrack(),
            ModulatorKind::Random => self.random,
            ModulatorKind::Release => self.release,
            ModulatorKind::MidiCc => self.cc_value,
        }
    }

    fn keytrack(&self) -> f32 {
        ((self.last_note - 60.0) / KEYTRACK_RANGE).clamp(-1.0, 1.0)
    }

    /// The per-kind display state for the `modulation` data stream: `(stage, x, value)` —
    /// an LFO reports its phase and value, an envelope its stage (0 idle, 1 attack, 2 decay,
    /// 3 sustain, 4 release) and level, every other kind just its value. No new state: it is
    /// read from what evaluation already maintains.
    pub fn display_state(&self) -> (u8, f32, f32) {
        match self.kind {
            ModulatorKind::Lfo => {
                let shape = LfoShape::from_index(self.real_eff(LFO_SHAPE).unwrap_or(0.0) as usize);
                (0, self.lfo.phase as f32, self.lfo.value(shape))
            }
            ModulatorKind::Adsr | ModulatorKind::Ad => {
                (self.env.state() as u8, 0.0, self.env.value())
            }
            _ => (0, 0.0, self.value()),
        }
    }

    /// Back to a fresh state (no notes held, envelopes idle, LFO at phase 0).
    pub fn reset(&mut self) {
        self.held = 0;
        self.last_note = 60.0;
        self.velocity = 0.0;
        self.release = DEFAULT_RELEASE;
        self.random = 0.0;
        self.lfo = Lfo::default();
        self.synced_cycle = f64::NAN;
        self.env.reset();
        self.mod_offset = [0.0; MAX_KIND_PARAMS];
        self.cc_target = 0.0;
        self.cc_value = 0.0;
    }

    #[inline]
    fn next_random(&mut self) -> u32 {
        let mut x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        x
    }

    /// Uniform in −1..1.
    #[inline]
    fn next_noise(&mut self) -> f32 {
        (self.next_random() as i32) as f32 * (1.0 / 2_147_483_648.0)
    }
}

impl Default for ModulatorState {
    fn default() -> Self {
        Self::new(ModulatorKind::Lfo, DEFAULT_SAMPLE_RATE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::tempo_sync::index_of;
    use crate::audio::modulation::envelope::AdsrState;

    const SR: f32 = 48_000.0;

    fn transport(tempo: f64, playing: bool, song_pos_beats: f64) -> Transport {
        Transport {
            tempo,
            playing,
            song_pos_beats,
            ..Default::default()
        }
    }

    /// Set a parameter by its real value (like the tests elsewhere use `set_real`).
    fn set_real(state: &mut ModulatorState, id: ParamId, real: f32) {
        let spec = state.params().table().spec(id).unwrap();
        state.set_param(id, spec.to_norm(real));
    }

    fn samples_in_state(state: &mut ModulatorState, target: AdsrState) -> usize {
        let t = transport(120.0, false, 0.0);
        let mut n = 0;
        while state.env.state() == target && n < 10_000_000 {
            state.advance(1, &t);
            n += 1;
        }
        n
    }

    fn assert_within_5_percent(samples: usize, seconds: f32) {
        let expected = seconds * SR;
        let err = (samples as f32 - expected).abs() / expected;
        assert!(
            err <= 0.05,
            "{samples} samples vs {expected} expected ({err:.3})"
        );
    }

    #[test]
    fn synced_lfo_period_is_the_beat_length_at_120_bpm() {
        let mut state = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut state, LFO_SYNC, index_of("1/4") as f32);
        let t = transport(120.0, false, 0.0);

        let quarter = (SR * 0.5) as usize;
        state.advance(quarter / 2, &t);
        assert!((state.lfo.phase - 0.5).abs() < 1e-6, "{}", state.lfo.phase);
        state.advance(quarter / 2, &t);
        let phase = state.lfo.phase;
        assert!(
            phase < 1e-6 || phase > 1.0 - 1e-6,
            "phase {phase} after one beat"
        );

        // Dotted and triplet divisions scale the rate.
        let mut state = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut state, LFO_SYNC, index_of("1/4.") as f32);
        state.advance((SR * 0.75 * 0.5) as usize, &t); // half a dotted-quarter
        assert!((state.lfo.phase - 0.5).abs() < 1e-6, "{}", state.lfo.phase);
    }

    #[test]
    fn a_synced_lfo_while_playing_reads_the_end_of_the_step_and_redraws_sample_and_hold() {
        let mut state = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut state, LFO_SYNC, index_of("1/4") as f32);
        set_real(&mut state, LFO_SHAPE, 4.0); // S&H

        // A quarter of a beat in from beat 0.
        state.advance((SR * 0.125) as usize, &transport(120.0, true, 0.0));
        assert!((state.lfo.phase - 0.25).abs() < 1e-6, "{}", state.lfo.phase);
        let first = state.value();

        // Same cycle: the held value stays; the next beat draws a new one.
        state.advance(64, &transport(120.0, true, 0.5));
        assert_eq!(state.value(), first, "redrew within a cycle");
        state.advance(64, &transport(120.0, true, 1.0));
        assert_ne!(state.value(), first, "no new value on the next cycle");
    }

    #[test]
    fn free_vs_note_retrigger() {
        // Retrigger Note: a note-on restarts the phase, at the Phase parameter's offset.
        let mut note = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut note, LFO_RETRIGGER, 1.0); // Note
        set_real(&mut note, LFO_PHASE, 90.0); // 0.25 cycles
        let t = transport(120.0, false, 0.0);
        note.advance(4_800, &t); // 0.1 s at 2 Hz = 0.2 cycles
        assert!(note.lfo.phase > 0.1, "{}", note.lfo.phase);
        note.note_on(60, 100.0 / 127.0, 0);
        assert!((note.lfo.phase - 0.25).abs() < 1e-9, "{}", note.lfo.phase);

        // Retrigger Free: a note-on leaves the phase running.
        let mut free = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut free, LFO_RETRIGGER, 0.0); // Free
        free.advance(4_800, &t);
        let before = free.lfo.phase;
        assert!(before > 0.1, "{before}");
        free.note_on(60, 100.0 / 127.0, 0);
        assert_eq!(free.lfo.phase, before);
    }

    #[test]
    fn adsr_and_ad_stage_times_within_5_percent() {
        for &time in &[0.005, 0.02, 0.3, 2.0] {
            let mut adsr = ModulatorState::new(ModulatorKind::Adsr, SR);
            set_real(&mut adsr, ENV_ATTACK, time);
            set_real(&mut adsr, ENV_DECAY, time);
            set_real(&mut adsr, ENV_SUSTAIN, 0.4);
            set_real(&mut adsr, ENV_RELEASE, time);
            adsr.note_on(60, 100.0 / 127.0, 0);
            assert_within_5_percent(samples_in_state(&mut adsr, AdsrState::Attack), time);
            assert_within_5_percent(samples_in_state(&mut adsr, AdsrState::Decay), time);
            assert!((adsr.value() - 0.4).abs() < 1e-6);
            adsr.note_off(60, DEFAULT_RELEASE, 0);
            assert_within_5_percent(samples_in_state(&mut adsr, AdsrState::Release), time);
            assert!(!adsr.env.is_active());

            let mut ad = ModulatorState::new(ModulatorKind::Ad, SR);
            set_real(&mut ad, ENV_ATTACK, time);
            set_real(&mut ad, ENV_DECAY, time);
            ad.note_on(60, 100.0 / 127.0, 0);
            assert_within_5_percent(samples_in_state(&mut ad, AdsrState::Attack), time);
            assert_within_5_percent(samples_in_state(&mut ad, AdsrState::Decay), time);
            assert_eq!(ad.value(), 0.0, "ad decays to silence");
        }
    }

    #[test]
    fn ad_ignores_note_off_but_adsr_releases_on_the_last_note() {
        // ADSR: two notes held, one released — still sustaining; the last release starts Release.
        let mut adsr = ModulatorState::new(ModulatorKind::Adsr, SR);
        set_real(&mut adsr, ENV_ATTACK, 0.001);
        set_real(&mut adsr, ENV_DECAY, 0.01);
        set_real(&mut adsr, ENV_SUSTAIN, 0.5);
        adsr.note_on(60, 100.0 / 127.0, 0);
        adsr.note_on(64, 100.0 / 127.0, 0);
        let t = transport(120.0, false, 0.0);
        adsr.advance(2_000, &t); // past attack + decay into sustain
        adsr.note_off(60, DEFAULT_RELEASE, 0);
        assert_eq!(adsr.env.state(), AdsrState::Sustain, "one note still held");
        adsr.note_off(64, DEFAULT_RELEASE, 0);
        assert_eq!(adsr.env.state(), AdsrState::Release);

        // A note-on while an envelope is running retriggers the attack.
        adsr.note_on(67, 100.0 / 127.0, 0);
        assert_eq!(adsr.env.state(), AdsrState::Attack);

        // AD is one-shot: note-off never releases it.
        let mut ad = ModulatorState::new(ModulatorKind::Ad, SR);
        set_real(&mut ad, ENV_ATTACK, 0.01);
        set_real(&mut ad, ENV_DECAY, 0.2);
        ad.note_on(60, 100.0 / 127.0, 0);
        ad.advance(480, &t); // past the attack
        ad.note_off(60, DEFAULT_RELEASE, 0);
        assert_ne!(ad.env.state(), AdsrState::Release);
    }

    #[test]
    fn release_modulator_latches_on_note_off() {
        let t = transport(120.0, false, 0.0);

        // Per voice: the default while held, the note-off's release after it.
        let mut voice = ModulatorState::new(ModulatorKind::Release, SR);
        voice.gate_voice_on(60, 0.8);
        assert_eq!(voice.advance(64, &t), DEFAULT_RELEASE);
        voice.gate_voice_off(0.9);
        assert_eq!(voice.advance(64, &t), 0.9);
        // The next note starts from the default again.
        voice.gate_voice_on(62, 0.8);
        assert_eq!(voice.value(), DEFAULT_RELEASE);

        // Mono: every note-off latches its release.
        let mut mono = ModulatorState::new(ModulatorKind::Release, SR);
        mono.note_on(60, 0.8, 0);
        assert_eq!(mono.advance(64, &t), DEFAULT_RELEASE);
        mono.note_off(60, 0.2, 0);
        assert_eq!(mono.advance(64, &t), 0.2);
        mono.note_on(64, 0.8, 0);
        assert_eq!(mono.value(), DEFAULT_RELEASE);
        mono.reset();
        assert_eq!(mono.value(), DEFAULT_RELEASE);
    }

    #[test]
    fn keytrack_and_velocity_mapping() {
        let t = transport(120.0, false, 0.0);

        let mut key = ModulatorState::new(ModulatorKind::Keytrack, SR);
        key.note_on(60, 100.0 / 127.0, 0);
        assert_eq!(key.advance(64, &t), 0.0, "C3 is the pivot");
        key.note_on(120, 100.0 / 127.0, 0);
        assert_eq!(key.advance(64, &t), 1.0, "+60 semitones");
        key.note_on(0, 100.0 / 127.0, 0);
        assert_eq!(key.advance(64, &t), -1.0, "−60 semitones");

        let mut vel = ModulatorState::new(ModulatorKind::Velocity, SR);
        vel.note_on(60, 1.0, 0);
        assert_eq!(vel.advance(64, &t), 1.0);
        vel.note_on(60, 64.0 / 127.0, 0);
        assert!((vel.advance(64, &t) - 64.0 / 127.0).abs() < 1e-6);

        let mut random = ModulatorState::new(ModulatorKind::Random, SR);
        random.note_on(60, 100.0 / 127.0, 0);
        let first = random.advance(64, &t);
        assert!((-1.0..=1.0).contains(&first));
        random.note_on(62, 100.0 / 127.0, 0);
        assert_ne!(random.advance(64, &t), first, "new value per note-on");
    }

    #[test]
    fn state_is_copy_and_bounded() {
        // `Copy` means no owned heap, and `advance` only touches these fields, so it cannot
        // allocate. `SizeCheck` bounds the per-device cost (8 modulators per instance).
        fn assert_copy<T: Copy>() {}
        assert_copy::<ModulatorState>();
        assert!(
            std::mem::size_of::<ModulatorState>() <= 256,
            "{} bytes",
            std::mem::size_of::<ModulatorState>()
        );
    }

    #[test]
    fn cc_latches_only_the_configured_controller_and_snaps_without_smoothing() {
        let t = transport(120.0, false, 0.0);
        let mut cc = ModulatorState::new(ModulatorKind::MidiCc, SR);
        set_real(&mut cc, CC_NUMBER, 7.0);
        cc.set_cc(1, 0.5);
        assert_eq!(cc.value(), 0.0, "wrong controller is ignored");

        cc.set_cc(7, 8192.0_f32 / 16383.0);
        assert!(cc.advance(64, &t) > 0.4, "snaps with smoothing off");
        cc.advance(64, &t);
        assert!((cc.value() - 8192.0 / 16383.0).abs() < 1e-6);

        // Other kinds ignore `set_cc`.
        let mut lfo = ModulatorState::new(ModulatorKind::Lfo, SR);
        lfo.set_cc(7, 1.0);
        assert_eq!(lfo.value(), 0.0);

        cc.reset();
        assert_eq!(cc.value(), 0.0, "reset zeroes the latched CC");
        // Note stream is irrelevant.
        cc.set_cc(7, 0.25);
        cc.note_on(60, 1.0, 0);
        cc.note_off(60, DEFAULT_RELEASE, 0);
        assert_eq!(cc.value(), 0.25, "note events left the latch alone");
    }

    #[test]
    fn cc_smoothing_converges_over_steps() {
        let t = transport(120.0, false, 0.0);
        let target = 8192.0_f32 / 16383.0;
        let mut cc = ModulatorState::new(ModulatorKind::MidiCc, SR);
        set_real(&mut cc, CC_NUMBER, 1.0);
        set_real(&mut cc, CC_SMOOTH, 0.05); // 50 ms
        cc.set_cc(1, target);

        let first = cc.advance(64, &t);
        assert!(
            first > 0.0 && first < target * 0.5,
            "first step moved part way: {first}"
        );
        let mut previous = first;
        for step in 1..400 {
            let value = cc.advance(64, &t);
            assert!(
                (value - target).abs() < (previous - target).abs(),
                "not converging at step {step}: {previous} -> {value}"
            );
            previous = value;
        }
        assert!((previous - target).abs() < 1e-3, "converged to {previous}");
    }

    #[test]
    fn display_state_reports_lfo_phase_env_stages_and_values() {
        let t = transport(120.0, false, 0.0);

        // An LFO reports its phase as x; a saw's value maps to it.
        let mut lfo = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut lfo, LFO_SHAPE, 2.0 / 5.0); // Saw
        assert_eq!(lfo.display_state().0, 0);
        let x0 = lfo.display_state().1;
        lfo.advance(12_000, &t); // 0.25 s at 2 Hz = half a cycle
        let (stage, x, value) = lfo.display_state();
        assert_eq!(stage, 0);
        let expected = (x0 + 0.5).fract();
        assert!(
            (x - expected).abs() < 0.01 || (x - expected + 1.0).abs() < 0.01,
            "x {x}, expected {expected}"
        );
        let saw = (x * 2.0 - 1.0).clamp(-1.0, 1.0);
        assert!((value - saw).abs() < 0.05, "saw value {value} at x {x}");

        // An envelope reports its stage and level; x stays 0.
        let mut adsr = ModulatorState::new(ModulatorKind::Adsr, SR);
        assert_eq!(adsr.display_state(), (0, 0.0, 0.0), "idle before a note");
        set_real(&mut adsr, ENV_ATTACK, 0.01);
        set_real(&mut adsr, ENV_DECAY, 0.01);
        set_real(&mut adsr, ENV_SUSTAIN, 0.5);
        set_real(&mut adsr, ENV_RELEASE, 0.01);
        adsr.note_on(60, 1.0, 0);
        adsr.advance(64, &t);
        let (stage, x, value) = adsr.display_state();
        assert_eq!((stage, x), (1, 0.0), "attack");
        assert!(value > 0.0);
        adsr.advance(SR as usize, &t);
        let (stage, x, value) = adsr.display_state();
        assert_eq!((stage, x), (3, 0.0), "sustain after attack + decay");
        assert!((value - 0.5).abs() < 1e-3);
        adsr.note_off(60, DEFAULT_RELEASE, 0);
        adsr.advance(64, &t);
        assert_eq!(adsr.display_state().0, 4, "release after the last note-off");

        // Everything else just reports its value.
        let mut vel = ModulatorState::new(ModulatorKind::Velocity, SR);
        vel.note_on(60, 0.75, 0);
        assert_eq!(vel.display_state(), (0, 0.0, 0.75));
    }

    #[test]
    fn mod_offset_changes_evaluation_but_not_the_base() {
        let t = transport(120.0, false, 0.0);

        // Same parameters produce the same value until an offset lands.
        let mut base = ModulatorState::new(ModulatorKind::Lfo, SR);
        let mut modded = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut modded, LFO_RATE, 2.0);
        base.advance(12_000, &t);
        modded.advance(12_000, &t);
        assert_eq!(modded.value(), base.value(), "same params, same value");

        modded.set_mod_offset(LFO_RATE, 0.5);
        base.advance(1_200, &t);
        modded.advance(1_200, &t);
        assert_ne!(modded.value(), base.value(), "the offset changed the rate");

        // get_param still reports the base.
        assert_eq!(modded.get_param(LFO_RATE), base.get_param(LFO_RATE));

        // The effective read is clamped to 0..1: a large negative offset pins the rate at
        // its minimum.
        modded.set_mod_offset(LFO_RATE, -5.0);
        let before = modded.lfo_phase();
        modded.advance(4_800, &t);
        let after = modded.lfo_phase();
        assert!(
            after - before < 0.01,
            "the rate was not clamped: {before} -> {after}"
        );
    }

    #[test]
    fn a_modulated_envelope_time_re_applies_and_clamps() {
        let t = transport(120.0, false, 0.0);
        let mut env = ModulatorState::new(ModulatorKind::Adsr, SR);
        set_real(&mut env, ENV_ATTACK, 0.01);
        set_real(&mut env, ENV_DECAY, 0.01);
        set_real(&mut env, ENV_SUSTAIN, 0.5);
        set_real(&mut env, ENV_RELEASE, 0.01);
        env.note_on(60, 1.0, 0);

        // An offset that pins the attack at its minimum: the envelope skips to decay.
        env.set_mod_offset(ENV_ATTACK, -1.0);
        env.advance(256, &t); // 5.3 ms, past the 0.5 ms minimum attack
        assert_eq!(env.display_state().0, 2, "a zeroed attack skips to decay");

        // Below OFFSET_EPSILON nothing is stored; an id outside the kind's table is ignored
        // (LFO_PHASE 40 is not an envelope parameter).
        let mut other = ModulatorState::new(ModulatorKind::Adsr, SR);
        other.set_mod_offset(ENV_ATTACK, OFFSET_EPSILON);
        assert_eq!(
            other.mod_offset[other.params.table().slot(ENV_ATTACK).unwrap()],
            0.0
        );
        other.set_mod_offset(LFO_PHASE, 0.5);
        assert!(other.mod_offset.iter().all(|off| *off == 0.0));
    }
}
