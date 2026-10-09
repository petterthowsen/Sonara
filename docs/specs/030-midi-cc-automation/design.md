# MIDI CC automation — Design

Implements [requirements.md](./requirements.md).

## Context

Engine:

- `Engine/src/audio/automation.rs` — `AutomationTarget` (`parse` / `Display`), `AutomationLane`
  (`last_applied`, `captured_base`), `apply_automation`, `apply_lane_value`, `release_lane`,
  `release_track_lane`, `APPLY_EPSILON`. Runs once per buffer from `audio/processing/mod.rs`
  (line 41), before the channels render.
- `Engine/src/audio/channel/chain.rs` — `Channel::dispatch_scheduled_midi` turns the channel's
  scheduled live events into note events and **drops every other message type** (`_ => continue`);
  `dispatch_notes`; `send_note_event_to_devices`.
- `Engine/src/audio/processing/live_midi.rs` — `schedule_live_midi_events` stamps each queued
  `MidiEvent` with a frame offset. A live CC arrives as `MidiMessageType::ControlChange` with
  `note` = controller and `velocity` = value (`osc/routes/channel.rs`, `midi_cc`).
- `Engine/src/audio/devices/device.rs` — `AudioDevice` has `send_note_event`, `set_parameter_at`,
  `get_parameter`, `accepts_note_input`, `mark_activity`, but no controller entry point.
- `Engine/src/audio/devices/note_fx/routing.rs` — `route_note`, the shared chain walk that
  `containers/chain.rs` and `containers/layer.rs` use through their `send_note_event`.
- `Engine/src/audio/devices/instruments/sfizz_device.rs` — `queued_midi`, `process_block`
  (renders in segments between queued events), `cc_values`, `send_normalized_cc`. Its
  `set_parameter` takes a blocking `cc_values.lock()` and calls `info!`, and today the automation
  pass calls it on the audio thread.
- `Engine/src/audio/ipc/protocol.rs` — `BlockEvent` and the `EVENT_*` kinds (1–5);
  `audio/devices/clap_host/subprocess_adapter/mod.rs` `send_note_event` fills `input_events`;
  `plugin_host/audio_thread.rs` turns events into `OwnedEvent`s for CLAP and drops unknown kinds
  (`_ => {}`); `plugin_host/vst3/processor.rs` `translate_events` counts them in
  `Dropped.unsupported`.
- `Engine/src/osc/routes/track.rs` — `/track/{id}/automation/create` parses the target through
  `AutomationTarget::parse` and ignores an unparseable one with a warning.

Godot:

- `Godot/data/AutomationTarget.gd` — `Kind`, `parse`, `_to_string`, `resolve`, `is_resolvable`,
  `display_name`, `param_label`. Mirrors the engine spelling byte for byte.
- `Godot/arranger/tracklist/AutomationParameterPicker.gd` — `_rebuild`, `_add_device`,
  `_add_param_group` (the `"cc"` group is added here), `_has_lane`.
- `Godot/data/AutomationLane.gd` — `to_json` / `from_json` persist `str(target)`.
- `Godot/data/Project.gd` — `_migrate_slot_automation(project)` after load (line 1913) is the
  existing precedent for rewriting saved lane paths.
- `Godot/data/DeviceInstance.gd` — `get_parameters_in_group`, `has_cc_parameters`, `device_id`.
- `Godot/core/Midi.gd` — `cc_name`, `cc_display_name(cc, device_supplied)`.
- `Godot/dawproject/DawProjectExporter.gd` (`_resolve_lane_target`, `_write_points`) and
  `DawProjectImporter.gd` (`_import_points`, which currently reports every `expression` target as
  dropped).

Facts that shape the design:

- Only the SFZ sampler uses the `"cc"` parameter group, and every SFZ parameter id *is* a
  controller number. So "a controller parameter" can be decided from the device id.
- The Godot picker is the only place a device-parameter lane is created.
- The Godot CC knobs keep working as they do now (`DeviceInstance.set_parameter` →
  `device.set_parameter`). They are the *base* value a released lane restores.

## Approach

