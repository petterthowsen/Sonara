# Clip editor performance in track mode

Implementation plan for making the clip editor usable in track mode with large projects (50–100
instrument tracks, each with hundreds of notes). The arranger copes with these projects; the clip
editor does not. This plan comes from reading the code. Nothing here has been measured yet, and
Phase 0 exists to fix that.

## Checklist

- [x] Phase 0: Benchmark and baseline numbers
- [x] Phase 1: Quick fixes within the current node-per-note design
- [x] Phase 2: Draw the context tracks (every visible track except the active one) instead of building nodes for them
- [ ] Phase 3 (optional): Draw the active track too and retire `VisualNote`

Do the phases in order. Phase 1 and Phase 2 each stand on their own and are worth shipping
separately. Phase 3 is only worth doing if Phase 0's numbers, re-run after Phase 2, still show
single-track editing is slow (for example dense drum clips with thousands of notes).

After each phase, run `Godot/tests/run_all.sh` and re-run the Phase 0 benchmark. Record the
numbers in the phase's section below. When a phase changes behaviour described in
`docs/subsystems/godot-architecture.md` (the Clip Editor section), update that file in the same
change.

## Root cause

In track mode, `MidiEditor` keeps one `NoteEditor` per visible track, all stacked full-size inside
`h_scroll`. Each `NoteEditor` (via `NoteContainer`) makes one `VisualNote` per note it shows.
A `VisualNote` is a `Panel` with a `Label` child and its own copy of a rounded `StyleBoxFlat`: the
scene marks the stylebox `resource_local_to_scene`, so every instance duplicates it.

At 100 tracks × 500 notes that is about 100,000 Controls and 50,000 styleboxes and labels. Godot
walks all of them for layout, canvas-item traversal and mouse picking, including those scrolled off
screen. On top of that, several code paths do O(notes) work per frame or per event (listed below).

For comparison, the arranger draws MIDI clip contents in one `_draw()` per clip
(`arranger/timeline/clip/MidiclipRenderer.gd`) and holds no node per note.

## Findings

References are to the code as of commit `df501ba`.

### F1. Horizontal scrolling repositions every note twice per frame

- `MidiEditor._process` writes `grid_helper.scroll_position` every frame while smooth scrolling
  settles. `GridHelper` emits `changed` on every scroll change.
- `NoteContainer._on_grid_helper_changed` responds with `_update_note_positions()` (every note)
  and `update_container_width()`.
- Note positions do not depend on scroll: `GridHelper.ticks_to_pixels` is
  `ticks / ppq * pixels_per_beat`, and `h_scroll` moves the content. The first pass is wasted.
- `update_container_width()` includes `scroll_pos + viewport_width` in the width, so every scroll
  step changes `custom_minimum_size.x`. That re-sorts the container, and
  `NOTIFICATION_SORT_CHILDREN` calls `_update_note_positions()` again. That second pass is also wasted.
- `_update_single_note_position` itself is expensive per note: a `get_meta("clip_instance")`
  lookup, `plays_clip_span`, `prepare_piano_roll_layout()` (rewrites about 8 anchor, grow and
  size-flag properties), setting `position` and `size` (which re-lays out the `Label`), and
  `update_label_visibility`.

This cost is multiplied by the number of editors, since every `NoteEditor` is connected to the same
`GridHelper`.

### F2. Track-mode note lookups scan every child

`visual_notes_by_id` is keyed by `"<instance id>:<note id>"`, but in track mode these functions
ignore it and loop over `get_children()`:

- `NoteContainer._on_clip_note_changed`
- `NoteContainer._on_clip_note_removed`
- `NoteContainer.get_visual_note`
- `NoteContainer.get_clip_instance_for_note`

Dragging, nudging or deleting k selected notes emits k clip signals. Each one scans the whole
track, so a drag costs k × (notes on the track) per frame. Each signal also calls
`update_container_width()` and emits `notes_changed`.

### F3. Mouse hover and hit-testing are linear in all notes

