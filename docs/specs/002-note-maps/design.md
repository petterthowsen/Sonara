# Note Maps and Drum View — Design

Implements [requirements.md](./requirements.md).

## Context

Clip editor, as it is today:

- `Godot/clip_editor/ClipEditor.tscn` — `BottomPanel/Toolbar` (an `HBoxContainer`) currently holds
  `Quantize` and `AuditionToggle`. The editor body is
  `HSplit/MainPanel/VBox/MidiEditor/HBox`, whose children are `VPiano` and `NoteArea`
  (`NoteLanes`, `GridRenderer`, `HScroll/NoteEditor`, `Playhead`, `Overlays`).
- `Godot/clip_editor/MidiEditor.gd` — owns `note_height` (`MidiEditor.gd:112`), pushes it to
  `v_piano.key_height`, `note_lanes.key_height` and each `NoteEditor.note_height`; owns vertical
  zoom (`_zoom_vertical`), `scroll_to_note`, mouse routing, and note preview through
  `_start_preview_note` / `_stop_preview_note` / `_on_piano_key_pressed`.
- `Godot/clip_editor/NoteLanes.gd` — `note_to_y`, `note_to_y_bottom`, `_draw_lanes`, per-pitch
  white/black lane colors.
- `Godot/components/VPiano.gd` — `note_to_y`, `get_note_rect`, `get_note_at_position`,
  `note_has_label`, `_draw_key`, and the `key_pressed(note, velocity)` / `key_released(note)`
  signals `MidiEditor` connects to.
- `Godot/clip_editor/note_editor/NoteContainer.gd` — `note_to_y` (`:530`), `y_to_note` (`:524`),
  `_get_minimum_size` (`:218`), `_update_single_note_position` (`:239`), `get_snap_interval`
  (`:547`).
- `Godot/clip_editor/note_editor/NoteEditor.gd` — extends `NoteContainer`; `default_note_length_ticks`
  (`:50`), `_place_note_at_position` (`:229`), drag pitch math at `:465` and `:902`.
- `Godot/clip_editor/VisualNote.gd` — `prepare_piano_roll_layout()`, `set_color`, `_update_visual`
  (velocity brightness), `update_label_visibility`, `_is_over_resize_handle`.
- `Godot/components/GridHelper.gd` — the precedent for a shared, signal-emitting helper object that
  several clip-editor views hold a reference to.

Model and infrastructure:

- `Godot/data/Channel.gd` — `JSON_FIELDS` (`:865`), `to_json` / `from_json`, `set_color`,
  `color_changed`, `device_added` / `device_removed` / `device_moved`, `aux_pad_note` (`:91`).
- `Godot/data/AuxReturnSync.gd` — `is_drum_machine`, `get_return_channel(project, device, index)`,
  `get_pad_drum`, `get_pad_device`.
- `Godot/data/DeviceInstance.gd` — `slot_note`, `children`, `get_display_name()`, `child_added` /
  `child_removed` / `child_moved`, `name_changed`.
- `Godot/devices/DeviceDropUtil.gd` — `DRUM_MACHINE_ID` (`:11`).
- `Godot/devices/PadLaneWatcher.gd` — the precedent for a per-frame-coalesced watcher over a
  channel, its parent and a Drum Machine's children.
- `Godot/ai/tools/AiTool.gd` — `drum_names_for_track` (`:508`), the existing pad-name lookup used by
  the assistant's clip text, and `_generic_drum_label` (`:536`).
- `Godot/ai/clip_text/ClipTextGrid.gd` — consumes `drum_names` as `{pitch: String}`.
- `Godot/history/HistoryUtil.gd` — `execute`, `execute_many`, `execute_property`;
  `Godot/history/commands/PropertyCommand.gd` for undoable setter calls.
- `Godot/Sonara.gd:29` — `~/.config/sonara` config dir; `Godot/ai/chat/ConversationStore.gd` is the
  precedent for a file-backed store with a test directory override and `Utils.is_test_mode()`.
