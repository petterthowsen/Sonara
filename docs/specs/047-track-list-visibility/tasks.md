# Track List and Visibility Presets — Tasks

Implements [design.md](./design.md). Tracking issue: _none yet_.

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Godot only. Run tests with `Godot/tests/run_all.sh <words>`, or run one script with
`godot --headless --path Godot -s tests/<script>.gd -- --test`.

## Phase 1 — model, commands and batching

- [x?] **T-001** [REQ-023] `VisibilityPresets` model.
  - _Files_: `Godot/data/VisibilityPresets.gd`, `Godot/tests/test_visibility_presets.gd` (new)
  - _Output_: the class with `add`, `rename`, `remove`, `move`, `set_hidden_ids`, `set_active`,
    `get_preset`, `count`, `display_name`, `snapshot` / `restore`, `prune`, `to_json` /
    `from_json`. `changed` is emitted on every mutation. `remove` and `move` keep `active_index`
    pointing at the same preset, or set it to −1 when the active one is removed.
  - _Verify_: model tests pass: `display_name(0) == "1: Orchestra"`, and after `move(1, 0)`
    `active_index` follows the preset. `from_json({})` is empty with active −1. An out-of-range
    active becomes −1. `prune` drops unknown IDs.
  - _Depends on_: —

- [x?] **T-002** [REQ-023] Save and load the presets with the project.
  - _Files_: `Godot/data/Project.gd`, `Godot/tests/test_visibility_presets.gd`
  - _Output_: the `visibility_presets` field. `to_json()` writes only existing track IDs.
    `from_json()` reads the key and prunes it after the tracks are loaded.
  - _Verify_: a round-trip test (two presets, order and active preserved), a missing key loads
    empty, and a stale ID is dropped on load.
  - _Depends on_: T-001

- [x?] **T-003** [non-functional] `Project.batch_visibility`.
  - _Files_: `Godot/data/Project.gd`, `Godot/tests/test_visibility_presets.gd`
  - _Output_: a depth counter and a pending flag. `notify_item_visibility_changed()` defers while
    the depth is above zero, the outermost call notifies once, and a doc comment says `fn` must
    not `await`.
  - _Verify_: hiding 300 tracks inside one batch emits `item_visibility_changed` exactly once.
    Nested batches also notify once.
  - _Depends on_: —

- [x?] **T-004** [REQ-008, REQ-017, REQ-018, REQ-020] Undo commands.
  - _Files_: `Godot/history/commands/VisibilityStateCommand.gd`,
    `Godot/history/commands/VisibilityPresetsStateCommand.gd`, `Godot/tests/test_visibility_presets.gd`
  - _Output_: both commands. `VisibilityStateCommand` applies inside `batch_visibility` and skips
    freed targets.
  - _Verify_: `do` / `undo` restore the hidden flags of a channel target and a channel-less track
    target. A presets snapshot command restores the order and `active_index`.
  - _Depends on_: T-001, T-003

## Phase 2 — visibility service

- [x?] **T-005** [REQ-017, REQ-018] `TrackVisibility` capture and apply.
  - _Files_: `Godot/editor/track_list/TrackVisibility.gd` (new), `Godot/tests/test_visibility_presets.gd`
  - _Output_: `target_of`, `capture`, `hidden_changes`, `apply_hidden_set`, `show_all`,
    `apply_preset` and `reset_preset`. Applying is one `MacroCommand` (visibility + active
    index) via `HistoryUtil`.
  - _Verify_: a track created after saving is visible on apply. Two tracks on one channel are set
    once, with "any hidden" winning. `show_all` plus one undo restores B and D. Applying uses
    `HistoryUtil.test_recorder` and gives one command.
  - _Depends on_: T-002, T-004

- [x?] **T-006** [REQ-009, REQ-010] Show-only, branch and mixed state.
  - _Files_: `Godot/editor/track_list/TrackVisibility.gd`, `Godot/tests/test_visibility_presets.gd`
  - _Output_: `show_only`, `is_only_visible_branch`, `show_branch` and `is_mixed`.
  - _Verify_: on A, F{B, C}, D, `show_only(B)` hides A, C and D and keeps F and B visible, and a
    second call shows everything. With C hidden, `is_mixed(F)` is true, and `show_branch(F)` shows
    F, B and C in one command.
  - _Depends on_: T-005

