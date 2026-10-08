# 027: Note effects — Requirements

Status: approved 2026-10-08.

## Problem

Notes go from a clip or live input straight to a channel's instruments, unchanged. There is no
way to arpeggiate a held chord, play a chord from one key, transpose a part without editing the
clip, tame or randomise velocities, echo notes, or split a keyboard between instruments, except
with the per-slot note maps in a Layer (spec 006). Every serious DAW has a set of MIDI/note
effects for this. Users notice the gap whenever they play a pad or bassline live, or want
generative variation without rewriting the clip.

This spec adds **note effects**: built-in devices that take notes in and send notes out to the
devices after them. Instead of one monolithic device, it adds a small set of single-purpose
effects that combine in chains: an arpeggiator followed by Chance and Note Echo, or Chord
followed by Transpose with scale snap. Two **note containers** run note effects in parallel.

## Scope

| | |
|---|---|
| Subsystem | Both. Engine (note flow through device chains, ten note effect devices, two note containers), Godot (browser category, device lane, device views, container views) |
| Touches real-time audio thread | yes. Note effects run on the audio callback, generate and schedule notes, and change which notes reach which device |
| Adds or changes an OSC message | yes. Built-in device info reports the new note-effect category. A device data stream carries the Step Sequencer's and Arpeggiator's current step. A new message sends the project scale to the engine (amending spec 026, which says the scale never reaches the engine). Note containers reuse the existing container messages |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes, additive only. Note effects and note containers save like other built-in devices. Older projects contain none and load unchanged (REQ-043) |

Delivery order (each wave usable on its own):

1. Note flow through chains (REQ-001 to REQ-012), plus Transpose, Note Filter and Velocity.
2. Chord, Arpeggiator, Chance.
3. Step Sequencer, Note Echo, Note Length, Latch.
4. Note Layer and Note Selector.

## Terms

- **Note effect**: a built-in device that receives notes and sends notes on. It doesn't change
  audio, so audio passes through it untouched.
- **Downstream**: the devices after a note effect in the same chain, plus any devices nested
  inside them.
- **Input note**: a note arriving at a note effect.
- **Output note**: a note a note effect sends downstream. It can be a changed input note
  (Transpose) or a **generated note** (a chord voice, an arpeggio step, an echo).
- **Held notes**: the input notes whose note-on has arrived and whose note-off hasn't.
- **Clocked effect**: a note effect that emits notes on a tempo grid (Arpeggiator, Step
  Sequencer, synced Note Echo, synced Note Length).
- **Rate**: a musical length used by clocked effects: 1/1, 1/2, 1/4, 1/8, 1/16, 1/32, each also
  dotted and triplet.
- **Note container**: a container whose slots hold only note effects and whose output is notes.
- **Branch**: one slot chain of a note container.

## Requirements

### Note flow through chains

#### REQ-001 — Note effects feed only downstream devices

The engine shall deliver a note effect's output notes to its downstream devices, and only to
them. Devices before a note effect in the chain keep receiving the notes that reached the note
effect.

- **Acceptance:** engine unit test. Chain [Polysynth A, Transpose +12, Polysynth B]. A note-on 60
  reaches A as 60 and B as 72. A never receives 72.

#### REQ-002 — Chained note effects compose in order

WHEN several note effects sit in a row, each one's output shall be the next one's input, in chain
order.

- **Acceptance:** engine unit test. [Transpose +12, Note Filter keep 70–80, instrument]. Input 60
  becomes 72, which passes the filter, so the instrument gets 72. Input 70 becomes 82, which is
  dropped. With the two effects swapped, input 70 passes the filter and arrives as 82.

#### REQ-003 — Sample-accurate output

A note effect that changes or passes a note shall emit it at the same sample position it arrived
at. A generated note shall be emitted at the sample position its timing rule gives it, including
positions that fall inside a later audio block.

- **Acceptance:** engine unit test. A note-on at frame offset 37 through Transpose arrives
  downstream at offset 37. A Note Echo repeat due 1.5 blocks later arrives in the next block at the
  correct offset.

#### REQ-004 — Note-offs follow their note-ons

WHEN an input note-off arrives, the note effect shall send the note-off for every output note that
input note produced, even if the effect's parameters changed while the note was held.

