# Scale catalogue — Requirements

Extends [026 scale support](../026-scale-support/requirements.md),
[027 note effects](../027-note-effects/requirements.md) (Transpose scale snap) and
[034 key changes](../034-key-changes/requirements.md).

## Problem

The project scale offers 12 scale types: the major and minor family, the church modes, two
pentatonics and blues. Users writing jazz, film, metal or non-Western-flavoured material reach for
melodic minor modes, harmonic minor modes, symmetric and exotic scales and don't find them. Key
names are always spelled with sharps, so F major reads `F G A A# C D E` and there is no
"Eb major" or "Bb minor" anywhere in the UI.

## Scope

| | |
|---|---|
| Subsystem | both (Godot scale catalogue and pickers; engine scale table used by Transpose) |
| Touches real-time audio thread | no new work. Transpose reads a longer static table |
| Adds or changes an OSC message | no. `/project/scale` and key changes already send a 12-bit mask; the Transpose Scale Type enum gets more labels through the existing parameter info |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. The `.sonara` project format version and the device preset version go up by one, so the saved Transpose Scale Type values can be migrated (REQ-007) |

## Terms

- **Scale catalogue**: the ordered list of scale types (id, label, group, intervals) offered by
  the scale picker and by Transpose's Scale Type parameter.
- **Scale group**: a heading in the catalogue (Common, Melodic Minor Modes, …).
- **Key spelling**: whether a key's note names use sharps (C#, F#) or flats (Db, Bb).

## Requirements

### REQ-001 — Catalogue contents

The scale catalogue shall contain "None" plus exactly these scale types, in this group order,
with these semitone intervals above the root:

| Group | Label | Intervals |
|---|---|---|
| Common | Major | 0 2 4 5 7 9 11 |
| Common | Natural Minor | 0 2 3 5 7 8 10 |
| Common | Harmonic Minor | 0 2 3 5 7 8 11 |
| Common | Melodic Minor | 0 2 3 5 7 9 11 |
| Common | Dorian | 0 2 3 5 7 9 10 |
| Common | Phrygian | 0 1 3 5 7 8 10 |
| Common | Lydian | 0 2 4 6 7 9 11 |
| Common | Mixolydian | 0 2 4 5 7 9 10 |
| Common | Locrian | 0 1 3 5 6 8 10 |
| Common | Major Pentatonic | 0 2 4 7 9 |
| Common | Minor Pentatonic | 0 3 5 7 10 |
| Common | Blues | 0 3 5 6 7 10 |
| Melodic Minor Modes | Dorian b2 | 0 1 3 5 7 9 10 |
| Melodic Minor Modes | Lydian Augmented | 0 2 4 6 8 9 11 |
| Melodic Minor Modes | Lydian Dominant | 0 2 4 6 7 9 10 |
| Melodic Minor Modes | Mixolydian b6 | 0 2 4 5 7 8 10 |
| Melodic Minor Modes | Half-Diminished | 0 2 3 5 6 8 10 |
| Melodic Minor Modes | Altered | 0 1 3 4 6 8 10 |
| Harmonic Modes | Locrian ♮6 | 0 1 3 5 6 9 10 |
| Harmonic Modes | Ionian #5 | 0 2 4 5 8 9 11 |
| Harmonic Modes | Ukrainian Dorian | 0 2 3 6 7 9 10 |
| Harmonic Modes | Phrygian Dominant | 0 1 4 5 7 8 10 |
| Harmonic Modes | Lydian #2 | 0 3 4 6 7 9 11 |
| Harmonic Modes | Harmonic Major | 0 2 4 5 7 8 11 |
| Exotic | Double Harmonic | 0 1 4 5 7 8 11 |
| Exotic | Hungarian Minor | 0 2 3 6 7 8 11 |
| Exotic | Hungarian Major | 0 3 4 6 7 9 10 |
| Exotic | Neapolitan Major | 0 1 3 5 7 9 11 |
| Exotic | Neapolitan Minor | 0 1 3 5 7 8 11 |
| Exotic | Persian | 0 1 4 5 6 8 11 |
| Exotic | Enigmatic | 0 1 4 6 8 10 11 |
| Symmetric | Whole Tone | 0 2 4 6 8 10 |
| Symmetric | Diminished (Half-Whole) | 0 1 3 4 6 7 9 10 |
| Symmetric | Diminished (Whole-Half) | 0 2 3 5 6 8 9 11 |
| Symmetric | Augmented | 0 3 4 7 8 11 |
| Bebop and Blues | Bebop Dominant | 0 2 4 5 7 9 10 11 |
| Bebop and Blues | Bebop Major | 0 2 4 5 7 8 9 11 |
| Bebop and Blues | Bebop Dorian | 0 2 3 4 5 7 9 10 |
| Bebop and Blues | Major Blues | 0 2 3 4 7 9 |
| Bebop and Blues | Spanish 8-Tone | 0 1 3 4 5 6 8 10 |
| Pentatonic and World | Egyptian | 0 2 5 7 10 |
| Pentatonic and World | Yo | 0 2 5 7 9 |
| Pentatonic and World | Hirajoshi | 0 2 3 7 8 |
| Pentatonic and World | In Sen | 0 1 5 7 10 |
| Pentatonic and World | Iwato | 0 1 5 6 10 |
| Pentatonic and World | Kumoi | 0 2 3 7 9 |
| Pentatonic and World | Pelog | 0 1 3 7 8 |

