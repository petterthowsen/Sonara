# Note Maps and Drum View — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Run all Godot tests with `Godot/tests/run_all.sh`; a single one with
`godot --headless --path Godot -s tests/<script>.gd -- --test`.

## Phase 1 — LaneLayout foundation (no visible change)

- [x?] **T-001** [REQ-016, REQ-020] Add `LaneLayout`: chromatic and folded pitch ↔ row ↔ Y math.
  - _Files_: `Godot/clip_editor/LaneLayout.gd`
  - _Output_: `class_name LaneLayout extends RefCounted` with `changed`, `row_height`,
    `chromatic()`, `set_rows()`, `is_folded()`, `row_count()`, `pitch_at_row()`, `row_of_pitch()`,
    `pitch_to_y()`, `pitch_to_y_center()`, `y_to_pitch()`, `y_to_row()`, `total_height()`,
    `step_pitch()`
  - _Verify_: `tests/test_drum_rows.gd` (T-002) passes its chromatic cases
  - _Depends on_: —

- [x?] **T-002** [REQ-016, REQ-020, REQ-024] Test `LaneLayout` against today's formula, plus folded
    behaviour.
  - _Files_: `Godot/tests/test_drum_rows.gd`
  - _Output_: chromatic `pitch_to_y`/`y_to_pitch` equals `(127 - note) * height` for all 128
    pitches at several row heights; folded `row_of_pitch` returns -1 for hidden pitches;
    `step_pitch` walks rows, saturating at the ends
  - _Verify_: `godot --headless --path Godot -s tests/test_drum_rows.gd -- --test` exits 0
  - _Depends on_: T-001

- [x?] **T-003** [REQ-015] Make `MidiEditor` own the layout and drive it from `note_height`.
  - _Files_: `Godot/clip_editor/MidiEditor.gd`
  - _Output_: one `LaneLayout` created in `_ready`, handed to `VPiano`, `NoteLanes` and each
    `NoteEditor`; the `note_height` setter (`:112`), `_zoom_vertical`, `scroll_to_note` and
    `_update_hovered_key` (`:867`) go through it
  - _Verify_: live — open a MIDI clip, zoom vertically with the existing shortcut, scroll, hover
    keys. Nothing moves differently from before the change
  - _Depends on_: T-001

- [x?] **T-004** [REQ-015] Convert the drawing and hit-testing controls to the layout.
  - _Files_: `Godot/clip_editor/NoteLanes.gd`, `Godot/components/VPiano.gd`
  - _Output_: both take a `LaneLayout` (defaulting to `chromatic()` so `@tool` mode still works)
    and drop their own `note_to_y` math
  - _Verify_: live — lanes, keys and clicks land on the same pitches as before; the Godot editor
    still renders both scenes without errors
  - _Depends on_: T-003

- [x?] **T-005** [REQ-015, REQ-019] Convert note positioning and pitch drag math to the layout.
  - _Files_: `Godot/clip_editor/note_editor/NoteContainer.gd`,
    `Godot/clip_editor/note_editor/NoteEditor.gd`
  - _Output_: `note_to_y` (`:530`), `y_to_note` (`:524`), `_get_minimum_size` (`:218`),
    `_update_single_note_position` (`:239`) and the drag math at `NoteEditor.gd:465` and `:902`
    use the layout; hidden pitches hide their `VisualNote`
  - _Verify_: live — draw, drag, resize, box-select and transpose notes in the piano roll; all
    behave as before. `Godot/tests/run_all.sh` stays green
  - _Depends on_: T-004

## Phase 2 — Note map model, library and resolver

- [x?] **T-006** [REQ-001, REQ-009] Add the `NoteMap` data object.
  - _Files_: `Godot/data/NoteMap.gd`
  - _Output_: `map_name`, `category`, `author`, `entries`; `get_name`, `get_color`, `set_entry`,
    `erase_entry`, `is_empty`, `pitches`, `duplicate_map`, `to_json` / `from_json`
  - _Verify_: `tests/test_note_map.gd` (T-010) round-trips a map through JSON unchanged
  - _Depends on_: —

- [x?] **T-007** [REQ-009, REQ-010] Add `NoteMapLibrary` over `~/.config/sonara/note_maps/`.
  - _Files_: `Godot/data/NoteMapLibrary.gd`
  - _Output_: `list`, `load_map`, `save_map`, `exists`, `path_for`, and a `dir_override` for tests
    following `ai/chat/ConversationStore.gd`
  - _Verify_: headless test saves two maps to a temp dir, lists them with category and author, and
    loads one back identical
  - _Depends on_: T-006

