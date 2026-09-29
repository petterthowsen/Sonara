# Clip Editor Track List — Requirements

## Problem

The clip editor's track mode only lists the tracks of the clips that were selected in the
arranger, so bringing another track into view means going back to the arranger. The list
items are flat colour bars with no padding and no per-track controls. You can't choose which
tracks are shown or which ones can be edited, and only the focused track's notes react to the
mouse. In clip mode the header gives no hint of which clip is open, and the mode switch is a
plain text button labelled "Clip Mode" or "Track Mode".

## Scope

| | |
|---|---|
| Subsystem | Godot (clip editor) |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no. Visibility, editability and solo state last for the session only |

## Terms

- **Selected track**: the track that is highlighted in the clip editor's track list. New notes
  go on this track, and keyboard shortcuts act on it. The code calls it the focused track.
- **Visible track**: a track whose notes the note editor draws.
- **Editable track**: a visible track whose notes respond to the mouse. A hidden track is never
  effectively editable, even when its edit toggle is on.
- **Solo**: a temporary state, entered with Shift+click on one track's toggle, in which only
  that track has the toggle on. It remembers the previous states so that they can be restored.

## Requirements

### Header and mode toggle

#### REQ-001 — Clip name in the header

WHILE the clip editor is in clip mode, the clip editor's main header shall show the name of the
bound clip. The name shall update when the clip is renamed.

- **Acceptance:** Godot test. Bind a clip named "Bassline" in clip mode and the header label
  reads "Bassline". Rename the clip to "Bass 2" and the label reads "Bass 2".
- **Example:** Double-click the clip "Chords" in the arranger. The header shows "Chords" next to
  the mode toggle.

#### REQ-002 — Icon mode toggle

The clip editor shall show the track/clip mode switch as a toggle button with an icon. The
button shall be pressed in track mode, released in clip mode, and its tooltip shall name the
mode it switches to.

- **Acceptance:** Godot test. In clip mode the toggle is released and has a non-null icon. In
  track mode it is pressed. Also checked live.

#### REQ-003 — Header in track mode

WHILE the clip editor is in track mode, the main header shall not show a clip name.

- **Acceptance:** Godot test. After switching to track mode, the clip name label is hidden.

### Track list contents and look

#### REQ-010 — All tracks listed

WHILE the clip editor is in track mode, the track list shall list every instrument track in
the project in arranger visual order, not only the tracks of the selected clips. Audio, folder
and group tracks are not listed.

- **Acceptance:** Godot test. In a project with three instrument tracks and one audio track,
  selecting a clip on one instrument track and entering track mode lists all three instrument
  tracks, in arranger order.

#### REQ-011 — List follows the project

WHEN an instrument track is added to the project, removed from it, reordered or renamed while
track mode is shown, the track list shall update to match.

- **Acceptance:** Godot test. Add a track and the list has one more item. Remove it and the
  item disappears. If the removed track was selected, REQ-032 applies.

#### REQ-012 — Item styling

Each track list item shall have inner padding and a soft rounded border, and the selected item
shall have a white border. Unselected items keep the track colour as their background, as they
do today.

- **Acceptance:** Live visual check. Godot test: the selected item's style has a white border
  colour and the other items' styles do not.

### Visibility and editability toggles

#### REQ-020 — Two toggles per item

Each track list item shall show a visibility toggle with an eye / eye-off icon and an
editability toggle with an icon. Clicking a toggle flips that state for that track only, and
clicking a toggle shall not change the selected track.

- **Acceptance:** Godot test. Clicking a visible track's eye hides that track and leaves the
  selected track unchanged.

#### REQ-021 — Initial states

WHEN track mode is entered from an arranger selection, the tracks of the selected clips shall
start visible and editable, and every other listed track shall start hidden and not editable.
WHEN track mode is re-entered with no new selection, the states from the previous track mode
session shall be kept.

- **Acceptance:** Godot test. Selecting clips on tracks A and C out of A, B and C gives A and C
  visible and editable, and B hidden and not editable.

#### REQ-022 — Visibility controls drawing

WHILE a track is hidden, the note editor shall draw none of that track's notes. WHILE it is
visible but not editable, its notes shall be drawn dimmed as context, as inactive tracks are
today.

- **Acceptance:** Godot test. Hiding track B leaves no drawn notes for B. Showing B makes them
  appear again.

#### REQ-023 — Hidden implies not editable

WHILE a track is hidden, the track shall not be editable whatever the state of its edit toggle,
and the edit toggle shall be drawn dimmed. WHEN the track becomes visible again, its edit
toggle's own state shall apply again.

- **Acceptance:** Godot test. Take a track that is editable, hide it, then show it again: it is
  editable, and while hidden its notes ignore clicks.

#### REQ-024 — Drag to toggle many

WHEN the user presses on a toggle and drags vertically over other items in the list, every
item the pointer passes over shall have the same kind of toggle (visibility or editability) set
to the state that the first click produced.

- **Acceptance:** Godot test with simulated input. With A, B, C and D all visible, press on A's
  eye (A is now hidden) and drag over B and C, then release. A, B and C are hidden and D stays
  visible. Dragging back over B during the same press does not flip it again.

#### REQ-025 — Shift+click solo

WHEN the user Shift+clicks a toggle on track X, the clip editor shall remember every track's
state for that toggle kind, turn the toggle on for X and turn it off for every other track.
WHILE that solo is active, the soloed toggle's icon shall be drawn in the accent colour.

- **Acceptance:** Godot test. With A and B visible and C hidden, Shift+clicking C's eye gives
  C visible and A and B hidden, and C's eye is marked as soloed.

#### REQ-026 — Shift+click again reverts

