# Musical Note Tools — Requirements

Extends [026 scale support](../026-scale-support/requirements.md),
[034 key changes](../034-key-changes/tasks.md), [038 scale catalogue](../038-scale-catalogue/requirements.md)
and the MIDI editor selection tools (`docs/midi-editor-qol-plan.md`, phase 2). Inspired by
Studio One's harmony editing tools.

## Problem

The MIDI editor can quantize, mirror, strum and conform notes to the scale, but it has no
*musical* tools. Writing chords means placing every note by hand. Nothing can harmonize a melody,
derive a bassline from chords, invert a chord, or pull one voice of a chord pad out onto its own
track. The project key also has to be set by hand. Someone who imports a MIDI file or plays in a
part doesn't know the key, and so can't turn on scale shading and snapping. Songwriters and
arrangers notice this most.

## Scope

| | |
|---|---|
| Subsystem | Godot only (MIDI editor, transport scale picker, key change track) |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no. Notes, clips and tracks are created and changed through the existing `data/` models, which already sync themselves |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | `config.json` only: the dialogs' last-used options and the new hotkey bindings. These are additive keys, so no migration is needed. `.sonara` is unchanged |

## Terms

- **Chord (note group)**: notes of one clip whose starts lie within the strum tolerance (1/64
  note, the existing `STRUM_TOLERANCE_TICKS`) of the group's first note. A note that starts alone
  is a one-note chord. This is the same grouping that Strum uses.
- **Voice**: a note's rank inside its chord, counted by pitch. *Voice 1* is the top note. *Bottom*
  is the lowest note. In a one-note chord, the note is both voice 1 and the bottom voice.
- **Scale at a tick**: the project scale, or the key change active at that tick (spec 034).
- **Degree progression**: an ordered list of scale degrees (I, ii, V7, …) that names chords
  relative to the scale at each chord's tick.
- **Note range**: a low and high MIDI pitch, inclusive, that generated notes must stay inside.

## Requirements

### Shared behaviour

### REQ-001 — One undo step per tool run

WHEN any tool in this spec changes notes, clips or the key, the editor shall record exactly one
undo step for that run, and undoing it shall restore the notes, clips and key exactly as they
were.

- **Acceptance:** a Godot test runs each tool once, checks that the history grew by one, undoes,
  and compares the notes with a snapshot.

### REQ-002 — Scale-dependent tools need a scale

WHILE the scale at the target position is "No scale", the MIDI editor shall disable Harmonize,
Insert Chords and Insert Bassline, and the tooltip shall say that a key is needed. Chord
Inversion, Select Voices, Transfer Notes and Split Voices shall work without a scale.

- **Acceptance:** Godot test: with no scale the three buttons are disabled. After the project
  scale is set to C Major they are enabled.

### REQ-003 — Key changes are respected

The scale-dependent tools shall build each generated note from the scale at that note's own
start tick, so material that crosses a key change follows the new key.

- **Example:** C Major at bar 1 and a key change to A Natural Minor at bar 3. Insert Chords with
  `I` in every bar gives C–E–G in bars 1–2 and A–C–E in bars 3–4.
- **Acceptance:** Godot test with exactly that setup.

### REQ-004 — Last-used options persist

Each dialog in this spec shall open with the options it was last confirmed with, including after
a restart.

- **Acceptance:** Godot test: confirm a dialog with non-default options, reopen it, and read the
  values back. Live: restart the app and check again.

### REQ-005 — Where the tools live

The clip editor toolbar shall have Invert Up and Invert Down as plain buttons next to the existing
selection tools, and one "Harmony" menu button listing Select Voices (a submenu), Harmonize…,
Insert Chords…, Insert Bassline…, Transfer Notes… and Split Voices. Every tool in that menu shall
also be a rebindable hotkey action in the MIDI editor context (unbound by default except where the
design gives a default). The MIDI editor has no note context menu, because right-click erases.

- **Acceptance:** Godot test: the menu has those items in that order, and each one is registered
  in the Hotkeys registry.

### Key detection

### REQ-010 — Detect the project key

WHEN the user chooses Detect in the transport scale picker, the scale picker shall estimate the
key from the MIDI notes of every non-drum track. When the project has key changes, only the notes
before the first key change count. It shall show the result (for example "A Natural Minor") with
a confidence indicator, and set the project scale only when the user accepts it.

- **Example:** a clip containing a C major scale and C–E–G chords → "C Major".
- **Acceptance:** a Godot unit test feeds known pitch material to the detector (C major material,
  A minor material, and the same material transposed to every root) and checks the key it
  returns. A second test checks that nothing changes until the result is accepted.

### REQ-011 — Detect at a key change

WHEN the user chooses Detect on a key change in the key change track, the key change track shall
estimate the key from the MIDI notes between that key change and the next one (or the end of the
song), and update that key change only when the user accepts the result.

- **Acceptance:** Godot test: two key changes over C-major and E-minor material. Detecting on the
  second key change proposes E Natural Minor.

