# Scale support — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/data/Project.gd`: the project model. Persisted view state already lives here as
  `ruler_lanes` and `arranger_view`, with `set_arranger_view` / `get_arranger_view`, the
  `arranger_view_changed` signal, and per-key fallback in `from_json`. The time signature is set
  through `Editor.set_time_signature`, which records a `PropertyCommand` and applies the change
  through `_apply_time_signature_silent`.
- `Godot/editor/Editor.tscn` / `Editor.gd`: the main toolbar's
  `VBoxContainer/Header/Top/Transport/TransportStatus/HBox/Options` box holds `Tempo` (SpinBox)
  and `TimeSignature` (LineEdit). `Editor.project_opened` fires when a project is opened.
- `Godot/clip_editor/LaneLayout.gd`: the shared pitch ↔ row ↔ Y math. `set_rows()` folds to an
  arbitrary list of pitches and `step_pitch()` walks the visible rows. **`is_folded()` doubles as
  "this is Drum View"**. That's true at `NotePlacement.note_rect` / `repeat_rect` / `visual_y`,
  `NoteContainer` (`set_drum_mode`), `NoteEditor._place_note_at_position` / `_on_drag_updated` /
  `flip_selection_vertical`, `MidiEditor.value_stems` and `NoteLanes._draw_lanes`.
- `Godot/clip_editor/MidiEditor.gd`: owns `lane_layout`, `note_map`, `drum_view`, and hands the
  layout to `v_piano`, `note_lanes`, `context_layer`, `drum_row_header` and every note editor
  (`_configure_note_editor`). `compute_rows()` / `rebuild_rows()` / `queue_row_rebuild()` /
  `on_interaction_finished()` rebuild the folded rows and defer the rebuild while a drag runs.
  `_apply_view_mode()` switches between `set_rows()` and `set_chromatic()`.
- `Godot/clip_editor/DrumRows.gd`: `rows_for(map, clips)` gives the union of the mapped pitches and
  the used pitches. `_collect_clip_pitches` reads notes duck-typed.
- `Godot/clip_editor/NoteLanes.gd`: draws the lanes. White/black colour per row, then `_tinted()`
  blends in the note map colour.
- `Godot/components/VPiano.gd`: the keyboard header. `_draw()` loops over all 128 keys and
  `get_note_rect()` grows the white keys around the black ones, so it assumes the chromatic layout.
- `Godot/clip_editor/note_editor/NoteEditor.gd`: `_place_note_at_position` (placement),
  `_on_drag_updated` (vertical drag: `delta_steps` from rows, then `step_note`; Shift bypasses
  snapping through `_snap_unless_shift`), `_move_selection_vertical(semitones)` (the transpose and
  octave hotkeys), and `_apply_selection_edit(history_name, edit)` (the shared path for selection
  tools).
- `Godot/clip_editor/note_editor/NoteTransforms.gd`: static pure note math, tested headless.
- `Godot/clip_editor/ClipEditor.gd`: the bottom toolbar. `ToggleGroup` (`AuditionToggle`),
  `ModeGroup` (`ModeSwitch`, `NoteMapButton`), `ToolsGroup` with `_register_selection_tool()` and
  `_sync_selection_tools()`.
- `Godot/data/NoteMap.gd` / `NoteMapResolver.sfz_map`: an SFZ Auto map holds an entry for every
  labelled key, keyswitches included. A keyswitch can only be told apart by its colour today.
- `Godot/input/HotkeyActions.gd`: `ACTIONS` (registry rows) and `GESTURES` (help-bar mouse
  entries, including `note_hover` / `note_drag` / `note_drag_alt` "Shift: move freely (no snap)").
- `Godot/ai/clip_text/ClipTextKey.gd`: private interval tables `_MAJOR`, `_MINOR`, `_DORIAN`,
  `_MIXO` used by `parse_key`.

## Approach

**A pure `MusicalScale` value plus a shared `ScaleContext`.** `MusicalScale` (root and type id)
owns the catalogue and answers pitch-class questions. The snapping math is static in
`NoteTransforms`, as the issue asks. `MidiEditor` owns one `ScaleContext` and hands it to its
views and note editors, the same way it shares `lane_layout`. The context holds the current scale,
the snap and fold flags, Drum View, and the keyswitch pitches, and it emits `changed`. Views read
from it and never read the project directly. `ClipEditor` copies the project's scale and toggles
into the context. The alternative was to put the scale on `LaneLayout`, which every view already
holds. I rejected it because the layout is geometry, and the fold rows already flow into it
through `set_rows()`.

