# 027: Note effects — Design

Status: approved 2026-10-08.

Implements [requirements.md](./requirements.md).

## Context

How notes reach devices today:

- `Engine/src/audio/processing.rs` `process_audio` dispatches clip notes for every tick event
  through `Channel::send_clip_note` (`audio/types.rs`) before any device renders. Live MIDI is
  dispatched later in the same callback, from `Channel::begin_device_chain` (when `start == 0`)
  and `Channel::process_aux_source`, through `dispatch_scheduled_midi`. So within one block, clip
  and live events reach devices in an order that isn't sorted by frame offset.
- Both paths go through `Channel::send_note_event_to_devices` → `send_note_event_to` in
  `audio/types.rs`, which **broadcasts** every event to every top-level device and calls
  `mark_activity` on those with `accepts_note_input()`. `ChainDevice::send_note_event`
  (`devices/chain.rs`) broadcasts to its children in the same way. `LayerDevice`
  (`devices/layer.rs`) routes per slot through its note maps, and `DrumMachineDevice`
  (`devices/drum_machine.rs`) routes per pad. Their children are slot chains (`ChainDevice`).
- `NoteEvent` (`audio/midi_types.rs`) carries a `SoundingNoteId`. `ActiveNotes`
  (`audio/active_notes.rs`) issues ids in `[1, ID_LIMIT = 2^31)`, kept below 2^31 because the
  CLAP adapters pass the id on as a positive CLAP `note_id` (`clap_host/adapter.rs`,
  `subprocess_adapter/mod.rs`, `ipc/protocol.rs`). `ActiveNotes::release_clip` ends clip notes
  on Pause, Stop and Seek (`audio/commands.rs`, through `Channel::release_clip_notes`) and on loop
  wraps (`processing.rs`, through `release_clip_notes_at`).
- Devices queue note events with their frame offset and consume them in `process_block`. Chains
  run through `container::run_chain` / `resume_chain` (`devices/container.rs`), with sleeping
  devices skipped. `ModulatedDevice` (`audio/modulation/host.rs`) wraps a device that carries
  modulators. It feeds `send_note_event` to the note-driven modulators and queues the event for
  the inner device, delivering it per control step in `process_block`.
- Every block, `processing.rs` hands each device a `Transport` snapshot (`audio/transport.rs`:
  tempo, `tempo_inc`, playing, `song_pos_beats`, …) through `devices::apply_transport`, whether
  or not the transport is playing.
- Built-in devices declare parameters with `devices/param_table.rs` (`ParamSpec`, `ParamTable`,
  `ParamValues`). Effects and drums are listed in `devices/factory.rs` (`EFFECT_IDS`,
  `DRUM_IDS`, `create_effect`, `create_drum`) and checked by `effect_conformance.rs` /
  `drum_conformance.rs`. `builtin_device_info` maps `DeviceCategory` (`devices/mod.rs`:
  Instrument, Effect, Utility) to the strings `"instrument"`, `"effect"` and `"utility"`.
- `dsp/tempo_sync.rs` has the shared sync list (`SYNC_CHOICES`, `sync_beats`). `dsp/noise.rs`
  has a real-time-safe xorshift `Rng`.
- Separate outputs: `mixing.rs` `mark_aux_sources` / `process_aux_sources` and
  `Channel::process_aux_source` assume the aux source is `devices[0]`. Godot mirrors this in
  `devices/container/LayerSlotRow.gd` `_refresh_out_enabled` (spec 006 REQ-007).
- Godot: `data/Device.gd` (`DeviceCategory`, `get_browser_group`, `container_focuses_one_child`,
  `creates_instrument_track`), `data/DeviceRegistry.gd` `_category_from_string`,
  `devices/DeviceDropUtil.gd` (`device_fits_channel`, `can_drop_instance_on_host`),
  `data/SlotChain.gd` (slot chains of Layer and Drum Machine), `data/DeviceInstance.gd`
  `sync_slot_to_engine` / `_send_layer_slot` (`slot/{i}/mute`, handled in `osc/server.rs` as
  `AudioCommand::SetLayerSlotMute`), `devices/DeviceViewFactory.gd`, `devices/simple_view/`, and
  `core/AudioEngineOSC.gd` `subscribe_device_data`.
- Project scale: `data/Project.gd` `set_scale` / `scale_root` / `scale_type`, with
  `data/MusicalScale.gd` `TYPES` (spec 026). Nothing reaches the engine yet.

## Approach

