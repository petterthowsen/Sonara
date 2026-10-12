# Device Chain Slots — Requirements

## Problem

To build a "note effect → PolySynth → delay" sound today, the user wraps the three devices in a
Chain. That works, but it makes the instrument a container with an extra panel and an extra level
in the device lane, and a preset of it is a Chain preset rather than a PolySynth preset. Bitwig
solves this with **device slots**: an instrument has a Note FX slot for note effects in front of it
and an FX slot for audio effects after it, and the Delay and Reverb have slots inside their
feedback loops (Delay+ FB FX, Reverb Tank FX and Wet FX). Sonara has the slot machinery for
containers (the lane bracket, slot chains, Multiband's fixed bands) but no built-in device that is
not a container can have slots.

## Scope

| | |
|---|---|
| Subsystem | both. Engine: the PolySynth, Delay and Reverb gain slot chains and run them. Godot: the device model, the device lane, drop rules and the Simple View |
| Touches real-time audio thread | yes. Slot chains run inside the device's own processing, and the loop slots run in sub-blocks inside a feedback loop |
| Adds or changes an OSC message | yes. `/builtin/info` gains a trailing block that lists the device's slots |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. A slotted device saves its slot chains as children in the `.sonara` project and in device presets. Projects and presets saved before this spec get empty slots when they load (REQ-030) |

## Terms

- **Device slot**: a fixed, named slot chain that is built into a device that isn't otherwise a
  container. It is shown like any container slot: a bracket in the slot's colour beside the
  device in the device lane. A device slot can't be added, removed, moved or renamed.
- **Slotted device**: a built-in device that has device slots. In this spec these are the
  PolySynth, the Delay and the Reverb.
- **Note slot**: a device slot that takes notes. It holds note effects only.
- **Audio slot**: a device slot that takes audio. It holds audio effects only.
- **Loop slot**: an audio slot that sits inside a feedback loop (the Delay's FB FX and the Reverb's
  Tank FX). It holds built-in audio effects only.
- **Slot tile**: the control that stands for one device slot in the Simple View.

| Device | Slot | Kind | Where it runs |
|---|---|---|---|
| PolySynth | Note FX | note | on the notes that reach the PolySynth, before its voices |
| PolySynth | FX | audio | on the PolySynth's output |
| Delay | FB FX | audio, loop | on the signal fed back into the delay line, once per repeat |
| Reverb | Tank FX | audio, loop | on the signal circulating in the reverb tank, once per pass |
| Reverb | Wet FX | audio | on the wet signal, before Mix |

## Requirements

### Slots and signal flow

#### REQ-001 — Slots exist on every instance

Every PolySynth, Delay and Reverb instance shall have exactly the device slots in the Terms table,
in that order, from the moment it's created.

- **Acceptance:** Godot test: a new instance of each device has slot keys for its slots, in table
  order, each holding an empty chain. Engine test: the device reports the same slot count.
- **Example:** a new PolySynth has "Note FX" then "FX", and both are empty.

#### REQ-002 — An empty slot changes nothing

WHILE every device slot of a slotted device is empty, the device's audio output shall be
sample-identical to its output without slots, for the same input, notes and parameters.

- **Acceptance:** engine test for each of the three devices: render the same input and notes
  through the device with empty slots and through a reference with no slot processing, and compare
  the outputs sample for sample.

#### REQ-003 — Note FX processes the PolySynth's notes

WHEN a note reaches a PolySynth, the PolySynth shall pass it through the note effects in its Note
FX slot, in slot order and by the same routing rules as a Chain, and shall play the notes that
come out at the frame offsets they come out with.

- **Acceptance:** engine test: a PolySynth whose Note FX slot holds a Transpose of +12 gets a
  note-on for key 60 at frame 37. It starts a voice for key 72 at frame 37.
- **Example:** a Chord effect in Note FX makes one input key sound three voices.

#### REQ-004 — Note FX releases what it sounds

IF a note effect in a Note FX slot is removed, bypassed or moved, or the transport stops or
jumps, THEN the PolySynth shall receive a note-off for every note that effect has sounding, as it
would for a note effect in a Chain.

- **Acceptance:** engine test: an Arpeggiator in Note FX is playing a held chord, then it's
  removed. Every voice it started gets a note-off and no voice is left held.

#### REQ-005 — MIDI controllers reach the Note FX slot

WHEN a MIDI controller message reaches a PolySynth, the PolySynth shall pass it to every device in
its Note FX slot as well as using it itself.

- **Acceptance:** engine test: a controller sent to the PolySynth is recorded by a device in its
  Note FX slot.

#### REQ-006 — FX processes the PolySynth's output

The PolySynth shall run its output through the devices in its FX slot, in slot order, and output
the result.

- **Acceptance:** engine test: with a gain effect at 0.5 in the FX slot, the PolySynth's output is
  half of its output with an empty FX slot.

#### REQ-007 — FB FX processes each delay repeat

WHILE the Delay's FB FX slot holds at least one enabled device, the Delay shall run the signal it
feeds back into the delay line through that slot, so that the first repeat isn't processed by
the slot and each later repeat has passed through the slot once more than the one before it.

- **Acceptance:** engine test: FB FX holds a gain of 0.5, Feedback is 100 % and Mix is 100 % wet,
  with the tone filters and drive neutral. An impulse gives repeats whose peaks fall by half from
  the second repeat on, within 0.5 dB.

#### REQ-008 — Tank FX processes each tank pass

WHILE the Reverb's Tank FX slot holds at least one enabled device, the Reverb shall run the
signal that circulates in its tank through that slot once per pass around the loop, for all three
algorithms (Room, Hall, Plate) and while Freeze is on.

- **Acceptance:** engine test: Tank FX holds a gain of 0.5. For each algorithm the tail's
  energy decays measurably faster than with an empty Tank FX slot. With a gain of 1.0 the tail
  matches an empty slot within 1 dB over the first second.

#### REQ-009 — Wet FX processes the wet signal

The Reverb shall run its wet signal through the devices in its Wet FX slot before the Mix stage,
so the dry signal never passes through Wet FX.

- **Acceptance:** engine test: with Mix at 0 % (dry only) and a gain of 0 in Wet FX, the output
  equals the input. With Mix at 100 %, the output is silent.

#### REQ-010 — Loop slot minimum time

WHILE a loop slot holds at least one enabled device, the loop's shortest round trip (the Delay
time, or the Reverb's shortest tank delay at the current Size) shall be at least the loop slot's
processing block, and that block shall be at most 1.5 ms at sample rates of 44.1 kHz and above.
A shorter setting shall be lengthened to that minimum without a click.

- **Acceptance:** engine test: Delay time is 1 ms and FB FX holds a gain of 1.0. Repeats arrive at
  the minimum spacing, which is at most 1.5 ms at 48 kHz, and the output has no step larger than
  the input's.

#### REQ-011 — Loop slots stay real-time safe

Running a slot chain, including a loop slot run in sub-blocks, shall not allocate, block, do
I/O or take a lock on the audio thread.

- **Acceptance:** code review against the audio-thread contract (ADR-0002), plus an engine test
  that runs each slotted device with a full slot chain under the allocation-counting harness if
  one exists, otherwise review only.

#### REQ-012 — Bypass

WHILE a slotted device is bypassed, its slots shall be bypassed with it, so the device passes
its input through unchanged (an instrument outputs silence, as it does today). WHILE a device
inside a slot is bypassed, only that device shall be skipped.

- **Acceptance:** engine test: a bypassed Delay with a gain of 0 in FB FX outputs its input.

#### REQ-013 — Sleep keeps slot tails

A slotted device shall not go to sleep while any device in its slots still produces audio, so
that a delay in a PolySynth's FX slot rings out after the last note.

- **Acceptance:** engine test: a PolySynth with a Delay in FX. After the last voice ends, the
  output stays non-silent until the delay tail has decayed, and only then does the PolySynth
  sleep.

### What a slot accepts

#### REQ-014 — Note slots take note effects only

IF a device that isn't a note effect is dropped, pasted or added (including by an AI tool) into a
note slot, THEN Godot shall refuse it, and the drop indicator shall not offer that position.

- **Acceptance:** Godot test: dropping a Delay on the PolySynth's Note FX slot is refused, and
  dropping a Transpose is accepted.

#### REQ-015 — Audio slots take audio effects only

IF an instrument or a note effect, or a container holding one, is dropped, pasted or added into an
audio slot, THEN Godot shall refuse it.

- **Acceptance:** Godot test: dropping a PolySynth or a Transpose on the PolySynth's FX slot is
  refused, and dropping a Delay or a Chain of effects is accepted.

#### REQ-016 — Loop slots take built-in effects only

IF a CLAP or VST3 plugin, or a container holding one, is dropped, pasted or added into a loop
slot, THEN Godot shall refuse it. Plugins remain allowed in the FX and Wet FX slots.

- **Acceptance:** Godot test: a CLAP effect is refused on the Delay's FB FX slot and accepted on
  the Reverb's Wet FX slot.

#### REQ-017 — The engine enforces the same rules

IF the engine is asked to add a device into a device slot that the slot doesn't accept, THEN the
engine shall not add it and shall log a warning naming the slot and the device.

- **Acceptance:** engine test: adding a polysynth into a PolySynth's FX slot through the command
  path leaves the slot empty and logs a warning.

#### REQ-018 — Slots are fixed

The device lane, the context menus and the AI tools shall not offer to remove, move, rename,
duplicate or drag a device slot's chain itself. Devices inside the slot can be edited as in any
slot.

- **Acceptance:** Godot test: removing or moving a slot chain of a PolySynth is refused, and so is
  dragging it.

### Device lane

#### REQ-019 — Slots open beside the device

WHEN the user opens a device slot, the device lane shall show it beside the slotted device under a
bracket in the slot's colour, as it shows a container slot, with an empty slot showing a drop zone.

- **Acceptance:** Godot test: opening the PolySynth's FX slot adds a slot group for it in the
  device lane. Live: the bracket and the drop zone look like a Chain's.

#### REQ-020 — One slot open at a time

WHEN the user opens a device slot, the device lane shall close any other open slot of the same
device.

- **Acceptance:** Godot test: open Note FX, then FX. Only FX is open.

#### REQ-021 — Slot colours

The device lane bracket and the slot tile of a note slot shall use the theme's secondary accent
colour, the same colour that marks note effects in the device panel. Audio slots shall use the
theme's primary accent colour. Neither can be recoloured by the user.

- **Acceptance:** Godot test: `slot_color` of the Note FX slot equals the `accent_secondary` role
  colour, and that of the FX slot equals the `accent` role colour.

#### REQ-022 — Slot contents reveal their slot

WHEN a device is added into a device slot, the device lane shall open that slot.

- **Acceptance:** Godot test: adding a Transpose into a closed Note FX slot opens it.

### Simple View

#### REQ-023 — A slotted device keeps its Simple View

A slotted device that uses the generated Simple View today shall keep using it.

- **Acceptance:** Godot test: `uses_simple_view` is true for PolySynth, Delay and Reverb.

#### REQ-024 — One slot tile per slot

The Simple View of a slotted device shall show one slot tile per device slot. The tile shows the
slot's name and how many devices it holds, and it is coloured with the slot's colour (REQ-021).

- **Acceptance:** Godot test: the PolySynth Simple View has two slot tiles labelled "Note FX" and
  "FX". After a Transpose is added to Note FX, its tile shows a count of 1.

#### REQ-025 — Clicking a slot tile opens the slot

WHEN the user clicks a slot tile, the device lane shall open that slot, or close it if it's
already open. The tile shall show whether its slot is open.

- **Acceptance:** Godot test: clicking the FX tile opens FX, and clicking it again closes it.

#### REQ-026 — Dropping on a slot tile

WHEN the user drops a device on a slot tile, Godot shall add it at the end of that slot, subject
to REQ-014 to REQ-016, and open the slot.

- **Acceptance:** Godot test: dropping a Delay asset on the FX tile adds it as the FX slot's last
  device.

#### REQ-027 — Slot tiles go last

WHEN the Simple View layout generator builds a layout for a slotted device, it shall place the
slot tiles in a group of their own after every other group on the Main page, at the right end,
in slot order.

- **Acceptance:** Godot test (`test_simple_layout_generator.gd`): for PolySynth, Delay and Reverb
  the last group on Main holds exactly the slot tiles, in table order, and no tile appears on
  another page.

#### REQ-028 — Layouts the user edited get the tiles

WHEN a saved Simple View layout that the user edited is loaded for a slotted device and it lacks
a tile for one of the device's slots, Godot shall append the missing tile at the end of the Main
page. Layouts the user never edited shall be generated again (with tiles).

- **Acceptance:** Godot test: an edited PolySynth layout without tiles gets both tiles appended at
  the end of Main when it loads, and every other control stays where it was.

### Saving, presets, modulation

#### REQ-029 — Projects and presets keep slot contents

WHEN a project or a device preset that holds a slotted device is saved and loaded again, every
slot shall come back with the same devices, parameters, bypass states and modulators.

- **Acceptance:** Godot test: save a PolySynth preset with a Transpose in Note FX and a Delay in
  FX, then load it on a new channel. Both devices are back in the right slots with their values.

#### REQ-030 — Older projects and presets get empty slots

WHEN a project or preset saved before this spec loads a PolySynth, Delay or Reverb, Godot shall
give it its missing slots, empty, and the device shall sound as it did.

- **Acceptance:** Godot test: loading a pre-spec PolySynth JSON (no children) yields an instance
  with two empty slots and the same parameter values.

#### REQ-031 — Loading a preset replaces slot contents

WHEN a device preset is loaded onto an existing slotted device, the device's slot contents shall
be replaced by the preset's, and a preset without slot contents (saved before this spec) shall
leave the slots empty. The load shall be one undo step.

- **Acceptance:** Godot test: a PolySynth with a Delay in FX loads a pre-spec PolySynth preset.
  FX ends up empty, and one undo brings the Delay back.

#### REQ-032 — Modulators reach slot devices

A slotted device's modulators shall be able to route to the parameters of devices inside its
slots, as a container's modulators can reach its children.

- **Acceptance:** engine test: a PolySynth LFO routed to the Mix of a Delay in its FX slot changes
  the Delay's effective Mix.

#### REQ-033 — Automation reaches slot devices

An automation lane shall be able to target the parameter of a device inside a device slot, and the
automation picker shall list it under the slotted device.

- **Acceptance:** Godot test: the automation target list of a channel holding a PolySynth with a
  Delay in FX includes that Delay's parameters.

#### REQ-034 — DAWproject export reports slot contents

WHEN a project is exported to DAWproject, any device inside a device slot that the export can't
place shall be listed in the transfer report, and the export shall still succeed.

- **Acceptance:** Godot test: exporting a project with a Delay in a PolySynth FX slot succeeds and
  the transfer report names the Delay.

## Non-functional

- **Real-time safety:** slot chains run on the audio thread inside the slotted device's
  processing. Every buffer they need, including the loop sub-block buffers, is allocated when the
  device is created or prepared. Nothing waits on a lock (REQ-011).
- **Latency / performance:** an empty slot costs one branch per block. A loop slot with devices
  costs one chain call per sub-block (REQ-010). Plugins are kept out of loop slots for that reason
  (REQ-016).
- **Compatibility:** pre-spec projects and presets load with empty slots (REQ-030). The
  `/builtin/info` change adds a trailing block, so old decoders keep working.

## Out of scope

- Slots on other instruments (Sampler, SFZ, drums) and other effects. The mechanism is generic, but
  only the three devices in the Terms table declare slots.
- Slots on CLAP or VST3 plugins.
- Wrapping existing Chains into slots, and turning a slot back into a Chain.
- Latency compensation for plugins in the FX or Wet FX slots beyond what Sonara does today.
- A per-slot mix or volume control.

## Open questions

None. Resolved with the user before writing:

- [x] Loop slots take built-in effects only (REQ-016).
- [x] Only the PolySynth gets Note FX and FX in this spec.
- [x] One slot of a device is open at a time (REQ-020).
- [x] Older projects and presets get empty slots on load (REQ-030).