**Split "folded" from "drum".** `LaneLayout.set_rows(pitches, drum := true)` records a separate
`_drum` flag behind a new `is_drum()`. Every call site listed above that means "Drum View" switches
to `is_drum()`. `is_folded()` keeps meaning "rows are a list". So a scale fold gets row walking,
hidden pitches and deferred rebuilds for free, while it still renders as a piano roll: note bars,
a white/black base colour and lengths. `step_pitch()` is unchanged.

**Fold rows reuse the Drum View pipeline.** `MidiEditor.compute_rows()` returns
`ScaleRows.rows_for(scale, clips)` when the fold is active. That's every in-scale pitch plus the
used pitches, with clips collected through `DrumRows` (whose `_collect_clip_pitches` becomes
public as `collect_clip_pitches`). The deferral in `rebuild_rows()` already covers REQ-010.
`rebuild_rows()` / `queue_row_rebuild()` gate on a new `_rows_folded()`
(`drum_view or scale fold active`) instead of `drum_view`.

**Scale steps (REQ-015 to REQ-017).** `NoteTransforms.step_in_scale(pitch, steps, pcs)` finds the
in-scale *base* at or below the pitch, walks `steps` in-scale pitches from it, and adds back the
original offset. If the result leaves 0 to 127, it saturates to the highest or lowest reachable
in-scale pitch plus the offset, clamped. During a drag the cursor sets the step count:
`target = snap_pitch(y_to_pitch(mouse), upper_half)`, then
`steps = NoteTransforms.scale_steps_between(base(drag_start_note), target, pcs)`. Every selected
note, the dragged one included, then becomes `step_in_scale(start_note, steps)`. An in-scale
dragged note lands exactly on `target`, and an out-of-scale one keeps its offset, so REQ-015 and
REQ-016 agree. Keyswitch notes move by the plain row delta (`step_note`), as they do today.

**Placement tie-break (REQ-014).** `NoteTransforms.snap_pitch(pitch, pcs, prefer_up)` returns the
nearest in-scale pitch, and `prefer_up` breaks ties. `NoteEditor` computes `prefer_up` as
`fposmod(pos.y, row_height) < row_height * 0.5`. Conform to scale (REQ-021) calls `snap_pitch`
with `prefer_up = false`.

**What snapping does in the fold with scale snap off.** Vertical moves keep their current folded
behaviour and walk the visible rows (`step_pitch`, the Drum View rule from spec 020 REQ-020). In
the fold, that skips hidden out-of-scale pitches. This is the "as before" path for a folded layout.

**Keyswitches.** `NoteMap` gains a non-serialized `keyswitches: PackedInt32Array`, filled by
`NoteMapResolver.sfz_map` from `info.keyswitch`, the same way `playable_ranges` is filled.
`MidiEditor.refresh_note_map()` copies it into the context.

**Toolbar picker.** `ScalePicker` is an `HBoxContainer` in the `Options` box after
`TimeSignature`, holding two flat `OptionButton`s: the root (the 12 `Midi.NOTE_NAMES`, disabled
while the type is None) and the type (the catalogue labels, None shown as "No scale"). Picking
either calls `Sonara.editor.set_project_scale(root, type_id)` (not `set_scale`, which `Control`
already defines). It records a `PropertyCommand`, mirroring `set_time_signature`.

## Thread and ownership

All of this lives on the Godot main thread. There is no engine, OSC or audio-thread state.

| State | Owner | Reached from | Real-time safe |
|---|---|---|---|
| `Project.scale_root`, `scale_type` | `Project` | `Editor.set_project_scale` (undoable), `ClipEditor` via `scale_changed` | n/a (UI only) |
| `Project.clip_editor_view` flags | `Project` | `ClipEditor` toggles via `set_clip_editor_view` | n/a |
| `ScaleContext` | `MidiEditor` | NoteLanes, VPiano, NoteEditor (assigned in `_configure_note_editor`) | n/a |

## Data and protocol changes

No OSC messages. No `sync_to_engine()` changes, because the scale is never sent.

> **Amended by spec 027 (note effects).** The project scale now does reach the engine, as a
> 12-bit pitch-class mask on `/project/scale` (`MusicalScale.mask()`), so the Transpose note effect
> can follow it. `Project.set_scale` sends it after updating state and project sync sends it after
> `/project/init`. Everything else here stays UI-only: the engine never sees the root or type id.

**Project model** (`Godot/data/Project.gd`):

