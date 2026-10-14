# Pitch Shifter — Requirements

Requirements for a built-in pitch-shifting effect device. Written against the repo's
`docs/specs/_templates/requirements.md`. File names and technology choices belong in `design.md`,
not here.

Context: Bitwig's Pitch Shifter (±12 semitones plus a Grain control in Hz) is the reference point.
This device keeps that core and adds Fine, Jitter, Feedback, Spread and Mix. The Frequency Shifter
was discussed alongside it and is tracked separately in issue #139.

## Problem

There is no way to transpose audio on a channel. Audio clips can only be repitched together with
their tempo, and no device can shift pitch while leaving time alone. So a user can't build an octave
layer, a detuned doubler, a harmonized line or a shimmer-style feedback texture from audio inside
Sonara. Every mainstream DAW ships a real-time pitch shifter as a basic effect.

## Scope

| | |
|---|---|
| Subsystem | Engine + Godot + docs (a new built-in effect device) |
| Touches real-time audio thread | yes. The device processes audio on the callback, so the design must respect the audio-thread contract. |
| Adds or changes an OSC message | no new message type. The device's parameters use the existing normalized parameter path, and the device gains an entry in the `/builtin/request` → `/builtin/info` → `/builtin/complete` list. The protocol doc's built-in list is updated. |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no. The device is additive, and its parameters persist through the existing device-parameter mechanism. |

## Requirements

### REQ-001 — A discoverable built-in Pitch Shifter

The engine shall expose a built-in effect device named **Pitch Shifter** in the built-in device
list, so Godot discovers it at runtime.

- **Acceptance:** the effect conformance check covers the device. A live built-in round trip
  reports it with its parameter list.
- **Example:** Godot requests built-ins → the response contains the Pitch Shifter with its
  parameters.

### REQ-002 — Insertable anywhere an effect can go

The device shall process stereo audio in a channel's device chain, inside a slot chain (including a
loop slot such as Delay FB FX or Reverb Tank FX), and inside a Multiband FX band.

- **Acceptance:** a live check in each position produces the shifted signal. In a loop slot,
  repeats climb or fall in pitch.
- **Example:** Pitch Shifter at +12 st in the Delay's FB FX → each repeat is an octave higher than
  the one before.

### REQ-003 — Pitch in semitones

The device shall shift its input by the **Pitch** amount, from −24 to +24 semitones in whole
semitone steps, without changing the input's duration.

- **Acceptance:** for a 440 Hz sine at Mix 100 %, Grain at its default and Jitter at 0, the
  strongest spectral peak of the output lies within ±10 cents of `440 · 2^(n/12)` Hz for
  n ∈ {−24, −12, −7, +7, +12, +24}.
- **Example:** Pitch +12 → the peak is near 880 Hz. Pitch −12 → near 220 Hz.

### REQ-004 — Fine tuning in cents

The device shall add a **Fine** offset from −100 to +100 cents, continuous, to the Pitch amount.

- **Acceptance:** the peak test from REQ-003 at Pitch 0, Fine +50 lies within ±5 cents of +50.
- **Example:** Pitch +7, Fine −2 → a slightly flat fifth.

### REQ-005 — Grain size

The device shall offer a **Grain** control from 1 to 100 Hz that sets how often it restarts its
read window. Lower values mean longer grains (smoother, more smeared). Higher values mean shorter
grains (tighter, with an audible grain-rate modulation at the top of the range).

- **Acceptance:** at a fixed non-zero shift, the period of the output's amplitude modulation from
  grain crossfades matches 1/Grain within 5 %. A render at 100 Hz shows sidebands at ±100 Hz around
  the shifted peak that a 5 Hz render does not.
- **Example:** Pitch +12, Grain 5 Hz → a smooth, slightly chorused octave. Grain 80 Hz → a buzzy,
  ring-mod-like octave.

### REQ-005a — Tempo-synced grain

WHERE the Grain **Sync** selector is set to a note division (not Off), the grain rate shall follow
the project tempo at that division, using the same divisions as the Delay's sync, and the Hz value
shall be ignored. WHEN the tempo changes, the grain rate shall follow without a click.

