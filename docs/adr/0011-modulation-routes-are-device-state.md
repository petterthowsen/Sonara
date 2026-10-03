# 0011 — Modulation routes are device state; polyphonic sources are evaluated inside the device

Status: accepted; superseded in part by 0014 (the "device owns the sources" half). "Routes are
device state" and "the modulated value sits next to the base and is never written back" still
hold.

## Context

PolySynth v2 (spec 011) has per-voice modulation sources (envelopes, LFOs, velocity, key
tracking) that drive its own parameters, set up Bitwig-style: arm a source, drag a control. The
value that results differs per voice, so it cannot be a single number per parameter.

ADR-0010 resolves one value per parameter per buffer (`base_or_automation`) and mentions
modulation as a later term in that sum. That step lives in the host and knows nothing about
voices.

## Decision

- A **modulation route** (`source`, `param_id`, `amount`) is device state. It is not a hidden
  parameter, so it never appears in parameter lists, automation targets or CLAP parameter
  mapping. It crosses OSC as `{device}/mod/set` and `{device}/mod/clear`, is stored on
  `DeviceInstance.mod_routes`, and is saved with the device in the project.
- The device owns the sources and evaluates the routes itself, once per control block and per
  voice: `mod_norm = clamp(base_norm + Σ amount × source, 0, 1)`. The modulated value sits next
  to the base and is never written back to it or echoed.
- `AudioDevice` gets `mod_sources`, `set_mod_route`, `clear_mod_routes` and `mod_routes`, all
  defaulting to "no modulation". `/builtin/info` advertises the sources and the default patch.
- Godot follows the self-synchronising model pattern (ADR-0006): the UI calls
  `DeviceInstance.set_mod_amount()`, and the model sends OSC and emits `mod_route_changed`.
- Amounts are in normalized units (ADR-0005), so the same amount means the same fraction of the
  range whatever the parameter's curve.

## Consequences

- This is not the ADR-0010 host-level resolve step. That step still applies to the base value
  that a voice starts from: automation moves the base, and the device modulates around it.
- A later host-level modulator system (a track LFO driving any device or channel parameter)
  can reuse the `mod/*` message family and the UI. Its routes would be resolved in the host,
  so it needs its own evaluation path and probably a per-target route store.
- Routes don't fit DAWproject, so export keeps them in Sonara's own `State` JSON and lists them
  in the transfer report (`mod_routes`); other applications ignore them.
- Only devices that implement the trait methods have modulation. CLAP plugins keep their own
  (plugin-internal) modulation.

References: `docs/specs/011-polysynth-v2/plan.md`, `docs/subsystems/osc-protocol.md`