**A note phase per chain.** A note effect is an `AudioDevice` that reports `is_note_effect()`
and passes audio through untouched. Note routing changes from "broadcast to every device" to
"deliver in chain order until the first note effect". A note effect *queues* what it receives.
Before a chain renders any audio, it runs a **note phase**: for each note effect in chain order,
call `process_notes(sample_count)`, which consumes the queued input together with the effect's
own clock and schedule and returns this block's output notes sorted by frame offset. Those notes
are then routed into the devices after the effect, again stopping at the next note effect, which
picks them up in its own turn in the same phase. All notes therefore reach every instrument
before the instrument renders, as today. ADR-0004 holds, because outputs keep their frame
offsets and later-dated notes stay in the effect's schedule until the block they fall in.

The note phase runs where live MIDI dispatch runs today (the channel's root chain), at the top of
`ChainDevice::process_block` (which covers every Chain, Layer slot and Drum Machine pad), and
inside note containers for their branches. The routing helpers live in one module and are used
by both `send_note_event_to` and `ChainDevice`, so the two can't drift apart.

**One generic host, small processors.** In the same way that `DrumHost<V: DrumVoice>` works, a
`NoteFxHost<P: NoteProcessor>` owns everything the ten devices share:

- input queue (sorted on entry to `process_notes`), output buffer and future-dated schedule;
- the **sounding table** (output note id, key, parent input id) that gives REQ-004 (note-offs
  follow their note-ons), REQ-006 (release everything) and REQ-007 (clip discontinuities) once;
- generated note ids, the bypass pass-through and the audio pass-through.

Each device is a `NoteProcessor` that only says what to emit and when, through a `NoteCx`
handle: `pass`, `emit_on` / `emit_off` at an absolute sample time, and `release_children`. The
clocked effects share a `StepClock`.

**Rejected alternatives:**

- *Note effects transform events synchronously inside `send_note_event` and forward them at
  once.* This works for Transpose, Filter, Velocity and Chance, but not for anything that emits
  without an input event in the block (arpeggio steps, echoes, strum, Note Length). Those need a
  per-block call anyway, and two delivery paths would make ordering bugs likely. The note phase
  serves both kinds.
- *A separate note event stream on `process_block`* (CLAP-style in/out event lists for every
  device). That is the most general option, but it changes every device and the CLAP adapters.
  Queuing through `send_note_event` keeps every existing device unchanged.
- *A dedicated `NoteBranch` type for note-container branches.* Branches are plain `ChainDevice`
  slot chains instead, so Godot's slot-chain machinery (`SlotChain.gd`, paths
  `{pos}/child/{i}/child/{j}`, undo) works unchanged. A chain marked as a note branch collects the
  notes that fall off its end.

**Generated note ids** keep the 31-bit space and encode their origin, so the transport-stop rule
(REQ-007) needs no new field on `NoteEvent`:

| Range | Bits 30, 29 | Issued by |
|---|---|---|
| `[1, 2^29)` | 0, 0 | `ActiveNotes`, live note |
| `[2^29, 2^30)` | 0, 1 | `ActiveNotes`, clip note |
| `[2^30, 2^30 + 2^29)` | 1, 0 | note effect, generated from a live note |
| `[2^30 + 2^29, 2^31)` | 1, 1 | note effect, generated from a clip note |

Generated ids come from one engine-wide `AtomicU32` counter (`fetch_add(Relaxed)`, lock-free,
safe on the audio thread). Ids are therefore unique across all note effects on all channels,
with no per-channel allocator to thread through the device tree (REQ-005). `is_clip_note(id)`
reads bit 29.

**Project scale (amends spec 026).** Godot sends the project scale as a 12-bit pitch-class mask
(bit 0 = C), and 0 means no scale. The engine stores it in `ProjectSettings` and copies it into
every block's `Transport`, which already reaches every device. Transpose in Follow mode reads
`transport.scale_mask`. The scale stays UI state in every other respect: no clip or note logic
in the engine uses it.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `NoteFxHost` input queue, output buffer, schedule, sounding table, held-note state | audio callback (inside the device, under the state lock) | command thread only for create (allocates, before insert), `set_parameter`, `set_enabled` (sets a flag), and the release helper below | yes: fixed-capacity arrays sized in `new()`, never grown |
| Generated-id counter (`static AtomicU32`) | none (atomic) | audio thread (`emit_on`), command thread (release helper) | yes |
| `ChainDevice` note-branch output buffer and `collects_note_output` flag | audio callback | command thread sets the flag in `NoteContainerDevice::insert_child` under the lock (no allocation: the buffer exists from `ChainDevice::new`) | yes |
| `release_pending` / `discontinuity_pending` flags in the host | audio callback consumes | command thread sets (`set_enabled(false)`, `Channel::stop_clip_notes`) | yes: plain bools under the state lock |
| Immediate release on remove/move | command thread, under the state lock | `note_fx::routing::release_note_effects(list)` runs before the structural edit, writing note-offs into downstream device queues at frame 0 | bounded work (≤ 256 note-offs per effect), no allocation |
| `ProjectSettings::scale_mask` | command thread writes (`SetProjectScale`) | audio thread reads it into `Transport` every block | yes (a `u16` copied under the lock) |
| Note-state data stream bytes | audio thread builds in `poll_device_data` | sent through the existing device-data status path | allocates one small `Vec<u8>` per poll at ~20 Hz, exactly like the spectrum and modulation streams |

