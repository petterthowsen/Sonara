# 0025 — Stage mic setups are capsules rendered per tap

Status: accepted (spec 052, `docs/specs/052-stage-mics-and-sections/`). Extends ADR 0024.

## Context

The Stage listener of spec 051 is an ideal constant-power panner: every direction becomes a pure
level difference. Orchestral recordings are made with mic arrays (Decca tree, AB, ORTF, Blumlein,
XY, Mid/Side), and each images and captures the room differently. Spaced arrays differ in arrival
time between left and right, and that difference applies to every reflection separately.

## Decision

- **A mic setup is a set of capsules.** `audio/stage/mic.rs` describes each setup as up to three
  capsules: an offset from the Listener, an aim, a first-order polar pattern `a + (1 - a) cos(theta)`
  (omni, cardioid, figure-8) and an output mix. `RoomModel::mic` carries the choice; it travels in
  `/stage/set` as the 23rd argument (0 Pan ... 6 Decca tree, unknown = Pan, 22-argument form = Pan).
- **Coincident setups cost the same as Pan.** XY, Blumlein and Mid/Side have every capsule at the
  Listener, so a tap is still one delay-line read and the capsule gains are summed into the L/R gain
  pair. Pan keeps `StereoPanner` untouched, so projects without a mic value sound as in spec 051.
- **Spaced setups render each tap once per capsule.** AB, ORTF and the Decca tree call `taps()` with
  the capsule position as the receiver, so each capsule gets its own path length, direction and
  polar gain, and the stage reads the history once per capsule (2 or 3 reads, measured at 1.2x to
  1.4x the Pan cost). With Distance delay off, delays are measured from the point's earliest capsule
  arrival, so the stage adds no fixed latency.
- **Normalization is at `R_REF` with a per-capsule distance law.** Each setup has a gain that gives
  a source straight ahead at `R_REF` (5 m) `L^2 + R^2 = 1`, as Pan does, with each capsule's own
  distance (`R_REF / r_capsule`) applied. This folds the Decca centre mic's head start into the level.
  At other distances the setups differ slightly, as real arrays do.
- **The Panner trait stays the layout seam.** The mic array sits beside it for stereo only; surround
  and binaural outputs plug in behind `Panner` later.
- **A mic change crossfades.** The direct sound state moves into the per-room `Bank`, so a `Fade`
  (50 ms) renders old and new setups together, as it already did for the reflections. The late tail
  ignores the mic.

## Rejected

Emulating spaced arrays after panning (a delay on one output, or a decorrelation filter on the
stereo result). It cannot give each reflection its own time difference, which is what makes AB and
the Decca tree sound wide, and it would put a second model of time differences in the stage.
Replacing the `Panner` trait by the mic array: the trait is the seam for non-stereo layouts.

## Consequences

Blumlein and Mid/Side use figure-8 capsules with opposite polarity between left and right for
sources to the side, so they are not mono compatible. Spaced setups cost up to 1.4x Pan per source.
Unit tests cover each setup's polar gains, the arrival-time differences and the level match.
