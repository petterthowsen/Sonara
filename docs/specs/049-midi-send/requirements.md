# MIDI Send — Requirements

The first step toward playing several tracks from one clip, such as a Choir group that drives
basses, tenors, altos and sopranos, or a string section for sketching. Later steps (Voice Pick and
Key Range note effects, splitting a group clip to its children, a dedicated Divisi device) build on
this spec and are out of scope here. Related: spec 048's voice extraction, which copies one voice of
a chord onto a track as an edit rather than live.

## Problem

Group tracks can't hold clips, and MIDI never leaves the channel it arrives on. To play a section
from one part, you have to copy the clip onto every child track and keep the copies in sync by hand.
Arrangers notice this when sketching orchestral or choir parts: changing one chord means editing
four or five clips.

## Scope

| | |
|---|---|
| Subsystem | both |
| Touches real-time audio thread | yes. Notes travel between channels inside the audio callback, so the design must respect the audio-thread contract and the channel worker pool (ADR 0020) |
| Adds or changes an OSC message | yes: setting a MIDI Send's targets and mode, and the device's status. `docs/subsystems/osc-protocol.md` is part of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | `.sonara`: group tracks save clip instances, and MIDI Send saves its target mode and targets. Both are additive keys, so older projects load unchanged and no migration is needed. `config.json`: a new choice value for the two group-arm settings |

## Terms

- **MIDI Send**: a built-in note device that forwards the note events reaching it to other channels.
- **Sender**: the channel whose chain holds a MIDI Send.
- **Target**: a channel a MIDI Send forwards to. Forwarded events enter the target's chain at its
  start, the same way the target's own clip notes do.
- **Children mode**: the targets are the channels nested directly under the sender in the mixer,
  re-evaluated whenever that nesting changes.
- **List mode**: the targets are an explicit list of channels.
- **Thru / Consume**: whether forwarded events also continue down the sender's own chain (Thru) or
  stop at the MIDI Send (Consume).
- **Note device**: a note effect or an instrument (built-in, CLAP or VST3).

## Requirements

### Group clips

#### REQ-001 — Group tracks hold MIDI clips

The arranger shall let a group track hold MIDI clips: create, draw, move, resize, copy, paste,
delete, and open in the MIDI editor, exactly as on an instrument track. It shall refuse audio clips
on a group track, the same way it refuses a drop it can't accept today.

- **Acceptance:** headless Godot test: create a MIDI clip on a group track, move it and paste it
  (instances present), then drop an audio clip on the group (refused, no instance).

#### REQ-002 — Group clips play into the group's chain

WHILE the transport plays, the audio callback shall deliver a group clip's notes to the group
channel's device chain at the same sample-accurate frames an instrument track's clip notes get.

- **Acceptance:** engine test: a clip on a track routed to a bus channel with a test note device;
  the device receives each note at the frame expected from 960 PPQ and the tempo.

#### REQ-003 — No MIDI Send means no sound, and no error

IF a group's chain has no note device that passes the notes on, THEN its clip notes shall be dropped
silently: no audio, no warning, and no hanging notes when a note device is inserted later.

- **Acceptance:** engine test: a bus channel with only an audio effect plays a clip; the output
  matches the same project without the clip, and no WARN is logged.

### MIDI Send

#### REQ-004 — MIDI Send is a built-in note device

The device browser shall offer MIDI Send among the built-in note effects. It shall be insertable
anywhere a note effect can go, on any user channel (instrument, audio or bus).

> **Amended at the design gate:** top-level chain only. Nested containers and slots are refused
> (design.md, Divergences 1).

- **Acceptance:** the device appears through `/builtin/request` → `/builtin/info`, and the
  note-effect conformance test passes for it.

#### REQ-005 — Same block, same frame

WHEN a note event reaches a MIDI Send at frame *f* of a block, each target's chain shall receive it
at frame *f* of that same block. No latency is added.

- **Acceptance:** engine test: a clip on track A, where A's MIDI Send targets channel B (a
  PolySynth), renders sample-identically to the same clip placed on B directly.

#### REQ-006 — Every note event is forwarded

A MIDI Send shall forward note-ons, note-offs, note expressions, controller and pitch-bend events,
with their original frames and values.

- **Acceptance:** engine test: each event kind sent into a sender arrives unchanged at a test note
  device on the target.

#### REQ-007 — Children mode

WHERE a MIDI Send is in children mode, its targets shall be the channels nested directly under the
sender in the mixer. Adding, removing or re-nesting a child channel changes the targets from the
next block on, without editing the device.

- **Acceptance:** engine test: a sender in children mode with two children; add a third, and its
  device receives the next note.

#### REQ-008 — List mode

WHERE a MIDI Send is in list mode, its targets shall be the listed channels. Any user channel may be
listed except the sender itself. The master channel and hardware outputs may not be listed.

- **Acceptance:** engine test: a list of channel ids including the sender, master and a hardware
  output keeps only the valid ids; the device view offers only valid channels.

#### REQ-009 — Thru and Consume

The MIDI Send shall have a Thru/Consume switch, defaulting to Thru. With Thru, the events also
continue to the devices after it in the sender's chain. With Consume, they stop at the MIDI Send.

- **Acceptance:** engine test: a sender with MIDI Send then PolySynth; Thru gives sound on both the
  sender and the target, and Consume gives sound only on the target.

#### REQ-010 — Note-offs always follow

