# Track List and Visibility Presets — Requirements

## Problem

Large projects (orchestral templates, multi-mic drum setups) have far more tracks than fit on
screen. Sonara can already hide tracks and channels (issue 70). But each track has to be hidden
one at a time from its context menu, a hidden track disappears from the arranger and then can't
easily be found again, and there is no way to save a set of visible tracks and switch back to it
later. Cubase and Studio One solve this with a Track List: a tree of every track with a visibility
toggle per row, plus saved visibility configurations. This spec is phase 1: the panel, the toggles
and the presets. The visibility actions ("tracks with events at the playhead / in the selected
range") are phase 2 and get their own spec.

## Scope

| | |
|---|---|
| Subsystem | Godot only |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no. Hiding stays visual-only. Enable/Disable from the context menu uses the existing path |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes: `.sonara` gains a list of visibility presets. It's an additive key, so older projects load with no presets and need no migration. `config.json` gains the default hotkey bindings through the existing Hotkeys registry |

## Terms

- **Track List**: the new dock panel described here.
- **Visibility preset**: a named, ordered snapshot of which tracks are hidden. Saved in the project.
- **Active preset**: the preset that was last applied or saved, if any.
- **Effectively hidden**: hidden itself, or under a hidden Folder/Group track (the existing
  `ItemVisibility` cascade).

Hiding a track hides its linked channel. So it also hides that channel's mixer strip and every
other track on the same channel. This is the existing issue 70 behaviour, and this spec keeps it
(see Out of scope).

## Requirements

### Panel

### REQ-001 — Dockable Track List panel

The editor shall provide a Track List dock panel that can be moved, tabbed and shown or hidden
like the other dock panels. It shall have a View menu entry that toggles it, and it shall start in
the left dock in a fresh layout.

- **Acceptance:** headless test: a fresh dock layout puts the Track List in the left dock, and the
  View menu entry toggles its visibility. Live: drag it to the right dock, restart, and it stays
  there.

### REQ-002 — Tree of all tracks

The Track List shall list every track in the project, hidden and disabled ones included, in
arranger order. Child tracks shall be nested under their Folder/Group track. Each row shall show,
left to right: a visibility toggle, an expand/collapse arrow (shown only on tracks that have
children), a strip in the track's color, and the track name. The list shall scroll vertically
when it is taller than the panel.

- **Acceptance:** headless test: a project with tracks A, Folder F { B, C }, D lists 5 rows in that
  order, with B and C indented one level under F and an arrow only on F.

### REQ-003 — Independent expand/collapse

WHEN the user clicks a row's expand/collapse arrow, the Track List shall show or hide that row's
descendants in the Track List only. The arranger's folder expansion shall not change, and
collapsing a folder in the arranger shall not collapse it in the Track List.

- **Acceptance:** headless test: collapsing F in the Track List leaves `F.is_folder_expanded`
  unchanged and hides B and C rows in the list only.

### REQ-004 — Dimmed hidden and disabled rows

WHILE a track is effectively hidden or disabled, the Track List shall still list its row and draw
it dimmed, at the same opacities the arranger and mixer use for listed hidden/disabled items.

- **Acceptance:** headless test: hide F → rows F, B and C are dimmed, and the toggles of B and C
  still show their own (visible) state.

### REQ-005 — Live updates

WHEN a track is added, removed, renamed, recolored, reordered, re-parented, hidden, shown, enabled
or disabled anywhere in the editor (including undo/redo), the Track List shall reflect the change
without the user reopening it.

- **Acceptance:** headless test covering add, remove, rename, recolor, reparent and an undone hide.

### REQ-006 — Name filter

The Track List shall have a filter field. WHILE the filter is non-empty, the list shall show only
the tracks whose name contains the text (case-insensitive) and their ancestors, with those
ancestors expanded. Clearing the filter shall restore the previous expand/collapse state.

- **Acceptance:** headless test: filter "c" on the example project shows F and C only, and clearing
  it shows all five rows again.

### Visibility toggles

### REQ-007 — Toggle a track's visibility

WHEN the user clicks a row's visibility toggle, the Track List shall flip that track's hidden
state, and the arranger and mixer shall update as they do for any other hide/show.

- **Acceptance:** headless test: clicking B's toggle sets `B.hidden == true`, and the arranger no
  longer lists B while `show_hidden` is off.

### REQ-008 — Drag across toggles

WHEN the user presses a visibility toggle and drags over other rows' toggles, the Track List shall
give every toggle it passes the same state the first press produced. This shall behave like the
existing drag-toggle buttons (mute, solo, arm), including fast drags that skip pixels. The whole
drag shall be one undo step.

- **Acceptance:** headless test: press A's toggle (hiding A) and drag over B, C and D → all four
  are hidden. One undo shows all four again.

### REQ-009 — Shift-click shows only this track

WHEN the user Shift-clicks a row's visibility toggle, the Track List shall make that track visible
along with its ancestors and descendants, and hide every other track, in one undo step. This
matches Shift-click on solo. IF that track is already the only visible branch, THEN Shift-click
shall show all tracks.

- **Acceptance:** headless test: Shift-click B's toggle → A, C and D are hidden, and F and B are
  visible. Shift-click B's toggle again → all visible.

### REQ-010 — Mixed state on parents

WHILE a Folder/Group track is visible but at least one of its descendants is hidden, the Track List
shall show its toggle in a mixed state. WHEN the user clicks a mixed toggle, the Track List shall
show that track and all its descendants in one undo step. Clicking a fully visible parent shall
hide only the parent itself, and its children shall follow through the existing cascade.

- **Acceptance:** headless test: hide C → F's toggle is mixed. Click F's toggle → B, C and F are all
  visible.

### Selection and navigation

### REQ-011 — Select tracks in the list

WHEN the user clicks a row (outside the toggle and the arrow), the Track List shall select that
track. Ctrl-click shall add it to or remove it from the selection, and Shift-click shall select
the range of visible rows. The selection shall be the arranger's track selection, so selecting in
either place shows in both.

- **Acceptance:** headless test: click B, then Ctrl-click D → the arranger's selected tracks are
  exactly {B, D}, and both rows are highlighted in the Track List.

### REQ-012 — Reveal on single click

WHEN a plain click selects exactly one track, the editor shall scroll that track into view: in the
arranger while the arranger view is active, or its channel strip in the mixer while the mixer view
is active. IF the track isn't listed in that view (hidden or disabled with the matching "show"
flag off), THEN the selection shall still change and nothing shall scroll.

