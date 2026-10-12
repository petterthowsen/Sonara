# Device Chain Slots — Design

Implements [requirements.md](./requirements.md).

## Context

Engine:

- `Engine/src/audio/devices/device.rs`: the `AudioDevice` trait. Containers expose children
  through `as_container` / `as_container_mut` (`DeviceContainer`), and `is_container()` is what
  `/builtin/info` advertises (`factory.rs` `builtin_device_info`).
- `Engine/src/audio/devices/containers/container.rs`: `DeviceContainer` (`child_count`, `child`,
  `child_mut`, `insert_child`, `remove_child`, `move_child`, `chain_children_mut`),
  `DevicePath`, and `insert_device` / `remove_device` / `move_device`, which every structural
  edit goes through (`command_worker/devices.rs`, and `modulation/host.rs` `wrap_at_path` /
  `unwrap_at_path`).
- `Engine/src/audio/devices/containers/chain.rs`: `ChainDevice`, the serial container that
  already serves as every Layer, Drum Machine and Multiband slot chain. It runs
  `run_note_phase` and then `process_serial_chain`. It has no `prepare`, so its ping-pong buffers
  keep the size they were created with.
- `Engine/src/audio/devices/effects/multiband.rs`: `MultibandDevice`, the precedent for an effect
  with fixed slot chains as children. Its six band chains are created by **Godot**
  (`Multiband.ensure_chains`) and sent with `add_device`.
- `Engine/src/audio/devices/note_fx/routing.rs`: `route_note`, `route_cc`, `run_note_phase`
  (which takes an optional `sink` for notes that fall off the end of the chain),
  `release_note_effects` and `release_note_effect_at`. The release functions route through the
  private `route_output` with no sink, so notes falling off the end are dropped.
- `Engine/src/audio/channel/chain.rs`: `release_note_effect_at`, `release_note_effects_in` and
  `stop_clip_notes` (which calls `note_discontinuity` on every nested note effect through
  `visit_devices_mut`). `audio/channel/mod.rs` `chain_list_mut` resolves a parent path to its
  `chain_children_mut`.
- `Engine/src/audio/modulation/host.rs`: `ModulatedDevice` wraps a device that has modulators. It
  forwards the trait method by method and splits `process_block` into `CONTROL_STEP` (64-frame)
  windows unless `has_async_blocks()` is true, in which case it calls `begin_block` /
  `finish_block` on the whole block.
- `Engine/src/audio/devices/instruments/polysynth/mod.rs`: `PolySynthDevice`. Notes go into
  `queued_midi` through `send_note_event`. `process_block` renders the voices. The device sleeps
  through `sleep_state: DeviceSleepState`, and `prepare` allocates its scratch.
- `Engine/src/audio/devices/effects/delay.rs`: `DelayDevice::process_block` is one per-sample
  loop. It reads the taps (`taps[ch].advance`, `line[ch].read_hermite`), applies tone and drive
  (`wet`), computes `own_fb = soft_clip(w * fb)`, cross-feeds it and pushes it with the input
  (`line[ch].push`). Sleep is `tail: TailSleep`.
