# 019: Note values and the value lane — Requirements

Status: draft, awaiting approval.

## Problem

A note's velocity is a 7-bit integer, and it can only be edited by Alt-dragging the note itself
with no readout. A note has no release velocity: the engine sends 0 on every note-off, and
DAWproject import drops `rel` into the transfer report. The device interface carries only a key
and a 7-bit velocity. It can't identify a sounding note, so per-note expression (pressure, timbre,
pitch curves) can't be added later without changing every device again. A user who wants to
shape dynamics or release behaviour has no tool for it, and new notes always come in at 100.

This spec lays the foundation for per-note data along the lines of the industry standards
(CLAP, MIDI 2.0, MPE, DAWproject). It ships two **note values**, velocity and release velocity,
and a **value lane** panel in the MIDI editor to edit them. Per-note **expression curves** are
the next spec, and the formats here leave room for them.

Decisions behind this spec were settled in a design interview (Q1–Q12) and are summarised in
`design.md`.

## Scope

| | |
|---|---|
| Subsystem | both |
| Touches real-time audio thread | yes: note events reaching devices, note ids, the `release` modulator |
| Adds or changes an OSC message | yes: `/clip/{id}/add_note` and `update_note` carry float velocity and release; live note-off carries release |
| Changes a persisted format (`.sonara`) | yes: notes store `vel`/`rel` floats in place of `velocity`. Old files migrate on load (`velocity / 127`), and the project gets a format version |

Phases: **A. Foundation** (model, format, OSC, engine, interop), then **B. UI** (value lane,
selection, new-note values, transforms). Phase B starts only once phase A is verified.

## Requirements

### A. Foundation

#### A1. Note values in the model and the project file

##### REQ-001: Velocity and release are normalized floats

The note model shall hold velocity and release velocity as floats. Velocity ranges over
`[1/127, 1.0]` (0 would mean note-off in MIDI 1.0). Release ranges over `[0.0, 1.0]`, with a
default of 0.5.

- **Acceptance:** Godot unit test: a note set to velocity 0.0 holds 1/127, and one set to 1.5
  holds 1.0. A new note has release 0.5. Setting velocity to 100 (an old 0–127 value) fails a
  debug assertion.

##### REQ-002: New project-file keys

WHEN a project is saved, each note shall be written with `vel` and, only when it differs from the
default, `rel`. The old `velocity` key shall not be written.

- **Acceptance:** Godot test saves a clip with notes at `vel` 0.5 / `rel` 0.5 and `vel` 0.25 /
  `rel` 0.9, and asserts the JSON keys: `rel` appears only on the second note, and no
  `velocity` key appears anywhere.

##### REQ-003: Old projects keep their velocities

WHEN a project whose notes have `velocity` (0–127) and no `vel` is loaded, the note model shall
set velocity to `velocity / 127` and release to the default.

- **Acceptance:** Godot test loads a fixture with `"velocity": 100` and `"velocity": 1`, and
  asserts velocities of 100/127 and 1/127 and release 0.5. Saving and reloading the result
  gives the same values.

##### REQ-004: Project format version

The project file shall carry a format version. Saving shall write the current version, and
loading a file with no version shall treat it as the pre-019 format.

- **Acceptance:** Godot test: a saved project contains the version, and a fixture without one
  loads through the REQ-003 migration.

##### REQ-005: Note operations keep every note value

Every operation that copies, rebuilds or snapshots notes shall carry velocity and release through
unchanged. That covers copy/paste, duplicate, split, clip merge, make-unique, quantize, the AI
clip tools, and undo/redo.

- **Acceptance:** Godot test runs each operation on a note with `vel` 0.3 / `rel` 0.8, and
  asserts the resulting note(s) still have both values. For undo/redo: a release edit undoes
  and redoes exactly.

#### A2. Engine delivery

##### REQ-006: Clip notes reach devices at full precision