WHEN a MIDI Send is bypassed, removed, switched mode, or has its targets changed, or a target or the
sender is deleted, every note it started on a target that no longer receives from it shall be
released on that target in the next block. No note shall be left hanging.

- **Acceptance:** engine test for each trigger: hold a note through the send, apply the trigger, and
  the target has no sounding note one block later.

#### REQ-011 — Transport stop, jump and loop wrap

WHEN the transport stops, jumps or wraps at the loop end, forwarded clip notes shall be released on
the targets exactly as each target's own clip notes are.

- **Acceptance:** engine test: a forwarded clip note sustaining across the loop end is released at
  the wrap frame on the target.

#### REQ-012 — Several sources on one target

WHEN a target gets the same key from more than one source (its own clip, live input, one or more
MIDI Sends), the notes shall be independent: ending one source's note shall not end another's.

- **Acceptance:** engine test: B's own clip holds C3 while A's send starts and ends C3; B's C3 is
  still sounding afterwards.

#### REQ-013 — Chains of sends

WHEN MIDI Sends chain (A → B → C), C shall receive A's events in the same block and at the same
frame.

- **Acceptance:** engine test: A → B → C renders sample-identically to the clip placed on C.

#### REQ-014 — Send loops are refused

IF setting a MIDI Send's targets or mode, or re-nesting a channel, would make a MIDI path lead back
to its own sender, THEN the engine shall not form the loop. The edge that would close it is ignored,
a warning reaches the UI log, and the device view marks that target as looping.

- **Acceptance:** engine test: A → B, then B lists A; A's events are not delivered back to A, and
  one warning is logged.

#### REQ-015 — Live input

WHILE a sender is record-armed, its live MIDI input shall be forwarded through its MIDI Send like
clip notes.

- **Acceptance:** live check: arm a group whose MIDI Send targets its children, play the virtual
  keyboard, and every child sounds.

#### REQ-016 — Saved with the project

The project file shall save a MIDI Send's mode, Thru/Consume and list targets, and group tracks'
clip instances. Reloading shall restore them, and children mode shall still follow the nesting
after reload.

- **Acceptance:** Godot test: round-trip a project through save and load; the device state and the
  group clips are equal, and a project saved before this spec loads unchanged.

#### REQ-017 — Device view

The MIDI Send view shall show the mode, the Thru/Consume switch and the current targets by channel
name. In list mode it shall let you add and remove targets from the valid channels. Names shall
follow renames, a deleted target shall disappear, and a looping target shall be marked (REQ-014).

- **Acceptance:** live check: add a target and rename it, and the view updates; delete it, and it
  disappears.

### Recording on a group

#### REQ-018 — Arm the group itself when it can play notes

Both group-arm settings (`arranger/group_arm_without_targets`, `arranger/group_arm_with_targets`)
shall gain the choice "Record arm the group if it has a note device". A group counts only when its
own chain holds a note device; a group with only audio effects does not. A group that doesn't count
falls back to the option's existing behaviour for that case (last armed valid child).

- **Acceptance:** extend `test_group_record_arm.gd`: with the new option, a group with a MIDI Send
  arms itself, and a group with only a Reverb arms its last armed child.

#### REQ-019 — Recording onto a group

> **Deferred at the design gate:** Sonara has no MIDI recording yet. This moves to the spec that
> adds it (design.md, Divergences 2).
> Carry this into the MIDI-recording issue/spec when it is opened: a record-armed group with a note
> device (REQ-018) qualifies, and its recording lands on the group track (groups hold MIDI clips,
> REQ-001).

WHILE a group is record-armed and recording, recorded MIDI shall land as a MIDI clip on the group
track, as it does on an instrument track.

- **Acceptance:** live check: arm a group with a MIDI Send, record four bars from the virtual
  keyboard, and a clip with those notes appears on the group track.

### Interchange

#### REQ-020 — DAWproject export reports what it drops

IF a project with group clips or MIDI Sends is exported to DAWproject, THEN the transfer report
shall list each MIDI Send, and each group clip the format can't carry, as not transferred.

- **Acceptance:** Godot DAWproject export test: the report contains one entry per MIDI Send.

## Non-functional

- **Real-time safety:** forwarding must not allocate, lock or block on the audio callback. Every
  target list, sounding-note table and event buffer is preallocated with a fixed capacity. When one
  is full, new note-ons are dropped (logged at most once a second), and note-offs are never dropped.
- **Latency / performance:** no added latency (REQ-005). Projects without a MIDI Send render exactly
  as before. Output with N pool workers is sample-identical to the output with one (ADR 0020).
- **Compatibility:** older projects load unchanged. A project with group clips opened in an older
  build loses those clips, which is acceptable.

## Out of scope

- Voice Pick, Key Range, Divisi, and "split group clip to children".
- Inserting a MIDI Send automatically when a clip lands on a group (decided: the user adds it).
- Audio clips on group tracks.
- Sending to hardware MIDI outputs, and forwarding a plugin's own note output.
- Folder tracks: they have no channel and so no chain.

## Open questions

Each one has a proposed answer. Please confirm or change it at the gate.

All three confirmed as proposed at the requirements gate.

- [x] **Children mode depth:** direct children only (proposed), or all descendants? With direct
  children, a nested group gets the notes and decides with its own MIDI Send, which composes better.
- [x] **Thru as default** (proposed), or Consume? Thru suits "send". On a group it makes no
  difference, because a bus has no instrument after the send.
- [x] **Arm option fallback:** when the group has no note device, the new option falls back to "last
  armed valid child" (proposed), or to arming the group anyway?