- `MidiEditor._note_hit` calls `get_note_at_position` on the active editor, then on every other
  editable editor. Each call allocates a fresh `get_children()` array and tests every child's rect.
  On empty space, which is the usual case, that's a full scan of every editable track per mouse
  motion event.
- Every `VisualNote` uses `MOUSE_FILTER_PASS` and has its own `_gui_input`, so Godot's own
  GUI picking also descends through all of them.
- `NoteEditor._get_notes_in_box` (box select) and Ctrl+A (`get_all_visual_notes`) are full scans.
  These run once per gesture, so they matter less.

### F4. Binding is slow

`set_track_views` and `bind_to_clips` instantiate `VisualNote.tscn` once per note, duplicating the
stylebox each time. `_update_visual` then sets label text (which shapes it) and font colour, and
`set_color` repeats `_update_visual`. Opening track mode, or toggling many tracks visible, builds
every node for every track at once.

### F5. Smaller costs

- During playback, `MidiEditor._update_active_keys` calls `pitches_sounding_at` every frame, which
  scans all of the active editor's children.
- Every context track is its own full-size canvas layer drawn with reduced `modulate.a`.
- `ClipEditor._process` runs every frame but only rebuilds the ruler regions when they are marked
  dirty. That part is fine as it is.

## Phase 0: Benchmark and baseline

Goal: numbers to judge every later phase by.

- Add `Godot/tests/bench_clip_editor.gd`. It extends `TestBase` and runs headless with `-- --test`.
  Name it `bench_*` so `run_all.sh`, which only picks up `test_*.gd`, doesn't run it by default.
- It builds a project with a configurable number of instrument tracks (default 100), each with a
  few clips and a configurable note count (default 500 notes per track, random pitch, start and
  length).
- It instantiates `ClipEditor` in track mode with every track visible and editable, then times:
  1. Binding: `set_track_views` with all tracks, until the next frame.
  2. One horizontal scroll step: set `grid_helper.scroll_position` and let one frame run.
  3. One horizontal zoom step.
  4. 100 hit-tests over empty space through `_note_hit`.
  5. Moving 50 selected notes by one snap step (`_move_selection_horizontal`).
  6. Rebinding after toggling one track hidden and visible.
- It prints each timing in milliseconds plus `Performance.get_monitor(Performance.OBJECT_NODE_COUNT)`.
- Record the baseline here, then again after each phase.

Headless timings leave out GPU and draw cost, but they capture layout, script and scene-tree cost,
which is where the problems above are. After Phase 2, also check in the running app with Godot's
profiler and the "Visible" monitors.

Run it with:

```bash
godot --headless --path Godot -s tests/bench_clip_editor.gd -- --test [--tracks=100] [--notes=500] [--clips=4] 2>&1 | grep BENCH
```

The script sets `OS.low_processor_usage_mode_sleep_usec = 0`. Headless Godot otherwise sleeps
6.9 ms every frame because it can't draw, and that would hide the real per-frame cost. Frame steps
are timed from the call until the next frame starts, so deferred sorts are included. Scroll and
zoom report the median of 20 and 10 steps.

### Results

100 tracks × 4 clips × 500 notes per track (50,000 notes), headless, same machine. All times are in ms.

| Step | Baseline (`df501ba`) | After Phase 1 | After Phase 2 |
|---|---:|---:|---:|
| 1. Bind all tracks | 10,882 | 8,934 | 144 |
| 2. Scroll step | 600 | 158 | 22 |
| 3. Zoom step | 2,169 | 858 | 70 |
| 4. 100 hit-tests over empty space | 3,242 | 2,931 | 151 |
| 5. Nudge 50 selected notes | 20.7 | 13.8 | 30.9 |
| 6a. Hide one track | 129 | 150 | 45 |
| 6b. Show it again | 303 | 442 | 43 |
| 7. Switch the active track | n/a | n/a | 130 |
| Nodes added by binding | 100,099 | 100,099 | 1,000 |

Step 7 was added in Phase 2. Steady-state idle frames cost 0.01 ms in every column. (The benchmark's "idle frame, all bound"
line can read about 1 ms right after binding while deferred work drains.) Steps 6a and 6b move by
±50 % from run to run, so treat them as unchanged.