- **Acceptance:** at 120 BPM with Sync 1/16, the grain modulation period measures 125 ms ±5 %. With
  Sync Off, the Hz knob applies again.
- **Example:** Sync 1/8 at 90 BPM → grains restart every 333 ms.

### REQ-006 — Zero shift is transparent

WHILE the total shift is zero (Pitch 0, Fine 0, Spread 0) and Jitter is 0, the wet signal shall be
the input delayed by a constant amount, with no grain-rate amplitude modulation.

- **Acceptance:** with Feedback at 0, the wet output equals the input delayed by the device's
  constant wet delay, within float rounding, for any Grain setting.
- **Example:** a drum loop at Pitch 0, Mix 100 % → it sounds identical to the input, only very
  slightly late.

### REQ-007 — Jitter

The device shall offer a **Jitter** control from 0 to 100 % that randomizes grain timing. At 0 %
grains are strictly periodic. As Jitter rises, the comb/flange coloration that periodic grains
produce on sustained material shall decrease.

- **Acceptance:** at 0 %, the grain-crossfade modulation is periodic. At 100 % its period varies
  from grain to grain. Two renders of the same input with the same settings are bit-identical
  (seeded randomness).
- **Example:** a held pad at +5 st, Grain 20 Hz → at Jitter 0 a buzzy tone at 20 Hz is audible. At
  Jitter 60 % it smears into a diffuse texture.

### REQ-008 — Feedback

The device shall offer a **Feedback** control from 0 to 95 % that feeds the shifted output back
into the shifter, so each pass is shifted again. The feedback path shall roll off high frequencies
gently, so repeated passes don't build up harshness. Output shall stay bounded at every setting.

- **Acceptance:** at Pitch +12, Feedback 80 %, an impulse produces decaying echoes. Each echo's
  dominant pitch is an octave above the previous one, up to the band limit. A 60-second render of
  full-scale noise at Feedback 95 % never exceeds a fixed output bound and contains no NaN or Inf.
- **Example:** Pitch +12, Feedback 60 % on a vocal → the classic rising shimmer stairs.

### REQ-009 — Stereo spread

The device shall offer a **Spread** control from 0 to 50 cents. The left channel is shifted up by
Spread and the right channel is shifted down by Spread, on top of Pitch + Fine.

- **Acceptance:** for a 440 Hz mono input at Pitch 0, Spread 20 cents, the left output's peak is
  within ±5 cents of +20 and the right output's peak within ±5 cents of −20. At Spread 0 the left
  and right outputs are identical for a mono input.
- **Example:** a mono vocal at Spread 10 cents, Mix 50 % → the classic micro-pitch doubler.

### REQ-010 — Mix

The device shall have a **Mix** control. At 0 % it outputs the input bit-exactly. At 100 % it
outputs only the wet signal. Changing Mix does not click.

- **Acceptance:** null test. At Mix 0 %, input minus output is digital silence for any other
  setting. Automating Mix produces no clicks.
- **Example:** Feedback 95 %, Pitch +24, Mix 0 % → the subtracted output is all zeros.

### REQ-011 — No reported latency

The device shall report zero added latency to the host. Its constant wet delay (REQ-006) shall be
short enough not to be heard as an echo.

- **Acceptance:** the device's reported latency is 0 for every parameter setting. The constant wet
  delay measured in REQ-006 is under 5 ms at 48 kHz.
- **Example:** Pitch Shifter on a channel → the latency plan for that channel is unchanged.

### REQ-012 — Smooth automation

Every continuous parameter shall be automatable and smoothed. Sweeping Pitch or Fine shall produce
a continuous glide (stepping in semitones for Pitch) with no clicks beyond the normal grain
character. Parameters shall cross the OSC boundary as normalized 0.0–1.0 values.

- **Acceptance:** recorded automation on Fine, Grain, Feedback, Spread and Mix plays back without
  zipper noise. A Pitch automation from −12 to +12 over one bar produces no discontinuity larger
  than a normal grain boundary.
