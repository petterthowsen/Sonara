# Virtual Stage — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine tasks run from `Engine/`. Build-heavy work runs one task at a time with
`CARGO_BUILD_JOBS=2`.

## Phase 1 — engine DSP building blocks

- [x?] **T-001** [REQ-001] Stage types and the Stage pan mode.
  - _Files_: `Engine/src/audio/stage/mod.rs` (new), `Engine/src/audio/mod.rs`, `Engine/src/audio/channel/pan.rs`
  - _Output_: `RoomModel` (`Copy`, clamped to 60 × 40 × 25 m), `StageParams`, `OutputMode`, `StageState`, constants; `PanMode::Stage` = 4 with an identity `get_pan_coefficients`
  - _Verify_: `cargo test pan` passes, including a new `stage_mode_is_identity` and the `from(4)` mapping
  - _Depends on_: —

- [x?] **T-002** [REQ-008, REQ-009, REQ-010] Image-source tap computation.
  - _Files_: `Engine/src/audio/stage/image_source.rs` (new)
  - _Output_: `taps(room, point, listener, distance_delay) -> TapSet`: the direct path, 6 first-order and 18 second-order taps with delay, gain, surface and direction
  - _Verify_: `cargo test image_source`: `first_reflection_earlier_near_wall`, `height_changes_floor_ceiling_taps`, `distance_delay_off_keeps_relative_tap_delays`
  - _Depends on_: T-001

- [x?] **T-003** [REQ-004] `Panner` trait and `StereoPanner`.
  - _Files_: `Engine/src/audio/stage/panner.rs` (new)
  - _Output_: constant-power stereo gains from direction, with a rear high-frequency cut flag
  - _Verify_: `cargo test panner`: left/center/right gains, constant power within 0.1 dB
  - _Depends on_: T-001

- [x?] **T-004** [REQ-004, REQ-006, REQ-007, REQ-013, REQ-026, REQ-027] `StageSource` render.
  - _Files_: `Engine/src/audio/stage/source.rs` (new)
  - _Output_: preallocated delay lines; direct sound for one or two points (size, rotation, sum mode); per-surface and second-order buses with filters; air absorption; ~30 ms smoothing with per-block ramps; 50 ms room crossfade; `Has room` and output-mode handling; per-tap block loops
  - _Verify_: `cargo test stage::source`: `farther_is_quieter_and_duller`, `left_source_is_left`, `size_spreads_stereo_inputs`, `mono_ignores_size`, `position_jump_has_no_step`, `room_change_crossfades`, `has_room_writes_no_reflections`, plus a test that allocations happen only in `new`
  - _Depends on_: T-002, T-003

- [x?] **T-005** [REQ-011, REQ-012, REQ-014] `StageTail`.
  - _Files_: `Engine/src/audio/stage/tail.rs` (new)
  - _Output_: wraps `ReverbDevice` (Hall, `EARLY` 0, `MIX` 100 %); `configure(&RoomModel)` sets `DECAY`, `SIZE` and `PREDELAY`; output = input + tail × tail gain; bypassed in Reflections only
  - _Verify_: `cargo test stage::tail`: `tail_decay_matches_room` (within 15 %), `output_modes`, `tail_rings_after_input_stops`
  - _Depends on_: T-001

## Phase 2 — engine wiring

- [x?] **T-006** [REQ-004] Channel and scratch state.
  - _Files_: `Engine/src/audio/channel/mod.rs`, `Engine/src/audio/render_scratch.rs`, `Engine/src/audio/channel/chain.rs`
  - _Output_: `stage_params`, `automation_stage`, `stage`, `stage_feed`, `stage_tail` on `Channel`; `MixBuffers::stage_left/right`; `Channel::render_stage`; `set_sample_rate` rebuilds the stage objects; `begin_device_chain` runs `stage_tail` first when `start == 0`
  - _Verify_: `cargo test` passes; a new `channel` test confirms the tail runs before the first device
  - _Depends on_: T-004, T-005

