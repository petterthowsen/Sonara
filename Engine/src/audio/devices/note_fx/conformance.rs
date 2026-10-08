//! Conformance checks every built-in note effect in `factory::NOTE_EFFECT_IDS` must pass
//! (spec 027 REQ-006 to REQ-008, REQ-012, REQ-034), bare and wrapped in a `ModulatedDevice`
//! with no routes. A new note effect gets them by being added to that list.
//!
//! The checks run at the effect's default parameters, where every note effect lets a note
//! through. `harness_catches_a_working_note_effect` runs them over the host's test processor,
//! so the harness is exercised even while the list is short.

use std::collections::HashSet;

use crate::audio::devices::{
    create_note_effect, enum_to_norm, norm_to_enum, AudioDevice, DeviceCategory, DevicePath,
    ParamType, NOTE_EFFECT_IDS,
};
use crate::audio::dsp::test_util::{stereo, white_noise};
use crate::audio::midi_types::{NoteEvent, SoundingNoteId, CLIP_ID_START};
use crate::audio::modulation::wrap_at_path;

use super::TimedNote;

const SR: f32 = 48_000.0;
const MAX_FRAMES: usize = 4_096;
const BLOCK: usize = 256;

type Make<'a> = &'a dyn Fn() -> Box<dyn AudioDevice>;

fn make_for(make: Make, wrapped: bool) -> Box<dyn AudioDevice> {
    let device = make();
    if !wrapped {
        return device;
    }
    let mut devices: Vec<Box<dyn AudioDevice>> = vec![device];
    wrap_at_path(&mut devices, &DevicePath::root(0), SR).expect("wrap the note effect");
    devices.pop().expect("wrapped device")
}

fn on(id: SoundingNoteId, key: u8) -> NoteEvent {
    NoteEvent::On {
        note_id: id,
        key,
        velocity: 0.8,
    }
}

fn off(id: SoundingNoteId, key: u8) -> NoteEvent {
    NoteEvent::Off {
        note_id: id,
        key,
        release: 0.5,
    }
}

/// Ids still sounding downstream after `notes`, given the ones before.
fn track(sounding: &mut HashSet<SoundingNoteId>, notes: &[TimedNote]) {
    for note in notes {
        match note.event {
            NoteEvent::On { note_id, .. } => {
                sounding.insert(note_id);
            }
            NoteEvent::Off { note_id, .. } => {
                sounding.remove(&note_id);
            }
            NoteEvent::Expression { .. } => {}
        }
    }
}

/// Play `events` at frame 0 and run a few blocks, tracking what sounds downstream.
fn play(device: &mut dyn AudioDevice, events: &[NoteEvent]) -> HashSet<SoundingNoteId> {
    let mut sounding = HashSet::new();
    for event in events {
        device.send_note_event(event, 0);
    }
    for _ in 0..4 {
        let out = device.process_notes(BLOCK).to_vec();
        track(&mut sounding, &out);
    }
    sounding
}

fn check_category_and_flags(make: Make, wrapped: bool) -> Result<(), String> {
    let device = make_for(make, wrapped);
    if device.device_category() != DeviceCategory::NoteEffect {
        return Err(format!("category is {:?}", device.device_category()));
    }
    if !device.is_note_effect() || !device.accepts_note_input() {
        return Err("doesn't report itself as a note effect taking note input".into());
    }
    Ok(())
}

fn check_audio_passes_bit_exact(make: Make, wrapped: bool) -> Result<(), String> {
    let mut device = make_for(make, wrapped);
    let input = stereo(&white_noise(BLOCK * 4, 0.5, 5));
    let mut output = vec![0.0; input.len()];
    for (i, o) in input.chunks(BLOCK * 2).zip(output.chunks_mut(BLOCK * 2)) {
        device.process_notes(BLOCK);
        device.process_block(i, o, BLOCK);
    }
    if output != input {
        return Err("audio output differs from the input".into());
    }
    Ok(())
}

fn check_bypass_passes_notes(make: Make, wrapped: bool) -> Result<(), String> {
    let mut device = make_for(make, wrapped);
    device.set_enabled(false);
    device.process_notes(BLOCK);
    device.send_note_event(&on(3, 60), 17);
    let out = device.process_notes(BLOCK).to_vec();
    let expected = vec![TimedNote {
        frame: 17,
        event: on(3, 60),
    }];
    if out != expected {
        return Err(format!("bypassed output is {out:?}"));
    }
    Ok(())
}

fn check_bypass_releases(make: Make, wrapped: bool) -> Result<(), String> {
    let mut device = make_for(make, wrapped);
    let mut sounding = play(device.as_mut(), &[on(1, 60), on(2, 64)]);
    if sounding.is_empty() {
        return Err("nothing sounds at the default parameters".into());
    }
    device.set_enabled(false);
    for _ in 0..4 {
        let out = device.process_notes(BLOCK).to_vec();
        track(&mut sounding, &out);
    }
    if !sounding.is_empty() {
        return Err(format!(
            "{} notes left hanging after bypass",
            sounding.len()
        ));
    }
    Ok(())
}

