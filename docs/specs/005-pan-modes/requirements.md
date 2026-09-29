# Pan Modes — Requirements

## Problem

A channel has four pan modes in the engine, but the mixer only offers two, and neither behaves
the way its name says. "Stereo Combined" is really a balance panner with a constant-power law,
so every centered stereo channel is 3 dB quieter than unity. Stereo Balance and Mono exist in
the engine but can't be chosen in the mixer, and the channel model silently ignores pan changes
in those modes. The AI assistant can set pan but can't see or change the mode. It gets wrong
results on channels that aren't in the default mode, and it still reports success.

## Scope

| | |
|---|---|
| Subsystem | both (engine mixing, Godot channel model, mixer UI, AI assistant tools) |
| Touches real-time audio thread | yes: the pan matrix is computed and applied on the audio callback |
| Adds or changes an OSC message | yes: the pan mode values change meaning and a width value is added |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes: `.sonara` channels gain a width value. Projects saved with the old "Stereo Combined" are migrated to Stereo Balance |

## Glossary

- **Position**: where a single-control panner points, from −1.0 (hard left) to +1.0 (hard right).
- **Width**: how far apart the Stereo Combined panner places the left and right inputs, from
  −1.0 to +1.0. 1.0 is full stereo, 0.0 is a single point, and a negative value swaps left and right.
- **Handle**: the output position of one input channel (L or R) in Stereo Dual or Stereo Combined.

## Requirements

### REQ-001 — Four modes, Stereo Balance by default

The mixer shall offer four pan modes on every channel: Stereo Balance, Stereo Combined,
Stereo Dual and Mono. New channels shall start in Stereo Balance with position 0.

- **Acceptance:** Right-clicking a channel's pan control lists all four modes and checks the
  current one. A newly created channel shows Stereo Balance.

### REQ-002 — Stereo Balance

WHILE a channel is in Stereo Balance, the audio callback shall pass both inputs through at unity
at position 0. Moving the position toward one side shall attenuate only the opposite input,
linearly, reaching silence at ±1.0. Left and right shall never cross over.

- **Acceptance:** Engine unit test on the pan coefficients.
- **Example:** position 0 → L→L 1.0, R→R 1.0. Position +0.5 → L→L 0.5, R→R 1.0.
  Position −1.0 → L→L 1.0, R→R 0.0. The cross terms are always 0.

### REQ-003 — Stereo Combined (Cubase-style)

WHILE a channel is in Stereo Combined, the audio callback shall place the left input at handle
`position − width` and the right input at handle `position + width`. Each handle is clamped to
−1.0..1.0 and panned with a constant-power law, the same as a Stereo Dual handle. Position moves
both handles together. Width spreads or narrows them around the position, and a negative width
swaps the sides.

- **Acceptance:** Engine unit test on the pan coefficients.
- **Example:** position 0, width 1.0 → handles −1/+1, identity (L→L 1, R→R 1, no cross terms).
  Position 0, width 0 → both handles at 0, each input goes 0.707 to each side.
  Position 0, width −1.0 → handles +1/−1, L→R 1, R→L 1.
  Position +0.5, width 1.0 → handles −0.5/+1.0 (the right handle is clamped).

### REQ-004 — Stereo Dual

WHILE a channel is in Stereo Dual, the audio callback shall pan the left and right inputs
independently to their own handles with a constant-power law. This is today's behavior,
unchanged.

- **Acceptance:** The existing Dual coefficients stay the same (engine unit test).

### REQ-005 — Mono

WHILE a channel is in Mono, the audio callback shall sum the inputs as (L+R)/2 and pan the sum
with a constant-power law.

- **Acceptance:** Engine unit test on the pan coefficients.
- **Example:** position 0 with identical L and R content at level x → each output is 0.707·x
  (−3 dB). Position +1.0 → left output silent, right output x.

### REQ-006 — Pan position is honored in every mode

WHEN the pan position of a channel in Stereo Balance, Stereo Combined or Mono is changed, the
channel model shall store it, send it to the engine, and notify the mixer. WHEN a Stereo Dual
channel's handles or a Stereo Combined channel's width are changed, the same shall happen for
those values.

- **Acceptance:** Headless Godot test: setting position, width and dual handles in each mode
  changes the stored values and emits the change signal.

### REQ-007 — Switching modes keeps the placement