- [x?] **T-007** [REQ-001, REQ-016, REQ-017] Commands and OSC routes.
  - _Files_: `Engine/src/audio/commands/stage.rs` (new), `Engine/src/audio/commands/mod.rs`, `Engine/src/audio/command_worker/mod.rs`, `Engine/src/osc/routes/stage.rs` (new), `Engine/src/osc/routes/mod.rs`, `Engine/src/osc/routes/channel.rs`
  - _Output_: `/stage/set`, `/stage/return`, `/channel/{id}/stage`, pan mode 4; Stage pan mode and `SetStageReturn` build their objects off-lock and swap them in; Stage refused on master and on the Stage return; `stage_feed` set on every source when the return changes
  - _Verify_: route parsing tests in `osc/routes` (the `mod tests` pattern used for `SetChannelPan`); a command test that refuses Stage on channel 1
  - _Depends on_: T-006

- [x?] **T-008** [REQ-004, REQ-005, REQ-014, REQ-017] Stage pass (serial) and the stage edge in routing.
  - _Files_: `Engine/src/audio/mixing/mod.rs`, `Engine/src/audio/mixing/routing.rs`
  - _Output_: `stage_pass` after `apply_fader_and_pan`; `count_route_inputs` counts `stage_feed`; `route_channel` mixes `mix.stage_*` into the return; `route_finished` renders the stage for a stage source that is a route target
  - _Verify_: `cargo test mixing::routing`: `stage_source_direct_follows_route`, `stage_return_receives_reflections`, `stage_return_rings_out`
  - _Depends on_: T-007

- [x?] **T-009** [REQ-004] Pooled stage pass (ADR 0020 extension).
  - _Files_: `Engine/src/audio/mixing/pool.rs`, `Engine/src/audio/mixing/mod.rs`
  - _Output_: a per-generation `JobKind { Chain, Stage }`; `PoolShared::step` dispatches `Stage` to `Channel::render_stage`; `stage_pass` uses `PooledPass` with the serial fallback
  - _Verify_: `cargo test pool`: `stage_pass_pooled_matches_serial` (sample-identical), and the existing pool tests still pass
  - _Depends on_: T-008

- [x?] **T-010** [REQ-019, REQ-020] Solo and mute through the stage edge.
  - _Files_: `Engine/src/audio/mixing/solo.rs`
  - _Output_: `any_output` and `spread_solo_up` walk `stage_feed`
  - _Verify_: `cargo test solo`: `solo_keeps_soloed_source_room_only`, `muted_source_feeds_no_room`
  - _Depends on_: T-008

- [x?] **T-011** [REQ-005] Latency compensation on the stage edge.
  - _Files_: `Engine/src/audio/mixing/latency.rs`, `Engine/src/audio/channel/mod.rs` (`ChannelLatency`), `Engine/src/audio/command_worker/latency.rs`, `Engine/src/audio/mixing/routing.rs`
  - _Output_: the stage edge in the signature and plan, `stage_delay` with a `stage` ring, and the plan rebuilt when `stage_feed` changes
  - _Verify_: `cargo test latency`: `stage_edge_aligns_with_plugin_latency` (a source behind a latency-reporting test device arrives aligned at the Stage return)
  - _Depends on_: T-008

- [x?] **T-012** [REQ-025] Stage automation targets.
  - _Files_: `Engine/src/audio/automation.rs`
  - _Output_: `AutomationTarget::StageParam`; parse and display `channel/stage/{x,y,z,size,rotation}`; apply and release into `automation_stage`; the stage pass reads the override
  - _Verify_: `cargo test automation`: parse/display round trip, `stage_x_automation_moves_balance`
  - _Depends on_: T-008

