# Clip Editor Clip Strip — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — Shared foundations (no visible change)

- [x?] **T-001** [REQ-011, REQ-022, REQ-023] Extract the edge-edit rules into `ClipEdgeEdits` and make `TimelineClip` and `Timeline` delegate to it. The behaviour is unchanged.
  - _Files_: `Godot/history/ClipEdgeEdits.gd` (new), `Godot/arranger/timeline/clip/TimelineClip.gd`, `Godot/arranger/timeline/Timeline.gd`
  - _Output_: `snapshot`, `resize_left`, `resize_right`, `neighbour_left/right`, `pad_clip`, `extend_clip_to`, `set_loop_length`, `clamp_move_on_track`, `transform_command`. `TimelineClip._resize_by` / `_finish_resize` / `_drag_loop_point` / `_finish_loop_drag` and `Timeline._clamp_instances_tick_delta` call them.
  - _Verify_: `Godot/tests/run_all.sh clip_drag clip_loop timeline_clip clip_scale` all pass.
  - _Depends on_: —

- [x?] **T-002** [REQ-011, REQ-022, REQ-023] Unit tests for `ClipEdgeEdits`.
  - _Files_: `Godot/tests/test_clip_edge_edits.gd` (new)
  - _Output_: tests for: left trim keeps notes' song positions; right resize grows and shrinks content length; left trim past 0 pads; `set_loop_length`; the move clamp at a neighbour and at 0; `transform_command` returning null with no change.
  - _Verify_: `Godot/tests/run_all.sh clip_edge_edits` passes.
  - _Depends on_: T-001

- [x?] **T-003** [REQ-004, REQ-030] Cached shared-clip state on `Project`.
  - _Files_: `Godot/data/Project.gd`, `Godot/data/Track.gd`, `Godot/data/ClipInstance.gd`, `Godot/tests/test_clip_shared_state.gd` (new)
  - _Output_: `is_clip_shared`, `mark_instance_counts_dirty`, coalesced `instance_counts_changed`. `get_clip_instance_count` reads the cache. Add, remove, `set_clip` and load mark it dirty.
  - _Verify_: `Godot/tests/run_all.sh clip_shared_state` passes (two instances → shared; Make Unique → neither; delete → not shared; a batch emits once). `Godot/tests/run_all.sh make_unique clip` stays green.
  - _Depends on_: —

- [x?] **T-004** [REQ-005] `Timeline.open_clip_menu(..., keep_selection)`, plus clipboard functions that take instances.
  - _Files_: `Godot/arranger/timeline/Timeline.gd`
  - _Output_: `_on_clip_context_menu_requested` goes through `open_clip_menu`. `copy_instances_to_clipboard` / `cut_instances_to_clipboard`. With `keep_selection`, Cut, Copy and Merge leave the arranger selection alone.
  - _Verify_: `Godot/tests/run_all.sh context_menu clip_drag` passes. Live: right-click → Copy in the arranger still copies, and Paste puts the clips back.
  - _Depends on_: —

## Phase 2 — The clip strip

- [x?] **T-005** [REQ-003] `ClipStrip` theme items.
  - _Files_: `Godot/core/theme/ThemeBuilder.gd`
  - _Output_: `ClipStrip` stylebox `bar` (theme radius), constant `height`, colors `name` / `link_icon`.
  - _Verify_: `godot --headless --path Godot -s tests/test_scale_ui.gd -- --test` and the theme tests (`Godot/tests/run_all.sh theme`) pass.
  - _Depends on_: —

- [x?] **T-006** [REQ-002, REQ-003, REQ-004, REQ-010, REQ-020, REQ-021] `ClipStrip` drawing and binding, with no gestures yet, wired into the clip editor. The ruler regions are removed.
  - _Files_: `Godot/clip_editor/ClipStrip.gd` (new), `Godot/clip_editor/ClipEditor.tscn`, `Godot/clip_editor/ClipEditor.gd`, `Godot/components/BaseRuler.gd`, `Godot/components/RulerStack.gd`
  - _Output_: the strip under the ruler, following `offset_x` and the grid. `bind_clip` (bar from the played window or the loop region, faint lead-in), `bind_track` (focus-track bars with names), the link icon, redraws on instance, colour, count and theme changes. The `_rebuild_ruler_regions` machinery and `BaseRuler` regions are deleted.
  - _Verify_: `Godot/tests/test_clip_strip.gd` (new) binding cases pass (REQ-010 unlooped and looped, REQ-020 focus switch). `Godot/tests/run_all.sh clip_editor midi_editor ruler` stays green.
  - _Depends on_: T-003, T-005