- [x?] **T-008** [REQ-001, REQ-011, REQ-012, REQ-026, REQ-028] Put the assignment on `Channel`.
  - _Files_: `Godot/data/Channel.gd`
  - _Output_: `note_map_mode` (default `AUTO`), `note_map`, `drum_view` (-1 unset); signal
    `note_map_changed`; setters; `to_json` / `from_json` / `JSON_FIELDS` wiring. No
    `sync_to_engine()` change
  - _Verify_: headless test — defaults, round trip, and a channel JSON without the keys loading as
    Auto with `drum_view == -1`
  - _Depends on_: T-006

- [x?] **T-009** [REQ-002, REQ-003] Add `NoteMapResolver`.
  - _Files_: `Godot/data/NoteMapResolver.gd`
  - _Output_: `effective_map`, `auto_map` (first `DeviceDropUtil.DRUM_MACHINE_ID` on the root
    chain; entries from children with `slot_note >= 0`, names from `get_display_name()`, colors
    from `AuxReturnSync.get_return_channel(...).color`), `has_auto_source`, `for_track`
  - _Verify_: headless test — the two-pad example from REQ-002, an empty pad staying unmapped, and
    a Polysynth channel resolving to an empty map
  - _Depends on_: T-008

- [x?] **T-010** [REQ-001, REQ-002, REQ-003, REQ-009, REQ-010, REQ-011, REQ-012, REQ-026, REQ-027,
    REQ-028] Write the model, library and persistence tests.
  - _Files_: `Godot/tests/test_note_map.gd`
  - _Output_: one test per acceptance check listed in those requirements, including the embedded
    copy surviving a deleted library entry and channel edits leaving the library untouched
  - _Verify_: `godot --headless --path Godot -s tests/test_note_map.gd -- --test` exits 0
  - _Depends on_: T-009

- [x?] **T-011** [REQ-004] Add `NoteMapWatcher`.
  - _Files_: `Godot/data/NoteMapWatcher.gd`
  - _Output_: binds `note_map_changed`, the channel's device signals, the Drum Machine's
    `child_added` / `child_removed` / `child_moved`, each pad child's `name_changed` and each
    return channel's `color_changed`; emits one coalesced `changed` per frame; rebinds and
    disconnects cleanly like `devices/PadLaneWatcher.gd`
  - _Verify_: headless test — renaming a pad device emits exactly one `changed` per frame, and a
    removed pad's signals are disconnected (no error on emit after removal)
  - _Depends on_: T-009

## Phase 3 — Piano roll labels and colors

- [x?] **T-012** [REQ-013, REQ-014] Show map names and colors in the piano roll.
  - _Files_: `Godot/components/VPiano.gd`, `Godot/clip_editor/NoteLanes.gd`,
    `Godot/clip_editor/MidiEditor.gd`
  - _Output_: `MidiEditor` resolves the effective map for the bound track, caches it, refreshes on
    `NoteMapWatcher.changed`, and passes it to both controls; mapped keys draw their name, mapped
    lanes are tinted
  - _Verify_: live — a Drum Machine channel shows pad names on its keys and tinted lanes; renaming
    a pad updates the label immediately (REQ-004)
  - _Depends on_: T-011

## Phase 4 — Drum View

- [x?] **T-013** [REQ-016, REQ-017, REQ-024] Add `DrumRows`.
  - _Files_: `Godot/clip_editor/DrumRows.gd`, `Godot/tests/test_drum_rows.gd`
  - _Output_: `rows_for(map, clips)` = mapped ∪ used, ascending; tests for the REQ-016 example and
    the two-track union
  - _Verify_: `godot --headless --path Godot -s tests/test_drum_rows.gd -- --test` exits 0
  - _Depends on_: T-002, T-009

- [x?] **T-014** [REQ-017, REQ-018] Add `DrumRowHeader`.
  - _Files_: `Godot/clip_editor/DrumRowHeader.gd`, `Godot/clip_editor/ClipEditor.tscn`
  - _Output_: a `Control` in `MidiEditor/HBox` beside `VPiano`, drawing one labeled, colored row per
    layout row, unmapped rows styled apart with `Midi.midi_to_note_name`; emits
    `key_pressed` / `key_released` like `VPiano`
  - _Verify_: live — with Drum View forced on in code, rows read "Kick", "Snare" etc. and clicking a
    label plays the pad
  - _Depends on_: T-013

- [x?] **T-015** [REQ-022] Add the hit display mode to notes.
  - _Files_: `Godot/clip_editor/VisualNote.gd`,
    `Godot/clip_editor/note_editor/NoteContainer.gd`
  - _Output_: `prepare_drum_layout()` — marker sized from row height, velocity shading kept, label
    hidden, `_is_over_resize_handle` false; `_update_single_note_position` uses it while folded
  - _Verify_: live — hits render one per note; switching back to the piano roll shows the original
    lengths unchanged
  - _Depends on_: T-014

