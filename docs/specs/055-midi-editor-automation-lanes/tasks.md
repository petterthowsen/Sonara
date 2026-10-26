# MIDI Editor Automation Lanes — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

**UI rule for every task:** new UI is a `.tscn` scene, so it can be previewed in the editor. Scripts reach nodes only through `%UniqueName` (`unique_name_in_owner = true`), never through `$Long/Path` and never by building layouts in code. The `%` names to expose are listed in design.md under "UI construction". Drawing-only controls are script nodes placed in a scene. Data-driven `PopupMenu` items may be added in code.

Single test script: `godot --headless --path Godot -s tests/<script>.gd -- --test`. Groups: `Godot/tests/run_all.sh <words>`. Run Godot test agents one at a time (see the parallel-agent memory).

## Phase 1 — shared foundations (no new UI)

- [x] **T-001** [REQ-016, REQ-017] Add the range-based tilt and compress maths.
  - _Files_: `Godot/clip_editor/value_lanes/ValueLaneEdits.gd`, `Godot/tests/test_value_lane_edits.gd`
  - _Output_: `tilt_range(values, xs, delta, from_left, lo, hi)` and `compress_range(values, factor, lo, hi)`. `tilt` / `compress` delegate to them.
  - _Verify_: `test_value_lane_edits.gd` passes with the new cases (0/960/1920 at 0.5, tilt right +0.2 → 0.5/0.6/0.7; 0.2/0.8 ×0.5 → 0.35/0.65; clamping at 0 and 1) and the existing cases.
  - _Depends on_: —

- [x] **T-002** [REQ-013] Move the automation clipboard operations from `Timeline` into `AutomationPointSelectionManager`.
  - _Files_: `Godot/arranger/timeline/AutomationPointSelectionManager.gd`, `Godot/arranger/timeline/Timeline.gd`
  - _Output_: `is_active()`, `cut_selection()`, `paste_at(fallback_tick)`, `duplicate_selection()` and `delete_selection()` on the manager. Timeline's `_automation_*` and `delete_automation_selection` delegate to them, with no behaviour change.
  - _Verify_: `Godot/tests/run_all.sh automation_range_ops automation_history automation_point_selection` all pass unchanged.
  - _Depends on_: —

- [x] **T-003** [REQ-011] Add override hooks to `AutomationLaneRow` (refactor only).
  - _Files_: `Godot/arranger/timeline/AutomationLaneRow.gd`
  - _Output_: `_release_other_selection()`, `_redraw_background()` and a `hotkey_context` var (default `"automation_lane"`). `_on_lane_height_changed` stays overridable. The two `clip_selection_manager.clear_selection()` calls and `timeline.queue_redraw()` go through the hooks.
  - _Verify_: `Godot/tests/run_all.sh automation` all pass.
  - _Depends on_: —

- [x] **T-004** [REQ-008, REQ-009, REQ-010] Add `Track.clip_editor_lanes` (open-lane entries).
  - _Files_: `Godot/data/Track.gd`, `Godot/tests/test_track_clip_editor_lanes.gd` (new)
  - _Output_: the var, the `clip_editor_lanes_changed` signal, and the `set_clip_editor_lanes()` setter, which drops unknown ids and clamps heights to `ValueLane.MIN_HEIGHT..MAX_HEIGHT`. Also `remove_automation_lane` drops the entry, `to_json` writes `"clip_editor_lanes"`, and `from_json` reads it after the lanes load.
  - _Verify_: the new test passes: the JSON round-trip, an unknown id dropped, a missing key → `[]`, removal drops the entry, and an entry height of 120 leaves `lane.height` unchanged.
  - _Depends on_: —

## Phase 2 — selection handles (Arranger and shared row)

