# Scale support — Requirements

Tracks [#82](https://github.com/petterthowsen/Sonara/issues/82), split out of #79 (MIDI editor QOL).

## Problem

The clip editor's piano roll shows all 128 pitches the same way, so writing in a key means counting
semitones by eye, and a slip of one row puts a wrong note in the clip. There is nowhere to say what
key a project is in. Users who write melodies and chords notice it every time they place or move a
note.

## Scope

| | |
|---|---|
| Subsystem | Godot |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no. The scale is UI state and never reaches the engine |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. The project file gains the project scale and two clip editor toggles. Older projects load with no scale (REQ-003) |

## Terms

- **Project scale**: one root pitch class (C to B) plus one scale type, or none. Set per project.
- **In-scale pitch**: a MIDI pitch whose pitch class belongs to the project scale.
- **Scale step**: moving from an in-scale pitch to the next in-scale pitch above or below it.
- **Scale snap**: the clip editor toggle that keeps placed and moved notes on in-scale pitches.
- **Fold to scale**: the clip editor toggle that hides out-of-scale rows in the piano roll.

## Requirements

### Project scale

### REQ-001: Scale catalogue

The project scale's type shall be one of: None, Major, Natural Minor, Harmonic Minor, Melodic Minor
(ascending form), Dorian, Phrygian, Lydian, Mixolydian, Locrian, Major Pentatonic, Minor Pentatonic
and Blues.

- **Acceptance:** a headless test checks each type's pitch classes for root C.
- **Example:** C Harmonic Minor gives {0, 2, 3, 5, 7, 8, 11}. A Blues gives {9, 0, 2, 3, 4, 7}
  (A C D D# E G).

### REQ-002: Setting the scale in the main toolbar

The main toolbar shall show two dropdowns right after the time signature field: the root (C to B)
and the scale type. They shall show the current project scale (for example "D" and "Dorian"), the
type reading "No scale" when it is None, in which case the root dropdown is disabled.

- **Acceptance:** live: the dropdowns sit after the time signature field. Picking D and Dorian
  redraws the clip editor lanes.

### REQ-003: Persistence and defaults

The project file shall store the project scale. A new project, and a project saved before this
feature, shall load with no scale (type None, root C).

- **Acceptance:** a headless round-trip test saves a project with E Lydian and loads it back as
  E Lydian. Loading a project dictionary without the scale keys gives type None.

### REQ-004: Undo

WHEN the user changes the project scale, the editor history shall record one undoable step that
restores the previous root and type.

- **Acceptance:** live: set G Major, then undo. The control reads the previous scale and the lanes
  redraw to match.

### Lane highlighting

### REQ-005: In-scale lanes

WHILE a project scale is set and the clip editor shows the piano roll, the note lanes shall tint
in-scale lanes with the theme's secondary accent colour (out-of-scale lanes keep the plain key colour), keep the white and black key pattern underneath,
and mark every lane holding the root pitch class with an accent.

- **Acceptance:** a headless test checks the lane colour picked for in-scale, out-of-scale and root
  pitches. Live: with C Major set, the lanes for C2, C3, C4 and so on carry the root accent and the
  C major lanes are tinted while C#, D#, F#, G# and A# stay plain.

### REQ-006: No scale means no change

WHILE the project scale's type is None, the note lanes shall look exactly as they did before this
feature.

- **Acceptance:** a headless test checks that with type None the lane colour equals the plain
  white or black key colour for every pitch.

### REQ-007: Note map tint still applies

WHILE a project scale is set and the effective note map has an entry for a pitch, that lane shall
still show the note map tint, blended over the scale shading.

- **Acceptance:** a headless test checks that a mapped out-of-scale lane differs from an unmapped
  out-of-scale lane.

### Fold to scale

### REQ-008: Folded rows

WHILE Fold to scale is on, a project scale is set and the clip editor shows the piano roll, the
clip editor shall show one row per in-scale pitch, plus one row for each out-of-scale pitch used by
a note in the editable clips on screen. Every other pitch shall be hidden.

- **Acceptance:** a headless test computes the rows for C Major Pentatonic over a clip holding
  C3 (60) and C#3 (61). The rows are every pitch with pitch class {0, 2, 4, 7, 9}, plus 61.

### REQ-009: Out-of-scale rows are marked

WHILE Fold to scale is on, a row shown only because a note uses its out-of-scale pitch shall be
drawn with the out-of-scale tint from REQ-005, and every folded row shall have a visible separator
line below it.

- **Acceptance:** live: with C Major and Fold to scale on, a C#3 note sits on a tinted row between
  C3 and D3, and every folded row is separated by a line.

### REQ-010: Rows don't move under the cursor

WHILE a note drag or resize is in progress, the folded row set shall not change. The rows shall
update once the gesture ends.

- **Acceptance:** live: with Fold to scale on and scale snap off, drag the only C#3 note to D3.
  The C#3 row stays until the mouse is released, then disappears.

### REQ-011: Fold to scale toggle

The clip editor toolbar shall have a Fold to scale toggle, and the `Hotkeys` registry shall have an
action for it (no default chord). Fold to scale is optional: it shall be off by default in every
project, and highlighting and scale snap shall work the same with it off. The toggle shall be
disabled while the project scale is None or the clip editor shows Drum View. Its state shall be
saved with the project.

- **Acceptance:** live: the toggle is greyed out with no scale and in Drum View. A headless
  round-trip test keeps its state.

### REQ-012: Keyboard header follows the rows

WHILE Fold to scale is on, the vertical piano header shall show one key per visible row, at the
same height as its row, labelled with that row's pitch.

- **Acceptance:** live: with D Dorian folded, the header's keys line up with the lanes and read
  D, E, F, G, A, B, C, going upward.

### Scale snap

### REQ-013: Scale snap toggle

The clip editor toolbar shall have a Scale snap toggle, and the `Hotkeys` registry shall have an
action for it with a help-bar entry. The toggle shall be disabled while the project scale is None
or the clip editor shows Drum View. Its state shall be saved with the project.

- **Acceptance:** live: the hotkey flips the toggle and the help bar lists it. A headless round-trip
  test keeps its state.

REQ-014 to REQ-019 apply only WHILE Scale snap is on, a project scale is set and the clip editor
shows the piano roll. In every other state, placing, dragging and transposing notes work exactly as
before. With Fold to scale on and Scale snap off, that means vertical moves walk the visible rows,
as folded rows already do in Drum View.

### REQ-014: Placing a note

WHEN the user places a note on an out-of-scale pitch, the clip editor shall place it on the nearest
in-scale pitch instead. When both neighbours are equally far, the half of the row the cursor is in
shall decide: the upper half picks the pitch above, the lower half the pitch below.

- **Acceptance:** a headless test of the snapping function. In C Major, clicking the upper half of
  the C#3 row places D3 (62), and clicking its lower half places C3 (60).

### REQ-015: Dragging moves by scale steps

WHEN the user drags selected notes vertically, the cursor's nearest in-scale pitch shall set a
number of scale steps, and every selected note shall move by that many scale steps. An in-scale
dragged note lands exactly on the in-scale pitch nearest the cursor. An out-of-scale note, the
dragged one included, follows REQ-016.

- **Acceptance:** a headless test of the scale-step function. In C Major, a selection of
  C3, E3 and G3 (60, 64, 67) moved up one scale step becomes D3, F3 and A3 (62, 65, 69).

### REQ-016: Out-of-scale notes in a moved selection

WHEN a moved selection holds an out-of-scale note, that note shall move by the same number of scale
steps, counted from the in-scale pitch just below it, and keep its semitone offset above that
pitch.

- **Acceptance:** a headless test. In C Major, C#3 (61) moved up one scale step becomes D#3 (63):
  C3 steps to D3 and the +1 offset stays.

### REQ-017: Keyboard transpose

WHEN the user presses the transpose up or transpose down hotkey, the selected notes shall move by
one scale step following REQ-015 and REQ-016. The octave hotkeys shall still move by 12 semitones.

- **Acceptance:** a headless test of the step function. Live: with A Minor set, pressing Up on
  B2 (59) gives C3 (60), and Ctrl+Up on B2 gives B3 (71).

### REQ-018: Shift bypasses scale snap

WHILE the user holds Shift during a note drag, the clip editor shall move notes by semitones with no
scale snap, the same way Shift already bypasses grid snap. The help-bar entry for Shift-drag shall
say that it bypasses both.

- **Acceptance:** live: with scale snap on, Shift-dragging a note in C Major can land it on C#3.

### REQ-019: Keyswitches are never snapped

The clip editor shall never snap a note onto or off a pitch that the effective note map marks as an
SFZ keyswitch. A keyswitch note shall move by semitones, and a click on a keyswitch row shall place
the note on that row.

- **Acceptance:** a headless test. With a note map that has a keyswitch on C#1 (37) and C Major set,
  placing on 37 keeps 37, and a selection of [37, 60] moved up one step becomes [38, 62].

### REQ-020: Existing notes are left alone

Turning on scale snap, or changing the project scale, shall not change any note. Notes change only
when the user edits them (REQ-014 to REQ-017) or runs Conform to scale (REQ-021).

- **Acceptance:** a headless test: changing the scale on a project with out-of-scale notes leaves
  every note's pitch unchanged.

### REQ-021: Conform to scale

The clip editor shall offer a Conform to scale selection tool, with a `Hotkeys` action (no default
chord), that moves each selected out-of-scale note to its nearest in-scale pitch, with ties going
down. Keyswitch notes (REQ-019) shall be skipped. It shall be one undoable step. It shall be
disabled while the project scale is None or the clip editor shows Drum View.

- **Acceptance:** a headless test. In C Major, conforming [61, 63, 66] gives [60, 62, 65].

### Drum View

### REQ-022: Drum View is untouched

WHILE the clip editor shows Drum View, lane highlighting, Fold to scale, scale snap and Conform to
scale shall all have no effect.

- **Acceptance:** live: switch a clip with a scale set to Drum View. The rows, colours, placement
  and drag behave as before this feature. A headless test checks that the snapping functions return
  their input unchanged when called in Drum View mode.

## Non-functional

- **Real-time safety:** not affected. Nothing here reaches the engine.
- **Latency / performance:** lane drawing stays one pass over the visible rows. Turning on Fold to
  scale rebuilds the rows once, the same way switching to Drum View does.
- **Compatibility:** a project saved by an older build loads with no scale and both toggles off. An
  older build ignores the new keys.

## Out of scope

- Key changes over time (a scale map like the time signature map).
- Snapping for paste, duplicate, flip vertical, strum, MIDI recording and the virtual keyboard.
  Those keep their semitone behaviour.
- Scale highlighting on the arranger's clip previews, and scale-aware note colours.
- DAWproject import and export of the scale.
- Feeding the project scale to the AI score format (`key` in spec 025). This is a natural follow-up.
- User-defined scales.

## Open questions

- [x] REQ-016: out-of-scale notes keep their semitone offset above the scale pitch below them
  (agreed over snapping them into the scale first).
- [x] REQ-011 and REQ-013: both toggles are saved per project (agreed).
