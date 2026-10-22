# Virtual Stage — Requirements

A built-in virtual stage: channels set to the **Stage** pan mode are placed in one shared room,
seen from above. The stage renders each source's direct sound, its early reflections and a shared
late tail. Plugins such as Parallax VSS do this with one instance per track; built in, one room
description, one tail and one placement view serve the whole project.

This spec covers stereo output, box-shaped rooms, room presets and the top-down placement view.
Source directivity, microphone setups as the listener, binaural output and surround layouts are
later specs (see Out of scope). The data model already stores height and orientation so those
specs extend it rather than change it.

## Problem

Placing orchestral instruments convincingly in a room today needs a placement plugin on every
channel, each one configured with the same room by hand, plus a separately matched reverb. Pan
alone only sets left and right: nothing says "back of the stage" or "close to the listener".
Composers working with dry sample libraries notice this most. Sections sound pasted onto the
reverb instead of standing in a hall.

## Scope

| | |
|---|---|
| Subsystem | both |
| Touches real-time audio thread | yes. Stage sources are rendered in the mixer's fader-and-pan pass and the reflections and tail feed a new route target, so the design must respect the audio-thread contract, the channel worker pool (ADR 0020) and latency compensation (ADR 0021). The "pan is a static matrix" assumption in the fader pass changes, which needs an ADR |
| Adds or changes an OSC message | yes: the Stage pan mode value, per-channel stage parameters, the project's stage settings, and the Stage return. `docs/subsystems/osc-protocol.md` is part of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | `.sonara`: a project-level stage block, and per-channel stage parameters. Both are additive keys, so older projects load unchanged and no migration is needed. The new `pan_mode` name is unknown to older builds, which fall back to their default pan mode |

## Terms

- **Stage**: the project's one virtual room: its dimensions, wall materials, listener position,
  tail settings and output mode. There is exactly one stage per project.
- **Stage source**: a channel whose pan mode is Stage. It has a position on the stage.
- **Listener**: the point the stage is heard from. Facing the front wall by default.
- **Position**: a stage source's X (left/right), Y (front/back, distance from the front wall) and
  Z (height above the floor), in meters inside the room.
- **Size**: a stage source's width in meters. A stereo source is rendered as two points, its left
  and right inputs, `size` meters apart along the source's line.
- **Rotation**: the angle of the source's line in the top-down view. 0° means parallel to the
  front wall.
- **Size-0 sum mode**: how a stereo source becomes a single point at size 0: `L+R` or `Mid`.
- **Has room**: a per-source flag for material recorded with its own room. The stage positions it
  but sends it no reflections or tail.
- **Direct sound**: the part of a stage source that reaches the listener without touching a wall.
- **Reflections**: the early reflections from the room's walls, floor and ceiling.
- **Tail**: the late reverberation of the room, shared by all stage sources.
- **Stage return**: the return channel that carries the reflections and tail of all stage sources.
- **Output mode**: a stage setting: `Full` (reflections and tail), `Reflections only` (for an
  external reverb on the Stage return), or `Direct only` (no Stage return signal at all).
- **Room preset**: a named set of room dimensions, materials, listener position and tail settings.
- **Stage view**: the top-down placement editor.

## Requirements

### Pan mode and sources

#### REQ-001 — Stage is a pan mode

The mixer shall offer Stage as a pan mode on instrument, audio and group channels, next to the
existing pan modes. Choosing it makes the channel a stage source. Other buses (folder buses and
return channels), master and the Stage return shall not offer it, so no signal is spatialized twice.

- **Acceptance:** headless Godot test: set an instrument channel's pan mode to Stage; the channel
  model reports Stage, and the engine channel reports the Stage pan mode in its status. A bus
  channel refuses Stage and keeps its pan mode. The engine, which has no channel types, refuses
  Stage on master and on the Stage return.

#### REQ-002 — Initial position follows the current pan

WHEN a channel switches to Stage and has no stage position yet, the mixer shall place it with X
taken from its current pan and at the room's default source depth, at the default height, with
size 0 for a mono input and 3 m for a stereo input.

- **Acceptance:** Godot model test.
- **Example:** pan −0.5 in a 20 m wide room → X = −5 m from the room's center line.

#### REQ-003 — Leaving Stage restores the previous pan

WHEN a stage source switches to another pan mode, the mixer shall restore the pan values it had
before entering Stage. The source's stage parameters shall be kept, so switching back to Stage
puts it where it was.

- **Acceptance:** Godot model test: pan 0.3 Balance → Stage → move → Balance (pan 0.3) → Stage
  (moved position).

#### REQ-004 — Direct sound is placed by position

WHILE a channel is a stage source, the audio callback shall render its direct sound from its
position relative to the listener. A source further away shall be quieter and duller (air
absorption), and a source to the listener's left shall be louder in the left output than in the
right.