- [x?] **T-007** [REQ-019, REQ-020, REQ-021, REQ-022, REQ-025] Preset management, the unsaved
  check and the label.
  - _Files_: `Godot/editor/track_list/TrackVisibility.gd`, `Godot/tests/test_visibility_presets.gd`
  - _Output_: `add_preset`, `rename_preset`, `delete_preset`, `move_preset`, `save_preset`,
    `is_dirty`, `selector_label` and `step_preset`. Each mutation is one undo step.
  - _Verify_: Add next to "Vis Group 1" and "Orchestra" gives "3: Vis Group 3". Move plus one undo
    restores the order. The label reads `"1: Orchestra *"` after hiding D and `"Custom"` with no
    active preset and something hidden. Save keeps D hidden on re-apply. `step_preset` wraps
    through "All". Deleting a track drops it from `to_json`, and undoing the delete restores it in
    the preset.
  - _Depends on_: T-005

## Phase 3 — panel UI

- [x?] **T-008** [REQ-002, REQ-003, REQ-004] `TrackListRow` and the panel skeleton, listing the
  tree.
  - _Files_: `Godot/editor/track_list/TrackListRow.gd` + `.tscn`,
    `Godot/editor/track_list/TrackListPanel.gd` + `.tscn`, `Godot/tests/test_track_list_panel.gd` (new)
  - _Output_: rows in visual order with indent, eye, fold arrow (only on parents), color strip and
    name. Collapse state is local to the panel. Dimming uses `ItemVisibility.dim_alpha`.
  - _Verify_: panel test: 5 rows in order, B and C indented, an arrow only on F. Collapsing F
    hides B and C and leaves `F.is_folder_expanded` unchanged. Hiding F dims F, B and C.
  - _Depends on_: T-006

- [x?] **T-009** [REQ-005, REQ-006] Live updates and the filter.
  - _Files_: `Godot/editor/track_list/TrackListPanel.gd`, `Godot/tests/test_track_list_panel.gd`
  - _Output_: a coalesced structural rebuild skipped when the signature is unchanged, refresh in
    place on visibility, name and color changes, and the filter `LineEdit`.
  - _Verify_: add, remove, rename, recolor, reparent and an undone hide are each reflected. A
    visibility change doesn't rebuild rows (the row instance IDs stay the same). Filter "c" shows
    F and C, and clearing it restores the earlier collapse state.
  - _Depends on_: T-008

- [x?] **T-010** [REQ-007, REQ-008, REQ-009, REQ-010] Eye click, drag painting, Shift-click and
  mixed click.
  - _Files_: `Godot/editor/track_list/TrackListRow.gd`, `Godot/editor/track_list/TrackListPanel.gd`,
    `Godot/tests/test_track_list_panel.gd`
  - _Output_: list-level painting in `_input` with segment hit-testing, applied live inside
    `batch_visibility` and recorded once on release. Shift+press calls `show_only`. A mixed press
    calls `show_branch`.
  - _Verify_: a synthesized press on A, a motion to D and a release give A–D hidden and one
    recorded command. Shift-click B, and mixed-click F, behave as in T-006.
  - _Depends on_: T-008

