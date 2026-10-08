//! Chord (spec 027 REQ-018, REQ-019): add up to six voices above or below each note, with an
//! optional strum. The original note keeps its id, so its note-off ends everything it started.

use super::host::{NoteCx, NoteProcessor};
use crate::audio::devices::param_table::{linear, slot_table, spec, Kind, ParamSpec, ParamTable};
use crate::audio::devices::ParamId;
use crate::audio::midi_types::NoteEvent;

pub const PLAY_ORIGINAL: ParamId = 0;
pub const STRUM: ParamId = 1;
pub const STRUM_DIRECTION: ParamId = 2;
/// Voice `k` (1..=6) has its parameters at `10 k`: on, interval, velocity.
pub const VOICES: usize = 6;
pub const fn voice_on(k: usize) -> ParamId {
    (10 * k) as ParamId
}
pub const fn voice_interval(k: usize) -> ParamId {
    (10 * k + 1) as ParamId
}
pub const fn voice_velocity(k: usize) -> ParamId {
    (10 * k + 2) as ParamId
}

const DIRECTIONS: &[&str] = &["Up", "Down"];

macro_rules! voice_specs {
    ($k:literal, $on_name:literal, $int_name:literal, $vel_name:literal, $group:literal,
     $on:literal, $interval:literal) => {
        [
            spec(voice_on($k), $on_name, $group, "", Kind::Bool, $on as f32),
            spec(
                voice_interval($k),
                $int_name,
                $group,
                "st",
                linear(-24.0, 24.0),
                $interval as f32,
            ),
            spec(
                voice_velocity($k),
                $vel_name,
                $group,
                "%",
                linear(0.0, 100.0),
                100.0,
            ),
        ]
    };
}

const V1: [ParamSpec; 3] = voice_specs!(1, "Voice 1", "Interval 1", "Velocity 1", "Voice 1", 1, 4);
const V2: [ParamSpec; 3] = voice_specs!(2, "Voice 2", "Interval 2", "Velocity 2", "Voice 2", 1, 7);
const V3: [ParamSpec; 3] = voice_specs!(3, "Voice 3", "Interval 3", "Velocity 3", "Voice 3", 0, 11);
const V4: [ParamSpec; 3] = voice_specs!(4, "Voice 4", "Interval 4", "Velocity 4", "Voice 4", 0, 12);
const V5: [ParamSpec; 3] =
    voice_specs!(5, "Voice 5", "Interval 5", "Velocity 5", "Voice 5", 0, -12);
const V6: [ParamSpec; 3] = voice_specs!(6, "Voice 6", "Interval 6", "Velocity 6", "Voice 6", 0, 0);

const MAIN: [ParamSpec; 3] = [
    spec(PLAY_ORIGINAL, "Play Original", "Chord", "", Kind::Bool, 1.0),
    spec(STRUM, "Strum", "Chord", "ms", linear(0.0, 500.0), 0.0),
    spec(
        STRUM_DIRECTION,
        "Strum Direction",
        "Chord",
        "",
        Kind::Enum(DIRECTIONS),
        0.0,
    ),
];

const SPECS: [ParamSpec; 21] =
    crate::audio::devices::param_table::flatten(&[&MAIN, &V1, &V2, &V3, &V4, &V5, &V6]);
const SLOTS: [u8; 63] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

#[derive(Clone, Copy)]
struct Voice {
    on: bool,
    interval: i32,
    velocity: f32,
}

pub struct Chord {
    sample_rate: f32,
    play_original: bool,
    strum_ms: f32,
    strum_down: bool,
    voices: [Voice; VOICES],
}

/// One output of an input note: pitch, velocity, and whether it is the original.
#[derive(Clone, Copy)]
struct Out {
    key: i32,
    velocity: f32,
    original: bool,
}

impl NoteProcessor for Chord {
    fn new(sample_rate: f32) -> Self {
        Self {
            sample_rate,
            play_original: true,
            strum_ms: 0.0,
            strum_down: false,
            voices: [Voice {
                on: false,
                interval: 0,
                velocity: 1.0,
            }; VOICES],
        }
    }

