# Note Maps and Drum View — Requirements

## Problem

The clip editor shows every MIDI note as an unlabeled piano lane. That makes drum parts slow to
write, because the user has to remember that D1 is the snare and scroll past 100 unused lanes to
find it. The same is true for instruments with keyswitches, where a handful of keys switch
articulations and nothing on screen says which. The Drum Machine already knows what is on each
pad, but only the assistant's clip text uses that. The piano roll shows none of it. Users notice
this whenever they program drums or a keyswitched instrument.

## Scope

| | |
|---|---|
| Subsystem | Godot (data model, clip editor, a new note map editor popup, assistant clip text). No engine changes |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no. Auditioning uses the existing preview-note path |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. Channels in `.sonara` gain a note map assignment, an embedded copy of a named map, and a Drum View preference. A new user library of named note maps lives in the user config directory. Older projects have no assignment and load as Auto (REQ-012) |

## Terms

- **Note Map**: a set of *entries*, at most one per MIDI pitch (0–127). Each entry has a name and a
  color. A pitch without an entry is *unmapped*.
- **Auto map**: a Note Map derived live from a channel's instrument and never stored. In this spec
  the only source is a Drum Machine.
- **Named map**: a user-authored Note Map with a name. It can be saved to and loaded from the
  *note map library*.
- **Assignment**: a channel's Note Map setting, one of *None*, *Auto*, or a *named map*.
- **Effective map**: the Note Map the clip editor uses for a track. It is the map assigned to the
  channel the track plays (its default channel).
- **Piano roll view**: today's clip editor layout, one lane per pitch.
- **Drum View**: the alternative clip editor layout, one *row* per shown pitch.

## Requirements

### Assignment

### REQ-001 — Channel note map assignment

The project model shall store a note map assignment on every channel: None, Auto, or a named map.
New channels default to Auto.

- **Acceptance:** headless Godot test. A new channel reports Auto. Set it to a named map "Kontakt
  Strings", save and reload the project, and the channel reports that named map with identical
  entries.

### REQ-002 — Auto map from a Drum Machine

WHILE a channel is set to Auto and has a Drum Machine on its root chain, the effective map shall
have one entry per pad that has a pad device. Each entry's name shall be the pad device's display
name, and its color shall be the color of that pad's return channel. If there are several Drum
Machines, the first one on the root chain is used.

- **Acceptance:** headless test. Drum Machine with "Kick" on 36 (return colored red) and "Snare"
  on 38 (return colored blue) → the effective map is exactly {36: Kick/red, 38: Snare/blue}.
- **Example:** an empty pad on 42 → pitch 42 is unmapped.

### REQ-003 — Auto map with no source

WHILE a channel is set to Auto and has no Auto map source, the effective map shall be empty.

- **Acceptance:** headless test. An Auto channel with only a Polysynth has no entries.

### REQ-004 — Auto map follows the pads

WHEN a pad device is added, removed, renamed or moved to another note, or a pad's return channel
color changes, an open clip editor shall show the updated names, colors and Drum View rows without
reopening the clip.

- **Acceptance:** live. Open a Drum Machine clip in Drum View and rename the pad device on 38 to
  "Rim". The row label changes immediately. Move it to 40 and the row moves to 40.

### REQ-005 — Auto maps are read-only

WHILE the note map editor shows an Auto map, it shall show the names and colors but not allow
editing them. "Save as…" stays available (REQ-027).

- **Acceptance:** live. Open the note map editor on a Drum Machine channel. The name field, color
  picker and reset button are disabled.

### Note map editor

### REQ-006 — Editing an entry

The note map editor shall show a piano keyboard covering all 128 pitches. WHEN the user selects a
key, the editor shall show that key's name in a text field and its color in a color picker.
Changing either one updates the entry for that pitch.

- **Acceptance:** live. Select C1 (36), type "Kick" and pick red. The C1 key shows "Kick" in red,
  and the open clip editor labels lane 36 "Kick".

### REQ-007 — Resetting an entry

WHEN the user presses the reset (X) button next to the name field, the note map editor shall
remove the selected pitch's entry so the pitch becomes unmapped.

- **Acceptance:** live. Press X with C1 selected. The C1 key loses its label and color, and lane 36
  in the clip editor is unlabeled again.

