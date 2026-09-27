# Godot Architecture

## Layers

```
Sonara (autoload)  ── Sonara.editor ──►  Editor (editor/Editor.gd)
                                           │ owns `project`, open/save/load, transport, selection
                     ┌─────────────────────┴─────────────────────┐
              Data layer (data/)                          UI layer (arranger/, mixer/,
   Project, Track, Channel, Clip, ClipInstance,           clip_editor/, devices/, components/)
   DeviceInstance…: state + signals + OSC sync             binds to data objects, listens to their signals
```

## Editor.gd
- Entry point (`editor/Editor.gd` + `.tscn`); wires together loosely-coupled, self-contained systems: switchable primary panels (Arranger, Mixer, Clip Editor) and secondary panels (e.g. `DeviceLane`).
- Owns the current `Project` and its lifecycle: `open_project()`, `save_project()`, `load_project()` (JSON via `Project.to_json()` / `Project.from_json()`).
- Emits app-level signals only: project lifecycle (`project_opened`, `project_activated`, `project_closed`, `project_saved`, `project_modified`), tempo/time signature, transport (`playback_started`, `playback_stopped`, `playhead_moved`), selection (`clips_selected`; `clip_instance_selected` is deprecated) and focus (`channel_focused`, `track_focused`).
- It does **not** relay per-object data changes; those come from the data objects themselves.

## Data model layer
data/ contains self-synchronizing (via OSC) data models (Project, Track, Channel, Clip, ClipInstance, DeviceInstance etc.), each with its own signals and `to_json()`/`from_json()` serialization.
- `Project.gd` emits structural signals (`track_added/removed`, `channel_added/removed`, `clip_added/removed`, `connection_state_changed`), owns the OSC listeners for clip/audiofile events, maps `req_id` ↔ clip IDs, and coordinates retries when waveform cache reads fail.
- Objects emit property signals (e.g. `Track.name_changed`, `Channel.volume_changed`, `Track.clip_instance_added`).
- `Clip.gd` tracks `LoadState` and load progress. Decoded audio metadata and the waveform live in `WaveformPyramid` (`clip.waveform`, also `DeviceInstance.sample_waveform` for Samplers); `Project` feeds both from `/audiofile/decode/ready` and `/audiofile/waveform/level`. Clip keeps forwarding properties (`audio_sample_rate`, `audio_waveform`, …).
- `DeviceRegistry.gd` (owned by `AssetService.device_registry`) holds every `Device` type and owns the `/builtin/*` and `/plugin/*` OSC plus `plugins.json`. Look devices up with `AssetService.get_device(id)`.
- Serialization: list plain fields in a `JSON_FIELDS` const and use `JsonFields.write` / `JsonFields.read`. A missing key keeps the constructor value, so defaults live only in the field initializers. Hand-write arrays, enums-by-name, colors (`Utils.color_to_json`) and nested models.

## Components
in ./components A set of small reusable custom UI controls such as Meters, Sliders, RotaryKnobs etc.

## Clip Editor

- `ClipEditor.gd` listens to `Sonara.editor.clips_selected`, decides between clip-mode and track-mode, and binds the ruler, cursor, and `MidiEditor` to either a single clip or the multi-track selection. Editor ticks are clip-content ticks in clip mode and song ticks in track mode; `_ruler_to_song_ticks` / `_song_to_ruler_ticks` convert through the bound `ClipInstance` (`clip_to_song_ticks`, `song_to_clip_ticks`, which honour `clip_offset`). Its ruler is a `RulerStack`: clicks move the project start position and playhead like the arranger's, Ctrl/Cmd click marks a range start (the paste cursor) and Ctrl/Cmd drag box-selects by time across every pitch. It shades the ruler with track-coloured regions: the instance's played window in clip mode, every clip of the shown tracks in track mode (focused track on top).
- `MidiEditor.gd` owns input and drawing for note editing, renders selection/playhead overlays, and delegates edits to one or more `NoteEditor` instances; in track-mode it builds one editor per track and keeps a `current_track` focus. It also drives the header's held keys (`set_active_notes`): live notes from the active channel's `Channel.live_note` plus, while playing, `NoteContainer.pitches_sounding_at(playhead)`. Alt+right-click previews the same set at the clicked tick. Playhead and overlays sit at `z_index = 2`, above the active editor (`z_index = 1`).
- `note_editor/NoteContainer.gd` renders notes for either a single `ClipInstance` or the set of clips on a track via `bind_to_clips`, staying in sync with `GridHelper`. In track mode a note sits at `ci.content_origin_ticks() + start_tick` (where the instance plays it) and notes outside the played window are hidden, as in the arranger; hidden notes are skipped by hit-testing, box select and Ctrl+A. It never assigns note ids: `Clip.allocate_note_id()` does, from the project counter that `Project` wires into every clip it adds or loads.
- `note_editor/NoteEditor.gd` extends `NoteContainer`, exposes a public API (place, erase, move, resize, duplicate-drag) called from `MidiEditor`, and keeps `NoteSelectionManager` as the data source for selection/clipboard state. Ctrl+drag on a note creates *pending* `VisualNote`s (`is_pending`: translucent, ignored by hit-testing and selection) whose data holds editor ticks; they are written to clips only on release (`finish_duplicate_drag`).
- `note_editor/NoteSelectionManager.gd` manages multi-note selection, clipboard payloads, and box-select ranges; `MidiEditor` now consumes its signals to drive all selection visuals.