- `var scale_root: int = 0` (pitch class 0 to 11, 0 = C) and `var scale_type: String = "none"`
  (a `MusicalScale` type id).
- `signal scale_changed(root: int, type_id: String)` and `func set_scale(root, type_id)`. The setter
  validates its input (an unknown id becomes `"none"`, the root wraps into 0 to 11), updates the
  state and emits the signal. It never pushes history (CONTEXT.md: data setters never record
  history).
- `var clip_editor_view: Dictionary = {"fold_to_scale": false, "scale_snap": false}` with
  `set_clip_editor_view(key, value)`, `get_clip_editor_view(key)` and
  `signal clip_editor_view_changed(key, value)`, copied from the `arranger_view` trio. It is not
  undoable.
- `to_json`: `"scale": {"root": scale_root, "type": scale_type}` and
  `"clip_editor_view": clip_editor_view.duplicate()`. `from_json` reads both, defaulting per key the
  way `arranger_view` does. `FORMAT_VERSION` stays 2 because the keys are additive and default
  safely.

**Scale type ids** (stable strings so the file survives reordering):
`none, major, natural_minor, harmonic_minor, melodic_minor, dorian, phrygian, lydian, mixolydian,
locrian, major_pentatonic, minor_pentatonic, blues`.

**Hotkeys** (`HotkeyActions.ACTIONS`, context `clip_editor`, group "Clip Editor"):

| id | label | default |
|---|---|---|
| `toggle_scale_snap` | Toggle scale snap | none (help-bar entry shown) |
| `toggle_fold_to_scale` | Toggle fold to scale | none |
| `notes_conform_to_scale` | Conform notes to scale | none, `requires: note_selection` |

`GESTURES`: the `note_hover` "move / resize without snap" label and the two `note_drag*`
"move freely (no snap)" labels become "move freely (no grid or scale snap)", and the `note_hover`
one becomes "move / resize without grid or scale snap".

## File-by-file change list