- [x] **T-005** [REQ-015, REQ-016, REQ-017, REQ-018, REQ-019] Add the tilt-left, tilt-right and compress handles to `AutomationLaneRow`.
  - _Files_: `Godot/arranger/timeline/AutomationLaneRow.gd`, `Godot/tests/test_automation_selection_handles.gd` (new)
  - _Output_:
    - Handle rects over 2+ selected points, drawn in `_draw_body`, with `CURSOR_VSIZE` on hover.
    - A press checks points and tension handles first.
    - Motion uses `FineDrag` and the `ValueLaneEdits.*_range` functions, written with `lane.update_point`, with a `+N%` tooltip readout.
    - Release records one `AutomationActions.move_points(…, "Tilt Points"/"Compress Points")`.
  - _Verify_: the new test passes: 1 selected → no rects, 2 → 3 rects at the selection edges; a tilt over 3 points then one undo restores them; a press on a selected point inside a handle rect starts a point drag. `Godot/tests/run_all.sh automation` still passes.
  - _Depends on_: T-001, T-003

## Phase 3 — lane views and the shared menu

- [x] **T-006** [REQ-005, REQ-007, REQ-022] Add the `AutomationLaneView` strategy and its two implementations.
  - _Files_: `Godot/arranger/tracklist/AutomationLaneView.gd` (new), `Godot/arranger/tracklist/ArrangerLaneView.gd` (new), `Godot/clip_editor/automation/ClipEditorLaneView.gd` (new)
  - _Output_: `is_shown`, `set_shown`, `shown_lanes`, `capture`, `restore`, `apply_shown` and `on_lane_created`. The Arranger view works on `lane.visible` and `automation_expanded`. The clip editor view works on `Track.clip_editor_lanes`, with default height 96, and keeps existing heights on `apply_shown`.
  - _Verify_: unit cases added to `Godot/tests/test_track_clip_editor_lanes.gd` for both views: `apply_shown([CC1, CC11])` on a track showing `[Volume, CC1]` leaves exactly `[CC1, CC11]` shown, and `restore(capture())` round-trips.
  - _Depends on_: T-004

- [x] **T-007** [REQ-005, REQ-006] Make `AutomationLaneMenu` take a view, and share lane creation.
  - _Files_: `Godot/arranger/tracklist/AutomationLaneMenu.gd`, `Godot/arranger/tracklist/TrackList.gd`, `Godot/history/AutomationLanePresetActions.gd` (new; `create_lane_for` only for now)
  - _Output_: `open_for(track, pos, view := ArrangerLaneView.new())`. TrackList passes an `ArrangerLaneView`, and its lane creation body moves to `AutomationLanePresetActions.create_lane_for(track, target, view)`.
  - _Verify_: `Godot/tests/run_all.sh automation_lane_menu` passes unchanged. A new case checks that `create_lane_for` with a `ClipEditorLaneView` opens the created lane and that one undo removes it.
  - _Depends on_: T-006

## Phase 4 — MIDI editor automation pane

- [x] **T-008** [REQ-004, REQ-011] Add `ClipAutomationLaneRow`.
  - _Files_: `Godot/clip_editor/automation/ClipAutomationLaneRow.gd` (new)
  - _Output_: a subclass mapping x through `MidiEditor.grid_helper` and the `h_scroll` offset, snapping with that grid. It draws its own fill, grid and playhead mirror. It leaves the note selection alone, uses its own height, takes `FOCUS_CLICK` and grabs focus on press, and sets `hotkey_context = "clip_automation_lane"`.
  - _Verify_: covered by T-012's REQ-004 and REQ-011 cases. The script parses: `godot --headless --path Godot --check-only -s clip_editor/automation/ClipAutomationLaneRow.gd`.
  - _Depends on_: T-003

- [x?] **T-009** [REQ-007, REQ-010, REQ-012] Build the `AutomationPaneLane` scene.
  - _Files_: `Godot/clip_editor/automation/AutomationPaneLane.tscn` (new), `AutomationPaneLane.gd` (new)
  - _Output_: a scene laid out like `ValueLane.tscn`, exposing `%ResizeGrip`, `%Header`, `%NameLabel`, `%MaxLabel`, `%MinLabel`, `%BypassButton`, `%CloseButton` and `%Row` (a `ClipAutomationLaneRow` node). The bypass button uses `HistoryUtil.execute_property`. It emits `close_requested(lane)` and `height_changed(lane, h)`, and clamps the grip height.
  - _Verify_: the scene opens in the Godot editor and previews with no errors, and the script uses no `$` paths (`grep -n '\$' AutomationPaneLane.gd` is empty). Behaviour is covered by T-012.
  - _Depends on_: T-008