- [x?] **T-013** [REQ-029, NF performance] Offline equality and budget bench.
  - _Files_: `Engine/src/audio/render/mod.rs` (test), `Engine/src/audio/mixing/mod.rs` (ignored bench test)
  - _Output_: `stage_offline_matches_realtime`; `stage_64_sources_budget` (`#[ignore]`), which prints the time per block at 48 kHz / 128 frames with 1 thread and with the pool
  - _Verify_: `cargo test stage_offline_matches_realtime`; `cargo test --release stage_64_sources_budget -- --ignored --nocapture` comes in under 15 % of a block's duration on the dev laptop. Report the measured number
  - _Depends on_: T-009, T-012

- [x?] **T-014** [REQ-all] ADR 0024 Stage render pass.
  - _Files_: `docs/adr/0024-stage-render-pass.md` (new)
  - _Output_: the decision (stage pass, identity pan, `JobKind`, stage edge) and its relation to ADR 0020 and 0021
  - _Verify_: the file exists and is referenced from `engine-architecture.md` (T-025)
  - _Depends on_: T-009

## Phase 3 — Godot

- [x?] **T-015** [REQ-015, REQ-016] Stage model and presets.
  - _Files_: `Godot/data/Stage.gd` (new), `Godot/data/StagePresets.gd` (new), `Godot/tests/test_stage_model.gd` (new)
  - _Output_: room values, materials, preset and `modified`, signals, setters sending `/stage/set`, `sync_to_engine()`, `to_json` / `from_json`; five presets and the material table
  - _Verify_: `Godot/tests/run_all.sh stage_model`: each preset applies its values, an edit marks it modified, JSON round-trips
  - _Depends on_: T-007

- [x?] **T-016** [REQ-001, REQ-002, REQ-003, REQ-023] Channel stage fields.
  - _Files_: `Godot/data/Channel.gd`, `Godot/tests/test_stage_pan_mode.gd` (new)
  - _Output_: `PanMode.STAGE`, `can_use_stage()`, stage fields with `stage_changed`, `get_stage_state` / `set_stage_state`, placement from pan on the first entry, `is_stage_return`, JSON, and `sync_to_engine` sending `/channel/{id}/stage`
  - _Verify_: `Godot/tests/run_all.sh stage_pan_mode`: an instrument channel accepts Stage and a bus refuses it; pan −0.5 in a 20 m room gives X = −5 m from the center; Balance → Stage → move → Balance restores pan 0.3 and Stage restores the moved position; sum mode and has room are set and round-trip
  - _Depends on_: T-015

- [x?] **T-017** [REQ-017, REQ-018, REQ-028] Project stage and the Stage return.
  - _Files_: `Godot/data/Project.gd`, `Godot/tests/test_stage_pan_mode.gd`, `Godot/tests/test_stage_model.gd`
  - _Output_: `project.stage`; `ensure_stage_return()`; `remove_channel` refuses the Stage return while sources exist; `stage_sources()`; save, load and `connect_to_engine` send the stage and `/stage/return`
  - _Verify_: `Godot/tests/run_all.sh stage`: two sources → one return; delete refused, then allowed with no sources; a project saved and reloaded has the same stage, the same channel stage values, and sends the stage OSC messages
  - _Depends on_: T-016

- [x?] **T-018** [REQ-025] Godot automation target.
  - _Files_: `Godot/data/AutomationTarget.gd`, its existing test
  - _Output_: `Kind.STAGE_PARAM` with the `channel/stage/{param}` spelling, offered only for stage sources
  - _Verify_: `Godot/tests/run_all.sh automation_target`: parse/format round trip and the target list for a stage source
  - _Depends on_: T-016

- [x?] **T-019** [REQ-001] Pan control.
  - _Files_: `Godot/mixer/PanControl.gd`, its scene
  - _Output_: a Stage item in the mode popup (only where `can_use_stage()`), undoable through `PropertyCommand`; in Stage mode a "Stage" button that opens the Stage view
  - _Verify_: `Godot/tests/run_all.sh channel_pan` passes, with a case for the Stage item's visibility
  - _Depends on_: T-016

