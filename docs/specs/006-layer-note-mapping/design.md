# Layer Note Mapping — Design

Implements [requirements.md](./requirements.md).

## Context

Engine:

- `Engine/src/audio/devices/layer.rs`: `LayerSlot` { `device`, `volume`, `mute`, `solo` } and
  `LayerDevice`. `send_midi_event` forwards every event to every slot, and `process_block` mixes
  every slot. It implements `DeviceContainer` (`insert_child`, `remove_child` and `move_child` move
  whole `LayerSlot`s through `insert_into_vec` / `remove_from_vec` / `move_in_vec`).
- `Engine/src/audio/devices/drum_machine.rs`: the model for extra outputs.
  `extra_output_bus_count()` returns `slots.len()`, and `process_block_with_extra` writes slot `i`
  to `extra_outs[i]` when `i < extra_outs.len()`, otherwise to the main mix.
- `Engine/src/audio/devices/mod.rs`: `AudioDevice::extra_output_bus_count` /
  `process_block_with_extra` (the default fills the extra buses with silence).
- `Engine/src/audio/types.rs`: `Channel::set_aux_out` grows `extra_out_targets` /
  `extra_out_buffers` on the command thread. `Channel::process_aux_source` calls
  `devices[0].process_block_with_extra`, so only the first root device can be a multi-out source.
- `Engine/src/audio/mixing.rs`: `mix.has_aux_source` is set when any `extra_out_targets` entry is
  non-zero. `process_aux_sources` → `copy_extra_outs_to_targets` copies buses into child channels.
- `Engine/src/audio/commands.rs`: `AudioCommand::SetLayerSlotVolume` / `SetLayerSlotMute` /
  `SetLayerSlotSolo` downcast `channel.device_at_path_mut(&device_path)` to `LayerDevice` under the
  state lock.
- `Engine/src/osc/server.rs`: the device action match (`["slot", slot_str, "volume"]` etc.) under
  `/channel/{id}/device/{path}/…`. `OscType::Blob` is already used for outgoing device data.

Godot:

- `Godot/data/DeviceInstance.gd`: Layer slot fields `slot_volume` / `slot_mute` / `slot_solo`, the
  setters `set_slot_volume` etc. (each calls `sync_slot_to_engine()` and emits `slot_changed`),
  `sync_slot_to_engine()` (sends `slot/{position}/…` when the parent is `sonara.builtin.layer`),
  `return_channel_id`, `detached_returns`, and `to_json` / `from_json`.
  `Channel.gd:899` calls `sync_slot_to_engine()` when a device is synced, so anything added there is
  re-sent on load and reconnect.
- `Godot/data/AuxReturnSync.gd`: return channels for multi-out sources (spec 001). Drum pads use
  `return_channel_id` on the child, `_detach_return` / `detached_returns` for undo, and
  `sync_aux_map_to_engine` to send `/channel/{id}/aux_out`. Hooks are `on_device_added`,
  `on_device_removed`, `on_device_moved` and `ensure_all`. `extra_out_count`, `get_return_channel`
  and `get_source` special-case the Drum Machine.
- `Godot/data/Channel.gd`: `is_plugin_return()` (`aux_bus_index >= 0 and aux_pad_note < 0`) blocks
  deleting a return on its own. Signal `device_removed`.
- `Godot/devices/builtin/LayerDefaultView.gd` and `Godot/devices/container/LayerSlotRow.gd`: the
  Layer device view, with one row per slot (light, name, volume knob).
- `Godot/components/VPiano.gd`: a vertical piano driven by a shared `LaneLayout`
  (`Godot/clip_editor/LaneLayout.gd`, `LaneLayout.chromatic()`, `row_height`, `pitch_to_y`,
  `y_to_pitch`). Signals `key_pressed` / `key_released`.
- `Godot/clip_editor/note_map/NoteMapEditorDialog.gd`: an existing `Window` with a `VPiano`. It's
  the pattern the mapping window follows.
- `Godot/history/HistoryUtil.gd`: `execute_property(label, target, setter_name, old, new)` and
  `execute_many(label, cmds)`, built on `PropertyCommand` and `MacroCommand`.
