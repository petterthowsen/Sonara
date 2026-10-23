# Stage Mic Setups and Sections — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine and Godot halves are independent after T-001 and can be done in either order. Run build
and test steps one at a time (`CARGO_BUILD_JOBS=2`); no parallel cargo or Godot test agents.

## Phase 1 — Engine: mic setup end to end

- [x] **T-001** [REQ-001, REQ-007] `RoomModel::mic` and `/stage/set`'s 23rd argument.
  - _Files_: `Engine/src/audio/stage/mic.rs` (new: `MicSetup` + `From<i32>` only),
    `Engine/src/audio/stage/mod.rs`, `Engine/src/osc/routes/stage.rs`, `Engine/src/osc/routes/mod.rs`
  - _Output_: `RoomModel { mic, .. }` defaulting to Pan; the route accepts 22 (Pan) or 23 args
  - _Verify_: `cargo test mic_setup_from_osc_value` and `cargo test stage_set` pass (22 → Pan,
    23 → given setup, 24 refused); `cargo test stage::` unchanged and green
  - _Depends on_: —

- [x] **T-002** [REQ-001, REQ-002, REQ-004] `MicArray`: capsules, polar gains, normalization.
  - _Files_: `Engine/src/audio/stage/mic.rs`
  - _Output_: `MicArray::for_setup`, `reads`, `is_spaced`, `coincident_gains` (Pan →
    `StereoPanner`), `capsule_gains`, `capsule_position`, `MAX_CAPSULES`, `MAX_ARRAY_SPAN_M`
  - _Verify_: `cargo test mic::` — `xy_follows_cardioids`, `blumlein_rear_swaps_sides`,
    `blumlein_sides_are_antiphase`, `front_power_matches_pan`, `coincident_capsules_have_no_offset`
  - _Depends on_: T-001

## Phase 2 — Engine: rendering

- [x] **T-003** [REQ-002, REQ-007] Per-capsule `TapRamp` and `Bank::mic`; coincident setups render.
  - _Files_: `Engine/src/audio/stage/source.rs`
  - _Output_: `CapsuleRamp`, per-capsule `TapRamp`, `pan_add` per capsule; `Bank` holds `MicArray`
    and the direct state (`direct_taps`, `direct_valid`, `direct_lp`); `tap_ramp` and
    `render_direct` use `coincident_gains`
  - _Verify_: every existing `cargo test stage::source` test passes unchanged (Pan bit-identical
    path); `render_does_not_allocate` green
  - _Depends on_: T-002

- [x] **T-004** [REQ-003] Spaced setups: per-capsule taps with earliest-arrival referencing.
  - _Files_: `Engine/src/audio/stage/source.rs`
  - _Output_: `render_direct` and `render_bank` call `taps()` / `direct_tap()` per capsule for
    spaced setups; Line history grown by `MAX_ARRAY_SPAN_M`
  - _Verify_: `cargo test ab_time_difference decca_centre_arrives_first` pass;
    `mic_setups_match_pan_level` passes (REQ-004)
  - _Note_: normalization includes each capsule's own distance law at `R_REF`; `mic_setups_match_pan_level` passes at 1.5 dB for all setups (Decca +1.01 dB).
  - _Depends on_: T-003

- [x] **T-005** [REQ-005] Crossfade the direct sound on a mic change.
  - _Files_: `Engine/src/audio/stage/source.rs`
  - _Output_: `Scratch::{direct_l, direct_r}`; during a `Fade` whose bank's mic differs, the direct
    renders from both banks with sin/cos gains; `set_room` with an unchanged mic keeps the direct ramp
  - _Verify_: `cargo test mic_change_crossfades room_change_crossfades position_jump_has_no_step`
  - _Depends on_: T-004

- [x] **T-006** [REQ-006, NFR] Tail independence, allocation and cost checks.
  - _Files_: `Engine/src/audio/stage/tail.rs`, `Engine/src/audio/stage/source.rs`
  - _Output_: `tail_ignores_mic`; `render_does_not_allocate` loops every setup;
    `#[ignore] stage_cost_per_mic_setup`
  - _Verify_: `cargo test tail_ignores_mic render_does_not_allocate`;
    `cargo test --release stage_cost_per_mic_setup -- --ignored --nocapture` shows spaced ≤ 3×
    Pan (record the numbers in this task); `cargo fmt`; full `cargo test` green
  - _Result_ (release, 32 sources, 60 x 40 x 25 m room, 256 frames, 48 kHz, per block of all
    sources): Pan 952 us, XY 984 us (1.03x), Blumlein 905 us (0.95x), M/S 908 us (0.95x),
    AB 1155 us (1.21x), ORTF 1128 us (1.18x), Decca 1345 us (1.41x). Spaced setups are well under 3x.
    Full `cargo test`: 1339 passed, 0 failed, 19 ignored (plus 2 passed in `vst3_host`).
  - _Depends on_: T-005

## Phase 3 — Godot: models

- [x] **T-007** [REQ-008, REQ-020] `VirtualStage.mic_setup`.
  - _Files_: `Godot/data/Stage.gd`, `Godot/tests/test_stage_model.gd`
  - _Output_: `MicSetup`, `MIC_IDS`, `MIC_LABELS`, `set_mic_setup`, 23 `osc_args`, `"mic"` in
    JSON (unknown → Pan), preset switch keeps it, edit marks modified
  - _Verify_: `Godot/tests/run_all.sh stage_model` green (22 → 23 arg assertion updated)
  - _Depends on_: T-001 (wire value)