A new lane target, `channel/cc/{n}` (`AutomationTarget::MidiCc { cc }`), names a controller on
the track's linked channel, not on one device. As with every lane, the lane itself belongs to the
track, and `apply_automation` routes it to the track's channel; a track with no linked channel
drives nothing. Each buffer, `apply_lane_value` quantizes the lane value to 14 bits
(`round(v × 16383)`), skips it when the quantized value is unchanged, and otherwise sends it down
the channel's device chain through a new `AudioDevice::send_cc(cc, value14, frame_offset)`
(default no-op), walked by a new `route_cc` that sits beside `route_note`. Live CC takes the same
route: `dispatch_scheduled_midi` stops dropping `ControlChange`, converts the 7-bit value to
14 bits and calls the same function, unless a lane currently owns that controller (a 128-bit
`cc_lane_mask` on the channel, set by `apply_lane_value`, cleared by `release_lane`).

Devices decide what 14 bits mean. The SFZ sampler converts back to a normalized float and sends
`sfizz_send_hdcc`, so it keeps all 14 bits. A CLAP plugin gets a new `EVENT_MIDI_CC` block event,
and `plugin_host` turns it into a CLAP MIDI event `B0 cc msb` with `msb = value14 >> 7` (7-bit
only, as decided). VST3 hosts no MIDI event, so for now the plugin host counts it as unsupported
(see Open questions). Everything else ignores it.

Release (REQ-006) uses a new `AudioDevice::cc_value(cc) -> Option<u16>`. The first time a lane
drives a controller, `captured_base` takes the first `cc_value` any device in the chain reports
(the SFZ sampler answers from its knob values); release sends that value back, or nothing when
there was none.

On the Godot side `AutomationTarget` gains `Kind.MIDI_CC` (appended, so existing integer kinds keep
their values) and the picker gets a top-level `MIDI CC` entry. Saved lanes aimed at an SFZ
parameter are rewritten to CC lanes at load, like `_migrate_slot_automation` rewrites slot paths.
DAWproject maps a CC lane to a `channelController` target.

**Rejected alternative:** keep CC lanes as device parameters and just widen the SFZ parameter list
to all 128 CCs. That fixes the SFZ case only. CLAP and VST3 plugins have no per-CC parameter, a
CC would stay tied to one device's chain position (moving the device would break the lane), and
live and lane CC would keep two separate paths.

**Rejected alternative:** deliver lane CCs through `set_parameter_at(cc, …)` on whichever device
has a matching id. Parameter id 1 on a PolySynth is not CC1; the SFZ sampler's `set_parameter` also
blocks on a mutex on the audio thread. A dedicated entry point avoids both.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `AutomationTarget::MidiCc`, lane data | command thread (lane edits, under the state lock) | audio callback, under its `try_lock` of the state | yes — as every other lane |
| `AutomationLane.last_applied`, `captured_base` for a CC lane | audio callback | command thread only in `release_track_lane` (bypass/delete), under the state lock | yes |
| `Channel.cc_lane_mask: u128` | audio callback (`apply_lane_value`, `release_lane`) | `dispatch_scheduled_midi` (audio callback); `release_lane` from the command thread under the state lock | yes — plain integer, no lock beyond the state lock |
| SFZ `queued_midi` entries for CCs (preallocated `Vec`) | audio callback (`process_block`) | `send_cc` from the audio callback, or from the command thread inside `release_lane` under the state lock | yes — capacity reserved at construction; a full queue drops the event (counted), never grows |
| SFZ `cc_values` (knob values) | command thread (`set_parameter`) | `cc_value` on the audio callback through `try_lock` | yes — a busy lock returns `None`, so that lane has no base to restore |
| CLAP `input_events` | audio callback | `send_cc` pushes a `BlockEvent` like a note; the ring is bounded by `MAX_BLOCK_EVENTS` (drops are counted in `stats.event_drops`) | yes |

`route_cc` allocates nothing and takes no lock. `apply_lane_value` for a CC lane never calls
`set_parameter`, so the SFZ sampler's blocking `cc_values.lock()` leaves the audio thread for
CC lanes.

## Data and protocol changes

**Target spelling** (engine `Display` / `parse`, Godot `_to_string` / `parse`): `channel/cc/{n}`,
`n` in 0..=119. 120–127 and non-integers fail to parse (REQ-002). No new OSC address:
`/track/{id}/automation/create` carries the new string, and an old engine ignores it with its
existing warning. Document it in `docs/subsystems/osc-protocol.md`, in the `target` list under the
automation table (around line 140).

**14-bit helpers** (`audio/midi_types.rs`): `CC_MAX = 16383`, `cc14_from_unit(f32) -> u16`,
`cc14_to_unit(u16) -> f32`, `cc14_from_cc7(u8) -> u16` (`round(v × 16383 / 127)`, so 127 → 16383),
`cc14_msb(u16) -> u8` (`value >> 7`, so 8192 → 64).