- `Godot/settings/SettingsDialog.gd` — precedent for a `Window`-based dialog.
- `Godot/arranger/tracklist/TrackItemContextMenu.gd:18` — the ColorPickerButton-opens-a-nested-Window
  caveat and how existing popups survive it.

## Approach

Three separable pieces, in this order.

**1. `LaneLayout` — one source of truth for pitch ↔ row ↔ Y.** Today `(127 - note) * height` is
written out in `NoteLanes`, `VPiano`, `NoteContainer` and twice in `NoteEditor`, and the inverse in
`NoteContainer.y_to_note` and `MidiEditor:867`. Drum View needs a layout where rows are an arbitrary
list of pitches, so every one of those sites must ask a shared object instead. `LaneLayout` is a
`RefCounted` with a `changed` signal, held by `MidiEditor` and handed to its children exactly like
`GridHelper` is. Phase 1 introduces it in chromatic mode with no visible change, which keeps the
risky refactor separate from the new feature. The rejected alternative — giving Drum View its own
parallel widgets — would fork note dragging, selection and the playhead, which is where the real
complexity lives.

**2. Note maps on the channel.** `NoteMap` is a plain data object (entries `{pitch: {name, color}}`
plus `map_name`, `category`, `author`). `Channel` gains an assignment (`NONE` / `AUTO` / `NAMED`),
an embedded `NoteMap` for the named case, and a tri-state Drum View preference. Nothing is sent to
the engine — maps are labels only, so `sync_to_engine()` is untouched. `NoteMapResolver` computes
the effective map, deriving the Auto map from the Drum Machine on demand rather than storing it,
which is what makes REQ-004 fall out for free. `NoteMapWatcher` (modeled on `PadLaneWatcher`) tells
the clip editor when a derived map may have changed, coalesced to one signal per frame. The library
is a directory of JSON files under `~/.config/sonara/note_maps/`, loaded and saved through
`NoteMapLibrary`, with a test override like `ConversationStore`.

**3. Drum View.** A second `LaneLayout` mode whose rows come from `DrumRows.rows_for(map, clips)`,
a `DrumRowHeader` control that takes `VPiano`'s slot in the `HBox` and emits the same
`key_pressed` / `key_released` signals so `MidiEditor` does not care which header is showing, and a
hit display mode on `VisualNote`. The bottom toolbar gains the mode switch and the map controls in
front of `Quantize`.

## Thread and ownership

No engine or audio-thread involvement — this is Godot-side UI and model state only, all on the main
thread. The table is included because the template asks for it.

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `Channel.note_map_mode`, `Channel.note_map`, `Channel.drum_view` | Godot main thread | clip editor and note map editor, via `Channel` setters and signals | n/a — never sent to the engine |
| Auto map entries | not stored; derived on demand by `NoteMapResolver` from `DeviceInstance` / `Channel` state | clip editor, via `NoteMapWatcher.changed` | n/a |
| Note map library files | Godot main thread, `NoteMapLibrary` | note map editor dialogs | n/a — file I/O never happens on a clip-editor frame path except on explicit save/load |

## Data and protocol changes

**OSC:** none. Auditioning reuses `MidiEditor._start_preview_note` / `_stop_preview_note`, which
already go through the existing preview path.

**Godot model (`Channel.gd`):**

- New fields: `note_map_mode: NoteMapMode` (enum `NONE`, `AUTO`, `NAMED`; default `AUTO`),
  `note_map: NoteMap` (null unless `NAMED`), `drum_view: int` (-1 unset, 0 off, 1 on; default -1).
- New signal: `note_map_changed`. Setters `set_note_map_mode`, `set_note_map`, `set_drum_view` emit
  it (`set_drum_view` emits nothing else). No `sync_to_engine()` wiring — none of this reaches the
  engine.
- `to_json` writes `note_map_mode` as a key name (like `pan_mode`) and `note_map` as a nested
  object; `drum_view` joins `JSON_FIELDS`. `from_json` reads `note_map_mode` with
  `NoteMapMode.get(str(data.get(...)), AUTO)`, so a missing key lands on `AUTO` (REQ-012).