Modulation of note-effect parameters: `ModulatedDevice` evaluates modulators per control step
inside `process_block`, which runs *after* the note phase. A note effect therefore sees
modulation offsets from the previous block (≤ one buffer of lag). This is accepted and documented
in the ADR, and no ADR is contradicted. ADR-0014 is satisfied: modulators remain instance state.

## Data and protocol changes

### Engine trait additions (`devices/mod.rs`)

```rust
pub enum DeviceCategory { Instrument, Effect, Utility, NoteEffect }

// on AudioDevice, all with no-op defaults:
fn is_note_effect(&self) -> bool { false }
/// Audio thread, once per block before the chain renders: consume queued input, return this
/// block's output notes sorted by frame offset.
fn process_notes(&mut self, _sample_count: usize) -> &[TimedNote] { &[] }
/// Command thread: write note-offs for everything sounding into the output buffer and drop the
/// schedule; returns them (frame 0).
fn release_notes_now(&mut self) -> &[TimedNote] { &[] }
/// Transport stopped/paused/seeked: drop clip-origin schedule, release clip-origin outputs at
/// the next `process_notes`.
fn note_discontinuity(&mut self) {}
```

`ModulatedDevice` forwards all four to the inner device. Its `send_note_event` updates the
modulators as today, but forwards straight to the inner device (instead of queueing for
`deliver_midi`) when the inner device `is_note_effect()`.

`DeviceContainer` gains `fn chain_children_mut(&mut self) -> Option<&mut Vec<Box<dyn AudioDevice>>> { None }`.
`ChainDevice` implements it. The release helper uses it because note effects only ever sit in
Vec-backed chains (channel root, Chain, slot chains, note branches).

### OSC

| Address | Args | Direction | Change |
|---|---|---|---|
| `/project/scale` | `i:mask` (12-bit pitch-class mask, 0 = none) | Godot → engine | **new**. `osc/server.rs` `["project", "scale"]` → `AudioCommand::SetProjectScale(u16)` (`audio/commands.rs`) → `state.settings.scale_mask` |
| `/builtin/info` | category string | engine → Godot | gains the value `"note_effect"` |
| `{device}/data/subscribe` `"note_state"` | | Godot → engine | new data type on the Arpeggiator, the Step Sequencer and both note containers |
| `{device}/data` `"note_state"` blob | `u8 step` (0xFF = none), `u8 sounding_key` (0xFF = none), `u8 branch` (0xFF = none), `u8 held_count`, `held_count × u8` held keys ascending | engine → Godot | new, ~20 Hz while subscribed |
| `{container}/slot/{i}/mute` | `i` | Godot → engine | existing address. Now also accepted when the container is a note container (`SetLayerSlotMute` handler downcasts to `NoteContainerDevice` as well) |

All of these go into `docs/subsystems/osc-protocol.md`.

### Godot models

- `Project.set_scale` sends `/project/scale` with `MusicalScale.make(root, type).mask()` after
  updating state. Project sync (next to the `/project/init` send in `Project.gd`) sends it too.
- `DeviceInstance.sync_slot_to_engine` sends `slot/{i}/mute` when the parent is a note container
  (branch mute reuses `slot_mute` and `set_slot_mute`).
- No new persisted keys: note effects save as ordinary device instances with parameters, and
  branches save as slot chains. Device presets work unchanged.

### Device ids and parameters

All devices use `param_table`. IDs are grouped in blocks of ten per module, and enums use the
choice lists shown. `Rate` = `SYNC_CHOICES` from `1/1` onwards, without `Off`.

