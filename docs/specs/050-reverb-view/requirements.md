# Reverb View — Requirements

## Problem

The built-in Reverb (spec 012, slots from spec 040) has 18 parameters and two slots. Today it
shows only the generated Simple View, which groups knobs by keyword role, not by where they sit
in the signal path, and has no picture of what the settings do. Seeing how Decay, the Decay EQ,
Pre-Delay, Early and the cuts shape the tail means listening and guessing. Users of the
reverb notice it every time they reach for one.

## Scope

| | |
|---|---|
| Subsystem | both (Godot view; Engine data stream on the Reverb device) |
| Touches real-time audio thread | yes — the Reverb collects envelope records in its process call; design must respect the audio-thread contract |
| Adds or changes an OSC message | no — reuses the existing device data subscribe/poll path with a new data type on the Reverb |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no — the view adds no parameters and no saved view state |

## Requirements

### REQ-001 — Custom panel view

The device panel shall show the Reverb with a dedicated view instead of the Simple View, and it
shall contain every Reverb parameter and both slots (Tank FX, Wet FX). The Simple View toggle
shall still switch to the generated view.

- **Acceptance:** headless test instantiates the Reverb panel view, finds one control per
  parameter id in the Reverb's parameter list and one slot tile per slot key.
- **Example:** a new Reverb on an audio channel opens with the decay map and all 18 controls
  inside the 350 px device panel.

### REQ-002 — Signal-path control order

The Reverb view shall lay out its controls left to right in signal-path order: Algorithm,
Pre-Delay, Early, Diffusion, Size, Decay, Freeze, Decay EQ (Low Mult, Low Freq, High Mult,
High Freq), Modulation (Rate, Depth), the Tank FX slot, Tone (Low Cut, High Cut), the Wet FX
slot, Ducking, Width, Mix.

- **Acceptance:** headless test reads the global x position of each control and asserts the
  order above (ties allowed only within one stacked group).

### REQ-003 — Decay map

The Reverb view shall show a decay map with time on the horizontal axis (square-root scaled,
so the first ~100 ms around Pre-Delay and the early reflections stay readable) and frequency
(log, 20 Hz–20 kHz) on the vertical axis, shading the tail's level in dB at each time and
frequency as the current parameters predict. It shall draw:

- a gap from t = 0 to Pre-Delay before anything starts;
- the onset after Pre-Delay as one picture: every early reflection (both channels in one row) a
  broadband column whose brightness follows Early and whose spacing follows Size and Algorithm;
  Diffusion blurs the columns into a wash and makes the late tail fill in sooner, while at 0 %
  the columns are sharp and the tail fills in behind them (a visual estimate, not modelled);
- the −60 dB contour per frequency, so the tail at 1 kHz ends at Decay, and below Low Freq and
  above High Freq it ends at Decay × Low Mult and Decay × High Mult, with a smooth knee at each
  crossover;
- the region below Low Cut and above High Cut faded out.

- **Acceptance:** unit test of the map model: for Decay 2.0 s, Low Mult 1.5, Low Freq 250 Hz,
  High Mult 0.5, High Freq 4 kHz, Pre-Delay 20 ms, the contour time is 2.02 s ± 10 % at 1 kHz
  (the engine's shelf skirts reach 1 kHz too; its own test allows 15 %), 3.02 s ± 5 % at 30 Hz
  and 1.02 s ± 5 % at 18 kHz.
- **Example:** turning High Mult from 0.5 to 1.0 makes the top of the shaded region reach as
  far right as the 1 kHz contour.

### REQ-004 — Map follows parameters

WHEN any Reverb parameter changes (from a knob, automation, a preset or an undo), the decay map
shall redraw from the new values within one frame.

- **Acceptance:** headless test sets Decay through `DeviceInstance` and asserts the map model's
  1 kHz contour time changed.

### REQ-005 — Auto-fitting time axis

The decay map's time span shall follow the longest predicted tail (Pre-Delay plus the largest
band decay), snapped to a readable step, and shall ease to a new span instead of jumping. WHILE
the user drags a handle on the map, the span shall not change.

- **Acceptance:** model test: Decay 0.3 s gives a span ≤ 1 s; Decay 20 s gives a span ≥ 20 s;
  a drag in progress leaves the span unchanged until release.

### REQ-006 — Freeze on the map

WHILE Freeze is on, the decay map shall draw the tail running past the right edge at full level
and mark the map as frozen.