- [x?] **T-011** [REQ-011, REQ-012] Selection and reveal.
  - _Files_: `Godot/editor/Editor.gd` (`select_tracks`, `reveal_track`),
    `Godot/arranger/tracklist/TrackList.gd` (`reveal_track`), `Godot/mixer/Mixer.gd`
    (`reveal_channel`), `Godot/editor/track_list/TrackListPanel.gd`, `Godot/tests/test_track_list_panel.gd`
  - _Output_: plain, Ctrl and Shift selection over the panel's visible rows, a highlight from
    `Editor.tracks_selected`, and a plain single click that reveals the track (no scroll when it
    isn't listed in that view).
  - _Verify_: panel test with a stub selection target: click B, then Ctrl-click D, gives {B, D},
    and both rows are highlighted. An external `tracks_selected` updates the highlight. Live
    scrolling is checked in T-017.
  - _Depends on_: T-009

- [x?] **T-012** [REQ-013, REQ-014, REQ-015] Rename, context menu and keyboard.
  - _Files_: `Godot/editor/track_list/TrackListRow.gd`, `Godot/editor/track_list/TrackListPanel.gd`,
    `Godot/tests/test_track_list_panel.gd`
  - _Output_: a double-click inline `LineEdit` (Enter or focus loss applies, Escape cancels,
    applied via `HistoryUtil.execute_property("Rename Track", …)`). A `PopupMenu` with Rename,
    Color, Hide/Show, Enable/Disable, Expand All and Collapse All, where each track-changing entry
    is one undo step and color is recorded when the picker closes. Up/Down/Left/Right/Space.
  - _Verify_: rename to "Strings" applies, and Escape leaves the name unchanged. Disable on {B, C}
    plus one undo enables both. The key sequence moves, collapses, goes to the parent, expands and
    toggles as specified.
  - _Depends on_: T-011

- [x?] **T-013** [REQ-016, REQ-017, REQ-019–REQ-022] Preset header.
  - _Files_: `Godot/editor/track_list/TrackListPanel.gd` + `.tscn`, `Godot/tests/test_track_list_panel.gd`
  - _Output_: an `OptionButton` ("All", then `display_name`s, showing `selector_label` for the
    current state), a ⋯ `MenuButton` (Add, Rename, Delete, Move Up, Move Down), and Save and Reset
    buttons enabled only while `is_dirty`. It refreshes on `VisibilityPresets.changed` and
    `item_visibility_changed`.
  - _Verify_: the items read "All", "1: Orchestra", "2: Drums". Picking an item applies it.
    Save and Reset are disabled when clean and enabled after hiding a track.
  - _Depends on_: T-007, T-008

## Phase 4 — integration

- [x?] **T-014** [REQ-001] Dock the panel and add the View entry.
  - _Files_: `Godot/editor/Editor.tscn`, `Godot/editor/docks/DockHost.gd`, `Godot/tests/test_dock_layout.gd`
  - _Output_: a `TrackListPanel` under `LeftDock` before `Inspector`. The `track_list` ID and the
    "Track List" title. `_DEFAULT_LEFT` updated. `_show_panel` uses the panel's default side.
  - _Verify_: `Godot/tests/run_all.sh dock_layout` passes, including the new cases: a fresh layout
    puts `track_list` first in the left dock, and showing it with a saved layout that lacks it
    places it left.
  - _Depends on_: T-013

- [x?] **T-015** [REQ-024, REQ-025] Hotkeys.
  - _Files_: `Godot/input/HotkeyActions.gd`, `Godot/editor/Editor.gd`, `Godot/tests/test_visibility_presets.gd`
  - _Output_: 12 `ACTIONS` rows, dispatched in `Editor._unhandled_input` to `TrackVisibility`.
  - _Verify_: a Ctrl+2 `InputEventKey` matches `visibility_preset_2`, and it doesn't match
    `keyboard_c#3`. The Ctrl+5 action with two presets changes nothing. The Settings conflict
    check reports no clash for the new defaults (`Godot/tests/run_all.sh hotkey` passes).
  - _Depends on_: T-007

## Phase 5 — docs

- [x?] **T-016** [REQ-all] Docs and changelog.
  - _Files_: `docs/subsystems/godot-architecture.md`, `CHANGELOG.md`
  - _Output_: a "Track List and visibility presets" section (model, service, batching, panel,
    the lazy pruning rule), and an `[Unreleased]` entry.
  - _Verify_: both files are updated, and every symbol the section names exists.
  - _Depends on_: T-014, T-015

## Phase 6 — live verification

- [ ] **T-017** [REQ-all] Verify in the running app.
  - _Files_: —
  - _Output_: the results recorded in this task, and the tracking issue commented on.
  - _Verify_: with a project of about 60 tracks, including folders:
    1. View › Track List shows the panel in the left dock.
    2. Drag the eye down 10 rows. The arranger and mixer update together, and one Ctrl+Z restores
       them.
    3. Shift-click an eye, then Shift-click it again.
    4. Add two presets. Ctrl+1, Ctrl+2 and Ctrl+0 switch between them. Edit to see `*`, then try
       Save and Reset. Save the project, reload it, and check the presets.
    5. Clicking a row scrolls the arranger in arranger view and the mixer in mixer view.
    6. Rebind Ctrl+1 in Settings, and check that the new chord works.
    7. Applying a preset on a 300-track project doesn't cause a visible stall.
  - _Depends on_: T-016

## Coverage

| REQ | Tasks |
|---|---|
| REQ-001 | T-014 |
| REQ-002, REQ-003, REQ-004 | T-008 |
| REQ-005, REQ-006 | T-009 |
| REQ-007 | T-010 |
| REQ-008 | T-004, T-010 |
| REQ-009, REQ-010 | T-006, T-010 |
| REQ-011, REQ-012 | T-011 |
| REQ-013, REQ-014, REQ-015 | T-012 |
| REQ-016 | T-013 |
| REQ-017, REQ-018 | T-005, T-013 |
| REQ-019 – REQ-022 | T-007, T-013 |
| REQ-023 | T-001, T-002, T-007 |
| REQ-024 | T-015 |
| REQ-025 | T-007, T-015 |
| Non-functional (performance) | T-003, T-017 |
