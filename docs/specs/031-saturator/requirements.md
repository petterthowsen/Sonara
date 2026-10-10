# Saturator — Requirements

Requirements for a built-in saturation / distortion effect device. Written against the repo's
`docs/specs/_templates/requirements.md`. No file names or technology choices here; those belong in
`design.md`.

Context: spec `016-multiband-fx` already names **Saturator** as one of the devices users are expected
to place in a Multiband FX slot chain, and `docs/daw-device-research.md` (§4) sets the expectations
for the category. Today no such device exists — drive exists only inside the drum instruments and
inside the Filter's drive stage, so it cannot be placed on a channel, in a slot chain, or in a band.

## Problem

A user cannot add distortion or saturation to a channel, a slot chain or a Multiband FX band. The
only shaping available is baked into individual instruments and the Filter, each with a fixed curve,
so there is no way to get a musical, level-dependent drive, no way to choose a character (tape,
tube, diode), and no way to control the aliasing that any digital nonlinearity produces. The research
document is explicit that level-dependent behaviour, perceptual shaping and a user-visible
oversampling control are what separate a usable saturation device from a static "painted on"
waveshaper.

## Scope

| | |
|---|---|
| Subsystem | Engine + Godot + docs (a new built-in effect device with a custom view) |
| Touches real-time audio thread | yes — the device processes audio on the callback; design must respect the audio-thread contract |
| Adds or changes an OSC message | yes — the device's parameters cross the existing normalized parameter path; no new *message type* is expected, but the built-in device list (`/builtin/request` → `/builtin/info` → `/builtin/complete`) gains an entry, and the protocol doc is part of the definition of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no — the device is additive; existing projects are unaffected, and the device's parameters persist through the existing device-parameter mechanism |

## Requirements

### REQ-001 — A built-in saturation device exists and is discoverable

The engine shall expose a built-in effect device named **Saturator** in the built-in device list,
so that Godot discovers it at runtime without a hardcoded list on the Godot side.

- **Acceptance:** an `effect_conformance`-style check finds the device in the built-in registry, and
  a live `/builtin/request` → `/builtin/info` → `/builtin/complete` round trip reports it with its
  parameter list.
- **Example:** engine started, Godot requests built-ins → response contains the Saturator id and its
  parameter count.

### REQ-002 — Insertable anywhere a device can go

The device shall be insertable in a channel's device chain, inside a slot chain, and inside a
Multiband FX band, and shall process stereo audio in all three positions.

- **Acceptance:** a live check in each of the three positions produces the audible/measurable
  distortion; the Multiband FX case shows no artefacts beyond the container's documented phase
  behaviour.
- **Example:** Saturator between an instrument and the channel output → with drive raised the signal
  becomes audibly denser; same device inside band 2 of a Multiband FX → only that band distorts.

### REQ-003 — A type selector with recognisably different characters

The device shall offer a **type** selector whose settings produce measurably different harmonic
spectra from the same input, at minimum:

1. a symmetric soft-clip character (odd-harmonic dominant),
2. an asymmetric character that produces even harmonics as well,
3. a tape-emulating character (see REQ-005),
4. a hard-clipping character with a sharper corner than the soft-clip type.

- **Acceptance:** for a fixed 1 kHz sine at a fixed level, the measured ratio between even and odd
  harmonics differs between type 1 and type 2; total harmonic content is higher for type 4 than
  type 1 at the same drive.
- **Example:** 1 kHz sine, drive raised until THD ≈ 10 % → type 1 shows only odd harmonics above the
  noise floor, type 2 shows a 2nd harmonic within ~20 dB of the 3rd.

### REQ-004 — Harmonics grow with input level

WHILE the input level rises, the device shall add progressively more harmonic content (the
character must be level-dependent rather than a fixed transfer curve), and the amount of that
level dependence shall itself be controllable from none to pronounced.

- **Acceptance:** the same signal at the same drive setting, at −18 dBFS and at −6 dBFS, produces
  measurably different THD; with level dependence at its minimum the two measurements converge.
