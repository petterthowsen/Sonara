# 017 — Utility device

A small built-in effect for everyday gain staging and stereo work: gain, pan, width, plus the
handful of toggles people expect next to them (mono, bass mono, phase invert, mute).

- ID: `sonara.builtin.utility`, name "Utility".
- Registered as an **effect** (`DeviceCategory::Effect`). The factory test requires this for
  every `EFFECT_IDS` entry.
- No new OSC messages. Parameters use the existing device param path and Godot discovers the
  device through `/builtin/request`.

## Parameters

| ID | Name | Group | Range / kind | Default |
|---|---|---|---|---|
| 0 | Gain | Main | `linear(-60, 24)` dB; the floor is treated as −inf (silence) | 0 dB |
| 1 | Pan | Main | −100…+100 % (balance) | 0 % |
| 2 | Width | Main | 0…200 % | 100 % |
| 10 | Mono | Stereo | Bool | off |
| 11 | Bass Mono | Stereo | Bool | off |
| 12 | Bass Mono Freq | Stereo | `log(20, 500)` Hz | 120 Hz |
| 20 | Invert L | Phase | Bool | off |
| 21 | Invert R | Phase | Bool | off |
| 30 | Mute | Main | Bool | off |

Gain tops out at +24 dB, like Bitwig's Tool. `param_table` has no −inf kind. The device maps the
bottom of the range to a gain of 0 instead of adding a new `Kind`.

## Signal path

Per sample, in this order:

1. **Phase invert.** Negate L and/or R.
2. **Bass mono** (only while enabled). A one-crossover `MultibandSplitter`
   (`audio/dsp/crossover.rs`) splits off the low band, which is summed to mono and added back to
   the high band. The splitter's dry-path all-passes keep the phase consistent, so the result
   with Bass Mono on and stereo-only content above the crossover equals the input apart from the
   all-pass phase. While the toggle is off, the splitter isn't run.
3. **Width.** In M/S, with M = (L+R)/2 and S = (L−R)/2. Mono forces w = 0.
   - w ≤ 1: `mid = 1`, `side = w`. Narrowing never changes the mono sum, and 0 % is a true mono
     fold.
   - w > 1: `n = sqrt((1 + w²) / 2)`, `mid = 1/n`, `side = w/n`. This keeps the total level
     constant for uncorrelated M/S. At 200 %, mid ≈ −4 dB and side ≈ +2 dB, a 2:1 side-to-mid
     ratio. The curve is continuous at w = 1.
4. **Pan (balance).** Unity in the center. Moving the knob attenuates the opposite side along a
   cos curve, reaching silence at ±100 %. The near side stays at unity.
5. **Gain × mute.** Mute is a smoothed fade to 0, not a hard switch.

Gain, pan, width and the mute fade use `SmoothedParam` (about 20 ms) so automation doesn't
produce zipper noise. The mid and side gains are computed from the smoothed width.

**Pass-through.** When every parameter is at its default and the smoothers have settled, the
block is passed through bit-exact (`effect::pass_through`).

**Sleep.** The device has no tail, so it follows the normal silence-based sleep.

**Audio-thread rules.** All state lives in the struct and is preallocated in `new()`: no
allocation, locks or I/O in `process`.

## Engine work

- `Engine/src/audio/devices/utility.rs`: the device, parameter specs and `mod tests`.
- `devices/mod.rs`: declare the module and export the device.
- `devices/factory.rs`: add the device to `EFFECT_IDS` and `create_effect`.
- `effect_conformance.rs` picks it up through `EFFECT_IDS`.

### Tests (in `utility.rs`)

- With default parameters, the output is bit-exact equal to the input.
- At width 0 %, the output has L == R, equal to (L+R)/2.
- At width 200 % on uncorrelated stereo noise, total power is within 0.1 dB of the input.
- At width 200 %, the side-to-mid gain ratio is 2:1.
- Pan at center is unity. Pan at +100 % silences L and leaves R at unity.
- Invert L and Invert R flip the sign of their channel only.
- Bass Mono: a low sine (40 Hz) panned hard left comes out with L ≈ R. A high sine (5 kHz)
  panned hard left stays on the left.
- Gain at the bottom of its range gives silence, and +24 dB gives about ×15.85.
- Mute fades to silence without a step: the per-sample difference stays below a threshold.
- The output does not depend on block size: identical for blocks of 64 and 512 frames.

## Godot work

- None required for v1. Like the phaser, the device uses the generic parameter view and the
  Simple View built from `/builtin/info`.
- Later and optional: a compact custom view (`devices/builtin/UtilityDefaultView`) with large
  Gain, Pan and Width knobs and a correlation or width meter.

## Docs

- `AGENTS.md`: add `utility` to the built-in devices list.
- `docs/subsystems/`: a short note next to the spec 012 effects describing the width curve and
  balance law.

## Order of work

1. `utility.rs` device and unit tests.
2. Registration in `factory.rs` and `mod.rs`, then run `cargo test` (unit and conformance tests).
3. Manual check in the app with the generic view: automate width and pan for zipper noise, and
   flip between mono and stereo.
4. Docs.

## Out of scope (possible follow-ups)

- An uncompensated ("add side") width mode.
- Channel mode (L only / R only / Swap).
- DC offset removal.
- A custom Godot view with a correlation meter.
