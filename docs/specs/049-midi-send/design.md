# MIDI Send — Design

Implements [requirements.md](./requirements.md).

## Context

- `Engine/src/audio/processing/clip_midi.rs`: `dispatch_clip_midi` sends each track's clip notes to
  its channel (`Channel::send_clip_note`) before any chain renders. `create_track` in
  `audio/commands/track.rs` accepts any channel id, bus channels included.
- `Engine/src/audio/channel/chain.rs`: `Channel::dispatch_notes` turns scheduled live MIDI into
  notes and runs the note phase. `begin_device_chain` (at `start == 0`) and
  `process_aux_source_untimed` call it during the render, which is where the pool runs.
- `Engine/src/audio/devices/note_fx/routing.rs`: `route_note` delivers a note in chain order and
  stops at the first note effect; `run_note_phase` runs each note effect's `process_notes` and
  routes its output downstream. `route_cc` sends CC to every device and isn't stopped by note
  effects.
- `Engine/src/audio/devices/note_fx/ids.rs`: `next_generated_id(clip_origin)`.
  `midi_types.rs`: `SoundingNoteId`, `is_clip_note`. Live and clip ids are issued per channel by
  `ActiveNotes`, so two channels can use the same id.
- `Engine/src/audio/mixing/mod.rs`: `mix_and_output` runs the aux-source pass, `device_prepass`
  and `route_in_dependency_order`; the last two use the `ChannelPool` (ADR 0020). The live stream
  (`stream.rs`) and offline render (`render/worker.rs`) both call `process_audio` and then
  `mix_and_output`.
- `Engine/src/audio/mixing/sidechain.rs`: `rebuild_taps(state)` is the precedent for
  cross-channel state. The command thread rebuilds it under the lock on every chain or channel
  change and drops the old one after unlocking. Call sites: `commands/mod.rs` (`InitProject`,
  `CreateChannel`, device move), `command_worker/devices.rs` (add, remove, clear),
  `command_worker/project.rs` (`remove_channel`, project load).
- `Engine/src/audio/devices/factory.rs`: `NOTE_EFFECT_IDS` and `create_note_effect`;
  `note_fx/conformance.rs` runs over that list, wrapped and unwrapped in `ModulatedDevice`
  (`modulation/host.rs`), which forwards the note methods of `AudioDevice`.
- `Engine/src/osc/routes/device_slots.rs`: `slot/{n}/choke_targets` →
  `AudioCommand::SetDrumSlotChokeTargets` is the precedent for device state that isn't a
  parameter. `osc/encode.rs` builds device status addresses with `DevicePath::to_osc_addr`.
- `Godot/data/Track.gd`: `has_clips()` is false for `FOLDER` and `GROUP`; `connect_to_engine()`
  skips both. `pair_mixer_channel` sets a group's `default_channel_id` to its bus channel.
- `Godot/data/Channel.gd`: `child_channel_ids`, `hierarchy_changed` (`notify_hierarchy_changed`);
  `Project.nest_channel` / `unnest_channel` change the nesting.
- `Godot/data/DeviceInstance.gd`: `choke_targets` with `set_choke_targets`, `_send_choke_targets`,
  `to_json`, `sync_to_engine`, and status listeners registered in `connect_to_engine()` through
  `AudioEngineOSC.listen(osc_addr(...))`. `Godot/data/DevicePreset.gd:88` lists the instance keys a
  preset leaves out.
- `Godot/editor/RecordArmPolicy.gd` and the two `arranger/group_arm_*` settings in
  `Godot/settings/Settings.gd`.
- **No MIDI recording exists.** Record arm routes live MIDI to the armed channel, and no code turns
  played notes into a clip. See the divergences below.

## Approach

