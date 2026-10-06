# Sampler Multisample — Requirements

## Problem

The built-in Sampler (`sonara.builtin.sampler`) plays exactly one audio file. To build an
instrument from several recordings, for example one sample every few keys or soft and hard hits,
users have to stack Samplers in a Layer with note maps, or write an SFZ file by hand for the SFZ
sampler. Neither lets you see or edit the key and velocity layout. The Sampler also has no Window
view or Companion view, so it can't use a device frame (spec 022) to show a bigger waveform.

This spec reverses spec 021's out-of-scope line "multi-sample zones (that's what the SFZ sampler
is for)". The Sampler gets native zones. The SFZ sampler stays the tool for large, disk-streamed
libraries.

## Scope

| | |
|---|---|
| Subsystem | both (Sampler engine device; Sampler device views in Godot) |
| Touches real-time audio thread | yes: zone selection at note-on and per-zone playback run in the audio callback; the design must respect the audio-thread contract |
| Adds or changes an OSC message | yes: zone, group and mode messages for the Sampler; `docs/subsystems/osc-protocol.md` is part of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes: the Sampler's device instance in `.sonara` and in device presets gains its mode, zones and groups. Old projects need no migration: a missing key means single-sample mode |

## Terms

- **Single-sample mode**: today's Sampler, one file. Its playback settings are device parameters.
- **Multisample mode**: the Sampler holds a list of zones and picks among them at each note-on.
- **Zone**: one sample in a multisample, with its key range, velocity range and per-zone
  settings. The UI calls it a "sample".
- **Group**: a named set of zones. A zone is in at most one group. Zones without a group are
  "Ungrouped". A group has no sound of its own. It carries what applies to several zones at once
  (gain, mute, solo, play mode, and later its output).
- **Focused zone**: the zone the waveform and per-zone controls show and edit, which is the one
  last clicked or selected.
- **Per-zone settings**: root key, tune, fine tune, gain, start, end, reverse, loop mode, loop
  start, loop end, loop crossfade, key fades and velocity fades.
- **Device-wide settings**: everything else (amp envelope, filter, speed, voices, play mode,
  velocity amount, key track, volume).

## Requirements

### Phase 1: Views

#### REQ-001 — Window view

The Sampler shall have a Window view that shows the interactive sample display (waveform with
play and loop handles and playheads, as in the Panel view) filling the view, and that can be
opened in a device frame like any other Window view.

- **Acceptance:** open the Sampler's window from the device lane. A device frame shows the
  waveform at the frame's size. Dragging the Start handle there moves the Start knob in the
  Companion view.

#### REQ-002 — Companion view

WHILE the Sampler's Window view is open, the device panel shall show a Companion view with the
same controls as the Panel view but no waveform.

- **Acceptance:** open the window. The panel's waveform disappears and every knob, segment and
  checkbox of the Panel view is still there and works. Close the window and the Panel view
  returns.

#### REQ-003 — Views stay in sync

The Panel, Companion and Window views of one Sampler shall always show the same values, whichever
view made the change.

- **Acceptance:** change Loop Mode in the Companion view. The Window view's loop handles appear
  immediately.

### Phase 2: Multisample mode

#### Entering and leaving the mode

#### REQ-010 — Empty Sampler placeholder

WHILE the Sampler has no sample, its waveform area shall show "Drop sample(s) here" and a
"Create Multisample" button. Pressing the button switches the Sampler to multisample mode with
no zones.

- **Acceptance:** add an empty Sampler. The placeholder and button show. Press the button and the
  multisample editor appears in the Window view with an empty zone map.

#### REQ-011 — Single drop replaces

WHILE the Sampler is in single-sample mode, WHEN one audio file is dropped on its waveform, the
Sampler shall replace its sample with that file and stay in single-sample mode.

- **Acceptance:** drop `kick.wav` on a Sampler holding `snare.wav`. It plays `kick.wav` and no
  multisample UI shows.

