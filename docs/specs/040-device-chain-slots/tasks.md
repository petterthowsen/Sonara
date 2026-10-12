# Device Chain Slots — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine tasks are verified with `cargo test <name>` and `cargo fmt` from `Engine/`, and Godot tasks
with `Godot/tests/run_all.sh <word>`.

## Phase 1 — engine: the slot mechanism

- [x?] **T-001** [REQ-001, REQ-014–017] Add `audio/devices/slots.rs`.
  - `SlotKind {Note, Audio, Loop}` with `as_str()` ("note" / "audio" / "loop") and
    `accepts(&dyn AudioDevice) -> Result<(), String>`, recursive over `as_container` children.
    Note takes `is_note_effect()`. Audio rejects `DeviceCategory::Instrument` and note effects.
    Loop also rejects `DeviceVariant::Clap` and `has_async_blocks()`.
  - `SlotSpec {key, name, kind}` and `LOOP_BLOCK = 64`.
  - `DeviceSlots`: `new(specs: &'static [SlotSpec], max_frames)` creates one `ChainDevice` per
    spec plus the scratch (`slot_buf`, `loop_in`, `loop_out`, `note_sink`). It also has
    `prepare`, `reset`, `chain_mut(i)`, `children_mut(i)` (the chain's
    `chain_children_mut`), `is_live(i)`, `has_async(i)`, and the `DeviceContainer` delegates
    (`insert_child` refuses with a warning, `remove_child` returns None, `move_child` does
    nothing).
  - Register the module in `audio/devices/mod.rs` and re-export it.
  - Tests: `kind_accepts`, `fixed_children_refuse_edits`, `is_live_ignores_bypassed`.
  - _Files_: `Engine/src/audio/devices/slots.rs`, `Engine/src/audio/devices/mod.rs`
  - _Output_: a reusable slot holder that compiles, with no device using it yet
  - _Verify_: `cargo test slots` passes; `cargo fmt`
  - _Depends on_: —

- [x?] **T-002** [REQ-001] Add the trait hooks and forward them.
  - In `device.rs`, add `fn device_slots(&self) -> &'static [SlotSpec] { &[] }` and
    `fn release_slot_notes(&mut self, _slot: usize, _index: Option<usize>) {}`.
  - `ModulatedDevice` forwards both.
  - `ChainDevice::prepare` resizes `buf_a` and `buf_b` when `max_frames * 2` is larger.
  - _Files_: `Engine/src/audio/devices/device.rs`, `Engine/src/audio/modulation/host.rs`,
    `Engine/src/audio/devices/containers/chain.rs`
  - _Output_: the hooks exist, are forwarded through the wrapper, and chains resize on `prepare`
  - _Verify_: `cargo build --release`; `cargo test chain` passes, including a new
    `prepare_grows_buffers` test
  - _Depends on_: T-001

- [x?] **T-003** [REQ-017] Enforce slot kinds in `insert_device`.
  - Add `slots::check_insert(devices, parent_path, device)`. It walks the ancestors of
    `parent_path` and finds the innermost one whose parent device has `device_slots()`, then
    calls `SlotKind::accepts`.
  - `container::insert_device` calls it, and an `Err` names the slot and the device.
  - Test: `container::tests::insert_into_slot_is_checked`, using a test slotted device.
  - _Files_: `Engine/src/audio/devices/slots.rs`, `Engine/src/audio/devices/containers/container.rs`
  - _Output_: the engine refuses a device that doesn't fit its slot, and logs a warning
  - _Verify_: `cargo test insert_into_slot` passes
  - _Depends on_: T-002

- [ ] **T-004** [REQ-004] Release note effects into a sink.
  - In `routing.rs`, add `release_note_effects_into` and `release_note_effect_at_into`, which take
    `Option<&mut NoteBuffer>`. The existing functions call them with `None`.
  - `Channel::release_note_effect_at` and `release_note_effects_in` call the slotted device's
    `release_slot_notes` when `path.parent()` is a note slot.
  - _Files_: `Engine/src/audio/devices/note_fx/routing.rs`, `Engine/src/audio/channel/chain.rs`
  - _Output_: a release inside a note slot reaches the slotted device
  - _Verify_: `cargo test note_fx` and `cargo test routing` still pass (the real test is in T-006)
  - _Depends on_: T-002