fn check_release_now_releases(make: Make, wrapped: bool) -> Result<(), String> {
    let mut device = make_for(make, wrapped);
    let mut sounding = play(device.as_mut(), &[on(1, 60), on(2, 64)]);
    let released = device.release_notes_now().to_vec();
    if released.iter().any(|n| n.frame != 0) {
        return Err("release-now note-offs aren't at frame 0".into());
    }
    track(&mut sounding, &released);
    for _ in 0..8 {
        let out = device.process_notes(BLOCK).to_vec();
        track(&mut sounding, &out);
        if out.iter().any(|n| matches!(n.event, NoteEvent::On { .. })) {
            return Err("a note started after release-now".into());
        }
    }
    if !sounding.is_empty() {
        return Err(format!(
            "{} notes left hanging after removal",
            sounding.len()
        ));
    }
    Ok(())
}

fn check_stop_releases_clip_notes_only(make: Make, wrapped: bool) -> Result<(), String> {
    use crate::audio::midi_types::is_clip_note;
    let mut device = make_for(make, wrapped);
    let clip = CLIP_ID_START + 11;
    let mut sounding = play(device.as_mut(), &[on(1, 48), on(clip, 60)]);
    // What a transport stop does: the clip note's note-off, then the discontinuity.
    device.send_note_event(&off(clip, 60), 0);
    device.note_discontinuity();
    for _ in 0..4 {
        let out = device.process_notes(BLOCK).to_vec();
        track(&mut sounding, &out);
    }
    if sounding.iter().any(|&id| is_clip_note(id)) {
        return Err("a clip-origin note kept sounding after stop".into());
    }
    if !sounding.iter().any(|&id| !is_clip_note(id)) {
        return Err("the live note was released by stop".into());
    }
    Ok(())
}

fn check_unknown_note_off_passes(make: Make, wrapped: bool) -> Result<(), String> {
    let mut device = make_for(make, wrapped);
    device.send_note_event(&off(99, 70), 9);
    let out = device.process_notes(BLOCK).to_vec();
    let expected = vec![TimedNote {
        frame: 9,
        event: off(99, 70),
    }];
    if out != expected {
        return Err(format!("an unknown note-off came out as {out:?}"));
    }
    Ok(())
}

fn check_never_sleeps(make: Make, wrapped: bool) -> Result<(), String> {
    let mut device = make_for(make, wrapped);
    let silence = vec![0.0; BLOCK * 2];
    let mut out = vec![0.0; BLOCK * 2];
    for _ in 0..((SR as usize * 4) / BLOCK) {
        device.update_sleep_state(false);
        device.process_notes(BLOCK);
        device.process_block(&silence, &mut out, BLOCK);
    }
    if device.is_sleeping() {
        return Err("went to sleep".into());
    }
    Ok(())
}

fn check_parameters_round_trip(make: Make, wrapped: bool) -> Result<(), String> {
    let mut device = make_for(make, wrapped);
    for info in device.parameters() {
        for norm in [0.0, 0.25, 0.5, 0.73, 1.0] {
            device.set_parameter(info.id, norm);
            let got = device
                .get_parameter(info.id)
                .ok_or_else(|| format!("'{}' has no value", info.name))?;
            let expected = match info.param_type {
                ParamType::Float => norm,
                ParamType::Enum => {
                    let n = info.enum_values.len();
                    enum_to_norm(norm_to_enum(norm, n), n)
                }
                ParamType::Bool => (norm >= 0.5) as u8 as f32,
            };
            if (got - expected).abs() > 1e-4 {
                return Err(format!(
                    "'{}' set to {norm} reads back {got} (expected {expected})",
                    info.name
                ));
            }
        }
    }
    Ok(())
}

type Check = fn(Make, bool) -> Result<(), String>;

const CHECKS: &[(&str, Check)] = &[
    ("category and flags", check_category_and_flags),
    ("audio passes bit-exact", check_audio_passes_bit_exact),
    ("bypass passes notes", check_bypass_passes_notes),
    ("bypass releases", check_bypass_releases),
    ("release now releases", check_release_now_releases),
    (
        "stop releases clip notes only",
        check_stop_releases_clip_notes_only,
    ),
    ("unknown note-off passes", check_unknown_note_off_passes),
    ("never sleeps", check_never_sleeps),
    ("parameters round-trip", check_parameters_round_trip),
];

fn failures(name: &str, make: Make) -> Vec<String> {
    let mut failed = Vec::new();
    for wrapped in [false, true] {
        for (check_name, check) in CHECKS {
            if let Err(e) = check(make, wrapped) {
                failed.push(format!("{name} (wrapped: {wrapped}) — {check_name}: {e}"));
            }
        }
    }
    failed
}

#[test]
fn every_builtin_note_effect_conforms() {
    let failed: Vec<String> = NOTE_EFFECT_IDS
        .iter()
        .flat_map(|id| {
            let make = || create_note_effect(id, SR, MAX_FRAMES).expect("a note effect");
            failures(id, &make)
        })
        .collect();
    assert!(failed.is_empty(), "\n{}", failed.join("\n"));
}

#[test]
fn harness_catches_a_working_note_effect() {
    use super::host::tests::test_host;
    let make = || Box::new(test_host(0.0, 0.0, 1.0)) as Box<dyn AudioDevice>;
    let failed = failures("test processor", &make);
    assert!(failed.is_empty(), "\n{}", failed.join("\n"));
}