**Library file format** (`~/.config/sonara/note_maps/<slug>.json`), one file per named map:

```json
{ "name": "GM Drums", "category": "Drums", "author": "Peter",
  "entries": { "36": {"name": "Kick", "color": "#cc4444"} } }
```

The same `NoteMap.to_json()` shape is embedded in `.sonara` channels, so one serializer covers both.

**Settings:** the view mode and map assignment live in the project, not in `Settings.gd`. No new
user setting is registered. (`ClipEditor.gd` keeps using `Sonara.get_config` for the audition
toggle, which is internal UI state.)

## File-by-file change list

| File | Change |
|---|---|
| `Godot/clip_editor/LaneLayout.gd` | **New.** `class_name LaneLayout extends RefCounted`. `signal changed`; `row_height`; `chromatic()` / `set_rows(PackedInt32Array)`; `is_folded()`, `row_count()`, `pitch_at_row(row)`, `row_of_pitch(pitch)` (-1 when hidden), `pitch_to_y(pitch)`, `pitch_to_y_center`, `y_to_pitch(y)`, `y_to_row(y)`, `total_height()`, `step_pitch(pitch, delta)` (row-wise, REQ-020) |
| `Godot/clip_editor/DrumRows.gd` | **New.** `static func rows_for(map: NoteMap, clips: Array[ClipInstance]) -> PackedInt32Array` — mapped pitches ∪ pitches used by the clips, ascending (REQ-016, REQ-024) |
| `Godot/clip_editor/DrumRowHeader.gd` | **New.** `Control` drawing one labeled, colored row per `LaneLayout` row; unmapped rows use `Midi.midi_to_note_name` and a muted style (REQ-017, REQ-018). Emits `key_pressed(note, velocity)` / `key_released(note)`, matching `VPiano` |
| `Godot/clip_editor/MidiEditor.gd` | Owns a `LaneLayout`; `note_height` setter drives `layout.row_height` instead of three separate `key_height` fields; `_zoom_vertical`, `scroll_to_note` and `_update_hovered_key` (`:867`) go through the layout; new `drum_view` property that swaps `VPiano` / `DrumRowHeader` visibility, rebuilds rows, and defers rebuilds while `active_editor.interaction_mode != NONE` (REQ-021); binds `NoteMapWatcher`; connects the header's key signals the same way `VPiano`'s are connected today |
| `Godot/clip_editor/NoteLanes.gd` | Draws from `LaneLayout` rows instead of `for note in 128`; tints mapped lanes with the entry color (REQ-014); in folded mode draws row separators instead of the E/F, B/C semitone borders |
| `Godot/components/VPiano.gd` | `note_to_y` / `get_note_rect` / `get_note_at_position` / `_draw` use the shared `LaneLayout`; `_draw_key` draws a map entry's name and color tint when the note is mapped (REQ-013) |
| `Godot/clip_editor/note_editor/NoteContainer.gd` | `note_to_y` (`:530`), `y_to_note` (`:524`), `_get_minimum_size` (`:218`) and `_update_single_note_position` (`:239`) use the layout; hidden pitches (`row_of_pitch == -1`) hide their `VisualNote` |
| `Godot/clip_editor/note_editor/NoteEditor.gd` | Pitch math at `:465` and `:902` uses `layout.step_pitch` / `y_to_pitch`; `_place_note_at_position` (`:229`) uses `get_snap_interval()` as the length in Drum View instead of `default_note_length_ticks` (REQ-019); resize interaction is disabled while folded |
| `Godot/clip_editor/VisualNote.gd` | New `prepare_drum_layout()` beside `prepare_piano_roll_layout()` (`:31`): hit marker sized from row height, velocity shading kept from `_update_visual`, label hidden, `_is_over_resize_handle` returns false (REQ-022). `NoteContainer.drum_marker_size()` caps the marker's **width** at one grid step so a tall row can't make neighbouring hits overlap into what looks like one legato note |
| `Godot/clip_editor/ClipEditor.tscn` | `BottomPanel/Toolbar` gains, before `Quantize`: `ModeSwitch` (Button), `NoteMapButton` (Button + `PopupMenu`), `NoteMapLoad`, `NoteMapEdit`, `NoteMapSave` |
| `Godot/clip_editor/ClipEditor.gd` | Wires those controls: the mode switch drives `midi_editor.drum_view` and `channel.set_drum_view`; `NoteMapButton` opens its `PopupMenu` *upwards* (position computed from the button's global rect minus the popup height, like the existing context menus) listing None / Auto / library maps; Load, Edit and Save open the three dialogs below. A successful save also assigns the saved map to the channel (REQ-027) |
| `Godot/data/NoteMap.gd` | **New.** `class_name NoteMap extends RefCounted`. `map_name`, `category`, `author`, `entries: Dictionary` (pitch → `{name: String, color: Color}`); `get_name(pitch)`, `get_color(pitch)`, `set_entry`, `erase_entry`, `is_empty()`, `pitches()` (sorted), `duplicate_map()`, `to_json()` / `static from_json()` |
| `Godot/data/NoteMapLibrary.gd` | **New.** `static dir_override` for tests (as in `ConversationStore`); `list() -> Array[NoteMap]` (metadata only), `load_map(name)`, `save_map(map, overwrite) -> bool`, `exists(name)`, `path_for(name)`; `~/.config/sonara/note_maps/` from `Sonara.get_config_dir()` |
| `Godot/data/NoteMapResolver.gd` | **New.** `effective_map(channel) -> NoteMap`, `auto_map(channel) -> NoteMap` (first `DeviceDropUtil.DRUM_MACHINE_ID` device on the root chain; one entry per child with `slot_note >= 0`, name from `get_display_name()`, color from `AuxReturnSync.get_return_channel(...).color`), `has_auto_source(channel) -> bool`, `for_track(project, track) -> NoteMap` |
| `Godot/data/NoteMapWatcher.gd` | **New.** Modeled on `PadLaneWatcher`: binds `channel.note_map_changed`, `device_added` / `device_removed` / `device_moved`, the Drum Machine's `child_added` / `child_removed` / `child_moved`, each pad child's `name_changed`, and each return channel's `color_changed`; emits a single coalesced `changed` per frame (REQ-004) |
| `Godot/data/Channel.gd` | Fields, signal, setters and JSON as described above |
| `Godot/clip_editor/note_map/NoteMapEditorDialog.gd` | **New.** `Window` (like `SettingsDialog`), built in code rather than from a `.tscn`, with a scrolled `VPiano` (taller keys and the clip editor's inverted palette, so naturals are dark), a row of `LineEdit` (name) + reset `X` + `ColorPickerButton`, and Save / Save as… buttons. A plain `LineEdit`, not `SmartLineEdit`: the latter renders as a bare centred label until double-clicked, which reads as static text in a dialog. Clicking a key selects and auditions it (REQ-006–REQ-008). All editing controls disabled for Auto maps (REQ-005). Edits go through `HistoryUtil.execute_property` on `Channel.set_note_map` so they undo as one step each (REQ-026) |
| `Godot/clip_editor/note_map/NoteMapBrowserDialog.gd` / `.tscn` | **New.** `Window` listing library maps grouped by category, with author shown; confirming assigns a copy to the channel (REQ-010) |
| `Godot/clip_editor/note_map/NoteMapSaveDialog.gd` / `.tscn` | **New.** `Window` with name, category and author fields; confirms before overwriting an existing name (REQ-009, REQ-027) |
| `Godot/ai/tools/AiTool.gd` | `drum_names_for_track` (`:508`) delegates to `NoteMapResolver.for_track`, keeping the existing de-duplication and `_generic_drum_label` fallback so clip text stays stable (REQ-025) |
| `Godot/tests/test_note_map.gd` | **New.** Model, library, resolver and persistence tests |
| `Godot/tests/test_drum_rows.gd` | **New.** `LaneLayout` and `DrumRows` tests |
| `docs/specs/002-note-maps/tasks.md` | Written at the next gate |
| `TODO.md` | Backlog entry for the feature |
| `docs/subsystems/godot-architecture.md` | Short section on `LaneLayout` and note maps once the code lands |

## Migration and compatibility

- `.sonara`: channels written by this version carry `note_map_mode`, an optional `note_map` object
  and `drum_view`. Older files have none, so `note_map_mode` falls back to `AUTO`, `note_map` stays
  null and `drum_view` stays -1 (unset → REQ-028's default). No migration pass is needed, and older
  Sonara versions ignore the extra keys when loading a newer project.
- `config.json`: untouched. The library is a new directory beside it; a missing directory means an
  empty library, created on first save.
- A named map embedded in a project is never rewritten from the library (REQ-026), so opening an old
  project after editing the library shows the map as it was saved.

## Test plan

- **Godot:** `godot --headless --path Godot -s tests/test_note_map.gd -- --test` — assignment
  default and round trip (REQ-001), Auto map from a Drum Machine including pad colors and empty pads
  (REQ-002), empty Auto map (REQ-003), library save/load round trip with category and author
  (REQ-009, REQ-010), embedded copy survives a deleted library entry (REQ-011), missing keys load as
  Auto (REQ-012), channel edits don't touch the library (REQ-026), Save as from an Auto map
  (REQ-027), Drum View default per channel type and its round trip (REQ-028).
- **Godot:** `godot --headless --path Godot -s tests/test_drum_rows.gd -- --test` — chromatic
  `LaneLayout` matches today's `(127 - note) * height` for every pitch (the phase-1 safety net), row
  sets from map ∪ used (REQ-016), multi-track union (REQ-024), `step_pitch` across rows (REQ-020).
- **Godot:** `godot --headless --path Godot -s ai/tests/test_clip_text.gd -- --test` — extended for
  a named map with no Drum Machine (REQ-025).
- **All:** `Godot/tests/run_all.sh`.
- **Live** (engine running, `godot --path Godot`) — everything visual: labeled keys and tinted lanes
  (REQ-013, REQ-014), the editor dialog's select / rename / recolor / reset / audition
  (REQ-006–REQ-008), read-only Auto maps (REQ-005), live pad renames (REQ-004), the toolbar's
  upward-opening dropdown, mode switching with selection kept (REQ-015), unmapped rows (REQ-017),
  row-label audition (REQ-018), one-grid-step hits (REQ-019), rows frozen during a drag (REQ-021),
  lengths preserved (REQ-022), the empty-view hint (REQ-023).

## Risks

| Risk | Mitigation |
|---|---|
| The `LaneLayout` refactor silently shifts the piano roll by a pixel or breaks drag math | Phase 1 changes no behavior, and `test_drum_rows.gd` asserts the chromatic layout equals the old formula for all 128 pitches before Drum View is built |
| Notes on hidden pitches get edited invisibly | Rows include every used pitch (REQ-016), so no note is ever hidden in Drum View; in the piano roll nothing is hidden at all |
| Rows reshuffling mid-drag makes notes jump | `MidiEditor` defers row rebuilds while `interaction_mode != NONE` (REQ-021), rebuilding on release |
| `ColorPickerButton` opens a nested `Window` that closes the dialog | Follow `TrackItemContextMenu.gd:18` and `MarkerContextMenu.gd:23`, which already keep their popup alive and connect the nested picker |
| `NoteMapWatcher` leaks connections when pads change | `PadLaneWatcher`'s `_disconnect_all` pattern, rebinding on every `changed`; `TODO.md:131` records the same bug class in `DrumMachineDefaultView` |
| Per-frame cost of resolving the Auto map | Resolve once per `changed` signal, cache the `NoteMap` on the editor, and coalesce watcher signals to one per frame |
| `NoteLanes.gd` and `VPiano.gd` are `@tool` scripts, so a null layout runs in the editor | Both keep a default `LaneLayout.chromatic()` instance, exactly as `NoteLanes` already does with `GridHelper.new()` |

## Open questions

None. Requirements' open questions were resolved before this document.