The 12 existing scale type ids (`major` … `blues`) shall keep their ids.

- **Acceptance:** a Godot test checks every row (label, group, intervals) and that the 12 old ids
  still resolve.
- **Example:** `MusicalScale.make(0, "<lydian dominant id>").pitch_classes()` → C D E F# G A A#.

### REQ-002 — One catalogue for both sides

The Transpose Scale Type parameter shall offer the same scale types, with the same labels and
intervals, in the same order as the scale picker (without "None").

- **Acceptance:** an automated check fails when the engine's table and the Godot catalogue
  differ in count, order, label or intervals.

### REQ-003 — Grouped scale picker

The scale picker (main toolbar and the key change popup) shall list the scale types under their
group headings, in catalogue order, with "No scale" first.

- **Acceptance:** Godot test on `ScalePicker`: the type menu shows 7 group headings, each followed
  by its scales; headings cannot be selected.

### REQ-004 — Root picker shows both spellings

The scale picker's root list shall label each black-key root with both spellings
(`C#/Db`, `D#/Eb`, `F#/Gb`, `G#/Ab`, `A#/Bb`) and white-key roots with one name.

- **Acceptance:** Godot test reads the 12 root item labels.

### REQ-005 — Key spelling

WHEN a scale is set, the Godot UI shall spell the key name, and the scale's notes, all with
sharps or all with flats, chosen as follows:

1. Spell the scale's pitch classes both ways (sharps: C C# D D# E F F# G G# A A# B; flats:
   C Db D Eb E F Gb G Ab A Bb B). Pick the spelling that repeats fewer letter names.
2. On a tie, use the reference major key: the root if the scale contains a major third
   (interval 4), otherwise the root plus 3 semitones. If that is F, Bb, Eb, Ab or Db, use flats;
   otherwise sharps.

- **Acceptance:** Godot test on `MusicalScale.display_name()` for the examples below.
- **Example:** root 10 Major → "Bb Major"; root 1 Major → "Db Major"; root 6 Major →
  "F# Major" (tie, reference F#); root 2 Natural Minor → "D Natural Minor"; root 5 Natural
  Minor → "F Natural Minor"; root 10 Natural Minor → "Bb Natural Minor"; root 1 Natural Minor →
  "C# Natural Minor"; root 3 Dorian → "Eb Dorian" (flats give 7 distinct letters); root 10 Minor
  Pentatonic → "Bb Minor Pentatonic" (tie, reference Db); root 3 Natural Minor → "D# Natural
  Minor" (tie, reference F#).

### REQ-006 — Note names follow the key in the clip editor

WHILE a scale is set and the piano roll is shown, the clip editor's piano keys and note labels
shall name pitches with the key spelling of the scale (REQ-005). Without a scale, and everywhere
outside the clip editor (sampler, drum pads, note maps), note names stay as today (sharps).

- **Acceptance:** Godot test: with F Major set, the label for MIDI 70 is "Bb3"; with no scale it
  is "A#3".

### REQ-007 — Saved Transpose settings survive the longer list

WHEN a project or device preset saved before this change is loaded, a Transpose device's Scale
Type shall select the same scale it selected when saved.

- **Acceptance:** Godot test loads a version-2 project JSON and a pre-change preset JSON whose
  Transpose stores Scale Type "Blues" (normalized 1.0) and "Dorian" (4/11), and checks they load
  as Blues and Dorian.
- **Example:** saved 1.0 → index 11 of the old 12 → "Blues" → its index in the new list,
  re-normalized.

### REQ-008 — Unknown scale ids

IF a project or key change names a scale type id the catalogue does not know, THEN the clip
editor shall treat it as before this spec (base scale → none; key change entry dropped).

- **Acceptance:** existing tests `test_key_change_sync.gd` and `test_scale_lanes.gd` keep
  passing.

## Non-functional

- **Real-time safety:** Transpose keeps reading a static table; no allocation added on the audio
  callback.
- **Compatibility:** projects and presets saved after this change opened in an older build show
  new project scales as "No scale" and new Transpose scale types clamped to the last old entry.
  Accepted: no forward compatibility is promised.

## Out of scope

- Microtonal scales and Arabic maqams (a 12-bit pitch-class mask can't represent them).
- User-defined custom scales.
- Group headings in Transpose's own Scale Type dropdown: the generic enum control shows a flat
  list, in catalogue order.
- Flat spelling outside the clip editor and the scale/key displays.
- Chord-name detection, or chord tools aware of the new scales.

## Open questions

- none
