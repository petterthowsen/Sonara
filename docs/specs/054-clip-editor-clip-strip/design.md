# Clip Editor Clip Strip — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/clip_editor/ClipEditor.gd`: binds clip mode (`_bind_clip_mode`, `bound_clip_instance`) and track mode (`_bind_track_mode`, `midi_editor.focus_track`). It shades the ruler in `_rebuild_ruler_regions`, driven by `_ruler_context_dirty` / `_mark_ruler_context_dirty` and the `_watch_ruler` / `_unwatch_ruler_context` signal bookkeeping. `_process_body` sets `ruler.offset_x` every frame from `midi_editor.note_area`. Editor ticks are clip-content ticks in clip mode and song ticks in track mode (`_ruler_to_song_ticks`). `_editor` caches `Sonara.editor`.
- `Godot/clip_editor/ClipEditor.tscn`: `HSplit/MainPanel/VBox/PanelContainer/VBox/Ruler` (a `RulerStack`), followed by `HSplit/MainPanel/VBox/EditorSplit`.
- `Godot/components/BaseRuler.gd`: `regions`, `set_regions`, `_draw_regions` and the `_tick_to_local_x` formula (`grid_helper.ticks_to_pixels(t) - grid_helper.scroll_position + offset_x`). `Godot/components/RulerStack.gd` `set_regions` forwards to every row. ClipEditor is the only caller.
- `Godot/clip_editor/MidiEditor.gd`: `focus_track` (setter emits `focus_track_changed`), `_sync_track_views` and `_bind_editor_to_track`, which hands the focus `NoteEditor` a copy of `track.clip_instances` through `NoteContainer.bind_to_clips`. `NoteContainer` follows `instance_modified` of the instances it holds, but not `Track.clip_instance_added` / `clip_instance_removed`. `ContextNotesLayer` already follows those for the non-focus tracks.
- `Godot/arranger/timeline/clip/TimelineClip.gd`: arranger clip. It holds the edge-resize rules (`_begin_resize`, `_snapped_resize_delta`, `_resize_by`, `_find_nearest_clip_left/right`, `_add_padding_to_clip`, `_extend_clip_to`, `_finish_resize` → one `ClipInstanceTransformCommand` per clip via `HistoryUtil.record_many("Resize Clips")`), the loop-divider drag (`_drag_loop_point`, `_finish_loop_drag`, "Move Loop Point"), and the header drawing (`_draw_body`, `_draw_mode_badge`, `header_style`, `header_height`, `name_settings`).
- `Godot/arranger/timeline/Timeline.gd`: owns the single `clip_ctx_menu` (`ClipContextMenu`) and its handlers (`_on_clip_split_requested` reads `clip_ctx_menu.split_tick`, `_on_clip_merge_requested`, `_on_clip_cut_requested` / `_on_clip_copy_requested` select the instances in the arranger and call `cut/copy_selection_to_clipboard`, `_on_clip_delete_requested`, `_on_clip_make_unique_requested`, `make_unique_per_track`). The menu opens from `_on_clip_context_menu_requested` → `clip_ctx_menu.popup_docked`. The move clamp is `_clamp_instances_tick_delta`, and a finished move records "Move Clip" `ClipInstanceTransformCommand`s under `HistoryUtil.record_many("Move Clips")` in `_finish_drag`.
- `Godot/arranger/timeline/TimelineTrack.gd` `_on_double_click`: snapped tick, `grid_helper.get_ticks_per_bar_at`, shortened to the next clip, `ClipActions.create_clip(project, track, tick, length, "", clip_type)`.
- `Godot/arranger/timeline/ClipContextMenu.gd` / `.tscn`: `bind_to_instances`, `split_tick`, `popup_docked(clip_rect, bounds, from_x)`. Icons exist for Loop, Cut, Copy, Split and Delete only.
- `Godot/data/Project.gd` `get_clip_instance_count(clip_id)`: walks every track's instances on every call. `Godot/data/Track.gd` `add_clip_instance` emits `clip_instance_added`. `Godot/data/ClipInstance.gd` `set_clip` emits `clip_changed` (Make Unique).
- `Godot/core/theme/ThemeBuilder.gd` `_components` / `box(p, bg, …)` (radius `p.radius` from `appearance/theme/corner_radius`), with `UiTheme.theme_applied`.
- `Godot/assets/icons/fetch_lucide_icons.sh`: the icon fetcher. `link.svg` already exists.