    fn device_id() -> &'static str {
        "sonara.builtin.chord"
    }

    fn device_name() -> &'static str {
        "Chord"
    }

    fn table() -> &'static ParamTable {
        &TABLE
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            PLAY_ORIGINAL => self.play_original = real >= 0.5,
            STRUM => self.strum_ms = real,
            STRUM_DIRECTION => self.strum_down = real >= 0.5,
            _ => {
                let k = id as usize / 10;
                if !(1..=VOICES).contains(&k) {
                    return;
                }
                let voice = &mut self.voices[k - 1];
                match id as usize % 10 {
                    0 => voice.on = real >= 0.5,
                    1 => voice.interval = real.round() as i32,
                    2 => voice.velocity = real / 100.0,
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
                // Gather the distinct pitches (no allocation: at most 7).
                let mut outs = [Out {
                    key: 0,
                    velocity: 0.0,
                    original: false,
                }; VOICES + 1];
                let mut n = 0;
                let add = |out: Out, outs: &mut [Out; VOICES + 1], n: &mut usize| {
                    if !(0..=127).contains(&out.key) || outs[..*n].iter().any(|o| o.key == out.key)
                    {
                        return;
                    }
                    outs[*n] = out;
                    *n += 1;
                };
                if self.play_original {
                    add(
                        Out {
                            key: key as i32,
                            velocity,
                            original: true,
                        },
                        &mut outs,
                        &mut n,
                    );
                }
                for voice in self.voices.iter().filter(|v| v.on) {
                    add(
                        Out {
                            key: key as i32 + voice.interval,
                            velocity: (velocity * voice.velocity).clamp(0.0, 1.0),
                            original: false,
                        },
                        &mut outs,
                        &mut n,
                    );
                }
                // Lowest to highest, or highest to lowest for Down. Insertion sort: tiny n.
                let outs = &mut outs[..n];
                for i in 1..n {
                    let mut j = i;
                    while j > 0 && outs[j - 1].key > outs[j].key {
                        outs.swap(j - 1, j);
                        j -= 1;
                    }
                }
                if self.strum_down {
                    outs.reverse();
                }
                let strum_samples = self.strum_ms as f64 * 0.001 * self.sample_rate as f64;
                for (i, out) in outs.iter().enumerate() {
                    let offset = if n > 1 {
                        (strum_samples * i as f64 / (n - 1) as f64).round() as u64
                    } else {
                        0
                    };
                    if out.original {
                        cx.emit_on_with(note_id, out.key, out.velocity, at + offset, note_id);
                    } else {
                        cx.emit_on(out.key, out.velocity, at + offset, note_id);
                    }
                }
            }
            NoteEvent::Off {
                note_id, release, ..
            } => cx.release_children(note_id, at, release),
            NoteEvent::Expression { .. } => {}
        }
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

    fn device() -> NoteFxHost<Chord> {
        let mut d = NoteFxHost::<Chord>::new(SR);
        // Start from a clean chord: no default voices.
        set(&mut d, voice_on(1), 0.0);
        set(&mut d, voice_on(2), 0.0);
        d
    }

    fn set(d: &mut NoteFxHost<Chord>, id: ParamId, real: f32) {
        d.set_parameter(id, TABLE.spec(id).unwrap().to_norm(real));
    }

    fn note_on(d: &mut NoteFxHost<Chord>, id: u32, key: u8, velocity: f32, frame: usize) {
        d.send_note_event(
            &NoteEvent::On {
                note_id: id,
                key,
                velocity,
            },
            frame,
        );
    }

    fn note_off(d: &mut NoteFxHost<Chord>, id: u32, key: u8, frame: usize) {
        d.send_note_event(
            &NoteEvent::Off {
                note_id: id,
                key,
                release: 0.5,
            },
            frame,
        );
    }

    /// `(frame, key, velocity)` of the note-ons in one block.
    fn ons(d: &mut NoteFxHost<Chord>, block: usize) -> Vec<(usize, u8, f32)> {
        d.process_notes(block)
            .iter()
            .filter_map(|n| match n.event {
                NoteEvent::On { key, velocity, .. } => Some((n.frame, key, velocity)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn voices_add_notes_at_scaled_velocities() {
        let mut d = device();
        set(&mut d, voice_on(1), 1.0);
        set(&mut d, voice_interval(1), 4.0);
        set(&mut d, voice_on(2), 1.0);
        set(&mut d, voice_interval(2), 7.0);
        set(&mut d, voice_velocity(2), 50.0);
        note_on(&mut d, 1, 60, 0.8, 0);
        let out = ons(&mut d, 64);
        assert_eq!(out.len(), 3);
        assert_eq!((out[0].1, out[0].2), (60, 0.8));
        assert_eq!((out[1].1, out[1].2), (64, 0.8));
        assert_eq!(out[2].1, 67);
        assert!((out[2].2 - 0.4).abs() < 1e-6);
    }

    #[test]
    fn voices_on_the_same_pitch_play_once() {
        let mut d = device();
        for k in [1, 2] {
            set(&mut d, voice_on(k), 1.0);
            set(&mut d, voice_interval(k), 12.0);
        }
        note_on(&mut d, 1, 60, 0.8, 0);
        let keys: Vec<u8> = ons(&mut d, 64).iter().map(|o| o.1).collect();
        assert_eq!(keys, vec![60, 72]);

        // Without the original, a voice on the same pitch as it still plays once.
        let mut d = device();
        set(&mut d, PLAY_ORIGINAL, 0.0);
        set(&mut d, voice_on(1), 1.0);
        set(&mut d, voice_interval(1), 0.0);
        note_on(&mut d, 1, 60, 0.8, 0);
        let keys: Vec<u8> = ons(&mut d, 64).iter().map(|o| o.1).collect();
        assert_eq!(keys, vec![60]);
    }

    #[test]
    fn a_single_voice_without_the_original_plays_only_the_voice() {
        let mut d = device();
        set(&mut d, PLAY_ORIGINAL, 0.0);
        set(&mut d, voice_on(1), 1.0);
        set(&mut d, voice_interval(1), 12.0);
        note_on(&mut d, 1, 60, 0.8, 0);
        let keys: Vec<u8> = ons(&mut d, 64).iter().map(|o| o.1).collect();
        assert_eq!(keys, vec![72]);
    }

    #[test]
    fn strum_spreads_outputs_evenly_from_low_to_high() {
        let mut d = device();
        set(&mut d, voice_on(1), 1.0);
        set(&mut d, voice_interval(1), 4.0);
        set(&mut d, voice_on(2), 1.0);
        set(&mut d, voice_interval(2), 7.0);
        set(&mut d, STRUM, 100.0);
        note_on(&mut d, 1, 60, 0.8, 10);
        let mut starts = Vec::new();
        for block in 0..10 {
            for (frame, key, _) in ons(&mut d, 1024) {
                starts.push((block * 1024 + frame, key));
            }
        }
        assert_eq!(starts, vec![(10, 60), (10 + 2400, 64), (10 + 4800, 67)]);
    }

    #[test]
    fn strum_down_starts_with_the_highest() {
        let mut d = device();
        set(&mut d, voice_on(1), 1.0);
        set(&mut d, voice_interval(1), 4.0);
        set(&mut d, STRUM, 100.0);
        set(&mut d, STRUM_DIRECTION, 1.0);
        note_on(&mut d, 1, 60, 0.8, 0);
        let first = ons(&mut d, 64);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].1, 64);
    }

    #[test]
    fn an_early_note_off_cancels_voices_that_have_not_started() {
        let mut d = device();
        set(&mut d, voice_on(1), 1.0);
        set(&mut d, voice_interval(1), 4.0);
        set(&mut d, voice_on(2), 1.0);
        set(&mut d, voice_interval(2), 7.0);
        set(&mut d, STRUM, 100.0);
        note_on(&mut d, 1, 60, 0.8, 0);
        assert_eq!(ons(&mut d, 1000).len(), 1);
        // Released before the middle voice at 2400.
        note_off(&mut d, 1, 60, 0);
        let rest = d.process_notes(1000).to_vec();
        assert!(rest
            .iter()
            .all(|n| matches!(n.event, NoteEvent::Off { .. })));
        let mut later = 0;
        for _ in 0..10 {
            later += ons(&mut d, 1024).len();
        }
        assert_eq!(later, 0, "cancelled voices started");
    }

    #[test]
    fn the_note_off_ends_every_output() {
        let mut d = device();
        set(&mut d, voice_on(1), 1.0);
        set(&mut d, voice_interval(1), 4.0);
        note_on(&mut d, 1, 60, 0.8, 0);
        d.process_notes(64);
        note_off(&mut d, 1, 60, 5);
        let offs: Vec<u8> = d
            .process_notes(64)
            .iter()
            .filter_map(|n| match n.event {
                NoteEvent::Off { key, .. } => Some(key),
                _ => None,
            })
            .collect();
        assert_eq!(offs.len(), 2);
        assert!(offs.contains(&60) && offs.contains(&64));
    }
}