WHEN the user Shift+clicks the soloed toggle again, the clip editor shall restore the
remembered states for that toggle kind and end the solo.

- **Acceptance:** Godot test. Continuing REQ-025, Shift+clicking C's eye again gives A and B
  visible and C hidden.

#### REQ-027 — Solo moves, plain click ends it

WHILE a solo of a toggle kind is active:
- WHEN the user Shift+clicks the same kind of toggle on another track Y, the solo shall move to
  Y and keep the originally remembered states, so reverting later restores the states from
  before the first solo.
- WHEN the user plain-clicks or drag-toggles any toggle of that kind, the solo shall end, the
  current states shall be kept as they are, and the click shall then apply normally.

Visibility solo and editability solo shall be tracked independently of each other.

- **Acceptance:** Godot test. Solo A, then solo B, then revert: this restores the states from
  before A was soloed. Solo A, then plain-click B's eye: A and B are visible, the rest stay as
  they were during the solo, and no toggle is marked soloed.

### Selection and editing across tracks

#### REQ-030 — Selected track is visible and editable

WHEN the user selects a track in the track list, the clip editor shall make that track visible
and editable if it was not already.

- **Acceptance:** Godot test. Clicking the name area of a hidden track B selects B and makes B
  visible and editable.

#### REQ-031 — Selection follows editability

IF the selected track stops being effectively editable (it is hidden, its edit toggle is turned
off, or a solo turns it off), THEN the clip editor shall select the first effectively editable
track in list order. IF there is none, the clip editor shall have no selected track and a
click on empty grid space shall place no note.

- **Acceptance:** Godot test. With A selected and B editable, soloing B's edit toggle selects B.
  Turning off every edit toggle leaves no track selected, and a click on empty grid space adds
  no note to any clip.

#### REQ-032 — Removed selected track

IF the selected track is removed from the project, THEN the clip editor shall behave as in
REQ-031.

- **Acceptance:** Godot test. Delete the selected track and another editable track becomes
  selected.

#### REQ-033 — Notes on every editable track are interactive

WHILE more than one track is editable, a left press on a note of any editable track shall
start the same gesture (drag, resize, Ctrl+click select or Ctrl+drag duplicate) that a press on
a note of the selected track starts today.

- **Acceptance:** Godot test. With A selected and B editable, pressing on a note of B and
  dragging moves that note within B's clip.

#### REQ-034 — Clicking another track's note selects that track

WHEN the user left-presses a note that belongs to an editable track other than the selected
one, the clip editor shall select that track in the track list before starting the gesture.
Notes placed afterwards shall go on that track. The switch shall count as a user pick, so the
editor may mirror it onto the arranger selection just as a click in the list does.

- **Acceptance:** Godot test. With A selected and B editable, pressing a note of B makes B the
  selected track. Releasing, then clicking empty grid space, places the new note in a clip on B.

#### REQ-035 — Hit priority between overlapping notes

IF notes of several editable tracks lie under the pointer, THEN the clip editor shall pick the
selected track's note first, and otherwise the note of the editable track that comes first in
list order.

- **Acceptance:** Godot test. A and B each have a note at the same pitch and tick, and A is
  selected: the press hits A's note. With B selected, it hits B's note.

#### REQ-036 — Notes are placed on the selected track

WHILE any number of tracks are editable, a left press on empty grid space shall place a note on
the selected track only.

- **Acceptance:** Godot test. With A selected and B editable, clicking empty space adds a note
  to A and leaves B unchanged.

#### REQ-037 — Erase works on any editable track

WHILE right-click erase is held, the clip editor shall erase notes of any editable track under
the pointer, and shall not change the selected track.

- **Acceptance:** Godot test. With A selected and B editable, a right-press on B's note removes
  it and A stays selected.

#### REQ-038 — Box select and keyboard stay on the selected track

Box select, Ctrl+A, copy, paste, delete and the arrow-key shortcuts shall keep acting on the
selected track only.

- **Acceptance:** Godot test. With A selected and B editable, a Ctrl+drag box over notes of A
  and B selects only A's notes.

#### REQ-039 — Hidden and non-editable notes ignore the mouse

The clip editor shall not hit-test notes of hidden tracks or of visible tracks that are not
editable.

- **Acceptance:** Godot test. With A selected and B visible but not editable, pressing B's note
  places a new note on A (the press lands on empty space for A) and does not select B.

## Non-functional

- **Performance:** listing every instrument track shall not create note views for hidden
  tracks. A project with 50 instrument tracks, 2 of them visible, enters track mode with no
  noticeable delay compared with today.
- **Compatibility:** no change to `.sonara` or `config.json`. Clip mode behaviour is otherwise
  unchanged.

## Out of scope

- Persisting the visibility, editability and solo state.
- Box select, Ctrl+A or copy across several tracks at once.
- Shift+drag, which toggles like a plain drag and does not solo.
- Folder, group and audio tracks in the list.
- Changing track selection in the arranger or mixer. The existing optional mirroring through
  `track_mode_track_selected` stays as it is.

## Open questions

- [x] Initial states: the selected clips' tracks start visible and editable, and the rest start hidden. (Answered.)
- [x] Persistence: the state lasts for the session only. (Answered.)
- [x] Coupling: a hidden track is never editable, and the selected track is forced editable. (Answered.)
- [x] Multi-track gestures: erase works on any editable track, and box select stays on the selected track. (Answered.)
- [ ] Assumed: only instrument tracks are listed, because audio tracks carry no MIDI notes. Please confirm.
- [ ] Assumed: a plain click on a toggle while a solo is active ends the solo and keeps the current states (REQ-027). Please confirm.
