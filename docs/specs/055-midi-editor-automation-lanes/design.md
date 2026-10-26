# MIDI Editor Automation Lanes — Design

Implements [requirements.md](./requirements.md).

## Context

**Arranger automation (reused):**

- `Godot/data/AutomationLane.gd`, `AutomationPoint.gd`, `AutomationTarget.gd` — the self-syncing lane model. `AutomationTarget._to_string()` / `parse()` give the wire spelling (`channel/cc/1`, `device/0/2/param/5`). `resolve(channel)` walks `device_path`, and `_devices_recursive()` walks a chain depth-first.
- `Godot/arranger/timeline/AutomationLaneRow.gd` — one lane's drawing and every point gesture. It reaches `Timeline` in only a few places:
  - `bind_to_lane` reads `timeline.automation_selection_manager`.
  - `tick_to_x` / `x_to_tick` / `_snap_tick` call `timeline.ticks_to_pixels` / `pixels_to_ticks` / `grid_helper.snap_ticks`.
  - `_visible_x_range` uses `grid_helper.scroll_position` and `get_viewport_width()`.
  - `_handle_mouse_button` and `_on_lane_pressed` clear `timeline.clip_selection_manager`.
  - `_on_lane_flag_changed` calls `timeline.queue_redraw()`, because `Timeline._draw_row_backgrounds` paints the row's fill and grid.
  - Row height follows `lane.height` (`_on_lane_height_changed`).
  - The hotkey context is the literal `"automation_lane"`.
- `Godot/arranger/timeline/AutomationPointSelectionManager.gd` — selection scoped to one lane, focus lane, anchor, range and segment clipboard. `Timeline.gd` holds the clipboard operations on top of it: `_automation_is_active`, `_automation_cut`, `_automation_paste`, `_automation_duplicate`, `_select_pasted_points` and `delete_automation_selection`. `Arranger._handle_input` routes `edit_*` to them.
- `Godot/arranger/tracklist/AutomationLaneMenu.gd` (a check item per lane toggling `lane.visible`, plus `+ Add new` → `add_lane_requested`) and `AutomationParameterPicker.gd` (`open_for(track, pos)` → `parameter_chosen`). `TrackList._on_automation_menu_requested`, `_on_add_lane_requested` and `_on_automation_parameter_chosen` wire them: `AutomationToolUtil.new_lane` + `AutomationActions.create_lane` + `add_point(lane, 0, target.current_normalized_value(channel))`.
- `Godot/history/AutomationActions.gd` — `create_lane_commands`, `move_points(lane, points, before, …)`, `capture_point_states`. `HistoryUtil.execute_many(label, cmds)` runs a `MacroCommand` in order and undoes it in reverse. Commands extend `Command` with `do()` / `undo()` (for example `AutomationLaneCreateCommand.gd`).
- `Godot/data/Track.gd` — `automation_lanes`, `add_automation_lane` / `remove_automation_lane` (emit `automation_lane_added` / `_removed`), `automation_expanded`, `to_json` / `from_json` with `JSON_FIELDS`.

**MIDI editor (host):**