- `Godot/midi/MidiManager.gd`: `send_note_to_channel(channel_id, note, velocity, is_note_on)`.

## Approach

**A 128-entry table per slot.** Each `LayerSlot` gets `note_map: [u8; 128]` (input → output,
`NOTE_NONE = 255` for "not mapped") and `held: [u8; 128]` (input → the output note its sounding
note-on went to). A note-on looks up `note_map`, records the output in `held`, and forwards it. A
note-off only reads `held`, so remapping, muting or moving a slot mid-note can't strand a note
(REQ-002). Both arrays live inside `LayerSlot`, so they move with the slot on reorder and are
allocated once, when the slot is created. The full map is the identity table, so new slots behave
as today (REQ-003). Live input and playback already reach the Layer through the same
`send_midi_event`, so REQ-004 comes for free.

Godot owns the map. It sends the whole 128-byte table as one OSC blob whenever it changes. Edits
are human-speed, and a whole-table send keeps the engine stateless about edit operations. All edit
logic (connect, range connect, disconnect, shift, clear, reset, resolve overlaps, distribute) lives
in one static GDScript helper over `PackedByteArray`, so it can be tested headless without the
window. Each edit replaces a slot's map through a normal setter (`set_slot_note_map`) wrapped in
`HistoryUtil.execute_property`, so undo needs no new command class. Multi-slot actions (Resolve,
Distribute) use `execute_many`.

**Separate outputs** reuse spec 001's machinery. `LayerDevice` reports `slots.len()` extra buses
(bus index = slot index, like the Drum Machine) and gets a per-slot `separate_out` flag. In
`process_block_with_extra`, a separate slot with an allocated bus writes its gained audio there,
and every other slot mixes into the main output. In plain `process_block` (a Layer that isn't first
on the root chain) the flag is ignored and everything mixes, so audio is never lost (REQ-007). In
Godot, `AuxReturnSync` gets a Layer branch next to the Drum Machine one. It creates, detaches and
re-attaches the slot's return through `return_channel_id` / `detached_returns`, which gives the
"same id and settings on undo" behaviour for free. Layer returns have `aux_pad_note = -1`, so the
existing `is_plugin_return()` rule already blocks deleting them on their own.

**Output-key auditioning** needs to reach one slot and bypass its map. A new
`slot/{i}/audition` action calls the slot device's `send_midi_event` directly from the command
thread under the state lock (the audio callback can't be inside the device then). It doesn't touch
`held`.

Rejected alternatives:
- *A key mask plus a transpose per slot.* This can't express Distribute (non-contiguous inputs to
  arbitrary outputs), and it's the same work in the engine as a table.
- *A new container device.* It would duplicate Layer's slots, volume/mute/solo and view, and leave
  users choosing between three containers. See the discussion that led to this spec.
- *Sending per-entry OSC edits.* That adds engine-side edit logic and ordering risk for no gain at
  128 bytes per change.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `LayerSlot::note_map` `[u8; 128]` | written by the command thread (`SetLayerSlotNoteMap`) under the state lock | read by the audio callback in `send_midi_event` under its `try_lock` | yes. Fixed-size copy, no allocation |
| `LayerSlot::held` `[u8; 128]` | audio callback (`send_midi_event`), cleared in `reset` | command thread only through `reset` / slot removal, under the state lock | yes |
| `LayerSlot::separate_out` `bool` | command thread (`SetLayerSlotSeparateOut`) | read in `process_block_with_extra` | yes |
| Extra-out buffers for Layer buses | `Channel::set_aux_out` on the command thread (already allocates there) | `process_aux_source` → `process_block_with_extra` | yes (unchanged path) |
| Slot audition note | command thread calls `slot.device.send_midi_event(…, 0)` under the state lock | the device's own MIDI queue, drained in its next `process_block` | yes, as long as each device's `send_midi_event` only enqueues (already required by the trait) |
| `AudioCommand::SetLayerSlotNoteMap { map: Box<[u8; 128]> }` | allocated on the OSC main thread, dropped on the command thread after copying | crossbeam channel | not on the audio thread |

## Data and protocol changes

New OSC messages under `/channel/{id}/device/{path}/…`, Godot → engine:

| Address suffix | Args | Command |
|---|---|---|
| `slot/{i}/note_map` | blob, exactly 128 bytes; byte *n* = output note for input *n*, 255 = unmapped | `AudioCommand::SetLayerSlotNoteMap { channel_id, device_path, slot, map }` |
| `slot/{i}/separate_out` | int 0/1 | `AudioCommand::SetLayerSlotSeparateOut { channel_id, device_path, slot, separate }` |
| `slot/{i}/audition` | int note, int velocity, int on (0/1) | `AudioCommand::AuditionLayerSlot { channel_id, device_path, slot, note, velocity, on }` |

A blob that isn't exactly 128 bytes is logged with `warn!` and ignored. Each needs the handler in
`osc/server.rs`, the variant plus its apply arm in `audio/commands.rs`, and a row in
`docs/subsystems/osc-protocol.md`. Return routing reuses the existing `/channel/{id}/aux_out`.

Godot model (`DeviceInstance`, meaningful when the parent is a Layer):

- `slot_note_map: PackedByteArray` (128 bytes; the identity table by default), with setter
  `set_slot_note_map(map)` and signal `slot_changed` (already emitted by the slot setters).
- `slot_separate_out: bool`, with setter `set_slot_separate_out(on)`. The setter calls
  `AuxReturnSync.on_layer_slot_separate_changed(project, channel, layer, slot)` and emits
  `slot_changed`.
- `sync_slot_to_engine()` also sends `slot/{position}/note_map` and `slot/{position}/separate_out`
  in its Layer branch. Load and reconnect already go through it (`Channel.gd:899`).

Persisted keys in the device JSON (`to_json` / `from_json`):

- `slot_note_map`: an array of 128 ints, **written only when the map isn't the full map**. Missing
  means full (REQ-016).
