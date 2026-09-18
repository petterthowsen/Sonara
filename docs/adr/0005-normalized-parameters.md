# 0005 — Parameters cross boundaries normalized 0.0–1.0

Status: accepted

## Context

Device parameters are set from three worlds: Godot UI widgets, the OSC wire, and CLAP
plugin IPC. Each has its own natural range and scale (dB, Hz, log curves, enum indices).

## Decision

On the wire — both OSC (engine ↔ Godot) and plugin IPC — parameter values are normalized
to 0.0–1.0. Real min/max, logarithmic flags, and enum labels travel as metadata
(`ParamInfo`, `/builtin/info` parameter descriptors) and conversion happens at the edges:
`parameter.rs` (engine side), `DeviceParameter` (Godot side).

## Consequences

- New parameters need no protocol changes; only metadata updates.
- UI code must never assume the OSC value is the display value — always denormalize via
  the descriptor. One known gap: `is_logarithmic` is still guessed from parameter names on
  the Godot side until the engine advertises it.

References: `docs/subsystems/engine-plugin-architecture.md`, `docs/subsystems/godot-device-views.md`