- `Godot/clip_editor/MidiEditor.gd` — `track_mode`, `focus_track` (setter emits `focus_track_changed`), `grid_helper`, `h_scroll`, `note_area`, `playhead`, `get_active_note_editor()`. Note content x is `editor.position.x + note x`, and the editor's position already carries the scroll (`_build_value_stems`).
- `Godot/clip_editor/value_lanes/NoteValuePane.gd` — the template for the new pane. It has an add `MenuButton`, `lanes_box`, and header widths aligned to `note_area` (`_align_lanes`). Its top lane fills the pane, sized by the editor split (`_split = get_parent() as SplitContainer`, `_sync_split`, `_capture_top_height`). It is persisted under config key `clip_editor/value_lanes`.
- `Godot/clip_editor/value_lanes/ValueLane.gd` / `.tscn` — layout template (resize grip, header column, area). `ValueLaneStemArea.gd` holds the selection handles to port: `Gesture.TILT_LEFT/TILT_RIGHT/COMPRESS`, `_handle_rects`, `_draw_handles`, `_begin_handle`, `_apply_tilt`, `_apply_compress`, `_delta_text`, `FineDrag`, `HANDLE_SIZE` / `HANDLE_GAP`. `ValueLaneEdits.tilt` / `compress` hold the maths, clamped through a `NoteValueDescriptor`.
- `Godot/clip_editor/ClipEditor.gd` / `.tscn` — `HSplit/MainPanel/VBox/EditorSplit` (a `VSplitContainer`: `MidiEditor`, `NoteValuePane`). The toolbar's `LanesGroup/ValueLanesToggle` is wired in `ClipEditor` (`value_pane.bind(midi_editor)`, `set_lanes_visible`).
- `Godot/clip_editor/note_editor/NoteEditor.gd` — handles `edit_copy/cut/paste/duplicate/delete` in its key input while it has focus. `ClipStrip._on_key` does the same for clips. In the clip editor, the shortcuts go to whichever control holds keyboard focus.
- `Godot/input/HotkeyActions.gd` — context parents (`"automation_lane": "arranger"`, `"value_lanes": "clip_editor"`), context labels and help-bar hint rows.

**Presets:**

- `Godot/data/PresetLibrary.gd` — `root_dir()` (the `presets/path` setting, overridden by `dir_override` in tests), `slug_for()`. `browser/PresetAssetProvider.gd` only picks up `.sonpreset` files, so other files in that root are ignored.
- `Godot/clip_editor/note_map/NoteMapSaveDialog.gd` — the template for a name dialog that asks before overwriting. `Editor.show_error(title, body)` shows the shared `PopupMessage`.
- `Godot/data/Device.gd` — `device_id` (`sonara.builtin.*`, `clap:…`), which `DeviceInstance.device` exposes.

## Approach

**One row class, two hosts.** `AutomationLaneRow` stays the single implementation of point editing. Its few `Timeline` touches become overridable hooks:

- `tick_to_x`, `x_to_tick`, `_snap_tick` and `_visible_x_range` already are methods.
- `_release_other_selection()` replaces the two `clip_selection_manager.clear_selection()` calls.
- `_redraw_background()` replaces `timeline.queue_redraw()`.
- `_on_lane_height_changed` becomes overridable.
- A `hotkey_context` variable replaces the literal.

A new `ClipAutomationLaneRow extends AutomationLaneRow` overrides them for the MIDI editor:

- It maps x through `MidiEditor.grid_helper` and the `h_scroll` offset, the same way the value lanes do.
- It snaps with that grid helper.
- It draws its own fill, grid lines and playhead mirror before calling `super._draw()`. The Timeline paints these for Arranger rows.
- It leaves the note selection alone, takes its height from the open-lane entry, and grabs keyboard focus on press.

The selection handles go into the base `AutomationLaneRow`, so the Arranger and the MIDI editor get them from one change.

*Rejected:* a separate `AutomationLaneHost` adapter object, implemented by `Timeline` and by the MIDI editor. It would remove the subclass, but every geometry call in a 1,200-line file would go through an extra object. Only six call sites differ, and the methods already exist as override points. *Also rejected:* drawing automation inside `ValueLaneStemArea` with a descriptor for automation. Stems are one value per note, while automation is a curve with tension, step segments and point identity, so almost nothing carries over.

**Shown lanes as a strategy.** Each view has its own idea of a "shown lane": `lane.visible` in the Arranger, and the track's open-lane list in the MIDI editor. An `AutomationLaneView` base class captures that difference with these methods:

- `is_shown(track, lane)`
- `set_shown(track, lane, on)`
- `shown_lanes(track)`, in order
- `capture(track)` / `restore(track, state)`, for undo
- `apply_shown(track, lanes)`
- `on_lane_created(track, lane)`

It has two implementations, `ArrangerLaneView` and `ClipEditorLaneView`. `AutomationLaneMenu.open_for(track, pos, view)` uses the view for its check items. The new preset section and the preset actions take a view too, so save, load, delete and undo are written once for both menus.

