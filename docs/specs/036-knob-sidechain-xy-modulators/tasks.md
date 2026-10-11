# Knob, Sidechain and XY modulators — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — kinds and state (engine)

- [x] **T-001** [REQ-001, REQ-002] Append `ModulatorKind::Knob` (`knob`,
  "Knob"): param 0 Value `linear(0,1)` default 0, param 10 Polarity
  `Enum["Unipolar","Bipolar"]`; `value()` = `2x − 1` when Bipolar; no DSP.
  - _Files_: `Engine/src/audio/modulation/kinds.rs`, `state.rs`
  - _Output_: `from_id("knob")` round-trips; a knob route offsets a Delay Mix
    by +0.125 (unipolar) / −0.25 (bipolar) at knob 0.25, amount 0.5.
  - _Verify_: `cargo test modulation`
  - _Depends on_: —

- [x] **T-002** [REQ-003] Append `XyX` (`xyx`, "XY X") and `XyY` (`xyy`,
  "XY Y"): param 0 Position `linear(0,1)` default 0.5; `bipolar() == true`;
  `value()` = `2·pos − 1`; poly-eligible.
  - _Files_: `Engine/src/audio/modulation/kinds.rs`, `state.rs`
  - _Output_: default value 0; both kinds route through the matrix.
  - _Verify_: `cargo test modulation`
  - _Depends on_: T-001 (append order)

- [x] **T-003** [REQ-006, REQ-007, REQ-008, REQ-009] Append `Sidechain`
  (`sidechain`): Low Cut, High Cut, Attack, Release, Source (`linear(0,999)`
  channel id, 0 = Device In); `ScState` (2× `Svf`, cached coefs,
  `EnvFollower` Peak); `feed_sidechain(mono)`; −60…0 dBFS → 0…1 `value()`;
  cuts bypass at extremes; `is_mono_only()` covers it; `COUNT == 12`.
  Device In: pass the step's inputs into `control_step_impl` from all three
  call sites and feed Source-0 sidechains (chunked for the whole-block path).
  - _Files_: `Engine/src/audio/modulation/{kinds,state,host}.rs`
  - _Output_: filter, level-map, Device In (incl. `process_block_with_extra`
    with a 256-frame block) and never-sleeps tests pass.
  - _Verify_: `cargo test modulation`
  - _Depends on_: T-002

- [x] **T-004** [REQ-006] Cross-channel taps: `SidechainTaps` in
  `EngineState`; command-thread rebuild (allocate unlocked, swap under lock,
  drop via `CommandEffects`) on modulator add/remove, Source change,
  channel/device add/remove/move and `/project/init`; snapshot at the end of
  `mix_and_output`; feed at block start; missing paths/channels skipped.
  - _Files_: `Engine/src/audio/mixing/{sidechain,mod}.rs`,
    `Engine/src/audio/{engine,state}.rs`,
    `Engine/src/audio/command_worker/*.rs`, `modulation/host.rs`
  - _Output_: source = B follows B one block late; deleting B → value decays
    to 0, no panic; two subscribers on B share one slot.
  - _Verify_: `cargo test sidechain` + `cargo test modulation`
  - _Depends on_: T-003

- [x] **T-005** [REQ-011] Payload and advertisement: `kind 2` rows for the
  four kinds; `/builtin/modulator_info` count 12; existing kind indices
  unchanged.
  - _Files_: `Engine/src/audio/modulation/host.rs`, `Engine/src/osc/encode.rs`
    (tests only)
  - _Verify_: `cargo test modulation` + `cargo test modulator_kind`
  - _Depends on_: T-003

## Phase 2 — Godot model

- [x] **T-006** [REQ-002] `Modulator.is_bipolar()` (knob reads Polarity);
  `DeviceInstance.get_routes_into` uses it.
  - _Files_: `Godot/data/Modulator.gd`, `Godot/data/DeviceInstance.gd`
  - _Output_: Bipolar knob routes report `bipolar = true`.
  - _Verify_: `Godot/tests/run_all.sh device_modulators`
  - _Depends on_: T-001

