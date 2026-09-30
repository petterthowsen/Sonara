# Time Signature Changes — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — Engine and wire

- [x?] **T-001** [REQ-010, REQ-011] Engine `TimeSignatureMap`.
  - _Files_: `Engine/src/audio/time_signature_map.rs`, `Engine/src/audio/mod.rs`
  - _Output_: `from_changes` (sort, dedupe by bar, drop invalid) and `segment_at(tick, base_num, base_den, ppq)` returning bar index, bar start tick, numerator, denominator
  - _Verify_: `cargo test time_signature` — base 4/4 with change `(3, 7, 8)`: tick 7679 in bar 2 (4/4), 7680 in bar 3 (7/8), 11040 starts bar 4; invalid entries dropped
  - _Depends on_: —

- [x?] **T-002** [REQ-011, REQ-012] `Transport::at` uses the map.
  - _Files_: `Engine/src/audio/transport.rs`, `Engine/src/audio/processing.rs`, `Engine/src/audio/commands.rs` (`EngineState.time_signature_map`)
  - _Output_: snapshot carries the signature, `bar_number` and `bar_start_beats` in effect at the tick; the callback passes the map
  - _Verify_: `cargo test transport` — existing tests unchanged; new tests at ticks 7679 / 7680 report 4/4 then 7/8; at tick 7680 `bar_number` is 2 and `bar_start_beats` is 8.0; at tick 8160 (one 7/8 beat later) both are unchanged
  - _Depends on_: T-001

- [x?] **T-003** [REQ-010] OSC `/transport/time_signature_map`.
  - _Files_: `Engine/src/osc/server.rs` (handler, `parse_time_signature_map_args`), `Engine/src/audio/commands.rs` (`AudioCommand::SetTimeSignatureMap`, slow-command list), `Engine/src/audio/command_worker.rs` (`set_time_signature_map`, dispatch, `clear_project`)
  - _Output_: the engine holds the map it was sent; no args clears it; log line reports the count
  - _Verify_: `cargo test parse_time_signature_map_args` (valid triples, out-of-range and bar 1 dropped, duplicate bars keep last, empty clears); `cargo build --release`; `cargo fmt`
  - _Depends on_: T-001, T-002

## Phase 2 — Godot model

- [x?] **T-004** [REQ-005, REQ-006, REQ-008, REQ-009] Godot `TimeSignatureMap` model.
  - _Files_: `Godot/data/TimeSignatureMap.gd`
  - _Output_: changes with `add_change` / `update_change` / `remove_change`, `snapshot` / `restore`, JSON, `parse`, cached `segments`, `tick_of_bar`, `bar_at_tick`, `bbt_at_tick`, `signature_at_tick`
  - _Verify_: `Godot/tests/test_time_signature_map.gd` — parser table (`7/8`, ` 3 / 4 ` valid; `0/4`, `4/3`, `4`, `a/b`, `33/4` invalid); bar 3 at tick 7680 and bar 4 at 11040; bbt at 7680+480 is bar 3 beat 2; move stays between neighbours; base 4/4 → 3/4 puts bar 3 at 5760; JSON round trip
  - _Depends on_: —

- [x?] **T-005** [REQ-002, REQ-010, REQ-012] Project owns and syncs the map.
  - _Files_: `Godot/data/Project.gd`, `Godot/history/commands/TimeSignatureMapStateCommand.gd`
  - _Output_: `time_signature_map`, `ruler_lanes["time_signature"] = false`, save/load, `_sync_time_signature_map_to_engine()` on connect and on change; snapshot command
  - _Verify_: extend `Godot/tests/test_ruler_lanes_persist.gd` for `time_signature`; test in `test_time_signature_map.gd` that an old project JSON without the keys loads with an empty map; command do/undo restores the snapshot
  - _Depends on_: T-003, T-004

## Phase 3 — Grid