| Device id | Name | Parameters (id: name, range) |
|---|---|---|
| `sonara.builtin.transpose` | Transpose | 0 Semitones −48..48 · 1 Octaves −4..4 · 10 Scale {Off, Follow Project, Custom} · 11 Root {C … B} · 12 Scale Type (`MusicalScale.TYPES` labels without None) |
| `sonara.builtin.note_filter` | Note Filter | 0 Key Low 0..127 · 1 Key High 0..127 · 2 Velocity Low 0..1 · 3 Velocity High 0..1 · 4 Invert |
| `sonara.builtin.velocity` | Velocity | 0 Curve −1..1 · 1 Out Low 0..1 · 2 Out High 0..1 · 3 Random 0..1 |
| `sonara.builtin.chord` | Chord | 0 Play Original · 1 Strum 0..500 ms · 2 Strum Direction {Up, Down} · Voice k (k = 1..6) at 10k: +0 On, +1 Interval −24..24, +2 Velocity 0..1 |
| `sonara.builtin.arpeggiator` | Arpeggiator | 0 Mode {Up, Converge, As Played, Random} · 1 Reverse · 2 Ping-Pong · 3 Repeat Ends · 4 Octaves 1..4 · 10 Rate · 11 Gate 0.1..2 · 12 Swing 0..0.75 · 20 Latch |
| `sonara.builtin.step_sequencer` | Step Sequencer | 0 Length 1..16 · 1 Mode {Chord, Mono} · 2 Velocity Source {Input × Step, Step} · 10 Rate · 11 Gate · 12 Swing · Step k (k = 1..16) at 100 + 10(k−1): +0 On, +1 Pitch −24..24, +2 Velocity 0..1, +3 Chance 0..1 |
| `sonara.builtin.note_echo` | Note Echo | 0 Repeats 1..16 · 1 Sync · 2 Time Rate · 3 Time 1..2000 ms · 4 Decay 0..1 · 5 Pitch Step −12..12 |
| `sonara.builtin.chance` | Chance | 0 Chance 0..1 |
| `sonara.builtin.note_length` | Note Length | 0 Mode {Fixed, Minimum} · 1 Sync · 2 Length Rate · 3 Length 1..4000 ms · 4 Legato |
| `sonara.builtin.latch` | Latch | 0 Mode {Chord, Toggle} · 1 Release All (momentary bool: 0 → 1 triggers) |
| `sonara.builtin.note_layer` | Note Layer | none |
| `sonara.builtin.note_selector` | Note Selector | 0 Mode {Index, Round Robin, Random} · 1 Select 1..8 |

Integer ranges are floats rounded on use, so they stay modulatable. "On", "Invert" and similar
switches are `Kind::Bool`.

## Behaviour details

- **Input order.** `NoteFxHost::send_note_event` appends to the input queue. `process_notes`
  insertion-sorts it by frame (stable, small n), because clip and live events arrive unsorted.
- **Host loop** (per block, `now` = absolute sample of frame 0):
  1. If `release_pending` (bypassed) or the effect has just been re-enabled, emit note-offs for
     the whole sounding table, clear the schedule, and call `P::reset`.
  2. If `discontinuity_pending`, drop clip-origin scheduled events, emit note-offs for
     clip-origin sounding outputs, and call `P::discontinuity`.
  3. While disabled, pass input through unchanged and stop.
  4. For each input event in order: `P::run_until(event_time)`, then `P::note(event)`. Then
     `P::run_until(block_end)`.
  5. Move due schedule entries (`at < now + sample_count`) into the output, merge-sorted.
  6. An input note-off whose id isn't in the sounding table and that the processor didn't claim
     passes through unchanged. This covers notes that started while the effect was bypassed or
     not yet inserted.
- **`NoteCx::emit_on(key, velocity, at, parent)`** returns a generated id (origin taken from
  `parent`). The note enters the sounding table when it is actually emitted.
  **`emit_off(id, at)`** for a note-on still in the schedule cancels both. This handles strum
  cancellation (REQ-019) and Note Length. **`release_children(parent, at)`** emits note-offs for
  every sounding or scheduled output of that input (REQ-004 for Chord, Transpose and Filter).
  Keys outside 0..127 are dropped in `emit_on` (REQ-009).
- **Capacity:** input 512, output 512, schedule 256, sounding 256, held 128. On overflow,
  generated notes are dropped, note-offs never are (a full output buffer flushes them in the next
  block at frame 0), and a rate-limited `warn!` is logged (once per second, using a
  sample-counter check).
- **`StepClock`** (`note_fx/clock.rs`) yields `(frame, step_index)` for step starts inside the
  block.
  - While `transport.playing`, steps sit at multiples of `rate_beats` in song position. The frame
    is computed from `song_pos_beats`, `tempo` and `tempo_inc`, and the index is
    `floor(beat / rate_beats)`.
  - While stopped, it free-runs from an anchor sample at `transport.tempo`.
  - Swing delays odd step indices by `swing × rate / 2`.
  - Arpeggiator immediate start (REQ-022): the processor emits step 1 at the note frame and tells
    the clock to skip a grid point less than half a step later, so the next step stays on the
    grid without a double hit.
  - The Step Sequencer doesn't start immediately while playing. It starts at the next grid point
    with index `step mod Length` (REQ-026). While stopped, it starts at the note frame from
    step 1.
  - Loop wraps aren't seen inside a block: the next block's transport realigns the grid. Clip
    notes are re-dispatched at the wrap anyway.