### REQ-012 — Detection candidates and fallbacks

The key detector shall choose between Major and Natural Minor on all 12 roots. It shall weight
each note by its duration. IF the span has fewer than 4 notes or fewer than 3 distinct pitch
classes, THEN it shall report "Not enough notes" and offer no result.

- **Acceptance:** unit tests for the threshold, and a test where a long tonic note outweighs many
  short passing notes.

### Selection tools

### REQ-020 — Select Voices

The MIDI editor shall offer Select Voices with the choices Top, Bottom and "Voice N" (N counted
from the top). WHEN the user picks one, the MIDI editor shall replace the selection with the notes
of that voice. The candidates are the selected notes, or every note of the edited clip(s) when
nothing is selected.

- **Example:** chords C3–E3–G3 and D3–F3–A3–C4. Top selects G3 and C4. Bottom selects C3 and D3.
  Voice 2 selects E3 and A3. Voice 4 selects only D3.
- **Acceptance:** Godot test with exactly those chords.

### REQ-021 — Chord Inversion up and down

WHEN the user presses Invert Up, the MIDI editor shall move the lowest note of every selected
chord up by octaves until it is above that chord's highest note. WHEN the user presses Invert
Down, it shall move the highest note down by octaves until it is below that chord's lowest note.
One-note chords are left alone. IF the moved note would leave 0–127, THEN that chord shall stay
unchanged.

- **Example:** C3–E3–G3 → Up → E3–G3–C4 → Up → G3–C4–E4 → Down → E3–G3–C4.
- **Acceptance:** Godot test with that sequence, plus a test that Up followed by Down restores the
  original notes.

### REQ-022 — Inversion hotkeys

Invert Up and Invert Down shall be rebindable hotkey actions in the MIDI editor context, with
default bindings that don't collide with existing MIDI editor hotkeys.

- **Acceptance:** both actions appear in the Hotkeys registry with a default chord that no other
  MIDI editor action uses, and they trigger the tool in a test.

### Generators

### REQ-030 — Harmonize

WHEN the user confirms the Harmonize dialog, the MIDI editor shall add, for each selected note,
one copy per chosen interval. The intervals are scale steps (a 3rd, 4th, 5th, 6th or octave,
above or below). Each copy keeps the original's start, length and velocity, with an optional
velocity offset. The original notes stay selected. Notes that already have the same pitch at the
same start shall not be duplicated.

- **Example:** C Major, melody C3 D3 E3, harmonize a 3rd above → adds E3 F3 G3. The same with a 6th
  below adds E2 F2 G2.
- **Acceptance:** Godot test with that melody and both intervals, and a run with two intervals at
  once.

### REQ-031 — Harmonize stays in key

A harmonized copy of an out-of-scale note shall be placed by moving the original by the interval's
scale steps from the nearest in-scale pitch below it, keeping the original's chromatic offset.
This is the same behaviour as the existing scale step move.

- **Acceptance:** Godot test: C Major, C#3 harmonized a 3rd above → F3 (C3 + 2 steps = E3, +1
  semitone).

### REQ-032 — Insert Chords

WHEN the user confirms the Insert Chords dialog, the MIDI editor shall insert one chord per step
of a degree progression, back to back, each lasting the chosen chord length (a note value from
1/16 to 2 bars). The progression repeats as needed. The chords fill the selected time range. When
no range is selected, the dialog's Count of chords is inserted from the edit position (the paste
position).

- **Example:** C Major, progression `I V vi IV`, length 1 bar, a 4-bar range → C, G, Am and F
  chords, one per bar.
- **Acceptance:** Godot test with that example, and a test that a 6-bar range repeats the
  progression (I V vi IV I V).

### REQ-033 — Degree progression input

The Insert Chords dialog shall accept a progression typed as Roman numerals (I–VII, upper or lower
case, an optional `7`, separated by spaces or dashes), and shall offer preset progressions. IF the
text doesn't parse, THEN the dialog shall show the offending token and disable OK. The chord on
each degree shall be built by stacking scale thirds from that degree (a triad, or a 7th chord with
`7`). The case of the numeral is for readability only, so `v` and `V` give the same diatonic chord.

- **Example:** in A Natural Minor, `V7` → E G B D (diatonic). Writing `ii` in C Major gives D F A.
- **Acceptance:** unit tests for the parser (valid, invalid, mixed case, separators) and for chord
  building in Major, Natural Minor and Harmonic Minor.

### REQ-034 — Note range and voicing

The Insert Chords dialog shall have a note range control (a dual-handle slider, default C2–C4) and
a voicing choice of Close or Spread, plus an inversion choice of Root position or Smooth (voice
leading). Every generated note shall lie inside the note range.

- With **Close** the chord fits within one octave. With **Spread** the chord tones are distributed
  over more than an octave (for example root, fifth, third an octave up).
- With **Smooth**, each chord after the first uses the inversion whose notes move the least total
  distance from the previous chord.