## Approach

**A new `ClipStrip` control, with the edit rules pulled out of `TimelineClip` into one node-free helper.** `ClipStrip` is a single `Control` that draws its bars in `_draw`. It handles hit-testing and gestures itself, the way `BaseRuler` does, rather than holding one child node per clip. The strip shows at most one track's clips, so per-clip nodes buy nothing. It lives under `clip_editor/`, gets its ticks→x mapping from the shared `GridHelper` plus an `offset_x` that `ClipEditor` sets every frame next to the ruler's, and runs in one of two modes, set by `ClipEditor`: `bind_clip(instance)` (content ticks, right end only) or `bind_track(track)` (song ticks, full editing).

The arranger's edge-resize, padding, extend and loop-length rules move into `Godot/history/ClipEdgeEdits.gd`. That is a static `RefCounted` working on a `ClipInstance` plus a start snapshot, next to `ClipActions` / `ClipRangeActions`. `TimelineClip` delegates to it and `ClipStrip` calls it, so a trim from the strip behaves exactly like one in the arranger. The single-track move clamp moves there too, and `Timeline._clamp_instances_tick_delta` calls it once per moving instance after it has picked the track to check.

The rejected alternative was to embed `TimelineClip` instances in the strip. They depend on `timeline` (`pixels_to_ticks`, `clip_selection_manager`, `get_snap_interval`, `grid_helper`), carry the note/waveform renderer and loop overlays, and hand moves over to `Timeline`. Faking a `Timeline` for them would couple the clip editor to arranger internals and draw far more than a 24 px bar needs. The other rejected alternative was copying the resize code into the strip, which is how two copies of the rules drift apart.

**The context menu stays the arranger's single instance.** `Timeline` gets a public `open_clip_menu(instances, split_tick, anchor_rect, from_x, keep_selection)`, and `_on_clip_context_menu_requested` becomes a thin caller of it. When the menu is opened from the strip, `keep_selection` is true. Cut and Copy then build the clipboard from the menu's instances without changing the arranger's selection, and Merge doesn't select its result in the arranger. A changed arranger selection emits `Editor.clips_selected`, and `ClipEditor._on_editor_clips_selected` would rebind (and could flip track mode to clip mode) in the middle of the user's work. The rejected alternative, a second `ClipContextMenu` in the clip editor, would need every handler duplicated or moved, Split depends on the menu's own `split_tick`, and the clipboard lives on `Timeline` anyway.

**Automation follows a strip move (REQ-028).** The arranger already keeps this rule node-free in `AutomationActions.shift_track_automation(moves, delta, "Move Automation")`. It takes `{track, start, end}` ranges from before the move, changes the lanes live and returns the commands. On release, `ClipStrip` builds those ranges from its drag-start snapshots, checks `project.get_arranger_view("automation_follows_clips")` (the check `Timeline._automation_follows_enabled` makes) and adds the commands to its "Move Clips" `record_many`. The future automation lanes in the MIDI editor will read the same lanes, so nothing here has to change for them.

**Shared state is cached on `Project`.** `Project.is_clip_shared(clip_id)` reads `_instance_counts` (clip_id → count). The cache is rebuilt lazily when `_instance_counts_dirty` is set. `Track.add_clip_instance` / `remove_clip_instance` and `ClipInstance.set_clip` mark it dirty through `get_project_ref()`, and so does project load. Marking it dirty also queues one deferred `instance_counts_changed` emission per frame, so `TimelineClip` and `ClipStrip` redraw once after a batch edit. `get_clip_instance_count` keeps its signature and reads the cache.