- **Example:** an LFO modulator on Fine at ±30 cents → a smooth vibrato.

### REQ-013 — Real-time safety and hostile input

The device shall not allocate, block, do I/O or wait on a lock on the audio callback. It shall be
denormal-safe. IF the input contains non-finite samples, THEN the device shall not keep them in its
internal state or produce non-finite output.

- **Acceptance:** an allocation/blocking check over the process function. A denormal test with a
  decaying feedback tail. A NaN/Inf injection test asserting that the output stays finite and that
  the device recovers to normal output after finite input resumes.
- **Example:** feed 1000 frames of ±Inf, then a sine → the output is finite throughout, and the sine
  comes out shifted.

### REQ-014 — Sample-rate changes

WHEN the engine's sample rate changes, the device shall keep its shift, grain timing and spread
correct at the new rate, and buffers shall not be resized on the audio callback.

- **Acceptance:** the REQ-003 peak test passes at 44.1, 48 and 96 kHz.

### REQ-015 — Sleep and tail

WHEN the device has had silent input for the standard idle period AND its feedback tail has
decayed, the engine shall put it to sleep (ADR 0008). It shall wake on the next signal without a
click or lost samples. With Feedback above 0, the device shall not sleep before its tail has
decayed.

- **Acceptance:** at Feedback 80 %, an impulse's echoes are not cut off by sleep. After the tail,
  the device reports sleeping. A hit after a long silence comes out intact.

### REQ-016 — CPU inside the effect budget

The device shall run within the existing built-in effect budget.

- **Acceptance:** a release-build benchmark of the process function (512 frames, 48 kHz, stereo)
  costs no more than the Chorus at its default settings, measured with the same harness. A live
  run has no dropouts.

### REQ-017 — Persistence

WHEN a project containing the device is saved and reopened, every parameter shall come back with
the same value.

- **Acceptance:** save → reopen → identical parameter values (the existing device-parameter round
  trip).

### REQ-018 — A usable view

The device shall be usable from Godot's generic device panel, with no custom view: every parameter
is reachable and shows its
value in its own unit (st, cents, Hz, %).

- **Acceptance:** live. Add the device, adjust every control, and see the value labels and the
  audible result.

## Non-functional

- **Real-time safety:** all buffers are sized for the worst case (the widest shift at the longest
  grain at the highest supported sample rate) on the command thread. The callback only reads,
  writes and mixes.
- **Latency / performance:** no reported latency (REQ-011). CPU cost is in the range of the
  Chorus.
- **Compatibility:** additive. Older projects are unaffected. A project saved with the device does
  not load the device in an engine that predates it.
- **Consistency:** the Mix convention (0 % = bit-exact dry) and the smoothed-parameter rule follow
  the spec 012 suite conventions.

## Out of scope

- A high-quality or formant-preserving mode (phase vocoder or similar). That should share an engine
  with the clip **Stretch** mode and will get its own spec. See open question 3 about reserving a
  Mode parameter now.
- MIDI-controlled pitch / harmonizer. MIDI only reaches the first device in a chain. Modulators can
  already drive Pitch and Fine.
- The Frequency Shifter (issue #139).
- A custom visual view (see open question 4).
- Factory presets.

## Open questions

Resolved at the requirements gate (2026-10-14):

- [x] **Pitch range.** ±24 st.
- [x] **Grain tempo sync.** Yes. A sync selector like the Delay's, where Off = the Hz knob (REQ-005).
- [x] **Feedback tone.** A fixed gentle high cut in the feedback path, with no knob (REQ-008).
- [x] **View.** The generic panel view only in v1 (REQ-018).

Proposed defaults, not raised at the gate (the design takes these unless overruled):

- [x] **Mode parameter.** Not reserved. A later HQ mode adds a new parameter id whose default means
      Granular.
- [x] **Tap count.** Fixed internally, not user-facing. The design picks 2 or 4 based on the
      Jitter/comb tests.