- **Stop, Pause and Seek** call `Channel::stop_clip_notes()` (new), which does
  `release_clip_notes()` and then `note_discontinuity()` on every note effect
  (`container::visit_devices_mut`). **Loop wraps** keep using `release_clip_notes_at` and are not
  a discontinuity, so echoes and latched notes ring across the loop point.
- **Bypass:** `set_enabled(false)` sets `release_pending`, and the next block releases.
  **Remove and move:** before `container::remove_device` / `move_device` touch a list holding a
  note effect, the command thread calls `release_note_effects(list)`. For each note effect in
  order, it takes `release_notes_now()` and routes those note-offs to the devices after it. Moving
  an instrument across an arpeggiator thus can't leave a note hanging. Loading a preset replaces
  the instance in Godot (`DeviceDropUtil.load_preset_into`), so it is a remove plus an add.
- **Sleep:** note effects never sleep (default `is_sleeping` = false). Routing marks downstream
  devices active exactly as `send_note_event_to` does now (REQ-012). The idle cost is one
  `process_notes` call that returns early, plus the audio pass-through copy.
- **Separate outputs** (amends spec 006 REQ-007): the aux source is the first device that isn't a
  note effect. `Channel::aux_source_index()` (new) replaces the hard-coded `0` in
  `process_aux_source` and `mixing.rs` (`start = aux_index + 1`). The leading note effects get
  their note phase in `process_aux_source` before the source renders. `LayerSlotRow` uses the same
  rule.
- **Note containers** (`NoteContainerDevice`, one type, `kind` Layer or Selector): its children
  are `ChainDevice`s with `collects_note_output = true`. `send_note_event` routes to branches
  (Layer: all non-muted; Selector: one, by Mode, remembered per note id so the note-off follows,
  REQ-032). `process_notes` runs each branch's note phase, then merges the branch outputs (k-way
  by frame) into its own sounding-tracked output. An empty branch's input falls straight through
  to its collected output (REQ-031). It is both `is_note_effect()` and `is_container()`.
- **Arpeggiator orders** are built into a fixed `[u8; 128 × 4]` sequence buffer whenever the held
  set or the Mode/Octaves/Reverse/Ping-Pong parameters change, never per step. Converge
  interleaves the sorted keys from both ends. Ping-Pong appends the reversed interior (with ends
  when Repeat Ends is on). Random picks with `Rng`, rerolling once when it hits the previous
  index and more than one note is held.
- **Velocity curve:** `out = in^(4^(−curve))`, then `lo + (hi − lo) × out`, then
  `+ (rng.bipolar() × random)`, clamped to `[lo, hi]` and to at least 1/127 so a note-on never
  becomes a note-off.
- **Scale snap:** the candidate pitch is searched outward from the shifted note (0, −1, +1, −2,
  +2, …) for the first in-mask pitch class, so ties go down. Custom mode builds its mask from
  Root and Scale Type with the interval table in `note_fx/scale.rs`. That table mirrors
  `MusicalScale.TYPES` (minus None), in the same order and with the same labels. A comment in
  each file points at the other.

## File-by-file change list

### Engine

