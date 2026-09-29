# Layer Note Mapping — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

The window tasks (T-009–T-012) also have headless smoke coverage in
`Godot/tests/test_layer_mapping_window.gd`. Their `[x?]` marks are waiting on the live checks.

Headless Godot commands use the form `godot --headless --path Godot -s tests/<script>.gd -- --test`.

## Phase 1 — Engine: routing and messages end to end

- [x] **T-001** [REQ-001, REQ-002, REQ-003] Slot note map and held-note routing in the Layer.
  - _Files_: `Engine/src/audio/devices/layer.rs`
  - _Output_:
    - `NOTE_NONE`, plus `LayerSlot::{note_map, held}`, set to identity / all `NOTE_NONE` in
      `LayerSlot::new`.
    - `LayerDevice::set_slot_note_map(index, &[u8; 128]) -> bool`.
    - `send_midi_event` routes a note-on through `note_map` and records it in `held`. If the input
      is already held, it sends a note-off for the old output first. A note-off reads and clears
      `held`, and only slots that receive an event are marked active.
    - `reset` clears `held`.
  - _Verify_: `cargo test layer` passes `layer_routes_note_through_slot_maps`,
    `layer_note_off_follows_held_note_after_remap`, `layer_note_off_follows_held_note_after_move`,
    `layer_retrigger_releases_previous_output` and `layer_fresh_slot_is_full_map`. Existing Layer
    tests still pass.
  - _Depends on_: —

- [x] **T-002** [REQ-005, REQ-007] Layer extra outputs.
  - _Files_: `Engine/src/audio/devices/layer.rs`
  - _Output_:
    - `LayerSlot::separate_out` and `set_slot_separate_out(index, bool) -> bool`.
    - `extra_output_bus_count()` returns `slots.len()`.
    - `process_block_with_extra` sends a separate slot's gained, mute/solo-gated audio to
      `extra_outs[i]` when `i < extra_outs.len()`, and mixes every other slot into main. Unused
      buses are zeroed.
    - `process_block` ignores the flag. The gain/mute/solo logic is shared with
      `process_block_with_extra`.
  - _Verify_: `cargo test layer` passes `layer_separate_slot_writes_extra_bus` (including the
    fallback past `extra_outs.len()`) and `layer_process_block_ignores_separate_flag`.
  - _Depends on_: T-001

- [x] **T-003** [REQ-013] Slot audition that bypasses the map.
  - _Files_: `Engine/src/audio/devices/layer.rs`
  - _Output_:
    - `LayerDevice::audition_slot(index, note, velocity, on) -> bool` forwards directly to the slot
      device (after `mark_activity`, with frame offset 0) without touching `held`.
    - `SubprocessAdapter` and the sfizz device's `send_midi_event` are checked to confirm they only
      enqueue. The result is noted in this task.
  - _Verify_: `cargo test layer_audition_bypasses_map` passes, and the enqueue check is written up.
  - _Depends on_: T-001
  - _Result_: the check passed. `SfizzDevice`, `SamplerDevice`, `PolySynth` and `SubprocessAdapter`
    `send_midi_event` all only push onto their queues. The command thread holds the state lock, so
    the audio callback isn't inside the device at the same time.

- [x?] **T-004** [REQ-001, REQ-005, REQ-013] Commands and OSC handlers.
  - _Files_: `Engine/src/audio/commands.rs`, `Engine/src/osc/server.rs`
  - _Output_:
    - `AudioCommand::SetLayerSlotNoteMap { channel_id, device_path, slot, map: Box<[u8; 128]> }`,
      `SetLayerSlotSeparateOut` and `AuditionLayerSlot`, with apply arms modelled on
      `SetLayerSlotVolume`.
    - Server arms for `["slot", s, "note_map"]` (a blob that must be exactly 128 bytes, else
      `warn!`), `["slot", s, "separate_out"]` and `["slot", s, "audition"]`.
  - _Verify_: `cargo build --release`, `cargo test` and `cargo fmt --check` are clean. `oscsend`
    smoke check with the engine running: send a 128-byte blob to `/channel/2/device/0/slot/0/note_map`
    for a Layer on channel 2, and it's applied with no warning in `Engine/logs/last_warn.log`. A
    127-byte blob logs a warning.
  - _Depends on_: T-002, T-003
  - _Status_: build, tests and `fmt --check` are clean. The `oscsend` smoke check needs a running
    engine and moves to the live pass.