- `slot_separate_out`: bool, default `false`.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/devices/layer.rs` | `NOTE_NONE`. `LayerSlot` gains `note_map`, `held` and `separate_out` (identity / NONE / false in `LayerSlot::new`). `set_slot_note_map(index, &[u8; 128])`, `set_slot_separate_out(index, bool)` and `audition_slot(index, note, velocity, on)`. `send_midi_event` routes through the map and `held` (note-on to an input already in `held` sends a note-off for the old output first). `reset` clears `held`. `extra_output_bus_count` → `slots.len()`. New `process_block_with_extra`, sharing the gain/mute/solo logic with `process_block`. Tests in `mod tests` |
| `Engine/src/audio/commands.rs` | Variants `SetLayerSlotNoteMap`, `SetLayerSlotSeparateOut` and `AuditionLayerSlot`, with apply arms modelled on `SetLayerSlotVolume` (downcast to `LayerDevice`, `warn!` on a bad slot or device) |
| `Engine/src/osc/server.rs` | Three new device-action arms (`["slot", s, "note_map"]`, `["slot", s, "separate_out"]`, `["slot", s, "audition"]`) next to `["slot", slot_str, "solo"]` |
| `docs/subsystems/osc-protocol.md` | Document the three messages |
| `Godot/data/LayerNoteMap.gd` (new) | `class_name LayerNoteMap`, static helpers over `PackedByteArray`: `NONE`, `full()`, `empty()`, `is_full()`, `inputs(map)`, `connect_note(map, in, out)`, `connect_range(map, inputs, out_start)`, `disconnect_notes(map, inputs)` (not `connect`/`disconnect`, which would shadow `Object` methods), `shift(map, inputs, delta)`, `resolve_overlaps(maps: Array) -> Dictionary` and `distribute(maps: Array) -> Dictionary` (each returns `{maps, skipped}`). Every editing helper treats a full map as empty first (REQ-011). Pure functions, no engine or model access |
| `Godot/data/DeviceInstance.gd` | `slot_note_map`, `slot_separate_out`, their setters, the `sync_slot_to_engine()` additions, and the `to_json` / `from_json` keys. `audition_slot(note, velocity, on)` sends `slot/{position}/audition` |
| `Godot/data/AuxReturnSync.gd` | `is_layer(device)`. `extra_out_count`, `get_return_channel` and `get_source` gain a Layer branch (bus = child index, return = the child's `return_channel_id`, only for `slot_separate_out` children). `on_layer_slot_separate_changed` (on: re-attach from the child's `detached_returns` or `_create_return_channel` named after the slot; off: `_detach_return`). `on_device_added` / `on_device_removed` / `on_device_moved` / `_ensure_root` handle Layer children the way they handle pads, except that removing a slot detaches its return rather than keeping it. A `sync_layer_aux_order` keeps bus indices equal to child order after moves |
| `Godot/devices/container/LayerSlotRow.gd` | A small "separate output" toggle per row. It is disabled with an explanatory tooltip when the Layer isn't `channel.devices[0]` (REQ-007), and goes through `HistoryUtil.execute_property(…, "set_slot_separate_out", …)` |
| `Godot/devices/builtin/LayerDefaultView.gd` | A "Mapping…" button that calls `LayerMappingWindow.open_for(device)` |
| `Godot/devices/container/layer_mapping/LayerMappingWindow.gd` (new) | `class_name LayerMappingWindow extends Window`. A static `open_for(layer)` keeps one window per Layer id and focuses an existing one (REQ-008), parented to `Sonara.editor`. Layout: a slot `ItemList`; a toolbar (Clear, Reset, Shift ±1/±12, Resolve overlaps, Distribute, and a status label for skipped slots); and a `ScrollContainer` holding [input `VPiano`][`LayerMappingCanvas`][output `VPiano`], which share one `LaneLayout`, so scroll and zoom are joint (REQ-009). It closes when the Layer leaves its channel: it listens to the channel's `device_removed`, each ancestor container's `child_removed` and `Project.channel_removed`, then re-checks attachment. Edits go through `HistoryUtil` on `set_slot_note_map`, and it listens to `slot_changed` / `child_*` to redraw |
| `Godot/devices/container/layer_mapping/LayerMappingCanvas.gd` (new) | The middle `Control`, draw-only. It draws connections for all zoned slots (faded unless selected), the selected-input band, and the rubber-band line while dragging (REQ-010). *Revised during implementation:* input handling (selection, drag to connect, Delete, arrow-key shifts) lives in `LayerMappingWindow`, which already receives the pianos' `key_pressed` signals and the window-level `_input`. Input-key slot colours, overlap marks ("Kick + Snare" in red) and output highlights are `NoteMap`s set on the pianos, and the "all notes" state is shown in the status line |
| `Godot/components/VPiano.gd` | *Revised during implementation:* no change. `VPiano.note_map` already tints and names keys, so the window builds `NoteMap`s for both pianos |
| `Godot/tests/test_layer_note_map.gd` (new) | Pure `LayerNoteMap` tests, model setter + undo, and persistence |
| `Godot/tests/test_layer_separate_out.gd` (new) | Return channel create / remove / undo / no track / aux map |
| `Godot/tests/test_layer_mapping_window.gd` (new, added during implementation) | Headless smoke test of the window (one per Layer, piano/canvas state, edits, Distribute as one macro, close on removal) and the `LayerSlotRow` OUT toggle's enabled state |
| `CONTEXT.md` | Terms: slot note map, full map, zoned slot, separate output |
| `docs/subsystems/godot-device-views.md` | A short note on the Layer view's mapping window and separate-output toggle |

## Revision 2026-09-29: names, colours, routing (REQ-017–020)

- **Rename:** `LayerSlotRow` shows the name in a `SmartLineEdit` (double-click to edit, through
  `DeviceActions.rename`, one undo step). A single click still opens the slot.
- **Name and colour sync:** `AuxReturnSync._bind_layer_return` links a separate slot and its return
  both ways:
  - the return's `name_changed` renames the slot;
  - the existing pad-rename follower (`_bind_pad`) renames the return from the slot;
  - the return's `color_changed` calls `layer.set_slot_color`;
  - `layer.slots_changed` recolours the return.
  At bind time, the slot's name and colour win. `_unbind_layer_return` drops the links when the
  return is detached. Undo needs nothing extra: undoing either rename or recolour moves the other
  side through the same links.
- **Routing:** `Channel.route_locked()` is false for `Channel.is_layer_return()` (an aux return
  whose source is a Layer, via `AuxReturnSync.get_source`), so the mixer and track IO menus offer
  Master and valid buses. The return stays nested. `ensure_layer_return` restores the saved route
  after `_attach`, because `Project.nest_channel` routes to the parent. The route is saved like any
  channel's. This revises spec 001's output lock for Layer returns only.
- **Engine fix** (`Engine/src/audio/mixing.rs`): the device pass starts at device 1 for a channel
  with `mix.has_aux_source`. A Layer whose returns all route to buses isn't a route target, and it
  used to run its first device twice (once in the aux pass, once in the device pass). Test:
  `aux_source_whose_returns_route_elsewhere_runs_once`.

## Migration and compatibility

- Older `.sonara` files have no `slot_note_map` / `slot_separate_out`, so they load as the full map
  with separate output off, which is exactly today's behaviour. A project with only full maps saves
  without the new keys.
- A newer project opened in an older build: the unknown keys are ignored, and Layers play every
  note on every slot. Layer returns become unowned nested channels (the same failure mode as spec
  001, so it's acceptable).
- The Drum Machine and its returns are untouched. The engine's Drum Machine code doesn't change.

## Test plan

- **Unit (engine):** `cargo test layer` in `Engine/src/audio/devices/layer.rs`:
  - `layer_routes_note_through_slot_maps`: REQ-001, the 36 → 36 / 36 → 49 / unmapped example,
    checking note and `frame_offset` with a recording test device.
  - `layer_note_off_follows_held_note_after_remap`: REQ-002, remap mid-note.
  - `layer_note_off_follows_held_note_after_move`: REQ-002, `move_child` mid-note.
  - `layer_fresh_slot_is_full_map`: REQ-003.
  - `layer_separate_slot_writes_extra_bus`: REQ-005. The separate slot's audio is on
    `extra_outs[i]` and not the main output, the non-separate slot is on main, and a separate slot
    beyond `extra_outs.len()` falls back to main.
  - `layer_process_block_ignores_separate_flag`: REQ-007 (no audio lost when not first).
  - `layer_audition_bypasses_map`.
- **Godot:** `godot --headless --path Godot -s tests/test_layer_note_map.gd -- --test`:
  connect, range, disconnect, shift, clear and reset (REQ-011, REQ-012); the full map turning empty
  on the first edit; `resolve_overlaps` on the REQ-014 example; `distribute` on the REQ-015
  example; a full-map slot skipped by both; `set_slot_note_map` undo; and a save → load round trip
  plus a legacy JSON without the keys (REQ-016).
- **Godot:** `godot --headless --path Godot -s tests/test_layer_separate_out.gd -- --test`: the
  REQ-006 steps (return created, no track, −6 dB survives off → undo with the same id), slot
  removal detaching and undo restoring, and the aux map bus index following slot moves.
  `Godot/tests/run_all.sh` stays green.
- **Live:** REQ-004 (virtual keyboard and clip playback on a remapped key), REQ-005 (the snare
  through its own strip), REQ-007 (tooltip / disabled toggle with a Delay first), REQ-008–010 and
  REQ-013 (window, layout, lines, auditioning).

## Risks

| Risk | Mitigation |
|---|---|
| A device's `send_midi_event` isn't safe to call from the command thread (auditioning) | The state lock excludes the audio callback. Check `SubprocessAdapter`'s and sfizz's `send_midi_event` only enqueue. If one doesn't, route auditioning through the channel `midi_queue` with a target slot instead |
| Bus index = slot index, so moving slots re-points returns | `sync_layer_aux_order` resends the full aux map after every move, as `sync_pad_aux_order` does, and it's covered by `test_layer_separate_out.gd` |
| A note-on arriving for an input that's already held (overlapping clip notes) | The note-off for the previous output is sent first, then the new note-on is recorded. Unit tested |
| The mapping canvas is slow with 16 slots × 128 lines | Only draw lines for zoned slots and visible rows. A full-map slot is a single "all notes" state |
| The window outlives its Layer and edits a detached `DeviceInstance` | Close on removal (REQ-008), and guard every edit with an attachment check |

## Open questions

- [x] `VPiano` tinting: neither. `VPiano.note_map` already does it, so the window builds a
      `NoteMap` for each piano.