## Phase 1: Quick fixes within the current design

Goal: make scrolling cheap and remove the per-edit O(n) scans. This keeps `VisualNote`, and no
editing code changes shape.

1. **Separate scroll from scale in `GridHelper`.** Add a `scale_changed` signal that fires when
   `pixels_per_beat`, `ppq`, the tempo map or the time signature map change, but not on
   `scroll_position`. Keep `changed` firing for everything, because rulers, `GridRenderer`,
   `Timeline` and the arranger lanes depend on it for scroll. `NoteContainer` connects to
   `scale_changed` instead of `changed`.
2. **Let `MidiEditor` own the content width.** Compute one width for all editors, using the maximum
   instance end across the shown tracks plus the extra bars, and assign it to every editor. Only
   recompute it when content changes or on `scale_changed`. The "keep growing as you scroll right"
   behaviour stays: when scroll comes within one viewport of the end, grow the width by a whole
   chunk (for example 16 bars) instead of on every pixel of scroll. Remove the width update from
   the per-note signal handlers and batch it with a deferred flag, the same way
   `queue_row_rebuild` batches row rebuilds.
3. **Stop the sort pass from repositioning notes.** Reposition on `NOTIFICATION_SORT_CHILDREN`
   only when a dirty flag is set: layout changed, scale changed, or an instance was modified.
4. **Call `prepare_piano_roll_layout()` / `prepare_drum_layout()` only when a note's mode actually
   changes.** Track the current mode on the note (`drum_mode` already exists) and skip the call
   when it matches. Only call `update_label_visibility` when the row height changes.
5. **Index lookups in track mode.** Keep a `note_id -> Array[VisualNote]` map (one entry per
   instance of the clip) next to `visual_notes_by_id`, kept up to date on add, remove, bind and
   unbind. Use it in the four functions listed under F2. Store the owning `ClipInstance` as a typed
   field on `VisualNote` instead of in metadata.
6. **Share styleboxes.** Remove `resource_local_to_scene` from the note stylebox. Give each
   `NoteContainer` a small cache from display colour to `StyleBoxFlat`. Velocity shading produces
   a bounded set of colours, so quantise brightness to, say, 16 steps. Notes then apply the cached
   box with `add_theme_stylebox_override`. Alternatively, drop the stylebox and draw the note's
   rect in `VisualNote._draw()`. That also makes Phase 3 easier.
7. **Stop GUI picking from descending into notes.** Set `VisualNote.mouse_filter` to
   `MOUSE_FILTER_IGNORE` and move the resize-cursor logic (`_gui_input` in `VisualNote`) into
   `NoteEditor`'s hover handling. Hover already goes through `_note_hit`. Do the same for the
   `Label`.
8. **Only the active editor answers `pitches_sounding_at`** (true already). Skip the call when the
   playhead hasn't moved since the last frame.

Expected result: scrolling costs nothing per note, and edits cost O(k) instead of O(k·n).
Binding, hover over empty space and the node count stay proportional to all notes; Phase 2 fixes
those.

### Outcome

Implemented as planned, with these differences:

- `scale_changed` also fires for `time_numerator`/`time_denominator` and `min_line_spacing`, because
  they change the snap interval and with it the Drum View marker width. Plain `tempo` doesn't fire it.
- Content width: `MidiEditor.update_content_width` (at least `min_width_bars`, the content end plus
  `extra_width_bars`, and whatever scrolling has grown it to). It runs right away on `scale_changed`
  and once per frame (deferred) when an editor emits `content_extent_changed`, which is now all
  `NoteContainer.update_container_width()` does. `_check_scroll_growth` grows the width by
  `scroll_growth_bars` (16) chunks once `scroll + 2 × viewport` passes the end.
- Shared `LabelSettings` as well as styleboxes. `Utils.apply_label_font_color` had been
  duplicating the `LabelSettings` for every note, so every note owned one. Each container now shares
  one per text colour (black or white). Labels only update their text when the pitch changes.