## Lane layout and note maps

Spec: `docs/specs/002-note-maps/`.

- `clip_editor/LaneLayout.gd` is the single source of truth for pitch ↔ row ↔ Y, shared exactly the way `GridHelper` is shared horizontally. `MidiEditor` owns one and hands the same instance to `VPiano`, `NoteLanes`, `DrumRowHeader` and every `NoteEditor`; all of them redraw on its `changed` signal. Chromatic mode is the piano roll (128 rows, row 0 at the top holding pitch 127, reproducing the old `(127 - note) * key_height`); folded mode is Drum View, where rows are an arbitrary ascending pitch list and everything else is hidden. Never write the `(127 - note)` formula again — call `pitch_to_y` / `y_to_pitch` / `step_pitch`.
- A **note map** (`data/NoteMap.gd`) is a set of names and colours, at most one per pitch. It is labels only and is never sent to the engine.
- `Channel` carries the assignment: `note_map_mode` (`NONE` / `AUTO` / `NAMED`, default `AUTO`), an embedded `note_map` for the named case, and `drum_view` (-1 unset, 0 piano roll, 1 Drum View). All three persist in `.sonara`; a project without the keys loads as Auto with Drum View unset. `note_map_changed` covers all three, and `sync_to_engine()` is untouched.
- `data/NoteMapResolver.gd` computes the effective map. Auto maps are **derived on demand** from the first Drum Machine on the channel's root chain (names from pad devices, colours from their return channels) rather than stored, which is what makes them follow pad edits for free. `wants_drum_view()` applies the per-channel default.
- `data/NoteMapWatcher.gd` (modelled on `devices/PadLaneWatcher.gd`) re-binds and emits one coalesced `changed` per frame when anything the derived map depends on moves. `MidiEditor` caches the resolved map and only re-resolves on that signal — never per frame.
- `data/NoteMapLibrary.gd` is the user's library of named maps, one JSON file per map under `~/.config/sonara/note_maps/`, with a `dir_override` for tests like `ai/chat/ConversationStore.gd`. Assigning a library map stores a **copy** on the channel, so project and library never write through to each other.
- `clip_editor/DrumRows.gd` computes Drum View's rows: mapped pitches ∪ pitches the bound clips use, so no note is ever hidden. `MidiEditor.rebuild_rows()` defers while an interaction is running so rows can't reshuffle mid-drag.
- `clip_editor/DrumRowHeader.gd` takes `VPiano`'s slot in `MidiEditor/HBox` and emits the same `key_pressed` / `key_released`, so audition and hover work without `MidiEditor` knowing which header is showing.

## Timeline & Grid

- `components/GridHelper.gd` centralizes tempo/PPQ/zoom/scroll state and exposes ticks↔pixels conversions, snapping, and grid-line generation consumed by Timeline, Ruler, and Midi editors.
- `components/BaseRuler.gd` holds everything the ruler rows share: background, context `regions`, the selection band, the start arrow, click-drag scrubbing (`start_position_requested`) and the Ctrl/Cmd range gestures (`selection_start_requested`, `box_select_started`). `Ruler.gd` (bars/beats) and `RealTimeRuler.gd` (clock) only draw lines and pick their click snapping (`_snapped_ticks_from_local`). Lines are drawn as whole-pixel rects at rounded x, exactly like `GridRenderer`, so ruler and grid land on the same pixel columns. `offset_x` shifts drawing only so rulers line up with gutters like the piano keyboard; ClipEditor sets it every frame from the note area's position.
- `components/RulerStack.gd` is the clock row over the beat row as one control, used by the clip editor. The arranger keeps its own rows because its marker lane sits between them, but they are the same components with the same gestures.
- Reusable value controls (knobs, sliders, meters, envelope) and their shared helpers (`FineDrag`, `ValueTooltip`, `LabelOverlay`) follow `godot-ui-components.md`.
- `Track.height` is the single arranger row height: `TrackList` headers and `Timeline` lanes/clips both size from it. A header's controls can force it taller than the user set (a narrow TracksPanel makes `CollapsingFlowContainer` wrap), so `TrackItem._sync_layout_height()` pushes the realized height through `Track.height` and restores the user's height when wrapping stops. Never size only one column from a layout-derived height.