- **Acceptance:** engine unit test, one per stateless effect. Transpose +12: note-on 60 (out 72),
  set Transpose to +7, note-off 60. Downstream receives note-off 72 and nothing on 67.

#### REQ-005 — Distinct identities for generated notes

Every output note shall carry an identity distinct from every other note sounding on the channel,
and its note-off shall carry the same identity. A changed input note keeps the input note's
identity.

- **Acceptance:** engine unit test. Chord with voices +4 and +7 on one note-on produces three
  note-ons with three different note ids, none equal to any other sounding id on the channel. The
  three note-offs carry the matching ids.

#### REQ-006 — No notes left hanging

WHEN a note effect is bypassed, removed, moved, or replaced, or its device preset is loaded, the
engine shall send a note-off for every note it had sounding downstream and discard any notes it
had scheduled.

- **Acceptance:** engine unit test. Arpeggiator mid-pattern with a held chord: bypass it. Every
  sounding arpeggio note gets a note-off in that block, and no further arpeggio notes arrive.

#### REQ-007 — Transport stop and jumps

WHEN the transport stops or the playhead jumps, each note effect shall release the notes it
generated from clip notes and discard the clip notes it had scheduled. Notes coming from live input
keep playing.

- **Acceptance:** engine unit test. A clip note into Note Echo with 4 repeats: stop after the first
  repeat. No more repeats arrive. A live-held key through an Arpeggiator keeps arpeggiating.

#### REQ-008 — Bypassed note effects pass notes through

WHILE a note effect is bypassed, it shall pass its input notes downstream unchanged.

- **Acceptance:** engine unit test. Bypassed Transpose +12 delivers 60 as 60.

#### REQ-009 — Out-of-range pitches are dropped

IF a note effect would produce a pitch below 0 or above 127, THEN it shall drop that output note
rather than wrapping or clamping it.

- **Acceptance:** engine unit test. Transpose +12 on input 120 produces nothing. On input 100 it
  produces 112.

#### REQ-010 — Live input and playback alike

Note effects shall process live input (an armed channel or the virtual keyboard), clip playback,
clip editor note previews and Drum Machine pad triggers the same way.

- **Acceptance:** live. With an Arpeggiator on a channel, holding a chord on the virtual keyboard
  and playing the same chord from a clip produce the same pattern.

#### REQ-011 — Note-driven modulators see output notes

A modulator driven by notes (velocity, keytrack, an envelope triggered by notes) on a downstream
device shall respond to the note effect's output notes, not its input.

- **Acceptance:** engine unit test. Velocity device fixed at 0.25 before a Polysynth with a
  velocity modulator. The modulator reads 0.25 whatever the input velocity is.

#### REQ-012 — Sleep

A note effect shall never sleep while it holds notes, has notes sounding downstream, or has notes
scheduled. A downstream device asleep when a generated note arrives shall wake for it.

- **Acceptance:** engine unit test. Hold a note through a Latch for 10 s of simulated time with no
  other input. The Latch and the instrument stay awake and the note keeps sounding.

#### REQ-013 — Note effects inside containers

Note effects shall work in any chain that receives notes: a channel's root chain, a Chain, a Layer
slot and a Drum Machine pad. A note effect inside a slot affects only that slot.

- **Acceptance:** engine unit test. Layer with two slots, Transpose +12 at the start of slot A
  only. Note-on 60 reaches slot A's instrument as 72 and slot B's as 60.

### Transpose

#### REQ-014 — Transpose

Transpose shall shift every input note by its **Semitones** (−48 to +48) plus 12 × its **Octaves**
(−4 to +4).

- **Acceptance:** engine unit test. Semitones +3, Octaves −1: 60 becomes 51.

#### REQ-015 — Scale snap

WHERE Transpose's **Scale** is on, it shall move each shifted note to the nearest pitch in the
selected scale. A note exactly between two scale pitches goes down. The scale is either **Follow
project** (the project scale from spec 026) or a root and scale type chosen on the device. With
Follow project and no project scale set, it doesn't snap. This amends spec 026: the project scale
now reaches the engine as project state, while staying UI-only in every other respect.