**Keyboard routing by focus.** The MIDI editor already routes shortcuts by keyboard focus: the note editor or the clip strip, whichever was clicked. A `ClipAutomationLaneRow` takes focus on press (`FOCUS_CLICK`), and the pane handles `edit_*` in `_gui_input` when that row has focus. A press in the note area hands focus back to the note editor through the existing click handling. A value-lane press doesn't take focus, so `ValueLaneStemArea._begin` grabs focus for `midi_editor.get_active_note_editor()`. That makes "last press wins" (REQ-013) hold without any new global state. Timeline's clipboard operations move into `AutomationPointSelectionManager` (`cut_selection()`, `paste_at(fallback_tick)`, `duplicate_selection()`, `delete_selection()`), so both hosts call the same code.

**Layout.** `EditorSplit`'s second child becomes a `VBoxContainer` called `LanePanes`, holding `NoteValuePane` and the new `AutomationPane`. `NoteValuePane.bind(editor, split, below)` takes the split explicitly instead of `get_parent()`. Its `_sync_split` adds the visible `below` pane's minimum height, so the value pane's top lane keeps filling and the automation lanes sit underneath at their own heights. If the value pane is hidden and the automation pane is shown, `AutomationPane` sets the split offset to its own minimum height. `LanePanes` is hidden when neither pane is visible.

**Presets.** `AutomationLanePresets` (in `data/`) is the store: one JSON file, `<presets root>/automation_lane_presets.json`. It holds `{"version": 1, "presets": [{"name", "entries": [{"target", "device_id"}]}]}` and is re-read on every menu open (REQ-028). `device_id` is set only for device and modulator parameter entries. Resolution (REQ-025) is a pure static function:
1. Parse `target`.
2. If it's a device target, check the device at `device_path`. If its `device.device_id` equals the entry's, keep it.
3. Otherwise, walk the chain depth-first with paths and take the first device with that id, rewriting `device_path`.
4. Reject the target if it's unresolvable or (for device parameters) not `is_automation_safe`.

`AutomationLanePresetActions` (in `history/`) handles save, load and delete:

- **Load** builds one macro for REQ-024. It contains `AutomationActions.create_lane_commands` for each missing target, seeded as in `TrackList._on_automation_parameter_chosen`, then one `AutomationShownStateCommand(view, track, before, after)`. The macro undoes in reverse, so the shown state is restored before the created lanes are detached. Skipped entries are returned, and the menu reports them through `Sonara.editor.show_error("Some lanes were skipped", …)`.
- **Save** is reached through a small name dialog modelled on `NoteMapSaveDialog`.
- **Delete** goes through a `ConfirmationDialog`.

**UI construction.** Every new piece of UI is a `.tscn` scene, so it can be previewed and adjusted in the Godot editor: the pane, the pane lane and the save dialog. Scripts reach their nodes only through scene-unique names (`%Name`, `unique_name_in_owner = true`), never through `$Long/Path`, so a layout can be rearranged without touching code. The scenes expose these names:

- `AutomationPane.tscn`: `%AddLaneButton`, `%Lanes`.
- `AutomationPaneLane.tscn`: `%ResizeGrip`, `%Header`, `%NameLabel`, `%MaxLabel`, `%MinLabel`, `%BypassButton`, `%CloseButton`, `%Row` (the `ClipAutomationLaneRow` script node placed in the scene).
- `AutomationLanePresetSaveDialog.tscn`: `%NameEdit`, `%SaveButton`, `%CancelButton`, `%StatusLabel`, `%OverwriteConfirm`.
- `ClipEditor.tscn` additions: `%LanePanes`, `%AutomationPane`, `%AutomationLanesToggle`.