- IF a chord can't fit inside the range in any inversion, THEN its notes shall be clamped by whole
  octaves into the range, and the dialog shall say so after inserting.
- **Acceptance:** Godot tests: every note is inside the range for all voicing and inversion
  combinations. With Smooth, `I IV V I` in C Major moves less in total than with Root position.

### REQ-035 — Insert Bassline

WHEN the user confirms the Insert Bassline dialog, the MIDI editor shall find the root of every
selected chord (chords of 2 or more notes) and add bass notes under them, in the bass note range
(a dual-handle slider, default C1–C2). The pattern is one of:

- **Sustained**: one root note lasting the chord's length.
- **Pulse**: the root repeated on the grid (snap) value for the chord's length.
- **Root–Fifth**: root and fifth alternating on the grid value.

The chord's length runs from its start to the next chord's start, or to its longest note when it
is the last chord.

- **Example:** chords C–E–G (1 bar) then A–C–E (1 bar), Sustained, range C1–C2 → C1 for 1 bar, A1
  for 1 bar.
- **Acceptance:** Godot test for each pattern on that example.

### REQ-036 — Chord root detection

The root detector shall match a chord's pitch classes against major, minor, diminished and
augmented triads and their 7th chords. When several match, it prefers the one whose root is the
lowest sounding note. IF none matches, THEN the root shall be the chord's lowest note.

- **Example:** E3–G3–C4 (C major, first inversion) → root C. C3–E3–G3–A3 → root C (C6 is treated
  as C, whose root is the lowest note), not A minor 7.
- **Acceptance:** unit tests covering every chord quality in root position and in every inversion.

### Cross-track tools

### REQ-040 — Transfer Notes

WHEN the user chooses Transfer Notes with a target track, the MIDI editor shall move the selected
notes to the target track at the same song positions. The target list has every other instrument
track, and its default is the arranger's selected track when that is not the source. The moved notes
are grouped into runs: notes whose bar spans touch or overlap belong to one run. For each run:

- WHEN a target clip overlaps the run's bars, the notes shall go into that clip, and the clip
  shall be extended (start earlier and/or end later, to whole bars) to cover any notes that stick
  out. If several clips overlap, the earliest one takes the notes it covers and the remaining
  notes follow the same rules.
- IF no target clip overlaps the run, THEN a new clip shall be created spanning the run's bars.
  Clips that don't overlap are never stretched to reach the notes, however close they are.

- **Example:** a track with one clip on bars 1–4. Notes on bars 3–5 → they go into that clip, which
  is extended to end at bar 5. A note on bar 9 → a new one-bar clip on bar 9. The clip on bars 1–4
  is not stretched to bar 9.
- **Acceptance:** Godot tests for the covered, extended, new-clip and two-overlapping-clips cases.

### REQ-041 — Split Voices

WHEN the user chooses Split Voices, the MIDI editor shall move voice 1, voice 2, … of the selected
notes (or of all notes of the edited clip when nothing is selected) to the selected tracks in
track order, one voice per track. If the source track is among the selected tracks, it takes its
place in that order. Voices without a target track stay on the source track. Notes are placed with
the same rules as Transfer Notes.

- **Example:** a 4-voice chord pad, with the source track plus two tracks below it selected →
  voice 1 stays on the source, voice 2 goes to the next track, voice 3 to the one after, and voice
  4 stays on the source.
- **Acceptance:** Godot test with that example.

### REQ-042 — Split Voices needs targets

IF fewer than one non-source track is selected, THEN Split Voices shall be disabled with a tooltip
explaining that target tracks must be selected in the arranger or track list.

- **Acceptance:** Godot test on the disabled state.

### REQ-043 — Linked clips

IF a cross-track tool would write into a clip that is linked to other instances, THEN the notes
shall appear in every linked instance (the existing linked-clip behaviour), and the confirmation
shall warn about it before applying.

- **Acceptance:** Godot test: transferring into a linked clip shows the warning flag, and after
  confirming, both instances contain the notes.

## Non-functional

- **Performance:** each tool finishes in under 100 ms for 2,000 selected notes on the dev laptop
  (measured in the Godot test with `Time.get_ticks_usec`).
- **Compatibility:** projects and notes are unchanged in format. Only new `config.json` keys are
  added.

## Out of scope

- A chord track or chord symbols in the arranger (issue #29). Insert Chords and Bassline work from
  degrees and notes only.
- Detecting keys other than Major and Natural Minor (modes, exotic scales).
- Borrowed chords, secondary dominants and chromatic chord symbols (`bVII`, `V/V`) in the
  progression parser.
- Automatically creating tracks for Split Voices.
- Suggesting chords that fit a melody.
- Drum View. All of these tools are disabled there.

- A right-click context menu for notes. Right-click erases in the MIDI editor and Alt+right-click
  previews the chord, so the tools are reached from the toolbar and hotkeys instead (REQ-005).

## Open questions

None. Both of the earlier questions are resolved by REQ-005.
