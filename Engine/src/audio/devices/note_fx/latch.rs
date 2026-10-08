//! Latch (spec 027 REQ-030, REQ-012): holds notes after their keys are released.
//!
//! **Chord** mode keeps a released chord sounding until the next note-on arrives while no keys
//! are physically down; that releases the held chord and starts the new note. **Toggle** mode
//! starts a note on a key's note-on and ends it on the next note-on for the same key. In both
//! modes the input note-off is swallowed — the latched note keeps sounding downstream (the host
//! stops treating the input note as held, so nothing else can end it). **Release All** is a
//! momentary parameter: its 0→1 transition releases every latched note in the next note phase.

use super::host::{NoteCx, NoteProcessor};
use crate::audio::devices::param_table::{slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::midi_types::{NoteEvent, DEFAULT_RELEASE};

pub const MODE: ParamId = 0;
pub const RELEASE_ALL: ParamId = 1;

const MODES: [&str; 2] = ["Chord", "Toggle"];
/// Physically down input ids and latched (sounding) notes, one per key.
const KEYS: usize = 128;

const SPECS: [ParamSpec; 2] = [
    spec(MODE, "Mode", "Mode", "", Kind::Enum(&MODES), 0.0),
    spec(
        RELEASE_ALL,
        "Release All",
        "Release All",
        "",
        Kind::Bool,
        0.0,
    )
    .not_automatable(),
];
const SLOTS: [u8; 2] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

pub struct Latch {
    mode: usize,
    /// `None` until the first `apply`, so the initial parameter load can't trigger a release.
    release_all_down: Option<bool>,
    release_requested: bool,
    /// Input ids whose keys are physically down (Chord mode's replacement trigger).
    down: Vec<u32>,
    /// Latched notes: output id (the input id, REQ-005) and key.
    latched: Vec<(u32, u8)>,
}

impl NoteProcessor for Latch {
    fn new(_sample_rate: f32) -> Self {
        Self {
            mode: 0,
            release_all_down: None,
            release_requested: false,
            down: Vec::with_capacity(KEYS),
            latched: Vec::with_capacity(KEYS),
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.latch"
    }

    fn device_name() -> &'static str {
        "Latch"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            MODE => self.mode = real.max(0.0) as usize % 2,
            RELEASE_ALL => {
                // `apply` cannot emit: queue the release for the next note phase.
                let down = real >= 0.5;
                if self.release_all_down == Some(false) && down {
                    self.release_requested = true;
                }
                self.release_all_down = Some(down);
            }
            _ => {}
        }
    }

    fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64) {
        match *event {
            NoteEvent::On {
                note_id,
                key,
                velocity,
            } => match self.mode {
                0 => {
                    // No keys physically down: the held chord ends and this note replaces it.
                    if self.down.is_empty() {
                        for &(id, _) in self.latched.iter() {
                            cx.emit_off(id, at, DEFAULT_RELEASE);
                        }
                        self.latched.clear();
                    }
                    if self.down.len() == self.down.capacity() {
                        return;
                    }
                    self.down.push(note_id);
                    if cx.emit_on_with(note_id, key as i32, velocity, at, note_id) {
                        self.latched.push((note_id, key));
                    }
                }
                _ => {
                    // A key already latched ends its note; otherwise it starts one.
                    if let Some(i) = self.latched.iter().position(|&(_, k)| k == key) {
                        let (id, _) = self.latched.remove(i);
                        cx.emit_off(id, at, DEFAULT_RELEASE);
                    } else if cx.emit_on_with(note_id, key as i32, velocity, at, note_id) {
                        if self.latched.len() == self.latched.capacity() {
                            self.latched.remove(0);
                        }
                        self.latched.push((note_id, key));
                    }
                }
            },
            NoteEvent::Off { note_id, .. } => {
                // Swallowed: the latched note keeps sounding past the key release.
                if let Some(i) = self.down.iter().position(|&id| id == note_id) {
                    self.down.remove(i);
                }
            }
            NoteEvent::Expression { .. } => {}
        }
    }

    fn run_until(&mut self, cx: &mut NoteCx, _until: u64) {
        if !self.release_requested {
            return;
        }
        self.release_requested = false;
        // As soon as the host lets us emit: the end of the current note phase.
        let at = cx.now();
        for &(id, _) in self.latched.iter() {
            cx.emit_off(id, at, DEFAULT_RELEASE);
        }
        self.latched.clear();
    }

    fn reset(&mut self) {
        self.down.clear();
        self.latched.clear();
        self.release_requested = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::note_fx::NoteFxHost;
    use crate::audio::devices::AudioDevice;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 256;

    fn on(id: u32, key: u8) -> NoteEvent {
        NoteEvent::On {
            note_id: id,
            key,
            velocity: 0.8,
        }
    }

    fn off(id: u32, key: u8) -> NoteEvent {
        NoteEvent::Off {
            note_id: id,
            key,
            release: DEFAULT_RELEASE,
        }
    }

    fn set_mode(d: &mut NoteFxHost<Latch>, index: usize) {
        d.set_parameter(MODE, TABLE.spec(MODE).unwrap().to_norm(index as f32));
    }

    /// Feed `events`, run one block, return the output (id, key, is_on) triples.
    fn run(d: &mut NoteFxHost<Latch>, events: &[NoteEvent]) -> Vec<(u32, u8, bool)> {
        for e in events {
            d.send_note_event(e, 0);
        }
        d.process_notes(BLOCK)
            .iter()
            .map(|n| {
                (
                    n.event.note_id(),
                    n.event.key(),
                    matches!(n.event, NoteEvent::On { .. }),
                )
            })
            .collect()
    }

    #[test]
    fn chord_holds_released_chord_and_replaces_on_next_press() {
        let mut d = NoteFxHost::<Latch>::new(SR);
        // REQ-030: press and release 60 and 64; both keep sounding.
        assert_eq!(
            run(&mut d, &[on(1, 60), on(2, 64)]),
            vec![(1, 60, true), (2, 64, true)]
        );
        assert_eq!(run(&mut d, &[off(1, 60), off(2, 64)]), vec![]);
        // After all keys are released, pressing 67 ends 60 and 64.
        assert_eq!(
            run(&mut d, &[on(3, 67)]),
            vec![(1, 60, false), (2, 64, false), (3, 67, true)]
        );
    }

    #[test]
    fn toggle_ends_a_latched_key_on_the_next_press() {
        let mut d = NoteFxHost::<Latch>::new(SR);
        set_mode(&mut d, 1);
        // REQ-030: press 60, it sounds; press 60 again, it ends.
        assert_eq!(run(&mut d, &[on(1, 60)]), vec![(1, 60, true)]);
        assert_eq!(run(&mut d, &[on(2, 60)]), vec![(1, 60, false)]);
        // The key is free again, so pressing it starts a new note.
        assert_eq!(run(&mut d, &[on(3, 60)]), vec![(3, 60, true)]);
    }

    #[test]
    fn release_all_releases_every_latched_note_once() {
        let mut d = NoteFxHost::<Latch>::new(SR);
        assert_eq!(
            run(&mut d, &[on(1, 60), on(2, 64)]),
            vec![(1, 60, true), (2, 64, true)]
        );
        assert_eq!(run(&mut d, &[off(1, 60), off(2, 64)]), vec![]);
        d.set_parameter(RELEASE_ALL, TABLE.spec(RELEASE_ALL).unwrap().to_norm(1.0));
        assert_eq!(run(&mut d, &[]), vec![(1, 60, false), (2, 64, false)]);
        // Momentary: it has already been released, so nothing more goes out.
        assert_eq!(run(&mut d, &[]), vec![]);
        // And the note-ons after it are not treated as replacements of anything.
        assert_eq!(run(&mut d, &[on(3, 67)]), vec![(3, 67, true)]);
    }
}
