# Spec 057: Blur

A built-in audio effect that smears and widens a sound with a cloud of very short, slowly
moving delay taps. It is in the family of Bitwig's Blur: short times (about 1 to 50 ms) heard as
colour, diffusion and width, not as echoes.

## Why

Users try to get this sound by putting a Delay on each side of an L/R Split and modulating
Time. In Clean mode that sounds grainy, because every change in Time starts a 50 ms crossfade
between two read taps (`delay.rs`, `CROSSFADE_SECONDS`). Under constant modulation those
crossfades keep restarting. Tape mode glides smoothly, but its 120 ms glide hides fast motion
and it adds wow and drive. A dedicated device fixes this: many taps, each moved smoothly sample
by sample, never crossfaded.

## Sound and behaviour

- Each channel has **8 taps** (a fixed count, preallocated) reading from one `DelayLine` with
  Hermite reads, as Chorus does. The tap count is the same for every setting so the CPU cost is
  constant.
- **Placement:** each tap has a base time inside `[Size × (1 − Spread), Size]`, taken from a
  fixed, irregular table of 8 fractions (not evenly spaced, so the comb notches don't line up
  into a pitched buzz). L and R use different tables, which is where the width comes from.
- **Motion:** every tap has its own smooth modulator, so the cloud keeps shifting and never
  settles into a static comb. Use either sine LFOs at unrelated rate multipliers (for example
  0.73, 1.0, 1.31, 1.62, ...) with random start phases, or interpolated smooth noise. Pick
  whichever sounds better in phase 1 and keep it. Rate sets the base speed; Depth sets the
  excursion as a fraction of each tap's base time, so short taps move less in absolute terms
  and the pitch wobble stays similar across taps. Positions are clamped to
  `MIN_HERMITE_DELAY`.
- **Diffusion:** an optional series of 3 short Schroeder allpasses (prime lengths of a few ms,
  scaled by Size) on the summed wet signal. At 0 % they are bypassed (exact), and at 100 % the
  attacks dissolve into a short wash. This is the setting that gives the "Blur" character
  rather than "multi-chorus".
- **Feedback:** the summed wet signal, after Tone and Low Cut, is written back into the line.
  Capped at 70 % and soft-clipped (as Delay does) so it can ring metallically but never blow up.
- **Tone:** a one-pole low-pass (Tone) and high-pass (Low Cut) on the wet signal. Low Cut keeps
  the bass out of the smear and keeps the mono sum solid.
- **Output:** each channel's wet signal is normalized by `1/sqrt(8)`. Width is a mid/side scale
  on the wet signal, and Mix is an equal-power crossfade where Mix 0 % is bit-exact dry. These
  are the same helpers Chorus uses (`dry_wet_gains`, `MixLaw`).

## Parameters

Parameter IDs are in blocks of ten per module, the same scheme Chorus and Delay use. Every
continuous parameter goes through a `SmoothedParam`. Size gets a long ramp (about 50 ms, like
Chorus Delay) so a big move glides instead of stepping.

| ID | Name | Group | Range | Default |
|---|---|---|---|---|
| 0 | Size | Blur | 0.5–50 ms, log | 5 ms |
| 1 | Spread | Blur | 0–100 % | 80 % |
| 2 | Rate | Blur | 0.02–5 Hz, log | 0.3 Hz |
| 3 | Sync | Blur | `SYNC_CHOICES` | Off |
| 4 | Depth | Blur | 0–100 %, skewed | 30 % |
| 5 | Diffusion | Blur | 0–100 % | 40 % |
| 6 | Feedback | Blur | 0–70 % | 0 % |
| 10 | Tone | Tone | 1–20 kHz, log | 12 kHz |
| 11 | Low Cut | Tone | 20–1000 Hz, log | 150 Hz |
| 20 | Width | Output | 0–200 % | 100 % |
| 21 | Mix | Output | 0–100 % | 50 % |

## Real-time and engine contract

- Allocate everything in `new`/`prepare`: the delay line sized for 50 ms × (1 + max Depth) plus
  margin, the allpass buffers sized for the largest Size, and the modulator state. Nothing
  allocates in `process_block`.
- The tail is about Size × (Feedback repeats) plus the allpass decay, reported through the same
  tail mechanism Delay uses, so sleep doesn't cut off a ringing smear.
- A sample-rate change re-prepares the buffers on the command thread, as the other effects do.

## Implementation steps

1. **DSP core.** Add `Engine/src/audio/devices/effects/blur.rs`, modelled on `chorus.rs`: the
   parameter table, the tap tables, per-tap modulators, the allpass chain, tone, width and mix.
2. **Registration.** Export it from `effects/mod.rs` and add it to `EFFECT_IDS` and
   `create_effect` in `factory.rs`. `effect_conformance.rs` then covers it automatically.
   Godot discovers it through `/builtin/info`, so no OSC changes are needed.
3. **Engine tests** (in `mod tests` in `blur.rs`):
   - Mix 0 % is bit-exact dry.
   - Sweeping Size and Rate while playing never jumps by more than the input could (the same
     shape as Delay's `clean_time_change_has_no_jump_bigger_than_the_inputs`). This is the
     regression guard for the jitter problem.
   - Diffusion 0 % gives exactly the no-allpass output.
   - Feedback 70 % with a loud input stays bounded.
   - The mono sum (L+R) of a sine through the wet signal doesn't cancel below a set floor
     across the audible range.
   - Silence in gives silence out once the tail has ended, and the device sleeps.
4. **Godot view.** Start with the generic parameter view. If it gets a custom panel, follow the
   device-view pattern (an editable `.tscn` panel scene, controls reached by `%UniqueName`).
   Add Simple view keywords if the browser uses them for effects.
5. **Docs.** Add Blur to the built-in device list in `AGENTS.md` and
   `docs/subsystems/engine-architecture.md`, and add a `CHANGELOG.md` line under
   `[Unreleased]`.

## Listening checks

These are for a person to do. The tests cover correctness, not taste.

- Drums at Size 5 ms, Diffusion 0: should sound wider and softer, with no audible echo or
  flutter.
- A held pad at Depth 60 %, Rate 0.3 Hz: smooth movement, no grain or zipper.
- Diffusion 100 %, Size 30 ms: attacks dissolve into a short, reverb-like smear.
- Switch the master to mono: the sound thins out a little but doesn't hollow out.

## Out of scope

- Delay Clean mode's crossfade under continuous Time modulation. It's a separate issue: the
  Delay could glide when the target moves in small, continuous steps and crossfade only on
  jumps. File it separately if it's worth fixing.
- Tempo-synced tap placement and a freeze/infinite mode.