- [x] **T-010** [REQ-003, REQ-005, REQ-006, REQ-008, REQ-014] Build the `AutomationPane` scene, bound to the focus track.
  - _Files_: `Godot/clip_editor/automation/AutomationPane.tscn` (new), `AutomationPane.gd` (new)
  - _Output_:
    - A scene with `%AddLaneButton` and `%Lanes`.
    - `bind(editor, split, value_pane)`.
    - Lanes rebuilt from `focus_track.clip_editor_lanes` on focus, list and lane-removed changes.
    - Its own `AutomationPointSelectionManager`, cleared on focus change.
    - The add button opens `AutomationLaneMenu` with a `ClipEditorLaneView`.
    - `+ Add new` opens `AutomationParameterPicker` → `create_lane_for`.
    - Header widths aligned to `note_area`.
    - Visibility persisted to `clip_editor/automation_pane`.
  - _Verify_: covered by T-012. No `$` paths in the script.
  - _Depends on_: T-007, T-009

- [x] **T-011** [REQ-001, REQ-002, REQ-013] Integrate the pane into the clip editor and route shortcuts.
  - _Files_: `Godot/clip_editor/ClipEditor.tscn`, `Godot/clip_editor/ClipEditor.gd`, `Godot/clip_editor/value_lanes/NoteValuePane.gd`, `Godot/clip_editor/value_lanes/ValueLaneStemArea.gd`, `Godot/input/HotkeyActions.gd`
  - _Output_:
    - `EditorSplit/%LanePanes` (VBox) holds `NoteValuePane` and `%AutomationPane`.
    - The toolbar gets `%AutomationLanesToggle` ("Automation").
    - Pane and toggle are visible only in track mode.
    - `NoteValuePane.bind(editor, split, below)` accounts for the pane below it.
    - Pane `_gui_input` routes `edit_*` to the selection manager while a row has focus.
    - `ValueLaneStemArea._begin` hands focus to the active note editor.
    - A new `"clip_automation_lane"` hotkey context with parent `clip_editor`, a label and hint rows.
  - _Verify_: `Godot/tests/run_all.sh value_lane clip_editor clip_strip` all pass.
  - _Depends on_: T-002, T-010

- [x] **T-012** [REQ-001–REQ-014] Write the shallow pane tests.
  - _Files_: `Godot/tests/test_clip_editor_automation_pane.gd` (new)
  - _Output_: the cases from design.md's test plan for this file.
  - _Verify_: `godot --headless --path Godot -s tests/test_clip_editor_automation_pane.gd -- --test` passes.
  - _Depends on_: T-011

## Phase 5 — lane presets

- [x] **T-013** [REQ-025, REQ-028] Add the `AutomationLanePresets` store and target resolution.
  - _Files_: `Godot/data/AutomationLanePresets.gd` (new), `Godot/tests/test_automation_lane_presets.gd` (new)
  - _Output_:
    - `names()`, `get_preset()`, `save()`, `delete()` and `entries_for(track, lanes)`.
    - Static `resolve_entry(entry, channel)`, which checks the saved position first, then takes the first device of the same `device_id` depth-first, and rejects targets that are unresolvable or not automation-safe.
    - The file is `<PresetLibrary.root_dir()>/automation_lane_presets.json`, version 1.
  - _Verify_: the test passes with `PresetLibrary.dir_override` set to a scratch directory: a store round-trips through a new instance; a Filter is resolved both at its saved position and after moving; a missing Filter gives null; CC, volume and pan always resolve.
  - _Depends on_: —

