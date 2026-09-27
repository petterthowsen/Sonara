# 0010 — Automation is an override evaluated in the engine, never a write to the base value

Status: accepted

## Context

Automation lanes drive channel volume, pan, send amounts and device parameters during playback.
The obvious implementation, sending `SetDeviceParameter` from a timer or from Godot, mutates the
parameter's base value. That value is echoed back to Godot (`param/{id}/value`) and saved with
the project, so every playback would rewrite the user's settings. It also can't be
sample-accurate, since commands are applied between buffers by another thread.

## Decision

- Lanes are engine state owned by `Track` (`audio/automation.rs`), authored in Godot and sent as
  incremental point edits over `/track/{id}/automation/*`, like clip notes.
- The audio callback evaluates each lane every buffer, before the `is_playing` early return, so
  a seek while stopped applies too. Evaluation is cursor-based: it walks forward with the
  playhead and binary-searches only on a backward jump. It never allocates.
- The resolved value is an **override** next to the base, never a write to it. Channel volume
  and pan use `Channel::automation_volume` / `automation_pan`. For device parameters, the lane
  captures the pre-automation value when it takes over and restores it when it stops.
- The automation apply path calls `set_parameter_at` directly and sends **no status** to Godot,
  and it skips values equal to the last one applied.
- Values are normalized 0.0–1.0 (ADR-0005). Curves are `linear` and `step`, plus a `tension`
  warp stored per point.

## Consequences

- The project file never drifts from playing it, and bypassing a lane returns the target to its
  manual value.
- Device knobs don't animate during playback. That needs a separate "automated value" status
  that the UI renders but never saves.
- Resolution is one value per buffer for now. `set_parameter_at(…, frame_offset)` is the hook for
  sample-accurate automation later (CLAP events are already frame-stamped).
- Modulation can plug in at the same resolve step (`base_or_automation + Σ contributions`)
  without changing anything downstream.

References: `docs/specs/003-automation/design.md`, `docs/subsystems/osc-protocol.md`
