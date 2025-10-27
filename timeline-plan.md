# Timeline Multi-Clip Selection & Clipboard Plan

## Objectives
- Re-enable Timeline clip selection with additive ctrl-click semantics.
- Support ctrl+drag box selection spanning multiple TimelineTracks.
- Introduce a `ClipSelection` data model for tracking selected instances, bounds, and clipboard payloads.
- Render both the live box select rectangle and the current selection span markers.
- Allow dragging to move the entire selection horizontally (snap-aware) and vertically between tracks.
- Implement keyboard-driven edits: `ui_left/right/up/down`, `ui_cut`, `ui_copy`, `ui_paste`.

## Implementation Phases

### 1. Selection Data & Manager
- Add `Godot/data/ClipSelection.gd` (RefCounted) mirroring `NoteSelection`:
  - Maintain ordered `Array[ClipInstance]`, cached tick bounds, per-track grouping, selection center, helper methods (`add/remove/clear`, `compute_bounds`, `get_track_span`, `duplicate_selection_data`).
  - Provide serialization helpers for clipboard use (relative tick offsets, track offsets, clip payload).
- Create `Godot/arranger/timeline/ClipSelectionManager.gd`:
  - Owns a `ClipSelection`, box-select state, clipboard state.
  - Emits signals (`selection_changed`, `box_selection_updated`, `clipboard_changed`).
  - Provides APIs for single-click select, ctrl-toggle, shift-range (future safety), ctrl+drag box select start/update/end, selection movement requests, clipboard copy/cut/paste helpers.
  - Tracks `project` and listens for clip removal/order changes to auto-prune invalid selections.

### 2. Wiring Timeline Nodes to Selection Manager
- Extend `Arranger.gd` to instantiate the `ClipSelectionManager`, expose it to Timeline & Overlay, and bridge signals.
- Update `TimelineTrack.gd`:
  - When instantiating clips, connect `select_requested`, `clip_move_requested`, `drag_started`, `drag_moved`, `drag_ended`.
  - Forward empty-area clicks to clear selection before moving playhead.
- Update `TimelineClip.gd`:
  - Adjust modifier detection to treat ctrl/command as additive toggle (keep shift as range hook).
  - Gate drag initiation so that dragging a selected clip moves the entire selection (not just origin clip).
  - Ensure `set_selected` is driven externally only.

### 3. Box Selection UX
- Capture ctrl+LMB drag gestures at the timeline container level (likely in `Timeline.gd` or via overlay overlay `_gui_input`).
  - Start box select when ctrl pressed + button press on background; delegate to manager start/update/end.
  - At completion, query timeline for clips overlapping the rect and update selection.
- Implement helper in `Timeline`/`TimelineTrack` to supply `get_clips_in_rect(rect: Rect2)` scanning all tracks efficiently.

### 4. Visual Feedback
- Render selection-related overlays directly in `Timeline._draw()`:
  - Draw active box selection rect (using theme colors from `Editor` group).
  - Draw selection span markers (vertical lines at selection bounds) and optionally highlight tracks encompassed.
  - Pull draw state from `ClipSelectionManager` (box rect, tick bounds, selected track indices).
- Update `TimelineClip` theme usage so selected clips visibly differentiate (leveraging existing StyleBoxes).

### 5. Dragging & Movement Logic
- Horizontal drag:
  - On `clip_move_requested`, compute tick delta from manager, snap to grid (`Timeline.grid_helper`), clamp to ≥0, apply to every selected `ClipInstance` via new manager method (batch updates with engine sync).
  - Ensure duration/resizing updates still function when selection contains single clip.
- Vertical drag:
  - During `drag_started`/`drag_moved`, derive target track under cursor (convert global position → timeline track index using `Timeline` utilities and stored node positions).
  - On `drag_ended`, if target track differs, reassign selection by removing from old tracks and adding to new track in order (consider type compatibility, e.g., prevent dropping on folder tracks; fall back gracefully).
  - Maintain relative ordering and ensure engine OSC updates propagate (re-emit `clip_instance_removed/added`).
- Support combined diagonal drag by updating both tick delta and target track simultaneously before final commit.

### 6. Keyboard Navigation & Clipboard
- In `Arranger._unhandled_input` (or dedicated handler), detect `ui_left/right/up/down`, `ui_cut/copy/paste` when timeline has focus:
  - `ui_left/right`: move selection by +/- one snap interval (use `Timeline.get_snap_interval()`); clamp to ≥0.
  - `ui_up/down`: move selection to adjacent visible track (skip folders if clips cannot exist there); preserve relative track spacing and prevent invalid track types.
  - `ui_cut`: use manager to clone clipboard payload, delete clips via their parent track `remove_clip_instance`, and emit selection change (clipboard retains relative offsets).
  - `ui_copy`: populate clipboard without altering scene.
  - `ui_paste`: paste at current playhead (`Sonara.editor.playhead_ticks`), applying stored relative tick offsets and track offsets; create new `ClipInstance`s via Track helpers, duplicating underlying `Clip` data when needed (ensure audio vs. MIDI handled).
- After clipboard actions, refresh selection to new instances and update visuals.

### 7. Housekeeping & Testing
- Update `STATUS.md` Phase 1 checklist as items complete; add new tasks to `TODO.md` if required.
- Manual test matrix:
  - Single + multi-selection interactions (click, ctrl-click, ctrl-box).
  - Dragging horizontally/vertically with mixed track types.
  - Keyboard moves respecting snap & track bounds.
  - Clipboard operations with both MIDI and audio clips.
  - Regression: double-click create clip, clip resizing, playhead click.
- Consider writing lightweight Godot unit tests for `ClipSelection` logic if feasible (optional).

## Open Questions / Assumptions
- Folder tracks likely should reject clip drops; plan assumes manager will skip them.
- Clipboard duplication rules for audio clips (silence padding vs. referencing same asset) need confirmation; default to referencing original `Clip` unless specified otherwise.
- Determine whether ctrl modifier should map to `Input.is_action_pressed("ui_select")` or explicit key check to support platform differences.