- [ ] **T-005** [REQ-001] Advertise slots in `/builtin/info`.
  - Add `slots: Vec<(String, String, String)>` to `BuiltinDeviceInfo`.
  - `factory.rs` `builtin_device_info` fills it from `device_slots()`.
  - `osc/encode.rs` appends `i:count` and then `(s:key, s:name, s:kind)` for each slot, and the
    test fixture gets `slots: vec![]`.
  - Test: an encode test checks that the trailing block is written after the default modulators.
  - _Files_: `Engine/src/audio/commands/status.rs`, `Engine/src/audio/devices/factory.rs`,
    `Engine/src/osc/encode.rs`
  - _Output_: `/builtin/info` carries the slot list
  - _Verify_: `cargo test encode` passes
  - _Depends on_: T-002

## Phase 2 — engine: the three devices

- [ ] **T-006** [REQ-001–006, REQ-012, REQ-013] PolySynth Note FX and FX.
  - Add `slots: DeviceSlots` with `POLYSYNTH_SLOTS` (`note_fx` Note, `fx` Audio).
  - `send_note_event` routes through Note FX with `route_note`. A note that falls through is
    queued directly. `send_cc` also calls `route_cc`.
  - `process_block`:
    1. If Note FX is live, run `run_note_phase` with the sink and queue the sink's notes.
    2. Render the voices.
    3. If FX is live, run `ChainDevice::process_block`.
  - `release_slot_notes` queues released note-offs at frame 0. `is_sleeping` is false while
    Note FX is live.
  - Add the container methods, `device_slots`, `prepare` and `reset`.
  - Tests: `slots_exist_and_are_fixed`, `empty_slots_are_sample_identical`,
    `note_fx_transposes_at_frame`, `note_fx_release_on_remove`, `cc_reaches_note_fx`,
    `fx_slot_processes_output`, `bypass_skips_slots`, `sleep_waits_for_fx_tail`.
  - _Files_: `Engine/src/audio/devices/instruments/polysynth/mod.rs`
  - _Output_: the PolySynth plays notes from its Note FX slot and runs its output through FX
  - _Verify_: `cargo test polysynth` passes; `cargo fmt`
  - _Depends on_: T-003, T-004

- [ ] **T-007** [REQ-006, REQ-009] Whole-block path for plugins in audio slots.
  - `has_async_blocks()` is true while an audio slot `has_async`.
  - `begin_block` processes the whole block synchronously into `slot_buf` and returns true, and
    `finish_block` copies `slot_buf` out. Do this for the PolySynth here, and for the Reverb
    in T-010.
  - Test: `async_slot_takes_whole_block_path`, which wraps a PolySynth in `ModulatedDevice`
    with an async test device in FX and asserts that the device sees one call per block.
  - _Files_: `Engine/src/audio/devices/instruments/polysynth/mod.rs`
  - _Output_: a plugin in FX gets one call per host block
  - _Verify_: `cargo test async_slot` passes
  - _Depends on_: T-006

- [ ] **T-008** [REQ-002, REQ-007, REQ-010, REQ-012] Delay FB FX.
  - Add `slots: DeviceSlots` with `DELAY_SLOTS` (`fb_fx` Loop) and a `loop_floor:
    SmoothedParam`, with target `LOOP_BLOCK + 2` while FB FX is live and 0 otherwise, applied in
    `target_samples`.
  - When FB FX is live, `process_block` runs in `LOOP_BLOCK` sub-blocks:
    1. Read phase: today's per-sample code up to `own_fb`, which goes to `loop_in`. The output is
       written here.
    2. Chain phase: run the slot on `loop_in`, giving `loop_out`.
    3. Write phase: cross-feed and push.
  - The plain path stays byte-for-byte as it is today.
  - Add the container methods, `device_slots`, `prepare` and `reset`.
  - Tests: `empty_fb_fx_is_sample_identical`, `fb_fx_halves_each_later_repeat`,
    `fb_fx_enforces_loop_floor_without_click`, `bypassed_delay_skips_fb_fx`.
  - _Files_: `Engine/src/audio/devices/effects/delay.rs`
  - _Output_: each repeat after the first passes through FB FX
  - _Verify_: `cargo test delay` passes, including the existing tests
  - _Depends on_: T-003

- [ ] **T-009** [REQ-002, REQ-008, REQ-010] Reverb Tank FX.
  - Split FDN `process` and `PlateTank::process` into `read` and `write` halves, keeping
    `process = read + write` so the plain path is unchanged.
  - Add `slots: DeviceSlots` with `REVERB_SLOTS` (`tank_fx` Loop, `wet_fx` Audio), a
    `loop_floor` on the line delays, and the fixed-size loop scratch (`fdn_f`, `fdn_inj`,
    `plate_d`).
  - When Tank FX is live, run the sub-block path:
    - FDN: project onto `u_L` and `u_R`, scaled by `out_scale·√8`, run the chain, and add back
      the difference.
    - Plate: run the chain on `(d0, d1)` and carry the last processed value in `last`.
  - During an algorithm crossfade, the fading algorithm stays on the plain path.
  - Tests: `empty_slots_are_sample_identical`, `tank_fx_shortens_tail_per_algorithm` (Room,
    Hall, Plate), `unity_tank_fx_matches_empty`, `tank_fx_runs_while_frozen`.
  - _Files_: `Engine/src/audio/devices/effects/reverb.rs`
  - _Output_: the tank's circulating signal passes through Tank FX once per loop
  - _Verify_: `cargo test reverb` passes, including the existing tests
  - _Depends on_: T-003