- `VisualNote.clip_instance` is a real field but untyped. Typing it as `ClipInstance`, or casting the
  parent to `NoteContainer`, pulls autoload-dependent scripts into every test that names
  `VisualNote` before autoloads exist, and those tests then fail to compile.
- Hover cursor: `NoteEditor.update_hover_cursor` runs on idle mouse motion and only checks the
  **active** editor's notes. Notes on other tracks no longer show the hand cursor, because checking
  every editable track on each motion event would repeat the F3 scan in GDScript. Phase 2's
  `ContextNotesLayer.note_at` can bring it back cheaply. (The plan said hover already went through
  `_note_hit`. It didn't: Godot's own GUI picking handled it.)
- `NoteEditor._on_clip_note_removed` now drops every visual of the removed note from the selection
  (one per linked instance), not just the first.

What the numbers say:

- Scrolling does no per-note script work now, and a test checks this. The remaining ~150 ms per
  scroll frame is Godot's own work: `ScrollContainer` moves the 100 editors, and each move propagates a
  transform change to about 1,000 descendant nodes. A probe showed that updating `scroll_position`
  alone costs 1.7 ms. Moving `h_scroll` costs 150–300 ms. Only fewer nodes fix this (Phase 2).
- Zoom still repositions all 50,000 notes. That work is now cheaper per note, but it is still
  proportional to all notes shown. Phase 2 cuts it to the active track.
- Hit-tests over empty space (F3) and binding (F4) are barely changed, as expected. Both scale with
  the number of editable tracks' nodes.
- `Log.info`/`debug` have no level filter: every call formats, writes and flushes `last.log` and
  prints. The per-note `logger.info` lines in `NoteContainer`'s reactive handlers ("Reactively
  updated visual note …") run once per note per edit. They cost little in the nudge step but add up in
  bulk edits. Consider a level filter or dropping those lines.

Tests: the existing track-mode tests (`test_clip_editor_track_list.gd`,
`test_note_clip_ownership.gd`, `test_linked_note_nudge.gd`, `test_midi_editor_features.gd`,
`test_drum_view.gd`) must still pass. Add a test that scrolling does not call
`_update_single_note_position`, for example by counting calls through a test hook.
Done in `Godot/tests/test_clip_editor_performance.gd`, with `NoteContainer.reposition_calls` as the
hook. It also covers the shared width and its chunked growth, the shared styleboxes and
`LabelSettings`, and the note id index.

## Phase 2: Draw the context tracks

Goal: the node count and the per-event cost depend only on the active track, not on how many
tracks are visible.

Of 100 visible tracks, only one is being edited. The rest are context: they are drawn dimmed, can
be clicked to switch to them, and can be right-click erased. None of that needs a node per note.

### Design

- **`ContextNotesLayer` (new, `clip_editor/note_editor/ContextNotesLayer.gd`).** A single
  `Control` inside `h_scroll`, placed behind the active editor. It draws the notes of every visible
  track except `current_track` in one `_draw()`, in the track's colour at the track's dimming (0.85
  editable, 0.5 view-only, the same values `_update_note_editor_states` uses now). Notes are drawn
  as plain rects, with no labels. Labels on context notes add little and cost the most.
- **Culling.** Draw only notes inside the visible tick range (from `h_scroll`'s scroll, the viewport
  width and `GridHelper`) and the visible row range (from `MidiEditor.scroll_vertical` and
  `LaneLayout`). For each clip, keep an index of notes sorted by start tick, plus the clip's longest
  note duration. Binary-search the first note whose start is at or after `visible_start - max_duration`.
  The index is built lazily and invalidated on the clip's `midi_note_added`, `midi_note_removed`
  and `midi_note_changed` signals.
- **Redraw triggers.** `queue_redraw()` on `GridHelper.changed` (culling depends on scroll now),
  on vertical scroll, on `LaneLayout.changed`, on note and instance signals from the shown tracks,
  on track colour changes, and when the set of visible or editable tracks changes. Coalesce these
  to one redraw per frame, which `queue_redraw` already does.