- **Example:** a drum loop at two input gains → harmonic content rises with input; turning level
  dependence down makes the two results match.

### REQ-005 — Tape character has the behaviours that make tape recognisable

WHEN the type is the tape character, the device shall additionally provide: high-frequency loss that
increases with signal level, a low-frequency emphasis (head bump), and a program-dependent
compression of peaks.

- **Acceptance:** with the tape type selected and drive fixed, the measured high-frequency energy of
  a sine sweep falls as input level rises; the low-frequency region shows the bump; peak levels are
  reduced more than RMS levels.
- **Example:** 1 kHz at −6 dBFS vs −18 dBFS through the tape type → the louder one has less relative
  HF content and a lower peak-to-RMS ratio than the soft-clip type produces.

### REQ-006 — Modulation and noise are opt-in and off by default

WHERE the tape character is selected, the device shall offer wow-and-flutter modulation and shall
add no noise whatsoever unless the user explicitly enables it.

- **Acceptance:** with modulation disabled the output is bit-identical across identical runs with
  the same input; with noise disabled, rendering silence through the device produces digital silence
  (no added noise floor).
- **Example:** two renders of the same input → identical samples; silence in → silence out.

### REQ-007 — User-visible oversampling with no reported latency

The device shall let the user choose the oversampling factor for the nonlinear stage (at least
1×, 2× and 4×), and changing it shall not increase the latency the device reports to the host.

- **Acceptance:** the device reports zero added latency at every oversampling setting, consistent
  with spec 012 decision 2; switching the factor while audio runs produces no click and no dropout.
- **Example:** a 7 kHz sine driven hard → with 4× selected, non-harmonic (alias) content measures
  lower than at 1× at matched output level.

### REQ-008 — Clean path, and Mix is bit-exact at zero

The device shall have a Mix control whose 0 % setting outputs the input bit-exactly, and the
transition from dry to wet shall be free of clicks.

- **Acceptance:** a null test — input minus output at Mix 0 % is digital silence for any drive
  setting; automating Mix produces no clicks.
- **Example:** drive at maximum, Mix at 0 % → subtracted output is all zeros.

### REQ-009 — Output level is manageable independently of drive

Raising drive shall not be the only way to change loudness: the device shall provide output level
control and an automatic level compensation that can be switched off.

- **Acceptance:** sweeping drive from minimum to maximum with compensation on changes perceived
  loudness far less than with compensation off; the output control attenuates/boosts by its face
  value (measured at mix 100 %).
- **Example:** drive 0 → 24 dB with compensation on → output RMS within a few dB of the input RMS.

### REQ-010 — Tone shaping before and after the nonlinearity

The device shall provide tone controls on both sides of the nonlinear stage: a high-pass before it
and a low-pass plus a tilt after it, so the 2–5 kHz region the research document calls out as
perceptually harshest can be reduced without removing the distortion.

- **Acceptance:** each control measurably changes the intended region of the output spectrum at a
  fixed drive setting; the post controls reach far enough to reduce 2–5 kHz energy by at least 6 dB
  while THD stays within 1 dB of its unshaped value.
- **Example:** bright distorted content → with post tilt down, the 2–5 kHz band drops while the
  harmonic count is unchanged.

### REQ-011 — The device is playable and automated like every other device

Every continuous parameter shall be automatable and smoothed; parameters shall cross the OSC
boundary as normalized 0.0–1.0 values; changing the type shall not click.

- **Acceptance:** automation recorded on Drive plays back without zipper noise; a type change
  crosfades rather than stepping; normalized values round-trip through the existing parameter path.
- **Example:** an automation lane sweeping Drive 0 → 100 % over two bars → no stepping artefacts.

### REQ-012 — Visual feedback matches the DSP

The device's custom view shall display the transfer curve the DSP is actually applying, and a live
harmonic display of the current output, so the user can see odd/even balance and the effect of each
control.