| File | Change |
|---|---|
| `Godot/data/MusicalScale.gd` | **New.** `class_name MusicalScale extends RefCounted`. `const TYPES` (ordered `{id, label, intervals}` rows for the catalogue in REQ-001), `var root`, `var type_id`, `static func make(root, type_id)`, `is_none()`, `pitch_classes() -> PackedInt32Array` (sorted, empty for none), `contains(pitch) -> bool`, `is_root(pitch) -> bool`, `display_name()` ("D Dorian" / "No scale"), `static func intervals_for(type_id)`, `static func label_for(type_id)`. |
| `Godot/clip_editor/ScaleContext.gd` | **New.** `class_name ScaleContext extends RefCounted`, `signal changed`. Fields `scale: MusicalScale`, `snap_enabled`, `fold_enabled`, `drum_view`, `keyswitches: PackedInt32Array` (each setter emits `changed`). `highlight_active()` (scale set and not Drum View), `snap_active()`, `fold_active()`, `is_keyswitch(pitch)`. Thin wrappers `snap_pitch(pitch, prefer_up)` / `step(pitch, steps)` / `steps_between(from, to)` that return the input unchanged when inactive (the REQ-022 no-op), else delegate to `NoteTransforms`. |
| `Godot/clip_editor/note_editor/NoteTransforms.gd` | Add static `snap_pitch(pitch, pcs, prefer_up) -> int`, `scale_base(pitch, pcs) -> int`, `step_in_scale(pitch, steps, pcs) -> int`, `scale_steps_between(from, to, pcs) -> int`, `conform_to_scale(notes, pcs, keyswitches) -> int` (returns how many changed). All take `pcs: PackedInt32Array` so they stay scene-free. An empty `pcs` returns the input. |
| `Godot/clip_editor/ScaleRows.gd` | **New.** `class_name ScaleRows`, `static func rows_for(scale: MusicalScale, clips: Array) -> PackedInt32Array`: the in-scale pitches 0 to 127 ∪ the used pitches (via `DrumRows.collect_clip_pitches`). |
| `Godot/clip_editor/DrumRows.gd` | Rename `_collect_clip_pitches` to `collect_clip_pitches` (public) and update its two callers in this file. |
| `Godot/clip_editor/LaneLayout.gd` | Add `_drum` and `is_drum()`. `set_rows(pitches, drum := true)` records it, and the early-out compares it too. `set_chromatic()` clears it. Update the header comment. |
| `Godot/clip_editor/note_editor/NotePlacement.gd` | `is_folded()` → `is_drum()` in `note_rect`, `repeat_rect`, `visual_y`. |
| `Godot/clip_editor/note_editor/NoteContainer.gd` | `set_drum_mode(layout.is_folded())` → `is_drum()` (two places). Add `var scale_context: ScaleContext` (defaults to an inactive instance). |
| `Godot/clip_editor/note_editor/NoteEditor.gd` | `is_folded()` → `is_drum()` at the three Drum View checks. **Placement:** after `y_to_note`, if `scale_context.snap_active()` and the pitch isn't a keyswitch, snap with the half-row `prefer_up`. **Drag:** in the POSITION branch, if `snap_active()` and Shift isn't held, compute `steps` from the snapped cursor target and set each note to `scale_context.step(start_pos.note, steps)`. Keyswitch notes keep `step_note(start, delta_steps)`. **Keyboard:** `notes_transpose_up/down` call a new `_transpose_selection(direction)` that uses `scale_context.step(note, ±1)` when `snap_active()`, else `_move_selection_vertical(±1)`. Refactor `_move_selection_vertical` to take a `step: Callable(pitch) -> int` so both share the overlap, sync and history code. **Conform:** `conform_selection_to_scale()` through `_apply_selection_edit("Conform to Scale", …)`. Handle `notes_conform_to_scale` in `handle_key_input`. |
| `Godot/clip_editor/NoteLanes.gd` | Add `var scale_context: ScaleContext` (connects `changed` → `queue_redraw`), exports `in_scale_tint_strength` (tint: theme role `accent_secondary`) and `root_accent_strength` (tonic: theme role `accent_primary`); roles (cached via `UiColors.role`, refreshed on `NOTIFICATION_THEME_CHANGED`). Add `static func lane_color(pitch, base_white, base_black, scale_pcs, root, out_tint, accent) -> Color` (pure, for REQ-005/006 tests). `_draw_lanes` uses it when `highlight_active()`, and draws `_tinted` on top (REQ-007). Folded-but-not-drum rows use the white/black base (`is_drum()` for the alternating colours). Every folded row (drum or scale) gets a full separator line instead of the E/F and B/C borders. |
| `Godot/components/VPiano.gd` | When `layout.is_folded()` and not `is_drum()`, draw one full-row key per visible row (`get_note_rect` returns the plain row rect, and `_draw` loops over `layout.rows()`), keep the white/black colour, label every key with its pitch name (REQ-012), and hit-test by row in `get_note_at_position`. The chromatic drawing is unchanged. |
| `Godot/clip_editor/MidiEditor.gd` | Own `var scale_context := ScaleContext.new()`. Assign it to `note_lanes`, `v_piano` and each editor in `_configure_note_editor`. Keep `scale_context.drum_view` in sync in the `drum_view` setter. In `refresh_note_map()`, copy `note_map.keyswitches`. `is_folded()` → `is_drum()` in `value_stems`. Add `_rows_folded()`. `compute_rows()` picks `ScaleRows` vs `DrumRows`. `rebuild_rows`, `queue_row_rebuild` and `_apply_view_mode` use `_rows_folded()` and call `set_rows(rows, drum_view)`. Connect `scale_context.changed` to re-run `_apply_view_mode()` when `fold_active()` flips, and to `rebuild_rows()` when the scale changes while folded. |
| `Godot/clip_editor/ClipEditor.gd` / `ClipEditor.tscn` | Add `FoldToScaleToggle` and `ScaleSnapToggle` (toggle buttons) to `ToggleGroup`, and a `ConformToScale` button to `ToolsGroup`. `_bind_project_scale()` on `_editor.project_opened` and in `_ready`: connect `project.scale_changed` / `clip_editor_view_changed`, push into `midi_editor.scale_context`, sync the toggles. The toggles call `project.set_clip_editor_view`. They are disabled when the scale is none or in Drum View, refreshed from `view_state_changed`. Handle `toggle_scale_snap` / `toggle_fold_to_scale` in `_unhandled_key_input`. Register Conform with `_register_selection_tool(..., false)` and extend the entry with `"scale": true` so `_sync_selection_tools` also disables it when the scale is none. |
| `Godot/editor/ScalePicker.gd` | **New.** `class_name ScalePicker extends HBoxContainer`: the root and type dropdowns built in code, `set_scale_display(root, type_id)` (no emit), `display_text()`, and emits `scale_picked(root, type_id)`. |
| `Godot/editor/Editor.tscn` / `Editor.gd` | Add a `Scale` node (`ScalePicker`) after `TimeSignature` in `Options`. `@onready var scale_picker`. Connect `scale_picked` → `set_project_scale`. Add `set_project_scale(root, type_id)` + `_apply_scale_silent(value)` (PropertyCommand "Set Scale", `_mark_modified()`). Refresh the picker in `_update_transport_ui()` and when a project opens. |
| `Godot/data/NoteMap.gd` | Add `var keyswitches := PackedInt32Array()` (not serialized, documented like `playable_ranges`), plus `is_keyswitch(pitch)`. Copy it in `duplicate_map()`. |
| `Godot/data/NoteMapResolver.gd` | `sfz_map`: append `info.key` to `map.keyswitches` when `info.keyswitch`. |
| `Godot/input/HotkeyActions.gd` | The three `ACTIONS` rows and the `GESTURES` label edits above. |
| `Godot/ai/clip_text/ClipTextKey.gd` | Replace `_MAJOR` / `_MINOR` / `_DORIAN` / `_MIXO` with `MusicalScale.intervals_for(...)` so there is one catalogue. `parse_key` output is unchanged. |
| `CONTEXT.md` | Add **Project scale**, **In-scale pitch**, **Scale step**, **Scale snap**, **Fold to scale** under "Godot data model". |
| `docs/subsystems/godot-architecture.md` | A short "Scale support" note: ScaleContext ownership, the folded vs drum split in LaneLayout. |