- **Acceptance:** model test: with Freeze on, the contour time at every frequency is reported as
  infinite; visual check in the live app.

### REQ-007 — Editable handles

The decay map shall let the user edit parameters by dragging:

| Handle | Drag | Parameter |
|---|---|---|
| 1 kHz contour | horizontal | Decay |
| Low knee | horizontal / vertical | Low Mult / Low Freq |
| High knee | horizontal / vertical | High Mult / High Freq |
| Left edge of the tail | horizontal | Pre-Delay |
| Bottom cut edge | vertical | Low Cut |
| Top cut edge | vertical | High Cut |

Each drag shall make one undo step per parameter it changed (the existing gesture rule for every
parameter control), shall respect the parameter's range, and the handle's control
shall show the same hover highlight and value tooltip as its knob. Double-clicking a handle shall
reset its parameter(s) to the default.

- **Acceptance:** headless test drags each handle with synthetic mouse events and asserts the
  parameter's real value moved in the right direction and stays in range; one undo restores it.

### REQ-008 — Live envelope strip

WHILE the Reverb view is shown, the view shall show a strip under the decay map with two
scrolling traces: the Reverb's input level and its wet output level, both in dB (−60 to 0 dBFS),
spanning the same length of time as the decay map.

- **Acceptance:** engine unit test: a subscribed Reverb fed one impulse produces records whose
  wet level decays at the configured Decay (−60 dB at Decay ± 10 %); live check: a snare hit
  shows an input spike followed by a wet trace sloping down over the map's span.
- **Example:** with Decay 2 s, a single hit's wet trace crosses −60 dB about 2 s after the
  input spike.

### REQ-009 — Stream subscription lifetime

WHEN the Reverb view is shown, it shall subscribe to the Reverb's envelope data, and WHEN it is
hidden or freed, it shall unsubscribe. WHILE no view is subscribed, the Reverb shall not collect
envelope records.

- **Acceptance:** engine unit test: an unsubscribed Reverb returns no device data; headless test
  shows/hides the view and asserts subscribe/unsubscribe calls on the device.

### REQ-010 — Sleep is unaffected

The envelope stream shall not keep a sleeping Reverb awake. WHILE the Reverb sleeps, the strip
shall keep scrolling and show silence.

- **Acceptance:** engine unit test: a subscribed Reverb with silent input still goes to sleep
  after its tail; headless test: no data for 0.5 s scrolls the strip and appends silence.

### REQ-011 — Tank FX note

WHILE the Tank FX slot holds at least one enabled device, the decay map shall mark the
prediction as approximate, since devices inside the decay loop change the tail in ways the map
cannot model.

- **Acceptance:** headless test adds a device to the Tank FX slot and asserts the map's
  approximate flag; removing it clears the flag.

### REQ-012 — Slot tiles

The Tank FX and Wet FX tiles shall show and hide their slot chains in the device lane the same
way the Simple View's slot tiles do.

- **Acceptance:** headless test clicks each tile and asserts the slot's open state toggles.

## Non-functional

- **Real-time safety:** the Reverb's envelope collection allocates nothing on the audio
  callback, takes no lock and does no I/O; record storage is sized in `prepare`. Collection
  costs no more than a peak compare per sample while subscribed and nothing when unsubscribed.
- **Latency / performance:** the decay map redraws only on parameter or span change, not every
  frame; the strip redraws at the device data rate (about 20 Hz).
- **Compatibility:** existing projects open unchanged; the Reverb's parameters and slot keys
  are untouched.

## Out of scope

- A live spectrogram or a measured impulse response of the actual reverb output.
- Separate early-reflection / late-tail traces, or per-channel (L/R) traces (the early taps of
  both channels share one row).
- A Window view or Companion view for the Reverb.
- Modelling the effect of Diffusion (beyond the onset estimate in REQ-003), Modulation, Ducking
  or Tank FX devices on the map beyond the approximate flag.
- Per-algorithm differences in the map shape (Room, Hall and Plate share Decay and the Decay EQ;
  only Early's tick spread may differ if the design finds the taps differ).

## Open questions

- [x] Do Room, Hall and Plate use the same early-reflection tap pattern? No: each has its own
      table (`EARLY_ROOM`, `EARLY_HALL`, `EARLY_PLATE`); the map draws the current algorithm's.
- [x] Does everything fit 350 px? Yes, with Decay EQ, Modulation and Tank FX in a row under the
      map (see design.md Layout); the order in REQ-002 holds.