### REQ-008 — Auditioning keys

WHEN the user clicks a key in the note map editor, the editor shall play that pitch on the channel
being edited.

- **Acceptance:** live. On a Drum Machine channel, clicking C1 plays the kick.

### REQ-009 — Saving to the library

WHEN the user saves a map under a name, the note map editor shall store it in the note map library
so that any project can load it after an application restart. Saving under an existing name asks
before overwriting.

- **Acceptance:** headless test (library save/load round trip) plus a live check across a restart.

### REQ-010 — Loading from the library

WHEN the user picks a named map from the library for a channel, the project model shall assign a
copy of that map to the channel.

- **Acceptance:** headless test. Load "GM Drums" onto a channel. The channel's entries equal the
  library entries.

### REQ-026 — Edits stay in the project

WHEN the user edits a named map assigned to a channel, the project model shall change only that
channel's embedded copy. The library entry changes only when the user explicitly saves.

- **Acceptance:** headless test. Load "GM Drums", rename 36 to "Kick 2" on the channel, and the
  library's "GM Drums" still says "Kick" (or whatever it said before).

### REQ-027 — Saving an Auto map as a named map

WHEN the user chooses "Save as…" on an Auto map, the note map editor shall store its current names
and colors as a new named map in the library, and shall then assign that named map to the channel,
so the user continues editing the map they just saved rather than the read-only Auto one.

- **Acceptance:** headless test. Drum Machine {36: Kick, 38: Snare} → "Save as" "My Kit" gives a
  library map with those two entries, and the channel then reports the named map "My Kit" with the
  same entries.

### REQ-011 — Projects are self-contained

The project file shall embed each channel's named map, so the project shows the same names and
colors on a machine whose library lacks that map.

- **Acceptance:** headless test. Save a project with "GM Drums" assigned, delete the library entry,
  and reload. The channel still has all GM Drums entries.

### REQ-012 — Older projects

IF a saved channel has no note map assignment, THEN the project model shall load it as Auto.

- **Acceptance:** headless test. Load a project JSON with no note map keys. Every channel reports
  Auto.

### Piano roll view

### REQ-013 — Labeled keys

WHILE the effective map has entries, the clip editor's piano keyboard shall show each mapped
pitch's name on its key, tinted with the entry's color.

- **Acceptance:** live. With {36: Kick/red}, the C1 key reads "Kick" and is tinted red. Unmapped
  keys look as they do today.

### REQ-014 — Tinted lanes

WHILE the effective map has entries, the clip editor shall tint each mapped pitch's lane with the
entry's color. Unmapped lanes shall look as they do today.

- **Acceptance:** live. Lane 36 is visibly red-tinted; lane 37 is unchanged.

### Drum View

### REQ-015 — Toggling Drum View

The clip editor shall provide a control that switches between the piano roll view and Drum View.
Switching shall keep the note selection, and shall keep a currently visible pitch in view when that
pitch has a row.

- **Acceptance:** live. Select two notes on 36 and 38 and toggle. Both stay selected, and row 36
  is on screen.

### REQ-028 — Drum View is remembered per channel

The project model shall remember, per channel, whether its clips open in Drum View. A channel
where the user never chose a view shall open in Drum View when its effective map comes from a Drum
Machine, and in the piano roll view otherwise.

- **Acceptance:** headless test. A new Drum Machine channel reports Drum View, and a new Polysynth
  channel reports piano roll. Toggle the Drum Machine channel to piano roll, save and reload, and
  it still reports piano roll.

### REQ-016 — Rows

WHILE in Drum View, the clip editor shall show one row for each pitch that is mapped in the
effective map or has at least one note in the bound clips, ordered by pitch with the lowest at the
bottom. All other pitches are hidden.

- **Acceptance:** headless test of the row set. Map {36, 38, 42} with clip notes on 38 and 50 gives
  rows [36, 38, 42, 50].

### REQ-017 — Unmapped rows are marked

WHILE in Drum View, a row for an unmapped pitch shall be labeled with its note name (C3 = 60) and
styled differently from mapped rows.

- **Acceptance:** live. In the example above, row 50 reads "D2" and looks different from rows 36,
  38 and 42.