- **Acceptance:** engine unit test. Scale C major, Semitones 0: 61 (C#3) becomes 60, 66 (F#3)
  becomes 65. Live: switch the project scale to D minor while Transpose follows it, and the next
  note snaps to D minor.

### Note Filter

#### REQ-016 — Note Filter

Note Filter shall pass a note-on only if its pitch is within **Key Low** to **Key High** and its
velocity within **Velocity Low** to **Velocity High**. WHERE **Invert** is on, it shall pass only
the note-ons that fail that test. Note-offs follow REQ-004.

- **Acceptance:** engine unit test. Keys 48–59, velocities 0–1: 50 passes and 60 is dropped. With
  Invert on, 60 passes and 50 is dropped. Note-on 50, change the range to 60–72, then note-off 50:
  the note-off for 50 still passes.

### Velocity

#### REQ-017 — Velocity

Velocity shall reshape each note-on's velocity: apply **Curve** (−100 % to +100 %, 0 = linear),
map the result into **Out Low** to **Out High**, then add a random offset of up to ±**Random**
(0–100 % of the full range), clamped to the output range. Release velocity on note-offs is left
unchanged. Out Low equal to Out High gives a fixed velocity.

- **Acceptance:** engine unit test. Curve 0, Out 0.5–1.0, Random 0: input 0 becomes 0.5 and input
  1 becomes 1.0. Out Low = Out High = 0.8: every note-on is 0.8. Random 20 %: 1000 note-ons at
  0.5 all land within 0.3–0.7.

### Chord

#### REQ-018 — Chord voices

Chord shall emit, for each input note-on, the original note (unless **Play Original** is off) plus
one note for each enabled **Voice** (up to 6). Each voice has an **Interval** (−24 to +24
semitones) and a **Velocity** (0–100 % of the input velocity). Voices that land on the same pitch
as another output of the same input note are emitted once.

- **Acceptance:** engine unit test. Voices +4 at 100 % and +7 at 50 %, input 60 at velocity 0.8:
  outputs 60 at 0.8, 64 at 0.8 and 67 at 0.4. A voice +12 together with another voice at +12
  produces one 72.

#### REQ-019 — Strum

WHERE **Strum** is above 0 ms (up to 500 ms), Chord shall spread its outputs for one input note
over the strum time, evenly spaced, from lowest to highest pitch, or highest to lowest WHERE
**Strum Direction** is Down. A note-off arriving before a strummed voice has started cancels that
voice.

- **Acceptance:** engine unit test at 48 kHz. Three outputs, Strum 100 ms, Up: the lowest starts at
  the input offset, the middle 2400 frames later, the highest 4800 frames later.

### Arpeggiator

#### REQ-020 — Arpeggio order

The Arpeggiator shall play its held notes one at a time in the order set by **Mode**:

- **Up**: lowest to highest pitch.
- **Converge**: lowest, highest, second lowest, second highest, and so on.
- **As Played**: the order the notes were pressed.
- **Random**: a random held note each step, never the same note twice in a row when more than one
  is held.

**Octaves** (1–4) repeats the sequence that many times, each time 12 semitones higher, before
starting over. **Reverse** plays the whole sequence, octaves included, backwards (Up becomes
down, Converge becomes diverge). **Ping-Pong** plays the sequence forwards then backwards without
repeating the end notes, or repeating them WHERE **Repeat Ends** is on.

- **Acceptance:** engine unit test, held 60, 64, 67:
  - Up, Octaves 2: 60 64 67 72 76 79 60 …
  - Up, Octaves 2, Reverse: 79 76 72 67 64 60 79 …
  - Up, Octaves 1, Ping-Pong: 60 64 67 64 60 64 … With Repeat Ends: 60 64 67 67 64 60 60 …
  - Converge: 60 67 64 60 …
  - As Played, pressed 67, 60, 64: 67 60 64 …

#### REQ-021 — Arpeggio timing

The Arpeggiator shall start a step every **Rate**. Each step lasts **Gate** (10–200 % of the
step; above 100 % consecutive steps overlap). **Swing** (0–75 %) delays every second step by that
fraction of half a step. WHILE the transport plays, steps fall on the transport's Rate grid and
follow tempo changes. WHILE it is stopped, steps run at the project tempo, counted from the first
note-on.

- **Acceptance:** engine unit test at 120 BPM and 48 kHz. Rate 1/16 (6000 frames), Gate 50 %: notes
  start 6000 frames apart and last 3000. Swing 50 % moves every second step 1500 frames later.
  While playing, step starts are multiples of 240 ticks.

#### REQ-022 — Arpeggio start and changes

WHEN the first note of a chord is pressed while no notes are held, the Arpeggiator shall play
step 1 immediately at that note's sample position, then continue on the grid. WHEN notes are
added to or released from a running arpeggio, the pattern shall continue from its current
position with the new note set, without restarting.

- **Acceptance:** engine unit test. Note-on 60 at offset 100 between grid points produces an output
  at offset 100. Adding 64 mid-pattern doesn't send the pattern back to step 1.

#### REQ-023 — Arpeggio latch

WHERE the Arpeggiator's **Latch** is on, releasing all keys shall keep the last chord
arpeggiating. The next note pressed after all keys were released starts a new chord in place of
the latched one. Turning Latch off releases latched notes that aren't physically held.

- **Acceptance:** engine unit test. Latch on: press and release 60 and 64, and the pattern keeps
  running. Press 67 and the pattern is 67 only. Latch off: the arpeggio stops.

### Step Sequencer

#### REQ-024 — Steps

The Step Sequencer shall have 16 steps, of which the first **Length** (1–16) play in a loop. Each
step has **On**, **Pitch** (−24 to +24 semitones), **Velocity** (0–100 %)
and **Chance** (0–100 %). **Velocity Source** sets how step Velocity is used: **Input × Step** (a
percentage of the input velocity, the default) or **Step** (the step's Velocity as an absolute
value, ignoring the input). It uses **Rate**, **Gate** and **Swing** as the Arpeggiator does
(REQ-021). An off step, or one that loses its chance roll, plays nothing.

- **Acceptance:** engine unit test. Length 4, pitches 0, +3, +7, +12, step 3 off, holding 60:
  60, 63, rest, 72, 60, … With step 1 Velocity 50 % and input velocity 0.8, step 1 plays at 0.4
  with Input × Step and at 0.5 with Step.

#### REQ-025 — What the steps apply to

In **Chord** mode, each step plays every held note shifted by the step's Pitch. In **Mono** mode,
each step plays only the most recently pressed held note, shifted.

- **Acceptance:** engine unit test. Holding 60 and 64, step pitch +2. Chord: 62 and 66. Mono, 64
  pressed last: 66 only.

#### REQ-026 — Step position

WHILE the transport plays, the current step shall follow the transport (step index = Rate grid
position modulo Length), so the pattern stays locked to bars. WHILE it is stopped, the pattern
shall start at step 1 when a note is pressed while no notes are held.

- **Acceptance:** engine unit test. Length 4, Rate 1/16, transport at tick 960: a held note plays
  step 1 (960 / 240 = 4, and 4 mod 4 = 0). Transport stopped: the first note-on plays step 1.

### Note Echo

#### REQ-027 — Note Echo

Note Echo shall pass each input note through and add **Repeats** (1–16) copies of it, the k-th
starting k × **Time** later. Each repeat's velocity is the previous one's × **Decay** (0–100 %).
Each repeat is shifted **Pitch Step** (−12 to +12 semitones) further than the previous one. A
repeat keeps the length of its source note. Time is a Rate WHERE **Sync** is on, otherwise 1 to
2000 ms. Repeats whose velocity would be below 1/127 aren't played.

- **Acceptance:** engine unit test at 120 BPM. Repeats 3, Time 1/8, Decay 50 %, Pitch Step +12,
  input 60 at 0.8 lasting 100 ms: outputs 60 at 0.8 at t=0, 72 at 0.4 at 250 ms, 84 at 0.2 at
  500 ms, 96 at 0.1 at 750 ms, each 100 ms long.

### Chance

#### REQ-028 — Chance

Chance shall pass each note-on with probability **Chance** (0–100 %) and drop it otherwise. A
note-off passes only if its note-on passed.

- **Acceptance:** engine unit test. Chance 0 %: nothing passes. 100 %: everything does. 50 % over
  10 000 notes: between 45 % and 55 % pass, and the passed and dropped note-offs pair up exactly.

### Note Length

#### REQ-029 — Note Length

Note Length shall control output note lengths in one of two **Modes**:

- **Fixed**: every note lasts exactly **Length**, whenever its input note-off arrives.
- **Minimum**: a note lasts at least Length. A note held longer than that ends at its own note-off.

Length is a Rate WHERE **Sync** is on, otherwise 1 to 4000 ms. WHERE **Legato** is on, each new
note-on also ends every note Note Length is sounding.

- **Acceptance:** engine unit test at 120 BPM. Fixed 1/8: an input lasting 50 ms and one lasting
  1 s both produce 250 ms notes. Minimum 1/8: the 50 ms input lasts 250 ms and the 1 s input lasts
  1 s. Legato: a second note-on ends the first note at that sample.

### Latch

#### REQ-030 — Latch

Latch shall hold notes after their keys are released, in one of two **Modes**:

- **Chord**: a released chord keeps sounding until the next note is pressed after all keys were
  released, which replaces the held chord.
- **Toggle**: pressing a key starts its note, and pressing the same key again stops it.

WHEN Latch is bypassed, or **Release All** is triggered, every latched note shall be released.

- **Acceptance:** engine unit test. Chord: press and release 60 and 64, and both keep sounding.
  Press 67: 60 and 64 end and 67 sounds. Toggle: press 60, it sounds. Press 60 again, it ends.

### Note containers

#### REQ-031 — Note Layer

The Note Layer shall send each input note to every branch (up to 8) and merge the branches' output
notes into its own output. A muted branch outputs nothing. An empty branch passes its input through
unchanged.

- **Acceptance:** engine unit test. Branch A empty, branch B Transpose +12: input 60 produces 60 and
  72 downstream. Muting A leaves only 72.

#### REQ-032 — Note Selector

The Note Selector shall send each input note-on to exactly one of its branches (up to 8),
chosen by **Mode**:

- **Index**: the branch given by the **Select** parameter, which can be automated and modulated.
- **Round Robin**: the next branch in turn.
- **Random**: a random branch.

A note-off goes to the branch that received its note-on.

- **Acceptance:** engine unit test. Round Robin with 3 branches: note-ons go to A, B, C, A. Index
  with Select on B: note-on 60 goes to B. Change Select to C, and note-off 60 still goes to B.

#### REQ-033 — Note containers hold only note effects

The device lane shall accept only note effects in a note container's branches. Dropping any other
device there is refused, with the drop indicator showing it isn't allowed.

- **Acceptance:** headless Godot test. Adding a Polysynth to a Note Layer branch through the model
  is rejected. Adding a Transpose succeeds.

### Godot

#### REQ-034 — Note effect category

The engine shall report every note effect and note container with a note-effect category, and the
browser shall list them together under **Note Effects**, apart from instruments and audio effects.

- **Acceptance:** headless Godot test against the builtin info the engine sends. All ten note
  effects and both note containers appear under Note Effects and nowhere else.

#### REQ-035 — Where note effects can be added

The device lane shall accept note effects anywhere a device can go on an instrument channel and
inside Chain, Layer slot and Drum Machine pad chains. It shall refuse them on audio channels, bus
channels and Multiband FX bands, where no notes arrive.

- **Acceptance:** headless Godot test. Adding Transpose to an audio channel's chain is rejected and
  to an instrument channel's chain succeeds. Live: dragging a note effect over an audio channel's
  device lane shows a not-allowed indicator.

#### REQ-036 — Note effects look different

The device lane shall show note effects with a visual marker that sets them apart from audio
devices, using a color from the theme.

- **Acceptance:** live. A Transpose and a Delay side by side are told apart at a glance, in both the
  light and dark theme.

#### REQ-037 — Parameter views

Transpose, Note Filter, Velocity, Chord, Chance, Note Echo, Note Length, Latch and the Arpeggiator
shall each have a device view showing all their parameters grouped as in this spec. Controls that
don't apply in the current state (Strum Direction while Strum is 0, Repeat Ends while Ping-Pong is
off, the scale controls while Scale is off or follows the project) are shown disabled.