- [ ] **T-010** [REQ-009, REQ-012, REQ-013] Reverb Wet FX and the whole-block path.
  - When Wet FX is live, `process_block` makes two passes: the wet signal goes into `slot_buf`,
    the chain runs on it, then the mix.
  - Add the `has_async_blocks`, `begin_block` and `finish_block` path from T-007, plus the
    container methods, `device_slots`, `prepare` and `reset`.
  - Tests: `wet_fx_never_touches_dry`, `bypassed_reverb_skips_slots`,
    `sleep_waits_for_wet_fx_tail`.
  - _Files_: `Engine/src/audio/devices/effects/reverb.rs`
  - _Output_: Wet FX processes only the wet signal
  - _Verify_: `cargo test reverb` passes
  - _Depends on_: T-009, T-007

- [ ] **T-011** [REQ-032] A modulator route into a slot device.
  - Test `modulation::host::tests::route_reaches_slot_device`: a wrapped PolySynth's LFO is routed
    to `child/1/child/0` param Mix of a Delay, and the Delay's effective Mix moves.
  - Fix the route resolution if the test fails.
  - _Files_: `Engine/src/audio/modulation/host.rs`
  - _Output_: routes resolve into slot devices
  - _Verify_: `cargo test route_reaches_slot_device` passes
  - _Depends on_: T-006

- [ ] **T-012** [REQ-011] Real-time review and the full engine gate.
  - Read every new audio-path function against ADR-0002: no `Vec` growth, no `String` or
    `format!` outside the warn-once paths, and no locks.
  - _Files_: everything from T-001 to T-011
  - _Output_: a review note in this task: what was checked and what was found
  - _Verify_: `cargo test` (all) passes; `cargo fmt --check` is clean; `cargo build --release`
  - _Depends on_: T-006 to T-011

## Phase 3 — Godot: model, sync, rules

- [x?] **T-013** [REQ-001, REQ-030] Parse the slots and create them on instances.
  - `Device.slots` and `has_device_slots()`. `uses_simple_view` allows slotted devices, and
    `creates_instrument_track` excludes them.
  - `DeviceRegistry._parse_device_slots`; `_parse_default_modulators` returns its end index.
  - New `data/DeviceSlots.gd` with `is_slotted`, `specs`, `is_slot_chain`, `spec_of`,
    `ensure_chains` (create, order and name the chains, adopting saved ones by key or position),
    `kind_for_host`, `accepts`, `accepts_instance`, `target_chain` and `role_color`.
  - `DeviceInstance._init` and `from_json` call `ensure_chains`. `from_json` clears the chains
    `_init` created.
  - Tests in `test_device_chain_slots.gd`: `test_new_instances_have_slots`,
    `test_pre_spec_json_gets_empty_slots`.
  - _Files_: `Godot/data/Device.gd`, `Godot/data/DeviceRegistry.gd`, `Godot/data/DeviceSlots.gd`,
    `Godot/data/DeviceInstance.gd`, `Godot/tests/test_device_chain_slots.gd`
  - _Output_: PolySynth, Delay and Reverb instances carry their slot chains
  - _Verify_: `Godot/tests/run_all.sh device_chain_slots` passes
  - _Depends on_: T-005