- [x?] **T-007** [REQ-026] Strip selection in track mode.
  - _Files_: `Godot/clip_editor/ClipStrip.gd`, `Godot/tests/test_clip_strip.gd`
  - _Output_: click, Shift+click and Ctrl/Cmd+click; a click on empty space clears; cleared on a focus-track change; selected bars drawn brighter.
  - _Verify_: test: Shift+click on two bars → selection size 2; switching the focus track → empty.
  - _Depends on_: T-006

- [x?] **T-008** [REQ-006, REQ-022, REQ-028] Move in track mode, with automation following.
  - _Files_: `Godot/clip_editor/ClipStrip.gd`, `Godot/tests/test_clip_strip.gd`
  - _Output_: body drag with a threshold moves the selection live, clamped with `ClipEdgeEdits.clamp_move_on_track`, snapped (Shift for free movement). On release it records one "Move Clips" step with `AutomationActions.shift_track_automation` when `automation_follows_clips` is on.
  - _Verify_: test: a one-bar move → `start_ticks` +960×4 and one history entry, and undo restores it. A multi-select move moves both clips. With automation follows on, the lane point moves and undo restores it; with it off, the point stays.
  - _Depends on_: T-001, T-007

- [x?] **T-009** [REQ-006, REQ-011, REQ-023] Edge gestures: both ends in track mode, the right end only in clip mode (loop length for a looped clip).
  - _Files_: `Godot/clip_editor/ClipStrip.gd`, `Godot/tests/test_clip_strip.gd`
  - _Output_: an 8 px edge zone with the resize cursor, applied to the whole selection in track mode, recorded as "Resize Clips" / "Move Loop Point".
  - _Verify_: test: a one-beat left trim → start and offset +960, duration −960. In clip mode, a one-bar right drag → duration +3840 (unlooped) or loop length +3840 (looped), with `start_ticks` unchanged.
  - _Depends on_: T-001, T-007

- [x?] **T-010** [REQ-024, REQ-025] Double-click: create on empty space, nothing on a bar.
  - _Files_: `Godot/clip_editor/ClipStrip.gd`, `Godot/tests/test_clip_strip.gd`
  - _Output_: snapped start, `get_ticks_per_bar_at`, shortened to the next clip, `ClipActions.create_clip` with the focus track's `default_clip_type()`.
  - _Verify_: test: a double-click at bar 3 on an empty track → one instance at 3840×2, one bar long, one undo step. A double-click on a bar leaves the instance count and mode unchanged.
  - _Depends on_: T-007

- [x?] **T-011** [REQ-027] The focus note editor follows instances added to and removed from the focus track.
  - _Files_: `Godot/clip_editor/MidiEditor.gd`
  - _Output_: a deferred rebind of the focus `NoteEditor` on `clip_instance_added/removed`, skipped during a live gesture and disconnected on unbind or focus change.
  - _Verify_: added to `Godot/tests/test_clip_editor_track_list.gd`: creating an instance on the focus track → after one frame the focus editor's `clip_instances` contains it; deleting it → gone. `Godot/tests/run_all.sh midi_editor multi_track note_clip` stays green.
  - _Depends on_: —

## Phase 3 — Integration

- [x?] **T-012** [REQ-005, REQ-012] Strip context menu, plus clearing the editor when the bound clip is deleted.
  - _Files_: `Godot/clip_editor/ClipStrip.gd`, `Godot/clip_editor/ClipEditor.gd`
  - _Output_: right-click release → `context_menu_requested` → `_editor.arranger.timeline.open_clip_menu(instances, snapped tick, bar rect, x, true)`. ClipEditor watches the bound instance's track `clip_instance_removed` and takes the empty-selection path.
  - _Verify_: live (needs the Editor): each entry from the strip in both modes behaves as in the arranger, the arranger selection is unchanged after Copy, Cut and Merge, and Delete in clip mode leaves no stale bar and no errors in `~/.local/state/sonara/logs/ui/last.log`.
  - _Depends on_: T-004, T-006