| File | Change |
|---|---|
| `Engine/src/audio/midi_types.rs` | Id-range constants and `is_clip_note(id)` / `is_generated(id)` helpers. Doc on `NoteEvent` about generated ids |
| `Engine/src/audio/active_notes.rs` | `issue_id` takes the source: live ids in `[1, 2^29)`, clip ids in `[2^29, 2^30)`, two counters. Update `active_notes_ids_wrap_below_2_pow_31_and_skip_0` for the new limits |
| `Engine/src/audio/devices/mod.rs` | `DeviceCategory::NoteEffect`. The four `AudioDevice` methods above. `mod note_fx;` and re-exports |
| `Engine/src/audio/devices/container.rs` | `DeviceContainer::chain_children_mut` (default None) |
| `Engine/src/audio/devices/note_fx/mod.rs` (new) | `TimedNote`, `NoteBuffer` (fixed capacity), `NoteProcessor` trait, `NoteCx`, module docs |
| `Engine/src/audio/devices/note_fx/host.rs` (new) | `NoteFxHost<P>`: `AudioDevice` impl (audio pass-through, queue, host loop, sounding table, schedule, flags, `note_state` data stream) |
| `Engine/src/audio/devices/note_fx/ids.rs` (new) | `static NEXT_GENERATED: AtomicU32` and `next_generated_id(clip_origin: bool)` |
| `Engine/src/audio/devices/note_fx/routing.rs` (new) | `route_note(devices, event, frame)`: deliver in order, stop at the first note effect, mark activity, return the event if it fell off the end. `run_note_phase(devices, sample_count, sink: Option<&mut NoteBuffer>)`. `release_note_effects(devices)` |
| `Engine/src/audio/devices/note_fx/clock.rs` (new) | `StepClock` |
| `Engine/src/audio/devices/note_fx/scale.rs` (new) | Scale type table, `mask_for(root, type)`, `snap(key, mask)` |
| `Engine/src/audio/devices/note_fx/transpose.rs` (new) | Transpose processor + tests (REQ-004, 009, 014, 015) |
| `Engine/src/audio/devices/note_fx/note_filter.rs` (new) | Note Filter + tests (REQ-016) |
| `Engine/src/audio/devices/note_fx/velocity.rs` (new) | Velocity + tests (REQ-017) |
| `Engine/src/audio/devices/note_fx/chord.rs` (new) | Chord + tests (REQ-005, 018, 019) |
| `Engine/src/audio/devices/note_fx/arpeggiator.rs` (new) | Arpeggiator + tests (REQ-020 to 023) |
| `Engine/src/audio/devices/note_fx/chance.rs` (new) | Chance + tests (REQ-028) |
| `Engine/src/audio/devices/note_fx/step_sequencer.rs` (new) | Step Sequencer + tests (REQ-024 to 026) |
| `Engine/src/audio/devices/note_fx/note_echo.rs` (new) | Note Echo + tests (REQ-003, 027) |
| `Engine/src/audio/devices/note_fx/note_length.rs` (new) | Note Length + tests (REQ-029) |
| `Engine/src/audio/devices/note_fx/latch.rs` (new) | Latch + tests (REQ-012, 030) |
| `Engine/src/audio/devices/note_fx/container.rs` (new) | `NoteContainerDevice` (Note Layer, Note Selector) + tests (REQ-031, 032) |
| `Engine/src/audio/devices/note_fx/conformance.rs` (new, `#[cfg(test)]`) | Over `NOTE_EFFECT_IDS`, bare and `wrap_at_path`-wrapped: audio passes bit-exact, bypass passes notes (REQ-008), bypass/remove releases (REQ-006), stop releases clip notes only (REQ-007), unknown note-off passes, never sleeps, parameter round-trip, category is NoteEffect |
| `Engine/src/audio/devices/chain.rs` | `send_note_event` → `routing::route_note` over children (falling-off events go to the collected output when `collects_note_output`). `process_block` runs `run_note_phase` first (even when bypassed). `chain_children_mut`. Note-branch output buffer, flag and accessor. Tests: REQ-001, 002, 013 |
| `Engine/src/audio/devices/layer.rs` | No routing change (it sends to slot chains). Test for REQ-013: a note effect in one slot only |
| `Engine/src/audio/devices/factory.rs` | `NOTE_EFFECT_IDS`, `create_note_effect`, used in `create_builtin` and `builtin_device_infos`. `builtin_device_info` maps NoteEffect → `"note_effect"` |
| `Engine/src/audio/types.rs` | `send_note_event_to` → `routing::route_note`. `dispatch_notes(sample_count)` = `dispatch_scheduled_midi` + `run_note_phase`, called from `begin_device_chain` and `process_aux_source`. `aux_source_index()`. `stop_clip_notes()`. `ProjectSettings::scale_mask: u16` (default 0) |
| `Engine/src/audio/mixing.rs` | Use `aux_source_index() + 1` instead of the literal `1` for `start` (both sites) |
| `Engine/src/audio/transport.rs` | `Transport::scale_mask: u16`, filled in `Transport::at` from `settings` |
| `Engine/src/audio/modulation/host.rs` | Forward the four note-effect methods. Immediate (unqueued) `send_note_event` for a note-effect inner |
| `Engine/src/audio/commands.rs` | `AudioCommand::SetProjectScale(u16)` and its handler. Pause/Stop/Seek call `stop_clip_notes()`. `MoveDevice` and the `SetLayerSlotMute` note-container downcast |
| `Engine/src/audio/command_worker.rs` | `remove_device` calls `release_note_effects` on the parent list before `container::remove_device` |
| `Engine/src/osc/server.rs` | `["project", "scale"]` handler |

### Godot

