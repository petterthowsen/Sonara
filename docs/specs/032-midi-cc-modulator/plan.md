# 032 — MIDI CC modulator

A new modulator kind, `cc` ("MIDI CC"), that reads the channel's MIDI controller
stream and applies like any other modulator (spec 018). Single-file plan:
requirements, design and tasks in one place, checkable.

## Problem

Modulators today are note- or clock-driven only (`lfo`, `adsr`, `ad`, `velocity`,
`keytrack`, `random`, `release` — `Engine/src/audio/modulation/kinds.rs`). There is
no way to map a MIDI controller to a *parameter offset* through the modulator
system. Spec 030 gave CC a first-class path as far as the device chain
(`Channel::send_cc_to_devices` → `route_cc` → `AudioDevice::send_cc`, with
automation lanes owning controllers via `Channel::cc_lane_mask`), but a
`ModulatedDevice` ignores it: `ModulatedDevice::send_cc` only forwards to the
inner device. A CC-driven modulator closes that gap with no new routing: the
wrapper already sits on the CC path.

## Scope

| | |
|---|---|
| Subsystem | Engine (modulation) + Godot (registry/pane, mostly free) |
| Touches real-time audio thread | yes — CC latch on `send_cc`, evaluation in the control-step pass |
| Adds or changes an OSC message | no new address; `/builtin/modulator_kind` gains the `cc` kind (auto, from `ModulatorKind::ALL`) |
| Changes a persisted format | yes, additively — saved modulator `kind: "cc"`; older engines reject it with a warning |

## Design

### Kind

- `ModulatorKind::MidiCc`, **appended last** in the enum (saved-project
  compatibility: `ModulatorKind::ALL` order and `index()` must not shift).
- Stable id `"cc"`, display name `"MIDI CC"`, **unipolar** (a 14-bit CC
  normalized to 0–1; bipolarity would waste half the range and no CC is signed).
- Own `ParamTable` (`MAX_KIND_PARAMS` stays 5 — the CC table has 2 params):
  - `CC_NUMBER` (slot 0): controller number, linear 0–119. 120–127 are
    channel-mode messages and stay excluded, matching spec 030 REQ-002.
  - `CC_SMOOTH` (slot 10): one-pole lag time, 0 (off) to 500 ms, skewed,
    default 0. Modulator values update per `CONTROL_STEP` (64 frames), so an
    unsmoothed CC lands in steps; the lag filters them without block-level ramps.
- `is_envelope()` → false; `is_note_driven()`-style classification: **not
  note-driven** (it must not consume the MIDI queue or retrigger per note).

### Evaluation (mono path, `state.rs` + `host.rs`)

- `ModulatorState` gains `cc_target: f32` (last normalized CC value for the
  configured controller) and `cc_value: f32` (smoothed output).
  - `advance(frames, transport)` for `MidiCc`: one-pole step from `cc_value`
    toward `cc_target` using `CC_SMOOTH` and the step duration; returns
    `cc_value`. Same in `value()`. No allocation, no transport read.
- `ModulatedDevice::send_cc(cc, value14, frame_offset)`: **before** forwarding
  to the inner device, latch into every `MidiCc` modulator whose `CC_NUMBER`
  matches: `cc_target = cc14_to_unit(value14)` and, if smoothing is off
  (`CC_SMOOTH == 0`), `cc_value = cc_target` so the change lands this step.
  The latch is O(8) fixed slots — audio-thread safe. If any modulator matched,
  also `mark_activity()` so a sleeping wrapped device wakes and the offset
  applies (CC routing otherwise wakes only note-accepting devices,
  `route_cc`).
- CC-latch timing: the latch happens when the CC arrives (sample-accurate in
  the block), but the modulator *value* is read at control-step boundaries, the
  same granularity every non-envelope modulator already has. Accept it; do not
  add per-frame CC ramps.

### Poly path (`voice.rs`, PolySynth)

CC is channel-level — the same value for every voice — so per-voice evaluation
buys nothing and would require plumbing CC into `RenderCtx`. Decision:

- `VoiceModSpec` **excludes `MidiCc` routes**: when `ModulatedDevice` builds the
  spec (`host.rs` ~367) it skips `MidiCc` modulator slots, so the inner
  PolySynth never sees them and does not double-apply.
- The wrapper evaluates `MidiCc` slots on the mono pass instead (its own
  `values[slot]` → `Own`/`Child` route offsets), even when `voice_mod` is true.
  This needs a small rule change where the wrapper currently hands all `Own`
  routes of a voice-modulating device to the spec: `Own` routes whose modulator
  is `MidiCc` stay mono-side. `Child` routes already are.
- `ModulatorKind::is_mono_only()` (true for `MidiCc`) documents the split.

### Persistence, advertisement, UI

- Saved modulators carry `kind: "cc"` (Godot `Modulator.gd`); params ride the
  existing modulator-param OSC path `device/{path}/mod/{mod_id}/param/{id}`
  — already generic, automatable, and a legal target of other modulators.
- Kind advertisement is generic: `osc/routes/modulation.rs` iterates
  `ModulatorKind::ALL` → `/builtin/modulator_kind` … `/builtin/modulator_complete`.
  Godot `DeviceRegistry._on_modulator_kind_received` and the Modulators pane
  (`ModulatorsPane.gd`, `+` menu, param detail) are kind-driven and need no
  new UI code — the CC panel renders from the advertised param table.