- [x?] **T-013** [REQ-030] Link icon in the arranger clip header.
  - _Files_: `Godot/arranger/timeline/clip/TimelineClip.gd`, `Godot/tests/test_clip_shared_state.gd`
  - _Output_: `is_shared()`. The icon is drawn left of the mode badge and the name width shrinks to fit. It redraws on `instance_counts_changed`.
  - _Verify_: test: two `TimelineClip`s of one clip report shared; after Make Unique, neither does. `Godot/tests/run_all.sh timeline_clip` stays green.
  - _Depends on_: T-003

- [x?] **T-014** [REQ-031] Context menu icons.
  - _Files_: `Godot/assets/icons/fetch_lucide_icons.sh`, new `Godot/assets/icons/*.svg`, `Godot/arranger/timeline/ClipContextMenu.tscn`, `Godot/tests/test_context_menu_popup.gd`
  - _Output_: icons on every action button. Any lucide name that doesn't exist is replaced, and the swap is noted here.
  - _Verify_: test: every `Button` in the instantiated `ClipContextMenu.tscn` has a non-null `icon`. Live: the icons read clearly at the current UI scale.
  - _Depends on_: —

## Phase 4 — Docs

- [x?] **T-015** [REQ-all] Update the docs and the changelog.
  - _Files_: `docs/subsystems/godot-architecture.md`, `CHANGELOG.md`
  - _Output_: the clip strip, `ClipEdgeEdits`, `Timeline.open_clip_menu(keep_selection)`, `Project.is_clip_shared` and the `BaseRuler` regions removal are documented. Changelog Added: clip strip (both modes), link icon, menu icons. Changelog Changed: plain clip-editor ruler.
  - _Verify_: the ruler-region sentence in `godot-architecture.md` is gone, and every new symbol above appears in it.
  - _Depends on_: T-012, T-013, T-014

## Phase 5 — Live verification

- [ ] **T-016** [REQ-all] Live check with the engine and Godot running.
  - _Files_: —
  - _Output_: every task marked `[x]`, plus a comment on the tracking issue listing what was and wasn't checked.
  - _Verify_: the steps are below.
    1. Clip mode: the bar lines up with the ruler at three zoom levels. Change Settings > Theme > Corner radius and the bars follow. Drag the right end of an unlooped clip, then a looped one.
    2. Track mode: move, trim left, resize right and double-click-create on the focus track. Notes follow live. Switch the focus track.
    3. With "automation follows clips" on, move a clip over a lane point. The point moves, and one undo restores both.
    4. Context menu from the strip: every entry, in both modes. The arranger selection is unchanged after Copy.
    5. Arranger: the link icon shows on duplicated linked clips and goes away after Make Unique.
  - _Depends on_: T-015

## Phase 6 — Follow-up after the first live test

- [x?] **T-018** [REQ-029] Restore the old move clamp (landing spot only) in `ClipEdgeEdits.clamp_move_on_track`; the "stop at the neighbour on a big jump" rule from T-001 is removed.
  - _Files_: `Godot/history/ClipEdgeEdits.gd`, `Godot/tests/test_clip_edge_edits.gd`, `Godot/tests/test_clip_strip.gd`
  - _Verify_: `Godot/tests/run_all.sh clip_edge clip_strip clip_drag` passes (jump into a free gap works; landing on a neighbour stops).

- [x?] **T-019** [REQ-040, REQ-041, REQ-042] Range select, Ctrl+C/V/D and Ctrl+drag copy in the strip, with the logic in `ClipStripActions`.
  - _Files_: `Godot/history/ClipStripActions.gd` (new), `Godot/clip_editor/ClipStrip.gd`, `Godot/clip_editor/ClipEditor.gd`, `Godot/tests/test_clip_strip.gd`
  - _Verify_: `Godot/tests/run_all.sh clip_strip` passes. Live: Ctrl+C in the strip then Ctrl+V pastes at the playhead or range start, and the clips also paste in the arranger; Ctrl+D overwrites; Ctrl+drag ghosts follow the pointer.

## Tracking

- [ ] **T-017** Open a GitHub issue for spec 054 (labels `godot`, `midi-editor`, `arranger`) linking this spec, after the user confirms.
  - _Depends on_: —