#### REQ-012 — Multi drop enters multisample mode

WHILE the Sampler is in single-sample mode, WHEN two or more audio files are dropped on it, the
Sampler shall switch to multisample mode with one zone per dropped file. A sample it already held
shall be kept as a zone too, with its per-zone settings taken from the parameters as in REQ-013
and its Root parameter as its root key. All of them are then laid out together as in REQ-020.

- **Acceptance:** select three files in the Browser and drop them on an empty Sampler. The Window
  view shows three zones, and playing each zone's key range plays its file. Drop three files on a
  Sampler that holds one sample: there are four zones, and the old one still plays with its loop
  points.

#### REQ-013 — Explicit switch keeps the current sample

WHEN the user chooses "Convert to Multisample" on a Sampler in single-sample mode that holds a
sample, the Sampler shall switch to multisample mode with that sample as its one zone. The zone
covers all keys and velocities, and its per-zone settings come from the current parameter values
(Root, Tune, Fine, Start, End, Reverse, Loop Mode, Loop Start, Loop End, Crossfade).

- **Acceptance:** with Root = D3 and a loop set, convert. The single zone has root D3 and the
  same loop points, and it sounds the same as before conversion.

#### REQ-014 — Back to single-sample mode

WHEN the user chooses "Convert to Single Sample" in multisample mode, the Sampler shall keep only
the focused zone, copy its per-zone settings into the matching device parameters, and switch to
single-sample mode.

- **Acceptance:** focus a zone with root E2, convert. The Sampler is in single-sample mode with
  that file and Root = E2.

#### REQ-015 — Adding zones in multisample mode

WHILE the Sampler is in multisample mode, WHEN audio files are dropped on the waveform, the
sample list or the zone map, the Sampler shall add one zone per file and keep the existing zones.
A drop on the zone map shall place the new zones starting at the key under the pointer.

- **Acceptance:** with four zones, drop two more on the map over F3. There are six zones, and the
  new ones start at F3.

#### Playback

#### REQ-016 — Zone selection at note-on

WHILE in multisample mode, WHEN a note-on arrives, the Sampler shall start a voice for every zone
whose key range contains the note and whose velocity range contains the velocity, subject to
group mute/solo (REQ-031) and round robin (REQ-032).

- **Acceptance:** zone A covers C3–B3 at velocity 1–64 and zone B covers C3–B3 at 65–127. Note E3
  at velocity 40 plays only A, and at 100 plays only B. A note outside every zone is silent.

#### REQ-017 — Per-zone playback settings

WHILE in multisample mode, each voice shall play with its zone's per-zone settings, combined with
the device-wide settings. The device parameters Root, Tune, Fine, Start, End, Reverse, Loop Mode,
Loop Start, Loop End and Crossfade shall have no effect on playback in this mode.

- **Acceptance:** two zones on different keys, one looping and one reversed. Each plays its own
  way. Automating the device Tune parameter changes neither.

#### REQ-018 — Key tracking per zone

WHILE in multisample mode, a zone's pitch shall follow the played note relative to the zone's
root key, whatever the device Key Track parameter is set to.

- **Acceptance:** a zone with root C3 covering C3–E3 plays E3 four semitones up.

#### REQ-019 — Note-off and voices

WHEN a note-off arrives, the Sampler shall apply it to every voice started by that note's
note-on. The Voices setting shall cap the total number of sounding voices across all zones. A
note that plays two stacked zones uses two voices.

- **Acceptance:** two stacked zones in Gated mode: note-off releases both. With Voices = 2,
  holding two notes on two stacked zones steals the oldest voice when the third voice starts.

#### Default layout

#### REQ-020 — Root key from file name

WHEN zones are created from dropped files, the Sampler editor shall set each zone's root key from
a note name or MIDI number in its file name, recognizing `C3`, `C#3`, `Db3`, `c-1` and a
standalone 0–127 number (C3 = 60). Each zone's key range shall reach halfway to its neighbors'
root keys, and the lowest and highest zones shall cover the remaining keys down to 0 and up to
127. Velocity ranges are 1–127.

