# Multi-out devices — Requirements

## Problem

Some devices produce more than one stereo output: the Drum Machine has one per pad, and a CLAP
plugin can have extra audio output ports. Today each extra output feeds a nested "return" channel
in the mixer, but those rules live in drum-machine special cases, they don't match between the two
kinds of source, and they break in edge cases. Undoing a pad removal creates a brand-new return
with default settings, CLAP returns still get timeline tracks, and a return can be deleted on its
own, which leaves the device pointing at a missing channel. Separately, in the device lane a nested
channel gives no hint that it has a parent and offers no way back to it. The user notices this when
they select a drum pad's return channel and see an empty lane with no way to get back to the
Drum Machine.

## Scope

| | |
|---|---|
| Subsystem | Godot (data model, device lane). The engine's extra-out → child routing already exists and is unchanged |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no. Uses the existing `/channel/{id}/aux_out` |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. Channels get a new `aux_pad_note` key (the drum pad a return belongs to, -1 otherwise). Missing in older saves, where it's filled in from the pad on load (REQ-011) |

## Terms

- **Multi-out device**: a device on a channel's root chain that exposes one or more *extra
  outputs* besides its main stereo pair. Drum Machine: one extra output per pad. CLAP plugin:
  one per stereo output port after the first.
- **Return channel**: the nested mixer channel an extra output feeds.
- **Source**: the multi-out device and output index that feed a return channel.
- **Nested channel**: any channel with a mixer parent. That includes return channels and children
  of user-created groups.
- **Pad**: a Drum Machine slot identified by its MIDI note. It has a return channel and, optionally,
  one *pad device* (the Drum Machine child that plays on that note). A pad without a device is
  *empty*; its return channel stays.
- **Pad lane**: the device chain shown for a pad's return channel: the pad device (if any) followed
  by the return channel's own devices.

## Requirements

### Multi-out contract

### REQ-001 — One return per extra output

WHEN a multi-out device is added to a channel's root chain, the project model shall create one
return channel per extra output. Each return is nested under that channel, with its output locked
to it.

- **Acceptance:** headless Godot test. Add a device whose descriptor reports 6 output channels
  (2 extra stereo outputs) to channel A. A now has exactly 2 child channels, each with
  `output_channel_id == A.id`.
- **Example:** 8-channel CLAP plugin on "Synth" → children "Out 2", "Out 3", "Out 4".

### REQ-002 — Drum pads are extra outputs

WHEN a pad is added to, removed from, or reordered within a Drum Machine on a channel's root chain,
the project model shall add, remove, or reorder that pad's return channel so the returns match
the pad order.

- **Acceptance:** headless test. Add pads KICK, SNARE, HAT, move HAT to the first slot, then remove
  SNARE. The drum channel's children are [HAT, KICK], and the engine aux map sent for them uses
  bus indices [0, 1].

### REQ-003 — No timeline tracks for returns

The project model shall not create a timeline track for any return channel, whether the source is
a Drum Machine pad or a CLAP plugin.

- **Acceptance:** headless test. Adding the Drum Machine with 2 pads and an 8-channel plugin
  leaves the project's track count unchanged.

### REQ-004 — Return names

The project model shall name a pad's return after the pad, and a plugin extra output's return
"Out N" (N = output number, starting at 2). Both names are project-unique. WHEN a pad is
renamed, its return channel shall be renamed to match.

- **Acceptance:** existing `Godot/tests/test_unique_names.gd` still passes, plus a new rename
  check.

### REQ-005 — Source lookup

The project model shall resolve any return channel to its source (device and output index), and
any extra output of a multi-out device to its return channel.

- **Acceptance:** headless test. For each return created in REQ-001/REQ-002, looking up the
  source gives back the device and index that created it, and looking up the return for that
  index gives back the same channel.

### REQ-006 — Engine aux map stays in sync

WHEN a return channel is created, removed, or reindexed, or the parent channel is (re)created in
the engine, the project model shall send the parent's full extra-output → return mapping to the
engine.

- **Acceptance:** headless test with OSC capture shows one `/channel/{parent}/aux_out` per return
  with the current bus index after each operation. Live check: each Drum Machine pad is heard
  through its own return fader.

### REQ-007 — Removing the source removes its returns

WHEN a multi-out device is removed, the project model shall remove the return channels fed by it,
including those of empty pads. WHEN a pad is removed, its return channel shall be removed with it.
WHEN only a pad's device is removed, the pad shall become empty and keep its return channel.