- **Acceptance:** live. Each device opens with every parameter reachable. Turning Ping-Pong off
  disables Repeat Ends.

#### REQ-038 — Step Sequencer view

The Step Sequencer view shall show the 16 steps as columns with a bar each for Pitch, Velocity and
Chance, and an On toggle. Dragging across the bars sets one step per column passed. Steps beyond
Length are shown dimmed. WHILE the sequencer is playing, the current step is highlighted.

- **Acceptance:** live. Drag across the Pitch row from step 1 to step 8 and each of the 8 steps
  takes the value under the cursor. Set Length to 6 and steps 7–16 dim. Hold a note: the highlight
  walks through steps 1–6.

#### REQ-039 — Arpeggiator step display

WHILE the Arpeggiator is playing, its view shall show which held note is sounding.

- **Acceptance:** live. Hold a three-note chord with Mode Up: the indicator walks low to high.

#### REQ-040 — Note container views

The Note Layer and Note Selector views shall show their branches in the device lane, like the Layer,
with add, remove, mute and rename for each branch. The Note Selector view also shows its Mode and
Select, and highlights the branch that received the last note-on.

- **Acceptance:** live. Add three branches to a Note Selector in Round Robin and play four notes:
  the highlight moves A, B, C, A.

#### REQ-041 — Automation, modulation and presets