## Thread and ownership

All state is on the Godot main thread. The engine is not touched.

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `ClipStrip` bars / selection / gesture | Godot main | `ClipEditor` | n/a |
| `Project._instance_counts` cache | Godot main | `Track`, `ClipInstance`, views | n/a |

## Data and protocol changes

- **OSC:** none. Every edit goes through the existing `ClipInstance` setters (`set_position`, `set_duration`, `set_clip_offset`, `set_loop`) and `Clip.set_content_length`, which already sync.
- **Undo:** the same commands and names as the arranger: "Move Clips" (`ClipInstanceTransformCommand` "Move Clip"), "Resize Clips", "Move Loop Point", and creation through `ClipActions.create_clip`.
- **Signal:** `Project.instance_counts_changed`.
- **Theme:** a `ClipStrip` theme type: stylebox `bar` (`box(p, Color.WHITE)`, so it carries `p.radius`), constant `height` (24), colors `name` and `link_icon`.
- **Persisted:** nothing.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/history/ClipEdgeEdits.gd` (new) | `class_name ClipEdgeEdits`. `snapshot(inst) -> Dictionary` (start, duration, offset, loop state, content length). `resize_left(inst, snap, delta, min_duration) -> int` (returns the padding added). `resize_right(inst, snap, delta, min_duration)`. `neighbour_left/right(inst, ref)`. `pad_clip(inst, ticks)` (from `_add_padding_to_clip`). `extend_clip_to(inst, end, start_length)`. `set_loop_length(inst, new_length, start_content)` (from `_drag_loop_point`, pass 1). `clamp_move_on_track(inst_start, duration, track, moving, delta) -> int`. `transform_command(name, inst, snap) -> Command` (null when nothing changed). |
| `Godot/arranger/timeline/clip/TimelineClip.gd` | Delegate `_resize_by`, `_find_nearest_clip_left/right`, `_add_padding_to_clip`, `_extend_clip_to`, `_drag_loop_point` length rule and `_finish_resize` / `_finish_loop_drag` command building to `ClipEdgeEdits`. Draw the link icon in the header band, left of the mode badge, when `is_shared()`. Add `is_shared() -> bool` and redraw on `Project.instance_counts_changed`. |
| `Godot/arranger/timeline/Timeline.gd` | `_clamp_instances_tick_delta` calls `ClipEdgeEdits.clamp_move_on_track` per instance. New `open_clip_menu(instances, split_tick, anchor_rect, from_x, keep_selection := false)`, with `_on_clip_context_menu_requested` routed through it. With `keep_selection`, Cut/Copy use new `copy_instances_to_clipboard(instances)` / `cut_instances_to_clipboard(instances)` (`ClipSelection.set_from`, then the existing range and automation snapshot code), and Merge skips `select_instances`. The existing `*_selection_to_clipboard` call the new ones with the selection's instances. |
| `Godot/arranger/timeline/ClipContextMenu.tscn` | Icons on Merge, OctaveDown, OctaveUp, ScaleHalf, ScaleDouble, MakeLegato, MergeSame, SplitToTracks, MakeUnique, MakeUniquePerTrack and MuteToggle (`expand_icon = true`, like the others). |
| `Godot/assets/icons/fetch_lucide_icons.sh` + new `.svg` | Add a "clip context menu" group: `unlink` (Make Unique), `unlink-2` (Make Unique Per Track), `combine` (Merge), `fold-horizontal` / `unfold-horizontal` (Scale ½ / ×2), `arrow-right-to-line` (Make Legato), `merge` (Merge Same), `split` (Split to Tracks). Octave down/up use the existing `chevrons-down` / `chevrons-up`, and Mute uses `volume-x`. A name lucide doesn't have is swapped for the nearest one, and the swap is recorded in tasks.md. |
| `Godot/data/Project.gd` | `_instance_counts`, `_instance_counts_dirty`, `instance_counts_changed`, `is_clip_shared(clip_id)`, `mark_instance_counts_dirty()` (with deferred, coalesced emit). `get_clip_instance_count` reads the cache. The load path marks it dirty. |
| `Godot/data/Track.gd` | `add_clip_instance` / `remove_clip_instance` call `get_project_ref().mark_instance_counts_dirty()` when there is a project. |
| `Godot/data/ClipInstance.gd` | `set_clip` marks the project's counts dirty. |
| `Godot/core/theme/ThemeBuilder.gd` | `_components`: the `ClipStrip` stylebox `bar`, constant `height` and colors `name` / `link_icon`. |
| `Godot/clip_editor/ClipStrip.gd` (new) | `class_name ClipStrip extends Control`. `grid_helper`, `offset_x`. `bind_clip(inst)`, `bind_track(track)`, `unbind()`. `selection: Array[ClipInstance]` (track mode). `_draw` draws bars from `get_effective_color()`, brighter when selected, the faint lead-in for a looped instance in clip mode, names (track mode, `TextLine` with an ellipsis, skipped under ~16 px) and the link icon. Hit-test `_bar_at(x)` / `_edge_at(x)` with an 8 px edge zone (one edge in clip mode). Gestures in `_gui_input`: press/drag/release for move, left/right edge, clip-mode right edge (unlooped: `resize_right`; looped: `set_loop_length`), selection clicks (REQ-026), double-click on empty space (create), right-click release → `context_menu_requested(instances, tick, bar_rect_global, from_x)`. Snapping goes through `grid_helper.snap_ticks` unless Shift is held, with a minimum length of `grid_helper.get_snap_interval()` or 1. Release records one undo step. A move's step also holds `AutomationActions.shift_track_automation` when `automation_follows_clips` is on (REQ-028). It watches the bound track's `clip_instance_added/removed`, each instance's `instance_modified`, `track.color_changed`, `Project.instance_counts_changed` and `theme_changed`, each triggering `queue_redraw` or a bar rebuild. Selection is cleared on `bind_track` with a different track. |
| `Godot/clip_editor/ClipEditor.tscn` | Add a `ClipStrip` node right after `Ruler` in `HSplit/MainPanel/VBox/PanelContainer/VBox`. |
| `Godot/clip_editor/ClipEditor.gd` | Remove `_rebuild_ruler_regions`, `_ruler_context_dirty`, `_mark_ruler_context_dirty`, `_watch_ruler`, `_unwatch_ruler_context`, `_ruler_watch` and their callers. `@onready var clip_strip`. Set `clip_strip.grid_helper` in the `grid_helper` setter and `clip_strip.offset_x` beside `ruler.offset_x` in `_process_body`. `_bind_clip_mode` → `clip_strip.bind_clip(bound_clip_instance)`. `_bind_track_mode` and `focus_track_changed` → `clip_strip.bind_track(midi_editor.focus_track)`. `clip_strip.context_menu_requested` → `_editor.arranger.timeline.open_clip_menu(..., true)`. Watch the bound instance's track `clip_instance_removed`: when the bound instance goes, take the path an empty arranger selection takes (`_on_editor_clips_selected([], false)`) (REQ-012). |
| `Godot/clip_editor/MidiEditor.gd` | In `_bind_editor_to_track`, connect the focus track's `clip_instance_added/removed` to a deferred rebind of the focus editor (`editor.unbind()` + `_bind_editor_to_track`), disconnected in `_clear_color_bindings_for` / unbind. Needed for REQ-027 (create and delete from the strip). Today a new focus-track instance only shows after a rebind. |
| `Godot/components/BaseRuler.gd`, `Godot/components/RulerStack.gd` | Remove `regions`, `set_regions`, `_draw_regions` (REQ-001; no other caller). |
| `docs/subsystems/godot-architecture.md` | Replace the "shades the ruler with track-coloured regions" sentence with the clip strip. Document `ClipEdgeEdits`, `Timeline.open_clip_menu(keep_selection)`, `Project.is_clip_shared` and the `BaseRuler` regions removal. |
| `CHANGELOG.md` | Under `[Unreleased]` → Added: clip strip, link icon, menu icons. Changed: plain clip-editor ruler. |

## Migration and compatibility

Nothing is persisted, so existing projects and config are unaffected. The `ClipStrip` theme items come from `ThemeBuilder`, and `Sonara_Theme.tres` is regenerated as usual.

## Test plan

- **Godot, logic** (`Godot/tests/test_clip_edge_edits.gd`, new): left trim keeps every note's song position (REQ-023). Right resize grows `content_length_ticks` and shrinks back (REQ-011/023). Left trim before the content start pads the clip. `set_loop_length` (REQ-011). `clamp_move_on_track` stops at the neighbour and at 0 (REQ-022). `transform_command` returns null when nothing changed.
- **Godot, model** (`Godot/tests/test_clip_shared_state.gd`, new): two instances → `is_clip_shared` for both. After `MakeClipUniqueCommand` → neither. After a delete → not shared. One `instance_counts_changed` per frame for a batch (REQ-004, REQ-030).
- **Godot, strip** (`Godot/tests/test_clip_strip.gd`, new, kept shallow per the UI-test policy): bars from `bind_clip` (unlooped and looped, REQ-010) and from `bind_track` (REQ-020, focus switch). Simulated mouse events for a move (one history entry, then undo, REQ-006/022), a multi-select move (REQ-026), a left trim (REQ-023), a double-click create (REQ-024), a double-click on a bar changing nothing (REQ-025), and a move with "automation follows clips" on and off (REQ-028).
- **Godot, existing:** `Godot/tests/run_all.sh clip_drag timeline_clip clip_loop clip_editor context_menu midi_editor` must stay green after the `ClipEdgeEdits` extraction (`test_clip_drag.gd`, `test_clip_loop.gd`, `test_timeline_clip_*`, `test_clip_editor_track_list.gd`, `test_context_menu_*`, `test_midi_editor_features.gd`).
- **Godot, menu** (added to `Godot/tests/test_context_menu_popup.gd`): every `Button` in an instantiated `ClipContextMenu.tscn` has an icon (REQ-031).
- **Ruler** (added to `test_clip_editor_track_list.gd`): after clip-mode and track-mode binds, the ruler rows hold no regions (REQ-001). With regions removed, this becomes "`BaseRuler` has no `set_regions`". The check is that nothing draws.
- **Live:** alignment at several zooms (REQ-002), corner-radius setting (REQ-003), each context-menu entry from the strip in both modes, with the arranger selection unchanged after Copy (REQ-005), deleting the bound clip in clip mode (REQ-012), notes following a strip move live (REQ-027), and the link icon in the arranger (REQ-030).

## Risks

| Risk | Mitigation |
|---|---|
| The `ClipEdgeEdits` extraction changes arranger resize behaviour | Move the code verbatim first, then run the existing clip tests before any strip work (separate task). |
| A menu action from the strip changes the arranger selection and rebinds the clip editor | `keep_selection` path. The live check covers Copy/Cut/Merge in track mode. |
| Rebinding the focus `NoteEditor` on add/remove drops the note selection or a live gesture | The rebind is deferred and skipped while `NoteEditor` has an active gesture. The selection already survives `_bind_editor_to_track` (`_sync_selected_look`). |
| Lazy count rebuild on a big project | O(instances) once per dirty frame, versus once per clip draw today. |

## Open questions

- [x] Selection cleared on focus-track change: yes (the requirements gate).
- [x] Strip moves move automation when "automation follows clips" is on (REQ-028), through the existing `AutomationActions.shift_track_automation`.