WHEN a clip note plays, the device shall receive its velocity on note-on and its release on
note-off as floats, with no rounding to 7 bits.

- **Acceptance:** Rust test: a clip note with velocity 0.5039 and release 0.25 reaches a probe
  device as exactly those floats, at the expected frame offsets.

##### REQ-007: A sounding note has an id

The engine shall give every note-on a **note id** that is unique among the notes sounding on that
channel. The matching note-off shall carry the same id, and two overlapping plays of the same
clip note (overlapping instances, a loop seam) shall get different ids.

- **Acceptance:** Rust test plays two overlapping clip instances of one clip and asserts that
  the probe device sees distinct ids for the two note-ons, and that each note-off matches its
  note-on's id.

##### REQ-008: Containers keep the note id

WHEN a container forwards a note event (Chain, Layer including a remapped key in a zoned slot,
Drum Machine), the inner device shall receive the same note id the container received.

- **Acceptance:** Rust test: a Layer slot maps 60 → 36. A probe device inside it receives
  key 36 with the outer note id, on both note-on and note-off.

##### REQ-009: Live input carries release velocity

WHEN a live note-off arrives from a MIDI input with a release velocity, the device shall receive
that release velocity. WHEN a note-on with velocity 0 arrives, the engine shall treat it as a
note-off with release 0.5. The virtual keyboard sends release 0.5.

- **Acceptance:** Rust test feeds a live note-off with velocity 32 and asserts release 32/127
  at the probe device. A note-on with velocity 0 gives a note-off with release 0.5.

##### REQ-010: CLAP plugins get the note id and release

The CLAP plugin host shall send note-on and note-off events with the engine's note id and the
float velocity or release.

- **Acceptance:** Rust test on the IPC event encoding: a note event round-trips the id, key and
  value. Live check: a CLAP plugin that shows release velocity (e.g. a MIDI monitor) displays
  the edited release value.

##### REQ-011: sfizz gets release velocity

The SFZ sampler device shall pass the release velocity to sfizz on note-off. The sfizz binding
takes 7-bit values, so velocity and release are quantized at that boundary. A float path through
sfizz's HD note API is a follow-up.

- **Acceptance:** Rust test or live check: a region with `trigger=release` and `amp_velcurve`
  plays at different levels for release 0.2 and 0.9 (or the device's queued event shows the
  release value).

##### REQ-012: Release modulator

The modulator system shall offer a `release` modulator kind. It is unipolar. For each voice it
outputs the default release (0.5) until that voice's note-off, then holds the note-off's release
velocity. The Modulators foldout shall list it with the other kinds.

- **Acceptance:** Rust test: a per-voice `release` modulator reads 0.5 while the note is held
  and 0.9 after a note-off with release 0.9. Godot test: the release kind can be added from the
  foldout and saves with the device.

##### REQ-013: Expression events have a place in the device interface

The device note interface shall be able to carry a per-note expression event (note id, key,
expression type, value) for the types pitch, gain, pan, timbre and pressure. Devices that don't
handle expressions shall ignore them. In this spec nothing sends one.

- **Acceptance:** Rust test sends an expression event to each built-in device and asserts
  nothing panics and the audio output is unchanged.

#### A3. Interop

##### REQ-014: DAWproject release velocity

WHEN a DAWproject file is imported, the importer shall keep each note's `vel` at full precision
and its `rel` as the note's release. The transfer report shall no longer list release velocity
as dropped. WHEN a project is exported, the exporter shall write `rel` for every note whose
release differs from the default.

- **Acceptance:** `test_dawproject_import.gd` and `test_dawproject_export.gd` cases with
  `vel="0.503"` / `rel="0.2"`. Round-trip in `test_dawproject_roundtrip.gd`.

### B. UI

#### B1. The value lane pane

##### REQ-015: Value lane pane

