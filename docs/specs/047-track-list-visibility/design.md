# Track List and Visibility Presets — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/data/Track.gd`: `hidden` and `enabled` read the linked `Channel`. `set_hidden`,
  `set_enabled`, `set_name` and `set_color` are the setters. `name_changed`, `color_changed`,
  `order_changed`, `parent_changed` and `item_state_changed` are the signals. `parent_track_id`
  and `child_track_ids` hold the tree, and `is_folder_expanded` is the arranger's own folder state.
- `Godot/data/Channel.gd`: `set_hidden` emits `hidden_changed` and calls
  `_notify_project_visibility()`, which calls `Project.notify_item_visibility_changed()`.
- `Godot/data/Project.gd`: `tracks`, `get_visual_track_list()`, `get_track_children()`,
  `get_track_by_id()`. Its signals are `track_added`, `track_removed`, `tracks_layout_changed`
  and `item_visibility_changed`. `notify_item_visibility_changed()` pushes enabled state to the
  engine, then emits `item_visibility_changed` and `tracks_layout_changed`. Serialization goes
  through `to_json()` / `from_json()`.
- `Godot/data/ItemVisibility.gd`: `track_hidden`, `track_disabled`, `track_listed`,
  `channel_listed` and `dim_alpha`.
- `Godot/clip_editor/tracklist/ClipEditorTrackList.gd`: the closest existing pattern. It's a
  `VBoxContainer` of row scenes in a `ScrollContainer`, rebuilt by a deferred `_queue_rebuild`.
  List-level drag painting happens in `_input`, using `_item_at_global_y` hit-testing that only
  counts rows inside the scroll viewport, so fast drags don't skip rows.
- `Godot/components/DragToggleButton.gd`: per-button painting for mute, solo and arm. Shift+press
  calls `_clear_others()`.
- `Godot/history/HistoryUtil.gd`: `execute`, `record`, `execute_many`, `record_many`,
  `execute_property` and `test_recorder` (used by headless tests). Commands live in
  `Godot/history/commands/`: `MacroCommand`, `PropertyCommand`, `ChannelsPropertyCommand`, and
  `KeyChangeMapStateCommand` (the before/after snapshot pattern). Executing through the editor
  marks the project as modified (`Editor._sync_modified_from_history`).
- `Godot/editor/Editor.gd`: `current_view` (`View.ARRANGER / MIXER / EDITOR / DEVICE`),
  `set_track_selection()`, the `tracks_selected` signal, `_select_track_externally()`, and
  `_unhandled_input()`, which handles the global hotkeys. `SelectionSync.channels_for_tracks()`
  (`Godot/editor/SelectionSync.gd`) maps tracks to channels.
- `Godot/arranger/tracklist/TrackList.gd`: owns the arranger track selection. It has
  `set_selection_silent()`, the `selection_changed` signal, `_find_track_item()` and
  `_ensure_track_item_visible()`.
- `Godot/mixer/Mixer.gd`: `set_selection_silent()`, `find_mixer_channel_ui_for_channel()`, and
  the `left_pane` / `right_pane` `ScrollContainer`s.
- `Godot/editor/docks/DockHost.gd`: `_NODE_IDS`, `_TITLES`, `_DEFAULT_LEFT`, `_show_panel()` (it
  always appends to the right dock) and `_apply_saved_layout()` (an id missing from a saved layout
  is parked hidden). `Godot/editor/MainMenu.gd` builds a View check item for every
  `DockHost.get_panel_ids()` entry, so new panels appear in the menu without changes there.
- `Godot/input/HotkeyActions.gd`: the `ACTIONS` table (with group `"View"` and context
  `"global"`). Settings builds a rebindable `shortcuts/<id>` from each row.
- Icons: `res://assets/icons/eye.svg`, `eye-off.svg`, `chevron-right.svg` and `chevron-down.svg`.
  There is no mixed-state eye icon.

## Approach

There are three layers: a preset model on the project, a static visibility service that owns
every rule, and the panel UI. Hotkeys call the service directly, so they work while the panel is
hidden (REQ-024).

**Model.** A new `VisibilityPresets` (`RefCounted`) is owned by `Project` as
`project.visibility_presets`. It holds an ordered list of `{name, hidden_track_ids}` plus
`active_index` (−1 = none), and emits `changed`. It has `snapshot()` / `restore()` for undo,
like `KeyChangeMap`. A preset stores the IDs of tracks whose own `hidden` flag is set, not the
effective (cascaded) state. Storing the effective state would make children of a hidden folder
"stick" hidden after the folder is shown again.