- **Acceptance:** live: with 60 tracks, click the last row → the arranger scrolls to it. Switch to
  the mixer and click a row → the mixer scrolls to that strip.

### REQ-013 — Rename in place

WHEN the user double-clicks a row's name, the Track List shall edit the name in place. Enter or
losing focus applies the new name, and Escape cancels.

- **Acceptance:** headless test: double-click, type "Strings", press Enter → the track is named
  "Strings" and the arranger header shows it.

### REQ-014 — Context menu

WHEN the user right-clicks a row, the Track List shall open a context menu that acts on the
selected tracks, or on the clicked track if it isn't selected (in which case it becomes the
selection). The menu shall offer: Rename (single track only), Color, Hide/Show, Enable/Disable,
Expand All and Collapse All. Every entry that changes a track shall be one undo step.

- **Acceptance:** headless test: select B and C, choose Disable → both are disabled, and one undo
  enables both.

### REQ-015 — Keyboard navigation

WHILE the Track List has focus, Up/Down shall move the selection one visible row. Left shall
collapse the current row, or move to its parent if it is already collapsed. Right shall expand
it. Space shall toggle the selected tracks' visibility.

- **Acceptance:** headless test driving the four keys on the example project.

### Visibility presets

### REQ-016 — Preset selector

The Track List shall show a preset selector at its top. It lists "All" first, then every
visibility preset in order as `<position>: <name>`.

- **Acceptance:** headless test: presets "Orchestra" and "Drums" → the selector items are "All",
  "1: Orchestra", "2: Drums".

### REQ-017 — Show all

WHEN the user picks "All", the Track List shall make every track visible in one undo step and
clear the active preset. "All" shall never show unsaved changes.

- **Acceptance:** headless test: with B and D hidden, pick "All" → no track is hidden, and one undo
  hides B and D again.

### REQ-018 — Apply a preset

WHEN the user picks a preset, the Track List shall hide exactly the tracks the preset stores as
hidden, show every other track (including tracks created after the preset was saved), make it the
active preset, and do all of this in one undo step.

- **Acceptance:** headless test: save a preset with C hidden, then add track E and show all. Apply
  the preset → only C is hidden, and E is visible.