Drawing-only controls (`ClipAutomationLaneRow`) are script nodes placed inside a scene. `AutomationLaneMenu` stays a code-populated `PopupMenu`, because its items are data. Its save dialog and delete confirmation are instanced from scenes (the confirmation is a `ConfirmationDialog` node in the menu host's scene, or inside the save dialog scene), not built with `.new()` plus layout code. Existing scenes keep their `$` paths unless a task touches those lines.

## Thread and ownership

Godot only. Nothing touches the engine's threads, and every engine-facing write goes through the existing `AutomationLane` mutators on the main thread.

| State | Owner | Reached from | Real-time safe |
|---|---|---|---|
| `Track.clip_editor_lanes` (open-lane entries) | Godot main thread, `Track` model | `ClipEditorLaneView`, `AutomationPane`, `to_json` / `from_json` | n/a (never sent to the engine) |
| `AutomationPane` selection manager | `AutomationPane` (one instance, separate from Timeline's) | its `ClipAutomationLaneRow`s | n/a |
| Lane preset file | `AutomationLanePresets` (static, read and written on explicit menu actions only) | both lane menus | n/a |

## Data and protocol changes

- **OSC:** none. Point edits go through `AutomationLane.add_point` / `update_point` / `remove_point`, and lane creation through `Track.add_automation_lane`. Both are already synced.
- **`Track` model:** new `var clip_editor_lanes: Array[Dictionary]`, where each entry is `{"id": String, "height": float}`, in pane order.
  - New `signal clip_editor_lanes_changed` and `func set_clip_editor_lanes(entries: Array[Dictionary])`, which drops ids that aren't in `automation_lanes`, clamps heights, and emits only when something changed.
  - It isn't part of `sync_to_engine()`, because it's UI state like `automation_expanded`.
  - `remove_automation_lane` drops the removed lane's entry (REQ-008).
  - `to_json` writes `"clip_editor_lanes"`. `from_json` reads it after the lanes are loaded and goes through the setter, so unknown ids are dropped (REQ-009). A missing key gives `[]`.
- **Lane preset file:** `<PresetLibrary.root_dir()>/automation_lane_presets.json`, version 1, shape as above. A missing or unreadable file reads as no presets, and an unreadable one is logged.
- **Editor preference:** the automation pane toggle uses `Sonara` config key `clip_editor/automation_pane` → `{"visible": bool}`, the same pattern as `NoteValuePane.CONFIG_KEY`. It's internal UI state, so it isn't registered in `Settings.gd`.
- **Hotkeys:** a new context `"clip_automation_lane"` with parent `"clip_editor"`, label `"Automation lane"`, and the three hint rows that `"automation_lane"` has (double-click add point, Shift-click toggle, Ctrl-drag range).

## File-by-file change list

| File | Change |
|---|---|
| `Godot/arranger/timeline/AutomationLaneRow.gd` | Add the hooks `_release_other_selection()`, `_redraw_background()` and `hotkey_context`, and make `_on_lane_height_changed` overridable; the existing call sites use them. Add the selection handles: `enum SelectionHandle { NONE, TILT_LEFT, TILT_RIGHT, COMPRESS }`, `HANDLE_SIZE` / `HANDLE_GAP`, `_selection_handle_rects()` (bounds of the selected points from `tick_to_x` / `value_to_y`), `_draw_selection_handles()` in `_draw_body`, and hover with `CURSOR_VSIZE`. Press handling: after the point hit and the tension-handle check, a plain press on a selection handle starts it (REQ-019). Motion runs `FineDrag` → `ValueLaneEdits.tilt_range` / `compress_range` on the values captured at press, written with `lane.update_point` (no history). Release calls `AutomationActions.move_points(lane, points, before, false, "Tilt Points"/"Compress Points")`. While a handle drag is live, the tooltip shows the `+N%` readout. |
| `Godot/clip_editor/automation/ClipAutomationLaneRow.gd` (new) | `extends AutomationLaneRow`. It has `midi_editor` and `pane_height`, and overrides `tick_to_x` / `x_to_tick` (`grid_helper.ticks_to_pixels(t) - h_scroll.scroll_horizontal + h_scroll.global_position.x - global_position.x`), `_snap_tick`, `_visible_x_range` (`0..size.x`), `_release_other_selection` (no-op), `_redraw_background` (`queue_redraw`) and `_on_lane_height_changed` (ignored). `_draw` fills with `get_lane_color()`, draws the grid lines as `ValueLaneStemArea._draw_grid` does, then calls `super`. It mirrors the playhead in `_process` as `ValueLaneStemArea` does. It sets `focus_mode = FOCUS_CLICK`, grabs focus on press, and sets `hotkey_context = "clip_automation_lane"`. It redraws on `grid_helper.changed` and `h_scroll` scroll. |
| `Godot/clip_editor/automation/AutomationPaneLane.gd` + `.tscn` (new) | Built like `ValueLane.tscn`: a resize grip, a header (name, max/min labels from `target.format_value(channel, 1.0/0.0)`, a bypass toggle using `HistoryUtil.execute_property` as `TrackList._on_lane_bypass_toggled` does, and a close button), then a `ClipAutomationLaneRow`. Signals `close_requested(lane)` and `height_changed(lane, h)`. Height clamp `ValueLane.MIN_HEIGHT..MAX_HEIGHT` (REQ-010). It shows the unresolved and bypassed look through the row (REQ-012). |
| `Godot/clip_editor/automation/AutomationPane.gd` + `.tscn` (new) | Built like `NoteValuePane`: an add `Button` opening the shared `AutomationLaneMenu` with a `ClipEditorLaneView`, `lanes_box`, and `_align_lanes` against `note_area`. `bind(editor, split, value_pane)`. It rebuilds the lanes from `focus_track.clip_editor_lanes` on `focus_track_changed`, `clip_editor_lanes_changed`, `automation_lane_removed` and `track_mode` changes (REQ-003, REQ-008), and clears its selection manager on focus change (REQ-014). It owns an `AutomationPointSelectionManager` (with `grid_helper` = the MIDI editor's) and an `AutomationParameterPicker`. `_gui_input` routes `edit_copy/cut/paste/duplicate/delete` to the selection manager's operations while a row has focus (REQ-013). It persists visibility to `clip_editor/automation_pane` (REQ-002). The pane height is the sum of its lanes, and the split offset is set when the value pane is hidden. |
| `Godot/clip_editor/automation/ClipEditorLaneView.gd` (new) | `extends AutomationLaneView`, backed by `Track.clip_editor_lanes`. `set_shown(…, true)` appends with `ValueLane` default height 96. `apply_shown` keeps the heights of lanes that were already open. `on_lane_created` opens the lane (REQ-006). |
| `Godot/arranger/tracklist/AutomationLaneView.gd` (new) | Base class with the methods listed under Approach. The default `on_lane_created` does nothing. |
| `Godot/arranger/tracklist/ArrangerLaneView.gd` (new) | `extends AutomationLaneView`, backed by `lane.visible`. `apply_shown` also sets `track.automation_expanded = true` (REQ-022). `capture` / `restore` cover every lane's `visible` and `automation_expanded`. |
| `Godot/arranger/tracklist/AutomationLaneMenu.gd` | `open_for(track, pos, view := ArrangerLaneView.new())`. Check items come from `view.is_shown` / `set_shown`. Below the lanes it adds a `Presets` section: one item per `AutomationLanePresets.names()`, `Save shown lanes as preset…` (disabled when `view.shown_lanes(track)` is empty), and a `Delete preset` submenu. The menu owns an `AutomationLanePresetSaveDialog` and a delete `ConfirmationDialog`, and calls `AutomationLanePresetActions`. It reports skipped entries (REQ-020–027). |
| `Godot/arranger/tracklist/AutomationLanePresetSaveDialog.gd` + `.tscn` (new) | A `Window` scene with `%NameEdit`, `%SaveButton`, `%CancelButton`, `%StatusLabel` and `%OverwriteConfirm`. Its behaviour is modelled on `NoteMapSaveDialog`, but its layout lives in the scene. It refuses an empty name and asks through a `ConfirmationDialog` before overwriting. It exposes `save_named(name, overwrite: bool) -> bool` for tests (REQ-021). |
| `Godot/arranger/tracklist/TrackList.gd` | `_on_automation_menu_requested` passes an `ArrangerLaneView`. `_on_automation_parameter_chosen`'s lane-creation body moves to `AutomationLanePresetActions.create_lane_for(track, target, view)`, which both hosts call. |
| `Godot/data/AutomationLanePresets.gd` (new) | The store: `names()`, `get_preset(name)`, `save(name, entries)`, `delete(name)`, `entries_for(track, lanes)` (target string + `device_id` from `target.resolve(channel)`), and the static `resolve_entry(entry, channel) -> AutomationTarget` (REQ-025), plus a depth-first helper that walks with paths. It reads and writes `PresetLibrary.root_dir()` so `PresetLibrary.dir_override` isolates tests (REQ-028). |
| `Godot/history/AutomationLanePresetActions.gd` (new) | Static `create_lane_for(track, target, view)`, `save(view, track, name)`, `load(view, track, preset) -> Array` (the skipped entries; one macro: create commands + `AutomationShownStateCommand`; a no-op when nothing resolves, REQ-023/024/026), and `delete(name)`. Command scripts are preloaded, as in `AutomationActions`. |
| `Godot/history/commands/AutomationShownStateCommand.gd` (new) | `do()` → `view.restore(track, after)`, `undo()` → `view.restore(track, before)`. |
| `Godot/arranger/timeline/AutomationPointSelectionManager.gd` | Gains `cut_selection()`, `paste_at(fallback_tick) -> Array`, `duplicate_selection()`, `delete_selection() -> bool` and `is_active()`, moved verbatim from `Timeline`'s `_automation_*`, `_select_pasted_points` and `delete_automation_selection`. |
| `Godot/arranger/timeline/Timeline.gd` | `_automation_is_active`, `_automation_cut`, `_automation_paste`, `_automation_duplicate` and `delete_automation_selection` delegate to the selection manager. No behaviour change. |
| `Godot/clip_editor/value_lanes/ValueLaneEdits.gd` | New `tilt_range(values, xs, delta, from_left, lo, hi)` and `compress_range(values, factor, lo, hi)`. `tilt` / `compress` call them with `d.min_value` / `d.max_value`. |
| `Godot/clip_editor/value_lanes/ValueLaneStemArea.gd` | `_begin` grabs focus for `midi_editor.get_active_note_editor()`, so a value-lane press takes the shortcuts back from an automation lane (REQ-013). |
| `Godot/clip_editor/value_lanes/NoteValuePane.gd` | `bind(editor, split := null, below: Control = null)`. `_split` comes from the argument and falls back to `get_parent()`. `_sync_split` and `_top_row_height` add `below`'s minimum height when it's visible. |
| `Godot/clip_editor/ClipEditor.tscn` / `ClipEditor.gd` | `EditorSplit/LanePanes` (VBox) holds `NoteValuePane` and `AutomationPane`. The toolbar gets `LanesGroup/AutomationLanesToggle` (a toggle button with the text "Automation", like `ValueLanesToggle`) after `ValueLanesToggle`. `value_pane.bind(midi_editor, editor_split, automation_pane)` and `automation_pane.bind(midi_editor, editor_split, value_pane)`. The toggle and pane are visible only while `track_mode` is on (REQ-001), applied where `left_panel.visible = track_mode` is already set. |
| `Godot/data/Track.gd` | `clip_editor_lanes`, its signal and setter, the `remove_automation_lane` drop, and JSON read/write (see Data). |
| `Godot/input/HotkeyActions.gd` | The `"clip_automation_lane"` context parent, label and hint rows. |
| `docs/subsystems/godot-architecture.md` | Clip editor section: the automation pane, the row hooks, `AutomationLaneView`, and lane presets. |
| `CHANGELOG.md` | `## [Unreleased]`: automation lanes in the MIDI editor's track mode, tilt and compress handles on automation, and lane presets. |

## Migration and compatibility

- **Old projects:** a `.sonara` without `clip_editor_lanes` loads with no open lanes in the MIDI editor. Older builds ignore the key.
- **Preset file:** it is new. A missing file means no presets. `version` is written now, so a later shape change can be detected.
- **Arranger behaviour** is unchanged apart from the handles. Plain presses on empty space between selected points still box-select, because the handles only take presses inside their 9 px rects.
- **Value-pane config** (`clip_editor/value_lanes`) is untouched.

## Test plan

Model and maths tests carry the logic. View tests stay shallow: they bind, assert what exists, and fire one gesture.

- **Godot:** `Godot/tests/test_value_lane_edits.gd` (extended) — `tilt_range` 0/960/1920 at 0.5, right +0.2 → 0.5/0.6/0.7, and `compress_range` 0.2/0.8 ×0.5 → 0.35/0.65, both clamped at 0..1 (REQ-016, REQ-017). The existing `tilt` / `compress` cases still pass.
- **Godot:** `Godot/tests/test_automation_selection_handles.gd` (new) — an `AutomationLaneRow` bound with a stub timeline: 1 point selected → no handle rects, 2 → 3 rects at the selection's edges (REQ-015). A tilt drag over 3 points, then one undo, restores all values (REQ-018). A press at a selected point's centre inside a handle rect starts a point drag (REQ-019).
- **Godot:** `Godot/tests/test_track_clip_editor_lanes.gd` (new) — the `to_json` / `from_json` round-trip, an unknown id dropped, a missing key → `[]` (REQ-009), `remove_automation_lane` drops the entry (REQ-008), and the setter clamps height without touching `lane.height` (REQ-010).
- **Godot:** `Godot/tests/test_automation_lane_presets.gd` (new, `PresetLibrary.dir_override` = scratch dir):
  - The store round-trips through a new instance (REQ-028).
  - Save with 2 shown lanes stores them in order; an empty name stores nothing; an existing name with `overwrite=false` keeps the old preset (REQ-021).
  - Load replaces the shown set and creates missing CC lanes seeded at their current values, for both views (REQ-022, REQ-023).
  - One undo restores the shown set and removes the created lanes (REQ-024).
  - Device resolution covers the same position and a moved Filter (REQ-025). A missing Filter is skipped and reported, and a load with nothing resolvable changes nothing (REQ-026).
  - Delete leaves the lanes alone (REQ-027).
- **Godot:** `Godot/tests/test_clip_editor_automation_pane.gd` (new, shallow):
  - Clip mode hides the pane and toggle, and track mode shows them (REQ-001). The toggle persists (REQ-002).
  - Focus A/B swaps the lanes, and a focus switch clears the point selection (REQ-003, REQ-014).
  - A point at tick 1920 lines up with `grid_helper.ticks_to_pixels(1920)` in the note area before and after scroll and zoom (REQ-004).
  - The menu lists lanes with check state and `Add new` last, and opens `Pan` (REQ-005).
  - A picked `Pan` creates a lane and opens it, and undo removes it (REQ-006). Close keeps the lane (REQ-007).
  - A double-click inserts at the snapped tick (REQ-011). The header shows the name, and its bypass toggle sets `lane.bypassed` (REQ-012).
  - Delete after a lane press removes points and keeps notes; after a note-area press it removes notes (REQ-013).
- **Godot regression:** `Godot/tests/run_all.sh automation value_lane clip_editor` — the existing `test_automation_range_ops.gd`, `test_automation_lane_menu.gd`, `test_value_lane_pane.gd` and `test_value_lane_stems.gd` still pass after the moves.
- **Live:** in track mode with an SFZ instrument:
  - Open CC1 in the pane and draw a ramp; it's audible and matches the Arranger lane.
  - Tilt-handle the ramp in both views.
  - Save `Strings` (CC1 + CC11), load it on another track, then undo.
  - Resize the pane split with and without value lanes shown.

## Risks

| Risk | Mitigation |
|---|---|
| Split sizing with two stacked panes fights `NoteValuePane`'s top-lane-fills rule (jumps on toggle) | `_sync_split` accounts for `below`'s height. The live step resizes and toggles each pane alone and both together. If it still fights, fall back to Godot 4.7's multi-child `SplitContainer` (`split_offsets`) as a third child, a design change to raise first. |
| The row's x mapping drifts from the notes by the scroll offset | REQ-004 test compares against `grid_helper.ticks_to_pixels` before and after scroll and zoom. The mapping is the same one `_build_value_stems` uses. |
| Focus-based routing breaks if a row press doesn't take focus (an embedded popup or tooltip) | The test presses the row and asserts `has_focus()` before checking that delete reaches the points. |
| Moving the clipboard operations out of `Timeline` changes Arranger behaviour | Verbatim move. `test_automation_range_ops.gd` and `test_automation_history.gd` must pass unchanged. |
| Handles intercept presses users meant for box select in the Arranger | They only appear with 2+ points selected, and points and tension handles win (REQ-019). Checked live. |

## Open questions

- None.