- [x?] **T-020** [REQ-021] Host a non-device page in a frame.
  - _Files_: `Godot/devices/frame/DeviceFrame.gd`, `Godot/devices/DeviceWindowManager.gd`
  - _Output_: audit and fix every use of `channel` and the device list that assumes a value; `open_stage()` / `close_stage()` with window, attach and detach like device frames; the channel header hidden
  - _Verify_: the existing frame tests pass (`Godot/tests/run_all.sh frame window`); a new case opens, attaches, detaches and closes a page-only frame without errors in the log
  - _Depends on_: —

- [x?] **T-021** [REQ-022] Edit operations.
  - _Files_: `Godot/stage/StageEdit.gd` (new), `Godot/tests/test_stage_edit.gd` (new)
  - _Output_: move, end-drag resize and rotate, clamp to room (taking size and rotation into account), multi-move keeping offsets, height for a selection
  - _Verify_: `Godot/tests/run_all.sh stage_edit`
  - _Depends on_: T-016

- [x?] **T-022** [REQ-021, REQ-022, REQ-023, REQ-016, REQ-025] Stage view.
  - _Files_: `Godot/stage/StageCanvas.gd` (new), `Godot/stage/StageView.gd` (new), `Godot/stage/StageView.tscn` (new), `Godot/editor/MainMenu.gd`, `Godot/tests/test_stage_view.gd` (new)
  - _Output_: a top-down canvas with the room, listener and source bars (colour, name; a dot at size 0); drags through `StageEdit` with undo; the room panel and source panel; automated positions shown during playback via `AutomationLane.get_value_at_tick`; View > Stage
  - _Verify_: `Godot/tests/run_all.sh stage_view` (kept shallow): three sources → three items; a source leaving Stage removes its item
  - _Depends on_: T-017, T-020, T-021

- [x?] **T-023** [REQ-024] Selection sync.
  - _Files_: `Godot/editor/SelectionSync.gd`, `Godot/stage/StageView.gd`, `Godot/tests/test_stage_view.gd`
  - _Output_: selecting in the Stage view selects the channel, and the other way round
  - _Verify_: `Godot/tests/run_all.sh stage_view` with the selection case
  - _Depends on_: T-022

- [x?] **T-024** [REQ-030] DAWproject export.
  - _Files_: `Godot/dawproject/DawProjectExporter.gd`, `Godot/tests/test_dawproject_export.gd`
  - _Output_: `_pan_position` maps Stage X onto pan; one transfer report entry for the stage
  - _Verify_: `Godot/tests/run_all.sh dawproject_export`
  - _Depends on_: T-016

## Phase 4 — docs

- [x?] **T-025** [REQ-all] Protocol, architecture and glossary.
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/engine-architecture.md`, `AGENTS.md`, `CONTEXT.md`, `CHANGELOG.md`
  - _Output_: the four messages and the automation targets; the stage pass and the stage edge in the mixing description; the pan rule reworded; glossary terms; an Unreleased entry
  - _Verify_: every OSC address added in T-007 appears in `osc-protocol.md`; `grep -n "stage" AGENTS.md CONTEXT.md` shows the new text
  - _Depends on_: T-014, T-022

## Phase 5 — live verification

- [ ] **T-026** [REQ-all] Live check and preset calibration.
  - _Files_: `Godot/data/StagePresets.gd` (tail gain and predelay tuning)
  - _Output_: presets tuned so the tail onset meets the reflections; the results of the checks below recorded in `STATUS.md`
  - _Verify_: with the engine and Godot running: a stereo strings patch, a mono patch and a brass patch as stage sources in Scoring Stage and Church. Move them during playback and listen for clicks; automate X; switch presets while playing; solo one source (only its room plays); mute one; toggle Has room and each output mode; export the project and compare it with playback; read the stage cost in the Engine panel with 64 sources
  - _Depends on_: T-013, T-023, T-024, T-025
