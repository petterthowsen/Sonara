# Sidechain modulator view, gain and amount; modulator capacity — Requirements

## Problem

The `sidechain` modulator (spec 036) is hard to set up by eye. Its panel display draws the
generic trace: 40 points from the ~20 Hz `modulation` stream, which steps visibly and misses
short transients such as a kick. Its options show the Source menu and four knobs, so there is
no way to see what the Low Cut / High Cut filters remove from the source. A quiet source sits
low in the follower's −60…0 dBFS window, and nothing can raise it. The modulator's output
can't be scaled or inverted except by editing every route. The filters are 12 dB/oct, which is
too gentle to isolate a kick from a bass playing on the same channel.

## Scope

| | |
|---|---|
| Subsystem | both — engine (modulation kinds and state, `ModulatedDevice` streams) and Godot (modulator panel display, Sidechain options) |
| Touches real-time audio thread | yes — gain, amount and the steeper filters run per frame in the sidechain feed; the new analysis runs on the audio callback while subscribed |
| Adds or changes an OSC message | yes — a new device data stream type on the existing `data/subscribe` / `data` addresses; no new address |
| Changes a persisted format (`.sonara`) | yes, additively — two new saved `sidechain` parameters (Gain, Amount). Projects without them load at their defaults. No migration. |

## Requirements

### REQ-001 — Input gain

The `sidechain` modulator shall have a **Gain** parameter, −24…+24 dB with a default of 0 dB,
applied to the source signal before the Low Cut / High Cut filters and the follower.

- **Acceptance:** engine unit test. A −30 dBFS sine reads a follower value of 0.5 at Gain 0 dB
  and 0.9 at Gain +24 dB (−6 dBFS mapped onto −60…0).
- **Example:** a quiet hi-hat bus at −40 dBFS with Gain +18 dB drives the follower like a
  −22 dBFS source.

### REQ-002 — Output amount

The `sidechain` modulator shall have an **Amount** parameter, 0…100 % with a default of
100 %. Its output shall be `amount × follower value`, which stays unipolar (0…1). Every route
then applies its own amount on top, as for any other kind; inverting is the route's job (a
negative route amount).

- **Acceptance:** engine unit test. With the follower at 0.8, Amount 50 % reports 0.4,
  Amount 100 % reports 0.8 and Amount 0 % reports 0. A route at +1.0 to a parameter at base
  0.2 then moves it to 0.6, 1.0 and 0.2.
- **Example:** a kick drives a filter cutoff too hard at 100 %; Amount 40 % tames every route
  at once without editing them.

### REQ-003 — 24 dB/oct filters

The Low Cut (high-pass) and High Cut (low-pass) filters ahead of the follower shall be
24 dB/oct. Each is still bypassed at its range extreme (Low Cut at 20 Hz, High Cut at 20 kHz).
This supersedes the 12 dB/oct slope in spec 036 REQ-007.

- **Acceptance:** engine unit test. With Low Cut at 500 Hz, a 125 Hz tone (two octaves below)
  reads at least 40 dB lower than with Low Cut off. With High Cut at 500 Hz, a 2 kHz tone
  likewise. With both at their extremes, the follower reads the same as the raw signal.

### REQ-004 — Animated signal line in the panel display

WHILE a device's modulators pane is shown, the `sidechain` modulator's panel display shall
draw its output (after Amount) as a line scrolling right to left over the last ~2 s, newest at
the right edge. The line shall advance smoothly at the UI frame rate and keep peaks shorter
than one ~50 ms status interval.

- **Acceptance:** live. A kick at 120 BPM on the source channel draws one distinct peak per beat
  that scrolls left without stepping. Godot test: feeding a decoded history of 80 values that
  holds one peak sample makes the line's highest point equal that peak.
- **Example:** a 10 ms kick transient at full level, which the 20 Hz snapshot often misses,
  shows as a peak reaching the top of the display.

### REQ-005 — Display range

The panel display shall draw 0 at the bottom and 1 at the top, whatever Amount is, so a lower
Amount visibly shrinks the line. The live dot sits at the line's newest point.

- **Acceptance:** Godot test. Amount 50 % with the follower at 1.0 puts the newest point at the
  vertical middle.

### REQ-006 — Spectrum in the Sidechain options

