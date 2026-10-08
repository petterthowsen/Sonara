//! Step Sequencer (spec 027 REQ-024 to REQ-026): 16 steps that re-play the held notes.
//!
//! The first `Length` (1..16) steps loop on a [`StepClock`] grid, using Rate, Gate and Swing
//! exactly as the Arpeggiator does (REQ-021). Each step has On, Pitch (−24..+24), Velocity
//! (0..100 %) and Chance (0..100 %): an on step that wins its chance roll plays the held notes
//! shifted by its Pitch — every held note in Chord mode, only the most recently pressed one in
//! Mono mode (REQ-025). Velocity Source picks a percentage of the input velocity (Input ×
//! Step) or the step velocity as an absolute value (Step). An off step, or one that loses its
//! chance roll, plays nothing.
//!
//! WHILE the transport plays the step position is the clock's grid index mod Length, so the
//! pattern stays bar-locked and doesn't start on the note-on (REQ-026). WHILE stopped, the
//! pattern starts at step 1 on the first note-on of an empty held set, then free-runs.
//!
//! Each output note's parent is the held note it came from, so it has that note's clip/live
//! origin and transport stop ends clip-origin notes only (REQ-005, REQ-007).

use super::clock::{rate_to_beats, StepClock, RATE_CHOICES, RATE_DEFAULT};
use super::host::{NoteCx, NoteProcessor, NoteState};
use crate::audio::devices::param_table::{linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::dsp::Rng;
use crate::audio::midi_types::{is_clip_note, NoteEvent, SoundingNoteId, DEFAULT_RELEASE};
use crate::audio::transport::Transport;

pub const LENGTH: ParamId = 0;
pub const MODE: ParamId = 1;
pub const VELOCITY_SOURCE: ParamId = 2;
pub const RATE: ParamId = 10;
pub const GATE: ParamId = 11;
pub const SWING: ParamId = 12;

/// Steps in the pattern; the first `Length` play.
pub const STEPS: usize = 16;

/// The parameters of step `k` (0-based): base + 0 On, +1 Pitch, +2 Velocity, +3 Chance.
pub const fn step_base(k: usize) -> ParamId {
    (100 + 10 * k) as ParamId
}
pub const fn step_on(k: usize) -> ParamId {
    step_base(k)
}
pub const fn step_pitch(k: usize) -> ParamId {
    step_base(k) + 1
}
pub const fn step_velocity(k: usize) -> ParamId {
    step_base(k) + 2
}
pub const fn step_chance(k: usize) -> ParamId {
    step_base(k) + 3
}

const MODES: &[&str] = &["Chord", "Mono"];
const MODE_MONO: u8 = 1;
const VELOCITY_SOURCES: &[&str] = &["Input × Step", "Step"];
const SOURCE_STEP: u8 = 1;

/// The shared parameters plus four per step (the largest ID is step 16's Chance, 253).
const SPECS: [ParamSpec; 6 + 4 * STEPS] = [
    spec(LENGTH, "Length", "Pattern", "", linear(1.0, 16.0), 4.0),
    spec(MODE, "Mode", "Pattern", "", Kind::Enum(MODES), 0.0),
    spec(
        VELOCITY_SOURCE,
        "Velocity Source",
        "Pattern",
        "",
        Kind::Enum(VELOCITY_SOURCES),
        0.0,
    ),
    spec(
        RATE,
        "Rate",
        "Timing",
        "",
        Kind::Enum(RATE_CHOICES),
        RATE_DEFAULT,
    ),
    spec(GATE, "Gate", "Timing", "%", linear(10.0, 200.0), 100.0),
    spec(SWING, "Swing", "Timing", "%", linear(0.0, 75.0), 0.0),
    spec(step_on(0), "On", "Step 1", "", Kind::Bool, 1.0),
    spec(
        step_pitch(0),
        "Pitch",
        "Step 1",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(0),
        "Velocity",
        "Step 1",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(0),
        "Chance",
        "Step 1",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(1), "On", "Step 2", "", Kind::Bool, 0.0),
    spec(
        step_pitch(1),
        "Pitch",
        "Step 2",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(1),
        "Velocity",
        "Step 2",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(1),
        "Chance",
        "Step 2",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(2), "On", "Step 3", "", Kind::Bool, 0.0),
    spec(
        step_pitch(2),
        "Pitch",
        "Step 3",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(2),
        "Velocity",
        "Step 3",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(2),
        "Chance",
        "Step 3",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(3), "On", "Step 4", "", Kind::Bool, 0.0),
    spec(
        step_pitch(3),
        "Pitch",
        "Step 4",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(3),
        "Velocity",
        "Step 4",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(3),
        "Chance",
        "Step 4",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(4), "On", "Step 5", "", Kind::Bool, 0.0),
    spec(
        step_pitch(4),
        "Pitch",
        "Step 5",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(4),
        "Velocity",
        "Step 5",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(4),
        "Chance",
        "Step 5",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(5), "On", "Step 6", "", Kind::Bool, 0.0),
    spec(
        step_pitch(5),
        "Pitch",
        "Step 6",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(5),
        "Velocity",
        "Step 6",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(5),
        "Chance",
        "Step 6",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(6), "On", "Step 7", "", Kind::Bool, 0.0),
    spec(
        step_pitch(6),
        "Pitch",
        "Step 7",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(6),
        "Velocity",
        "Step 7",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(6),
        "Chance",
        "Step 7",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(7), "On", "Step 8", "", Kind::Bool, 0.0),
    spec(
        step_pitch(7),
        "Pitch",
        "Step 8",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(7),
        "Velocity",
        "Step 8",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(7),
        "Chance",
        "Step 8",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(8), "On", "Step 9", "", Kind::Bool, 0.0),
    spec(
        step_pitch(8),
        "Pitch",
        "Step 9",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(8),
        "Velocity",
        "Step 9",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(8),
        "Chance",
        "Step 9",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(9), "On", "Step 10", "", Kind::Bool, 0.0),
    spec(
        step_pitch(9),
        "Pitch",
        "Step 10",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(9),
        "Velocity",
        "Step 10",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(9),
        "Chance",
        "Step 10",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(10), "On", "Step 11", "", Kind::Bool, 0.0),
    spec(
        step_pitch(10),
        "Pitch",
        "Step 11",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(10),
        "Velocity",
        "Step 11",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(10),
        "Chance",
        "Step 11",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(11), "On", "Step 12", "", Kind::Bool, 0.0),
    spec(
        step_pitch(11),
        "Pitch",
        "Step 12",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(11),
        "Velocity",
        "Step 12",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(11),
        "Chance",
        "Step 12",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(12), "On", "Step 13", "", Kind::Bool, 0.0),
    spec(
        step_pitch(12),
        "Pitch",
        "Step 13",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(12),
        "Velocity",
        "Step 13",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(12),
        "Chance",
        "Step 13",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(13), "On", "Step 14", "", Kind::Bool, 0.0),
    spec(
        step_pitch(13),
        "Pitch",
        "Step 14",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(13),
        "Velocity",
        "Step 14",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(13),
        "Chance",
        "Step 14",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(14), "On", "Step 15", "", Kind::Bool, 0.0),
    spec(
        step_pitch(14),
        "Pitch",
        "Step 15",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(14),
        "Velocity",
        "Step 15",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(14),
        "Chance",
        "Step 15",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(step_on(15), "On", "Step 16", "", Kind::Bool, 0.0),
    spec(
        step_pitch(15),
        "Pitch",
        "Step 16",
        "st",
        linear(-24.0, 24.0),
        0.0,
    ),
    spec(
        step_velocity(15),
        "Velocity",
        "Step 16",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(
        step_chance(15),
        "Chance",
        "Step 16",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
];
const SLOTS: [u8; 260] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Held notes (the host holds at most this many input notes).
const MAX_HELD: usize = 128;

/// One step's values, in real units.
#[derive(Clone, Copy)]
struct StepState {
    on: bool,
    pitch: i32,
    velocity: f32,
    chance: f32,
}

#[derive(Clone, Copy)]
struct Held {
    id: SoundingNoteId,
    key: u8,
    velocity: f32,
}

pub struct StepSequencer {
    length: u8,
    mono: bool,
    absolute_velocity: bool,
    gate: f32,

    clock: StepClock,
    rng: Rng,

    steps: [StepState; STEPS],
    held: Vec<Held>,
    /// Index of the most recently pressed held note (Mono plays it).
    last_pressed: usize,
    last_key: Option<u8>,
    /// A sequence starting at this sample (the first note-on while stopped); step 1 plays once
    /// the block has reached it.
    pending_start: Option<u64>,
    /// The sequence is running (it free-runs while a note stays held).
    running: bool,
    /// The step of the last grid point handed out.
    step: Option<u8>,
}

impl StepSequencer {
    /// Play step `k` at sample `at`: one note per held note (or the last pressed one in Mono).
    /// An off step, or one that loses its chance roll, plays nothing.
    fn play_step(&mut self, cx: &mut NoteCx, at: u64, k: usize) {
        self.step = Some(k as u8);
        let step = self.steps[k];
        if !step.on || self.held.is_empty() {
            return;
        }
        // One chance roll per step, not per held note. `next_f32` is in [0, 1): 100 % always
        // passes, 0 % never does.
        if self.rng.next_f32() >= step.chance {
            return;
        }
        let length = ((self.gate * self.clock.step_samples() as f32) as u64).max(1);
        let count = if self.mono { 1 } else { self.held.len() };
        for i in 0..count {
            let held = if self.mono {
                self.held[self.last_pressed]
            } else {
                self.held[i]
            };
            let key = held.key as i32 + step.pitch;
            let velocity = if self.absolute_velocity {
                step.velocity
            } else {
                held.velocity * step.velocity
            };
            if let Some(id) = cx.emit_on(key, velocity, at, held.id) {
                cx.end_note_at(id, key as u8, at + length, DEFAULT_RELEASE, held.id);
                self.last_key = Some(key as u8);
            }
        }
    }

    fn start_pending(&mut self, cx: &mut NoteCx, until: u64) {
        if let Some(at) = self.pending_start {
            if until > at {
                self.pending_start = None;
                self.clock.start_at(cx.now(), at);
                // While playing, `start_at` keeps the next step on the grid: no immediate hit.
                if !self.clock.on_grid() {
                    self.play_step(cx, at, 0);
                }
            }
        }
    }

    fn forget_all(&mut self) {
        self.held.clear();
        self.last_pressed = 0;
        self.last_key = None;
        self.pending_start = None;
        self.running = false;
        self.step = None;
    }
}

impl NoteProcessor for StepSequencer {
    fn new(sample_rate: f32) -> Self {
        Self {
            length: 4,
            mono: false,
            absolute_velocity: false,
            gate: 1.0,
            clock: StepClock::new(sample_rate),
            rng: Rng::new(0x57E9_5E10),
            steps: core::array::from_fn(|k| StepState {
                on: k == 0,
                pitch: 0,
                velocity: 1.0,
                chance: 1.0,
            }),
            held: Vec::with_capacity(MAX_HELD),
            last_pressed: 0,
            last_key: None,
            pending_start: None,
            running: false,
            step: None,
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.step_sequencer"
    }

    fn device_name() -> &'static str {
        "Step Sequencer"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            LENGTH => self.length = (real.round() as u8).clamp(1, STEPS as u8),
            MODE => self.mono = real as u8 == MODE_MONO,
            VELOCITY_SOURCE => self.absolute_velocity = real as u8 == SOURCE_STEP,
            RATE => self.clock.set_rate_beats(rate_to_beats(real as usize)),
            GATE => self.gate = real / 100.0,
            SWING => self.clock.set_swing(real / 100.0),
            _ => {
                let Some(k) = id.checked_sub(100).map(|i| i as usize) else {
                    return;
                };
                if k / 10 >= STEPS {
                    return;
                }
                let step = &mut self.steps[k / 10];
                match k % 10 {
                    0 => step.on = real >= 0.5,
                    1 => step.pitch = real.round() as i32,
                    2 => step.velocity = real / 100.0,
                    3 => step.chance = real / 100.0,
                    _ => {}
                }
            }
        }
    }

    fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64) {
        match *event {
            NoteEvent::On {
                note_id,
                key,
                velocity,
            } => {
                if self.held.len() >= MAX_HELD {
                    return;
                }
                let fresh = self.held.is_empty();
                self.held.push(Held {
                    id: note_id,
                    key,
                    velocity,
                });
                self.last_pressed = self.held.len() - 1;
                if fresh {
                    self.running = true;
                    if self.clock.on_grid() {
                        // While playing the pattern doesn't start on the note-on (REQ-026): it
                        // starts at the next grid point.
                        self.clock.sync_to_grid(cx.now(), at);
                    } else {
                        self.pending_start = Some(at);
                    }
                }
            }
            NoteEvent::Off {
                note_id, release, ..
            } => {
                let Some(i) = self.held.iter().position(|h| h.id == note_id) else {
                    return;
                };
                // The step the key started ends with it, so a legato clip note (or a loop wrap)
                // followed at once by the next note never overlaps with it.
                cx.release_children(note_id, at, release);
                self.held.remove(i);
                // After any removal, the most recently pressed held note is the last one.
                self.last_pressed = self.held.len().saturating_sub(1);
                if self.held.is_empty() {
                    self.running = false;
                    self.pending_start = None;
                    self.step = None;
                }
            }
            NoteEvent::Expression { .. } => {}
        }
    }

    fn run_until(&mut self, cx: &mut NoteCx, until: u64) {
        self.start_pending(cx, until);
        // A sequence still arriving at its start frame: step 1 anchors the clock, so don't ask
        // it for steps before then.
        if self.held.is_empty() || !self.running || self.pending_start.is_some() {
            return;
        }
        while let Some(step) = self.clock.next(cx.now(), until) {
            // The pattern is the clock's index — the transport grid index while playing, the
            // free-running count while stopped — mod Length (REQ-026).
            let k = step.index.rem_euclid(self.length as i64) as usize;
            self.play_step(cx, step.at, k);
        }
    }

    fn reset(&mut self) {
        self.forget_all();
        self.clock.reset();
    }

    fn discontinuity(&mut self, _cx: &mut NoteCx) {
        self.held.retain(|h| !is_clip_note(h.id));
        if self.held.is_empty() {
            self.forget_all();
            self.clock.reset();
        }
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.clock.set_transport(transport);
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.clock.set_sample_rate(sample_rate);
    }

    const HAS_STATE: bool = true;

    fn state(&self, out: &mut NoteState) {
        if self.running {
            out.step = self.step.unwrap_or(0xFF);
        }
        out.key = self.last_key.unwrap_or(0xFF);
        out.held.extend(self.held.iter().map(|h| h.key));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::note_fx::NoteFxHost;
    use crate::audio::devices::AudioDevice;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 500;

    /// 120 BPM at the default Rate 1/16: one step every 6000 frames = 12 blocks.
    fn device() -> NoteFxHost<StepSequencer> {
        let mut d = NoteFxHost::<StepSequencer>::new(SR);
        d.set_transport(&Transport {
            tempo: 120.0,
            ..Transport::default()
        });
        d
    }

    fn set(d: &mut NoteFxHost<StepSequencer>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    fn set_step(
        d: &mut NoteFxHost<StepSequencer>,
        k: usize,
        on: bool,
        pitch: f32,
        velocity: f32,
        chance: f32,
    ) {
        set(d, step_on(k), if on { 1.0 } else { 0.0 });
        set(d, step_pitch(k), pitch);
        set(d, step_velocity(k), velocity);
        set(d, step_chance(k), chance);
    }

    /// Turn steps `0..n` on, all with Pitch 0 (for timing tests).
    fn set_steps_on(d: &mut NoteFxHost<StepSequencer>, n: usize) {
        for k in 0..n {
            set_step(d, k, true, 0.0, 100.0, 100.0);
        }
    }

    fn press(d: &mut NoteFxHost<StepSequencer>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::On {
                note_id: id,
                key,
                velocity: 0.8,
            },
            frame,
        );
    }

    fn release(d: &mut NoteFxHost<StepSequencer>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::Off {
                note_id: id,
                key,
                release: 0.5,
            },
            frame,
        );
    }

    /// Absolute `(sample, is_on, key, velocity)` of everything the device emits over `blocks`
    /// blocks starting at block `from`.
    fn collect(
        d: &mut NoteFxHost<StepSequencer>,
        from: usize,
        blocks: usize,
    ) -> Vec<(usize, bool, u8, f32)> {
        let mut out = Vec::new();
        for b in from..from + blocks {
            for n in d.process_notes(BLOCK) {
                let at = b * BLOCK + n.frame;
                match n.event {
                    NoteEvent::On { key, velocity, .. } => out.push((at, true, key, velocity)),
                    NoteEvent::Off { key, .. } => out.push((at, false, key, 0.0)),
                    _ => {}
                }
            }
        }
        out
    }

    /// Like `collect`, with the transport playing from `start_beats` at 120 BPM.
    fn collect_playing(
        d: &mut NoteFxHost<StepSequencer>,
        start_beats: f64,
        blocks: usize,
    ) -> Vec<(usize, bool, u8, f32)> {
        let mut out = Vec::new();
        for b in 0..blocks {
            d.set_transport(&Transport {
                tempo: 120.0,
                playing: true,
                song_pos_beats: start_beats + (b * BLOCK) as f64 / SR as f64 * 2.0,
                ..Transport::default()
            });
            for n in d.process_notes(BLOCK) {
                let at = b * BLOCK + n.frame;
                match n.event {
                    NoteEvent::On { key, velocity, .. } => out.push((at, true, key, velocity)),
                    NoteEvent::Off { key, .. } => out.push((at, false, key, 0.0)),
                    _ => {}
                }
            }
        }
        out
    }

    fn on_keys(events: &[(usize, bool, u8, f32)]) -> Vec<u8> {
        events.iter().filter(|e| e.1).map(|e| e.2).collect()
    }

    fn on_frames(events: &[(usize, bool, u8, f32)]) -> Vec<usize> {
        events.iter().filter(|e| e.1).map(|e| e.0).collect()
    }

    /// REQ-024: Length 4, pitches 0/+3/+7/+12, step 3 off, holding 60 — the keys cycle
    /// 60, 63, rest, 72, 60, …
    #[test]
    fn the_first_length_steps_loop() {
        let mut d = device();
        set(&mut d, LENGTH, 4.0);
        set_step(&mut d, 0, true, 0.0, 100.0, 100.0);
        set_step(&mut d, 1, true, 3.0, 100.0, 100.0);
        set_step(&mut d, 2, false, 7.0, 100.0, 100.0);
        set_step(&mut d, 3, true, 12.0, 100.0, 100.0);
        press(&mut d, 1, 60, 0);
        let keys = on_keys(&collect(&mut d, 0, 12 * 8));
        assert_eq!(keys, vec![60, 63, 72, 60, 63, 72], "{keys:?}");
    }

    /// REQ-024: the steps from `Length` on are skipped until the loop wraps.
    #[test]
    fn length_stretches_the_loop() {
        let mut d = device();
        set(&mut d, LENGTH, 6.0);
        set_step(&mut d, 0, true, 0.0, 100.0, 100.0);
        set_step(&mut d, 4, true, 1.0, 100.0, 100.0);
        set_step(&mut d, 5, true, 2.0, 100.0, 100.0);
        press(&mut d, 1, 60, 0);
        let keys = on_keys(&collect(&mut d, 0, 12 * 12));
        assert_eq!(keys, vec![60, 61, 62, 60, 61, 62], "{keys:?}");
    }

    /// REQ-024: step 1 Velocity 50 % with input 0.8 — 0.4 with Input × Step, 0.5 with Step.
    #[test]
    fn velocity_source_multiplies_or_replaces_the_input() {
        let mut d = device();
        set_step(&mut d, 0, true, 0.0, 50.0, 100.0);
        press(&mut d, 1, 60, 0);
        let (_, _, _, v) = collect(&mut d, 0, 13)[0];
        assert!((v - 0.4).abs() < 1e-5, "{v}");

        let mut d = device();
        set(&mut d, VELOCITY_SOURCE, 1.0);
        set_step(&mut d, 0, true, 0.0, 50.0, 100.0);
        press(&mut d, 1, 60, 0);
        let (_, _, _, v) = collect(&mut d, 0, 13)[0];
        assert!((v - 0.5).abs() < 1e-5, "{v}");
    }

    /// REQ-024: an off step, or one that loses its chance roll, plays nothing.
    #[test]
    fn an_off_step_or_a_lost_chance_roll_plays_nothing() {
        let mut d = device();
        set_step(&mut d, 0, false, 0.0, 100.0, 100.0);
        set_step(&mut d, 1, true, 0.0, 100.0, 0.0);
        press(&mut d, 1, 60, 0);
        assert!(on_keys(&collect(&mut d, 0, 40)).is_empty());

        let mut d = device();
        set_step(&mut d, 0, true, 0.0, 100.0, 100.0);
        press(&mut d, 1, 60, 0);
        assert_eq!(on_keys(&collect(&mut d, 0, 13)), vec![60]);
    }

    /// REQ-009 (via the host): an out-of-range step pitch is dropped, not wrapped.
    #[test]
    fn an_out_of_range_pitch_plays_nothing() {
        let mut d = device();
        set_step(&mut d, 0, true, 24.0, 100.0, 100.0);
        press(&mut d, 1, 120, 0);
        assert!(on_keys(&collect(&mut d, 0, 13)).is_empty());
    }

    /// REQ-025: Chord plays every held note shifted; Mono plays the last pressed one only.
    #[test]
    fn chord_plays_every_held_note_and_mono_the_last() {
        let mut d = device();
        set_step(&mut d, 0, true, 2.0, 100.0, 100.0);
        press(&mut d, 1, 60, 0);
        press(&mut d, 2, 64, 0);
        let keys = on_keys(&collect(&mut d, 0, 13));
        assert!(keys.contains(&62) && keys.contains(&66), "{keys:?}");

        let mut d = device();
        set(&mut d, MODE, 1.0);
        set_step(&mut d, 0, true, 2.0, 100.0, 100.0);
        press(&mut d, 1, 60, 0);
        press(&mut d, 2, 64, 0);
        assert_eq!(on_keys(&collect(&mut d, 0, 13)), vec![66]);
    }

    /// REQ-026: while playing, the step is the transport grid index mod Length — at tick 960
    /// (Rate 1/16 = 240 ticks) that is 4 mod 4 = step 1 — and the note-on doesn't start it
    /// before the next grid point.
    #[test]
    fn playing_the_step_follows_the_transport_grid() {
        let mut d = NoteFxHost::<StepSequencer>::new(SR);
        d.set_transport(&Transport {
            tempo: 120.0,
            playing: true,
            song_pos_beats: 1.0,
            ..Transport::default()
        });
        set(&mut d, LENGTH, 4.0);
        set_step(&mut d, 0, true, 0.0, 100.0, 100.0);
        set_step(&mut d, 1, true, 3.0, 100.0, 100.0);
        set_step(&mut d, 2, true, 7.0, 100.0, 100.0);
        set_step(&mut d, 3, true, 12.0, 100.0, 100.0);
        press(&mut d, 1, 60, 0);
        // The grid points from tick 960 on, at 6000-frame steps, play steps 1..4 in order.
        let events = collect_playing(&mut d, 1.0, 12 * 5);
        let played: Vec<(usize, u8)> = events.iter().filter(|e| e.1).map(|e| (e.0, e.2)).collect();
        assert_eq!(
            played,
            vec![
                (0, 60),
                (6000, 63),
                (12_000, 67),
                (18_000, 72),
                (24_000, 60)
            ],
            "{played:?}"
        );
    }

    /// REQ-026: while stopped, the first note-on of an empty held set plays step 1 at its own
    /// frame, then the pattern free-runs.
    #[test]
    fn stopped_the_first_note_on_plays_step_1() {
        let mut d = device();
        set_step(&mut d, 1, true, 3.0, 100.0, 100.0);
        set_step(&mut d, 2, true, 7.0, 100.0, 100.0);
        press(&mut d, 1, 60, 123);
        let events = collect(&mut d, 0, 26);
        let played: Vec<(usize, u8)> = events.iter().filter(|e| e.1).map(|e| (e.0, e.2)).collect();
        assert_eq!(
            played,
            vec![(123, 60), (123 + 6000, 63), (123 + 12_000, 67)],
            "{played:?}"
        );
    }

    /// REQ-021: Gate scales the step's length; above 100 % steps overlap.
    #[test]
    fn gate_scales_the_step_length() {
        let mut d = device();
        set(&mut d, GATE, 50.0);
        set_steps_on(&mut d, 4);
        press(&mut d, 1, 60, 0);
        let offs: Vec<usize> = collect(&mut d, 0, 60)
            .iter()
            .filter(|e| !e.1)
            .map(|e| e.0)
            .collect();
        assert_eq!(&offs[..2], &[3000, 9000]);

        let mut d = device();
        set(&mut d, GATE, 150.0);
        set_steps_on(&mut d, 4);
        press(&mut d, 1, 60, 0);
        let offs: Vec<usize> = collect(&mut d, 0, 60)
            .iter()
            .filter(|e| !e.1)
            .map(|e| e.0)
            .collect();
        assert_eq!(offs[0], 9000);
    }

    /// REQ-021: Swing delays every second step by that fraction of half a step.
    #[test]
    fn swing_delays_every_second_step() {
        let mut d = device();
        set(&mut d, SWING, 50.0);
        set_steps_on(&mut d, 4);
        press(&mut d, 1, 60, 0);
        let frames = on_frames(&collect(&mut d, 0, 60));
        assert_eq!(&frames[..4], &[0, 6000 + 1500, 12_000, 18_000 + 1500]);
    }

    /// A held note's note-off ends the output it started; with nothing held the pattern stops.
    #[test]
    fn a_note_off_ends_the_notes_it_started() {
        let mut d = device();
        set_step(&mut d, 0, true, 0.0, 100.0, 100.0);
        press(&mut d, 1, 60, 0);
        collect(&mut d, 0, 2);
        release(&mut d, 1, 60, 100);
        let events = collect(&mut d, 2, 1);
        assert!(events.iter().any(|e| !e.1 && e.2 == 60), "{events:?}");
        assert!(on_keys(&collect(&mut d, 3, 40)).is_empty());
    }

    /// A new note-on after everything was released starts the pattern at step 1 again.
    #[test]
    fn a_new_chord_restarts_at_step_1() {
        let mut d = device();
        set_steps_on(&mut d, 2);
        press(&mut d, 1, 60, 0);
        collect(&mut d, 0, 13);
        release(&mut d, 1, 60, 0);
        collect(&mut d, 13, 2);
        press(&mut d, 2, 72, 40);
        let frames = on_frames(&collect(&mut d, 15, 13));
        assert_eq!(frames[0], 15 * BLOCK + 40, "{frames:?}");
    }

    /// The note_state stream carries the current step, the last sounding key and the held keys.
    #[test]
    fn the_note_state_stream_shows_the_step_and_held_keys() {
        let mut d = device();
        d.subscribe_data("note_state").unwrap();
        press(&mut d, 1, 60, 0);
        press(&mut d, 2, 67, 0);
        collect(&mut d, 0, 1);
        let (kind, bytes) = d.poll_device_data().unwrap();
        assert_eq!(kind, "note_state");
        // Step 1 (0-based 0), sounding 67 (Chord played 60 and 67, 67 last), no branch,
        // two held keys ascending.
        assert_eq!(bytes, vec![0x00, 67, 0xFF, 2, 60, 67]);
    }
}
