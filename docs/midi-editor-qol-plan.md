# MIDI editor QOL plan (issue #79)

Tracks [#79](https://github.com/petterthowsen/Sonara/issues/79). Scope: checklist items 1, 3, 4, 5 and 6. Item 2 (scale support) is out of scope for now.

Checkbox legend (as in AGENTS.md): `[ ]` open, `[x?]` implemented but not verified, `[x]` verified. Comment on the issue after each phase.

## Ground rules

- Edit notes through the existing selection-edit pattern in `Godot/clip_editor/note_editor/NoteEditor.gd`: `_history_begin_selection()`, then mutate `MidiNoteData` for `_selected_note_visuals()`, then `_refresh_notes()`, `note_clip.update_midi_note()`, `update_container_width()` and `_history_commit("<Name>")`. Undo then comes for free via `ClipNotesStateCommand`. `_move_selection_vertical` and `_move_selection_horizontal` are the templates.
- Handle overlaps the way the nudge functions do: `cut_overlapping_notes_at_pitch`.
- Linked clip instances and loop repeats share one `MidiNoteData` through several visuals. Always iterate `_selected_note_visuals()`, which de-duplicates, and never the raw selection.
- Put the pure math (quantize, mirror, strum, scale) in static functions on a new `Godot/clip_editor/note_editor/NoteTransforms.gd`, so it can be tested headless without a scene. `NoteEditor` stays a thin wrapper.
- Ticks are 960 PPQ. Middle C is C3, MIDI 60.
- Register every new action in `Hotkeys` (ADR 0017) with a help-bar entry. UI code never sends OSC. `clip.update_midi_note()` handles engine sync.
- Tests extend `TestBase` and are named `Godot/tests/test_*.gd`. Run them with `Godot/tests/run_all.sh <word>`. Use glossary terms in test names (`CONTEXT.md`).
- Check Drum View separately for every feature. Hit markers have no length (REQ-022), so length-based features must be a no-op or hidden there.
- Read `docs/subsystems/godot-architecture.md` and `godot-ui-components.md` before starting, and check their claims against the source.

---

## Phase 1: Velocity as a progress bar (item 1)

Goal: velocity is drawn as a fill in the bottom half of the note. Note opacity or brightness no longer encodes velocity.

Current state: `VisualNote._update_visual()` maps velocity to HSV brightness (0.2 to 0.8, quantized to `VELOCITY_SHADES`). `NoteContainer.note_style()` caches one shared `StyleBoxFlat` per colour, which keeps thousands of notes cheap. The note is a `Panel` with a `Label` child.

- [x?] Decide the look (a short design note at the top of the PR or issue comment):
  - Fill height: the bottom half of the note, with the bar's width equal to `velocity` × note width.
  - Track bar: a faint darker strip behind the fill.
  - The note body becomes a constant brightness. The selected state still brightens it.
- [x?] Remove the velocity-to-brightness mapping in `VisualNote._update_visual()`. Keep `VELOCITY_SHADES` only if the bar still needs quantizing, otherwise delete it with its comments.
- [x?] Draw the bar without per-note allocation:
  - Done as: a `_draw()` override on `VisualNote` that draws the shared body stylebox itself, then two `draw_rect` calls. A Panel paints its own style after a script's `_draw()`, so the panel style is overridden with an empty one and the shared box is drawn in `_draw()` (zero extra nodes).
  - Option A (original idea): a `_draw()` override on `VisualNote` that draws two `draw_rect` calls. Call `queue_redraw()` only when velocity, size, selection or colour change.
  - Option B: a child `ColorRect` per note. This costs one more node per note, which hurts the performance work in `docs/clip-editor-performance-plan.md`.
  - Do not create a stylebox per note. Keep using the shared `note_style` cache.
- [x?] Keep the label readable over the bar (label text colour is derived in `_apply_label_color`). The bar sits in the bottom half and the label in the top half, so check the label still fits at the smallest row heights (`LABEL_FONT_SIZE_MIN`).
- [x?] Drum View: hit markers (12 px wide) should show the bar as height rather than width. Decide and document this. A simple option is a bottom-aligned fill whose height is `velocity` × marker height.
- [x?] Redraw on velocity edits from every path that changes it: the value lane stem drag (`ValueLaneStemArea`), velocity drag, and paste or undo (`_refresh_notes`).
- [x?] `ContextNotesLayer` (ghost notes of other clips): confirm it needs no bar. It should stay flat and dim.
- [x?] Tests (`test_visual_note_velocity.gd`): bar width fraction for velocity 1/127, 0.5 and 1.0. The body colour is identical for two notes of different velocity. Selection still changes the body colour.
- [x] Manual check: zoom in and out, then check a dense clip for FPS regressions against the previous build.

---

## Phase 2: Quantize, flip/mirror, strum (items 3, 4, 5)

Goal: three selection-transform tools on one shared foundation. Build the foundation first.

### 2.0 Modifier change (done before 2a)

- [x?] Note drag modifiers follow the setting `midi_editor/note_drag_modifiers`. Default "Alt: length and velocity": Alt held after grabbing a note, a 6 px threshold, then sideways = length and up/down = velocity (up raises). Alternative "Ctrl: length, Alt: velocity". Shift bypasses snapping for note drag, the resize handle and the Ctrl+drag duplicate. The resize handle's "same duration for all" uses the setting's length key. Ctrl pressed before the click still duplicates or toggles selection. Help-bar states `note_drag` / `note_drag_alt` in `HotkeyActions.gd`; test `test_note_drag_alt_axis.gd`.

- [x?] Arrow-key hotkeys (clip editor, all rebindable in Settings › Shortcuts): Ctrl+Right/Left grow/shrink the range end and Ctrl+Shift+Left/Right grow/shrink its start, by the finest visible snap step; nudging notes moves the range too; Shift+Left/Right move the selection (and its range) by the range length; Alt+Up/Down change velocity by 4/127; Alt+Left/Right change length by the snap step (min one step, no-op in Drum View). Test `test_note_arrow_hotkeys.gd`. Note: `_edit_selection_data` in `NoteEditor.gd` is a small version of the 2a `_apply_selection_edit` helper.

### 2a. Shared foundation

- [x?] Create `NoteTransforms.gd` (static, pure) operating on `Array[MidiNoteData]` and returning or applying the edit in place.
- [x?] Add one `NoteEditor` helper, for example `_apply_selection_edit(name: String, fn: Callable)`. It runs the history begin, the mutation, the overlap cut, `update_midi_note`, the refresh, `update_container_width` and the history commit. Refactor `_move_selection_vertical` and `_move_selection_horizontal` onto it only if that is a small, safe change. If not, leave them alone.
- [x?] Restructure the bottom Toolbar in `Godot/clip_editor/ClipEditor.tscn` (`BottomPanel/Toolbar`) so the tools have a home. Wrap the buttons in one `HBoxContainer` per group, increase the Toolbar's horizontal spacing (`theme_override_constants/separation`), and put a `VSeparator` between groups. Reuse the existing `ToolbarSeparator` stylebox (`StyleBoxLine_wamqs`, already extended to cover the Toolbar padding) for every separator. Groups, left to right:
  1. **Mode and note map:** `ModeSwitch`, `NoteMapButton`.
  2. **Toggles:** `AuditionToggle` (the only one today).
  3. **Value lanes:** `ValueLanesToggle`, `NextValue`.
  4. **Selection tools:** Quantize, Flip/Mirror, Strum (and later the group scale tool if it gets a button).
- [x?] Fold the note map `Load`, `Edit` and `Save` buttons into the `NoteMapPopup` as menu items, and delete `NoteMapLoad`, `NoteMapEdit` and `NoteMapSave`. The popup is built in `_rebuild_note_map_popup()` in `ClipEditor.gd`, and ids are handled in `_on_note_map_popup_id_pressed()`:
  - Add a separator, then "Load...", "Edit...", "Save..." items with their own id constants next to `NOTE_MAP_ID_NONE` and `NOTE_MAP_LIBRARY_ID_BASE`. Keep them clear of the library id range.
  - Move the handlers (`_on_note_map_load_pressed`, `_on_note_map_edit_pressed`, `_on_note_map_save_pressed`) over to the popup dispatcher.
  - Move the `disabled = not has_channel` logic (around line 516) onto the popup items with `set_item_disabled`. Rebuild or update it whenever the popup opens, since it is already rebuilt then.
  - Remove the three `@onready` vars and their `pressed.connect` calls.
  - Check `Godot/tests/` for tests that reference the removed nodes (`test_note_map*.gd`) and update them.
- [x?] The scene already has an unwired placeholder `Quantize` button (no handler, no tooltip). Reuse it as the Quantize tool rather than adding a second one.
- [x?] Add the tool buttons with icons or short text and tooltips that name the hotkey. Disable them when no notes are selected, and in Drum View for the tools that do not apply. Hotkeys and the right-click context menu come in addition to the buttons, not instead.
- [ ] Check the Toolbar at a narrow editor width. Four groups plus separators must not clip, so let the Toolbar wrap or shrink labels if needed.
- [x?] Operate on the selected notes. Decided: in clip mode the tool buttons select all notes when nothing is selected; in track mode they are disabled without a selection.

Done as: `NoteTransforms.gd` has `pitch_bounds`, `tick_bounds` and `group_by_start` for now (quantize, mirror and strum math arrive with their phases). `_apply_selection_edit(name, fn)` takes `fn(notes: Array[MidiNoteData])` and goes through `_history_begin_selection` / `_history_commit`, so every tool is one undo/redo step; `_edit_selection_data` is now a per-note wrapper over it, the nudge functions were left alone. Toolbar groups are `ModeGroup`, `ToggleGroup`, `LanesGroup` and `ToolsGroup` with `Separator1-3`. The note map popup disabled state was not needed: the button is disabled without a channel, so the popup cannot open. Tools register with `ClipEditor._register_selection_tool(button, run, works_in_drum_view)`; a button without a registration stays disabled. Mirror and Strum buttons are added in their own phases. Still open: the empty-selection decision (currently a no-op: `_apply_selection_edit` returns early) and a narrow-width check of the Toolbar. Test: `test_selection_edit_foundation.gd`.

### 2b. Quantize (item 3)

- [x?] Strength-based quantize: `new_start = lerp(start, snapped, strength)`. Strength 100% is a hard snap. The quantize popup has a strength slider (0 to 100%), defaulting to 100%. The last used value is remembered for the next time and persisted through `Sonara.get_config`/`set_config` (key e.g. `clip_editor/quantize_strength`). The hotkey quick-quantize uses the remembered strength too.
- [x?] Options: quantize start (default), start and end (also snaps duration), and optionally the grid size.
- [x?] Grid source: the editor's current snap value from `GridHelper` by default. Read `NextNoteValues.gd` and spec 019 (note values) to see how snap and note values interact, and respect triplet and dotted grids.
- [ ] Optional swing amount. Defer if it makes the dialog heavy.
- [x?] Quantize can create same-pitch overlaps. Reuse the overlap-cut path.
- [x?] Looped instances: starts fold into the loop via `fold_into_loop`, as `_move_selection_horizontal` does.
- [x?] A hotkey applies the default quantize (grid, 100%) immediately. A small popup or dialog sets strength and the start/end option.
- [x?] Tests (`test_note_quantize.gd`): snap to 1/16, partial strength, the strength is remembered between uses, triplet grid, start-and-end mode, and an already-quantized note stays unchanged.

Done as: `NoteTransforms.quantize(notes, snap, strength, mode)` with a `Callable` snapper (`GridHelper.snap_ticks`, so time-signature segments are respected); `NoteEditor.quantize_selection()` wraps it (loop folding, Drum View forces start-only, overlap cuts via `_apply_selection_edit`). Strength and mode persist in `clip_editor/quantize_strength` and `clip_editor/quantize_mode`. The toolbar has a Quantize button (applies at once with the remembered settings) and a `v` button beside it that opens the strength slider and "Quantize note ends too" popup. Hotkey `notes_quantize`, default Ctrl+Q. Empty selection: in clip mode the tool buttons select all notes first; in track mode they stay disabled until something is selected (the hotkey always needs a selection). Deferred: swing and grid-size override. The grid has no triplet or dotted mode today (`GridHelper` only has binary subdivisions), so the triplet test exercises the snapper with a 320-tick grid; revisit when triplet grids exist.


### 2c. Flip / mirror (item 4)

- [x?] Vertical flip (invert pitch): `new = lo + hi - note`, mirrored around the middle of the selection's pitch range. This keeps the group in place. Clamp to 0..127.
- [x?] Horizontal flip (reverse time): mirror starts around the selection's time range, so `new_start = range_start + range_end - (start + duration)`. Durations are unchanged.
- [x?] Both are exact involutions: applying one twice restores the original. Test this.
- [x?] Respect the range-selection boundaries (`NoteSelectionManager.has_range()`) as the mirror axis when a range exists. Otherwise use the bounds of the selected notes.
- [x?] Drum View: vertical flip would reorder pads, which is rarely wanted, so disable or hide it there. Horizontal flip works.
- [x?] Tests (`test_note_mirror.gd`): both axes, the involution property, clamping at pitch 0 and 127, and a single-note selection (a no-op).

Done as: `NoteTransforms.mirror_pitch` / `mirror_time`; `NoteEditor.flip_selection_vertical()` / `flip_selection_horizontal()`; toolbar buttons Flip V and Flip H; hotkeys `notes_flip_vertical` (Ctrl+Shift+V) and `notes_flip_horizontal` (Ctrl+Shift+H). Vertical axis is the selected notes' pitch bounds; horizontal axis is the selection range (which also covers the span of selected notes), loop-region starts fold back into the loop. Drum View: vertical is disabled, horizontal mirrors hit start points only.

### 2d. Strum (item 5)

- [x?] Operates on chords: notes whose starts fall within `NoteTransforms.STRUM_TOLERANCE_TICKS` (60, a 1/64 note) of the group's first note, grouped with `group_by_start`.
- [x?] Each chord: sort by pitch, then offset note `i`'s start by `i × spread_ticks`. Direction up (low to high), down, or alternate (flips every chord, starting up). Decided: note ends stay put, so durations shrink (the tooltip says so).
- [x?] Optional velocity ramp: `velocity_ramp` (-1..1) is added across the strum, 0 for the first note up to the full amount for the last.
- [x?] Parameters (spread 0-240 ticks, direction, velocity ramp) live in their own small popup beside the Strum button (the quantize popup is a different tool), persisted in `clip_editor/strum_spread_ticks`, `clip_editor/strum_direction` and `clip_editor/strum_velocity_ramp`.
- [x?] The offset is clamped to `duration - 1`, so a note keeps at least one tick.
- [x?] Tests (`test_note_strum.gd`): a 3-note chord up and down, two chords with alternate direction, a single note (unchanged), clamping on a very short note, the velocity ramp, and one undo step through `strum_selection`.

Done as: `NoteTransforms.strum(notes, spread_ticks, direction, velocity_ramp)`; `NoteEditor.strum_selection()`; toolbar buttons Strum and `v` (options popup) in the Tools group; hotkey `notes_strum`, default Ctrl+Shift+S. Drum View: disabled (hits have no length and rows are pads). Single notes in the selection are skipped, so selecting a lone note is a no-op.

### 2e. Phase 2 wrap-up

- [x?] Hotkeys and help-bar entries registered and listed in `Hotkeys`. The help bar is registry-driven (`requires: note_selection`), so the entries come from `HotkeyActions.gd`; not yet looked at in the running app.
- [x?] Every tool is one undo step. Checked headless for strum with a multi-clip track-mode selection (`test_note_strum.gd`); the Ctrl+Z key itself is not tried in the app.
- [x?] Track mode with several clip instances and linked instances: shared notes are processed once (tested for strum). That test found that strum merged same-tick notes of different clips into one chord; chords are now grouped per clip. Quantize and mirror were not re-examined: mirror takes its default axis from the bounds of all selected notes in clip ticks, which in track mode mixes clips.
- [x?] `docs/subsystems/godot-architecture.md` (Clip Editor section) describes the tools and `NoteTransforms.gd`.

---

## Phase 3: Group length-scale handle (item 6)

Goal: with notes selected, a handle appears at the end of the right-most selected note. Dragging it scales the selected notes as a whole.

Scaling semantics (confirm before building): this scales both start offsets and durations relative to the left edge of the selection, so the group stretches like a clip: `start' = anchor + (start - anchor) × f`, `duration' = duration × f`, where the anchor is the earliest selected start and `f` is the drag-driven factor. If only lengths should scale (starts stay put), change the formula and say so in the tooltip. This is the main open question for this phase.

- [ ] Add a handle overlay, drawn and hit-tested in `MidiEditorOverlays.gd` or as a node in the `NoteEditor` layer. `MidiEditor._note_hit` and `VisualNote.RESIZE_HANDLE_WIDTH` show how hit testing is done there, because notes never take part in GUI picking.
- [ ] Show the handle only when two or more notes are selected, or one note (it duplicates the per-note resize, so probably two or more only). Hide it in Drum View.
- [ ] Handle position: at the right edge of the right-most selected note's end (`max(start + duration)`), vertically on that note. It must track zoom, scroll and selection changes, so reposition it from the same signals the selection overlays use.
- [ ] Drag behaviour:
  - Snap the new group end to the grid via `GridHelper`, as `_on_resize_updated` does for single notes (`_snapped_duration`).
  - Clamp the minimum factor so no note collapses below 1 tick (or a minimum grid step).
  - Work from a snapshot taken at drag start (like `_snapshot_selection`), so repeated mouse moves do not accumulate rounding.
  - Live preview by moving the visuals during the drag, then commit `MidiNoteData` at release.
  - One undo step ("Scale Notes") through `_history_begin_selection` and `_history_commit`.
  - Escape cancels and restores the snapshot.
- [ ] Overlap handling on commit: `cut_overlapping_notes_at_pitch`, as in the nudge functions.
- [ ] Cursor: use a horizontal resize cursor over the handle (`update_hover_cursor`). Handle hit-testing takes priority over note resize and box selection.
- [ ] Looped instances and linked instances: shared `MidiNoteData` is scaled once. Notes in a loop region must stay inside the loop (see `fold_into_loop`).
- [ ] Reuse `NoteTransforms.scale(notes, anchor, factor)`, put in the pure module, so it is unit-testable.
- [ ] Tests (`test_note_group_scale.gd`): factor 2.0 and 0.5, an anchor note that does not move, minimum clamp, the snapshot gives the same result after many drag updates, and cancel restores the original notes.
- [ ] Manual check: handle follows scrolling and zoom, handle disappears when the selection is cleared, and it behaves in both clip mode and track mode.

---

## Out of scope

- Item 2, scale support (highlighted lanes and optional snapping). It likely needs its own spec under `docs/specs/` (project-level scale state, lane rendering in `NoteLanes.gd`, snapping rules), so it is better to track separately.

## Suggested order and commits

1. Phase 1: one commit, then comment on #79 and tick item 1.
2. Phase 2: foundation first (2a), then one commit each for quantize, mirror and strum.
3. Phase 3: pure scale math and tests first, then the handle and drag.

Tick items in #79 only when verified in the running app (`[x?]` until then).