**A MIDI pre-pass in front of the mixer.** At the top of `mix_and_output`, before the aux-source
pass, a new `midi_send::forward` walks the *sender order*: the channels holding a MIDI Send, sorted
so that every sender comes after anything that sends to it. For each sender it calls
`dispatch_notes` (live MIDI plus note phase) early, on the callback thread, and marks the channel
`notes_dispatched` so the render doesn't run it again. It then copies each MIDI Send's outbox into
scratch and delivers every event to each effective target with `send_note_event_to_devices` at the
same frame. Targets receive the events before their own note phase, which still runs in the render
as now. This gives same-block, same-frame delivery (REQ-005, REQ-013) and leaves the pool
untouched: the pre-pass is serial, cheap note-only work, so output is sample-identical at any
thread count. A project without a MIDI Send has an empty sender order, and the pre-pass is a
no-op.

**Rejected: forwarding during the render.** A send that emits while its channel renders on a pool
worker would reach a target that is already rendering or done. That adds a block of latency and
makes output depend on scheduling, which ADR 0020 forbids. **Also rejected: resolving the sender
graph per block on the callback.** The graph changes only with commands, so the command thread
builds it, as `rebuild_taps` does.

**The device.** `MidiSend` (`note_fx/midi_send.rs`) implements `AudioDevice` directly rather than
through `NoteFxHost`. It needs two outputs (downstream and the outbox) and its own id mapping,
which `NoteFxHost` doesn't model. It queues input like other note effects. In `process_notes` it
gives each forwarded note-on a new `next_generated_id(is_clip_note(input_id))`, stores
(input id, output id, key) in a fixed sounding table, and maps note-offs and expressions through
that table. That keeps sources independent on the target (REQ-012) and preserves clip origin for
stop handling (REQ-011). The outbox gets the remapped events. Downstream gets the *original* events
when the `Thru` parameter is on, and nothing when it's off (REQ-009). CC isn't stopped by note
effects (`route_cc` reaches every device), so `MidiSend::send_cc` pushes CC into the outbox too, as
a `TimedCc` (REQ-006). Pitch bend has no engine event today and arrives with whatever path adds it.
Bypassed, the send passes input downstream unchanged, and on the next note phase it emits note-offs
for its sounding table into the outbox. `note_discontinuity` does the same for clip-origin entries
(REQ-010, REQ-011).

**Targets are resolved in Godot; loops are refused in the engine.** The engine has no mixer
nesting (no `parent_channel_id` exists in `Engine/src`), so `DeviceInstance` resolves children mode
from `Channel.child_channel_ids`. It re-sends the concrete list whenever the sender's
`hierarchy_changed` fires or a channel is removed (REQ-007). The engine only ever sees "this send
targets channels [a, b, c]". `rebuild_midi_sends` drops ids that are invalid (the sender itself,
master `1`, ids ≥ 1000, ids not in `state.channels`). It then adds edges in a fixed order (sender id,
device index, target id), skips any edge whose target can already reach the sender (it would close
a loop, REQ-014), and writes the accepted list into each device as its *effective* targets. The
skipped ones go back to Godot as `blocked`.

**MIDI Send lives only in a channel's top-level chain.** Containers and slots run their note phases
inside their own `process_block`, during the render, so a nested MIDI Send would emit too late.
Adding one at a nested path is refused.

### Divergences from requirements.md (need approval)

1. **REQ-004 narrowed:** MIDI Send can be inserted only in a channel's top-level chain, not inside
   Chain, Layer, Drum Machine or slot chains. The browser and drag-drop refuse nested drops, and the
   engine refuses and logs a nested `add_device`.
2. **REQ-019 deferred:** Sonara has no MIDI recording yet, so "recording onto a group" can't be
   built here. Arming a group routes live input through its MIDI Send (REQ-015), and REQ-018 still
   decides which track arm lands on. REQ-019 moves to whichever spec adds MIDI recording, with a
   note that groups qualify.
3. **REQ-007 acceptance** becomes a Godot test, since children mode is resolved there.
4. **REQ-006 pitch bend:** forwarded once a pitch-bend event exists; nothing in the engine carries
   one today.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `MidiSend` requested targets, effective targets (fixed capacity `MAX_TARGETS = 64`) | command thread writes under the lock (`SetMidiSendTargets`, `rebuild_midi_sends`) | audio callback reads in the pre-pass | yes: fixed arrays, never grown on the callback |