Every note effect parameter, including each step's values and each chord voice's values, shall be
automatable and modulatable and shall be saved in device presets, like other built-in device
parameters.

- **Acceptance:** live. Automate Transpose's Semitones from 0 to +12 across a bar and hear the
  played notes rise. Save a Step Sequencer preset, load it on a new instance, and every step value
  matches.

#### REQ-042 — Undo

Adding, removing, moving and bypassing note effects and note container branches shall be undoable
like other device edits.

- **Acceptance:** headless Godot test. Add a Transpose, undo, and the chain is as before. Redo
  restores it with its parameters.

### Persistence

#### REQ-043 — Saving and loading

Note effects and note containers, with all their parameters and branches, shall be saved in the
project and restored on load. Projects saved before this feature load unchanged.

- **Acceptance:** headless Godot test. Save a project containing a Note Layer with an Arpeggiator in
  one branch and Chord in another, reload it, and the structure and every parameter match. A
  project saved before this feature (a serialized project with no note effects) round-trips with
  no differences.

## Non-functional

- **Real-time safety:** note effects run on the audio callback under the audio-thread contract:
  no allocation, locking, I/O or blocking. Held notes, sounding outputs and scheduled notes live in
  fixed-capacity storage sized at creation. IF that storage is full, THEN the effect drops the new
  generated note (never an input note-off) and logs a warning at most once per second.