| File | Change |
|---|---|
| `Godot/data/Device.gd` | `DeviceCategory.NoteEffect`. `get_category_string` → "Note Effect", `get_browser_group` → "Note Effects", `get_icon`. `is_note_effect()`. `container_focuses_one_child` includes `note_layer` and `note_selector`. `creates_instrument_track` true for note effects |
| `Godot/data/DeviceRegistry.gd` | `_category_from_string("note_effect")` |
| `Godot/data/NoteFx.gd` (new) | Static helpers: `CONTAINER_IDS`, `is_note_container(inst)`, `is_note_branch(inst)`, `is_inside_note_container(host)`, `leading_note_effect_count(devices)` |
| `Godot/devices/DeviceDropUtil.gd` | `device_fits_channel`: note effects only on INSTRUMENT non-master channels (REQ-035). `can_drop_instance_on_host`: no note effects in Multiband bands; only note effects (or branch chains) inside note containers (REQ-033). The same checks in the asset path (`can_drop_asset_on_channel`, `can_drop_on_container`) |
| `Godot/data/DeviceInstance.gd` | `sync_slot_to_engine` sends `slot/{i}/mute` for note-container branches. Model-level refusal in the add path (`DeviceAddCommand` callers go through `DeviceDropUtil`) |
| `Godot/data/MusicalScale.gd` | `mask() -> int` |
| `Godot/data/Project.gd` | `set_scale` sends `/project/scale`. Project sync sends it after `/project/init` |
| `Godot/devices/container/LayerSlotRow.gd` | `_refresh_out_enabled`: first device *after leading note effects* |
| `Godot/devices/device_lane/DevicePanel.gd` | Note-effect marker: a stripe on the header in `UiColors.role(&"accent_secondary")` (REQ-036) |
| `Godot/devices/simple_view/ParamRules.gd` (new) | Per device id, which parameters are disabled given other parameter values (REQ-037 rules) |
| `Godot/devices/simple_view/SimpleView.gd`, `SimpleControl.gd` | Apply `ParamRules` on bind and on every parameter change. `SimpleControl.set_disabled` |
| `Godot/devices/builtin/ArpeggiatorDefaultView.gd` / `.tscn` (new) | Controls for every Arpeggiator parameter (pattern of `CompressorDefaultView`) plus a held-notes strip that highlights the sounding key from `note_state` (REQ-037, 039) |
| `Godot/devices/builtin/StepSequencerDefaultView.gd` / `.tscn` (new) | Header controls plus a 16-column step grid (On / Pitch / Velocity / Chance) with drag-paint, Length dimming and the current-step highlight (REQ-038) |
| `Godot/devices/builtin/StepGrid.gd` (new) | The custom-drawn step-bar control used by the Step Sequencer view |
| `Godot/devices/builtin/NoteContainerDefaultView.gd` / `.tscn` (new) | Branch rows (name, mute, remove, add up to 8), Mode/Select for the Selector, last-branch highlight from `note_state` (REQ-040) |
| `Godot/devices/DeviceViewFactory.gd` | Register the three new panel scenes |

### Docs

| File | Change |
|---|---|
| `docs/adr/0019-note-effects-note-phase.md` (new) | Records: per-chain note phase, routing stops at note effects, the generated-id ranges, one block of modulation lag, loop wrap isn't a discontinuity |
| `docs/subsystems/osc-protocol.md` | `/project/scale`, `"note_effect"` category, the `note_state` stream, note-container slot mute |
| `docs/subsystems/engine-architecture.md` | The note phase in the callback flow |
| `docs/subsystems/godot-device-views.md` | `ParamRules`, the new views |
| `CONTEXT.md` | Note effect, Note container, Branch, Generated note. Fix the stale "MIDI goes only to the first device" |
| `AGENTS.md` | Built-in devices list: the note effects and `NOTE_EFFECT_IDS` / `note_fx/conformance.rs` |
| `docs/specs/026-scale-support/design.md` | A note that spec 027 sends the scale to the engine |
| `docs/specs/006-layer-note-mapping/design.md` | A note that the aux source skips leading note effects |

## Migration and compatibility

- `.sonara`: nothing new. Note effects are device instances like any built-in, and note-container
  branches are slot chains. Old projects contain none, so they load unchanged. The project scale
  is already saved by spec 026. It is now also sent to the engine on load.
- Note ids: the live/clip split halves each range (2^29 ids each before wrapping). The ids stay
  positive i32, so CLAP is unaffected.
- Godot device cache (`DeviceRegistry._device_to_cache_data`) stores the category by enum key.
  `NoteEffect` is new, and older caches have no such entries.