- **Example:** `Piano_C3.wav`, `Piano_E3.wav`, `Piano_G#3.wav` → roots 60, 64, 68 and ranges
  0–62, 63–66, 67–127.
- **Fallback:** IF no dropped file name yields a note, THEN zones get consecutive single keys in
  drop order, starting at C3 (or at the key under the pointer for a map drop), each with its root
  key on that key.
- **Mixed:** IF only some names yield a note, THEN the ones without a note use the consecutive
  layout after the highest detected zone.
- **Acceptance:** Godot unit test with the example names and with names like `kick.wav`.

#### Focus and groups

#### REQ-021 — Focused zone

WHILE in multisample mode, the Sampler shall have one focused zone, the zone last clicked in the
list or the map (or the first zone added when none was focused). The waveform shall show the
focused zone's sample with a label of its name, and its handles shall edit that zone's start,
end and loop points.

Clicking the name label on the waveform shall open a menu of all zones, sorted by root key.
Choosing one focuses it, so focus can change from the Panel view without opening the window.

- **Acceptance:** click zone B in the map. The waveform shows B's file and name. Dragging Start
  changes B's start only. In the Panel view, click the label and choose zone A: the waveform
  shows A.

#### REQ-022 — Per-zone controls follow focus

WHILE in multisample mode, the controls for per-zone settings in the Panel and Companion views
(Root, Tune, Fine, Reverse, Loop Mode, Crossfade) shall show and edit the focused zone, and shall
be visibly marked as applying to the focused sample. Device-wide controls stay as they are.

- **Acceptance:** zones A (root C3) and B (root G3). Focus A and the Root knob shows C3. Focus B
  and it shows G3. Turning Root edits B only.

#### REQ-023 — Zone strip in the Companion view

WHILE in multisample mode, the Companion view shall show, in the space the Panel view uses for
the waveform, the focused zone's name, group, key range, velocity range, gain, key fades and
velocity fades, all editable.

- **Acceptance:** with the window open, change the focused zone's gain in the Companion view. The
  zone's level changes, and the Window view's map still shows the same zone focused.

#### REQ-024 — Playheads follow the focused zone

WHILE in multisample mode, the sample display shall draw playheads only for voices playing the
focused zone.

- **Acceptance:** play a chord across two zones. The waveform shows playheads only for the notes
  in the focused zone.

#### REQ-025 — Groups

The Sampler editor shall let the user create, rename and delete groups and move selected zones
into a group or back to Ungrouped. Deleting a group shall move its zones to Ungrouped.

- **Acceptance:** create group "Soft", move two zones into it, delete "Soft". Both zones are
  Ungrouped and still play.

#### Editing and persistence

#### REQ-026 — Undo

Every edit to the mode, zones, groups and per-zone settings shall be one undoable step, and a
continuous drag shall be one step.

- **Acceptance:** drag a zone across four keys, then undo once. It is back where it started.

#### REQ-027 — Persistence

The Sampler's mode, zones (file, ranges, per-zone settings, group), groups (name, gain, mute,
solo, round-robin mode) and focused zone shall be saved with the project and in device presets,
and restored on load.

- **Acceptance:** build a three-zone multisample with one group, save, reopen. Same zones,
  groups, focus and sound. Same for save and load as a device preset. A project saved before
  this spec loads in single-sample mode, unchanged.

#### REQ-028 — Missing sample files

IF a zone's file can't be loaded, THEN that zone shall stay in the list and map, marked as
missing with the reason, play silence, and not affect other zones.

- **Acceptance:** rename one zone's file on disk and reopen the project. That zone shows
  "missing", and the others play.

#### Extras

#### REQ-030 — Zone crossfades