**Service.** `TrackVisibility` (static functions) works on a project:
- `capture(project)` returns the sorted IDs of tracks whose `hidden` is true.
- `apply_hidden_set(project, ids, label)` builds the change and executes it as one undo step.
- `show_all`, `show_only(track)`, `show_branch(track)`, `apply_preset(i)`, `step_preset(dir)`,
  `is_dirty`, `selector_label`.
- `add_preset`, `rename_preset`, `delete_preset`, `move_preset` and `save_preset` wrap a
  `VisibilityPresetsStateCommand`.

Hidden lives on the channel, so the service sets visibility per **target**: the linked channel,
or the track itself if it has no channel. Every target is set once. A target is hidden if any of
its tracks is in the set. This rule only matters if tracks were re-routed after the preset was
saved, because a capture always records tracks that share a channel together.

Applying a preset is one `MacroCommand`. It has a `VisibilityStateCommand` (target → old/new
bool) and a `VisibilityPresetsStateCommand` for the `active_index` change, so undo also restores
which preset is active.

**Batching.** Every `set_hidden` currently ends in `notify_item_visibility_changed()`, which
re-filters the arranger and mixer. That's one relayout per track, too slow on a 300-track
project. `Project` gets `batch_visibility(fn: Callable)`: a depth counter. While it's above zero,
`notify_item_visibility_changed()` only sets a pending flag, and the outermost call ends with one
notify. `VisibilityStateCommand.do/undo` and the panel's drag painting run inside it.

**Panel.** `TrackListPanel` is a `VBoxContainer` holding:
- a header with the preset `OptionButton`, a ⋯ `MenuButton` (Add / Rename / Delete / Move Up /
  Move Down) and the Save and Reset buttons;
- a filter `LineEdit`;
- a `ScrollContainer` with one `TrackListRow` per listed track.

Rows are rebuilt by a deferred `_queue_rebuild()` when the structure changes (`track_added`,
`track_removed`, `tracks_layout_changed`, or per-track `order_changed` / `parent_changed`). On
`item_visibility_changed`, `name_changed` and `color_changed` the rows only refresh in place.
Expand/collapse state is a panel-local `Dictionary` (track ID → collapsed), so it never touches
`is_folder_expanded` (REQ-003) and isn't saved.

**Drag painting** follows `ClipEditorTrackList`. The press on an eye is handled by the row, which
emits `eye_pressed(shift)`. The panel records the old state of every target and applies the new
value live (inside `batch_visibility`). In `_input` it paints each row the pointer crosses: it
hit-tests the segment between the last and the current mouse position, so fast drags don't skip
rows. On release it records one `VisibilityStateCommand` with `HistoryUtil.record()` (REQ-008).
Shift+press calls `TrackVisibility.show_only()` and doesn't start painting (REQ-009).

**Selection** stays owned by the arranger's `TrackList`. The panel computes plain, Ctrl and
Shift selection over its own visible rows and calls a new `Editor.select_tracks(tracks, active)`.
That updates the arranger (`set_selection_silent`), the mixer (`SelectionSync` →
`set_selection_silent`) and the Editor's state (`set_track_selection(..., false)`, so record arm
doesn't follow). The panel highlights from `Editor.tracks_selected`, so a selection made in the
arranger shows in the list too (REQ-011). A plain click also calls `Editor.reveal_track(track)`.
In the mixer view that calls `Mixer.reveal_channel()`, and otherwise
`TrackList.reveal_track()`. Neither scrolls when `ItemVisibility.track_listed` /
`channel_listed` is false (REQ-012).

**Rejected alternatives.**
- *Godot `Tree`.* It has built-in arrows, selection and keyboard navigation, but it draws the
  fold arrow only in column 0, at the start of the cell. That makes the required eye | arrow |
  color | name order impossible without custom-drawing every cell, and drag painting across
  `TreeItem` buttons would be a second, ad-hoc implementation.
- *`DragToggleButton` for the eye.* It emits `toggled` per button, so a sweep becomes N undo
  steps, and its Shift path clears every other button in the group. REQ-009 needs ancestors and
  descendants kept visible, and REQ-008 needs one undo step. The panel paints at list level
  instead, like `ClipEditorTrackList`.