- [x?] **T-016** [REQ-015, REQ-019, REQ-020, REQ-021, REQ-023] Wire Drum View into `MidiEditor`.
  - _Files_: `Godot/clip_editor/MidiEditor.gd`,
    `Godot/clip_editor/note_editor/NoteEditor.gd`
  - _Output_: a `drum_view` property that swaps header controls, sets the folded layout and keeps
    selection and a visible pitch; row rebuilds deferred while `interaction_mode != NONE`; new
    notes one grid step long; resize disabled; the empty-view hint
  - _Verify_: live — REQ-015, REQ-019, REQ-020, REQ-021 and REQ-023 acceptance steps
  - _Depends on_: T-015

## Phase 5 — Toolbar and dialogs

- [x?] **T-017** [REQ-015, REQ-028] Add the mode switch and map dropdown to the bottom toolbar.
  - _Files_: `Godot/clip_editor/ClipEditor.tscn`, `Godot/clip_editor/ClipEditor.gd`
  - _Output_: before `Quantize`: `ModeSwitch`, `NoteMapButton` (its `PopupMenu` positioned above
    the button), `NoteMapLoad`, `NoteMapEdit`, `NoteMapSave`. The switch reads and writes
    `Channel.drum_view`, defaulting to Drum View when the map has a Drum Machine source
  - _Verify_: live — the dropdown opens upwards and lists None, Auto and library maps; toggling the
    mode, saving and reloading the project keeps the choice (REQ-028)
  - _Depends on_: T-016

- [x?] **T-018** [REQ-005, REQ-006, REQ-007, REQ-008] Add the note map editor dialog.
  - _Files_: `Godot/clip_editor/note_map/NoteMapEditorDialog.gd` / `.tscn`
  - _Output_: `Window` with a scrolled `VPiano`, `SmartLineEdit` + reset `X` + `ColorPickerButton`;
    key click selects and auditions; edits go through `HistoryUtil.execute_property` on
    `Channel.set_note_map`; every editing control disabled for Auto maps
  - _Verify_: live — REQ-005 to REQ-008 acceptance steps, plus undo restoring a renamed entry
  - _Depends on_: T-017

- [x?] **T-019** [REQ-009, REQ-010, REQ-027] Add the load and save dialogs.
  - _Files_: `Godot/clip_editor/note_map/NoteMapBrowserDialog.gd` / `.tscn`,
    `Godot/clip_editor/note_map/NoteMapSaveDialog.gd` / `.tscn`
  - _Output_: browser grouped by category showing the author, assigning a copy on confirm; save
    dialog with name, category and author, confirming before overwrite; "Save as…" available on
    Auto maps
  - _Verify_: live — save a Drum Machine's Auto map as "My Kit", assign it to a Polysynth channel
    from the browser, restart Godot and load it again
  - _Depends on_: T-018

## Phase 6 — Assistant

- [x?] **T-020** [REQ-025] Point the assistant's drum names at the effective map.
  - _Files_: `Godot/ai/tools/AiTool.gd`, `Godot/ai/tests/test_clip_text.gd`
  - _Output_: `drum_names_for_track` (`:508`) delegates to `NoteMapResolver.for_track`, keeping the
    existing de-duplication and `_generic_drum_label` fallback; a test for a named map with no Drum
    Machine
  - _Verify_: `godot --headless --path Godot -s ai/tests/test_clip_text.gd -- --test` and
    `ai/tests/test_device_tools.gd` exit 0
  - _Depends on_: T-009

## Phase 7 — Docs

- [x?] **T-021** [REQ-all] Document the feature for future work.
  - _Files_: `docs/subsystems/godot-architecture.md`, `TODO.md`
  - _Output_: a short `LaneLayout` / note map section in the rule file; `TODO.md` entry
    "Note maps and drum view (docs/specs/002-note-maps)" under the Godot UI section
  - _Verify_: the rule file describes `LaneLayout`, `NoteMapResolver` and the channel keys; the
    `TODO.md` entry exists
  - _Depends on_: T-019, T-020

## Phase 8 — Live verification

- [x] **T-022** [REQ-all] Full live pass with the engine and Godot running.
  - _Files_: —
  - _Output_: every live acceptance check in requirements.md walked through; `TODO.md` entry marked
    `[x]`; anything unresolved written into `STATUS.md`
  - _Verify_: start the engine (`Engine/run_release.sh`), run `godot --path Godot`, then: build a
    Drum Machine kit and confirm the clip editor opens in Drum View with named, colored rows; write
    a beat with single clicks; drag a hit between rows; add a note on an unmapped pitch and confirm
    it gets a marked row; switch to the piano roll and confirm labels, tints and unchanged note
    lengths; rename and recolor a pad and watch the editor follow; save the map to the library,
    restart, and load it onto another channel; save and reload the project
  - _Depends on_: T-021
