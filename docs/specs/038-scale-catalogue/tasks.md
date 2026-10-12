# Scale catalogue — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — catalogue on both sides

- [x] **T-001** [REQ-001] Extend `MusicalScale.TYPES` to the 47 scales plus "none", one entry per
  line, each with `"group"`; add `GROUPS` (order of headings) and `group_for(id)`. New ids are
  snake_case of the label (`dorian_b2`, `lydian_augmented`, `lydian_dominant`, `mixolydian_b6`,
  `half_diminished`, `altered`, `locrian_nat6`, `ionian_sharp5`, `ukrainian_dorian`,
  `phrygian_dominant`, `lydian_sharp2`, `harmonic_major`, `double_harmonic`, `hungarian_minor`,
  `hungarian_major`, `neapolitan_major`, `neapolitan_minor`, `persian`, `enigmatic`,
  `whole_tone`, `diminished_hw`, `diminished_wh`, `augmented`, `bebop_dominant`, `bebop_major`,
  `bebop_dorian`, `major_blues`, `spanish_8_tone`, `egyptian`, `yo`, `hirajoshi`, `in_sen`,
  `iwato`, `kumoi`, `pelog`).
  - _Files_: `Godot/data/MusicalScale.gd`
  - _Output_: 48-entry `TYPES`; old 12 ids unchanged
  - _Verify_: `test_scale_catalogue.gd` catalogue section passes (written in T-004)
  - _Depends on_: —

- [x] **T-002** [REQ-002] Extend `SCALE_TYPE_LABELS` / `SCALE_INTERVALS` to the same 47 entries;
  add `catalogue_matches_godot` (parses `../Godot/data/MusicalScale.gd`, asserts ≥ 47 parsed
  entries and equal labels and intervals) and mask tests for Lydian Dominant, Whole Tone,
  Hirajoshi. Update the module doc comment (sync is now checked here).
  - _Files_: `Engine/src/audio/devices/note_fx/scale.rs`
  - _Output_: engine table matches Godot
  - _Verify_: `cargo test scale` and `cargo test transpose` pass; `cargo fmt`
  - _Depends on_: T-001

- [x] **T-003** [REQ-002] Remove `ENGINE_SCALE_TYPES` and `_test_labels` from the Godot sync test.
  - _Files_: `Godot/tests/test_project_scale_sync.gd`
  - _Output_: no third copy of the list
  - _Verify_: `Godot/tests/run_all.sh project_scale_sync` passes
  - _Depends on_: T-002

## Phase 2 — spelling

- [x] **T-004** [REQ-001, REQ-005] Add `Midi.FLAT_NOTE_NAMES` and the `flats` argument on
  `midi_to_note_name`; add `MusicalScale.uses_flats()`, `note_name()`, `root_name()`; spell
  `display_name()`. Create `test_scale_catalogue.gd` with the catalogue rows, old ids and every
  REQ-005 example.
  - _Files_: `Godot/core/Midi.gd`, `Godot/data/MusicalScale.gd`, `Godot/tests/test_scale_catalogue.gd`
  - _Output_: "Bb Major", "Eb Dorian", "D# Natural Minor" …
  - _Verify_: `godot --headless --path Godot -s tests/test_scale_catalogue.gd -- --test`
  - _Depends on_: T-001

- [x] **T-005** [REQ-006] `ScaleContext.spell_flats()`; `VPiano` key labels and `VisualNote`
  labels use it (`NoteContainer` pushes `spell_flats` on create and on `scale_context.changed`).
  Test: MIDI 70 reads "Bb3" with F Major, "A#3" with no scale and in Drum View.
  - _Files_: `Godot/clip_editor/ScaleContext.gd`, `Godot/components/VPiano.gd`,
    `Godot/clip_editor/VisualNote.gd`, `Godot/clip_editor/note_editor/NoteContainer.gd`,
    `Godot/tests/test_scale_catalogue.gd`
  - _Output_: clip editor note names follow the key
  - _Verify_: `test_scale_catalogue.gd` passes; `Godot/tests/run_all.sh scale` passes
  - _Depends on_: T-004