## Migration and compatibility

Older projects have neither `scale` nor `clip_editor_view`. `from_json` defaults them to
none/C and both flags off, so nothing changes visually (REQ-006). Older builds ignore the new keys.
`config.json` is untouched.

## Test plan

New headless scripts extend `TestBase` and run with `Godot/tests/run_all.sh <word>`.

- **`Godot/tests/test_musical_scale.gd`**: every type's pitch classes for C (REQ-001), the
  REQ-001 examples (C Harmonic Minor, A Blues), `display_name`, and an unknown id falling back to
  none.
- **`Godot/tests/test_scale_snap.gd`**: `NoteTransforms.snap_pitch` (REQ-014 examples, both tie
  directions), `step_in_scale` (REQ-015 C–E–G → D–F–A, REQ-016 61 → 63, REQ-017 59 → 60 in
  A minor, saturation at 0 and 127), `scale_steps_between`, `conform_to_scale` (REQ-021
  [61, 63, 66] → [60, 62, 65], keyswitch skipped per REQ-019), and `ScaleContext` returning its
  input when the scale is none or in Drum View (REQ-022). It also checks that changing the scale
  leaves notes alone (REQ-020).
- **`Godot/tests/test_scale_lanes.gd`**: `NoteLanes.lane_color` for in-scale, out-of-scale and
  root lanes (REQ-005), no change with none (REQ-006), and a mapped lane differing (REQ-007).
  `ScaleRows.rows_for` gives the REQ-008 example.
- **`Godot/tests/test_scale_persistence.gd`**: `Project.to_json` / `from_json` round trip of
  E Lydian and both flags (REQ-003, REQ-011, REQ-013), and a dictionary without the keys loading
  as none with flags off.
- **Existing:** `test_drum_view.gd`, `test_drum_rows.gd`, `test_context_notes_layer.gd`,
  `test_note_arrow_hotkeys.gd`, `test_hotkeys_registry.gd`, `test_help_bar.gd`,
  `test_note_map_sfz.gd` (extended: `keyswitches` filled), and the full `run_all.sh` must stay
  green after the `is_drum()` split.
- **Live** (engine and Godot running): REQ-002, 004, 005, 009, 010, 011, 012, 013, 017, 018 and 022
  as written in their acceptance lines.

## Risks

| Risk | Mitigation |
|---|---|
| Missing an `is_folded()` call site that means "drum" makes the scale fold render as hits | The call sites are listed above. `grep is_folded` after the change should leave only geometry uses (LaneLayout, NoteLanes border loop, VPiano). `test_drum_view.gd` guards the Drum View side |
| VPiano's folded drawing drifts from the lanes | Both read the same `layout.row_to_y`. Checked live (REQ-012) |
| A scale change while folded reshuffles rows mid-drag | `rebuild_rows()` already defers during interaction |
| `step_in_scale` saturation collapses a chord at the keyboard edges | Accepted. The existing chromatic move clamps the same way |

## Open questions

- [x] REQ-015 (out-of-scale dragged note follows REQ-016) and the folded-with-snap-off row walking
  are written into requirements.md (approved). Fold to scale stays optional and off by default.