## Utilities

- `Utils` class is general-purpose utility functions.
- `Midi` class is a static class with midi, note and frequency conversion functions.
- `Sonara` singleton provides access to the Editor instance via `Sonara.editor`.
- Share `GridHelper` instances across views (ClipEditor, Ruler, Timeline) so zoom/scroll changes propagate via the `changed` signal without manual listeners per component.

## CLI Automation

- Run non-interactive maintenance tasks through the Godot CLI so they share the same project state as the editor; invoke commands from the repo root and pass `--path Godot` to target the UI workspace.
- Prefer headless mode for CI, cache warmers, and project scripts: `godot --headless --path Godot -s path/to/script.gd`, where the script path is relative to the `Godot/` project root (no `res://` prefix needed when supplying `--path`).

## OSC

AudioEngineOSC.gd is a Low-level OSC transport class with `send` and `listen` interface.

## Lifecycle and OSC syncing

1. Editor.gd opens/creates a `Project` and emits `project_opened` / `project_activated`.
2. Project establishes connection to audio engine via AudioEngineOSC.
3. Container views (e.g. `TrackList`) listen to `Sonara.editor.project_activated`/`project_closed`, then connect to the project's structural signals (`track_added`, …) and instantiate one item per object.
4. Items bind to their object (`TrackItem.bind_to_track()`, `MixerChannel.bind_to_channel()`) and connect to its property signals to refresh UI. See "Signal lifecycle" below for the unbind rules.
5. Godot > Engine: UI callbacks call `set_[prop]` setters on data objects, which update state, send OSC, and emit the signal — UI never mutates fields or sends OSC directly.

## Undo / Redo

- Document mutations that should be undoable go through `Sonara.editor.history` via `HistoryUtil.execute()` / `HistoryUtil.record()` (or `Editor.execute_command` / `record_command`).
- Data-object setters (`Channel.set_volume`, `Clip.add_midi_note`, …) must **not** push history themselves — they stay “apply + OSC + signal” only.
- Use `execute` when the command should call `do()`; use `record` when the UI already applied the change live (e.g. fader/clip/note drag) and commits one command on gesture end (or via mergeable `PropertyCommand`s during the drag).
- For a batch, collect `Array[Command]` and call `HistoryUtil.execute_many(label, cmds)` / `record_many` (one command as itself, several as a `MacroCommand`, none as a no-op). Don't use `begin_macro`/`end_macro` for synchronous UI actions.
- Shared undoable actions: `ClipActions.create_clip()` (timeline double-click, note editor, AI), `DeviceDropUtil` for every device drop.
- Clear history on new/open/close project; call `history.mark_save_point()` on save so undo-to-save-point clears the dirty flag.

## UI Binding Practices

- When refreshing a control from a data signal, use `set_pressed_no_signal()`, `set_value_no_signal()` etc. so the update doesn't re-trigger the setter and loop.
- Many UI controls are `@tool` scripts; guard runtime-only work (autoload access, data/editor signal connections) with `Engine.is_editor_hint()` so scenes still load in the Godot editor.
- Handle objects removed from the project gracefully (check for `null`/freed instances before use).

## Signal lifecycle (bind / unbind)

Views that connect to data objects (a project, track, channel, device) follow one shape:

```gdscript
var track: Track = null

func bind_to_track(t: Track) -> void:
	_unbind()                      # always first: rebinding must not stack connections
	track = t
	if track:
		track.name_changed.connect(_on_track_name_changed)

## Disconnect everything bind_to_track connected. Idempotent.
func _unbind() -> void:
	if track and track.name_changed.is_connected(_on_track_name_changed):
		track.name_changed.disconnect(_on_track_name_changed)
	track = null

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unbind()
```

- `bind_to_x(obj)` starts with `_unbind()` and then stores `obj`. `_unbind()` disconnects with `is_connected` guards, releases non-signal resources (engine data subscriptions, popups), and nulls the reference.
- Call `_unbind()` from `NOTIFICATION_PREDELETE`, **not** `_exit_tree()`. `DockHost` reparents docks, which fires `_exit_tree()` on every descendant, and `is_queued_for_deletion()` is only true on the node `queue_free()` was called on, not its children. Godot does drop connections that target a freed object, so the predelete call matters for rebinding, for subscriptions and popups, and for callbacks that run between `queue_free()` and the actual free.
- Containers that connect to each child's data object (e.g. `order_changed` per track) disconnect those in their `_clear_all_*` methods too, not only in the per-item remove handler. Otherwise reopening a project re-connects and errors, and closed-project objects keep calling the container.
- Never pass `callable.bind(x)` / `bindv` to `disconnect()` or `is_connected()` and rely on it matching. Keep the bound callable in a variable or dictionary (see `Mixer._channel_hierarchy_cbs`), or have the signal carry the object.