- **Acceptance:** engine tests: the same impulse at 3 m and 15 m (farther = lower RMS and lower
  energy above 8 kHz); a source at X = −5 m has more left energy than right.

#### REQ-005 — Direct sound follows the channel's route

The direct sound of a stage source shall go to the channel's route and post-fader sends exactly as
a panned signal does today, so group buses and their effects still process it.

- **Acceptance:** engine test: a stage source routed to a bus reaches the bus, and not master
  directly.

#### REQ-006 — Size spreads a stereo source

WHERE a stage source has a stereo input, the audio callback shall render its left and right inputs
as two points `size` meters apart, centered on its position and lying along its rotation. At size 0
it shall render a single point using its size-0 sum mode.

- **Acceptance:** engine test: a source with size 0 and size 10 m at the same position. With 10 m,
  a left-only input is louder on the left output than a right-only input is. With size 0 they
  match.

#### REQ-007 — Mono sources stay a point

WHERE a stage source has a mono input, the audio callback shall render it as one point whatever
its size.

- **Acceptance:** engine test: a mono source at size 0 and size 10 m gives the same output.

#### REQ-008 — Distance delay is optional

WHERE the stage's Distance delay setting is off (the default), the direct sound of every stage
source shall arrive with no delay added for distance. WHERE it is on, the direct sound shall be
delayed by its distance to the listener divided by the speed of sound. In both cases each
reflection keeps its delay relative to its source's direct sound.

- **Acceptance:** engine test: an impulse 17 m away arrives at frame 0 with the setting off, and
  at about 50 ms with it on. The first reflection lags the direct sound by the same amount in both.

### Room, reflections and tail

#### REQ-009 — Reflections depend on position

WHERE the output mode is Full or Reflections only, the audio callback shall render each stage
source's reflections from its position, the room's dimensions, the wall materials and the
listener's position, and mix them into the Stage return. Moving a source changes its reflections.

- **Acceptance:** engine test: a source near the left wall yields an earlier first reflection than
  the same source in the room's center.

#### REQ-010 — Height changes the reflections

The audio callback shall use a source's Z position for its floor and ceiling reflections.

- **Acceptance:** engine test: the same source at Z = 1 m and Z = 6 m in a 10 m high room
  produces different floor and ceiling reflection delays.

#### REQ-011 — One shared tail

WHERE the output mode is Full, the audio callback shall feed all stage sources into one tail whose
decay matches the room preset's decay time, and mix it into the Stage return. The tail starts as
the reflections fade, without a gap in level.

- **Acceptance:** engine test: measured decay of the tail from an impulse is within 15 % of the
  room's decay time. A listening check confirms there is no audible gap between reflections and tail.

#### REQ-012 — Output modes

The audio callback shall honour the stage's output mode: Full mixes reflections and tail into the
Stage return; Reflections only mixes reflections and no tail; Direct only mixes nothing into the
Stage return.

- **Acceptance:** engine test for each mode: the Stage return's output energy (reflections only,
  tail only, none).

#### REQ-013 — Has room

WHERE a stage source has Has room set, the audio callback shall render its direct sound and mix
none of its signal into the reflections or tail.

- **Acceptance:** engine test: Stage return output is silent when its only source has Has room.

#### REQ-014 — The tail rings out

WHEN every stage source falls silent, the Stage return shall keep rendering until its reflections
and tail have decayed, and only then may it sleep.

- **Acceptance:** engine test: after a source stops, the Stage return produces signal for at least
  the room's decay time.

#### REQ-015 — Room presets

The stage shall offer at least these room presets: Scoring Stage, Concert Hall, Church, Chamber
Room and Studio Room. Choosing one sets the room's dimensions, wall materials, listener position
and tail settings. Any of these can then be edited, after which the stage shows the preset as
modified.

- **Acceptance:** Godot model test: apply each preset; values match its definition; editing one
  value marks it modified.

#### REQ-016 — Editable room

The Stage view shall let the user edit the room's width, depth and height, the material of each
surface (front, back, left, right, floor, ceiling), the listener's position, the decay time and
the Distance delay setting.

- **Acceptance:** Godot model test: each edit reaches the engine as a stage setting.

### Stage return

#### REQ-017 — The Stage return channel

WHEN the first channel in a project becomes a stage source, the mixer shall create the Stage return,
routed to master by default and routable to any bus. There shall be at most one Stage return per
project. Its fader, mute, solo, devices and sends work like any channel's.

- **Acceptance:** Godot model test: two channels switch to Stage; one Stage return exists. An
  engine test confirms its devices process the reflections and tail.

#### REQ-018 — The Stage return is kept while it has sources