- `Engine/src/audio/devices/effects/reverb.rs`: `ReverbDevice::process_sample` takes the
  pre-delay, the early reflections and the diffuser, then `late()` (FDN `process` or the Plate's
  two `PlateTank::process` calls), then decorrelation, tone, ducking and width. `process_block`
  then applies `dry_wet_gains`. The FDN per sample reads 8 lines, computes
  `y = absorb·gain`, applies Householder `y − 2·mean` and pushes it with the injection. A
  `PlateTank` reads, absorbs, stores `inx` (the other tank's last decayed output plus the input)
  and keeps `last` for cross-coupling.
- `Engine/src/osc/encode.rs` (`EngineStatus::BuiltinDeviceInfo` → `/builtin/info`) and
  `audio/commands/status.rs` (`BuiltinDeviceInfo` fields).

Godot:

- `Godot/data/Device.gd`: `is_container`, `creates_instrument_track`,
  `container_focuses_one_child`, `uses_simple_view` (false for every container).
- `Godot/data/DeviceRegistry.gd` `_on_builtin_info_received` parses `/builtin/info`, then
  `_parse_default_modulators`.
- `Godot/data/DeviceInstance.gd` "CONTAINER SLOTS": `slot_keys`, `has_slot`, `slot_chain`,
  `slot_devices`, `slot_key_for`, `slot_title`, `slot_color` / `set_slot_color`, `set_slot_open`
  (one open at a time when `container_focuses_one_child`), `_slots_to_json` / `_slots_from_json`.
  `_init` and `from_json` call `Multiband.ensure_chains`.
- `Godot/data/Multiband.gd` and `Godot/data/SlotChain.gd`: fixed band chains and slot chain
  wrapping.
- `Godot/data/Channel.gd`: `add_device`, `_send_add_device_osc`,
  `_sync_device_tree_to_engine` (sends `add_device` for every child, recursively).
- `Godot/devices/DeviceDropUtil.gd`: `device_fits_host`, `can_drop_instance_on_host` (refuses
  `Multiband.is_band_chain`), `can_drop_on_container`, `drop_on_container`.
- `Godot/history/commands/DeviceAddCommand.gd` redirects a device added straight into a
  Multiband to a band chain. `DevicePresetLoadCommand.gd` swaps the whole instance, so children
  come from the preset.
- `Godot/devices/DeviceContextMenu.gd` and `Godot/ai/tools/RemoveDeviceTool.gd` special-case
  `Multiband.is_band_chain`. `Godot/ai/tools/DeviceToolUtil.gd` and `AiTool.gd` check
  `parent.is_container()`.
- `Godot/components/DeviceSlotButton.gd`: the slot tile (`bind_to_slot`, `_draw` with
  `container.slot_color(key)`), already used by `ChainDefaultView`.
- `Godot/devices/device_lane/DeviceSlotGroup.gd`: the lane bracket in `container.slot_color(key)`.
- Simple View: `SimpleLayoutGenerator.gd` (`generate`, `build_pages`, `VERSION` = 14),
  `GridPacker.gd` (`pack_pages`, `make_control`), `SimpleLayout.gd` (`_page_from_dict`,
  `validate`, `reconcile`, `_place_on_last_page`), `SimpleLayoutStore.gd`
  (`load_or_generate`), `SimpleControlKinds.gd`, `SimpleControl.gd` (`bind`, `_build_inner`),
  and `SimpleView.gd` (`_add_control`).
- `Godot/core/UiColors.gd` `role()`. The roles are `accent_primary` and `accent_secondary`
  (`core/theme/ThemePalette.gd`).
- `Godot/arranger/tracklist/AutomationParameterPicker.gd` `_add_device` already recurses into
  `children`.
- `Godot/dawproject/DawProjectExporter.gd` writes a built-in device as `BuiltinDevice` with its
  full `to_json()` (children included) as state. `TransferReport.gd` holds the report kinds.

## Approach

**Slot chains are owned by the engine.** A slotted device creates its slot `ChainDevice`s in
its constructor and exposes them as fixed container children (child *i* = slot *i*). Godot
mirrors them as children of the `DeviceInstance` (so paths, saving, presets, automation and
modulator routes work unchanged), but never sends `add_device`, `remove_device` or
`move_device` for a slot chain itself. Devices inside a slot are added at
`{device}/child/{slot}` like any slot chain's devices.

*Rejected: Godot-owned slot chains like Multiband's bands.* The engine device would exist without
its slots until Godot's `add_device` messages arrive, so parameter and route messages for slot
devices could race the chain's creation. An engine test couldn't build a slotted device on its own
(REQ-001). The engine also couldn't tell which slot a chain is, so it couldn't enforce what a slot
accepts (REQ-017).

A slotted device declares its slots once, as a `&'static [SlotSpec]` (key, name, kind:
`Note`, `Audio` or `Loop`), through a new `AudioDevice::device_slots()`. `/builtin/info` sends
it as a trailing block, and Godot builds everything else from that list: the slot keys, the drop
rules, the tiles and the colours. A shared `DeviceSlots` helper holds the chains and the scratch
buffers and implements the `DeviceContainer` plumbing. Each device decides only *where* in its
signal path each slot runs:

- **PolySynth Note FX.** `send_note_event` routes the note through the Note FX chain's children
  with `route_note`. A note that falls through (empty slot, or no note effect took it) goes
  straight into `queued_midi`. At the start of `process_block`, `run_note_phase` runs over the slot
  with a sink, and the sink's notes are queued at their frames. CC goes through `route_cc` as
  well.
- **PolySynth FX** runs `ChainDevice::process_block` on the rendered output.
- **Reverb Wet FX** splits `process_block` into two passes when the slot is in use: compute the
  wet signal for the block into scratch, run the chain, then mix.
- **Loop slots (Delay FB FX, Reverb Tank FX)** run in sub-blocks of `LOOP_BLOCK` = 64 frames
  (1.45 ms at 44.1 kHz, 1.33 ms at 48 kHz). Each sub-block has three phases: a **read phase** runs
  the existing per-sample code but stores the loop signal instead of pushing it, the **chain
  phase** processes that signal through the slot, and the **write phase** pushes it into the
  lines. That's only correct if no line is read within `LOOP_BLOCK + 2` samples of being written
  (Hermite needs ±2), so while a loop slot is in use the loop delay is held at or above that
  minimum by a smoothed floor (REQ-010).
  - **Delay:** the chain processes the stereo `own_fb` pair (after the feedback gain and soft
    clip), before the cross-feed. The first repeat comes straight from the line, so it isn't
    processed; every later repeat has gone through the slot once more (REQ-007).
  - **Reverb FDN (Room, Hall):** after the Householder step, the 8-line feedback vector `f` is
    projected onto the two output directions `u_L = FDN_OUT_L/√8` and `u_R = FDN_OUT_R/√8`. These
    are orthogonal, and they are exactly what the listener hears. The stereo pair `(u_L·f, u_R·f)`,
    scaled to the output level by `out_scale·√8` so a Saturator or Compressor sees the level it
    would see on the output, goes through the chain. Only the difference is added back:
    `f' = f + (a'−a)·u_L + (b'−b)·u_R`. A unity chain leaves `f` untouched. Because the matrix keeps
    rotating energy into the projected plane, every pass is shaped by the slot (REQ-008).
  - **Reverb Plate:** the stereo pair is the two tanks' decayed outputs `(d0, d1)`, which are what
    cross-couples. The write phase stores `v + d'_other[n−1]`, with the last processed value
    carried across sub-block edges in `PlateTank::last`. The output taps are still read in the
    write phase, in the same order as today.
  - While the algorithm crossfades (`late()` runs `prev` and `current`), only the current
    algorithm runs through Tank FX. The fading one finishes on the plain path.
- **Empty or all-bypassed slots** keep today's code path exactly. Every device checks
  `DeviceSlots::is_live(slot)` once per block, which is how REQ-002 gets sample identity rather
  than a near match.

**Releases in the Note FX slot.** `Channel::release_note_effect_at` / `release_note_effects_in`
resolve the slot chain through `chain_list_mut` and release into nothing, so the note-offs never
reach the PolySynth. A new `AudioDevice::release_slot_notes(slot, index)` handles this case:
`Channel` calls it on the slotted device when the parent path is a note slot, and PolySynth runs
new sink-taking variants of the release helpers and queues the note-offs at frame 0 (REQ-004).
Transport discontinuities already reach nested note effects (`visit_devices_mut`), and they drain
through the Note FX note phase into the sink.

**Plugins in FX and Wet FX.** `ModulatedDevice` splits a wrapped PolySynth into 64-frame windows,
which would cost a plugin in its FX slot one IPC round trip per window. A slotted device therefore
reports `has_async_blocks()` while any audio slot holds a device with async blocks. The wrapper
then calls `begin_block`, which runs the whole block synchronously (voices, then the slot) into
`DeviceSlots` scratch and returns true, and `finish_block` copies the result out. The trade-off is
that, while a plugin sits in the slot, mono modulation of the PolySynth's own parameters is
applied once per block instead of every 64 frames. Per-voice modulation is unaffected.

**Engine-side acceptance.** `container::insert_device` calls a new `slots::check_insert`,
which walks the parent path upwards and finds the innermost ancestor that is a slot chain of a
slotted device. It then checks the new device, including its nested children, against that slot's
kind (`SlotKind::accepts`). The rules: Note takes `is_note_effect()`. Audio rejects
`DeviceCategory::Instrument` and note effects. Loop also rejects `DeviceVariant::Clap` and any
async-block device (VST3 adapters). A rejection returns `Err` with the slot and device named, and
`command_worker/devices.rs` already logs `Err` as a warning (REQ-017). `DeviceSlots::insert_child`
(adding to the slotted device itself) always refuses with a warning, and `remove_child` and
`move_child` are no-ops, because the slots are fixed.

**Godot.** A new `data/DeviceSlots.gd` (static helpers, like `Multiband.gd`) is the single source
for slot behaviour. `Device.slots` holds the parsed specs. `DeviceInstance` gets its slot chains
from `DeviceSlots.ensure_chains`, keyed by spec key (`note_fx`, `fx`, `fb_fx`, `tank_fx`, `wet_fx`),
and the CONTAINER SLOTS functions branch on `DeviceSlots.is_slotted(self)` first. The device stays
`is_container` (it really does own children, and the lane and slot code rely on that), but every
place that means a *user* container excludes slotted devices: `uses_simple_view`,
`creates_instrument_track`, `can_drop_on_container`, and the AI tools' parent checks.

**Simple View.** A new control kind `slot` (footprint 2×1, no parameters) carries `"slot": key`.
`SimpleControl` builds a `DeviceSlotButton` for it, and the button gains a device count and drop
support. The generator appends a `column` group titled "Slots" as the last group of the Main
section before `GridPacker.pack_pages`, so the tiles land in the rightmost column of Main
(REQ-027). `SimpleLayout.reconcile_slots` drops tiles for unknown keys and appends missing tiles
at Main's right edge for layouts the user edited (REQ-028). `VERSION` goes to 15, so layouts the
user never edited are generated again.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `DeviceSlots.chains: Vec<Box<dyn AudioDevice>>` (the slot `ChainDevice`s) | inside the slotted device. Mutated by the command thread under the state lock (`insert_device` / `remove_device` on `{device}/child/{slot}`) | audio thread through the device's `process_block` / `send_note_event` / `send_cc` under the callback's `try_lock` | yes. The vector never changes length after construction, and chain children change only under the lock, as in any Chain |
| `DeviceSlots` scratch: `slot_buf` (stereo, max frames), `loop_in` / `loop_out` (stereo, `LOOP_BLOCK`), `note_sink: NoteBuffer` (`OUTPUT_CAPACITY`) | slotted device | audio thread | yes. Allocated in `DeviceSlots::new` and resized only in `prepare` (command thread, stream stopped) |
| Reverb loop scratch: `fdn_f: [[f32; 8]; LOOP_BLOCK]`, `fdn_inj: [[f32; 8]; LOOP_BLOCK]`, `plate_d: [[f32; 2]; LOOP_BLOCK]` | `ReverbDevice` | audio thread | yes. Fixed-size arrays |
| `loop_floor: SmoothedParam` (minimum loop delay in samples) | Delay / Reverb | audio thread, target set in `process_block` from `is_live(loop slot)` | yes |
| `ChainDevice` ping-pong buffers | `ChainDevice` | audio thread | yes. New `ChainDevice::prepare` resizes them on the command thread while the stream is stopped, which `prepare` allows |
| `SlotSpec` tables | `'static` | any | yes |

## Data and protocol changes

**OSC: `/builtin/info`** gains a trailing block after the default modulators:

```
i:slot_count,
repeat slot_count times: ( s:key, s:name, s:kind )   # kind: "note" | "audio" | "loop"
```

Old decoders stop after the default modulators and never read it. Changes:
`audio/commands/status.rs` (`BuiltinDeviceInfo.slots: Vec<(String, String, String)>`),
`factory.rs` `builtin_device_info` (fills it from `device_slots()`), `osc/encode.rs` (pushes the
block, and its test fixture near line 902 gains `slots: vec![]`), and
`docs/subsystems/osc-protocol.md`. No new addresses: slot devices use the existing
`/channel/{id}/device/{path}/add_device|remove_device|move_device` with `{path}` =
`{device}/child/{slot}`.

The slot specs (also listed in `CONTEXT.md`):

| Device | index | key | name | kind |
|---|---|---|---|---|
| `sonara.builtin.polysynth` | 0 | `note_fx` | Note FX | note |
| | 1 | `fx` | FX | audio |
| `sonara.builtin.delay` | 0 | `fb_fx` | FB FX | loop |
| `sonara.builtin.reverb` | 0 | `tank_fx` | Tank FX | loop |
| | 1 | `wet_fx` | Wet FX | audio |

**Godot models.** `Device.slots: Array[Dictionary]` (`{key, name, kind}`) and
`Device.has_device_slots()`. `DeviceInstance` keeps its slot chains in `children` in spec order.
Each chain's `name` is the spec name. `_slots_to_json` stores the open slot as before, and
`slot_color` returns a fixed role colour (`accent_secondary` for note, `accent_primary` for audio
and loop). `set_slot_color` ignores device slot keys.

**Persisted format.** Unchanged in shape: a slotted device's `to_json()` already writes
`children`, here its slot chains. On load, `from_json` clears the children `_init` created
(like Multiband), loads the saved ones, then `DeviceSlots.ensure_chains` fills in any missing ones,
renames them to the spec names and orders them by spec (REQ-030). Presets go through the same
`to_json` / `from_json` (`DevicePreset.gd`), and `DevicePresetLoadCommand` swaps whole instances,
so REQ-031 comes for free and only needs a test.

**Simple View layout JSON.** A control may be `{kind: "slot", params: [], slot: "<key>", rect, group}`.
`_page_from_dict` keeps the `slot` key.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/devices/slots.rs` (new) | `SlotKind {Note, Audio, Loop}` with `as_str` and `accepts(&dyn AudioDevice) -> Result<(), String>` (recursive over `as_container` children). `SlotSpec {key, name, kind}`. `LOOP_BLOCK = 64`. `DeviceSlots` (chains, scratch, `new(specs, max_frames)`, `prepare`, `chain_mut(i)`, `is_live(i)` = any enabled child, `has_async(i)`, `DeviceContainer` delegate methods, `note_sink`). `check_insert(devices, parent_path, &dyn AudioDevice)`. Unit tests |
| `Engine/src/audio/devices/mod.rs` | `mod slots;`, re-export `slots::{DeviceSlots, SlotKind, SlotSpec, LOOP_BLOCK}` |
| `Engine/src/audio/devices/device.rs` | `fn device_slots(&self) -> &'static [SlotSpec] { &[] }` and `fn release_slot_notes(&mut self, _slot: usize, _index: Option<usize>) {}` |
| `Engine/src/audio/modulation/host.rs` | forward `device_slots` and `release_slot_notes` on `ModulatedDevice` |
| `Engine/src/audio/devices/containers/chain.rs` | `impl prepare` that resizes `buf_a` / `buf_b` to `max_frames * 2` when larger |
| `Engine/src/audio/devices/containers/container.rs` | `insert_device` calls `slots::check_insert` before inserting into a container |
| `Engine/src/audio/devices/note_fx/routing.rs` | `release_note_effects_into(devices, sink)` and `release_note_effect_at_into(devices, index, sink)`. The existing functions call these with `None` |
| `Engine/src/audio/channel/chain.rs` | `release_note_effect_at` / `release_note_effects_in`: when `path.parent()` is slot *s* of a device with `device_slots()[s].kind == Note`, call that device's `release_slot_notes(s, Some(i)/None)` instead |
| `Engine/src/audio/devices/instruments/polysynth/mod.rs` | `slots: DeviceSlots` with `POLYSYNTH_SLOTS`. `send_note_event` / `send_cc` route through Note FX. `process_block` runs the note phase with the sink, then voices, then FX if live. `release_slot_notes`, `as_container[_mut]`, `is_container`, `device_slots`, `has_async_blocks`, `begin_block` / `finish_block`. `is_sleeping` is false while Note FX is live. `prepare` → `slots.prepare`. `reset` resets the chains |
| `Engine/src/audio/devices/effects/delay.rs` | `slots: DeviceSlots` with `DELAY_SLOTS`. `loop_floor`. When FB FX is live, `process_block` runs the three-phase sub-block path with the chain on `own_fb` and the floor applied in `target_samples`. Otherwise today's loop, untouched. Container methods, `device_slots`, `prepare`, `reset` |
| `Engine/src/audio/devices/effects/reverb.rs` | `slots: DeviceSlots` with `REVERB_SLOTS`. FDN and `PlateTank` split into `read` / `write` halves (`process` = read + write, so the plain path is unchanged). Sub-block loop path when Tank FX is live, with the projection (FDN) or the pair (Plate) and `loop_floor` on the line delays. Two-pass `process_block` when Wet FX is live. Container methods, `device_slots`, `has_async_blocks` / `begin_block` / `finish_block` for plugins in Wet FX, `prepare`, `reset` |
| `Engine/src/audio/devices/factory.rs` | `builtin_device_info` fills `slots` |
| `Engine/src/audio/commands/status.rs` | `BuiltinDeviceInfo.slots` |
| `Engine/src/osc/encode.rs` | encode the trailing slot block, and update the test fixture |
| `Godot/data/DeviceSlots.gd` (new) | `is_slotted(inst)`, `specs(inst)`, `is_slot_chain(inst)`, `spec_of(chain)`, `kind_for_host(host_parent)` (innermost slot kind above a host), `accepts(kind, Device)` / `accepts_instance(kind, inst)` (recursive), `ensure_chains(inst)`, `target_chain(inst, device)` (the slot a device dropped onto the slotted device goes into, or null), `role_color(kind)` |
| `Godot/data/Device.gd` | `var slots: Array[Dictionary]`, `has_device_slots()`. `uses_simple_view` allows slotted devices. `creates_instrument_track` excludes them |
| `Godot/data/DeviceRegistry.gd` | `_parse_device_slots(device, args, idx)` after `_parse_default_modulators` (which returns its end index) |
| `Godot/data/DeviceInstance.gd` | `_init` / `from_json` call `DeviceSlots.ensure_chains`, and `from_json` clears `_init`'s chains for slotted devices. CONTAINER SLOTS: `slot_keys`, `has_slot`, `slot_chain`, `slot_key_for`, `slot_title`, `slot_color`, `set_slot_color` and `set_slot_open` (one open) handle slotted devices |
| `Godot/data/Channel.gd` | `_sync_device_tree_to_engine`: skip `_send_add_device_osc` for children that are `DeviceSlots.is_slot_chain`, but still recurse |
| `Godot/devices/DeviceDropUtil.gd` | `device_fits_host` and `can_drop_instance_on_host` / `copy_fits_host` apply `DeviceSlots.kind_for_host` + `accepts`. `can_drop_instance_on_host` refuses slot chains. `can_drop_on_container` is false for slotted devices |
| `Godot/history/commands/DeviceAddCommand.gd` | parent is slotted → redirect to `DeviceSlots.target_chain`, or leave `device_instance` null (no-op) when no slot fits |
| `Godot/devices/DeviceContextMenu.gd` | slot chains: no Remove / Copy / Rename. "Clear Slot" removes the slot's devices |
| `Godot/ai/tools/RemoveDeviceTool.gd`, `Godot/ai/tools/DeviceToolUtil.gd`, `Godot/ai/tools/AiTool.gd` | refuse removing a slot chain and adding straight into a slotted device without a fitting slot, and apply the slot kind rules |
| `Godot/components/DeviceSlotButton.gd` | optional device count under the title (`show_count`), and `_can_drop_data` / `_drop_data` through `DeviceDropUtil.can_drop_on_container` / `drop_on_container` on the slot chain, then `set_slot_open` |
| `Godot/devices/simple_view/SimpleControlKinds.gd` | `SLOT := "slot"`, footprint `(2, 1)`, `PARAM_COUNT[SLOT] = 0` |
| `Godot/devices/simple_view/SimpleControl.gd` | `_build_inner` creates a `DeviceSlotButton` (count on, bound to `control_data.slot`) for `SLOT`. `refresh` / mod targets skip it |
| `Godot/devices/simple_view/SimpleLayoutGenerator.gd` | `generate` appends the slot group (`id: "slots"`, `title: "Slots"`, `column: true`, items `{kind: "slot", params: [], slot: key}`) after the Main groups in `build_pages`. `VERSION = 15` |
| `Godot/devices/simple_view/GridPacker.gd` | `make_control` copies `slot` |
| `Godot/devices/simple_view/SimpleLayout.gd` | `_page_from_dict` keeps `slot`. `reconcile_slots(keys)`. `param_ids` skips slot controls |
| `Godot/devices/simple_view/SimpleLayoutStore.gd` | `load_or_generate` calls `layout.reconcile_slots` with the device's slot keys after `reconcile` |
| `Godot/dawproject/TransferReport.gd`, `Godot/dawproject/DawProjectExporter.gd` | `DEVICE_SLOTS` kind and its message. The exporter adds an entry per slotted device with non-empty slots, naming the devices |
| `docs/subsystems/osc-protocol.md` | `/builtin/info` slot block, plus a "Device slots" note under the containers section |
| `CONTEXT.md` | **Device slot**, **Slotted device**, **Loop slot** terms |
| `docs/subsystems/engine-architecture.md` | a short "Device slots" section: engine-owned chains and the loop sub-block rule |
| `Engine/src/audio/devices/slots.rs` tests, `polysynth/mod.rs`, `delay.rs`, `reverb.rs` `mod tests` | engine tests in the test plan |
| `Godot/tests/test_device_chain_slots.gd` (new), `Godot/tests/test_simple_layout_generator.gd`, `Godot/tests/test_simple_view_render.gd`, `Godot/tests/test_device_presets.gd`, `Godot/tests/test_dawproject_export.gd` | Godot tests in the test plan |

## Migration and compatibility

- **Projects and presets from before this spec:** a PolySynth, Delay or Reverb with no `children`
  gets its empty slot chains from `ensure_chains` on load. The engine creates its own chains,
  so nothing extra is sent. Output is unchanged (REQ-002, REQ-030).
- **Automation and modulator route paths** into slot devices are new and can't collide with old
  ones, since these devices had no children before.
- **Simple View layouts:** layouts the user never edited (`generated`, version 14) are generated
  again with tiles. Edited layouts keep their controls and get missing tiles appended
  (`reconcile_slots`).
- **Engine/Godot version skew:** an older Godot ignores the trailing `/builtin/info` block and
  never shows slots, while the engine still runs empty chains. A newer Godot with an older engine
  sees no slot block, so `Device.slots` stays empty and the devices behave as before.

## Test plan

Engine (`cargo test <name>`):

- `slots::tests::kind_accepts` (REQ-014–017): Note takes Transpose only. Audio rejects
  PolySynth and Transpose, accepts Delay and a Chain of effects. Loop also rejects a CLAP-variant
  test device.
- `container::tests::insert_into_slot_is_checked` (REQ-017): `insert_device` of a polysynth at
  `{0}/child/1` returns `Err`, and the slot stays empty.
- `polysynth::tests::slots_exist_and_are_fixed` (REQ-001): two children. `insert_child` on the
  device is refused.
- `polysynth::tests::empty_slots_are_sample_identical`, `delay::tests::empty_fb_fx_is_sample_identical`,
  `reverb::tests::empty_slots_are_sample_identical` (REQ-002): compare against a copy with the slots
  path disabled, sample for sample.
- `polysynth::tests::note_fx_transposes_at_frame` (REQ-003): Transpose +12, note at frame 37,
  voice key 72 at frame 37.
- `polysynth::tests::note_fx_release_on_remove` (REQ-004): latched Arpeggiator removed through
  `Channel::release_note_effect_at`, then no voice is held.
- `polysynth::tests::cc_reaches_note_fx` (REQ-005).
- `polysynth::tests::fx_slot_processes_output` (REQ-006).
- `polysynth::tests::sleep_waits_for_fx_tail` (REQ-013).
- `delay::tests::fb_fx_halves_each_later_repeat` (REQ-007).
- `delay::tests::fb_fx_enforces_loop_floor_without_click` (REQ-010).
- `delay::tests::bypassed_delay_skips_fb_fx` (REQ-012).
- `reverb::tests::tank_fx_shortens_tail_per_algorithm`, `reverb::tests::unity_tank_fx_matches_empty` (REQ-008).
- `reverb::tests::wet_fx_never_touches_dry` (REQ-009).
- `modulation::host::tests::route_reaches_slot_device` (REQ-032).
- `osc::encode` test: the `/builtin/info` slot block round-trips.
- REQ-011: code review against ADR-0002. No allocation-counting harness exists, so this is review only.

Godot (`Godot/tests/run_all.sh <word>`):

- `test_device_chain_slots.gd`: REQ-001 (keys and order), REQ-014–016 (drop rules), REQ-018
  (slot chains refuse remove, move and drag), REQ-019–022 (lane slot group, one open, role
  colours, reveal), REQ-023 (`uses_simple_view`), REQ-030 (pre-spec JSON), REQ-033 (automation
  picker lists the slot device), engine sync skips slot chains (OSC capture).
- `test_simple_layout_generator.gd`: REQ-027 (last group on Main, in order, no other page).
- `test_simple_view_render.gd`: REQ-024–026 (tiles, count, click toggles, drop on tile), REQ-028
  (edited layout gets appended tiles).
- `test_device_presets.gd`: REQ-029 and REQ-031 (round-trip, pre-spec preset empties slots,
  one undo).
- `test_dawproject_export.gd`: REQ-034.

Live (engine and Godot running):

- Add a PolySynth, open Note FX and drop an Arpeggiator, open FX and drop a Delay. Hold a chord:
  arpeggiated notes go through the delay. Release: the tail rings out, then the device sleeps.
- Delay with Saturator in FB FX at 95 % feedback: each repeat gets dirtier. Set Time to 1 ms: no
  click.
- Reverb Plate with a Filter in Tank FX: the tail darkens over time. Put a CLAP effect in Wet FX:
  it works, and a CLAP dropped on Tank FX is refused.
- Save, reload the project, and save/load a PolySynth preset: the slots come back.

## Risks

| Risk | Mitigation |
|---|---|
| The loop sub-block path changes the sound slightly versus today (ordering, floor) | The path is used only while the slot is live. `unity_tank_fx_matches_empty` and the Delay identity test bound the difference |
| Tank FX gain above 1 (Saturator makeup, Utility gain) blows the tank up | The existing `soft_clip` on every push still bounds the loop, as it does for Freeze |
| A plugin in FX or Wet FX makes the wrapper's mono modulation of the host block rate | Only while such a plugin is present. Per-voice modulation is unaffected. Documented in the design and the osc-protocol note |
| The `loop_floor` jump clicks when the first device lands in a loop slot | The floor is a `SmoothedParam`. The Delay additionally uses its tap crossfade or glide. Covered by `fb_fx_enforces_loop_floor_without_click` |
| `is_container` slotted devices hit code that assumes a user container | The Godot change list names every `is_container` call site outside tests (Device, DeviceInstance, DeviceDropUtil, DeviceDropTarget via `can_drop_on_container`, DeviceLaneItem, DevicePanel, AI tools), and `test_device_chain_slots.gd` covers drop-on-panel |
| CPU: two extra chain calls per PolySynth block | An empty slot costs one `is_live` check per block: a scan of the slot chain's direct children for `is_enabled()`, a handful of virtual calls. It isn't cached, because a child's bypass toggles without its parent being told |

## Open questions

None.