- Godot model: nothing to add; `Modulator.gd` stores kind as a string.
- Interaction with spec 030 automation lanes: a `channel/cc/{n}` lane owns the
  *controller* and suppresses live CC (`cc_lane_mask`), but lane values are
  still delivered through `send_cc_to_devices` → `send_cc`, so the modulator
  follows lane-driven CC identically. No change needed; document it.

## Non-functional

- **Real-time safety:** the CC latch and smoothing are fixed-capacity,
  allocation-free, no locks beyond the existing `try_lock` state lock. No I/O.
- **Compatibility:** appending the enum variant keeps old projects loading;
  new projects saved with a `cc` modulator load into an older engine as an
  unknown-kind warning at worst. `MAX_KIND_PARAMS` unchanged (5).

## Out of scope

- 14-bit CC *input* pairing (MSB/LSB) beyond what spec 030 already delivers.
- Per-voice CC, MPE, channel splitting, pitch-bend/aftertouch modulators.
- A CC learn UI (drag-to-assign on the CC number field) — numeric field only.

## Tasks

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

### Phase 1 — kind and state (engine)

- [x] **T-001** Add `ModulatorKind::MidiCc` (last), id `"cc"`, name `"MIDI CC"`,
  unipolar, `CC_NUMBER` (0–119) + `CC_SMOOTH` (0–500 ms, default 0) param table.
  - _Files_: `Engine/src/audio/modulation/kinds.rs`
  - _Output_: `from_id("cc")`, `table()`, `bipolar()`, `ALL`/`COUNT` consistent;
    `kind_ids_round_trip` passes unchanged.
  - _Verify_: `cargo test kind -- --nocapture`
  - _Depends on_: —

- [x] **T-002** Extend `ModulatorState`: `cc_target`/`cc_value`, latch method
  `set_cc(cc, unit_value)` (matching controller only), smoothing in
  `advance`, `value`, `reset`. Not note-driven: `note_on`/`note_off`/
  `update_note` ignore it; `is_note_driven` in `host.rs` returns false.
  - _Files_: `Engine/src/audio/modulation/state.rs`, `Engine/src/audio/modulation/host.rs`
  - _Output_: a `cc` modulator holds and smooths a latched CC value.
  - _Verify_: `cargo test modulation`
  - _Depends on_: T-001

### Phase 2 — CC plumbing into the wrapper (engine)

- [x] **T-003** `ModulatedDevice::send_cc` latches into matching `cc`
  modulators before forwarding to the inner device, and wakes the device
  (`mark_activity`) when one matched.
  - _Files_: `Engine/src/audio/modulation/host.rs`
  - _Output_: a CC on the channel reaches a modulator inside the wrapper; a
    wrapped sleeping device wakes on its controller.
  - _Verify_: `cargo test modulation` (new test: CC moves a Delay Mix route)
  - _Depends on_: T-002

- [x] **T-004** Poly split: `is_mono_only()`; `VoiceModSpec` build skips `cc`
  slots; wrapper evaluates `cc` `Own` routes on the mono pass even when
  `voice_mod`.
  - _Files_: `Engine/src/audio/modulation/{kinds,host,voice}.rs`,
    `Engine/src/audio/devices/instruments/polysynth/mod.rs` (only if its spec
    consumption asserts on unknown kinds)
  - _Output_: a `cc` modulator on PolySynth modulates without per-voice
    evaluation or double-apply.
  - _Verify_: `cargo test polysynth` + `cargo test modulation`
  - _Depends on_: T-003

### Phase 3 — Godot

- [x] **T-005** Confirm the generic path: registry parses the `cc` kind
  (`DeviceRegistry._on_modulator_kind_received`), the `+` menu lists "MIDI CC",
  the tile shows CC Number / Smooth controls, params save and reload.
  No new Godot code expected — if any kind list is hardcoded, fix it.
  - _Files_: `Godot/data/DeviceRegistry.gd` (only if needed),
    `Godot/tests/test_device_modulators.gd`, `Godot/tests/test_modulators_ui.gd`
  - _Output_: adding a MIDI CC modulator from the UI round-trips through JSON.
  - _Verify_: `Godot/tests/run_all.sh modulator`
  - _Depends on_: T-001 (kinds advertised), engine build running

### Phase 4 — docs

- [x] **T-006** Document the `cc` kind: modulator kinds list in
  `docs/subsystems/engine-architecture.md` (or wherever spec 018's kind list
  lives), the CC-latch rule and the `is_mono_only` poly exception, plus the
  spec-030 lane interaction note in `docs/subsystems/osc-protocol.md` if the
  modulator section names kinds.
  - _Files_: matching `docs/subsystems/*.md`
  - _Output_: the kinds table includes `cc` with its params and poly rule.
  - _Verify_: every kind named in the docs matches `ModulatorKind::ALL`
  - _Depends on_: T-004

### Phase 5 — live verification

- [ ] **T-007** Live check with the engine and Godot running: add a MIDI CC
  modulator on a Delay, route it to Mix; send
  `oscsend localhost 7000 /channel/2/cc 0 1 8192` (or a real MIDI knob) and
  hear/see Mix move; verify smoothing at CC_SMOOTH > 0; verify a
  `channel/cc/1` automation lane still drives it.
  - _Files_: —
  - _Output_: `STATUS.md` note of what was and wasn't checked.
  - _Verify_: manual listen + device panel meter movement
  - _Depends on_: T-006

## Open questions

- [ ] None blocking. (CC_SMOOTH upper bound 500 ms and step-rate granularity
      are judgement calls recorded above, not blockers.)