IF the user tries to delete the Stage return while stage sources exist, THEN the mixer shall
refuse and explain why. WHEN no stage sources remain, the Stage return shall stay in the project
until the user deletes it.

- **Acceptance:** Godot model test: delete refused with a source; allowed with none.

#### REQ-019 — Solo keeps the room

WHEN a stage source is soloed, the mixer shall keep that source's reflections and tail audible
through the Stage return, and the other sources' reflections and tail shall be silent.

- **Acceptance:** engine test: two sources, one soloed; the Stage return carries only the soloed
  source's reflections.

#### REQ-020 — Mute removes the source from the room

WHILE a stage source is muted, the audio callback shall mix none of its signal into the
reflections or tail.

- **Acceptance:** engine test.

### Stage view

#### REQ-021 — Top-down view of every stage source

The Stage view shall show the room from above with the listener and every stage source, each drawn
as a bar of its size and rotation (a dot at size 0), in its channel's colour and labelled with its
channel's name. It shall be openable as a window and attachable in the editor's primary view, like
a device view.

- **Acceptance:** headless Godot test: three stage sources → three source items with the right
  names; a channel leaving Stage removes its item.

#### REQ-022 — Placing sources

In the Stage view, dragging a source's middle shall move it, dragging an end shall change its size
and rotation, and a height control shall set Z for the selected sources. Moving several selected
sources shall keep their relative positions. Sources cannot leave the room.

- **Acceptance:** headless Godot model test of the edit operations (move, resize, rotate, clamp to
  room, multi-move). Dragging itself is a live check.

#### REQ-023 — Source settings

The Stage view shall let the user set, for the selected source, its size-0 sum mode and Has room.

- **Acceptance:** Godot model test.

#### REQ-024 — Selection follows the mixer

WHEN a stage source is selected in the Stage view, the editor shall select its channel, and the
other way round.

- **Acceptance:** headless Godot test.

### Automation, persistence and export

#### REQ-025 — Stage parameters are automatable

Each stage source's X, Y, Z, size and rotation shall be automation targets. WHILE they are
automated, the Stage view shall show the automated position.

- **Acceptance:** engine test: an automated X sweep moves the left/right balance over the clip.
  Godot test: the target exists in the automation target list.

#### REQ-026 — Moving sources don't click

WHEN a source's position, size or rotation changes, including under automation, the audio callback
shall change its sound smoothly, without clicks or zipper noise.

- **Acceptance:** engine test: an X jump from −5 m to +5 m produces no sample-to-sample step larger
  than with a smooth ramp. A listening check with a sine source confirms.

#### REQ-027 — Room changes don't click

WHEN the room is changed while audio plays (a preset, a dimension, a material, the listener), the
audio callback shall crossfade to the new reflections rather than jump.

- **Acceptance:** listening check while switching presets during playback.

#### REQ-028 — Saved with the project

The project file shall save the stage and every channel's stage parameters, and loading the
project shall restore them and send them to the engine.

- **Acceptance:** Godot round-trip test: save, load, compare values and the stage OSC messages.

#### REQ-029 — Offline export matches playback

Exporting a project shall render the stage exactly as real-time playback does.

- **Acceptance:** engine test: render the same block through the real-time and offline paths; the
  outputs are identical.

#### REQ-030 — DAWproject export reports the loss

WHEN a project with stage sources is exported as DAWproject, the exporter shall write each stage
source with its X mapped to pan, and the transfer report shall list the stage as not transferred.

- **Acceptance:** Godot DAWproject export test.

## Non-functional

- **Real-time safety:** all stage rendering runs inside the audio callback or the channel worker
  pool with no allocation, locking or I/O. Every delay line and buffer sized by the largest room is
  preallocated. Room changes reach the callback as prepared data, never as work done on the
  callback.
- **Performance:** 64 stereo stage sources in Full mode at 48 kHz and 128-frame blocks use less than
  15 % of one core on the reference laptop, measured with the engine's channel timers.
- **Latency:** the stage adds no reported latency. Distance delay is part of the sound, not latency
  to compensate.
- **Compatibility:** projects without a stage load unchanged. A project with stage sources opened
  in an older build loads with those channels on the default pan mode.

## Out of scope

- Surround and object output layouts (5.1, 7.1.4) and variable channel widths. The renderer's
  design should allow them later.
- Binaural (HRTF) output.
- Microphone setups as the listener (Decca tree, ORTF, AB, close and room mics).
- Source directivity, beyond storing rotation.
- Rooms that aren't box-shaped.
- A 3D Stage view.
- Spreading a mono source over a width (decorrelation).
- More than one stage per project.

## Open questions

None. Resolved:

- Buses can't be stage sources (REQ-001).
- 64 sources is the performance target.
- Whether the Stage return is a new channel kind or a flagged bus is decided in design.md.