- [x?] **T-006** [REQ-008, REQ-012, REQ-013] `GridHelper` follows the map.
  - _Files_: `Godot/components/GridHelper.gd`
  - _Output_: `time_signature_map` var (connected like `tempo_map`), segment-based `get_visible_grid_lines()`, segment-relative `snap_ticks()` / `floor_ticks()`, `get_ticks_per_bar_at` / `get_ticks_per_beat_at`, `ticks_to_bbt()` via the map; base getters unchanged
  - _Verify_: grid tests in `test_time_signature_map.gd` — 4/4 → 7/8 at bar 3: bar lines and bar numbers 1, 2, 3, 4; beat lines in bar 3 are 480 ticks apart; a snap just before bar 3 never passes 7680; with an empty map results equal the old ones; `Godot/tests/run_all.sh` passes
  - _Depends on_: T-004

- [x?] **T-007** [REQ-008] Bind the map and fix the BBT readout.
  - _Files_: `Godot/arranger/Arranger.gd` (bind to the grid on project load), `Godot/editor/Editor.gd` (`_update_transport_ui`)
  - _Output_: ruler, timeline grid and the position label follow the map
  - _Verify_: test that a grid built for a project with a map yields bar 4 at 11040 and the readout helper reports bar 4 beat 1 at that tick
  - _Depends on_: T-005, T-006

## Phase 4 — Lane UI

- [x?] **T-008** [REQ-001, REQ-003] Lane, toggle and drawing.
  - _Files_: `Godot/arranger/ruler/TimeSignatureTrack.gd`, `Godot/arranger/ruler/TimeSignatureItem.gd`, `Godot/arranger/Arranger.tscn`, `Godot/arranger/Arranger.gd` (`time_signature_toggle`, `_apply_ruler_row_visibility()`, restore, bind/unbind)
  - _Output_: toggle button; lane between `Ruler` and `TempoTrack`; one labeled flag per change at its bar line
  - _Verify_: Godot test — toggling changes the lane's `visible`; lane holds one item per change and items follow scroll/zoom; item order in the header is `Ruler`, `TimeSignatureTrack`, `TempoTrack`
  - _Depends on_: T-005, T-007

- [x?] **T-009** [REQ-004, REQ-005, REQ-007] Add, edit, delete.
  - _Files_: `Godot/arranger/ruler/TimeSignatureTrack.gd`, `Godot/arranger/ruler/TimeSignatureItem.gd`
  - _Output_: double-click / right-click Add at the nearest bar (bar 1 → bar 2; existing change → edit it), inline `N/D` editing (Enter applies, Escape or invalid keeps), Delete in the item menu; each is one undo step
  - _Verify_: Godot test on the lane's action methods — add at bar 5 while 4/4 gives `(5, 4, 4)`; edit to `7/8` then undo restores `4/4`; invalid text keeps the value; delete then undo restores
  - _Depends on_: T-008

- [x?] **T-010** [REQ-006] Move by dragging.
  - _Files_: `Godot/arranger/ruler/TimeSignatureItem.gd`, `Godot/arranger/ruler/TimeSignatureTrack.gd`
  - _Output_: drag snaps to bar lines within the neighbours (bars 2 up to next − 1); one command on release
  - _Verify_: Godot test on the move method — `(5, 7, 8)` moved to bar 3 sits at bar 3's tick under the earlier map; clamped against neighbours; undo restores
  - _Depends on_: T-009

## Phase 5 — docs

- [x?] **T-011** [REQ-010] Document the message and the lane.
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/godot-architecture.md`, `STATUS.md`, `TODO.md`
  - _Output_: `/transport/time_signature_map` documented (triples, clears on empty, validation); one architecture line; STATUS moves the item out of "Later"; TODO entry added
  - _Verify_: the message appears in the OSC doc; `TODO.md` has the entry
  - _Depends on_: T-003, T-008

## Phase 6 — live verification

- [ ] **T-012** [REQ-all] Verify live with the engine (`Engine/run_release.sh`) and Godot running.
  - _Files_: —
  - _Output_: `TODO.md` entry marked `[x]`; `STATUS.md` notes what was and wasn't checked
  - _Verify_: toggle the lane; add 7/8 at bar 3; bar numbers and beat lines change from bar 3; snap stays on the new beats; edit, drag, delete and undo each work; play across the change with a tempo-synced CLAP plugin and check its bar position; save, reopen, lane and changes are back; `Engine/logs/last_info.log` shows "Time signature map" with the right count. Ask before touching port 7000 or PipeWire settings.
  - _Depends on_: T-010, T-011
