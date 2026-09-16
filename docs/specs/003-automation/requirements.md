# Parameter Automation — Requirements

## Problem

Sonara has no automation or modulation. A channel's volume, pan and send levels and a device's
parameters can only be set to a single static value, so nothing can change over the course of a
song without a user moving a control by hand while the transport runs. `TODO.md` carries this as
"Modulation" (line 176) and it is the largest remaining gap in the arranger.

Two half-built stubs exist and mislead: `Godot/data/AutomationLane.gd` and
`Godot/data/AutomationPoint.gd` are serialized by `Track.to_json()` but never read back
(`Track.from_json()` carries a `# TODO: Load automation when AutomationLane exists`), and the
engine has no concept of automation at all — `is_automation_safe` on `ParamInfo` is reported to
the UI and then ignored.

This spec covers phase 1: **timeline automation of parameters, authored per track, evaluated in
the engine.** It deliberately establishes the target-addressing and value-resolution model that
Bitwig-style modulate-everything will later plug into, without building any modulator.

## Scope

| | |
|---|---|
| Subsystem | both (Engine + Godot) |
| Touches real-time audio thread | **yes** — lanes are evaluated on the audio callback; design must respect the audio-thread contract |
| Adds or changes an OSC message | **yes** — a new `/automation/*` group; protocol docs are part of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | **yes** — `.sonara` gains real `automation_lanes` content per track; plus new UI settings keys |

## Definitions

- **Lane** — an ordered set of points targeting exactly one parameter, owned by one track.
- **Target** — the parameter a lane drives, addressed as a channel plus either a built-in channel
  parameter or a device path and parameter id.
- **Base value** — the value the user set by hand on the control; what a knob shows with no
  automation and what persists in the project.
- **Resolved value** — what the device or mixer actually uses for a given sample position:
  `base`, overridden by the lane's value where an enabled lane exists.
- **Segment** — the points of one lane within a tick range, the unit of cut/copy/paste.

## Requirements

### REQ-001 — Lanes are owned by tracks

The project shall store automation lanes on the track, not on clips or clip instances.

- **Acceptance:** `Godot/tests/` test creates a track, adds two lanes, saves and reloads the
  project, and finds both lanes on that track with their points intact.
- **Example:** a project with one track carrying a volume lane and a filter-cutoff lane
  round-trips through `Project.to_json()` / `from_json()` with 2 lanes and every point's tick,
  value and curve preserved.

### REQ-002 — A lane targets one parameter of a track-linked channel

A lane shall target exactly one of: the linked channel's volume, its pan, one of its send
amounts, or one parameter of one device in its chain (including nested container children).
A device parameter here means any parameter the device exposes, whether it belongs to the
device's own parameter group or its MIDI CC group.

- **Acceptance:** `cargo test` unit test resolves each of the four target kinds to the correct
  live value on a constructed `EngineState`.
- **Example:** a lane targeting channel 4's `Delay` device (device path `0`) parameter 2 moves
  that parameter and nothing else.

### REQ-003 — Automation overrides the base value while a lane is enabled

WHILE an enabled lane covers the current playback position, the audio callback shall use the
lane's value for that parameter in place of the base value.

- **Acceptance:** `cargo test` — evaluate a two-point volume ramp at three positions and assert
  the resolved gain differs from `volume_db`'s base and matches the interpolated curve.
- **Example:** channel volume base is `0.0 dB`; a lane ramps 0.0→1.0 normalized across bars 1–2;
  at bar 1.5 the resolved gain is the midpoint value, not `0.0 dB`.

### REQ-004 — The base value is preserved, not overwritten

The engine shall leave a parameter's base value unchanged while automation drives it, and shall
restore the base value when the lane is bypassed or deleted.

- **Acceptance:** `cargo test` — automate a parameter, bypass the lane, assert the parameter
  reads back its original base value.
