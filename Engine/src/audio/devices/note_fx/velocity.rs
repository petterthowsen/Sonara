//! Velocity (spec 027 REQ-017): reshape note-on velocities with a curve, an output range and
//! a random offset. Release velocities pass unchanged.

use super::host::{NoteCx, NoteProcessor};
use crate::audio::devices::param_table::{linear, slot_table, spec, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::dsp::Rng;
use crate::audio::midi_types::NoteEvent;

pub const CURVE: ParamId = 0;
pub const OUT_LOW: ParamId = 1;
pub const OUT_HIGH: ParamId = 2;
pub const RANDOM: ParamId = 3;

/// A note-on never leaves quieter than this, so it can't read as a note-off downstream.
const MIN_VELOCITY: f32 = 1.0 / 127.0;

const SPECS: [ParamSpec; 4] = [
    spec(CURVE, "Curve", "Velocity", "%", linear(-100.0, 100.0), 0.0),
    spec(OUT_LOW, "Out Low", "Velocity", "%", linear(0.0, 100.0), 0.0),
    spec(
        OUT_HIGH,
        "Out High",
        "Velocity",
        "%",
        linear(0.0, 100.0),
        100.0,
    ),
    spec(RANDOM, "Random", "Velocity", "%", linear(0.0, 100.0), 0.0),
];
const SLOTS: [u8; 4] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

pub struct Velocity {
    /// Exponent from Curve: `4^(−curve)`, 1 = linear.
    exponent: f32,
    low: f32,
    high: f32,
    random: f32,
    rng: Rng,
}

impl Velocity {
    fn shape(&mut self, velocity: f32) -> f32 {
        let curved = velocity.clamp(0.0, 1.0).powf(self.exponent);
        let mut out = self.low + (self.high - self.low) * curved;
        if self.random > 0.0 {
            out += self.rng.bipolar() * self.random;
        }
        let (lo, hi) = (self.low.min(self.high), self.low.max(self.high));
        out.clamp(lo, hi).max(MIN_VELOCITY)
    }
}

impl NoteProcessor for Velocity {
    fn new(_sample_rate: f32) -> Self {
        Self {
            exponent: 1.0,
            low: 0.0,
            high: 1.0,
            random: 0.0,
            rng: Rng::new(0x5EED_0017),
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.velocity"
    }

    fn device_name() -> &'static str {
        "Velocity"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            CURVE => self.exponent = 4f32.powf(-real / 100.0),
            OUT_LOW => self.low = real / 100.0,
            OUT_HIGH => self.high = real / 100.0,
            RANDOM => self.random = real / 100.0,
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
                let velocity = self.shape(velocity);
                cx.emit_on_with(note_id, key as i32, velocity, at, note_id);
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

    fn device() -> NoteFxHost<Velocity> {
        NoteFxHost::new(48_000.0)
    }

    fn set(d: &mut NoteFxHost<Velocity>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    fn velocities(d: &mut NoteFxHost<Velocity>, inputs: &[f32]) -> Vec<f32> {
        for (i, &v) in inputs.iter().enumerate() {
            d.send_note_event(
                &NoteEvent::On {
                    note_id: 1 + i as u32,
                    key: (i % 128) as u8,
                    velocity: v,
                },
                0,
            );
        }
        let out: Vec<f32> = d
            .process_notes(64)
            .iter()
            .filter_map(|n| match n.event {
                NoteEvent::On { velocity, .. } => Some(velocity),
                _ => None,
            })
            .collect();
        // Release them so the next call starts empty.
        for i in 0..inputs.len() {
            d.send_note_event(
                &NoteEvent::Off {
                    note_id: 1 + i as u32,
                    key: (i % 128) as u8,
                    release: 0.5,
                },
                0,
            );
        }
        d.process_notes(64);
        out
    }

    #[test]
    fn maps_into_the_output_range() {
        let mut d = device();
        set(&mut d, OUT_LOW, 50.0);
        set(&mut d, OUT_HIGH, 100.0);
        let out = velocities(&mut d, &[0.0, 1.0]);
        assert!(
            (out[0] - 0.5).abs() < 1e-5 && (out[1] - 1.0).abs() < 1e-5,
            "{out:?}"
        );
    }

    #[test]
    fn equal_low_and_high_fix_the_velocity() {
        let mut d = device();
        set(&mut d, OUT_LOW, 80.0);
        set(&mut d, OUT_HIGH, 80.0);
        for v in velocities(&mut d, &[0.1, 0.5, 1.0]) {
            assert!((v - 0.8).abs() < 1e-5);
        }
    }

    #[test]
    fn random_stays_within_its_spread() {
        let mut d = device();
        set(&mut d, RANDOM, 20.0);
        let mut all = Vec::new();
        for _ in 0..10 {
            all.extend(velocities(&mut d, &[0.5; 100]));
        }
        assert_eq!(all.len(), 1000);
        assert!(all.iter().all(|&v| (0.3 - 1e-5..=0.7 + 1e-5).contains(&v)));
        assert!(
            all.iter().any(|&v| (v - 0.5).abs() > 0.05),
            "random did nothing"
        );
    }

    #[test]
    fn curve_bends_and_release_is_untouched() {
        let mut d = device();
        set(&mut d, CURVE, 100.0);
        let out = velocities(&mut d, &[0.5]);
        assert!((out[0] - 0.5f32.powf(0.25)).abs() < 1e-5);

        let mut d = device();
        set(&mut d, OUT_LOW, 80.0);
        d.send_note_event(
            &NoteEvent::On {
                note_id: 1,
                key: 60,
                velocity: 0.2,
            },
            0,
        );
        d.process_notes(64);
        d.send_note_event(
            &NoteEvent::Off {
                note_id: 1,
                key: 60,
                release: 0.33,
            },
            0,
        );
        let off = d.process_notes(64).to_vec();
        assert!(
            matches!(off[0].event, NoteEvent::Off { release, .. } if (release - 0.33).abs() < 1e-6)
        );
    }

    #[test]
    fn zero_velocity_never_becomes_a_note_off() {
        let mut d = device();
        let out = velocities(&mut d, &[0.0]);
        assert!(out[0] >= MIN_VELOCITY);
    }
}