**Device API** (`audio/devices/device.rs`):

```rust
fn send_cc(&mut self, _cc: u8, _value14: u16, _frame_offset: usize) {}
fn cc_value(&self, _cc: u8) -> Option<u16> { None }
```

**IPC** (`audio/ipc/protocol.rs`): `EVENT_MIDI_CC = 6`; `BlockEvent::cc(sample_offset, cc,
value14)` with `note = cc`, `id = value14 as u32`, `value = cc14_to_unit(value14)`. This is an
added event kind inside the existing `repr(C)` struct, so the layout and `MAX_BLOCK_EVENTS` are
unchanged; `plugin_host` ignores kinds it doesn't know, so a mismatched pair degrades to no CC.
Document in `docs/subsystems/engine-plugin-architecture.md`.

**Godot persisted format**: lanes keep `"target": "<string>"` in the `.sonara` file; only the
new spelling is added. Load-time migration (below).

**Settings**: none.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/midi_types.rs` | 14-bit helpers; tests for them |
| `Engine/src/audio/devices/device.rs` | `send_cc`, `cc_value` on `AudioDevice` (defaults above) |
| `Engine/src/audio/devices/note_fx/routing.rs` | `route_cc(devices, cc, value14, frame_offset)`: every device in order, `mark_activity` on those that `accepts_note_input`, not stopped by note effects |
| `Engine/src/audio/devices/containers/chain.rs`, `layer.rs` | forward `send_cc` to children / slots (`drum_machine.rs` keeps the default: pads are drums) |
| `Engine/src/audio/channel/mod.rs` | `cc_lane_mask: u128` field, initialised to 0 |
| `Engine/src/audio/channel/chain.rs` | `send_cc_to_devices`; `dispatch_scheduled_midi` handles `ControlChange` (mask check, 7→14 bit, `route_cc`) |
| `Engine/src/audio/automation.rs` | `AutomationTarget::MidiCc { cc }` with `parse` (0–119) and `Display`; `apply_lane_value` and `release_lane` arms; the 14-bit dedup; base capture/restore |
| `Engine/src/audio/devices/instruments/sfizz_device.rs` | `send_cc` (queued, applied at its offset in `process_block` with `sfizz_send_hdcc`), `cc_value` (`try_lock`); `queued_midi` becomes a small `Copy` enum of note and CC entries, and the existing `sfizz_release_reaches_binding` test follows |
| `Engine/src/audio/ipc/protocol.rs` | `EVENT_MIDI_CC`, `BlockEvent::cc` |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs` | `send_cc` pushes `BlockEvent::cc` (drops counted like notes) |
| `Engine/src/plugin_host/audio_thread.rs` | `OwnedEvent::Midi` built from `EVENT_MIDI_CC` as CLAP MIDI event `B0 cc msb` |
| `Engine/src/plugin_host/vst3/processor.rs` | `EVENT_MIDI_CC` explicitly counted in `Dropped.unsupported` (documented v1 limitation) |
| `Godot/data/AutomationTarget.gd` | `Kind.MIDI_CC` (value 5), `midi_cc(cc)`, spelling/parse (0–119), `is_resolvable` true, `display_name` and `cc_label(channel, cc)` |
| `Godot/data/DeviceInstance.gd` | `is_controller_parameter(param)`: `group == "cc"` or the device is the SFZ sampler (`sonara.builtin.sfizz`) |
| `Godot/arranger/tracklist/AutomationParameterPicker.gd` | `MIDI CC` submenu (instrument-labelled first, then CC0–CC119 by `Midi.cc_display_name`, searchable, omitting CCs with a lane); `_add_param_group` skips controller parameters; remove the `"cc"` group call |
| `Godot/data/Project.gd` | `_migrate_cc_automation(project)` after `_migrate_slot_automation`: rewrite `device/…/param/N` lanes on an SFZ sampler to `channel/cc/N`; drop a would-be duplicate with a `push_warning` |
| `Godot/dawproject/DawProjectExporter.gd` | `_resolve_lane_target` kind 5 → `{kind: "cc"}`; `_write_points` writes `Target expression="channelController" channel="0" controller="N"` with identity map |
| `Godot/dawproject/DawProjectImporter.gd` | `_import_points`: `expression="channelController"` becomes a `channel/cc/N` lane; other expressions are still reported |
| `docs/subsystems/osc-protocol.md`, `engine-plugin-architecture.md`, `engine-sfz-sampler.md`, `dawproject.md` | the target spelling, the IPC event, the SFZ `send_cc` path, the CC mapping |
| `docs/specs/003-automation/requirements.md` | one-line note under REQ-015 and REQ-017 pointing here (amended, not rewritten) |