Each zone shall have a key fade-in and fade-out (in semitones, from the low and high edges of its
key range) and a velocity fade-in and fade-out (in velocity steps). A note inside a fade region
shall play that zone at an equal-power gain between 0 and 1 for its position in the fade.

- **Example:** zone covers velocity 1–80 with a velocity fade-out of 20. Velocity 70 plays it at
  gain cos(π/2 · (70−60)/20) ≈ 0.71.
- **Acceptance:** engine unit test on the gain at the fade edges, the middle and outside the
  fade.

#### REQ-031 — Group gain, mute and solo

Each group, and Ungrouped, shall have gain, mute and solo. A muted group's zones shall not start
voices. WHILE any group is soloed, only zones in soloed groups shall start voices. Group gain
shall multiply the zone gain.

- **Acceptance:** solo "Soft": only Soft's zones sound. Mute it instead: everything else sounds.

#### REQ-032 — Round robin and random

Each group, and Ungrouped, shall have a play mode: **All** (default, every matching zone plays),
**Round robin** (each note-on plays the next of that group's matching zones in turn) or
**Random** (each note-on plays one of that group's matching zones at random, avoiding the zone
played last when there is more than one).

- **Acceptance:** three zones stacked on C3 in a round-robin group. Four C3 hits play zone 1, 2,
  3, 1. In Random mode, 100 hits never play the same zone twice in a row and hit all three.

### Phase 2: Window view multisample editor

#### REQ-040 — Layout and visibility

WHILE in multisample mode, the Window view shall show the multisample editor above the waveform:
a header with group filter buttons, then a resizable split with the sample list on the left and
the zone map on the right. WHILE in single-sample mode, the editor shall be hidden.

- **Acceptance:** convert to multisample and the editor appears. Convert back and it is gone, and
  the waveform fills the view.

#### REQ-041 — Group filter

The header shall show an "All" button, an "Ungrouped" button and one button per group. Clicking
one shows only its zones in the list and map. Ctrl-click adds or removes it from the visible set.
"All" shows everything. Each group button shall offer gain, mute and solo (REQ-031) and the play
mode (REQ-032).

- **Acceptance:** click "Soft" and only Soft's zones show. Ctrl-click "Ungrouped" and Ungrouped
  zones show too.

#### REQ-042 — Sample list

The sample list shall show the visible zones by name, filtered by a search field (case-insensitive
substring of the name). Click selects one zone, Ctrl-click toggles a zone, Shift-click selects a
range, and the clicked zone becomes focused. Selection is shared with the zone map.

- **Acceptance:** type "soft" and only names containing it show. Shift-click selects the range,
  and the map highlights the same zones.

#### REQ-043 — Zone map axes and piano

The zone map shall plot keys left to right and velocity bottom to top (1 at the bottom, 127 at
the top), with a horizontal piano keyboard along the bottom. Clicking a piano key shall play that
note into the Sampler at a velocity set by the click height on the key (higher up = louder), and
release it on mouse-up.

- **Acceptance:** click near the top of C3: the Sampler plays C3 at a high velocity. Click near
  the bottom and it plays quietly.

#### REQ-044 — Zone rectangles

Each visible zone shall be drawn as a rectangle spanning its key range and velocity range, labeled
with its name. The label shall be rotated −90° when the rectangle is taller than it is wide, and
shall be clipped to the rectangle. Selected zones shall be drawn in the selection color, the
focused zone shall be marked further, and missing zones (REQ-028) shall be drawn as missing.

- **Acceptance:** a one-key zone shows a vertical label clipped to its rectangle. A selected zone
  uses the selection color.

#### REQ-045 — Select, move and resize

In the zone map, left-click shall select and focus the zone under the pointer, with Ctrl and Shift
as in the list. Left-drag inside a zone shall move every selected zone by whole keys and whole
velocity steps, keeping their sizes. Dragging a zone's left or right edge shall change its key
range, and dragging its top or bottom edge shall change its velocity range. The pointer shall show
the matching resize cursor over edges. Ranges stay within 0–127 keys and 1–127 velocity and are
never empty. Clicking empty space clears the selection.

- **Acceptance:** drag the right edge of a C3–E3 zone two keys right: C3–F#3. Drag it far left:
  it stops at C3–C3. Move two selected zones: both shift by the same amount.

#### REQ-046 — Overlapping zones

WHEN the user left-clicks repeatedly at one spot covered by several zones, the zone map shall
cycle the selection through those zones. WHEN the user right-clicks, the zone map shall open a
context menu listing the zones under the pointer (selecting one selects and focuses it),
followed by the batch operations for the selection.

- **Acceptance:** three stacked zones. Three clicks focus each one in turn. Right-click lists all
  three, and choosing the second focuses it.

#### REQ-047 — Batch operations

The zone map and sample list context menus shall offer, for the selected zones:

- **Assign velocity**: set every zone's velocity range to the given range (or single value).
- **Assign note**: set every zone's key range to the given range (or single key).
- **Distribute on velocity**: split the given velocity range across the zones in list order,
  without changing key ranges. Option: **stretch** (contiguous slices that fill the range) or
  **gaps** (equal slices of the given size, with the rest of the range left empty).
- **Distribute on notes**: split the given key range across the zones, ordered by root key, with
  stretch (the default) or gaps, without changing velocity ranges.
- **Set root from name**: re-run REQ-020's name detection for the root key only.
- **Move to group** and **Delete**.

Assign and distribute shall open a popup to set the range and options before applying. Each batch
operation shall be one undo step. The menus shall use the app's context-menu style.

- **Example:** distribute four zones on velocity 1–127, stretch → 1–32, 33–64, 65–96, 97–127.
- **Acceptance:** Godot unit test for each operation's range math, including uneven splits and
  more zones than steps.

#### REQ-048 — Keyboard

WHILE the zone map or sample list has focus, Delete shall remove the selected zones and Ctrl+A
shall select all visible zones.

- **Acceptance:** select two zones and press Delete. They are removed, and one undo restores them.

## Non-functional

- **Real-time safety:** choosing zones at note-on and playing per zone in the audio callback don't
  allocate, lock or do I/O. Adding a zone or replacing its PCM never frees PCM on the audio
  thread. Zone edits under the state lock are O(zones) at most.
- **Capacity:** at least 256 zones per Sampler. Choosing zones at note-on stays bounded for that
  count. The editor stays interactive while dragging at that count.
- **Memory:** all zone PCM is decoded into RAM, as for single-sample mode. This is a known limit:
  large libraries belong in the SFZ sampler.
- **Compatibility:** single-sample mode behaves exactly as today, including its parameter IDs and
  saved values. Projects and presets saved before this spec load unchanged.

## Out of scope

- SFZ import and export (follow-up). Zone fields are kept SFZ-mappable to make it easy later.
- Group outputs: routing groups to extra outputs and return channels (follow-up spec 024, "Sampler
  group outputs"). Groups are the future routing unit, so group data must be able to take an
  output assignment without a format break. Several groups may share one output, and "Separate
  channel" on a group creates its return channel the way Layer's separate out does.
- Streaming samples from disk.
- Per-zone filter, envelope or pan, and automating or modulating per-zone settings.
- Keyswitches, release triggers, and choosing a group by a controller value.
- Highlighting incoming MIDI notes on the zone map's piano.
- Automatic loop-point detection and zero-crossing snapping.
- Carrying multisample zones across DAWproject import/export.
- Multisample support in the SFZ sampler or Drum Machine pads beyond what a Sampler inside a pad
  gets for free.

## Open questions

Resolved (2026-10-06):

- [x] **REQ-012:** a sample already in a single-sample Sampler is kept as a zone when 2+ files are
  dropped.
- [x] **REQ-041:** clicking a group filter shows only that group, and Ctrl-click adds more.
- [x] **REQ-019:** Voices counts zone voices, not notes.