- DAWproject export treats note effects like other built-ins, which aren't transferred and are
  listed in the transfer report. No change.
- Version skew: an older engine doesn't know `/project/scale` and logs it as unknown. An older
  Godot ignores `"note_effect"` (it maps unknown categories to Effect).

## Test plan

- **Unit (engine):** `cargo test note_fx`, which covers:
  - `note_fx::routing::tests`: REQ-001/002 routing order, stop at note effect, fall-off sink.
  - `note_fx::host::tests`: REQ-003 future-dated events cross blocks at the right offset, REQ-004
    note-offs after a parameter change, REQ-005 distinct ids, REQ-006 bypass releases, REQ-007
    clip vs live discontinuity, REQ-009 range drop, overflow keeps note-offs, unsorted input
    sorted.
  - One `mod tests` per device file with the examples from REQ-014 to REQ-032, verbatim (e.g.
    `arpeggiator::tests::up_two_octaves_reverse`, `note_echo::tests::three_repeats_eighths_decay_half`).
  - `note_fx::conformance` over `NOTE_EFFECT_IDS`, bare and wrapped.
  - `chain::tests::note_effect_feeds_only_downstream` (REQ-001),
    `layer::tests::note_effect_in_one_slot_only` (REQ-013),
    `modulation::host::tests::velocity_modulator_sees_note_effect_output` (REQ-011),
    `types::tests::latch_keeps_instrument_awake` (REQ-012),
    `active_notes::tests::live_and_clip_ids_in_their_ranges`,
    `mixing::tests::aux_source_after_leading_note_effects`.
  - `note_fx::host::tests::idle_cost` measures 8 idle note effects on a 256-frame block against
    an empty chain (the CPU budget in the non-functional section), following the CPU harness
    pattern of spec 012.
- **Godot:** `Godot/tests/run_all.sh note_fx step_sequencer note_container scale_sync`:
  - `Godot/tests/test_note_fx_category.gd`: REQ-034, browser grouping from a fake
    `/builtin/info`.
  - `Godot/tests/test_note_fx_drop.gd`: REQ-033, REQ-035 (audio channel, bus, Multiband band,
    note container branch).
  - `Godot/tests/test_note_container.gd`: branches are slot chains, mute is sent, max 8, undo
    (REQ-042), save/load round-trip (REQ-043).
  - `Godot/tests/test_step_sequencer_view.gd`: drag-paint sets one step per column, Length
    dimming, the highlight from a fake `note_state` blob (REQ-038).
  - `Godot/tests/test_param_rules.gd`: the REQ-037 disable rules.
  - `Godot/tests/test_project_scale_sync.gd`: `set_scale` sends the right mask, and none for
    "none".
  - `Godot/tests/test_layer_mapping_window.gd`: extend REQ-007 with a leading note effect.
- **Live** (engine + Godot running): the REQ-010 virtual keyboard vs clip arpeggio, REQ-015
  following a project scale change, REQ-036 marker in both themes, REQ-039 arpeggio highlight,
  REQ-040 selector highlight, REQ-041 automating Semitones and a Step Sequencer preset
  round-trip. Plus a soak: Arpeggiator → Note Echo → Polysynth at 64-frame buffers for 5
  minutes, checking `last_warn.log` for xruns or overflow warnings.

## Risks

| Risk | Mitigation |
|---|---|
| Changing broadcast routing breaks existing setups (instrument + effect chains, Drum Machine, Layer) | With no note effect in a chain, `route_note` is the old broadcast loop. All existing chain/layer/drum tests must pass unchanged before any device lands (wave 1, first task) |
| Unsorted clip/live input causes out-of-order output | The host sorts input. A host test feeds deliberately unsorted events |
| Hanging notes through structural edits (move an instrument across an arpeggiator, remove a Note Layer) | `release_note_effects` before every remove and move, and a conformance check per device. The `release_note_effects` test moves an instrument across an arpeggiator |
| Generated ids collide with ActiveNotes ids | Disjoint ranges by construction, plus a unit test over wrap boundaries |
| Note effect parameter modulation lags one block | Documented in ADR-0019. Inaudible for note logic at typical buffer sizes |
| Grid drift on tempo ramps or loop wraps | `StepClock` uses `tempo_inc` within the block and resyncs to `song_pos_beats` every block. Test with a tempo ramp |
| `scale.rs` and `MusicalScale.TYPES` drift | Cross-reference comments, and `test_project_scale_sync.gd` checks the Transpose `Scale Type` enum labels from a captured `/builtin/info` against `MusicalScale.TYPES` |
| The spec is large | Delivered in the four waves from requirements.md. Each wave ends green and usable |

## Open questions

None.