- **Example:** a filter cutoff base of 0.3 automated up to 0.9 still reports 0.3 in the project
  file and returns to 0.3 audibly when the lane is bypassed.

### REQ-005 — Values are interpolated between points

The engine and the arranger shall compute the same value between two points, honouring the
point's curve shape: linear, step (hold until the next point), and a single-parameter tension
curve that bends the ramp toward ease-in or ease-out.

- **Acceptance:** `cargo test` asserts engine values at 5 positions across each of the three
  curve shapes; a Godot test asserts the GDScript evaluator agrees with the same expected
  values to within 0.001.
- **Example:** two points (tick 0 → 0.0, tick 960 → 1.0) with tension `+0.5` evaluate to less
  than 0.5 at tick 480; with tension `0.0` they evaluate to exactly 0.5.

### REQ-006 — Before the first and after the last point the value is held

The engine shall hold the first point's value for any position before it, and the last point's
value for any position after it.

- **Acceptance:** `cargo test` — a lane whose first point is at tick 1920 resolves to that
  point's value at tick 0.

### REQ-007 — A lane with no points does not drive its parameter

IF an enabled lane has no points, THEN the engine shall leave the parameter at its base value.

- **Acceptance:** `cargo test` — an empty lane leaves `volume_db` untouched.

### REQ-008 — Automation applies when seeking while stopped

WHEN the playhead moves while the transport is stopped, the engine shall resolve every enabled
lane at the new position and apply it.

- **Acceptance:** live — with the transport stopped, send `/transport/seek` to a tick where a
  volume lane sits at a low value, then play a note and hear the automated level; the engine log
  records the resolved value.
- **Example:** seeking to bar 5 where a cutoff lane reads 0.8 leaves the device at 0.8, so
  pressing play produces no audible jump.

### REQ-009 — A lane can be bypassed without being deleted

WHERE a lane is bypassed, the engine shall stop applying it and the arranger shall render it
visually muted while keeping every point.

- **Acceptance:** Godot test toggles bypass and asserts the point count is unchanged and the
  bypass state round-trips through JSON; `cargo test` asserts a bypassed lane leaves the base
  value in place.

### REQ-010 — Automation is real-time safe

The audio callback shall evaluate lanes without allocating, blocking, locking beyond the existing
bounded `try_lock`, or performing I/O, and shall not scan a lane's full point list per buffer.

- **Acceptance:** code review against the audio-thread contract in `AGENTS.md`, plus a
  `cargo test` that asserts evaluation of a 10,000-point lane advancing sample-by-sample across
  the whole lane touches each point a bounded number of times.
- **Non-negotiable:** a lane evaluation that allocates fails this requirement outright.

### REQ-011 — Automating a plugin parameter does not flood the IPC ring

The engine shall not send a parameter update across the plugin IPC boundary when the resolved
value has not meaningfully changed since the last update.

- **Acceptance:** `cargo test` — feed a constant-valued lane for 100 buffers and assert one
  update is emitted, not 100.
- **Example:** a step-curve lane holding 0.5 for four bars produces one IPC message at the step,
  not one per buffer.

### REQ-012 — Lane edits reach the engine incrementally

WHEN the user adds, moves, or deletes a single point, the arranger shall send only that change to
the engine, matching the granularity of the existing per-note clip messages.

- **Acceptance:** live — drag one point and observe a single point-update message in the engine
  log, not a whole-lane replacement.

### REQ-013 — Lanes appear as rows beneath their track

The arranger shall render each visible lane as its own row directly below the track's clip lane,
vertically aligned between the track list and the timeline, resizable with the same gesture as a
track.

- **Acceptance:** live — show two lanes on a track, resize one, and confirm its header and its
  timeline row stay the same height and stay aligned while scrolling.

### REQ-014 — A track header discloses its lanes

The track header shall provide a control that shows and hides that track's existing lanes, and a
menu listing every lane with a per-lane visibility checkbox plus an entry that creates a new lane.