- [x] **T-007** [REQ-003] `XYPad` model; `add_xy_pad` (needs 2 free ids,
  appends `xyx` then `xyy`, names "XY Pad…"/"… Y"), `remove_xy_pad`,
  `duplicate_xy_pad`, pair rename, `move_modulator_block`, `xy_pairs`.
  - _Files_: `Godot/data/XYPad.gd` (new), `Godot/data/DeviceInstance.gd`
  - _Output_: add → 2 adjacent entries; 7 used → refused; delete →
    0; duplicate/rename keep pairs; save/load round-trips.
  - _Verify_: `Godot/tests/run_all.sh device_modulators`
  - _Depends on_: T-002

## Phase 3 — pane, tile, display

- [x] **T-008** [REQ-003, REQ-004, REQ-010] Pair-aware `_rebuild_grid`
  (orphans → plain tiles); `+` menu hides `xyy`, lists `xyx` as "XY Pad" →
  `add_xy_pad`; `ModulatorPanel.setup_pair` with X/Y wire buttons;
  `_sync_wires`; flat + colour overrides on all wire buttons; pair routes in
  the tile menu; `ModulatorDrag` moves pairs via `move_modulator_block`.
  - _Files_: `Godot/devices/modulators/{ModulatorsPane,ModulatorPanel,ModulatorDrag}.gd`
  - _Output_: one tile with X + Y; X → assign from `xyx` with the X colour;
    drags keep pairs adjacent; plain tiles unchanged.
  - _Verify_: `Godot/tests/run_all.sh modulators_ui`
  - _Depends on_: T-007

- [x] **T-009** [REQ-005] `XYPadPanel`: compact `XYSlider` display,
  `values_changed` → `set_position`, live dot from both slots, pad presses
  isolated from tile select/drag.
  - _Files_: `Godot/devices/modulators/XYPadPanel.gd` (new), `ModulatorPanel.gd`
  - _Output_: `set_values(0.3, 0.8)` writes both slots' param 0.
  - _Verify_: `Godot/tests/run_all.sh modulators_ui`
  - _Depends on_: T-008

- [x] **T-010** [REQ-001, REQ-005, REQ-006] Detail column: `knob`
  (`KNOB_ORDER`), pair (140×140 `XYSlider`), `sidechain` (`SC_ORDER` +
  Source `OptionButton` of Device In + channels by id, refreshed on channel
  changes, "(missing channel)"); `ModulatorDisplay` `knob` glyph.
  - _Files_: `Godot/devices/modulators/{ModulatorsPane,ModulatorDisplay}.gd`
  - _Output_: each kind's options render; Source writes the channel id.
  - _Verify_: `Godot/tests/run_all.sh modulator`
  - _Depends on_: T-006, T-009

## Phase 4 — docs

- [x] **T-011** [REQ-all] Update `docs/subsystems/osc-protocol.md` (kinds,
  Source = channel id, post-fader tap, one-block latency),
  `engine-architecture.md` (kinds, `is_mono_only`, tap snapshot/feed in the
  mixing section), `godot-osc.md` (XY pair).
  - _Files_: `docs/subsystems/{osc-protocol,engine-architecture,godot-osc}.md`
  - _Verify_: doc kind list matches `ModulatorKind::ALL`
  - _Depends on_: T-005, T-010

## Phase 5 — live verification

- [ ] **T-012** [REQ-002, REQ-004–REQ-009] Live: engine + Godot running.
  (1) Dynamic EQ: EQ on A, sidechain source B, Low Cut 200 Hz, High Cut
  2 kHz → band gain at −0.5; loop on B; band dips in time. (2) Ducking: B →
  Utility gain on a bass channel; park transport with B live input, > 3 s →
  still ducks. (3) XY pad: two knobs bound to X and Y; rename/duplicate/
  delete/drag the pair; save/reload; `Engine/logs/last_warn.log` clean.
  (4) Knob: route to Mix, toggle Bipolar, arc and offset sign flip.
  - _Output_: `STATUS.md` note of what was and wasn't checked.
  - _Verify_: manual listen + meters
  - _Depends on_: T-011

## Open questions

- [ ] None blocking (D1–D8 recorded in design.md).