- *Reusing the arranger's `TrackItemContextMenu`.* It brings Delete, Duplicate, bus linking and
  routing, which REQ-014 doesn't ask for, and its hide/enable toggles aren't undoable. The panel
  gets a small `PopupMenu` of its own.

## Thread and ownership

All of this is on the Godot main thread, and none of it reaches the audio callback. Enable and
Disable go through the existing `Track.set_enabled` → `Channel.apply_enabled_to_engine()` OSC
path.

| State | Owner | Reached from | Real-time safe |
|---|---|---|---|
| `Project.visibility_presets` | `Project` (main thread) | panel, `TrackVisibility`, hotkeys, undo commands | n/a (UI only) |
| Track List expand/collapse map | `TrackListPanel` | itself only | n/a |
| `Project._visibility_batch_depth` / pending flag | `Project` | `batch_visibility`, `notify_item_visibility_changed` | n/a |

## Data and protocol changes

- **No OSC changes.**
- **`.sonara`**: `Project.to_json()` gains:
  ```json
  "visibility_presets": {
    "active": 0,
    "presets": [ {"name": "Orchestra", "hidden_track_ids": [4, 7, 12]} ]
  }
  ```
  `from_json()` reads it with `VisibilityPresets.from_json(data.get("visibility_presets", {}))`.
  A missing key gives an empty list with `active = -1`. Unknown track IDs are dropped after the
  tracks are loaded (`prune(existing_ids)`), and an out-of-range `active` becomes −1.
  `FORMAT_VERSION` is unchanged because the key is additive.
- **Deleting a track** (REQ-023): IDs are pruned **lazily**. `capture`, `is_dirty` and
  `apply_preset` ignore IDs with no track, and `to_json()` writes only existing ones. So the next
  save removes a deleted track from every preset. Undoing the deletion brings the track (same ID)
  back into its presets, which removing it eagerly on `track_removed` would break.
- **Hotkeys**: new `ACTIONS` rows in group `"View"`, context `"global"`:
  `visibility_show_all` (Ctrl+0), `visibility_preset_1` … `visibility_preset_9`
  (Ctrl+1 … Ctrl+9), `visibility_preset_next` and `visibility_preset_previous` (no default).
  Settings creates the `shortcuts/<id>` entries from the table, so no other change is needed.