## Phase 3 — picker

- [x] **T-006** [REQ-003, REQ-004] `MusicalScale.ROOT_LABELS`; `ScalePicker` group separators,
  id-based selection (`get_item_index`, `get_selected_id`). Tests: 7 headings, headings disabled,
  `set_scale_display(3, "hirajoshi")` → `display_text()` "D# Hirajoshi" (spellings tie,
  reference F#), root labels.
  - _Files_: `Godot/data/MusicalScale.gd`, `Godot/editor/ScalePicker.gd`, `Godot/tests/test_scale_catalogue.gd`
  - _Output_: grouped dropdown in toolbar and key change popup
  - _Verify_: `test_scale_catalogue.gd` and `Godot/tests/run_all.sh key_change` pass
  - _Depends on_: T-004

## Phase 4 — migration

- [x] **T-007** [REQ-007] `MusicalScale.LEGACY_TYPE_IDS` and `migrate_v1_type_norm()`;
  `DeviceInstance.migrate_scale_catalogue(data)` (recurses into `"children"`).
  - _Files_: `Godot/data/MusicalScale.gd`, `Godot/data/DeviceInstance.gd`
  - _Output_: helpers, unit-tested on 0.0, 4/11, 1.0
  - _Verify_: `test_scale_catalogue.gd` migration helper section passes
  - _Depends on_: T-001
  - _Note_: migration tests (T-007..T-009) live in `Godot/tests/test_scale_migration.gd`, not `test_scale_catalogue.gd`

- [x] **T-008** [REQ-007] `Project.FORMAT_VERSION := 3`; in `from_json` for `format_version < 3`
  migrate channel device JSON before `Channel.from_json`, and after tracks are built remap
  automation points of lanes targeting a transpose param 12. Update
  `test_note_values_persistence.gd` to expect 3. Test with a version-2 project dict (Transpose
  on Blues, a nested Transpose on Dorian, a lane automating param 12).
  - _Files_: `Godot/data/Project.gd`, `Godot/tests/test_note_values_persistence.gd`,
    `Godot/tests/test_scale_catalogue.gd`
  - _Output_: old projects keep their Transpose scale
  - _Verify_: `Godot/tests/run_all.sh scale note_values` passes
  - _Depends on_: T-007

- [x] **T-009** [REQ-007] `DevicePreset.VERSION := 2`; `instantiate()` migrates `data` and returns'
  channel devices when `file_version < 2`. Test with a version-1 preset dict.
  - _Files_: `Godot/data/DevicePreset.gd`, `Godot/tests/test_scale_catalogue.gd`
  - _Output_: old presets keep their Transpose scale
  - _Verify_: `Godot/tests/run_all.sh scale preset` passes
  - _Depends on_: T-007

## Phase 5 — docs and regression

- [x] **T-010** [REQ-all] Pointer in spec 026 design to this spec; `docs/subsystems/osc-protocol.md`
  unchanged (no new messages), confirm the Transpose param description there (if any) doesn't
  list the 12 scales.
  - _Files_: `docs/specs/026-scale-support/design.md`, `docs/subsystems/osc-protocol.md`
  - _Output_: docs consistent
  - _Verify_: `grep -rn "Major Pentatonic" docs/` shows no stale 12-entry lists
  - _Depends on_: T-006

- [x] **T-011** [REQ-008] Full regression.
  - _Files_: —
  - _Output_: green test suites
  - _Verify_: `cargo test` (Engine) and `Godot/tests/run_all.sh` pass
  - _Depends on_: T-003, T-005, T-006, T-008, T-009

## Phase 6 — live verification

- [x] **T-012** [REQ-all] With the engine and Godot running: pick "Eb Dorian" in the toolbar
  (grouped menu, `D#/Eb` root label); the piano roll highlights the scale and labels show Eb/Bb;
  Transpose on Follow Project snaps notes into it; Transpose Custom + Hirajoshi snaps correctly;
  an old project with Transpose on Blues loads with Blues.
  - _Files_: —
  - _Output_: user confirms
  - _Verify_: user reports the steps above working
  - _Depends on_: T-011