- [x] **T-014** [REQ-021, REQ-022, REQ-023, REQ-024, REQ-026, REQ-027] Implement preset save, load and delete with undo.
  - _Files_: `Godot/history/AutomationLanePresetActions.gd`, `Godot/history/commands/AutomationShownStateCommand.gd` (new), `Godot/tests/test_automation_lane_presets.gd`
  - _Output_:
    - `save(view, track, name)`, which refuses an empty name and takes an overwrite flag.
    - `load(view, track, preset) -> Array` (the skipped entries): one macro with the create commands followed by the shown-state command. A load with nothing resolvable changes nothing.
    - `delete(name)`.
  - _Verify_: the test passes for both views: save order; an empty name and `overwrite=false` keep the store unchanged; a load replaces the shown set and creates seeded CC lanes; one undo restores the shown set and removes the created lanes; skipped entries are returned; a load with nothing resolvable is a no-op; delete leaves the lanes alone.
  - _Depends on_: T-006, T-007, T-013

- [x?] **T-015** [REQ-021] Build the save dialog scene.
  - _Files_: `Godot/arranger/tracklist/AutomationLanePresetSaveDialog.tscn` (new), `AutomationLanePresetSaveDialog.gd` (new)
  - _Output_: a `Window` scene with `%NameEdit`, `%SaveButton`, `%CancelButton`, `%StatusLabel` and `%OverwriteConfirm`, and `save_named(name, overwrite) -> bool`. An existing name asks through `%OverwriteConfirm`.
  - _Verify_: the scene previews in the editor, and the script has no `$` paths. A case in `test_automation_lane_presets.gd` checks that instancing the scene and calling `save_named("", true)` returns false.
  - _Depends on_: T-014

- [x] **T-016** [REQ-020, REQ-026, REQ-027] Add the presets section to both lane menus.
  - _Files_: `Godot/arranger/tracklist/AutomationLaneMenu.gd`
  - _Output_:
    - A `Presets` section: preset items, `Save shown lanes as preset…` (disabled with no shown lanes), and a `Delete preset` submenu with confirmation.
    - The save dialog is instanced from its scene.
    - Skipped entries are reported through `Sonara.editor.show_error`.
    - The store is re-read on every open.
  - _Verify_: a case in `test_automation_lane_menu.gd` checks that after saving `Strings` through the store, `open_for` on an Arranger track lists `Strings`, as does the menu with a `ClipEditorLaneView`, and that the save entry is disabled with no shown lanes.
  - _Depends on_: T-014, T-015

## Phase 6 — docs

- [x] **T-017** [REQ-all] Update the subsystem doc.
  - _Files_: `docs/subsystems/godot-architecture.md`
  - _Output_: the clip editor section describes the automation pane, the row hooks and `ClipAutomationLaneRow`, `AutomationLaneView`, focus-routed shortcuts, and lane presets with their file location.
  - _Verify_: every new class from design.md's file list is named in the doc.
  - _Depends on_: T-016

- [x] **T-018** [REQ-all] Update the changelog.
  - _Files_: `CHANGELOG.md`
  - _Output_: lines under `## [Unreleased]` for automation lanes in the MIDI editor (track mode), tilt and compress handles on automation points, and automation lane presets, with the issue number if one is created.
  - _Verify_: three lines present under `[Unreleased]`.
  - _Depends on_: T-016

## Phase 7 — live verification

- [ ] **T-019** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: —
  - _Output_: the issue checklist marked `[x]`, and `STATUS.md` notes what was and wasn't checked.
  - _Verify_: in track mode with an SFZ instrument on two tracks:
    1. Toggle the automation pane. It's absent in clip mode.
    2. Add a CC1 lane from the pane and draw a ramp. You hear the sweep, and the Arranger lane matches it.
    3. Tilt and compress the ramp in both the MIDI editor and the Arranger. Undo is one step each time.
    4. Switch the focus track. The lanes swap, and Delete acts on whatever was pressed last.
    5. Resize the split and the lanes with the value lanes shown, then hidden. Nothing jumps.
    6. Save `Strings` (CC1 + CC11). Load it on the second track from the Arranger: the lanes are created and shown, and Volume is hidden. Undo.
    7. Save the project, reopen it, and check that the open lanes and their heights come back.
  - _Depends on_: T-012, T-016, T-018