WHEN the pan mode changes, the channel model shall carry the placement over as follows:
- Balance, Combined and Mono share one position, which is kept.
- Switching to Stereo Dual sets the handles to the Combined handles
  (`position ∓ width`, clamped). From Balance or Mono, width is taken as 1.0.
- Switching from Stereo Dual to Combined sets position to the handles' midpoint and width to half
  their distance (the right handle minus the left).
- Switching from Stereo Dual to Balance or Mono sets position to the handles' midpoint.

- **Acceptance:** Headless Godot test covering each transition.
- **Example:** Dual L −1.0 / R +0.2 → Combined position −0.4, width 0.6 → back to Dual:
  L −1.0 / R +0.2.

### REQ-008 — Pan changes are undoable

WHEN the user changes the pan mode, position, width or dual handles from the mixer, the change
shall be one undo step that restores the mode and all pan values exactly. A slider drag counts
as one step.

- **Acceptance:** Headless Godot test: change the mode, then undo, and mode and values match
  the originals.

### REQ-009 — Mixer controls per mode

The mixer pan control shall show:
- one position slider in Stereo Balance and Mono
- two handles in Stereo Dual, each dragged on its own
- two handles in Stereo Combined: dragging a handle changes the width symmetrically around the
  position, since the other handle mirrors it. Handles may cross, which makes the width negative

In both two-handle modes, dragging the fill between the handles moves both handles together and
keeps their distance. When the handles overlap (width 0), a plain drag moves both, and an
Alt-drag spreads them apart. Shift keeps its existing fine-drag behavior.

While dragging, the value label shall show the mode's values, for example `30R` or
`L 100L / R 20R`, and for Combined `C, W 60%`.

- **Acceptance:** Live: switch a channel through all four modes and drag each control. The
  displayed values match what the engine applies (`/channel/{id}/pan` messages in the engine
  info log).

### REQ-010 — Old projects migrate to Stereo Balance

IF a project saved before this change has a channel in the old "Stereo Combined" mode, THEN the
channel model shall load it as Stereo Balance with the same position. Stereo Dual channels
shall load unchanged.

- **Acceptance:** Headless Godot test loading an old-format channel dictionary.
- **Example:** old `{"pan_mode": "STEREO_COMBINED", "pan": 0.3}` → Stereo Balance, position 0.3.

### REQ-011 — Save and reload round-trip

The channel model shall save and reload the pan mode, position, width and dual handles without
loss, for all four modes.

- **Acceptance:** Headless Godot test: save and load one channel in each mode.

### REQ-012 — Pan automation drives the position

WHILE a `channel/pan` automation lane plays, the audio callback shall use its value as the
position in Stereo Balance, Stereo Combined and Mono. In Stereo Dual it shall be ignored, which
is today's behavior. Width is not automatable.

- **Acceptance:** Engine unit test: an automation override moves the Combined handles together
  and leaves the width alone.

### REQ-013 — AI assistant reads pan mode

The AI assistant's channel listings (the `list_channels` tool, the prompt context and the
selection context) shall report each channel's pan mode and the values that mode uses:
position, position + width, or the L/R handles.

- **Acceptance:** Headless Godot test on the channel summary.

### REQ-014 — AI assistant sets pan mode and values

The AI assistant's `set_mixer` tool shall accept a pan mode, a position, a Combined width, and
Dual L/R handles. It shall apply them through the same model path as the mixer, as one undo
step. IF a value doesn't apply to the resulting mode (for example width on a Balance channel),
THEN the tool shall refuse the call with an error that names the mode, and change nothing.

- **Acceptance:** Headless Godot test in `Godot/ai/tests/`: set each mode and its values, undo,
  and check that an invalid combination is refused.

## Non-functional

- **Real-time safety:** computing the pan matrix stays allocation-free and lock-free on the audio
  callback. The new width value lives alongside the existing pan fields.
- **Latency / performance:** unchanged. The matrix is computed once per channel per buffer, as
  today.
- **Compatibility:** old projects load under REQ-010. The OSC mode numbers stay stable
  (0 = Combined, 1 = Dual, 2 = Balance, 3 = Mono). Only the meaning of 0 changes, and Godot and
  the engine ship together.

## Out of scope

- Automating width or the Dual handles.
- A project-wide pan-law setting.
- Surround panning.

## Open questions

- [x] Width drag: handle-drag changes width and a drag on the fill moves both. Alt is used only
  to spread overlapping handles, and Shift stays fine-drag (`FineDrag`).