- **Dock layout** (`ui/docks` config): new panel ID `track_list`. The format is unchanged.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/data/VisibilityPresets.gd` | **New.** `class_name VisibilityPresets extends RefCounted`. It holds `presets: Array[Dictionary]` and `active_index`, and emits `changed`. Methods: `add(name, ids) -> int`, `rename(i, name)`, `remove(i)`, `move(i, to)`, `set_hidden_ids(i, ids)`, `set_active(i)`, `get_preset(i)`, `count()`, `display_name(i)` → `"%d: %s"`, `snapshot()` / `restore()`, `prune(existing: Dictionary)`, `to_json(existing)` / `static from_json(d)`. |
| `Godot/data/Project.gd` | Adds `var visibility_presets := VisibilityPresets.new()`. Writes and reads `"visibility_presets"` in `to_json()` / `from_json()`, with the prune after the tracks load. Adds `batch_visibility(fn: Callable)`, plus `_visibility_batch_depth` and `_visibility_notify_pending`, and makes `notify_item_visibility_changed()` defer while the depth is above zero. |
| `Godot/history/commands/VisibilityStateCommand.gd` | **New.** `old_values` / `new_values: Dictionary` (target `Object` → `bool`), and `project`. `do` / `undo` apply `set_hidden` inside `project.batch_visibility`, skipping freed targets (`is_instance_valid`). |
| `Godot/history/commands/VisibilityPresetsStateCommand.gd` | **New.** Before/after `VisibilityPresets.snapshot()`, same shape as `KeyChangeMapStateCommand`. |
| `Godot/editor/track_list/TrackVisibility.gd` | **New.** `class_name TrackVisibility`, static only. Methods: `target_of(project, track)` (the linked channel, or the track), `capture`, `hidden_changes(project, ids) -> VisibilityStateCommand` (null when nothing changes), `apply_hidden_set`, `show_all`, `show_only`, `show_branch` (REQ-010), `is_only_visible_branch`, `apply_preset`, `step_preset`, `is_dirty`, `is_mixed(project, track)`, `selector_label`, `add_preset` (name `"Vis Group %d" % (count + 1)`), `rename_preset`, `delete_preset`, `move_preset`, `save_preset`, `reset_preset`. Every mutating call goes through `HistoryUtil`. |
| `Godot/editor/track_list/TrackListRow.gd` + `.tscn` | **New.** `PanelContainer` → `HBox`: an indent `Control`; an eye `Button` (flat, icon `eye` / `eye-off`, a mixed state drawn as the `eye` icon at half alpha with an accent underline); a fold `Button` (`chevron-right` / `chevron-down`, made invisible but keeping its width on tracks without children, so names line up); a 4 px color `ColorRect`; and a name `Label` with a `LineEdit` swapped in while renaming. It emits `eye_pressed(shift)`, `fold_pressed`, `row_pressed(ctrl, shift)`, `row_double_clicked`, `context_requested(pos)` and `rename_committed(text)`. `refresh()` reads the track (name, color, own hidden flag, mixed state, `modulate.a = ItemVisibility.dim_alpha(...)`) and `set_selected(bool)`. |
| `Godot/editor/track_list/TrackListPanel.gd` + `.tscn` | **New.** The header, filter, scroll and rows described in Approach. It binds on `Sonara.editor.project_activated` / `project_closed`. It handles row signals, drag painting in `_input`, the keyboard (Up/Down/Left/Right/Space in `_gui_input` while focused), the context `PopupMenu` (Rename, Color, Hide/Show, Enable/Disable, Expand All, Collapse All), and a `PopupPanel` with a `ColorPicker`. Color edits apply live and are recorded once when the popup closes, the same pattern as `ClipInspector`. It calls `HotkeyActions.declare_context(self, "tracklist")`. |
| `Godot/editor/Editor.tscn` | Adds a `TrackListPanel` instance under `LeftDock`, before `Inspector`. |
| `Godot/editor/docks/DockHost.gd` | `_NODE_IDS["TrackListPanel"] = "track_list"`, `_TITLES["track_list"] = "Track List"`, `_DEFAULT_LEFT = ["track_list", "inspector"]`. `_show_panel()` puts a panel that has never been placed into the dock whose default list contains its ID (left for `track_list` and `inspector`), so existing users toggling it on from View get it in the left dock. |
| `Godot/editor/Editor.gd` | Adds `select_tracks(tracks, active)` (as in Approach, guarded by `_syncing_selection`) and `reveal_track(track)`. In `_unhandled_input` it dispatches `visibility_show_all`, `visibility_preset_1..9` and `visibility_preset_next/previous` to `TrackVisibility`. |
| `Godot/arranger/tracklist/TrackList.gd` | Adds `reveal_track(track)`: `_ensure_track_item_visible(_find_track_item(track))`. |
| `Godot/mixer/Mixer.gd` | Adds `reveal_channel(ch)`: finds the strip with `find_mixer_channel_ui_for_channel`, then calls `ensure_control_visible` on whichever pane contains it. |
| `Godot/input/HotkeyActions.gd` | Adds the 12 `ACTIONS` rows listed above. |
| `Godot/tests/test_visibility_presets.gd` | **New.** Covers the model, the service and serialization. |
| `Godot/tests/test_track_list_panel.gd` | **New.** Covers the panel's UI behaviour. |
| `Godot/tests/test_dock_layout.gd` | Adds `track_list` default placement and the show-from-View case. |
| `docs/subsystems/godot-architecture.md` | Adds a "Track List and visibility presets" section. |
| `CHANGELOG.md` | Adds an `[Unreleased]` entry. |

## Migration and compatibility

- Old projects have no `visibility_presets` key, so they load with no presets and nothing
  changes.
- A project with presets opened in an older build: the key is ignored and lost on the next save.
  Track hidden flags themselves are unaffected.
- An existing `ui/docks` layout has no `track_list` entry, so the panel starts hidden (current
  `_apply_saved_layout` behaviour). View › Track List shows it in the left dock. A fresh config
  shows it in the left dock above the Inspector.

## Test plan

- **Godot:** `godot --headless --path Godot -s tests/test_visibility_presets.gd -- --test`
  - `capture` / `apply_preset` round trip. A track created after saving is visible on apply
    (REQ-018).
  - Two tracks on one channel are applied once. The "any hidden" rule holds.
  - `show_all`, then undo (REQ-017). `show_only`, plus a second `show_only` showing everything
    (REQ-009). `show_branch` on a mixed folder (REQ-010). `is_mixed`.
  - Add naming `"Vis Group 3"` with two existing presets (REQ-019). Move, then undo the order
    (REQ-020). Rename. Delete.
  - `is_dirty` and `selector_label`: `"1: Orchestra *"` and `"Custom"` (REQ-021). Save and Reset
    (REQ-022).
  - `to_json` / `from_json` round trip, a missing key, a stale track ID dropped, an
    out-of-range `active` (REQ-023). A deleted track is gone from `to_json`, and undoing the
    delete restores it in the preset.
  - `step_preset` wraps through "All" (REQ-025). A hotkey index past the end does nothing
    (REQ-024).
  - `batch_visibility`: applying 300 tracks emits `item_visibility_changed` once and takes less
    than 50 ms (non-functional).
- **Godot:** `godot --headless --path Godot -s tests/test_track_list_panel.gd -- --test`
  - Row order and indent for A, F{B, C}, D, and the arrow only on F (REQ-002). Collapsing F leaves
    `is_folder_expanded` unchanged (REQ-003). Dimming (REQ-004).
  - Live updates: add, remove, rename, recolor, reparent and an undone hide (REQ-005). Filter
    `"c"`, then clear (REQ-006).
  - Eye click (REQ-007). A synthesized press, a motion across 4 rows and a release give 4 hidden
    tracks and one history entry (REQ-008). Shift-click (REQ-009). Mixed click (REQ-010).
  - Click and Ctrl-click select {B, D} in the arranger `TrackList` (REQ-011). Double-click rename
    (REQ-013). Context-menu Disable on two tracks, then one undo (REQ-014). The four keys
    (REQ-015).
  - Selector items `"All", "1: Orchestra", "2: Drums"` (REQ-016).
- **Godot:** `godot --headless --path Godot -s tests/test_dock_layout.gd -- --test`: a fresh
  layout puts `track_list` first in the left dock. With a saved layout lacking it, showing it
  places it in the left dock (REQ-001).
- **Hotkeys:** a test in `test_visibility_presets.gd` builds `InputEventKey` Ctrl+2 and checks
  `Hotkeys.pressed(event, "visibility_preset_2")` (REQ-024). It also checks that the Ctrl+2 chord
  doesn't match `keyboard_c#3` (a physical "2" with no modifier).
