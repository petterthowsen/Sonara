//! Note Echo (spec 027 REQ-027, REQ-003): a "repeats" effect. Every input note plays
//! unchanged and is copied `Repeats` times; the k-th copy starts `k × Time` after the input
//! note-on, each copy is `Decay %` quieter and `Pitch Step` semitones further than the
//! previous one, and each keeps its source note's length (its note-off goes out `source
//! duration` after the copy's note-on). `Sync` converts Time to `rate_to_beats(Rate)`
//! quarter notes at the stored tempo, otherwise Time is milliseconds. Copies stop once
//! velocity falls below 1/127 or the key leaves 0..=127.
//!
//! The input note itself passes through via [`NoteCx::pass`], and each copy is emitted
//! through [`NoteCx::emit_on`] with `parent` = the input note id, so copies inherit the
//! input note's clip/live origin and transport stop releases clip-origin copies only
//! (REQ-005, REQ-007). Copies due past the current block stay in the host's schedule and
//! come out at their exact sample position in a later block (REQ-003).

use super::clock::{rate_to_beats, RATE_CHOICES};
use super::host::{NoteCx, NoteProcessor};
use crate::audio::devices::param_table::{linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::dsp::tempo_sync::{index_of, SYNC_CHOICES};
use crate::audio::midi_types::{NoteEvent, SoundingNoteId};
use crate::audio::transport::Transport;

pub const REPEATS: ParamId = 0;
pub const SYNC: ParamId = 1;
pub const TIME_RATE: ParamId = 2;
pub const TIME: ParamId = 3;
pub const DECAY: ParamId = 4;
pub const PITCH_STEP: ParamId = 5;

/// A copy never starts quieter than this, so it can't read as a note-off downstream.
const MIN_VELOCITY: f32 = 1.0 / 127.0;
/// Input notes with copies still tracked (the host holds at most 128 input notes).
const MAX_SOURCES: usize = 128;
/// Largest value of Repeats.
const MAX_REPEATS: usize = 16;
/// Time Rate default: 1/8, three straight choices before the 1/16 default.
const TIME_RATE_DEFAULT: f32 =
    index_of("1/8") as f32 - (SYNC_CHOICES.len() - RATE_CHOICES.len()) as f32;

const SPECS: [ParamSpec; 6] = [
    spec(REPEATS, "Repeats", "Echo", "", linear(1.0, 16.0), 3.0),
    spec(SYNC, "Sync", "Time", "", Kind::Bool, 1.0),
    spec(
        TIME_RATE,
        "Time Rate",
        "Time",
        "",
        Kind::Enum(RATE_CHOICES),
        TIME_RATE_DEFAULT,
    ),
    spec(TIME, "Time", "Time", "ms", linear(1.0, 2000.0), 250.0),
    spec(DECAY, "Decay", "Echo", "%", linear(0.0, 100.0), 50.0),
    spec(
        PITCH_STEP,
        "Pitch Step",
        "Echo",
        "st",
        linear(-12.0, 12.0),
        0.0,
    ),
];
const SLOTS: [u8; 6] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// One copy of one input note, remembered so its note-off can be scheduled.
#[derive(Clone, Copy)]
struct Repeat {
    id: SoundingNoteId,
    key: u8,
    /// Absolute sample the copy's note-on starts (or was scheduled) at.
    at: u64,
}

/// An input note still sounding, with the copies it has started.
#[derive(Clone, Copy)]
struct Source {
    id: SoundingNoteId,
    /// Absolute sample the input note-on arrived at.
    on_at: u64,
    count: usize,
    repeats: [Repeat; MAX_REPEATS],
}

pub struct NoteEcho {
    repeats: f32,
    sync: f32,
    rate: f32,
    time_ms: f32,
    decay: f32,
    pitch_step: f32,

    sample_rate: f32,
    tempo: f32,
    sources: Vec<Source>,
}

impl NoteEcho {
    /// The interval between copies, in frames, from the stored sample rate and tempo.
    fn step_frames(&self) -> u64 {
        let seconds = if self.sync >= 0.5 {
            rate_to_beats(self.rate.round() as usize) * 60.0 / self.tempo.max(1.0) as f64
        } else {
            self.time_ms as f64 / 1000.0
        };
        ((seconds * self.sample_rate as f64).round().max(1.0)) as u64
    }

    /// Find the source entry for input note `id`, if the effect is tracking it.
    fn find_source(&self, id: SoundingNoteId) -> Option<usize> {
        self.sources.iter().position(|s| s.id == id)
    }
}

impl NoteProcessor for NoteEcho {
    fn new(sample_rate: f32) -> Self {
        Self {
            repeats: 3.0,
            sync: 1.0,
            rate: TIME_RATE_DEFAULT,
            time_ms: 250.0,
            decay: 50.0,
            pitch_step: 0.0,
            sample_rate,
            tempo: 120.0,
            sources: Vec::with_capacity(MAX_SOURCES),
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.note_echo"
    }

    fn device_name() -> &'static str {
        "Note Echo"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            REPEATS => self.repeats = real,
            SYNC => self.sync = real,
            TIME_RATE => self.rate = real,
            TIME => self.time_ms = real,
            DECAY => self.decay = real,
            PITCH_STEP => self.pitch_step = real,
            _ => {}
        }
    }

    fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64) {
        match *event {
            NoteEvent::On {
                note_id,
                key,
                velocity,
            } => {
                // The input note itself plays unchanged; its off is passed on arrival.
                cx.pass(event, at);
                // The step the copies are spread over; read per note-on so a tempo or
                // parameter change affects the notes that follow it.
                let step = self.step_frames();
                let repeats = self.repeats.round().clamp(1.0, MAX_REPEATS as f32) as usize;
                let decay = (self.decay / 100.0).clamp(0.0, 1.0);
                let pitch_step = self.pitch_step.round() as i32;
                if self.sources.len() == self.sources.capacity() {
                    // Nothing to remember the copies on, so don't start any: a copy without
                    // a scheduled note-off would sound forever downstream.
                    return;
                }
                let mut vel = velocity;
                let mut count = 0;
                let mut repeats_out = [Repeat {
                    id: 0,
                    key: 0,
                    at: 0,
                }; MAX_REPEATS];
                for k in 1..=repeats {
                    vel *= decay;
                    if vel < MIN_VELOCITY {
                        break;
                    }
                    let copy_key = key as i32 + k as i32 * pitch_step;
                    let copy_at = at + k as u64 * step;
                    // Each copy keeps its source note's length: its note-off is scheduled
                    // when the input note-off arrives, at its own note-on plus the source's
                    // duration. `emit_on` schedules copies past the current block (REQ-003)
                    // and drops out-of-range keys (REQ-009).
                    let Some(id) = cx.emit_on(copy_key, vel, copy_at, note_id) else {
                        // Out of key range or no room: later copies can only be worse.
                        break;
                    };
                    repeats_out[count] = Repeat {
                        id,
                        key: copy_key as u8,
                        at: copy_at,
                    };
                    count += 1;
                }
                // Overwrite a previous entry for the same input note (a retrigger while held).
                self.sources.retain(|s| s.id != note_id);
                self.sources.push(Source {
                    id: note_id,
                    on_at: at,
                    count,
                    repeats: repeats_out,
                });
            }
            NoteEvent::Off {
                note_id, release, ..
            } => {
                // The input note's own note-off passes through unchanged.
                cx.pass(event, at);
                let Some(index) = self.find_source(note_id) else {
                    return;
                };
                let source = self.sources[index];
                // A copy keeps the length of its source note: end it at its note-on plus the
                // source's duration, without cancelling its still-scheduled note-on (REQ-004).
                let duration = at.saturating_sub(source.on_at);
                for r in &source.repeats[..source.count] {
                    cx.end_note_at(r.id, r.key, r.at + duration, release, note_id);
                }
                self.sources.swap_remove(index);
            }
            NoteEvent::Expression { .. } => {}
        }
    }

    fn reset(&mut self) {
        self.sources.clear();
    }

    fn discontinuity(&mut self, _cx: &mut NoteCx) {
        // The host releases clip-origin outputs and drops their schedule; the copies' offs
        // are only ever scheduled when their input note-off arrives, so there is nothing
        // pending here beyond the host's own bookkeeping.
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.tempo = transport.tempo as f32;
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::note_fx::NoteFxHost;
    use crate::audio::devices::AudioDevice;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 500;

    fn device() -> NoteFxHost<NoteEcho> {
        let mut d = NoteFxHost::<NoteEcho>::new(SR);
        d.set_transport(&Transport {
            tempo: 120.0,
            ..Transport::default()
        });
        d
    }

    fn set(d: &mut NoteFxHost<NoteEcho>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    fn press(d: &mut NoteFxHost<NoteEcho>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::On {
                note_id: id,
                key,
                velocity: 0.8,
            },
            frame,
        );
    }

    fn release(d: &mut NoteFxHost<NoteEcho>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::Off {
                note_id: id,
                key,
                release: 0.5,
            },
            frame,
        );
    }

    /// Absolute `(sample, is_on, key, velocity or release)` of everything the device emits
    /// over `blocks` blocks starting at block `from`.
    fn collect(
        d: &mut NoteFxHost<NoteEcho>,
        from: usize,
        blocks: usize,
    ) -> Vec<(usize, bool, u8, f32)> {
        let mut out = Vec::new();
        for b in from..from + blocks {
            for n in d.process_notes(BLOCK) {
                let at = b * BLOCK + n.frame;
                match n.event {
                    NoteEvent::On { key, velocity, .. } => out.push((at, true, key, velocity)),
                    NoteEvent::Off { key, release, .. } => out.push((at, false, key, release)),
                    _ => {}
                }
            }
        }
        out
    }

    /// REQ-027 at 120 BPM, defaults (Repeats 3, Sync on 1/8, Decay 50 %) with Pitch Step +12:
    /// input 60 at 0.8 lasting 100 ms gives 60/72/84/96 at 0.8/0.4/0.2/0.1, 250 ms apart, each
    /// 100 ms long.
    #[test]
    fn three_repeats_eighths_decay_half() {
        let mut d = device();
        set(&mut d, PITCH_STEP, 12.0);
        press(&mut d, 1, 60, 0);
        assert_eq!(collect(&mut d, 0, 9), vec![(0, true, 60, 0.8)]);
        release(&mut d, 1, 60, 300);
        assert_eq!(
            collect(&mut d, 9, 73),
            vec![
                // The input's own off passes through at its sample position.
                (4_800, false, 60, 0.5),
                // Copy 1 starts 250 ms in, ends 100 ms after its own start.
                (12_000, true, 72, 0.4),
                (16_800, false, 72, 0.5),
                // Copy 2 another 250 ms later.
                (24_000, true, 84, 0.2),
                (28_800, false, 84, 0.5),
                // Copy 3.
                (36_000, true, 96, 0.1),
                (40_800, false, 96, 0.5),
            ]
        );
    }

    /// REQ-003: a copy due more than one block later arrives in the correct later block at
    /// the correct frame offset, and its off follows 200 ms (the source length) later.
    #[test]
    fn a_repeat_due_more_than_a_block_later_is_sample_accurate() {
        let mut d = device();
        set(&mut d, SYNC, 0.0);
        set(&mut d, TIME, 250.0);
        set(&mut d, DECAY, 50.0);
        set(&mut d, REPEATS, 1.0);
        press(&mut d, 1, 60, 37);
        release(&mut d, 1, 60, 237);
        // The input holds for 200 frames; the copy starts 250 ms (12000 frames) after its
        // source note-on, and ends 200 frames later.
        assert_eq!(
            collect(&mut d, 0, 60),
            vec![
                (37, true, 60, 0.8),
                (237, false, 60, 0.5),
                (12_037, true, 60, 0.4),
                (12_237, false, 60, 0.5),
            ]
        );
    }

    /// Copies whose velocity falls below 1/127 are not played, and the chain stops there.
    #[test]
    fn copies_stop_below_min_velocity() {
        let mut d = device();
        set(&mut d, SYNC, 0.0);
        set(&mut d, TIME, 50.0);
        set(&mut d, DECAY, 5.0);
        set(&mut d, REPEATS, 16.0);
        press(&mut d, 1, 60, 0);
        release(&mut d, 1, 60, 100);
        // 0.8 → 0.04, and 0.002 is below 1/127: only one copy.
        let events = collect(&mut d, 0, 8);
        assert_eq!(
            events.iter().map(|e| (e.0, e.1, e.2)).collect::<Vec<_>>(),
            vec![
                (0, true, 60),
                (100, false, 60),
                (2_400, true, 60),
                (2_500, false, 60)
            ]
        );
        assert!((events[0].3 - 0.8).abs() < 1e-6, "{}", events[0].3);
        assert!((events[2].3 - 0.04).abs() < 1e-6, "{}", events[2].3);
    }

    /// Copies shifted outside 0..=127 are dropped; the input note still passes.
    #[test]
    fn out_of_range_copies_are_dropped() {
        let mut d = device();
        set(&mut d, SYNC, 0.0);
        set(&mut d, TIME, 50.0);
        set(&mut d, DECAY, 100.0);
        set(&mut d, REPEATS, 3.0);
        set(&mut d, PITCH_STEP, 12.0);
        press(&mut d, 1, 120, 0);
        release(&mut d, 1, 120, 100);
        assert_eq!(
            collect(&mut d, 0, 5),
            vec![(0, true, 120, 0.8), (100, false, 120, 0.5)]
        );
    }
}
