//! Note Filter (spec 027 REQ-016): pass note-ons inside a key range and a velocity range, or
//! only those outside with Invert. A note-off follows its note-on whatever the ranges are by
//! then (REQ-004).

use super::host::{NoteCx, NoteProcessor};
use crate::audio::devices::param_table::{linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::midi_types::NoteEvent;

pub const KEY_LOW: ParamId = 0;
pub const KEY_HIGH: ParamId = 1;
pub const VELOCITY_LOW: ParamId = 2;
pub const VELOCITY_HIGH: ParamId = 3;
pub const INVERT: ParamId = 4;

const SPECS: [ParamSpec; 5] = [
    spec(KEY_LOW, "Key Low", "Keys", "key", linear(0.0, 127.0), 0.0),
    spec(
        KEY_HIGH,
        "Key High",
        "Keys",
        "key",
        linear(0.0, 127.0),
        127.0,
    ),
    spec(
        VELOCITY_LOW,
        "Velocity Low",
        "Velocity",
        "%",
        linear(0.0, 100.0),
        0.0,
    ),
    spec(
        VELOCITY_HIGH,
        "Velocity High",
        "Velocity",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(INVERT, "Invert", "Filter", "", Kind::Bool, 0.0),
];
const SLOTS: [u8; 5] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

pub struct NoteFilter {
    key_low: i32,
    key_high: i32,
    velocity_low: f32,
    velocity_high: f32,
    invert: bool,
}

impl NoteFilter {
    fn passes(&self, key: u8, velocity: f32) -> bool {
        let key = key as i32;
        let inside = (self.key_low..=self.key_high).contains(&key)
            && velocity >= self.velocity_low - 1e-6
            && velocity <= self.velocity_high + 1e-6;
        inside != self.invert
    }
}

impl NoteProcessor for NoteFilter {
    fn new(_sample_rate: f32) -> Self {
        Self {
            key_low: 0,
            key_high: 127,
            velocity_low: 0.0,
            velocity_high: 1.0,
            invert: false,
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.note_filter"
    }

    fn device_name() -> &'static str {
        "Note Filter"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            KEY_LOW => self.key_low = real.round() as i32,
            KEY_HIGH => self.key_high = real.round() as i32,
            VELOCITY_LOW => self.velocity_low = real / 100.0,
            VELOCITY_HIGH => self.velocity_high = real / 100.0,
            INVERT => self.invert = real >= 0.5,
            _ => {}
        }
    }

    fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64) {
        match *event {
            NoteEvent::On { key, velocity, .. } => {
                if self.passes(key, velocity) {
                    cx.pass(event, at);
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

    fn device() -> NoteFxHost<NoteFilter> {
        let mut d = NoteFxHost::new(48_000.0);
        set(&mut d, KEY_LOW, 48.0);
        set(&mut d, KEY_HIGH, 59.0);
        d
    }

    fn set(d: &mut NoteFxHost<NoteFilter>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    fn on(id: u32, key: u8) -> NoteEvent {
        NoteEvent::On {
            note_id: id,
            key,
            velocity: 0.8,
        }
    }

    fn keys_out(d: &mut NoteFxHost<NoteFilter>) -> Vec<(u8, bool)> {
        d.process_notes(64)
            .iter()
            .map(|n| (n.event.key(), matches!(n.event, NoteEvent::On { .. })))
            .collect()
    }

    #[test]
    fn key_range_and_invert() {
        let mut d = device();
        d.send_note_event(&on(1, 50), 0);
        d.send_note_event(&on(2, 60), 0);
        assert_eq!(keys_out(&mut d), vec![(50, true)]);

        let mut d = device();
        set(&mut d, INVERT, 1.0);
        d.send_note_event(&on(1, 50), 0);
        d.send_note_event(&on(2, 60), 0);
        assert_eq!(keys_out(&mut d), vec![(60, true)]);
    }

    #[test]
    fn note_off_passes_after_the_range_changes() {
        let mut d = device();
        d.send_note_event(&on(1, 50), 0);
        keys_out(&mut d);
        set(&mut d, KEY_LOW, 60.0);
        set(&mut d, KEY_HIGH, 72.0);
        d.send_note_event(
            &NoteEvent::Off {
                note_id: 1,
                key: 50,
                release: 0.5,
            },
            0,
        );
        assert_eq!(keys_out(&mut d), vec![(50, false)]);
    }

    #[test]
    fn velocity_range() {
        let mut d = device();
        set(&mut d, VELOCITY_LOW, 50.0);
        d.send_note_event(
            &NoteEvent::On {
                note_id: 1,
                key: 50,
                velocity: 0.3,
            },
            0,
        );
        d.send_note_event(&on(2, 51), 0);
        assert_eq!(keys_out(&mut d), vec![(51, true)]);
    }
}