- [x] **T-008** [REQ-013, REQ-014, REQ-015, REQ-017, REQ-020] Channel depth, display mode, players.
  - _Files_: `Godot/data/Channel.gd`, `Godot/data/Stage.gd` (constants), `Godot/tests/test_stage_model.gd`
  - _Output_: `StageDisplay`, `stage_depth` / `stage_display` / `stage_players` in
    `get_stage_state` / `set_stage_state` (clamped), 2 m default from `place_in_stage_from_pan`
  - _Verify_: `Godot/tests/run_all.sh stage_model` — defaults, old `stage` block without the keys,
    depth-only change leaves the `/channel/{id}/stage` args identical, JSON round trip, undo
  - _Depends on_: —

## Phase 4 — Godot: edit operations

- [x] **T-009** [REQ-009] Snapping in `StageEdit`.
  - _Files_: `Godot/stage/StageEdit.gd`, `Godot/tests/test_stage_edit.gd`
  - _Output_: `snap_point`, `snap_length`; `move_by(..., anchor, step)`; `drag_end(..., snap_deg, length_step)`
  - _Verify_: `Godot/tests/run_all.sh stage_edit` — (3.37, 4.81) → (3, 5) / (3.4, 4.8); size
    2.6 → 3.0 / 2.6; rotation 22° → 15° / 22°; multi-move keeps offsets
  - _Depends on_: —

- [x] **T-010** [REQ-011, REQ-012] Rectangle geometry and depth edits.
  - _Files_: `Godot/stage/StageEdit.gd`, `Godot/tests/test_stage_edit.gd`
  - _Output_: `corners`, depth-aware `half_extent` / `clamp_state`, `drag_edge`, `set_depth`
  - _Verify_: `Godot/tests/run_all.sh stage_edit` — corners of a 30°-rotated source; depth drag on a
    rotated source; clamp at the back wall; existing cases still pass
  - _Depends on_: T-008, T-009

- [x] **T-011** [REQ-016, REQ-017, REQ-018, REQ-019] Section layout and minimum.
  - _Files_: `Godot/stage/StageEdit.gd`, `Godot/tests/test_stage_edit.gd`
  - _Output_: `section_grid`, `player_positions`, `section_fits`, `fit_section`, `set_display`,
    `set_players`; size/depth edits stop at the minimum in Section mode
  - _Verify_: `Godot/tests/run_all.sh stage_edit` — 12 in 8 × 2.4 → 6 × 2, all inside, even
    spacing; 12 at 6 × 2.4 shrink to 4 → stops at 6; 16 from 6 × 2.4 → depth 3.6; 64 in a 4 × 3 m
    room → clamped, no error; players clamped to 1–64; layout of an automated undersized source works
  - _Depends on_: T-010

## Phase 5 — Godot: view

- [x] **T-012** [REQ-011, REQ-012, REQ-016] Canvas: rectangles, player icons, edge handles.
  - _Files_: `Godot/stage/StageCanvas.gd`
  - _Output_: Block fill / Section outline + icons, dots at size 0, inside-rectangle hit test,
    `Drag.EDGE`, updated tooltip
  - _Verify_: `Godot/tests/run_all.sh stage_view` green; drawing checked live in T-017
  - _Depends on_: T-011

- [x] **T-013** [REQ-009, REQ-010] Canvas snapping and the Snap toggle.
  - _Files_: `Godot/stage/StageCanvas.gd`, `Godot/stage/StageView.gd`, `Godot/stage/StageView.tscn`,
    `Godot/tests/test_stage_view.gd`
  - _Output_: `snap_enabled` from `Sonara.get_config("stage_view/snap", true)`; Shift = fine step;
    toggle in the view writes the config
  - _Verify_: `Godot/tests/run_all.sh stage_view` — toggle round-trips through the config
  - _Depends on_: T-009, T-012

- [x] **T-014** [REQ-008, REQ-012, REQ-015, REQ-017] Panels: Mic option, Depth, Display, Players.
  - _Files_: `Godot/stage/StageView.gd`, `Godot/stage/StageView.tscn`, `Godot/tests/test_stage_view.gd`
  - _Output_: room panel Mic option via `_edit_room`; source panel Depth spin, Display option,
    Players spin (visible in Section) via `_edit_source_states`
  - _Verify_: `Godot/tests/run_all.sh stage` green — Players spin hidden for Block, shown for Section
  - _Depends on_: T-007, T-011

## Phase 6 — docs

- [x] **T-015** [REQ-001] Protocol and architecture docs, ADR.
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/engine-architecture.md`,
    `docs/adr/0025-stage-mic-capsules.md`
  - _Output_: `/stage/set` 23rd argument documented (and the 22-arg fallback); stage pass bullet
    mentions mic setups; ADR written
  - _Verify_: `grep -n "mic" docs/subsystems/osc-protocol.md` shows the argument; ADR lists the
    rejected alternative
  - _Depends on_: T-006

- [x] **T-016** [REQ-all] Glossary and changelog.
  - _Files_: `CONTEXT.md`, `CHANGELOG.md`
  - _Output_: glossary terms from the requirements; two `## [Unreleased]` lines
  - _Verify_: terms present; changelog lines under Unreleased
  - _Depends on_: T-014

## Phase 7 — live verification

- [ ] **T-017** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: —
  - _Output_: notes on what was and wasn't checked, in this task
  - _Verify_: View > Stage with several sources. Snapping steps (1 m, Shift 0.1 m, 15°/1°) and the
    toggle; rectangle and edge drags; Section icons at several zoom levels; a section won't shrink
    below its players; mic setups switched during playback without clicks; Blumlein's swapped rear
    reflections and AB/Decca width are audible; engine load with a spaced setup and ~30 sources
  - _Depends on_: T-006, T-014