### REQ-018 — Row labels

WHILE in Drum View, the clip editor shall replace the piano keyboard with row labels that show the
entry name (or note name) and the entry color. Clicking a label shall audition the row's pitch (when audition toggle is on at the bottom of the note editor).

- **Acceptance:** live. Row 36 reads "Kick" in red, and clicking it plays the kick.

### REQ-019 — Drawing hits

WHEN the user adds a note in a Drum View row, the clip editor shall create a note at that row's
pitch, with its start snapped to the grid and its length equal to one grid step.

- **Acceptance:** live with the grid at 1/16. Clicking row 38 at beat 2 creates a note on 38 at
  tick 960 with length 240 (960 PPQ).

### REQ-020 — Moving between rows

WHILE in Drum View, dragging a note vertically (or transposing it up or down one step with the
keyboard) shall move it to the pitch of the adjacent row, not the adjacent semitone.

- **Acceptance:** live. Rows [36, 38, 42]. Dragging a note from 38 up one row puts it on 42.

### REQ-021 — Rows stay put while dragging

IF a drag would leave an unmapped row empty or put notes on a new pitch, THEN the clip editor shall
keep the row set unchanged until the drag ends, and update it afterwards.

- **Acceptance:** live. Dragging the only note on unmapped row 50 to row 42 doesn't shift the rows
  during the drag. Row 50 disappears on release.

### REQ-022 — Notes drawn as hits

WHILE in Drum View, the clip editor shall draw each note as a hit marker at its start, shaded by
velocity. Moving, copying or pasting a note shall keep its stored length unchanged.

- **Acceptance:** live. A note with length 1920 shows as a single marker. After dragging it to
  another beat its length is still 1920 (visible after switching back to the piano roll view).

### REQ-023 — Empty Drum View

IF Drum View would have no rows, THEN the clip editor shall show a hint with a way to open the
note map editor for the channel.

- **Acceptance:** live. An Auto channel with a Polysynth and an empty clip in Drum View shows the
  hint, and clicking it opens the editor.

### REQ-024 — Several tracks at once

WHILE the clip editor shows clips from more than one track in Drum View, rows shall be the union of
the rows for each track. Labels and colors shall come from the effective map of the active note
editor's track.

- **Acceptance:** headless row-set test with two tracks mapped {36} and {38} → rows [36, 38].

### Assistant

### REQ-025 — Assistant uses the effective map

WHEN the assistant renders or parses a drum clip as text, it shall take lane names from the
track's effective map, so named maps label lanes as well as Drum Machine pads.

- **Acceptance:** headless test in `Godot/ai/tests/`. A channel with the named map {36: "Kick",
  38: "Snare"} and no Drum Machine renders drum lanes named KICK and SNARE.

## Non-functional

- **Real-time safety:** unchanged. No audio-thread or engine code is involved.
- **Latency / performance:** switching views and row-set updates stay under one frame for clips with
  up to 10,000 notes. Auto map updates are coalesced to at most one per frame.
- **Compatibility:** older `.sonara` files load as Auto (REQ-012). A map copy embedded in a project
  is never overwritten by library changes.

## Out of scope

- Other Auto map sources: the CLAP `note-name` extension and SFZ `label_key` / `sw_label`. The
  design should leave room for them.
- Keyswitch semantics (articulation or sound-variation switching, latching, a lane that shows the
  active articulation). Maps are labels and colors only.
- Input→output pitch remapping (Cubase-style I-note/O-note), per-row mute/solo, custom row order.
- Import/export of map files outside the library.
- Editing an Auto map. Names come from pad devices and colors from return channels. It can only be
  saved as a new named map (REQ-027).

## Open questions

- [x] Editing a named map assigned to a channel changes only the project's copy. Saving to the
      library is explicit (REQ-026).
- [x] Drum View is on by default for Drum Machine channels, and the choice is remembered per
      channel (REQ-028).
- [x] An Auto map can be saved as a new named map, and saving switches the channel onto it
      (REQ-027; revised after the first live pass, where staying on the read-only Auto map after a
      save was confusing).
- [x] A pad with no device gets no Auto map entry. It only gets a row if the clip has notes on it
      (REQ-002, REQ-016).
