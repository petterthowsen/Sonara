# 0014 — Modulators are device-instance state; the engine evaluates them

Status: accepted. Supersedes in part 0011 — the half that says the device owns the sources and
evaluates the routes itself.

## Context

0011 gave PolySynth per-voice modulation sources that live inside the device: the device owns
Filter Env, LFO 1/2, Velocity and Keytrack, and resolves its own routes per voice. That works for
a synthesizer, but it makes modulation a property of *how a device is built*. Any other device —
an effect, a container, a CLAP plugin — would have to implement per-voice sources to be
modulatable at all, and a source could never drive a different device than the one that owns it.

Spec 018 makes modulation a property of a **device instance**: any device carries a small set of
**modulators** (LFO, envelope, velocity, keytrack, random), and each modulator can drive any
modulatable parameter of its own device, of a device nested inside it, or (later) of another
modulator. Devices advertise **default modulators** rather than owning sources.

The engine has no stable device IDs — everything is addressed by `DevicePath` — and devices move
within a chain on reorder and drag.

## Decision

- **A modulator belongs to a device instance**, not to the device type. It has a `mod_id` (unique
  within the device), a `kind`, its kind's parameters, and a list of routes. The device only
  supplies *default modulators* that a new instance starts with (PolySynth's Filter Env → Cutoff,
  LFO 1, LFO 2). Modulators are saved with the instance in projects and presets, and are edited
  per instance.

- **Evaluation is mono in the host and poly only inside a poly-capable device.** The engine
  evaluates a device's modulators once per control step and applies
  `effective = clamp(base_or_automation + Σ amount × source, 0, 1)` as a **modulation offset**
  next to the base value; the base value is never written back and the modulated value is never
  echoed or saved (0010, 0011). A device that reports `supports_voice_modulation()` additionally
  receives the modulator definitions and the routes into its own parameters, and runs one
  instance of each note-driven modulator per voice from the shared DSP in `audio/modulation/`
  (`mod_norm = clamp(effective + Σ poly, 0, 1)`). PolySynth is the only such device in v1.
  Note-driven modulators on the mono path follow the device's note stream: an envelope
  retriggers per note-on and releases on the last note-off; velocity and keytrack take the last
  note.

- **A transparent `ModulatedDevice` wrapper holds the modulators**, not the device. It is
  inserted when a device gets its first modulator and removed when it loses the last one, so a
  device with no modulators costs nothing. It forwards every trait method, and `as_any_mut` and
  `as_container(_mut)` return the inner device's so the existing downcasts keep working. This was
  chosen over storing modulators on each device because there are no stable IDs to key routes by,
  and the wrapper **moves with the device** on reorder and drag, so routes never need re-keying.

- **Modulation offsets sit next to the base values.** `ParamValues` gains an `offset` array;
  `get()` still returns the base, and `set()` returns the real value of `clamp(norm + offset)`.

- **MIDI reaches every device in the chain**, not just the first, so live and held notes behave
  like scheduled notes already do and note-driven modulators work on any device. Audio effects
  ignore notes by the trait default. Only devices with MIDI ports, or with note-driven
  modulators, are woken by a note, so a sleeping reverb stays asleep.

## Consequences

- The `mod_sources` / `set_mod_route` / `clear_mod_routes` / `mod_routes` trait methods from 0011
  and the `{device}/mod/*` OSC family are replaced by modulators (`{device}/modulator/*`).
- Modulator parameters are real parameters: automatable as
  `device/{path}/mod/{mod_id}/param/{id}`, and (later) targets of other modulators.
- Routes are relative paths within the owning device, so they survive the device moving and are
  rewritten only when a *descendant* moves or is removed.
- Only ADR-0010's host resolve step still applies to the base value a voice starts from:
  automation moves the base, the engine modulates around it.
- CLAP targets use `CLAP_PARAM_IS_MODULATABLE` and non-destructive `PARAM_MOD` offsets; there is
  no destructive fallback.

References: `docs/specs/018-device-modulators/plan.md`,
`docs/adr/0011-modulation-routes-are-device-state.md`, `docs/subsystems/osc-protocol.md`
