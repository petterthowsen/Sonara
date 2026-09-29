# Clip Editor Track List — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/clip_editor/ClipEditor.gd`, the `ClipEditor` class:
  - It owns the mode toggle (`track_mode_toggle`, driven by `_update_mode_ui` and
    `_on_track_mode_toggle_toggled`), the track list (`track_selector`) and the ruler.
  - It keeps the track-mode memory in `last_track_mode_tracks`,
    `last_track_mode_selected_track` and `last_active_clip_by_track`.
  - `_bind_track_mode()` fills the list with `track_selector.set_tracks(selected_tracks)`
    (the tracks of the selected clips only) and calls
    `midi_editor.bind_to_clips(selected_clips, selected_tracks)`.
  - `_rebuild_ruler_regions()` iterates `selected_tracks`.
  - `track_mode_track_selected` is consumed by
    `Editor._on_clip_editor_track_mode_track_selected` (`Godot/editor/Editor.gd:743`).
- `Godot/clip_editor/ClipEditor.tscn` contains the path `HSplit/MainPanel/VBox/PanelContainer/MainHeader/MainOptions/TrackModeToggle`,
  a text `Button` with `toggle_mode = true`.
- `Godot/clip_editor/tracklist/ClipEditorTrackList.gd` (`ClipEditorTrackList`, a
  `PanelContainer` holding the `$Items` VBox):
  - Its methods are `set_tracks`, `select_track`, `select_track_no_signal` and
    `_on_item_pressed`, and it emits `track_selected(track)`.
- `Godot/clip_editor/tracklist/ClipEditorTrackListItem.gd` and `.tscn`
  (`ClipEditorTrackListItem`, a `BoxContainer` holding a `Label`):
  - It draws the track colour itself in `_draw`, and emits `pressed` on a left click.
- `Godot/clip_editor/MidiEditor.gd`:
  - `bind_to_clips(clips, tracks)` creates one `NoteEditor` per track in `note_editors`, and
    `current_track` (the selected track) has a setter that calls `_update_note_editor_states()`
    and emits `current_track_changed`.
  - `get_active_note_editor()` falls back to `note_editor` when `current_track` is null.
  - Input goes through `_handle_left_mouse_press`, `_handle_right_mouse_press` and
    `_handle_note_editing_mouse_motion`, all of which act only on `get_active_note_editor()`.
- `Godot/clip_editor/note_editor/NoteContainer.gd` has `_get_note_at_position(pos)` (hits only
  visible, non-pending notes, top-most first), `track` and `multi_clip_mode`.
  `NoteEditor.erase_note(note)` records its own undo step, based on the note's clip.
- `Godot/data/Project.gd` has the signals `track_added(track)`, `track_removed(track)` and
  `tracks_layout_changed`, plus `get_visual_track_list()` and `create_instrument_track(name)`.
  `Track.order_changed(new_order)`, `Track.get_project_ref()` and
  `Track.TrackType.INSTRUMENT` are also available.
- `Godot/data/Clip.gd`: `Clip.set_name(new_name)` emits `clip_modified`.
- `Godot/assets/icons/` already has `eye.svg`, `eye-off.svg` and `list-music.svg`.
  `fetch_lucide_icons.sh` fetches more icons in the house style.

## Approach

**A pure state model.** Visibility, editability and solo live in a new `TrackToggleState`
(`RefCounted`). It does not depend on any UI, so every rule in REQ-021 to REQ-027 and REQ-031
can be tested headless without simulated clicks. `ClipEditor` owns one instance for the whole
session, so the state survives rebinds and switches between track and clip mode (REQ-021's
re-entry rule), and nothing is written to disk. The model emits `changed`, and `ClipEditor`
applies it in one place (`_apply_track_toggles`). That method:
- tells the list to refresh its icons,
- tells `MidiEditor` which tracks to show and which to make editable,
- and then repairs the selection.

**`MidiEditor` keeps one `NoteEditor` per visible track.** `MidiEditor.set_track_views(tracks,
edited_clips)` reconciles `note_editors` against the visible tracks in place. It keeps the
editors whose track stays visible, so their selection survives. It binds new editors for tracks
that become visible and frees the editors of tracks that are hidden. The scene's first editor
always stays in the array and is only rebound. This way hidden tracks cost nothing (the
performance NFR).

**Hit-testing across editors.** `MidiEditor.editable_tracks` holds the list, in list order.
`_note_hit(global_pos)` asks the active editor first and then every other editable editor in
that order, which gives the priority in REQ-035. If a left press hits a note that belongs to
another editor:
1. `MidiEditor` sets `current_track`.
2. It emits `note_track_picked(track)`. `ClipEditor` turns that into a list selection plus
   `track_mode_track_selected`, which gives the mirroring in REQ-034.