- **Live:**
  1. Open a project with about 60 tracks and show View › Track List.
  2. Drag the eye down 10 rows. The arranger and mixer update together, and one Ctrl+Z restores
     them.
  3. Add two presets, press Ctrl+1 and Ctrl+2, and edit to see the `*`. Save, reload the project,
     and check the presets.
  4. Click a row in the arranger view and in the mixer view, and check the scroll (REQ-012).
  5. Rebind Ctrl+1 in Settings.

## Risks

| Risk | Mitigation |
|---|---|
| A rebuild on every `tracks_layout_changed` (also emitted by every visibility notify) makes drag painting rebuild 300 rows per frame | Visibility changes only `refresh()` rows in place. Structural rebuilds are queued and coalesced, and `TrackListPanel` ignores `tracks_layout_changed` when the visual track list's IDs and parents are unchanged (compared against a cached signature) |
| Ctrl+digit collides with the computer keyboard's physical digit notes, or with bindings the user already has | A hotkey test asserts that Ctrl+2 doesn't trigger `keyboard_c#3`. The Settings conflict report already flags user-defined clashes |
| `batch_visibility` callers that throw or return early leave the depth raised | `batch_visibility` decrements in all paths. GDScript has no `finally`, so `fn` must not `await`, and this is documented on the method |
| Shared-channel hiding surprises users (hiding one track hides its sibling on the same channel) | This is existing issue 70 behaviour. Rows refresh from `item_visibility_changed`, so both eyes flip together and the effect is visible |

## Open questions

- [ ] None blocking. One deliberate reading of REQ-023: a deleted track is removed from presets on
      the next save, not the moment it is deleted, so undoing the delete keeps the track's preset
      membership. Confirm this is acceptable.