The MIDI editor shall have a pane below the note area holding a stack of **value lanes**. It
starts with one velocity lane. The pane can be shown and hidden with a toolbar toggle and with
a shortcut action that has no default key (bindable in Settings), and resized with a splitter.

- **Acceptance:** Godot test toggles the pane and asserts that it shows and hides and that its
  height is kept.

##### REQ-016: Adding and removing lanes

The pane shall let the user add a lane for any note value (velocity, release) and close any
lane. Which lanes are open, their heights and whether the pane is shown shall be kept across
sessions as an editor preference and not saved in the project.

- **Acceptance:** Godot test adds a release lane, closes the velocity lane, re-creates the
  editor, and asserts that the same lanes come back and the project JSON is unchanged.

##### REQ-017: Lanes follow the note area

The value lanes shall share the note area's horizontal zoom and scroll, so a stem is always
directly below its note.

- **Acceptance:** Godot test zooms and scrolls the note area and asserts that the stem x
  position equals the note's start x (velocity) or end x (release).

##### REQ-018: Stems

Each lane shall draw a stem per note, with height proportional to the value: velocity at the
note's start, release at the note's end. Hovering a stem shall highlight its note in the note
area, and hovering a note shall highlight its stems.

- **Acceptance:** Godot test checks stem geometry for known values (velocity 1.0 = full lane
  height). Hover highlighting is a live check.

##### REQ-019: Which notes show stems

The lanes shall show full stems for every note in an editable clip, coloured by track in track
mode. Context (non-editable) notes get no stems. Loop repeats and linked instances get ghost
stems, and editing a ghost stem edits the source note.

- **Acceptance:** Godot test in track mode with one editable and one context track and a looped
  instance: stem count = editable notes + repeat visuals, and editing a ghost changes the
  source note.

##### REQ-020: Display format

The lanes shall show values as 0–127 by default. WHERE the user has chosen percent in the
settings, they shall show 0–100%.

- **Acceptance:** Godot test on the formatter: velocity 100/127 shows "100", or "79%" in
  percent mode.

#### B2. Editing in a lane

##### REQ-021: Paint

WHEN the user left-drags in a lane, every stem the pointer passes over shall take the value at
the pointer's height. While notes are selected, only selected notes shall be painted. With no
selection, every stem at the pointer's x shall be painted.

- **Acceptance:** Godot test drags across three single notes and a chord with nothing selected
  (all stems take the pointer value), then repeats with one chord note selected (only that
  note changes).

##### REQ-022: Relative and scale drags

WHEN the user Alt-drags a stem, the selection (or, with no selection, the stems at that x)
shall shift by the same amount, each clamped to its range. WHEN the user Ctrl+Alt-drags, the
values shall be scaled toward 0 by the same factor.

- **Acceptance:** Godot test: velocities 0.4/0.6 Alt-dragged by +0.2 give 0.6/0.8, and
  Ctrl+Alt-dragged by half give 0.2/0.3.

##### REQ-023: Line

WHEN the user Ctrl-drags in a lane, the lane shall draw a straight line, and on release every
stem it crosses (only selected notes while a selection exists) shall take the line's value at
that stem's x.

- **Acceptance:** Godot test draws a line from 0.2 to 1.0 across five evenly spaced notes and
  asserts values 0.2, 0.4, 0.6, 0.8, 1.0.

##### REQ-024: Fine adjust, reset, exact value, readout

Holding Shift during a drag shall make value changes finer. Ctrl+clicking a stem (without
moving) shall reset it to the default. Double-clicking a stem shall open a field to type an
exact value in the display format. While dragging, a tooltip shall show the value in the
display format. These follow the shared value-control gestures in
`docs/subsystems/godot-ui-components.md`. (Amended at the design gate: originally a
double-click reset.)

- **Acceptance:** Godot test: Ctrl+clicking a release stem at 0.9 gives 0.5. Double-clicking a
  velocity stem and committing "64" gives 64/127. The Shift ratio and tooltip are live checks.