3. The gesture then runs on the newly active editor, unchanged.

Erase uses the same hit function but calls `erase_note` on the editor that owns the note, and
never switches tracks (REQ-037). Box select and keys go through `get_active_note_editor()` as
before (REQ-038). With no selected track in track mode, `get_active_note_editor()` returns
null and a press on empty space does nothing (REQ-031).

**Rejected alternative: putting every track's notes into one `NoteEditor`.** That would make
cross-track hits trivial. But placement, clipboard, undo snapshots and per-track colours all
assume one track per editor (`NoteContainer.track`, `edited_clip_instances`), so it would mean
rewriting `NoteContainer`. We keep the per-track editors and pay only for a small hit-test loop.

**Rejected alternative: rebinding everything with `bind_to_clips` on every toggle.** It is
simpler, but `bind_to_clips` clears every editor's selection. Hiding an unrelated track would
then wipe the user's note selection.

**Drag-to-paint (REQ-024).** Once a mouse press starts on a toggle, Godot routes every later
motion event to that control, so the list items never see `mouse_entered`. The list therefore
tracks the drag itself. The item emits
`toggle_pressed(kind, shift)`:
- On a plain press, the list records `_paint_kind` and `_paint_value` (the new state of the
  pressed toggle) and applies them.
- While painting, `ClipEditorTrackList._input` maps the pointer's Y coordinate to an item and
  sets that item's state to `_paint_value`. Setting a state to the value it already has does
  nothing, so dragging back over an item never flips it twice.
- Releasing the left button ends the paint.
- A Shift+press calls `toggle_solo` and starts no paint.

## Thread and ownership

The feature is UI only and runs on the Godot main thread. It does not touch the engine, OSC or
the audio callback.

| State | Owner | Reached from | Real-time safe |
|---|---|---|---|
| per-track visible/editable flags, solo snapshots | `ClipEditor.track_toggles` (`TrackToggleState`) | `ClipEditorTrackList` (reads, and writes through its methods), `ClipEditor._apply_track_toggles` | n/a (UI) |
| visible note editors | `MidiEditor.note_editors` | `set_track_views` | n/a |
| editable track order | `MidiEditor.editable_tracks` | set by `ClipEditor._apply_track_toggles` | n/a |

## Data and protocol changes

- No OSC message is added and no persisted key is added. No `data/` model changes: nothing
  here syncs to the engine.
- New class `TrackToggleState` (`Godot/clip_editor/tracklist/TrackToggleState.gd`):
  - `enum Kind { VISIBLE, EDITABLE }` and `signal changed`.
  - `set_tracks(tracks: Array[Track])` keeps the known tracks' states and gives new tracks
    `false`/`false`. It drops removed tracks, including from the solo snapshots. If a soloed
    track is removed, that solo ends and the snapshot is restored.
  - `init_from_selection(tracks, selected: Array[Track])` sets selected tracks to `true`/`true`
    and all others to `false`/`false`, and clears both solos.
  - `is_on(track, kind) -> bool`, and `is_editable(track) -> bool`, which is
    `is_on(VISIBLE) and is_on(EDITABLE)` (REQ-023).
  - `set_on(track, kind, on)`. If it changes a value while that kind is soloed, it ends the
    solo and keeps the current states (REQ-027).
  - `toggle_solo(track, kind)` covers REQ-025 to REQ-027:
    - with no solo, it snapshots and solos `track`,
    - on the soloed track, it restores the snapshot,
    - on another track, it moves the solo and keeps the original snapshot.
  - `soloed_track(kind) -> Track` returns null when the kind is not soloed.
  - `first_editable(tracks) -> Track` returns the first editable track, in the order given.
- `MidiEditor` gets:
  - `signal note_track_picked(track: Track)`,
  - `var editable_tracks: Array[Track]`,
  - `func set_track_views(tracks: Array[Track], edited_clips: Array[ClipInstance])`,
  - `func _note_hit(global_pos: Vector2) -> Array`, which returns `[editor, note]` or `[]`,
  - `func _editor_track(editor) -> Track`, which factors out the track lookup that is currently
    duplicated in `get_active_note_editor()` and `_update_note_editor_states()`.
- `ClipEditorTrackListItem` gets `signal toggle_pressed(kind: int, shift: bool)`,
  `func refresh_toggles(state: TrackToggleState)` and a `pressed` signal, which already exists.