## Phase 2 — Godot: model, edit logic, returns

- [x] **T-005** [REQ-011, REQ-012, REQ-014, REQ-015] `LayerNoteMap` pure helpers.
  - _Files_: `Godot/data/LayerNoteMap.gd` (new), `Godot/tests/test_layer_note_map.gd` (new)
  - _Output_:
    - The helpers `NONE`, `full`, `empty`, `is_full`, `inputs`, `connect`, `connect_range`,
      `disconnect`, `shift`, `resolve_overlaps` and `distribute` (the last two return
      `{maps, skipped}`).
    - Each editing helper treats a full map as empty first.
  - _Verify_: `test_layer_note_map.gd` passes. It covers each helper, the full → empty rule, the
    REQ-014 and REQ-015 examples verbatim, full-map slots being skipped, a shift that would leave
    0–127, and Distribute running past 127 (the slot is reported as skipped).
  - _Depends on_: —

- [x] **T-006** [REQ-011, REQ-012, REQ-016] `DeviceInstance` slot map and separate-out fields,
  sync and persistence.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/tests/test_layer_note_map.gd`
  - _Output_:
    - `slot_note_map` (default `LayerNoteMap.full()`) and `slot_separate_out`.
    - `set_slot_note_map` and `set_slot_separate_out` (the latter's `AuxReturnSync` call lands in
      T-007), plus `audition_slot`.
    - `sync_slot_to_engine()` sends `note_map` (a blob) and `separate_out`.
    - `to_json` writes `slot_note_map` only when it isn't full, and `from_json` defaults to full / off.
  - _Verify_: `test_layer_note_map.gd` adds:
    - `set_slot_note_map` via `HistoryUtil.execute_property`, where undo and redo restore the maps;
    - a save → load round trip of a zoned slot;
    - legacy JSON without the keys loading as full / off;
    - a full-map slot's JSON with no `slot_note_map` key.
  - _Depends on_: T-005

- [x] **T-007** [REQ-006] Layer returns in `AuxReturnSync`.
  - _Files_: `Godot/data/AuxReturnSync.gd`, `Godot/data/DeviceInstance.gd`,
    `Godot/tests/test_layer_separate_out.gd` (new)
  - _Output_:
    - `is_layer`, plus Layer branches in `extra_out_count`, `get_return_channel`, `get_source`,
      `on_device_added`, `on_device_removed`, `on_device_moved` and `_ensure_root`.
    - `on_layer_slot_separate_changed`, which attaches from `detached_returns` or creates a return
      named after the slot, or detaches it.
    - `sync_layer_aux_order`.
  - _Verify_: `test_layer_separate_out.gd` passes:
    - turning separate out on creates one nested child and leaves the track count unchanged;
    - set −6 dB, turn off, undo → same id and −6 dB;
    - removing a slot detaches its return, and undoing the removal restores it;
    - moving slots keeps the aux map bus indices equal to child order (captured OSC);
    - `is_plugin_return()` is true for a Layer return.
    `Godot/tests/run_all.sh` is green, including `test_multi_out_devices.gd`.
  - _Depends on_: T-006

## Phase 3 — UI

- [x?] **T-008** [REQ-005, REQ-007] Separate-output toggle on Layer slot rows.
  - _Files_: `Godot/devices/container/LayerSlotRow.gd`
  - _Output_:
    - A toggle per row, backed by `set_slot_separate_out` through `HistoryUtil.execute_property`
      and following `slot_changed`.
    - It is disabled, with an explanatory tooltip, when the Layer isn't `channel.devices[0]`, and
      re-evaluates on the channel's `device_added` / `device_removed` / `device_moved`.
  - _Verify_: live. Toggle the snare's output: a "Snare" strip appears under the Layer channel and
    only the snare plays through it. With a Delay before the Layer the toggle is disabled with the
    tooltip, and moving the Layer to the front enables it.
  - _Depends on_: T-004, T-007
  - _Status_: the enable/disable logic and the toggle → return are covered headless in
    `test_layer_mapping_window.gd`. Hearing the snare through its own strip still needs a live check.

- [x?] **T-009** [REQ-008, REQ-009] Mapping window shell.
  - _Files_: `Godot/devices/container/layer_mapping/LayerMappingWindow.gd` (new),
    `Godot/devices/builtin/LayerDefaultView.gd`
  - _Output_:
    - A "Mapping…" button, and `LayerMappingWindow.open_for(layer)` (one window per Layer id,
      focused if already open, parented to `Sonara.editor`).
    - A slot `ItemList`, and a toolbar placeholder.
    - [input `VPiano`][canvas][output `VPiano`] in one `ScrollContainer` with a shared `LaneLayout`,
      and zoom on Ctrl+wheel.
    - The window closes when the Layer is detached.
  - _Verify_: live. Clicking "Mapping…" twice gives one focused window, the pianos scroll together,
    the arranger stays usable, and deleting the Layer closes the window.
  - _Depends on_: T-006

- [x?] **T-010** [REQ-009, REQ-010] Drawing maps.
  - _Files_: `Godot/devices/container/layer_mapping/LayerMappingCanvas.gd` (new),
    `Godot/components/VPiano.gd` (tint support, if needed)
  - _Output_:
    - Connections for zoned slots, with unselected slots faded.
    - Input keys tinted by slot color, and overlap marks.
    - The output keys used by the selected slot highlighted.
    - The full-map "all notes" state.
    - Redraws on `slot_changed` and child changes.
  - _Verify_: live, with the REQ-010 example: lines 36 → 38 and 37 → 40 are shown and 36 is marked
    as an overlap. A full-map slot shows "all notes". The existing clip editor piano is visually
    unchanged.
  - _Depends on_: T-009

- [x?] **T-011** [REQ-011, REQ-012, REQ-014, REQ-015] Editing and automatic assignment in the window.
  - _Files_: `Godot/devices/container/layer_mapping/LayerMappingCanvas.gd`,
    `Godot/devices/container/layer_mapping/LayerMappingWindow.gd`
  - _Output_:
    - Input selection by click, shift-click and drag.
    - Drag onto the output piano to connect, or to range connect.
    - Delete to disconnect.
    - Shift ±1 / ±12, Clear and Reset.
    - Resolve overlaps and Distribute (through `HistoryUtil.execute_many`), with the skipped slots
      shown in the status label.
    - One undo step per gesture.
  - _Verify_: live. On a full-map Cymbals slot, drag 42 → 49: 42 plays key 49 and 60 is silent on
    the cymbals, and Ctrl+Z restores all notes. Distribute on the REQ-015 setup gives 36–41. Resolve
    on the REQ-014 setup moves the snare to 37–38.
  - _Depends on_: T-004, T-010

- [x?] **T-012** [REQ-013] Auditioning in the window.
  - _Files_: `Godot/devices/container/layer_mapping/LayerMappingCanvas.gd`
  - _Output_:
    - Pressing an input key sends `MidiManager.send_note_to_channel` on the Layer's channel.
    - Pressing an output key sends `DeviceInstance.audition_slot` for the selected slot.
    - Releasing sends the note-off, and the notes are stopped when the window closes.
  - _Verify_: live. Input 36 plays the kick. Output 49 with Cymbals selected plays key 49 even when
    nothing maps to it. No note hangs after closing the window mid-press.
  - _Depends on_: T-011

## Phase 4 — docs

- [x] **T-013** [REQ-all] Protocol, glossary and view docs.
  - _Files_: `docs/subsystems/osc-protocol.md`, `CONTEXT.md`, `docs/subsystems/godot-device-views.md`
  - _Output_:
    - `slot/{i}/note_map`, `slot/{i}/separate_out` and `slot/{i}/audition` are documented with
      their argument types.
    - Glossary entries for slot note map, full map, zoned slot and separate output.
    - A Layer view note in `godot-device-views.md`.
  - _Verify_: all three messages appear in `osc-protocol.md`, and the terms appear in `CONTEXT.md`.
  - _Depends on_: T-004

## Revision 2026-09-29 — names, colours, routing

- [x] **T-015** [REQ-020] Engine: aux sources run their first device once, even when not a route
  target.
  - _Files_: `Engine/src/audio/mixing.rs`
  - _Verify_: `cargo test aux_source_whose_returns_route_elsewhere_runs_once` passes, and fails
    (2 calls) with the old `begin_device_chain(0, …)`. The full suite is green (217) and
    `fmt --check` is clean.
  - _Depends on_: T-002

- [x] **T-016** [REQ-017] Inline slot rename in `LayerSlotRow` (`SmartLineEdit`).
  - _Files_: `Godot/devices/container/LayerSlotRow.gd`
  - _Verify_: `test_layer_mapping_window.gd` `_test_slot_row_rename`. Live: double-click renames,
    and a single click still opens the slot.
  - _Depends on_: T-008

- [x] **T-017** [REQ-018, REQ-019] Two-way name and colour sync between a separate slot and its
  return.
  - _Files_: `Godot/data/AuxReturnSync.gd`
  - _Verify_: `test_layer_separate_out.gd` `_test_name_sync` and `_test_color_sync`.
  - _Depends on_: T-007

- [x?] **T-018** [REQ-020] Free routing for Layer returns.
  - _Files_: `Godot/data/Channel.gd`, `Godot/data/AuxReturnSync.gd`
  - _Verify_: `test_layer_separate_out.gd` `_test_route_is_free` (headless). Live: route the snare
    return to a "Perc High" bus from the mixer strip's output button, and hear it there.
  - _Depends on_: T-007, T-015

- [x?] **T-019** [REQ-021, REQ-022] `LayerSlotRow`: the name widens to fit its text, and the knob
  drives the return channel's volume while OUT is on.
  - _Files_: `Godot/devices/container/LayerSlotRow.gd`
  - _Verify_: `test_layer_mapping_window.gd` `_test_slot_row_knob_follows_out` and
    `_test_slot_row_name_width`. Live: a long name grows the Layer panel.
  - _Depends on_: T-016

- [x?] **T-020** [REQ-023] Layer returns shown as a pad lane (slot chain first).
  - _Files_: `Godot/data/AuxReturnSync.gd` (`get_layer_slot`), `Godot/devices/PadLane.gd`
    (`front_device`), `Godot/devices/PadLaneWatcher.gd`
  - _Verify_: `test_layer_separate_out.gd` `_test_lane_shows_slot`. `test_multi_out_devices.gd`
    and `test_device_slots.gd` still pass. Live: the return's mixer strip and device lane show the
    slot's devices.
  - _Depends on_: T-007
  - _Note_: Godot treats `bind()`s of one method as the same connection, so the Layer colour
    follower is connected once per Layer, not once per slot.
  - _Revised_: the lane flattens the slot chain (`PadLane.front_devices`); covered by
    `_test_lane_flattens_slot_chain`. Dropping an asset into the slot's part is a live check.

- [x?] **T-021** [REQ-024] The OUT button resets the slot volume to unity (one macro with the toggle).
  - _Files_: `Godot/devices/container/LayerSlotRow.gd`
  - _Verify_: `test_layer_mapping_window.gd` `_test_out_resets_slot_volume`.
  - _Depends on_: T-019

- [x?] **T-022** [REQ-025] Layer as an Auto note map source.
  - _Files_: `Godot/data/NoteMapResolver.gd` (`find_auto_source`, `layer_map`,
    `has_zoned_slot`), `Godot/data/NoteMapWatcher.gd`
  - _Verify_: `test_layer_note_map.gd` `_test_auto_map_from_layer` and `_test_auto_map_watcher`.
    `test_note_map.gd` still passes. Live: Drum View rows appear after zoning.
  - _Depends on_: T-006

## Phase 5 — live verification

- [ ] **T-014** [REQ-all] End-to-end check with the engine and Godot running.
  - _Files_: `TODO.md`, `STATUS.md` if anything fails
  - _Output_: the `TODO.md` entry is marked `[x]`, or the gaps are listed.
  - _Verify_:
    1. Build an "Orchestral Drums" channel whose Layer holds three SFZs (kick, snare, cymbals).
    2. Zone each slot with a range drag, then Distribute.
    3. Turn on the separate output for each slot.
    4. Write a clip using the distributed keys. Playback and the virtual keyboard sound the same
       instruments (REQ-004), and each instrument meters on its own strip only (REQ-005).
    5. Remap a cymbal while a long note is held: no stuck note (REQ-002).
    6. Save, reload and play again: identical (REQ-016).
    7. Open an older project that has a Layer: every slot still plays every note.
  - _Depends on_: T-008, T-011, T-012, T-013