| `MidiSend` input queue, sounding table, outbox (`NoteBuffer`, fixed capacities like `note_fx/host.rs`) | audio callback | command thread under the lock, to release notes before removal or retargeting | yes |
| `EngineState::midi_sends: MidiSendOrder` (sender channel ids in topological order) | command thread builds it under the lock; the old one goes to `CommandEffects::discard` or is dropped after unlock | audio callback iterates it read-only | yes |
| `Channel::notes_dispatched: bool` | audio callback | set and cleared within one `mix_and_output` | yes |
| `RenderScratch::midi_forward: NoteBuffer` (+ a CC list) | audio callback | preallocated in `render_scratch.rs` | yes |

Note-offs the command thread sends (target removed from a send, send removed, sender channel
removed) go straight to the target channel's `send_note_event_to_devices` under the lock: at most
one off per sounding entry per removed target, which is fast.

## Data and protocol changes

**OSC (Godot → Rust)**

| Address | Args | Meaning |
|---|---|---|
| `/channel/{id}/device/{path}/midi_send/targets` | `i...` (zero or more channel ids) | Replace the send's target list. Zero args means none. Routed in `osc/routes/device.rs` as `["midi_send", "targets"]` → `AudioCommand::SetMidiSendTargets { channel_id, device_path, targets: Vec<ChannelId> }` |

**OSC (Rust → Godot)**

| Address | Args | Meaning |
|---|---|---|
| `/channel/{id}/device/{path}/midi_send/blocked` | `i...` | Requested targets not used because they would close a loop. Sent after every rebuild that changes the set. `EngineStatus::MidiSendBlocked`, encoded in `osc/encode.rs` |

Thru is parameter 0 (`bool`, default on) of the device's `ParamTable`, so it uses the existing
`/param/{id}` path, automation and the simple view.

**Godot model** (`DeviceInstance.gd`, only for `device_id == "sonara.builtin.midi_send"`)

- `midi_send_mode: String` (`"children"` | `"list"`, default `"children"`),
  `midi_send_targets: PackedInt32Array` (list mode), `midi_send_blocked: PackedInt32Array`
  (runtime only).
- Signals `midi_send_changed()` and `midi_send_blocked_changed()`.
- Setters `set_midi_send_mode`, `set_midi_send_targets` and `toggle_midi_send_target`, with history
  through `HistoryUtil.execute_property`, like `set_choke_targets`.
- `resolved_midi_send_targets()` returns the direct `child_channel_ids` in children mode, or the
  list filtered to existing user channels. `_send_midi_send_targets()` sends it and is called from
  `sync_to_engine()`, from the setters, from the sender channel's `hierarchy_changed`, and from
  `Project.channel_removed` (which also drops the id from the list).
- `to_json` / `from_json` gain `midi_send_mode` and `midi_send_targets`. `DevicePreset.gd` leaves
  out `midi_send_targets` (channel ids belong to the project) and keeps the mode.

**Settings:** both `arranger/group_arm_*` choice lists gain
`RecordArmPolicy.ARM_GROUP_IF_NOTES = "Record arm the group if it has a note device"`. `resolve()`
returns the group when its channel chain has a top-level device whose `Device.category` is
`Instrument` or `NoteEffect`, otherwise the last armed valid child (falling back to the group when
there is none, as today).