- `ClipEditorTrackList` gets:
  - `func set_toggle_state(state: TrackToggleState)`,
  - `func set_project(project: Project)`, which subscribes to `track_added`, `track_removed`,
    `tracks_layout_changed` and every listed track's `order_changed`, and rebuilds when any of
    them fire,
  - `func listed_tracks() -> Array[Track]`,
  - `signal tracks_changed`, which `ClipEditor` uses to re-sync `TrackToggleState.set_tracks`.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/assets/icons/fetch_lucide_icons.sh` | Add `pencil pencil-off layers` to `names`, then run the script to create `pencil.svg`, `pencil-off.svg` and `layers.svg` (Godot creates the `.import` files on the next editor or headless import). |
| `Godot/clip_editor/tracklist/TrackToggleState.gd` | **New.** The pure state model described above. |
| `Godot/clip_editor/tracklist/ClipEditorTrackListItem.tscn` | Change the root to a `PanelContainer`, with `HBox` → `Label` (expand), `VisibleToggle` (`Button`, flat, 20×20, eye icon) and `EditToggle` (`Button`, flat, 20×20, pencil icon). Set the root's `mouse_filter` to STOP. |
| `Godot/clip_editor/tracklist/ClipEditorTrackListItem.gd` | Extend `PanelContainer` and drop `_draw`.<br>Build a per-item `StyleBoxFlat`:<br>• background = `Utils.display_color(track.color)` (alpha 1.0 when selected, 0.7 otherwise)<br>• corner radius 4<br>• content margins 6/4<br>• border 1 px, `bg.lightened(0.25)` at alpha 0.5 when unselected<br>• border 2 px, `Color.WHITE` when selected (REQ-012)<br>A left press on the toggles emits `toggle_pressed(kind, event.shift_pressed)`. A press elsewhere emits `pressed`.<br>`refresh_toggles(state)` sets the icons (eye / eye-off, pencil / pencil-off), dims the edit toggle while the track is hidden (REQ-023), and uses `SOLO_COLOR` (`Color("#ffb13b")`) as `icon_normal_color` / `icon_hover_color` on the soloed toggle, with the contrasting text colour otherwise (REQ-025). |
| `Godot/clip_editor/tracklist/ClipEditorTrackList.gd` | Add `set_project` (the list = the instrument tracks from `project.get_visual_track_list()`, REQ-010 and REQ-011), `set_toggle_state`, `listed_tracks`, `tracks_changed` and the paint handling (`_on_item_toggle_pressed`, `_input`, `_item_at_global_y`; REQ-024).<br>`set_tracks` and `set_tracks_from_clips` stay for existing callers, but `ClipEditor` stops using them.<br>Rebuilding keeps `selected_track` when that track is still listed. |
| `Godot/clip_editor/tracklist/ClipEditorTrackList.tscn` | Give `Items` a 4 px `separation` and remove the placeholder item instance. |
| `Godot/clip_editor/ClipEditor.tscn` | `TrackModeToggle`: `text = ""`, `icon = layers.svg`, `flat`, `tooltip_text`. Add `ClipNameLabel` (a `Label`) after it in `MainOptions`. |
| `Godot/clip_editor/ClipEditor.gd` | Add:<br>• `track_toggles := TrackToggleState.new()`, connected to `_apply_track_toggles`<br>• `@onready clip_name_label`<br>• `_project()`: `_editor.project`, otherwise the first known track's `get_project_ref()`<br>• `_listed_tracks()`<br><br>`_bind_track_mode()`:<br>• calls `track_selector.set_project(_project())` and `set_toggle_state`<br>• when entered from a new selection (`_bind_pending_clips`), calls `track_toggles.init_from_selection(listed, selected_tracks)`; otherwise calls `set_tracks(listed)` (REQ-021)<br>• then calls `_apply_track_toggles()`<br><br>`_apply_track_toggles()`:<br>• refreshes the list<br>• calls `midi_editor.set_track_views(visible, selected_clips)` and sets `midi_editor.editable_tracks`<br>• then calls `_ensure_valid_selection()` (REQ-031 and REQ-032): keep `midi_editor.current_track` if it is editable, otherwise use `first_editable`, otherwise null<br>• marks the ruler context dirty<br><br>`_on_track_selector_track_selected` first makes the track visible and editable (REQ-030).<br>Connect `midi_editor.note_track_picked`: select in the list silently, then set `last_track_mode_selected_track`, then emit `track_mode_track_selected` (REQ-034).<br>`_rebuild_ruler_regions` iterates the visible tracks instead of `selected_tracks`.<br>`_update_mode_ui` sets `track_mode_toggle.tooltip_text`. It also shows `clip_name_label` only in clip mode, with the text set by `_update_clip_name()`, which watches `bound_clip_instance.clip.clip_modified` (REQ-001 to REQ-003). |
| `Godot/clip_editor/MidiEditor.gd` | Add `note_track_picked`, `editable_tracks`, `set_track_views`, `_note_hit` and `_editor_track`.<br>In track mode with a null `current_track`, `get_active_note_editor()` returns null.<br>`_update_note_editor_states()`: the active editor gets alpha 1.0 and z 1, other editable editors get 0.85 and z 0, and non-editable visible editors get 0.5 and z 0 (REQ-022).<br>`_handle_left_mouse_press` uses `_note_hit` and, on a hit in another editor, sets `current_track` and emits `note_track_picked` before starting the gesture (REQ-033 to REQ-035). A press on empty space with no active editor returns without placing a note (REQ-031 and REQ-036).<br>Right press and erase motion use `_note_hit` and the owner editor's `erase_note` and `last_erased_note` (REQ-037).<br>`_note_hit` skips editors whose track is not in `editable_tracks` (REQ-039).<br>`bind_to_clips` stays as it is for callers that don't use toggles. |
| `Godot/tests/test_clip_editor_track_list.gd` | **New.** Covers every test in the test plan below. |
| `docs/subsystems/godot-architecture.md` | Update the ClipEditor, MidiEditor and track list paragraphs: all instrument tracks are listed, the visibility and edit toggles with drag and solo, cross-track hits, and the clip name in the header. |
| `TODO.md` | Add a backlog entry for spec 007. |

## Migration and compatibility

Nothing is persisted, and `.sonara` and `config.json` are unchanged. Clip mode behaves as
before, apart from the header label and the icon toggle. `bind_to_clips` keeps its signature,
so `test_midi_editor_features.gd` and `test_midi_editor_clip_paste.gd` keep working.

## Test plan

- **Godot:** `godot --headless --path Godot -s tests/test_clip_editor_track_list.gd -- --test`
  - `_test_toggle_state_solo`: the `TrackToggleState` rules for solo, revert, moving the solo
    and a plain click ending it, with both kinds tracked independently (REQ-025 to REQ-027).
  - `_test_toggle_state_editable`: hidden implies not editable, and the edit state comes back
    when the track is shown again (REQ-023); also `first_editable` (REQ-031).
  - `_test_list_all_instrument_tracks`: a project with three instrument tracks and one audio
    track, following adds and removes (REQ-010 and REQ-011).
  - `_test_initial_states`: selected versus not selected tracks, and re-entry keeping the
    states (REQ-021).
  - `_test_item_style`: the selected item's border is white and the others' are not
    (REQ-012); toggle icons, solo colour and the dimmed edit toggle (REQ-020, REQ-023,
    REQ-025).
  - `_test_drag_paint`: simulated press on A's eye, motion over B and C, then release
    (REQ-024).
  - `_test_hidden_track_not_drawn`: after hiding B there is no `NoteEditor` for B (REQ-022).
  - `_test_selection_follows_editability`: selecting a hidden track makes it visible and
    editable. Soloing another track's edit toggle moves the selection. With nothing editable
    there is no selected track and a press places no note. Removing the selected track moves
    the selection (REQ-030 to REQ-032).
  - `_test_cross_track_note_press`:
    - pressing B's note selects B and emits `track_mode_track_selected`, and the next
      empty-space press places on B (REQ-033, REQ-034, REQ-036),
    - priority between overlapping notes (REQ-035),
    - right-press erases B's note while A stays selected (REQ-037),
    - a box select covers only A's notes (REQ-038),
    - a non-editable B's note is not hit (REQ-039).
  - `_test_header_clip_name`: the label text, renaming, the label hidden in track mode, and the
    toggle's icon and pressed state (REQ-001 to REQ-003).
- **Regression:** `Godot/tests/run_all.sh`, and `test_midi_editor_features.gd` and
  `test_midi_editor_clip_paste.gd` in particular.
- **Live:** run the engine and `godot --path Godot`, select clips on two tracks and open the
  clip editor. Then check the look of the items, the eye and pencil icons, drag-painting, the
  solo colour, clicking a note on the other track (the list highlight moves and the arranger
  mirrors it if that setting is on), and the clip name in clip mode.

## Risks

| Risk | Mitigation |
|---|---|
| Mouse input goes to the item that received the press, so drag-paint misses the other items | The list follows the drag in `_input` using global Y, and does not rely on `mouse_entered` |
| `get_active_note_editor()` returning null in track mode crashes a caller that assumed non-null | Grep every call site (`ClipEditor`, `MidiEditor`) and add null guards. Most already check |
| Freeing the editor of a hidden track while a gesture is running | `set_track_views` runs from toggle clicks, which happen in the list and never during a note gesture. It skips (and defers) freeing an editor whose `interaction_mode != NONE` |
| An `eye` toggle press also selects the item | The item handles the toggles' `gui_input` and accepts the event, so `pressed` is not emitted |

## Open questions

- [ ] The icons `layers` (for the mode toggle) and `pencil` / `pencil-off` (for editability)
  are my picks. Say if you prefer others, for example `lock` / `lock-open` for editability.