- [ ] **T-014** [REQ-019–021] Slot keys, colours and open state.
  - Make the CONTAINER SLOTS functions handle slotted devices: `slot_keys` returns the spec keys,
    and `has_slot`, `slot_chain`, `slot_devices`, `slot_key_for` and `slot_title` follow them.
    `slot_color` returns the role colour, and `set_slot_color` ignores device slot keys.
  - `set_slot_open` keeps only one slot open.
  - Tests: `test_one_slot_open`, `test_slot_role_colors`.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/tests/test_device_chain_slots.gd`
  - _Output_: slots behave like a focused container's, with fixed colours
  - _Verify_: `Godot/tests/run_all.sh device_chain_slots device_slots` passes
  - _Depends on_: T-013

- [ ] **T-015** [REQ-001] Engine sync skips slot chains.
  - `Channel._sync_device_tree_to_engine` doesn't send `add_device` for `DeviceSlots.is_slot_chain`
    children, but still recurses into them.
  - Test `test_sync_skips_slot_chains`: capture sent OSC and check there's no `add_device` at
    `…/device/0` for the chains, but there is one at `…/device/0/child/1` for a Delay in FX.
  - _Files_: `Godot/data/Channel.gd`, `Godot/tests/test_device_chain_slots.gd`
  - _Output_: Godot never creates or removes the engine's slot chains
  - _Verify_: `Godot/tests/run_all.sh device_chain_slots` passes
  - _Depends on_: T-013

- [ ] **T-016** [REQ-014–018] Drop rules and fixed slots.
  - `DeviceDropUtil`: `device_fits_host` and `copy_fits_host` apply the slot kind;
    `can_drop_instance_on_host` refuses slot chains; `can_drop_on_container` is false for
    slotted devices.
  - `DeviceAddCommand` redirects through `DeviceSlots.target_chain`.
  - `DeviceContextMenu` shows "Clear Slot" and no Remove, Copy or Rename for slot chains.
  - The AI tools (`RemoveDeviceTool`, `DeviceToolUtil`, `AiTool`) refuse a slot chain and apply
    the kinds.
  - Tests: `test_note_slot_takes_note_effects_only`, `test_audio_slot_rejects_instruments_and_note_fx`,
    `test_loop_slot_rejects_plugins`, `test_slot_chain_cannot_move_or_be_removed`,
    `test_drop_on_slotted_panel_is_not_a_container_drop`.
  - _Files_: `Godot/devices/DeviceDropUtil.gd`, `Godot/history/commands/DeviceAddCommand.gd`,
    `Godot/devices/DeviceContextMenu.gd`, `Godot/ai/tools/RemoveDeviceTool.gd`,
    `Godot/ai/tools/DeviceToolUtil.gd`, `Godot/ai/tools/AiTool.gd`,
    `Godot/tests/test_device_chain_slots.gd`
  - _Output_: only devices that fit reach a slot, and slots can't be edited away
  - _Verify_: `Godot/tests/run_all.sh device_chain_slots note_fx_drop device_drop` passes
  - _Depends on_: T-014

- [ ] **T-017** [REQ-019, REQ-022, REQ-033] Lane and automation.
  - Check that opening a slot adds a `DeviceSlotGroup` and that adding into a closed slot
    reveals it (`reveal_child`). Fix whatever doesn't hold.
  - Test that the automation picker lists the parameters of a device in a slot.
  - Tests: `test_open_slot_shows_slot_group`, `test_add_reveals_slot`,
    `test_automation_lists_slot_devices`.
  - _Files_: `Godot/devices/device_lane/DeviceLane.gd` (only if needed),
    `Godot/tests/test_device_chain_slots.gd`
  - _Output_: slots show in the lane and their devices can be automated
  - _Verify_: `Godot/tests/run_all.sh device_chain_slots` passes
  - _Depends on_: T-014

## Phase 4 — Godot: Simple View

- [ ] **T-018** [REQ-024–026] The slot control kind and the tile.
  - `SimpleControlKinds.SLOT` with footprint (2, 1) and 0 parameters.
  - `SimpleControl` builds a `DeviceSlotButton` for it.
  - `DeviceSlotButton` gets `show_count`, `_can_drop_data` and `_drop_data`, which add to the
    end of the slot chain and open the slot.
  - `GridPacker.make_control` copies `slot`. `SimpleLayout._page_from_dict` keeps it, and
    `param_ids` skips slot controls.
  - Tests in `test_simple_view_render.gd`: `test_slot_tiles_render_with_count`,
    `test_slot_tile_click_toggles`, `test_drop_on_slot_tile`.
  - _Files_: `Godot/devices/simple_view/SimpleControlKinds.gd`,
    `Godot/devices/simple_view/SimpleControl.gd`, `Godot/components/DeviceSlotButton.gd`,
    `Godot/devices/simple_view/GridPacker.gd`, `Godot/devices/simple_view/SimpleLayout.gd`,
    `Godot/tests/test_simple_view_render.gd`
  - _Output_: a slot tile renders and works in a Simple View
  - _Verify_: `Godot/tests/run_all.sh simple_view` passes
  - _Depends on_: T-014

- [ ] **T-019** [REQ-023, REQ-027] The generator puts the tiles last.
  - `SimpleLayoutGenerator.generate` appends the "Slots" column group after the Main groups.
    `VERSION = 15`.
  - Test in `test_simple_layout_generator.gd`: `test_slot_tiles_are_last_on_main` for
    PolySynth, Delay and Reverb, plus a check that `uses_simple_view` is true for all three.
  - _Files_: `Godot/devices/simple_view/SimpleLayoutGenerator.gd`,
    `Godot/tests/test_simple_layout_generator.gd`
  - _Output_: generated layouts end with the slot tiles
  - _Verify_: `Godot/tests/run_all.sh simple_layout` passes
  - _Depends on_: T-018

- [ ] **T-020** [REQ-028] Edited layouts get the missing tiles.
  - `SimpleLayout.reconcile_slots(keys)` and the call to it in `SimpleLayoutStore.load_or_generate`.
  - Test: `test_edited_layout_gets_slot_tiles_appended`. Every other control keeps its rect.
  - _Files_: `Godot/devices/simple_view/SimpleLayout.gd`,
    `Godot/devices/simple_view/SimpleLayoutStore.gd`, `Godot/tests/test_simple_view_render.gd`
  - _Output_: saved user layouts gain tiles without moving anything
  - _Verify_: `Godot/tests/run_all.sh simple_view simple_layout` passes
  - _Depends on_: T-019

## Phase 5 — Godot: presets and export

- [ ] **T-021** [REQ-029, REQ-031] Presets keep slot contents.
  - Tests in `test_device_presets.gd`: `test_slotted_preset_round_trip`,
    `test_pre_spec_preset_empties_slots_one_undo`. Fix `DevicePreset` / `DevicePresetLoadCommand`
    only if the tests fail.
  - _Files_: `Godot/tests/test_device_presets.gd` (plus `Godot/data/DevicePreset.gd` if needed)
  - _Output_: proof that presets carry slots and that loading one is a single undo step
  - _Verify_: `Godot/tests/run_all.sh device_presets preset_load` passes
  - _Depends on_: T-015

- [ ] **T-022** [REQ-034] Report slot contents in DAWproject export.
  - Add `TransferReport.DEVICE_SLOTS` and its message. `DawProjectExporter` adds one entry per
    slotted device whose slots hold devices.
  - Test: `test_export_reports_slot_devices` in `test_dawproject_export.gd`.
  - _Files_: `Godot/dawproject/TransferReport.gd`, `Godot/dawproject/DawProjectExporter.gd`,
    `Godot/tests/test_dawproject_export.gd`
  - _Output_: the export succeeds and the report names the devices in slots
  - _Verify_: `Godot/tests/run_all.sh dawproject` passes
  - _Depends on_: T-013

- [ ] **T-023** [REQ-all] Full Godot gate.
  - _Files_: —
  - _Output_: no regressions in the other Godot tests
  - _Verify_: `Godot/tests/run_all.sh` passes. Any failure that was already there is listed with
    evidence from `git stash`
  - _Depends on_: T-016 to T-022

## Phase 6 — docs

- [ ] **T-024** [REQ-001] Document the protocol and the domain terms.
  - `docs/subsystems/osc-protocol.md`: the `/builtin/info` slot block, and a "Device slots" note
    (engine-owned chains, `{device}/child/{slot}` paths, kinds).
  - `CONTEXT.md`: Device slot, Slotted device and Loop slot.
  - `docs/subsystems/engine-architecture.md`: a "Device slots" section with the loop sub-block
    rule and the whole-block plugin path.
  - _Files_: `docs/subsystems/osc-protocol.md`, `CONTEXT.md`, `docs/subsystems/engine-architecture.md`
  - _Output_: the docs match the code
  - _Verify_: the slot block appears in osc-protocol.md with the exact argument order that
    `encode.rs` writes; the three terms are in CONTEXT.md
  - _Depends on_: T-005, T-012

## Phase 7 — live verification

- [ ] **T-025** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: —
  - _Output_: a note in this file listing what was heard and seen, and what wasn't checked
  - _Verify_: the steps in design.md › Test plan › Live:
    1. PolySynth with an Arpeggiator in Note FX and a Delay in FX: arpeggiated notes are
       delayed; the tail rings out, then the device sleeps.
    2. Delay with a Saturator in FB FX at 95 % feedback: repeats get dirtier. Time at 1 ms: no
       click.
    3. Reverb Plate with a Filter in Tank FX: the tail darkens. A CLAP in Wet FX works, and a
       CLAP is refused on Tank FX.
    4. Save and reload the project, and save and load a PolySynth preset: the slots come back.
    5. The Simple View tiles are at the right, Note FX is green (secondary accent), and clicking
       a tile opens its slot.
  - _Depends on_: T-023, T-024