- **Acceptance:** live — toggle disclosure and confirm rows appear and disappear; open the menu,
  uncheck a lane, and confirm only that lane's row is hidden while its points are kept.

### REQ-015 — New lanes are chosen from the linked channel's parameters

WHEN the user adds a lane, the arranger shall offer the automatable parameters of the track's
linked channel — its built-in channel parameters, and for each device in chain order (nearest the
chain input first) both its device parameters and its MIDI CC parameters — and shall exclude
parameters already carrying a lane on that track.

- **Acceptance:** live — a track whose channel has two devices offers both devices' parameters
  grouped and ordered by device position, with each device's CC parameters presented as a
  distinct group from its device parameters; a parameter that already has a lane is absent.
- **Example:** with `polysynth` at position 0 and `delay` at position 1, the polysynth's
  parameters are listed first. An SFZ device offers `Cutoff` under its device parameters and
  `CC1 Mod Wheel` under its CC parameters.

### REQ-016 — MIDI CC parameters are named from a shared lookup

The UI shall resolve a display name for any MIDI CC number from a single shared lookup covering
the standard controller assignments, and shall prefer a device-supplied name when the device
provides one.

- **Acceptance:** Godot test asserts the lookup returns the standard name for a sample of CC
  numbers (1, 7, 10, 11, 64, 74), returns a stable fallback for an unassigned number, and never
  returns an empty string for any number 0–127.
- **Example:** CC74 resolves to its standard brightness/cutoff name; CC3, which has no standard
  assignment, resolves to a generic `CC3` rather than blank.
- **Note:** this lookup serves the lane picker and lane headers here, and is the same lookup a
  later CC-learn or CC-lane feature will use.

### REQ-017 — A lane header identifies its target and offers bypass and delete

Each lane header shall show the target as device and parameter name, and provide a bypass control
and a delete control that removes the entire lane.

- **Acceptance:** live — a lane on a delay's mix parameter reads as the device name followed by
  the parameter name; bypass mutes it; delete removes the row and the data.
- **Example:** a lane on the `Filter` device's `Freq` parameter reads `Filter / Freq`; a lane on
  an SFZ device's CC1 reads `Piano / CC1 Mod Wheel`, named through REQ-016.

### REQ-018 — Points are created, moved and deleted by direct manipulation

The arranger shall insert a point on double-click in a lane row, move a point by click-and-drag,
and delete the points under the current selection on a delete action, snapping horizontal
movement with the shared grid.

- **Acceptance:** live — double-click inserts at the snapped tick and the value under the cursor;
  dragging repositions in both axes; delete removes the selection.

### REQ-019 — A point's curve shape can be changed

The arranger shall let the user set a selected point's curve shape to linear or step.

- **Acceptance:** live — set a point to step, confirm the drawn curve holds flat until the next
  point and the engine holds the value audibly; set it back to linear and the ramp returns.
- **Note:** this is the minimal affordance that keeps REQ-005's step shape reachable now that the
  mid-segment tension handle is deferred. Tension stays in the format and in both evaluators but
  no phase-1 control writes it, so every stored point has tension `0.0`.

### REQ-020 — Multi-select uses the same modifiers as clips

The arranger shall extend a point selection on ctrl-click and support a box-select gesture within
a lane row, mirroring the clip selection modifiers.

- **Acceptance:** live — ctrl-click three points and drag them together as one group; box-select
  a span and confirm only points inside it are selected.

### REQ-021 — Points support range-aware cut, copy, paste and duplicate

The arranger shall cut, copy, paste and duplicate point segments using the same conventions as
clips: the active time range when one exists, otherwise the selection, pasted at the last-clicked
position.

- **Acceptance:** Godot test builds a lane, copies a 1-bar segment, pastes at bar 3 and asserts
  the points exist at the shifted ticks with their curves intact; live check that the range and
  anchor behaviour matches clip paste.