- **Acceptance:** the drawn curve matches the shaper's real response — a test that sweeps the input
  range through the DSP and compares it to the curve the view would draw passes within tolerance
  (the pattern the EQ already uses to draw its response from the filter's own coefficients).
- **Example:** bias raised → the curve visibly becomes asymmetric and the harmonic display shows a
  2nd harmonic appear.

### REQ-013 — Real-time safety and hostile-input tolerance

The device shall not allocate, block, do I/O, or wait on a lock on the audio callback; it shall be
denormal-safe; and IF the input contains non-finite samples, THEN the device shall not propagate
them or produce non-finite output.

- **Acceptance:** an allocation/blocking check over the process function; a denormal test with a
  decaying tail; a NaN/Inf injection test that asserts the output stays finite and bounded.
- **Example:** feed 1000 silent frames of ±Inf → output is finite, no exception, no runaway.

### REQ-014 — Sleeps and wakes like the other devices

WHEN the device has had no input above silence and no parameter change for the standard idle period,
the engine shall put it to sleep (spec 008) and wake it on the next signal without an audible click
or lost samples.

- **Acceptance:** the device's sleep state follows the shared rule; a wake immediately after a long
  silent stretch produces a correctly shaped first hit.
- **Example:** silence for 10 s, then a drum hit → the hit is intact, no click at the transition.

### REQ-015 — CPU inside the effect budget

The device shall run within the same CPU budget as the existing built-in effects, measured the same
way, including at 4× oversampling.

- **Acceptance:** measured engine load with one instance, dry and driven, at 1× and 4×, compared
  against the Filter's drive stage measured identically, with no dropouts.
- **Example:** one instance at 4× on a busy project → load stays within budget, no xruns over a
  one-minute run.

### REQ-016 — Presets and persistence

WHEN a project containing the device is saved and reopened, every parameter shall come back with the
same value, and the device shall ship with a small set of factory presets that demonstrate each type.

- **Acceptance:** save → reopen → parameter values identical (the existing device-parameter
  round trip); factory presets load and audibly demonstrate their named character.
- **Example:** set Tape + drive 12 dB, save, reopen → still Tape + 12 dB.

## Non-functional

- **Real-time safety:** nothing on the callback allocates, blocks, does I/O or waits on a lock; the
  oversampling buffers are preallocated for the maximum supported factor; denormals are flushed.
- **Latency / performance:** the device adds no latency that must be reported (spec 012 decision 2);
  its CPU cost must not push a typical project over budget at 4× oversampling.
- **Compatibility:** additive — older projects are unaffected; a project saved with the device does
  not load in an engine that predates it (documented, not migrated).
- **Consistency:** the Mix convention (0 % = bit-exact dry), the smoothed-parameter rule and the
  5–10 ms enum crossfade follow the suite conventions from spec 012.

## Out of scope

- A separate per-band saturation device — per-band use comes from placing this device in a Multiband
  FX slot (spec 016).
- External sidechain or any envelope source other than the device's own input.
- Component-level circuit modelling (valve curves fitted from measurements, tape hysteresis models
  such as Jiles-Atherton).
- Extreme oversampling factors (8×, 16×) — the 2×/4× structure is the shipped range.
- A CLAP/VST3 wrapper of the device, and any host-plugin packaging.
- Bit-crushing / sample-rate reduction (a different device if it is ever wanted).

## Open questions

Resolved at the requirements gate (2026-09-18, before design.md):

- [x] **Which types ship in v1** — all four: soft-clip, asymmetric (even-harmonic), tape, hard.
- [x] **Level dependence: one knob or baked per type** — one knob, exposed. The gate asked for
      *transparent controls*, so no character is hidden inside a type.
- [x] **Input trim** — yes, the device gets an input trim as well as output gain/auto gain.

Still open (do not block the design gate; the design proposes an answer for each):

- [ ] Should changing the type also apply that type's typical tone defaults, or leave the user's tone
      settings untouched? (Design: leave them untouched; type-typical starting points ship as presets.)
- [ ] Is the hard-clipping type distinct enough from the soft-clip type at high drive to ship in v1,
      or does it collapse into "startup brightness" of the same curve? (Settled by the type tests.)
- [ ] User-facing name: **Saturator** (as spec 016 already writes it) or something that hints at the
      distortion range too?
