//! Note Length (spec 027 REQ-029): control how long output notes last.
//!
//! **Fixed** makes every note last exactly Length, whenever its input note-off arrives: the
//! note keeps the input note's id, and its note-off is scheduled at the note-on plus Length
//! (REQ-005). **Minimum** lets a note last at least Length: it ends at its own input note-off,
//! or at note-on + Length when that is later. Length is a Rate while Sync is on, otherwise
//! milliseconds. WHERE Legato is on, each new note-on first ends every note the effect is
//! sounding, at the new note-on's frame.

use super::clock::{rate_to_beats, RATE_CHOICES, RATE_DEFAULT};
use super::host::{NoteCx, NoteProcessor};
use crate::audio::devices::param_table::{linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::midi_types::{is_clip_note, NoteEvent, SoundingNoteId, DEFAULT_RELEASE};
use crate::audio::transport::Transport;

pub const MODE: ParamId = 0;
pub const SYNC: ParamId = 1;
pub const LENGTH_RATE: ParamId = 2;
pub const LENGTH: ParamId = 3;
pub const LEGATO: ParamId = 4;

const MODES: &[&str] = &["Fixed", "Minimum"];
/// Minimum (Mode 1).
const MODE_MINIMUM: usize = 1;
/// Sounding notes tracked (input id, key, note-on time), one per sounding output. Bounded by
/// the host's held table, which holds at most this many input note-ons.
const MAX_TRACKED: usize = 128;

/// Default Length Rate: 1/8 (250 ms at 120 BPM, matching the default ms Length). The Rate
/// choices run from 1/1 downwards in straight, dotted, triplet order (`clock::RATE_CHOICES`),
/// so 1/8 sits three choices above the 1/16 default.
const LENGTH_RATE_DEFAULT: f32 = RATE_DEFAULT - 3.0;

const SPECS: [ParamSpec; 5] = [
    spec(MODE, "Mode", "Length", "", Kind::Enum(MODES), 0.0),
    spec(SYNC, "Sync", "Length", "", Kind::Bool, 1.0),
    spec(
        LENGTH_RATE,
        "Length Rate",
        "Length",
        "",
        Kind::Enum(RATE_CHOICES),
        LENGTH_RATE_DEFAULT,
    ),
    spec(LENGTH, "Length", "Length", "ms", linear(1.0, 4000.0), 250.0),
    spec(LEGATO, "Legato", "Length", "", Kind::Bool, 0.0),
];
const SLOTS: [u8; 5] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// A sounding note the effect is tracking: the input id it came from (REQ-005) and the
/// absolute sample its note-on was emitted at.
#[derive(Clone, Copy)]
struct Tracked {
    id: SoundingNoteId,
    on_at: u64,
}

pub struct NoteLength {
    mode: usize,
    sync: bool,
    rate: usize,
    length_ms: f32,
    legato: bool,
    sample_rate: f64,
    tempo: f64,
    /// Sounding notes, so Minimum can find their note-on time and Legato can end them.
    notes: Vec<Tracked>,
}

impl NoteLength {
    /// Length in samples, from the stored tempo and rate while Sync is on, otherwise from
    /// the ms Length. Read per note, so a tempo or parameter change affects what follows.
    fn length_samples(&self) -> u64 {
        let seconds = if self.sync {
            rate_to_beats(self.rate) * 60.0 / self.tempo
        } else {
            self.length_ms as f64 / 1000.0
        };
        (seconds * self.sample_rate).round().max(1.0) as u64
    }
}

impl NoteProcessor for NoteLength {
    fn new(sample_rate: f32) -> Self {
        Self {
            mode: 0,
            sync: true,
            rate: LENGTH_RATE_DEFAULT as usize,
            length_ms: 250.0,
            legato: false,
            sample_rate: sample_rate as f64,
            // Matches `StepClock`'s default: containers' first blocks may not set a transport.
            tempo: 120.0,
            notes: Vec::with_capacity(MAX_TRACKED),
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.note_length"
    }

    fn device_name() -> &'static str {
        "Note Length"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            MODE => self.mode = real.max(0.0) as usize % 2,
            SYNC => self.sync = real >= 0.5,
            LENGTH_RATE => {
                self.rate = real.round().clamp(0.0, (RATE_CHOICES.len() - 1) as f32) as usize
            }
            LENGTH => self.length_ms = real.clamp(1.0, 4000.0),
            LEGATO => self.legato = real >= 0.5,
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
                if self.legato {
                    // Each new note-on first ends every note still sounding, at this frame.
                    for n in self.notes.iter() {
                        if cx.is_sounding(n.id) {
                            cx.emit_off(n.id, at, DEFAULT_RELEASE);
                        }
                    }
                    self.notes.clear();
                }
                // A retrigger of a note still tracked replaces its entry.
                self.notes.retain(|n| n.id != note_id);
                let length = self.length_samples();
                match self.mode {
                    MODE_MINIMUM => {
                        if cx.emit_on_with(note_id, key as i32, velocity, at, note_id)
                            && self.notes.len() < self.notes.capacity()
                        {
                            self.notes.push(Tracked {
                                id: note_id,
                                on_at: at,
                            });
                        }
                        // If there was no room to remember the note-on, the input note-off
                        // falls through untracked and ends the note at its own time.
                    }
                    _ => {
                        // Fixed: the note keeps the input id and ends at note-on + Length,
                        // whenever its input note-off arrives. An end scheduled in a later
                        // block is delivered by the host's schedule (REQ-003).
                        if cx.emit_on_with(note_id, key as i32, velocity, at, note_id) {
                            cx.end_note_at(note_id, key, at + length, DEFAULT_RELEASE, note_id);
                            if self.notes.len() < self.notes.capacity() {
                                self.notes.push(Tracked {
                                    id: note_id,
                                    on_at: at,
                                });
                            }
                        }
                    }
                }
            }
            NoteEvent::Off {
                note_id, release, ..
            } => {
                if self.mode == MODE_MINIMUM {
                    match self.notes.iter().position(|n| n.id == note_id) {
                        Some(i) => {
                            let n = self.notes.remove(i);
                            // At least Length: end at the later of the input note-off and
                            // note-on + Length. `emit_off` carries the sounding key.
                            let end = at.max(n.on_at + self.length_samples());
                            cx.emit_off(note_id, end, release);
                        }
                        // Untracked (no room, or Legato already ended it): pass the off
                        // through, so the note still ends at its own time.
                        None => cx.pass(event, at),
                    }
                } else {
                    // Fixed: the input note-off is ignored — the end is already scheduled.
                    // Drop entries whose note has ended, to keep the table for Legato.
                    self.notes.retain(|n| cx.is_sounding(n.id));
                }
            }
            NoteEvent::Expression { .. } => {}
        }
    }

    fn reset(&mut self) {
        self.notes.clear();
    }

    fn discontinuity(&mut self, _cx: &mut NoteCx) {
        // The host already released clip-origin outputs and dropped their scheduled ends;
        // forget the tracked clip notes. Live notes keep playing (REQ-007).
        self.notes.retain(|n| !is_clip_note(n.id));
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.tempo = transport.tempo.max(1.0);
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate as f64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::note_fx::NoteFxHost;
    use crate::audio::devices::AudioDevice;
    use crate::audio::midi_types::CLIP_ID_START;

    const SR: f32 = 48_000.0;
    /// 240 divides every time in the tests: 50 ms = 10 blocks, 1/8 = 50 blocks, 1 s = 200.
    const BLOCK: usize = 240;
    /// 1/8 at 120 BPM = 250 ms.
    const LENGTH_1_8: u64 = 12_000;

    fn device() -> NoteFxHost<NoteLength> {
        let mut d = NoteFxHost::<NoteLength>::new(SR);
        d.set_transport(&Transport {
            tempo: 120.0,
            ..Transport::default()
        });
        d
    }

    fn set(d: &mut NoteFxHost<NoteLength>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    fn press(d: &mut NoteFxHost<NoteLength>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::On {
                note_id: id,
                key,
                velocity: 0.8,
            },
            frame,
        );
    }

    fn release(d: &mut NoteFxHost<NoteLength>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::Off {
                note_id: id,
                key,
                release: 0.5,
            },
            frame,
        );
    }

    /// Absolute `(sample, is_on, key)` of everything the device emits over `blocks` blocks
    /// starting at block `from`.
    fn collect(
        d: &mut NoteFxHost<NoteLength>,
        from: usize,
        blocks: usize,
    ) -> Vec<(usize, bool, u8)> {
        let mut out = Vec::new();
        for b in from..from + blocks {
            for n in d.process_notes(BLOCK) {
                let at = b * BLOCK + n.frame;
                match n.event {
                    NoteEvent::On { key, .. } => out.push((at, true, key)),
                    NoteEvent::Off { key, .. } => out.push((at, false, key)),
                    _ => {}
                }
            }
        }
        out
    }

    /// The note-offs of a `collect` result.
    fn offs(events: &[(usize, bool, u8)]) -> Vec<(usize, u8)> {
        events.iter().filter(|e| !e.1).map(|e| (e.0, e.2)).collect()
    }

    #[test]
    fn the_default_length_rate_is_one_eighth() {
        assert_eq!(RATE_CHOICES[LENGTH_RATE_DEFAULT as usize], "1/8");
        assert_eq!(rate_to_beats(LENGTH_RATE_DEFAULT as usize), 0.5);
    }

    #[test]
    fn fixed_makes_short_and_long_inputs_last_exactly_length() {
        // REQ-029 at 120 BPM, Fixed 1/8 (defaults): an input lasting 50 ms and one lasting
        // 1 s both produce a 250 ms note.
        let mut d = device();
        press(&mut d, 1, 60, 0);
        assert_eq!(collect(&mut d, 0, 1), vec![(0, true, 60)]);
        // The input note-off arrives after 50 ms; the note still ends at 250 ms.
        collect(&mut d, 1, 9);
        release(&mut d, 1, 60, 0);
        let events = collect(&mut d, 10, 41);
        assert_eq!(offs(&events), vec![(LENGTH_1_8 as usize, 60)]);

        // A second, much longer input: the note-off arrives long after Length is over and is
        // ignored, so the note also lasts exactly 250 ms.
        press(&mut d, 2, 62, 0);
        assert_eq!(collect(&mut d, 51, 1), vec![(51 * BLOCK, true, 62)]);
        let events = collect(&mut d, 52, 50);
        assert_eq!(offs(&events), vec![(51 * BLOCK + LENGTH_1_8 as usize, 62)]);
        // The input note-off 1 s after the note-on: nothing.
        collect(&mut d, 102, 149);
        release(&mut d, 2, 62, 0);
        assert!(offs(&collect(&mut d, 251, 2)).is_empty());
    }

    #[test]
    fn minimum_holds_short_notes_for_length_and_long_ones_for_their_own_length() {
        // REQ-029 at 120 BPM, Minimum 1/8: the 50 ms input lasts 250 ms, the 1 s input 1 s.
        let mut d = device();
        set(&mut d, MODE, 1.0);
        press(&mut d, 1, 60, 0);
        assert_eq!(collect(&mut d, 0, 1), vec![(0, true, 60)]);
        // The input note-off arrives after 50 ms; the note lasts Length.
        collect(&mut d, 1, 9);
        release(&mut d, 1, 60, 0);
        let events = collect(&mut d, 10, 41);
        assert_eq!(offs(&events), vec![(LENGTH_1_8 as usize, 60)]);

        press(&mut d, 2, 62, 0);
        assert_eq!(collect(&mut d, 51, 1), vec![(51 * BLOCK, true, 62)]);
        // Held for 1 s: it ends at its own note-off, not at Length.
        collect(&mut d, 52, 199);
        release(&mut d, 2, 62, 0);
        assert_eq!(offs(&collect(&mut d, 251, 1)), vec![(60240, 62)]);
    }

    #[test]
    fn legato_ends_every_sounding_note_at_the_new_note_on() {
        // Fixed mode.
        let mut d = device();
        set(&mut d, LEGATO, 1.0);
        press(&mut d, 1, 60, 0);
        assert_eq!(collect(&mut d, 0, 1), vec![(0, true, 60)]);
        // A second note-on at sample 240 ends the first note at that sample, before it starts.
        press(&mut d, 2, 64, 0);
        assert_eq!(
            collect(&mut d, 1, 1),
            vec![(BLOCK, false, 60), (BLOCK, true, 64)]
        );

        // The same in Minimum mode, on a fresh device.
        let mut d = device();
        set(&mut d, MODE, 1.0);
        set(&mut d, LEGATO, 1.0);
        press(&mut d, 1, 60, 0);
        assert_eq!(collect(&mut d, 0, 1), vec![(0, true, 60)]);
        press(&mut d, 2, 67, 0);
        assert_eq!(
            collect(&mut d, 1, 1),
            vec![(BLOCK, false, 60), (BLOCK, true, 67)]
        );
    }

    #[test]
    fn unsynced_length_is_milliseconds() {
        let mut d = device();
        set(&mut d, SYNC, 0.0);
        set(&mut d, LENGTH, 100.0); // 4800 frames at 48 kHz.
        press(&mut d, 1, 60, 0);
        assert_eq!(collect(&mut d, 0, 1), vec![(0, true, 60)]);
        // The input note-off lands exactly on Length: exactly one note-off comes out.
        collect(&mut d, 1, 19);
        release(&mut d, 1, 60, 0);
        assert_eq!(offs(&collect(&mut d, 20, 1)), vec![(4800, 60)]);
    }

    #[test]
    fn minimum_off_at_exactly_length_is_not_duplicated() {
        let mut d = device();
        set(&mut d, MODE, 1.0);
        press(&mut d, 1, 60, 0);
        collect(&mut d, 0, 1);
        // The input note-off lands exactly on note-on + Length.
        collect(&mut d, 1, 49);
        release(&mut d, 1, 60, 0);
        assert_eq!(
            offs(&collect(&mut d, 50, 1)),
            vec![(LENGTH_1_8 as usize, 60)]
        );
    }

    #[test]
    fn transport_stop_releases_clip_notes_but_live_notes_keep_their_ends() {
        let mut d = device();
        // Fixed mode: the live note has its end scheduled at Length.
        // A live held note.
        press(&mut d, 1, 60, 0);
        assert_eq!(collect(&mut d, 0, 1), vec![(0, true, 60)]);
        // A clip note.
        press(&mut d, CLIP_ID_START, 64, 0);
        assert_eq!(collect(&mut d, 1, 1), vec![(BLOCK, true, 64)]);
        // Stop: the clip note is released at once; the live note still ends at Length.
        d.note_discontinuity();
        let events = collect(&mut d, 2, 60);
        assert_eq!(
            offs(&events),
            vec![(2 * BLOCK, 64), (LENGTH_1_8 as usize, 60)]
        );
    }

    #[test]
    fn reset_forgets_tracked_notes() {
        let mut d = device();
        set(&mut d, MODE, 1.0);
        press(&mut d, 1, 60, 0);
        collect(&mut d, 0, 1);
        d.reset();
        // The tracked note-on is gone, so the input note-off passes through instead.
        release(&mut d, 1, 60, 0);
        let events = collect(&mut d, 1, 1);
        assert_eq!(offs(&events), vec![(BLOCK, 60)]);
    }
}