WHILE a `sidechain` modulator's options are shown, the options shall draw a spectrum of its
source on a log frequency axis (20 Hz–20 kHz). The incoming signal (after Gain, before the
filters) is a gray filled area. The filtered signal that reaches the follower is a white line
drawn over it.

- **Acceptance:** live. With Low Cut at 1 kHz on a full-range source, the white line falls away
  below 1 kHz at a visibly steeper slope than it does with the cut off, while the gray area is
  unchanged. Godot test: decoding a known two-curve blob yields the gray and white point arrays.
- **Example:** a drum bus source with Low Cut 30 Hz and High Cut 150 Hz shows white only around
  the kick's fundamental, over a gray full-range area.

### REQ-007 — Cut markers on the spectrum

The spectrum shall mark the Low Cut and High Cut frequencies with vertical lines while each
filter is active, and hide a marker while its filter is bypassed at the range extreme. The
markers follow the parameter values, including modulation offsets that reach them.

- **Acceptance:** Godot test. Low Cut at 20 Hz draws no low marker. At 200 Hz the marker's x
  equals the axis position of 200 Hz.

### REQ-008 — Gain and Amount controls

The Sidechain options shall show a **Gain** knob and an **Amount** slider (0…100 %), bound
like the existing knobs: automatable, modulatable by other modulators (mod→mod) and showing
their live modulation.

- **Acceptance:** Godot test. The options scene has slots for both parameters, bound to the
  modulator, and stays within `ModulatorOptions.MAX_HEIGHT`. Live: dragging Amount to 50 %
  halves the height of the panel display's line.

### REQ-009 — Streams cost nothing when hidden

WHILE no view subscribes, the engine shall not run the spectrum analysis or collect the
display history for a `sidechain` modulator.

- **Acceptance:** engine unit test. Without a subscription, a `ModulatedDevice` carrying a
  sidechain modulator returns no sidechain data from `poll_device_data`. After unsubscribing,
  it stops returning data.

### REQ-010 — Old projects load unchanged

WHEN a project saved before this spec is loaded, its `sidechain` modulators shall get Gain 0 dB
and Amount 100 %. Their output then equals the pre-spec output, apart from the steeper filter
slope (REQ-003).

- **Acceptance:** Godot or engine test. Load a modulator record without the new parameters; the
  parameters read their defaults, and with both cuts bypassed the output matches the old follower
  value.

### REQ-011 — 32 modulators and 128 routes per device

A device shall hold up to 32 modulators (was 8) and 128 modulation routes (was 64). The
modulators pane shall offer the add cell until the device holds 32, and its full-capacity
tooltip shall name the new limit. This supersedes the capacity in spec 018.

- **Acceptance:** engine unit test. Adding modulator ids 0–31 succeeds and id 32 is rejected;
  a 128th route is accepted and a 129th is rejected. Godot test (`test_modulators_ui.gd`): at
  32 modulators one placeholder remains, with the tooltip "Maximum of 32 modulators".
- **Example:** a device with 12 knob macros, 4 LFOs and a sidechain (17) can be built.

## Non-functional

- **Real-time safety:** the per-frame feed stays allocation-free and fixed-size, and
  `ModulatorState` stays `Copy`. The FFT, history and spectrum buffers are allocated on the
  command thread before a subscription becomes active, and are dropped off the audio thread.
- **Latency / performance:** follower latency is unchanged. While unsubscribed, the added cost
  is the gain multiply and the extra filter sections only. Empty modulator slots cost a skipped
  branch per control step. The capacity increase grows a PolySynth's preallocated per-voice
  modulator state about fourfold (64 voices × 32 slots, on the order of 1 MB per instance);
  design must measure it.
- **Compatibility:** an old engine with a new Godot rejects the new stream subscription with a
  warning; the panel then falls back to the existing trace and the options show no spectrum.
  A new engine with an old Godot is unaffected. A project saved with more than 8 modulators on
  a device loads in an older build without the modulators above id 7 (they are rejected with a
  warning).

## Out of scope

- Changing the follower's −60…0 dBFS mapping, its peak detection, or the attack/release ranges.
- A filter slope choice. The slope is fixed at 24 dB/oct.
- Resonance, or filter types beyond high-pass and low-pass.
- Changing the panel displays of other trace kinds (CC, velocity, random and so on).
- Configurable spectrum resolution or speed (the EQ's `data/configure` options).
- Interacting with the spectrum, such as dragging the cut markers.

## Open questions

- [ ] None blocking.