### REQ-019 — Add a preset

WHEN the user adds a preset, the Track List shall append a new preset holding the current hidden
state, named "Vis Group N", where N is the position the new preset takes in the list (counting from
1), so the name matches its number in the selector. The new preset becomes the active one. The name
is fixed at creation and doesn't change if the preset is later moved.

- **Acceptance:** headless test: with presets "Vis Group 1" and "Orchestra", Add → "3: Vis Group 3".

### REQ-020 — Manage presets

The Track List shall let the user rename the active preset, delete it, and move it up or down. The
positions shown in the selector and used by the hotkeys shall follow the new order. Each of these
changes shall be one undo step and shall mark the project as modified.

- **Acceptance:** headless test: move "2: Drums" up → the selector shows "1: Drums", "2: Orchestra",
  and one undo restores the order.

### REQ-021 — Unsaved changes indicator

WHILE an active preset exists and the current hidden state differs from what it stores, the preset
selector shall show the active preset followed by ` *`, and Save and Reset shall be enabled.
WHILE there is no active preset and some track is hidden, the selector shall show "Custom".

- **Acceptance:** headless test: apply "Orchestra", then hide D → the selector reads "1: Orchestra *".
  Show D again → the asterisk disappears.

### REQ-022 — Save and reset

WHEN the user presses Save, the Track List shall store the current hidden state in the active
preset, as one undo step. WHEN the selector reads Custom (no active preset), Save shall instead add
a new preset holding the current hidden state and make it active. WHEN the user presses Reset, the Track List shall re-apply the active
preset as REQ-018 describes.

- **Acceptance:** headless test: apply, hide D, Save → re-applying keeps D hidden. Apply, hide D,
  Reset → D is visible.

### REQ-023 — Persist presets in the project

The project shall save the presets in order: names, stored hidden tracks, and which one is active.
Loading the project shall restore them. Loading shall drop any stored track that no longer exists,
and deleting a track shall remove it from every preset. A project saved before this feature shall
load with no presets.

- **Acceptance:** headless round-trip test: save with two presets, reload, and the presets, the
  order and the active preset match. A project file without the key loads with an empty list.

### Hotkeys

### REQ-024 — Preset hotkeys

The Hotkeys registry shall have rebindable actions "Show All Tracks" (default Ctrl+0) and "Apply
Visibility Preset 1"–"9" (defaults Ctrl+1–Ctrl+9). Each preset action does what picking that
preset in the selector does. IF no preset exists at that position, THEN the action shall do
nothing. The actions shall work whether or not the Track List is shown.

- **Acceptance:** headless test: with two presets, the Ctrl+2 action applies preset 2 and the
  Ctrl+5 action changes nothing. Live: the actions appear in the hotkey settings and can be
  rebound.

### REQ-025 — Next and previous preset

The Hotkeys registry shall have "Next Visibility Preset" and "Previous Visibility Preset" actions,
unbound by default. They step through "All" followed by the presets in order, wrapping around at
either end.

- **Acceptance:** headless test: with no active preset, Next applies preset 1. On the last preset,
  Next applies "All".

## Non-functional

- **Latency / performance:** opening the Track List, applying a preset or dragging across toggles
  on a 300-track project shall not cause a visible stall (target: under 50 ms per apply, measured in
  a headless test).
- **Compatibility:** projects without presets load unchanged. Projects with presets opened in an
  older build lose only the presets, because the unknown key is ignored.

## Out of scope

- Separate visibility for the arranger and the mixer (Cubase-style). Hidden stays one per-channel
  flag shared by both views, as decided in issue 70.
- Phase 2 visibility actions (tracks with events at the playhead or in the selected range, only
  selected tracks, hide empty tracks, invert) and their transport-bar dropdown. These get their own
  spec, and the command palette gets another one after that.
- Reordering or re-parenting tracks by dragging in the Track List.
- Saving the Track List's expand/collapse state in the project.
- Presets that also store disabled state, track heights or folder expansion.

## Open questions

None blocking. These decisions were made in conversation, so challenge them here if needed:

- [x] Expand/collapse in the Track List is separate from the arranger's folder state (REQ-003).
- [x] Selection is shared with the arranger's track selection (REQ-011).
- [x] Shift-click on a toggle shows only that branch, and a second Shift-click shows everything (REQ-009).
- [x] A preset stores the hidden tracks, so tracks created later are visible (REQ-018).