- **Example:** a range covering bars 1–2 copied and pasted at bar 5 reproduces every point from
  that span offset by 4 bars.

### REQ-022 — Every lane edit is undoable

The arranger shall route lane and point edits through the command history so each is undone and
redone as one step, with a multi-point gesture undone as a single step.

- **Acceptance:** Godot test executes a point-move command, undoes it and asserts the original
  ticks and values return; live — drag five selected points, press undo once, and all five
  return.

### REQ-023 — Lanes survive a project round-trip

The project shall persist every lane's target, points, curves, bypass state, visibility and row
height, and shall load a project written before this feature without error.

- **Acceptance:** Godot test round-trips a project with lanes and asserts equality; opening a
  pre-existing `.sonara` from before this change loads with zero lanes and no error in
  `Godot/logs/last.log`.

### REQ-024 — An unresolvable target is preserved and reported

IF a lane's target cannot be resolved — the track's channel changed, or the device was
removed — THEN the arranger shall keep the lane, mark it unresolved, stop sending it to the
engine, and the engine shall apply nothing for it.

- **Acceptance:** live — delete a device that has a lane, confirm the lane row remains marked
  unresolved, the parameter returns to its base value, and no error spams `Engine/logs/`.

## Non-functional

- **Real-time safety:** lane evaluation runs on the audio callback under the existing bounded
  `try_lock`; all storage it touches is preallocated. It allocates nothing, and adding automation
  must not introduce a new lock on the callback.
- **Latency / performance:** parameter resolution is per-buffer in phase 1 (not per-sample), and
  the interface for finer granularity must exist so it can be tightened later without touching
  every device. Channel volume and pan keep their existing per-sample smoothing.
- **Compatibility:** projects saved before this change load with no lanes. The engine must
  tolerate a Godot build that never sends `/automation/*`, and lanes for an unknown target are
  ignored rather than fatal.
- **Parity:** the GDScript and Rust evaluators must agree, since the UI draws one and the ear
  hears the other.

## Out of scope

- **The mid-segment tension handle.** Hovering between two points to bend the ramp by dragging is
  deferred; `tension` stays in the persisted format and in both evaluators so phase 2 adds the
  gesture without a format change, but no phase-1 control writes it. REQ-019 is the minimal
  replacement that keeps the step shape reachable.
- **The freehand draw tool.** Placing a run of points by dragging across a lane is deferred;
  points are placed one at a time per REQ-018.
- Automation recording from control gestures (touch / latch / write modes) and the override
  behaviour when a user grabs an automated control during playback.
- Modulators, macro knobs, LFOs, envelope followers and any additive modulation contribution —
  phase 1 establishes the resolution model but implements only the automation contribution.
- Clip-level or clip-instance-level automation.
- The "automation follows clips" toggle: moving or copying a clip instance does not move lane
  points in phase 1.
- Automation of buses and the master channel, and of any channel no track routes to.
- Tempo, time-signature and transport automation.
- Per-sample accuracy for third-party CLAP plugin parameters.
- MIDI CC learn and external-controller mapping, even though they will share the target address
  and the CC name lookup from REQ-016.
- Widening the set of MIDI CCs that devices expose as parameters. A lane can target any CC a
  device already exposes, but today only `sfizz_device` exposes any, and only the five in its
  `STANDARD_CC_CONTROLS` list minus whatever the loaded SFZ labels itself — which is why a
  typical SFZ shows just Mod Wheel and Sustain on the C tab. Growing that list, and giving
  `polysynth` and CLAP devices CC parameters at all, is a device-side change tracked separately;
  REQ-016's lookup is what makes it cheap.

## Open questions

None — the three blocking forks (bus/master scope, seek-while-stopped behaviour, and whether
"follows clips" ships in phase 1) were resolved before this document was written and are recorded
in Out of scope and REQ-008.
