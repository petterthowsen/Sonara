# Knob, Sidechain and XY modulators — Requirements

## Problem

The device modulator system (spec 018, panel in 033, CC in 032) covers
note-driven and controller sources only. Three gaps:

- There is no plain manual source: a fixed, automatable value with no DSP
  behind it, useful as a macro or remote-controlled offset.
- There is no audio-driven source: you cannot duck or dynamic-EQ a device
  from the signal of another channel (or of the device itself), because
  modulators never see audio.
- There is no 2D source: one grid position that drives two independent
  destinations costs two full modulator slots and two tiles today.

## Scope

| | |
|---|---|
| Subsystem | Engine (modulation, mixing tap) + Godot (pane, panel, display, model) |
| Touches real-time audio thread | yes — new kinds evaluate in the control-step pass; the sidechain filters and follower run per frame; the mixer snapshots tapped channels once per block |
| Adds or changes an OSC message | no new address; `/builtin/modulator_kind` advertises the four new kinds automatically (from `ModulatorKind::ALL`) |
| Changes a persisted format | yes, additively — new saved modulator `kind` values `"knob"`, `"xyx"`, `"xyy"`, `"sidechain"` |

## Requirements

### REQ-001 — Knob kind

The engine shall provide a modulator kind `knob` ("Knob") whose value is a
single user parameter, and every existing route/automation/mod→mod mechanism
shall apply to it unchanged.

- **Acceptance:** add a `knob` modulator via OSC; setting
  `modulator/{id}/param/0/value` moves its reported `kind 2` value; a route to
  a device parameter offsets it.
- **Example:** knob 0.25 (Unipolar) routed to a Delay Mix at amount 0.5 →
  Mix reads base + 0.125.

### REQ-002 — Knob polarity

WHEN the knob's Polarity parameter is switched from Unipolar to Bipolar,
THEN its routed value shall change from `x` (0…1) to `2x − 1` (−1…1) while the
stored Value parameter stays 0…1, and the Godot route-range display shall draw
that route as bipolar.

- **Acceptance:** same route as REQ-001 with the knob at 0.25 and Bipolar on →
  Mix reads base − 0.25 (value −0.5 × amount 0.5); the knob's mod arc is
  drawn centred on the base.

### REQ-003 — XY pad as one UI modulator

The `+` menu shall offer one "XY Pad" entry, and adding it shall produce a
single tile that behaves as one modulator (select, rename, duplicate, delete,
drag-reorder) while occupying two engine modulator slots (kinds `xyx` and
`xyy`, adjacent in the device's modulator array, `xyx` first).

- **Acceptance:** add from the menu → one tile; the device model holds two
  modulators at adjacent array indices; drag the tile past another tile → the
  pair stays adjacent; delete → both gone; save/load round-trips as a pair.
- **Example:** a device with 0 modulators → add XY Pad →
  `modulators.size() == 2`; with 7 modulators → add XY Pad is refused
  (warning, nothing added).

### REQ-004 — XY connect buttons

The XY Pad tile shall show two connect buttons, labeled "X" and "Y",
one per axis, each starting assign mode for its own slot's routes, styled per
REQ-010 with its own slot's colour.

- **Acceptance:** pressing X then dragging a knob of the same device creates a
  route from the `xyx` slot; the knob's arc shows the X colour; Y behaves
  identically for `xyy`.

### REQ-005 — XY pad control surfaces

The XY tile's in-place display shall be a compact interactive XY pad (drag sets
both axis positions), and its options panel shall show the same pad larger.
Dragging the pad shall not select or drag-reorder the tile.

- **Acceptance:** dragging the compact pad sends one
  `modulator/{id}/param/0/value` per slot; the big pad in the options panel
  follows and edits the same values.

### REQ-006 — Sidechain source

The engine shall provide a modulator kind `sidechain` ("Sidechain") whose
follower tracks either the audio arriving at its own device's input
("Device In") or the post-fader output of any channel in the project (master
included), selected by a parameter that stores the source **channel id** (so
the choice survives channel reorder and rename).

- **Acceptance:** a `sidechain` modulator on an EQ on channel A, source =
  channel B, signal on B only → the modulator's reported value rises with
  B's level and falls back to 0 with B silent.
- **Example:** kick on channel B ducks a bass band on A (classic ducking).

### REQ-007 — Sidechain filters

The sidechain signal shall pass a 12 dB/oct high-pass ("Low Cut") and a
12 dB/oct low-pass ("High Cut") before the follower; each is bypassed at its
range extreme (Low Cut at 20 Hz, High Cut at 20 kHz).

- **Acceptance:** with Low Cut at 500 Hz, a 50 Hz tone reads ≥ 20 dB lower
  than with Low Cut off; with High Cut at 500 Hz, a 5 kHz tone likewise; with
  both at their extremes the follower reads the same as the raw signal.

### REQ-008 — Dynamic EQ / ducking via routes

WHEN a `sidechain` modulator is routed to a device or child parameter, THEN the
parameter shall be offset by `amount × follower value`, on the same route and
mod→mod machinery as every other kind. The follower value is the detected
level mapped from −60…0 dBFS onto 0…1.

- **Acceptance:** sidechain (source channel B) → EQ band gain at amount −0.5:
  band gain dips while B plays.

### REQ-009 — Sidechain keeps running while the device is silent

A device carrying a `sidechain` modulator shall keep evaluating it while the
device's own input is silent. (Already true: a `ModulatedDevice` with any
modulator never reports sleeping — ADR-0014; this requirement pins it with a
test.)

- **Acceptance:** park the transport, leave B playing, wait > 3 s → the
  modulator's live value still tracks B.

### REQ-010 — Connect button styling

All modulator connect buttons shall be flat (`flat = true`) with both label
and icon colored by the modulator's source colour.

- **Acceptance:** theme overrides asserted in a test; the X/Y buttons carry
  their slot colours, plain modulator buttons their array-index colour.

### REQ-011 — Compatibility

Existing projects shall load unchanged; old engines shall reject the new kinds
with a warning, not an error; the `modulation` payload, route grammar and
kind advertisement stay backward compatible (new kinds ride the existing
generic paths).

- **Acceptance:** a project saved before this spec loads with identical
  modulators and routes; an old-engine + new-Godot session warns on
  `knob`/`xyx`/`xyy`/`sidechain` adds and keeps running.

## Non-functional

- **Real-time safety:** all new evaluation is allocation-free fixed-size DSP;
  the cross-channel tap buffers are preallocated by the command thread; no
  I/O, no locks beyond the existing `try_lock`.
- **Latency:** a cross-channel sidechain source is one audio block behind (the
  tap is snapshotted after the mix completes); a Device In source is
  current-block.
- **Compatibility:** `ModulatorKind` variants are appended (never reordered);
  `MAX_KIND_PARAMS` stays 5; `MAX_MODULATORS` stays 8.

## Out of scope

- Audio-rate (per-sample) modulation output — the follower value still lands
  at control-step boundaries.
- Pre-fader or pre-device sidechain tap points (post-fader only).
- Multiband detection.
- Multiple XY presets/snapshots ("morph" pads).
- Any change to the compressor's own sidechain path (spec 015).

## Open questions

- [ ] None blocking. Judgement calls are recorded as decisions D1–D8 in
      design.md.
