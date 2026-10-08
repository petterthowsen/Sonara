//! Chance (spec 027 REQ-028): pass each note-on with a probability. A note-off passes only if
//! its note-on did, which the host gives for free: a dropped note-on never enters the sounding
//! table, so its note-off has nothing to release.

use super::host::{NoteCx, NoteProcessor};
use crate::audio::devices::param_table::{linear, slot_table, spec, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::dsp::Rng;
use crate::audio::midi_types::NoteEvent;

pub const CHANCE: ParamId = 0;

const SPECS: [ParamSpec; 1] = [spec(
    CHANCE,
    "Chance",
    "Chance",
    "%",
    linear(0.0, 100.0),
    100.0,
)];
const SLOTS: [u8; 1] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

pub struct Chance {
    probability: f32,
    rng: Rng,
}

impl NoteProcessor for Chance {
    fn new(_sample_rate: f32) -> Self {
        Self {
            probability: 1.0,
            rng: Rng::new(0xC4A7_CE01),
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.chance"
    }

    fn device_name() -> &'static str {
        "Chance"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        if id == CHANCE {
            self.probability = real / 100.0;
        }
    }

    fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64) {
        match *event {
            NoteEvent::On {
                note_id,
                key,
                velocity,
            } => {
                // `next_f32` is in [0, 1): 100 % always passes, 0 % never does.
                if self.rng.next_f32() < self.probability {
                    cx.emit_on_with(note_id, key as i32, velocity, at, note_id);
                }
            }
            NoteEvent::Off {
                note_id, release, ..
            } => cx.release_children(note_id, at, release),
            NoteEvent::Expression { .. } => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::note_fx::NoteFxHost;
    use crate::audio::devices::AudioDevice;

    fn run(chance: f32, count: u32) -> (Vec<u32>, Vec<u32>, Vec<u32>) {
        let mut d = NoteFxHost::<Chance>::new(48_000.0);
        d.set_parameter(CHANCE, TABLE.spec(CHANCE).unwrap().to_norm(chance));
        let (mut sent, mut ons, mut offs) = (Vec::new(), Vec::new(), Vec::new());
        for batch in 0..count / 100 {
            for i in 0..100 {
                let id = batch * 100 + i + 1;
                d.send_note_event(
                    &NoteEvent::On {
                        note_id: id,
                        key: (i % 128) as u8,
                        velocity: 0.7,
                    },
                    0,
                );
                sent.push(id);
            }
            for n in d.process_notes(64) {
                if let NoteEvent::On { note_id, .. } = n.event {
                    ons.push(note_id);
                }
            }
            for i in 0..100 {
                let id = batch * 100 + i + 1;
                d.send_note_event(
                    &NoteEvent::Off {
                        note_id: id,
                        key: (i % 128) as u8,
                        release: 0.5,
                    },
                    0,
                );
            }
            for n in d.process_notes(64) {
                if let NoteEvent::Off { note_id, .. } = n.event {
                    offs.push(note_id);
                }
            }
        }
        (sent, ons, offs)
    }

    #[test]
    fn zero_percent_passes_nothing_and_full_passes_everything() {
        let (_, ons, offs) = run(0.0, 1000);
        assert!(ons.is_empty() && offs.is_empty());
        let (sent, ons, offs) = run(100.0, 1000);
        assert_eq!(ons.len(), sent.len());
        assert_eq!(offs.len(), sent.len());
    }

    #[test]
    fn half_passes_about_half_and_note_offs_pair_exactly() {
        let (_, ons, mut offs) = run(50.0, 10_000);
        let share = ons.len() as f32 / 10_000.0;
        assert!((0.45..=0.55).contains(&share), "{share}");
        let mut ons = ons;
        ons.sort_unstable();
        offs.sort_unstable();
        assert_eq!(ons, offs);
    }
}
