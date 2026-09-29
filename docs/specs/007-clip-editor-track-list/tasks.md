# Clip Editor Track List — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Test command used throughout (called "the suite" below):
`godot --headless --path Godot -s tests/test_clip_editor_track_list.gd -- --test`

## Phase 1 — Foundation

- [x?] **T-001** [REQ-020, REQ-002] Fetch the icons.
  - _Files_: `Godot/assets/icons/fetch_lucide_icons.sh`, `Godot/assets/icons/{pencil,pencil-off,layers}.svg`
  - _Output_: three SVGs in the house style (white stroke, no class attribute), with `.import` files generated
  - _Verify_: `ls Godot/assets/icons/{pencil,pencil-off,layers}.svg.import` succeeds after `godot --headless --path Godot --import`
  - _Depends on_: —

- [x?] **T-002** [REQ-023, REQ-025, REQ-026, REQ-027, REQ-021, REQ-031] Write the `TrackToggleState` model.
  - _Files_: `Godot/clip_editor/tracklist/TrackToggleState.gd`, `Godot/tests/test_clip_editor_track_list.gd`
  - _Output_: the model with `set_tracks`, `init_from_selection`, `is_on`, `is_editable`, `set_on`, `toggle_solo`, `soloed_track` and `first_editable`, plus the tests `_test_toggle_state_solo` and `_test_toggle_state_editable`
  - _Verify_: the suite passes
  - _Depends on_: —

## Phase 2 — Track list

- [x?] **T-003** [REQ-012, REQ-020, REQ-023, REQ-025] Rebuild the list item: a styled `PanelContainer` with the two toggles.
  - _Files_: `Godot/clip_editor/tracklist/ClipEditorTrackListItem.tscn`, `Godot/clip_editor/tracklist/ClipEditorTrackListItem.gd`, the test file
  - _Output_: padding and a soft border, a white border on the selected item, `toggle_pressed(kind, shift)`, and `refresh_toggles(state)` with the solo colour and the dimmed edit toggle; plus the test `_test_item_style`
  - _Verify_: the suite passes
  - _Depends on_: T-001, T-002

- [x?] **T-004** [REQ-010, REQ-011] Make the list show every instrument track and follow project changes.
  - _Files_: `Godot/clip_editor/tracklist/ClipEditorTrackList.gd`, `Godot/clip_editor/tracklist/ClipEditorTrackList.tscn`, the test file
  - _Output_: `set_project`, `set_toggle_state`, `listed_tracks` and `tracks_changed`; the list keeps its selection across rebuilds, and the placeholder item is removed; plus the test `_test_list_all_instrument_tracks`
  - _Verify_: the suite passes
  - _Depends on_: T-003

- [x?] **T-005** [REQ-024, REQ-025, REQ-026, REQ-027] Add drag-to-paint and Shift+click solo in the list.
  - _Files_: `Godot/clip_editor/tracklist/ClipEditorTrackList.gd`, the test file
  - _Output_: `_on_item_toggle_pressed`, `_input` and `_item_at_global_y`; plus the test `_test_drag_paint` (a simulated press, motion and release)
  - _Verify_: the suite passes
  - _Depends on_: T-004

## Phase 3 — Note editor behaviour

- [x?] **T-006** [REQ-022, REQ-039] Add `MidiEditor.set_track_views`, `editable_tracks` and the three-level dimming.
  - _Files_: `Godot/clip_editor/MidiEditor.gd`, the test file
  - _Output_: editors are reconciled per visible track, and `_editor_track` is factored out; plus the test `_test_hidden_track_not_drawn`
  - _Verify_: the suite passes, and so do `godot --headless --path Godot -s tests/test_midi_editor_features.gd -- --test` and `tests/test_midi_editor_clip_paste.gd`
  - _Depends on_: T-002

- [x?] **T-007** [REQ-033, REQ-034, REQ-035, REQ-036, REQ-037, REQ-038, REQ-039] Add cross-track hit-testing.
  - _Files_: `Godot/clip_editor/MidiEditor.gd`, the test file
  - _Output_: `_note_hit` and `note_track_picked`; the left press switches track before the gesture, erase works through the editor that owns the note, and `get_active_note_editor()` returns null in track mode with no selected track (null guards added at every call site); plus the test `_test_cross_track_note_press`
  - _Verify_: the suite passes, and the two regression suites from T-006 pass
  - _Depends on_: T-006

## Phase 4 — ClipEditor integration

- [x?] **T-008** [REQ-021, REQ-030, REQ-031, REQ-032, REQ-034] Connect `ClipEditor` to the toggle state, the list and `MidiEditor`.
  - _Files_: `Godot/clip_editor/ClipEditor.gd`, the test file
  - _Output_:
    - `track_toggles`, `_project()`, `_listed_tracks()`, `_apply_track_toggles()` and `_ensure_valid_selection()`,
    - `_bind_track_mode` initialises the states from the selection or keeps them on re-entry,
    - selecting a track forces it visible and editable, and `note_track_picked` is handled,
    - the ruler regions come from the visible tracks,
    - plus the tests `_test_initial_states` and `_test_selection_follows_editability`
  - _Verify_: the suite passes
  - _Depends on_: T-005, T-007

- [x?] **T-009** [REQ-001, REQ-002, REQ-003] Add the header clip name and the icon mode toggle.
  - _Files_: `Godot/clip_editor/ClipEditor.tscn`, `Godot/clip_editor/ClipEditor.gd`, the test file
  - _Output_: `ClipNameLabel`, `_update_clip_name` (which follows `clip_modified`), and the `layers` icon toggle with a tooltip; plus the test `_test_header_clip_name`
  - _Verify_: the suite passes
  - _Depends on_: T-001, T-008

## Phase 5 — Docs and backlog

- [x?] **T-010** [REQ-all] Update the architecture doc and `TODO.md`.
  - _Files_: `docs/subsystems/godot-architecture.md`, `TODO.md`
  - _Output_: the ClipEditor, MidiEditor and track list paragraphs describe the toggles, solo, cross-track hits and the header; `TODO.md` has an entry for spec 007
  - _Verify_: the doc mentions `TrackToggleState`, `set_track_views` and `note_track_picked`, and `TODO.md` links `docs/specs/007-clip-editor-track-list`
  - _Depends on_: T-009

## Phase 6 — Verification

- [ ] **T-011** [REQ-all] Run the full regression suite.
  - _Files_: —
  - _Output_: no new failures compared with `master`
  - _Verify_: `Godot/tests/run_all.sh` passes; any failure also present on `master` is recorded as pre-existing
  - _Depends on_: T-010

- [ ] **T-012** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: —
  - _Output_: the `TODO.md` entry is marked `[x]`
  - _Verify_: the user checks the item look, the eye and pencil icons, drag-painting, the Shift+click solo colour and revert, clicking another track's note (the list highlight moves and new notes land on that track), erasing across tracks, and the clip name in clip mode
  - _Depends on_: T-011