##### REQ-025: One undo step, one sync

Each lane gesture shall be one undo step. The engine shall receive note updates when the
gesture ends, not on every pointer move. WHILE the clip editor's audition toggle is on, a drag
on a single note's velocity stem shall audition that note at the new velocity.

- **Acceptance:** Godot test paints across five notes and asserts one history entry and five
  `update_note` sends after release (none during the drag). Undo restores all five.

##### REQ-026: Transforms

A lane's context menu shall offer **Set…** (one value), **Randomize…** (± amount around each
value) and **Scale…** (percentage around the mean). They act on the selected notes, or on every
note in the editable clips when nothing is selected. Each transform is one undo step.

- **Acceptance:** Godot test: Set 0.5 gives all 0.5. Scale 50% of 0.2/0.6 gives 0.3/0.5.
  Randomize ±0.1 with a fixed seed stays within ±0.1 and clamps to the range.

#### B3. Selection and new notes

##### REQ-027: Select a row's notes

WHEN the user clicks a drum row header in Drum View, the MIDI editor shall select every
editable note in that row. Shift-click shall add them to the selection. WHEN the user
Ctrl-clicks a piano key, it shall do the same for that pitch. A plain click on a key keeps
auditioning the note as it does today.

- **Acceptance:** Godot test clicks a row header with hits on three rows and asserts that only
  that row's notes are selected. Shift-click on a second row adds its notes. Ctrl-click on a
  piano key selects that pitch.

##### REQ-028: New notes inherit the last touched note's values

WHEN the user draws a new note, it shall take the velocity and release of the **last touched
note**: the note most recently clicked, dragged, or edited in a lane. Before any note has been
touched in the session, velocity is 100/127 and release 0.5. The MIDI editor toolbar shall show
the velocity the next note will get, and scrolling on that readout shall change it without
editing any note. Closes the `TODO.md` item "velocity of new notes is wrong".

- **Acceptance:** Godot test: touching a note with `vel` 0.3 / `rel` 0.7 and then drawing a
  note gives 0.3 / 0.7. Scrolling the readout up then drawing gives a higher velocity.

## Non-functional

- **Real-time safety:** note events, note-id allocation and the `release` modulator on the audio
  callback shall not allocate, block or lock. The note-id counter and any per-note bookkeeping
  are preallocated (the audio-thread contract, ADR-0002).
- **Latency / performance:** unchanged for playback. Drawing the value lanes shall not push
  `test_clip_editor_performance.gd` past its current budgets.
- **Compatibility:** pre-019 projects load with the same audible velocities (REQ-003). Projects
  saved by 019 are not meant to open in older builds. Godot and the engine are built together,
  so the OSC change needs no version skew handling.

## Out of scope

- Per-note expression curves (pitch, gain, pan, timbre, pressure): their model, OSC, editing,
  CLAP `NOTE_EXPRESSION` output, MPE/MIDI translation in the plugin host, and the per-voice
  modulator kinds for them. That's the next spec. This spec only reserves the device-interface
  slot (REQ-013).
- Generative note properties (chance, repeats, occurrence).
- MIDI clip recording (it doesn't exist yet).
- New ways of drawing velocity on the note itself. Note brightness stays as it is.
- Humanize (timing and velocity together).
- MIDI CC, pitch bend and channel pressure lanes in the clip editor. Track automation
  (spec 003) covers these.
- Translating notes for CLAP plugins that only accept the MIDI dialect. To be filed as its own
  issue.

## Open questions

None block the design. Decisions made while writing that weren't covered in the interview:

- [ ] Transforms with no selection act on every note in the editable clips (REQ-026).
- [ ] Ctrl-click on a piano key selects that pitch, since a plain click auditions (REQ-027).
- [ ] The display-format setting (0–127 or %) is one global setting, not per lane (REQ-020).
- [ ] Only a single-note velocity drag auditions. Painting across many notes doesn't (REQ-025).