- **Acceptance:** headless test. Removing the Drum Machine removes every pad return. Deleting the
  KICK return removes the KICK pad device and the return. Removing the KICK pad device with
  `DeviceRemoveCommand` leaves the KICK return in place.
- *Revised 2026-09-15:* pads persist when their device is removed (Bitwig model).

### REQ-008 — Undo restores returns intact

WHEN the removal of a multi-out device or pad is undone, the project model shall restore its
return channels with their original channel ids, fader, pan, mute/solo, sends and device chains.

- **Acceptance:** headless test. Set the KICK return volume to −6 dB and add a device to it,
  remove the pad, then undo. The KICK return has the same id, −6 dB, and the same device.

### REQ-009 — Returns can't be detached

IF the user tries to move a return channel out of its parent, or to delete a plugin extra-output
return on its own, THEN the mixer shall refuse. Deleting a pad's return channel removes the pad
(REQ-007).

- **Acceptance:** the channel context menu's Delete is disabled for plugin returns and enabled for
  pad returns, and a mixer drag of any return onto another parent or the root is rejected.
- *Revised 2026-09-15:* pad returns can be deleted, which removes the pad.

### REQ-010 — Deleting the parent channel

WHEN a channel that hosts a multi-out device is deleted, the mixer shall delete its return
channels with it, and undo shall restore them all.

- **Acceptance:** existing `Godot/tests/test_linked_delete.gd` passes, extended with a plugin
  extra-output case.

### REQ-011 — Loading projects

WHEN a project is loaded, the project model shall link every return channel to its source and
create any missing returns, without duplicating a return that already exists. This includes
projects saved before this change.

- **Acceptance:** headless test. Load a fixture project saved in the current format that has a
  Drum Machine with 2 pads. After loading there are exactly 2 pad returns with their saved ids
  and volumes, and a save → load round trip keeps them unchanged.

### Device lane navigation

### REQ-012 — Parent header

WHILE the device lane is bound to a nested channel, the device lane shall show a parent header
to the left of the channel header. The parent header shows the parent channel's name and color.

- **Acceptance:** live. Select a drum pad return: the lane shows [Drum channel header][KICK
  header][devices…]. Select a top-level channel: only its own header is shown.

### REQ-013 — Parent header follows the parent

WHEN the bound channel's parent is renamed, recolored, changed, or removed, the device lane shall
update or hide the parent header to match.

- **Acceptance:** live. Renaming the drum channel updates the parent header text immediately.
  Un-nesting a group child hides the header.

### REQ-014 — Going up

WHEN the user clicks the parent header, the editor shall select the parent channel exactly as a
click on that channel in the mixer would. The mixer selection moves to the parent and the device
lane binds to the parent channel and shows its devices.

- **Acceptance:** live. With a pad return bound, click the parent header. The drum channel's
  mixer strip is selected and the lane shows the Drum Machine. For a channel nested two levels
  deep, clicking twice reaches the top-level channel.

### Pad lane

### REQ-015 — Pad device on the return channel

WHILE the device lane or a mixer strip shows a pad's return channel, the device lane and the
mixer strip shall show the pad lane: the pad device first, then the return channel's own devices.
The pad device is the same instance the Drum Machine holds, so edits show up in both places.

- **Acceptance:** live. Select the KICK return: the lane shows [Drums][KICK][Sampler][Kick FX…],
  and the KICK strip's device list shows the Sampler first. A plugin "Out 2" return shows only its
  own devices.

### REQ-016 — Removing the pad device empties the pad

WHEN the pad device is removed from the pad lane, the Drum Machine shall remove that child. The pad
and its return channel (with its devices) stay.

- **Acceptance:** headless test. Remove the KICK Sampler: the Drum Machine has no child on note
  36, and the KICK return still exists with the same id and devices.

### REQ-017 — The front of the pad lane plays the pad

WHEN a device is added or dragged to the first position of a pad lane, the Drum Machine shall use
that device as the pad device on the pad's note. Any previous pad device becomes the first device
of the return channel's own chain. WHEN the pad device is dragged behind another device, that
device becomes the pad device.

- **Acceptance:** headless test. Empty KICK pad: add a PolySynth at lane index 0, and it becomes the
  Drum Machine child on note 36 feeding the KICK return. With [Sampler][Delay], moving the Sampler
  to the end gives [Delay][Sampler], with Delay as the pad device on note 36 and Sampler as a return
  device. Each step undoes back to the previous state.
