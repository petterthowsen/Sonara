//! Transpose (spec 027 REQ-014, REQ-015): shift notes by semitones and octaves, optionally
//! snapping to a scale. A changed note keeps its id, and its note-off ends the pitch it
//! actually started on, whatever the parameters are by then (REQ-004).

use super::host::{NoteCx, NoteProcessor};
use super::scale::{mask_for, snap, ROOT_LABELS, SCALE_TYPE_LABELS};
use crate::audio::devices::param_table::{linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::midi_types::NoteEvent;
use crate::audio::transport::Transport;

pub const SEMITONES: ParamId = 0;
pub const OCTAVES: ParamId = 1;
pub const SCALE: ParamId = 10;
pub const ROOT: ParamId = 11;
pub const SCALE_TYPE: ParamId = 12;

const SCALE_MODES: &[&str] = &["Off", "Follow Project", "Custom"];
const MODE_FOLLOW: u8 = 1;
const MODE_CUSTOM: u8 = 2;

const SPECS: [ParamSpec; 5] = [
    spec(
        SEMITONES,
        "Semitones",
        "Transpose",
        "st",
        linear(-48.0, 48.0),
        0.0,
    ),
    spec(
        OCTAVES,
        "Octaves",
        "Transpose",
        "oct",
        linear(-4.0, 4.0),
        0.0,
    ),
    spec(SCALE, "Scale", "Scale", "", Kind::Enum(SCALE_MODES), 0.0),
    spec(ROOT, "Root", "Scale", "", Kind::Enum(&ROOT_LABELS), 0.0),
    spec(
        SCALE_TYPE,
        "Scale Type",
        "Scale",
        "",
        Kind::Enum(&SCALE_TYPE_LABELS),
        0.0,
    ),
];
const SLOTS: [u8; 13] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

pub struct Transpose {
    semitones: i32,
    octaves: i32,
    mode: u8,
    root: usize,
    scale_type: usize,
    project_mask: u16,
}

impl Transpose {
    fn mask(&self) -> u16 {
        match self.mode {
            MODE_FOLLOW => self.project_mask,
            MODE_CUSTOM => mask_for(self.root, self.scale_type),
            _ => 0,
        }
    }
}

impl NoteProcessor for Transpose {
    fn new(_sample_rate: f32) -> Self {
        Self {
            semitones: 0,
            octaves: 0,
            mode: 0,
            root: 0,
            scale_type: 0,
            project_mask: 0,
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.transpose"
    }

    fn device_name() -> &'static str {
        "Transpose"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            SEMITONES => self.semitones = real.round() as i32,
            OCTAVES => self.octaves = real.round() as i32,
            SCALE => self.mode = real as u8,
            ROOT => self.root = real as usize,
            SCALE_TYPE => self.scale_type = real as usize,
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
                let shifted = key as i32 + self.semitones + 12 * self.octaves;
                let key = snap(shifted, self.mask());
                cx.emit_on_with(note_id, key, velocity, at, note_id);
            }
            NoteEvent::Off {
                note_id, release, ..
            } => cx.release_children(note_id, at, release),
            NoteEvent::Expression { .. } => {}
        }
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.project_mask = transport.scale_mask;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::note_fx::NoteFxHost;
    use crate::audio::devices::AudioDevice;

    fn device() -> NoteFxHost<Transpose> {
        NoteFxHost::new(48_000.0)
    }

    fn set(d: &mut NoteFxHost<Transpose>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    /// Keys of the note-ons out of one block after playing `keys`.
    fn play(d: &mut NoteFxHost<Transpose>, keys: &[u8]) -> Vec<u8> {
        for (i, &k) in keys.iter().enumerate() {
            d.send_note_event(
                &NoteEvent::On {
                    note_id: 100 + i as u32,
                    key: k,
                    velocity: 0.8,
                },
                0,
            );
        }
        d.process_notes(64)
            .iter()
            .filter(|n| matches!(n.event, NoteEvent::On { .. }))
            .map(|n| n.event.key())
            .collect()
    }

    #[test]
    fn semitones_and_octaves() {
        let mut d = device();
        set(&mut d, SEMITONES, 3.0);
        set(&mut d, OCTAVES, -1.0);
        assert_eq!(play(&mut d, &[60]), vec![51]);
    }

    #[test]
    fn c_major_snap() {
        let mut d = device();
        set(&mut d, SCALE, MODE_CUSTOM as f32);
        set(&mut d, ROOT, 0.0);
        set(&mut d, SCALE_TYPE, 0.0);
        assert_eq!(play(&mut d, &[61, 66]), vec![60, 65]);
    }

    #[test]
    fn follow_project_without_a_scale_does_not_snap() {
        let mut d = device();
        set(&mut d, SCALE, MODE_FOLLOW as f32);
        d.set_transport(&Transport::default());
        assert_eq!(play(&mut d, &[61]), vec![61]);
        // With the project in D minor, C# snaps down to C.
        d.set_transport(&Transport {
            scale_mask: mask_for(2, 1),
            ..Transport::default()
        });
        assert_eq!(play(&mut d, &[61]), vec![60]);
    }

    #[test]
    fn out_of_range_is_dropped() {
        let mut d = device();
        set(&mut d, SEMITONES, 12.0);
        assert_eq!(play(&mut d, &[120, 100]), vec![112]);
    }

    #[test]
    fn note_off_follows_after_a_parameter_change() {
        let mut d = device();
        set(&mut d, SEMITONES, 12.0);
        assert_eq!(play(&mut d, &[60]), vec![72]);
        set(&mut d, SEMITONES, 7.0);
        d.send_note_event(
            &NoteEvent::Off {
                note_id: 100,
                key: 60,
                release: 0.5,
            },
            4,
        );
        let out = d.process_notes(64).to_vec();
        assert_eq!(out.len(), 1);
        assert!(matches!(
            out[0].event,
            NoteEvent::Off {
                note_id: 100,
                key: 72,
                ..
            }
        ));
        assert_eq!(out[0].frame, 4);
    }
}