## Migration and compatibility

- **Saved lanes** on an SFZ sampler's parameter (`device/…/param/N`, any depth) load as
  `channel/cc/N`. Values are equivalent: the SFZ parameter was already the normalized CC.
  A lane inside a Layer container now drives the whole channel chain instead of that slot's
  sampler; the migration logs this once. A second lane for the same controller on one track is
  dropped with a warning (REQ-011).
- **Newer project in an older build:** `channel/cc/N` is unparseable there, so the lane is kept
  but unresolved (003 REQ-024) and the engine logs and ignores the create.
- **Engine↔plugin_host skew:** an old `plugin_host` ignores `EVENT_MIDI_CC`; the pair is always
  built together (`run_release.sh`).
- Nothing in `config.json` or `assets.json` changes.

## Test plan

- **Unit (`cargo test`):**
  - `midi_types.rs` `mod tests`: `cc14_*` helpers (0.5 → 8192, 127 → 16383, 8192 → msb 64).
  - `automation.rs` `mod tests`: `automation_target_roundtrip` extended with `channel/cc/74`
    (and failing 120, `channel/cc/x`); new `automation_cc_lane_delivers_value14`,
    `automation_cc_lane_dedups_at_14_bits`, `automation_cc_lane_applies_while_stopped`,
    `automation_cc_lane_restores_known_base_on_bypass`, `automation_cc_lane_without_base_sends_nothing`,
    `automation_cc_lane_ignored_by_device_without_cc`.
  - `channel/chain.rs` `mod tests`: `live_cc_reaches_device_with_frame_offset`,
    `live_cc_is_suppressed_while_a_lane_owns_the_controller`.
  - `sfizz_device.rs` `mod tests`: `sfizz_cc_reaches_synth_at_full_resolution`,
    `sfizz_cc_value_reports_knob_value`; the updated queued-events test.
  - `subprocess_adapter/mod.rs` `mod tests`: `cc_reaches_the_host_with_its_sample_offset`, next to
    the existing `midi_and_automation_reach_the_host_with_their_sample_offsets`.
  - `plugin_host/audio_thread.rs` / `vst3/processor.rs` `mod tests`: the CLAP event bytes
    (`B0 cc msb`), and the VST3 event counted as unsupported.
- **Godot (`Godot/tests/run_all.sh`):** extend `test_automation_model.gd` (spelling, parse,
  120–127 refused, labels, one lane per controller); extend `test_automation_lane_menu.gd`
  (picker: REQ-001, 002, 008, 009); new `test_cc_automation_migration.gd` (REQ-007);
  extend `test_dawproject_roundtrip.gd` with a CC1 lane (REQ-016); `test_automation_history.gd`
  covers undo (REQ-015).
- **Live (needs sound and the VPO libraries):** play a VPO patch, add a CC1 lane, check the
  dynamics follow it, bypass and delete it and check the knob value returns; move a keyboard
  mod wheel and check the patch responds, then add a lane and check the wheel is ignored; open
  an older project with a CC73 lane and check it becomes `CC73 Attack`.

## Risks

| Risk | Mitigation |
|---|---|
| The SFZ queue fills during a very dense CC lane | A lane sends only on 14-bit change, at most once per buffer; capacity 256; drops are counted and warned once |
| `cc_value` loses the `try_lock` race, so a release restores nothing | Rare (the knob lock is held for microseconds); the requirement already allows "nothing is sent" |
| Migration moves a Layer slot's lane to the whole chain | Logged; rare (Layer plus per-slot SFZ plus automation) |
| DAWproject attribute names (`channelController`, `channel`, `controller`) differ from other hosts | Verify against the DAWproject schema when writing the exporter task; round-trip test covers our side |
| A flat 7-bit plugin sees 128 steps on a slow ramp | Accepted by the user; the SFZ sampler (the VPO case) gets full resolution |

## Open questions

None. Resolved with the user:

- [x] **VST3:** plugins receive no CC in this spec. VST3 has no MIDI event; delivery needs the
  host to map a controller to a parameter through the plugin's `IMidiMapping`, which
  `plugin_host/vst3` does not implement. Follow-up spec: implement `IMidiMapping` in
  `plugin_host/vst3` and have `translate_events` turn `EVENT_MIDI_CC` into a parameter point.
  Until then `translate_events` counts the event in `Dropped.unsupported`.