- **Capacity:** each note effect handles at least 128 held notes, and each clocked or delaying
  effect at least 256 scheduled notes.
- **Latency:** note effects add no latency. Only the delays they exist for (strum, echo, swing,
  note length) move notes in time.
- **CPU:** a channel with 8 note effects and no notes playing costs no more than an empty channel
  plus 1 % of one core at 48 kHz with 256-frame buffers.
- **Determinism:** the random features (Velocity Random, Arpeggiator Random, step Chance, Chance,
  Note Selector Random) aren't required to repeat between runs.
- **Recording:** when MIDI recording is added, it records the notes arriving at the channel, before
  any note effect.

## Out of scope

- CLAP plugins as note effects (plugins with note outputs). CLAP instruments downstream of note
  effects do receive the output notes.
- Printing a note effect's output to a clip.
- Scale-aware (diatonic) chord intervals. Use Chord followed by Transpose with scale snap.
- Note Length shortening by a percentage. That needs the note's length before its note-off
  arrives, which live input can't provide.
- Per-note expression processing. Expression events pass through unchanged.
- Note effects reading MIDI CC, pitch bend or aftertouch.
- Replacing spec 006's Layer slot note maps with note effects.
- A free-running Step Sequencer that plays without held notes.

## Decisions

- **Step velocity:** the Step Sequencer has a Velocity Source switch, Input × Step (default) or
  Step (REQ-024).
- **Arpeggio start while playing:** step 1 plays at once on the note-on, and later steps fall on
  the grid (REQ-022).
- **Project scale in the engine:** spec 026 is amended so the engine receives the project scale,
  which Follow project uses (REQ-015).

## Open questions

None.