- **Played window and Drum View.** Use the same rules as `NoteContainer._update_single_note_position`:
  notes sit at `ci.content_origin_ticks() + start_tick`, notes outside `plays_clip_span` are
  skipped, pitches without a row are skipped, and folded layouts draw hit markers sized by
  `drum_marker_size`. Move that placement math into one shared static helper (for example
  `NotePlacement.gd`) that both `NoteContainer` and `ContextNotesLayer` call, so the two can't drift
  apart.
- **Hit-testing on data.** `ContextNotesLayer.note_at(local_pos, tracks)` returns `[track,
  clip_instance, note_data]` or `[]`, for the editable tracks in list order. It converts the
  position to a tick and a pitch row, then searches the sorted index. `MidiEditor._note_hit` asks
  the active `NoteEditor` first, as now, and then this layer instead of the other editors.
- **Switching tracks.** When a left press hits a context note, `MidiEditor` switches
  `current_track` (as it does now, emitting `note_track_picked`). It binds the single active
  `NoteEditor` to the new track, then looks up that track's `VisualNote` for the hit note in the
  Phase 1 map so the press carries on as a normal press on a note. The old active track goes back
  to the context layer.
- **Right-click erase on context tracks.** Erase through the data: `Clip.remove_midi_note` inside
  the same undo history step `NoteEditor` uses. Move that history code into a small shared helper
  if `NoteEditor`'s private `_history_*` methods can't be called from outside.
- **Only one `NoteEditor` in track mode.** `set_track_views` stops creating an editor per track.
  It binds the scene editor to `current_track` and gives the context layer the rest.
  `note_editors` stays an array, but it only ever holds one editor. Code that loops over it keeps
  working, and the extra-editor code paths can be removed later.

### What moves where

| Now | After Phase 2 |
|---|---|
| One `NoteEditor` per visible track, created in `set_track_views` | One `NoteEditor` for `current_track`, one `ContextNotesLayer` for the rest |
| Dimming via each editor's `modulate.a` and `z_index` | Dimming via the draw colour in `ContextNotesLayer` |
| `_note_hit` loops over editors | Active editor, then `ContextNotesLayer.note_at` |
| Right-click erase on another track goes through that track's `NoteEditor` | Erased through the clip data, same undo step |
| The time range moves between editors on track switch | Unchanged; there is still one active editor to hand it to |
| `MidiEditor._visible_clips` reads the editors (Drum View row union) | Reads the visible tracks' instances directly |

### Risks

- Selection only ever lives in the active editor today, so this change doesn't affect it. Check
  that `NoteSelectionManager.clipboard` (static) and cross-track paste still target the right
  track, because paste goes through the active editor and `get_or_create_clip_at_position`.
- Ctrl+drag duplicates (`is_pending` notes) are only made in the active editor. No change.
- A track can show the same clip more than once (several instances). The context layer draws each
  instance, and hit-testing returns the instance, as `NoteContainer` does.
- Switching tracks now builds nodes for one track. That costs as much as opening that track alone,
  which is fine at hundreds of notes. At thousands it points to Phase 3.

### Tests

- New `Godot/tests/test_context_notes_layer.gd`: placement (played window, `clip_offset`, Drum View
  markers), culling bounds, `note_at` for editable versus view-only tracks, and index invalidation
  on note add, remove and change.
- Update the track-mode tests that assume one `NoteEditor` per track
  (`test_clip_editor_track_list.gd`, `test_note_clip_ownership.gd`). The behaviour they cover stays
  the same (switching on click, erase across tracks, list mirroring), but how they reach it
  changes.
- Re-run the Phase 0 benchmark. The node count should now be about the active track's notes plus a
  constant, whatever the track count.

### Outcome

Implemented as designed, with these differences and findings:

- The layer knows all the visible tracks and skips the active one (`excluded_track`), instead of being handed "every track except the active one". A track switch then costs a redraw, not a reconnect of every track's signals.
- `MidiEditor` tells the layer what is on screen (`view_rect`) once per frame from `_process`, rather than the layer subscribing to scroll signals. Redraws come from a changed rect, `GridHelper.scale_changed`, `LaneLayout.changed`, the clips' note signals, the tracks' instance and colour signals, and the track list.
- The layer watches the note signals of every clip on its tracks from the start (not only those on screen), so Drum View's row rebuild still hears about notes changed on any visible track (`ContextNotesLayer.notes_changed` calls `queue_row_rebuild`). Only the sorted index is lazy. It is sorted with packed int64 keys (`tick * 2^24 + position`) because a script comparator over every clip in a project was slow.
- `_note_hit` now returns a Dictionary: `{editor, visual}` for the active track, `{track, instance, data}` for a context track, `{}` for a miss.
- Placement math is in `NotePlacement.gd`. `NoteContainer.drum_marker_size` / `note_visual_y` are thin wrappers around it, since drag code calls them.
- Erasing a context note goes through `ClipNotesStateCommand.record_edit(name, clip, edit)`, a small helper next to the snapshot code, instead of exposing `NoteEditor`'s private `_history_*` methods.
- The hand cursor over other tracks' notes is back (the Phase 1 loss): `MidiEditor` asks `note_at` on idle mouse motion.
- `NoteContainer.unbind` now removes the note nodes from the tree before freeing them. A rebind in the same frame (a track switch) would otherwise still see the old nodes until the end of the frame.
- `NoteEditor.unbind` resets any gesture state (drag, resize, pending placement, erase), because the nodes those refer to are gone.

Behaviour changes to know about:

- The note selection now lives in the one editor, so switching tracks clears it. Before, each track's editor kept its own selection and showed it while another track was active. The time range still carries over.
- Selecting a track builds nodes for that track alone (130 ms for a 500-note track in the headless benchmark, mostly node creation). That's the cost Phase 3 would remove.
- Context notes are plain rects: no rounded corners and no pitch labels.

What the numbers say: the node count depends on the active track only (1,000 nodes instead of 100,099), so binding, scrolling, zoom and hit-testing all dropped by one to two orders of magnitude. Nudging 50 notes read slower (13.8 to 30.9 ms) in a single run. I haven't investigated it: the editing code is unchanged, but the nudge now runs on the editor after a rebind, and the benchmark's other steps swing by ±50 % between runs. Re-measure before trusting it. What remains is proportional to the active track's notes. Phase 3 is only worth it if a dense single track (thousands of notes) is slow to open or switch to in the live app; measure that first.

Tests: `Godot/tests/test_context_notes_layer.gd` covers placement, the played window and `clip_offset`, Drum View markers, `note_at` for editable and view-only tracks, index invalidation on add, change and remove, unsorted clips and long notes, and that the node count follows the active track. `test_clip_editor_track_list.gd`, `test_select_all.gd` and `test_clip_editor_performance.gd` were updated to the one-editor design.

## Phase 3 (optional): Draw the active track too

Goal: `VisualNote` goes away, and the active track is drawn the same way as the context layer.
Hit-testing, selection and drags work on note data.

Only do this if the numbers after Phase 2 show a problem with dense single tracks.

- Replace `VisualNote` with a small `NoteRef` (`RefCounted`: `clip_instance` and `note_data`,
  compared by instance id and note id) as the type passed around by `NoteSelectionManager`,
  `data/NoteSelection.gd`, the clipboard and `NoteEditor`'s drag, resize and duplicate code.
- `NoteEditor` draws its notes in `_draw()` with the same `NotePlacement` helper. It draws labels
  only when `VisualNote.label_font_size_for` returns a size, and only for notes whose width fits
  the text. Selected and pending notes are drawn in the same pass.
- Drags keep their state in `NoteRef`s plus pixel offsets. The note data only changes on release,
  as now, and between those points the editor redraws itself.
- This touches every file that references `VisualNote` (`NoteEditor`, `NoteSelectionManager`,
  `NoteContainer`, `MidiEditor`, `data/NoteSelection.gd` and five test files). Plan it as its own
  spec under `docs/specs/` before starting.