- **Example:** drop an EQ at index 0 of [Sampler] → [EQ][Sampler]; EQ is the pad device (silent,
  since nothing feeds it), Sampler is the return's first device.

### REQ-018 — Pad lane appends

WHEN a device is added anywhere after the first position of a pad lane, the project model shall
insert it into the return channel's own chain at the matching position.

- **Acceptance:** headless test. [Sampler] + Delay appended → Delay is `KICK.devices[0]`.

### REQ-019 — A pad keeps its return across note changes and refills

WHEN a pad device's MIDI note changes, the pad's return shall follow the device. WHEN a device is
added to an empty pad's note in the Drum Machine (grid drop or pad lane), it shall adopt that pad's
existing return instead of creating a new one.

- **Acceptance:** headless test. Empty the KICK pad, then add a PolySynth to the Drum Machine on
  note 36: no new channel is created and the PolySynth feeds the KICK return.

## Non-functional

- **Real-time safety:** unchanged. No new work on the audio callback.
- **Compatibility:** projects saved with the current `return_channel_id` /
  `return_channel_ids` / `aux_bus_index` keys load with returns intact (REQ-011).

## Out of scope

- Showing the parent plugin on a plugin extra-output return's lane. The parent header is the
  navigation there.
- Showing empty pads in the Drum Machine grid (they're visible as mixer channels only).
- Dragging devices between a pad lane and other channels or containers. Pad lanes accept drags
  only between their own positions.
- Carrying CLAP extra output ports through `plugin_host` shared memory into the engine (still
  a separate `TODO.md` item). CLAP returns get created, but stay silent until that lands.
- A parent header on the mixer strip. Nested strips already sit inside their parent's fold-out.
- Showing more than the immediate parent. Deeper ancestors are reached by clicking the header
  repeatedly.
- Multi-in (sidechain inputs).

## Open questions

- [x] REQ-003: CLAP returns no longer get a timeline track (existing projects keep theirs). Approved.
- [x] REQ-009: deleting a return channel on its own is blocked. Approved.

Approved 2026-09-15; implementation proceeds directly without separate design/tasks gates.
- [x] Revised 2026-09-15 after live testing: pad device shown and editable on the pad return
      (REQ-015–019); pads persist when emptied; deleting a pad return removes the pad (REQ-007/009).

## Implementation status

Design and tasks gates were skipped at the user's request; implementation notes live here.

| Requirement | Status | Evidence |
|---|---|---|
| REQ-001–011, REQ-016–019 | `[x]` headless | `Godot/tests/test_multi_out_devices.gd` (REQ-010 is covered there, not in `test_linked_delete.gd`) |
| REQ-004 rename | `[x]` headless | `Godot/tests/test_unique_names.gd` `_test_pad_returns_do_not_loop` |
| REQ-009 | `[x]` | `LinkedDeleteSnapshot` refuses plugin returns (tested); UI guards checked live 2026-09-15 |
| REQ-006 live | `[x]` | Checked live by the user 2026-09-15 |
| REQ-012–014 | `[x]` live | Checked by the user 2026-09-15 (Drums \| Kick headers) |
| REQ-015, REQ-017 UI | `[x]` live | `DeviceLane.gd` / `ChannelDeviceList.gd` via `PadLane` + `PadLaneWatcher`; checked by the user 2026-09-15 |

Notes:
- New persisted channel key `aux_pad_note`. Older saves get it filled in from the pad on load. Device keys are unchanged.
- Removing a root multi-out device keeps its returns on `DeviceInstance.detached_returns` (not persisted), which is how undo gets the same channels back. Removing a pad device leaves an empty pad; deleting the pad's return (mixer, or "Remove Pad" in the Drum Machine folder) removes the pad.
- Pad lane edits (`PadLane.commands`) are built from a target lane. The front device goes into the Drum Machine on the pad note (`DeviceTransferCommand` / `DeviceAddCommand`), and the rest become moves and adds on the return channel.
- A device that adopts an empty pad doesn't rename the return; only renaming the pad device does.
- Known limitation: the engine only treats `devices[0]` as the aux source (`Channel::process_aux_source`). A multi-out device further down the chain still gets returns, but they stay silent.
- Known limitation: moving a device between the Drum Machine and the return channel re-creates it in the engine (parameters and loaded file are re-sent; CLAP plugin state that isn't exposed as a parameter is lost).
