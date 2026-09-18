# 0006 — Godot data models are self-synchronizing; UI never sends OSC

Status: accepted

## Context

With OSC messages flowing both ways, it would be easy for the UI to mutate fields and send
OSC ad hoc — producing state drift between engine, model, and widgets.

## Decision

All engine-visible state lives in `Godot/data/` model classes (Project, Track, Channel,
Clip, DeviceInstance, …). One pattern for every change: UI calls the setter → the model
updates state, sends the OSC message, and emits a signal → UI refreshes from the signal.
UI code never mutates fields or sends OSC directly. Reconciliation on (re)connect goes
through the model's `sync_to_engine()`.

## Consequences

- Adding a synced property is a fixed recipe: field + signal + setter (OSC + emit) +
  wire into `sync_to_engine()` + UI connects in `bind_to_*()`.
- Widgets refresh from signals with `set_*_no_signal()` to avoid feedback loops.
- Undo/redo stays out of the setters: history is pushed by UI-level commands through
  `HistoryUtil`, so a setter stays "apply + OSC + signal".

References: `docs/subsystems/godot-architecture.md`, `docs/subsystems/godot-osc.md`
