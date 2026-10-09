# Scale support — Tasks

Implements [design.md](./design.md). Backlog item: [#82](https://github.com/petterthowsen/Sonara/issues/82)
(the backlog lives in GitHub Issues, not `TODO.md`).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — Foundation (pure math and the model)

- [x] **T-001** [REQ-001] `MusicalScale` with the catalogue.
  - _Files_: `Godot/data/MusicalScale.gd` (new), `Godot/tests/test_musical_scale.gd` (new)
  - _Output_: `TYPES`, `make`, `is_none`, `pitch_classes`, `contains`, `is_root`, `display_name`,
    `intervals_for`, `label_for`. Unknown ids fall back to none.
  - _Verify_: `Godot/tests/run_all.sh musical_scale` passes (C pitch classes per type, C Harmonic
    Minor, A Blues, display names).
  - _Depends on_: —

- [x] **T-002** [REQ-014, REQ-015, REQ-016, REQ-017, REQ-019, REQ-021] Scale math in `NoteTransforms`.
  - _Files_: `Godot/clip_editor/note_editor/NoteTransforms.gd`, `Godot/tests/test_scale_snap.gd` (new)
  - _Output_: `snap_pitch`, `scale_base`, `step_in_scale`, `scale_steps_between`,
    `conform_to_scale`. All return their input for an empty `pcs`.
  - _Verify_: `Godot/tests/run_all.sh scale_snap` passes with every example from REQ-014 to
    REQ-017 and REQ-021, plus saturation at 0 and 127, and the keyswitch skip in
    `conform_to_scale`.
  - _Depends on_: T-001

- [x] **T-003** [REQ-019, REQ-022] `ScaleContext`.
  - _Files_: `Godot/clip_editor/ScaleContext.gd` (new), `Godot/tests/test_scale_snap.gd`
  - _Output_: the fields, `changed`, `highlight_active` / `snap_active` / `fold_active`,
    `is_keyswitch`, and the `snap_pitch` / `step` / `steps_between` wrappers.
  - _Verify_: `run_all.sh scale_snap`. The wrappers return their input with scale none, in Drum
    View, and with snap off. Keyswitch pitches are reported.
  - _Depends on_: T-002

- [x] **T-004** [REQ-003, REQ-011, REQ-013, REQ-020] Project scale state and persistence.
  - _Files_: `Godot/data/Project.gd`, `Godot/tests/test_scale_persistence.gd` (new)
  - _Output_: `scale_root`, `scale_type`, `scale_changed`, `set_scale` (validated, no history),
    the `clip_editor_view` dict with setter, getter and signal, and the `to_json` / `from_json` keys.
  - _Verify_: `run_all.sh scale_persistence`. The E Lydian round trip and both flags survive, a
    dict without the keys loads as none with both flags off, and `set_scale` leaves every note
    pitch unchanged (REQ-020).
  - _Depends on_: T-001

- [x] **T-005** [REQ-019] Keyswitch pitches on `NoteMap`.
  - _Files_: `Godot/data/NoteMap.gd`, `Godot/data/NoteMapResolver.gd`, `Godot/tests/test_note_map_sfz.gd`
  - _Output_: `keyswitches`, `is_keyswitch`, copied in `duplicate_map`, filled by `sfz_map`.
  - _Verify_: `run_all.sh note_map` passes, with a new assert that an SFZ keyswitch key shows up in
    `keyswitches` and a plain labelled key doesn't.
  - _Depends on_: —

## Phase 2 — Split folded from drum

- [x] **T-006** [REQ-008, REQ-022] `LaneLayout.is_drum()` and the call-site switch.
  - _Files_: `Godot/clip_editor/LaneLayout.gd`, `Godot/clip_editor/note_editor/NotePlacement.gd`,
    `Godot/clip_editor/note_editor/NoteContainer.gd`, `Godot/clip_editor/note_editor/NoteEditor.gd`,
    `Godot/clip_editor/MidiEditor.gd`, `Godot/clip_editor/NoteLanes.gd`
  - _Output_: `set_rows(pitches, drum := true)` and `is_drum()`. Every "means Drum View" check
    uses `is_drum()`. There is no behaviour change yet.
  - _Verify_: `grep -rn is_folded Godot --include=*.gd` lists only geometry uses. The full
    `Godot/tests/run_all.sh` is green (in particular `drum_view`, `drum_rows`,
    `context_notes_layer`).
  - _Depends on_: —

## Phase 3 — Behaviour in the clip editor

- [x] **T-007** [REQ-005, REQ-006, REQ-007, REQ-009] Lane highlighting.
  - _Files_: `Godot/clip_editor/NoteLanes.gd`, `Godot/clip_editor/ClipEditor.tscn` (export values),
    `Godot/tests/test_scale_lanes.gd` (new)
  - _Output_: `scale_context`, the `in_scale_tint_strength` / `root_accent_strength` exports, static
    `lane_color`, `_draw_lanes` using it with the note map tint on top, and folded non-drum rows
    keeping the white/black base.
  - _Verify_: `run_all.sh scale_lanes` passes the REQ-005, 006 and 007 colour checks.
  - _Depends on_: T-003, T-006

- [x] **T-008** [REQ-008, REQ-010] Fold rows.
  - _Files_: `Godot/clip_editor/ScaleRows.gd` (new), `Godot/clip_editor/DrumRows.gd`,
    `Godot/clip_editor/MidiEditor.gd`, `Godot/tests/test_scale_lanes.gd`
  - _Output_: `ScaleRows.rows_for`, public `DrumRows.collect_clip_pitches`, `MidiEditor` owning
    `scale_context` (wired to lanes, piano and editors), `_rows_folded()`, `compute_rows` /
    `rebuild_rows` / `queue_row_rebuild` / `_apply_view_mode` handling the scale fold, and the
    keyswitch copy in `refresh_note_map`.
  - _Verify_: `run_all.sh scale_lanes drum` passes, including the REQ-008 example rows.
  - _Depends on_: T-005, T-006, T-007

- [x] **T-009** [REQ-012] Folded keyboard header.
  - _Files_: `Godot/components/VPiano.gd`
  - _Output_: in a folded, non-drum layout, one full-row key per visible row, every key labelled,
    and hit-testing by row. Chromatic drawing is unchanged.
  - _Verify_: live check in T-018 (REQ-012). `run_all.sh midi_editor` stays green.
  - _Depends on_: T-008

- [x] **T-010** [REQ-014, REQ-019] Snapped placement.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`
  - _Output_: `_place_note_at_position` snaps with the half-row tie-break unless the pitch is a
    keyswitch or snap is inactive.
  - _Verify_: a headless check in `Godot/tests/test_scale_snap.gd` drives `_place_note_at_position`
    on a NoteEditor with a C Major context. Upper/lower half of C#3 gives 62/60, and a keyswitch
    row keeps its pitch.
  - _Depends on_: T-003, T-008

- [x] **T-011** [REQ-015, REQ-016, REQ-018, REQ-019] Drag by scale steps.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`
  - _Output_: the POSITION branch of `_on_drag_updated` uses `steps_between` / `step` when snap is
    active and Shift is up. Keyswitch notes keep the row delta.
  - _Verify_: a headless drag in `test_scale_snap.gd` (the `_on_drag_started` / `_on_drag_updated`
    pattern from `test_note_drag_alt_axis.gd`). C–E–G dragged one row up gives D–F–A, and C#3 gives
    D#3. Shift is checked live in T-018.
  - _Depends on_: T-010

- [x] **T-012** [REQ-017] Keyboard transpose by scale step.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`, `Godot/tests/test_note_arrow_hotkeys.gd`
  - _Output_: `_move_selection_vertical` takes a step Callable. `_transpose_selection(direction)`
    is used by `notes_transpose_up/down`. The octave keys are unchanged.
  - _Verify_: `run_all.sh note_arrow` passes, with new asserts: A Minor, Up on 59 gives 60, Ctrl+Up
    gives 71, and snap off still gives semitones.
  - _Depends on_: T-011

- [x] **T-013** [REQ-021] Conform to scale.
  - _Files_: `Godot/clip_editor/note_editor/NoteEditor.gd`
  - _Output_: `conform_selection_to_scale()` through `_apply_selection_edit("Conform to Scale", …)`,
    and the `notes_conform_to_scale` key handling.
  - _Verify_: `test_scale_snap.gd` runs it on [61, 63, 66] in C Major, gets [60, 62, 65], and one
    undo restores the notes.
  - _Depends on_: T-003

## Phase 4 — UI and integration

- [x] **T-014** [REQ-002, REQ-004] Main toolbar scale picker.
  - _Files_: `Godot/editor/ScalePicker.gd` (new), `Godot/editor/Editor.tscn`, `Godot/editor/Editor.gd`
  - _Output_: a `Scale` box after `TimeSignature` with the root and type dropdowns, `Editor.set_project_scale` /
    `_apply_scale_silent` with a "Set Scale" PropertyCommand, and a refresh on project open and in
    `_update_transport_ui`.
  - _Verify_: live check in T-018 (REQ-002, REQ-004). `run_all.sh transport` stays green.
  - _Depends on_: T-004

- [x] **T-015** [REQ-011, REQ-013, REQ-018, REQ-021] Clip editor toggles, Conform button, hotkeys.
  - _Files_: `Godot/clip_editor/ClipEditor.gd`, `Godot/clip_editor/ClipEditor.tscn`,
    `Godot/input/HotkeyActions.gd`
  - _Output_: `FoldToScaleToggle` and `ScaleSnapToggle` (both off by default), the `ConformToScale`
    selection tool with a `"scale"` gate, `_bind_project_scale()`, the three hotkey actions, and
    the Shift gesture labels.
  - _Verify_: `run_all.sh hotkeys help_bar` passes (registry has the three ids, no chord
    conflicts, `toggle_scale_snap` is listed in the help bar).
  - _Depends on_: T-004, T-008, T-013

## Phase 5 — Docs and cleanup

- [x] **T-016** [REQ-001] One scale catalogue.
  - _Files_: `Godot/ai/clip_text/ClipTextKey.gd`
  - _Output_: `parse_key` reads its intervals from `MusicalScale.intervals_for`.
  - _Verify_: `run_all.sh clip_text score` (the AI clip text tests under `Godot/ai/tests/`) stays
    green.
  - _Depends on_: T-001

- [x] **T-017** [REQ-all] Glossary and subsystem notes.
  - _Files_: `CONTEXT.md`, `docs/subsystems/godot-architecture.md`
  - _Output_: the five glossary terms, plus the ScaleContext / `is_drum()` note.
  - _Verify_: both files mention every term in requirements.md's Terms section.
  - _Depends on_: T-015

## Phase 6 — Live verification

- [x] **T-018** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: `STATUS.md` (notes), issue #82 (checklist plus a comment)
  - _Output_: the issue checklist updated with `[x]` for what was checked, and a comment listing
    what was and wasn't verified.
  - _Verify_: follow the acceptance lines of REQ-002, 004, 005, 009, 010, 011, 012, 013, 017, 018
    and 022:
    1. Pick D and Dorian in the toolbar dropdowns. The lanes tint and accent
       (REQ-002, 005). Undo restores the previous scale (REQ-004).
    2. Turn on Fold to scale. The header keys line up with the rows (REQ-012). A C#3 note in
       C Major sits on a tinted row (REQ-009). Dragging it away keeps the row until release
       (REQ-010).
    3. With Scale snap on, Up/Down step through the scale and Ctrl+Up moves an octave (REQ-017).
       Shift-drag lands off-scale (REQ-018).
    4. With scale none, and in Drum View, the toggles and Conform are disabled and Drum View
       behaves as before (REQ-011, 013, 022).
    5. Save, reopen, and check that the scale and both toggles are restored.
  - _Depends on_: T-009, T-011, T-012, T-014, T-015, T-017