**Project file:** group tracks write `clip_instances` like other tracks, and the MIDI Send keys
above. Both are additive.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/devices/note_fx/midi_send.rs` (new) | `MidiSend`: param table (Thru), input queue, sounding table, outbox (notes and CC), requested and effective targets, release on bypass, discontinuity and command; `mod tests` |
| `Engine/src/audio/devices/note_fx/mod.rs` | `pub mod midi_send;` |
| `Engine/src/audio/devices/device.rs` | `AudioDevice::as_midi_send_mut(&mut self) -> Option<&mut MidiSend>`, default `None` |
| `Engine/src/audio/modulation/host.rs` | `ModulatedDevice` forwards `as_midi_send_mut` |
| `Engine/src/audio/devices/factory.rs` | add `"sonara.builtin.midi_send"` to `NOTE_EFFECT_IDS` and `create_note_effect` |
| `Engine/src/audio/mixing/midi_send.rs` (new) | `MidiSendOrder`; `rebuild_midi_sends(state) -> MidiSendOrder` (validation, loop refusal, effective targets, blocked statuses); `forward(channels, order, scratch, frames)` (the pre-pass); `release_send_targets(state, channel_id, index, which)` for the command thread; `mod tests` |
| `Engine/src/audio/mixing/mod.rs` | `mod midi_send;`; call `midi_send::forward` first in `mix_and_output`; clear `notes_dispatched` at the end |
| `Engine/src/audio/channel/mod.rs` | `notes_dispatched: bool` on `Channel` |
| `Engine/src/audio/channel/chain.rs` | `begin_device_chain` and `process_aux_source_untimed` skip `dispatch_notes` when `notes_dispatched` |
| `Engine/src/audio/state.rs` | `midi_sends: MidiSendOrder` on `EngineState` |
| `Engine/src/audio/render_scratch.rs` | `midi_forward` note and CC buffers |
| `Engine/src/audio/commands/mod.rs` | `AudioCommand::SetMidiSendTargets`; call `rebuild_midi_sends` next to each `rebuild_taps` (`InitProject`, `CreateChannel`, device move) |
| `Engine/src/audio/commands/device.rs` | `set_midi_send_targets`: release notes on removed targets, store the list, rebuild |
| `Engine/src/audio/command_worker/devices.rs` | add: refuse a MIDI Send at a nested path; add, remove and clear: release the send's targets before removal, rebuild next to `rebuild_taps` |
| `Engine/src/audio/command_worker/project.rs` | `remove_channel`: release the removed sender's targets, then rebuild; project load: rebuild |
| `Engine/src/audio/commands/status.rs` | `EngineStatus::MidiSendBlocked { channel_id, device_path, ids }` |
| `Engine/src/osc/routes/device.rs` | `["midi_send", "targets"]` route |
| `Engine/src/osc/encode.rs` | encode `MidiSendBlocked` |
| `docs/subsystems/osc-protocol.md` | both addresses, plus a MIDI Send entry under Built-In Devices |
| `docs/subsystems/engine-architecture.md` | the MIDI pre-pass in the callback-and-mixing description |
| `docs/adr/0023-midi-pre-pass.md` (new) | decision: cross-channel MIDI is delivered in a serial pre-pass before the pooled render; extends ADR 0020 |
| `AGENTS.md` | add MIDI Send to the built-in device list and step 5 (pre-pass) |
| `Godot/data/Track.gd` | `has_clips()` true for `GROUP`; new `accepts_audio_clips()` (false for groups); `connect_to_engine()` connects groups (not folders); `_remember_as_last_armed` keeps excluding groups |
| `Godot/arranger/timeline/Timeline.gd`, `TimelineTrack.gd` | drop, paste and move into a group check `accepts_audio_clips()` for audio clips |
| `Godot/editor/Editor.gd`, `Godot/editor/RecordArmPolicy.gd`, `Godot/history/commands/TrackDuplicateCommand.gd`, `Godot/ai/tools/AiTool.gd` | review each `has_clips()` call: arm-target and child lookups keep groups out (`has_clips() and not is_group()`); duplicate copies group clips |
| `Godot/editor/RecordArmPolicy.gd` | `ARM_GROUP_IF_NOTES` and the "group has a note device" check |
| `Godot/settings/Settings.gd` | the new choice on both group-arm settings, plus description text |
| `Godot/data/DeviceInstance.gd` | MIDI Send fields, signals, setters, resolution, sync, JSON, `blocked` listener |
| `Godot/data/DevicePreset.gd` | leave out `midi_send_targets` |
| `Godot/devices/builtin/midi_send/MidiSendDefaultView.{gd,tscn}` (new) | mode switch, Thru toggle, target list (names follow `Channel.name_changed`; blocked rows marked), add-target picker of valid channels |
| `Godot/devices/DeviceViewFactory.gd` | register the panel scene |
| `Godot/devices/DeviceDropUtil.gd` | `device_fits_host`, `can_drop_instance_on_host` and `copy_fits_host` refuse MIDI Send into a container or slot (`host_parent != null`) |
| `Godot/dawproject/DawProjectExporter.gd` | export group clips on the group track's lane; add a `TransferReport` entry for each MIDI Send |
| `CHANGELOG.md` | Unreleased: MIDI clips on group tracks, MIDI Send device, the new group-arm option |

## Migration and compatibility

Older projects have no group clips and no MIDI Send, so they load unchanged, and an empty sender
order makes the pre-pass a no-op. A missing `midi_send_mode` reads as `"children"`. A project with
group clips opened in an older build drops them (accepted in requirements.md). The new group-arm
choice is additive; old values keep their meaning.

## Test plan

- **Unit (`note_fx/midi_send.rs`):** `forwards_with_new_ids_and_paired_offs`,
  `thru_passes_original_downstream`, `consume_passes_nothing_downstream`,
  `bypass_releases_sounding_into_outbox`, `discontinuity_releases_clip_origin_only`,
  `cc_goes_to_outbox`, `full_tables_drop_ons_never_offs`.
- **Unit (`mixing/midi_send.rs`):** `forwarded_clip_matches_direct_clip` (REQ-005, sample compare
  with a PolySynth target), `chain_of_sends_same_block` (REQ-013), `loop_edge_is_blocked` (REQ-014),
  `invalid_targets_dropped` (REQ-008), `same_key_from_two_sources_is_independent` (REQ-012),
  `retarget_releases_removed_targets`, `removing_send_or_sender_releases_targets` (REQ-010),
  `loop_wrap_releases_on_target` (REQ-011), `bus_without_note_device_is_silent` (REQ-003),
  `pool_output_matches_single_thread_with_sends` (ADR 0020).
- **Conformance:** `note_fx/conformance.rs` picks MIDI Send up from `NOTE_EFFECT_IDS` (REQ-004).
- **Unit (`processing/clip_midi.rs`):** `clip_on_bus_channel_reaches_its_chain` (REQ-002).
- **Godot (`Godot/tests/test_group_midi_clips.gd`, new):** clips on a group (create, move, paste),
  audio drop refused, save/load round-trip (REQ-001, REQ-016).
- **Godot (`Godot/tests/test_midi_send_targets.gd`, new):** children mode re-resolves on
  nest/unnest and channel removal (REQ-007), list mode filtering, JSON round-trip, preset leaves out
  the targets.
- **Godot (`Godot/tests/test_group_record_arm.gd`):** the new option (REQ-018).
- **Godot (the existing DAWproject export test):** a report entry per MIDI Send (REQ-020).
- **Live:** a Choir group with 4 sfizz children, a clip on the group, and a MIDI Send in children
  mode. Play, loop, stop, bypass mid-note, and retarget mid-note; no hanging notes. Arm the group
  and play the virtual keyboard (REQ-015). Check the view updates on rename and delete (REQ-017).

## Risks

| Risk | Mitigation |
|---|---|
| Instruments that pair notes by key (sfizz, some plugins) can't keep two same-key notes apart, so REQ-012 can't hold for them | REQ-012 holds for id-paired instruments. For key-paired ones it behaves like two overlapping same-key clip notes today. State this in the device docs; the test uses PolySynth |
| A missed `notes_dispatched` path runs the note phase twice and doubles notes | Both call sites are guarded; the flag is cleared once at the end of `mix_and_output`; `forwarded_clip_matches_direct_clip` catches doubling |
| A missed rebuild call site leaves stale effective targets after a chain or channel change | Rebuild next to every existing `rebuild_taps` call, plus `SetMidiSendTargets`; the tests cover add, remove, move and channel removal |
| Pre-pass cost on large projects | Serial note-only work over the senders only; empty for projects without sends; check with `/engine/perf/subscribe` live |

## Open questions

- [x] Approve the four divergences above (REQ-004 top-level only, REQ-019 deferred, REQ-007 test in
  Godot, REQ-006 pitch bend when it exists).
