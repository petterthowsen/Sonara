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
    ModParams, ModulatorKind, ENV_ATTACK, ENV_DECAY, ENV_RELEASE, ENV_SUSTAIN, LFO_PHASE, LFO_RATE,
    LFO_RETRIGGER, LFO_SHAPE, LFO_SYNC,
};
use super::lfo::{Lfo, LfoShape};
use crate::audio::devices::ParamId;
use crate::audio::dsp::tempo_sync::sync_beats;
use crate::audio::transport::Transport;

/// The keytrack source reaches ±1 this many semitones either side of C3 (60), as in PolySynth.
const KEYTRACK_RANGE: f32 = 60.0;
/// Sample rate used until `prepare` supplies the real one (RT-safe default).
const DEFAULT_SAMPLE_RATE: f32 = 48_000.0;

#[derive(Clone, Copy, Debug)]
pub struct ModulatorState {
    kind: ModulatorKind,
    params: ModParams,
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
    random: f32,
    /// xorshift state; never zero.
    rng: u32,
}

impl ModulatorState {
    pub fn new(kind: ModulatorKind, sample_rate: f32) -> Self {
        let mut state = Self {
            kind,
            params: ModParams::new(kind),
            sample_rate: sample_rate.max(1.0),
            lfo: Lfo::default(),
            synced_cycle: f64::NAN,
            env: AdsrEnvelope::new(sample_rate),
            held: 0,
            last_note: 60.0,
            velocity: 0.0,
            random: 0.0,
            rng: (kind.index() as u32 + 1).wrapping_mul(0x9E37_79B9) | 1,
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
        let attack = self.params.real(ENV_ATTACK).unwrap_or(0.005);
        let decay = self.params.real(ENV_DECAY).unwrap_or(0.3);
        let (sustain, release) = if self.kind == ModulatorKind::Adsr {
            (
                self.params.real(ENV_SUSTAIN).unwrap_or(0.5),
                self.params.real(ENV_RELEASE).unwrap_or(0.3),
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
    pub fn note_on(&mut self, note: u8, velocity: u8, _frame: usize) {
        self.held = self.held.saturating_add(1);
        self.trigger(note, velocity);
    }

    fn trigger(&mut self, note: u8, velocity: u8) {
        let velocity = velocity as f32 / 127.0;
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
        }
    }

    /// A note-off: an envelope releases once the last held note is released.
    pub fn note_off(&mut self, _note: u8, _frame: usize) {
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
    pub fn gate_voice_on(&mut self, note: u8, velocity: u8) {
        self.held = 1;
        self.trigger(note, velocity);
    }

    /// Per-voice note-off: gate the envelope off (an `ad` ignores it), as
    /// [`gate_voice_on`](Self::gate_voice_on) is the per-voice companion to `note_on`.
    pub fn gate_voice_off(&mut self) {
        self.held = 0;
        if self.kind == ModulatorKind::Adsr {
            self.env.gate_off();
        }
    }

    /// Follow a new note without retriggering (a legato slide): velocity and keytrack update,
    /// envelopes and LFOs are left running.
    pub fn update_note(&mut self, note: u8, velocity: u8) {
        match self.kind {
            ModulatorKind::Velocity => self.velocity = velocity as f32 / 127.0,
            ModulatorKind::Keytrack => self.last_note = note as f32,
            _ => {}
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
                let shape =
                    LfoShape::from_index(self.params.real(LFO_SHAPE).unwrap_or(0.0) as usize);
                let sync = sync_beats(self.params.real(LFO_SYNC).unwrap_or(0.0) as usize);
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
                            None => self.params.real(LFO_RATE).unwrap_or(2.0) as f64,
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
        }
    }

    /// The current value, without advancing.
    pub fn value(&self) -> f32 {
        match self.kind {
            ModulatorKind::Lfo => {
                let shape =
                    LfoShape::from_index(self.params.real(LFO_SHAPE).unwrap_or(0.0) as usize);
                self.lfo.value(shape)
            }
            ModulatorKind::Adsr | ModulatorKind::Ad => self.env.value(),
            ModulatorKind::Velocity => self.velocity,
            ModulatorKind::Keytrack => self.keytrack(),
            ModulatorKind::Random => self.random,
        }
    }

    fn keytrack(&self) -> f32 {
        ((self.last_note - 60.0) / KEYTRACK_RANGE).clamp(-1.0, 1.0)
    }

    /// Back to a fresh state (no notes held, envelopes idle, LFO at phase 0).
    pub fn reset(&mut self) {
        self.held = 0;
        self.last_note = 60.0;
        self.velocity = 0.0;
        self.random = 0.0;
        self.lfo = Lfo::default();
        self.synced_cycle = f64::NAN;
        self.env.reset();
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
        note.note_on(60, 100, 0);
        assert!((note.lfo.phase - 0.25).abs() < 1e-9, "{}", note.lfo.phase);

        // Retrigger Free: a note-on leaves the phase running.
        let mut free = ModulatorState::new(ModulatorKind::Lfo, SR);
        set_real(&mut free, LFO_RETRIGGER, 0.0); // Free
        free.advance(4_800, &t);
        let before = free.lfo.phase;
        assert!(before > 0.1, "{before}");
        free.note_on(60, 100, 0);
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
            adsr.note_on(60, 100, 0);
            assert_within_5_percent(samples_in_state(&mut adsr, AdsrState::Attack), time);
            assert_within_5_percent(samples_in_state(&mut adsr, AdsrState::Decay), time);
            assert!((adsr.value() - 0.4).abs() < 1e-6);
            adsr.note_off(60, 0);
            assert_within_5_percent(samples_in_state(&mut adsr, AdsrState::Release), time);
            assert!(!adsr.env.is_active());

            let mut ad = ModulatorState::new(ModulatorKind::Ad, SR);
            set_real(&mut ad, ENV_ATTACK, time);
            set_real(&mut ad, ENV_DECAY, time);
            ad.note_on(60, 100, 0);
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
        adsr.note_on(60, 100, 0);
        adsr.note_on(64, 100, 0);
        let t = transport(120.0, false, 0.0);
        adsr.advance(2_000, &t); // past attack + decay into sustain
        adsr.note_off(60, 0);
        assert_eq!(adsr.env.state(), AdsrState::Sustain, "one note still held");
        adsr.note_off(64, 0);
        assert_eq!(adsr.env.state(), AdsrState::Release);

        // A note-on while an envelope is running retriggers the attack.
        adsr.note_on(67, 100, 0);
        assert_eq!(adsr.env.state(), AdsrState::Attack);

        // AD is one-shot: note-off never releases it.
        let mut ad = ModulatorState::new(ModulatorKind::Ad, SR);
        set_real(&mut ad, ENV_ATTACK, 0.01);
        set_real(&mut ad, ENV_DECAY, 0.2);
        ad.note_on(60, 100, 0);
        ad.advance(480, &t); // past the attack
        ad.note_off(60, 0);
        assert_ne!(ad.env.state(), AdsrState::Release);
    }

    #[test]
    fn keytrack_and_velocity_mapping() {
        let t = transport(120.0, false, 0.0);

        let mut key = ModulatorState::new(ModulatorKind::Keytrack, SR);
        key.note_on(60, 100, 0);
        assert_eq!(key.advance(64, &t), 0.0, "C3 is the pivot");
        key.note_on(120, 100, 0);
        assert_eq!(key.advance(64, &t), 1.0, "+60 semitones");
        key.note_on(0, 100, 0);
        assert_eq!(key.advance(64, &t), -1.0, "−60 semitones");

        let mut vel = ModulatorState::new(ModulatorKind::Velocity, SR);
        vel.note_on(60, 127, 0);
        assert_eq!(vel.advance(64, &t), 1.0);
        vel.note_on(60, 64, 0);
        assert!((vel.advance(64, &t) - 64.0 / 127.0).abs() < 1e-6);

        let mut random = ModulatorState::new(ModulatorKind::Random, SR);
        random.note_on(60, 100, 0);
        let first = random.advance(64, &t);
        assert!((-1.0..=1.0).contains(&first));
        random.note_on(62, 100, 0);
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
}
