# Stage Mic Setups and Sections — Requirements

Follows spec 051 (Virtual Stage). Two parts: the listener becomes a choice of **mic setup**
(coincident and spaced stereo arrays), and the Stage view draws each source as a **rectangle** with
a **display mode**, including a Section mode that lays out a known number of players. Placement
drags snap by default.

## Problem

The Stage listener in 051 is an ideal constant-power panner: every direction becomes a pure level
difference between left and right. Real orchestral recordings are made with mic arrays (Decca tree,
AB, ORTF, Blumlein, XY), and each one images and captures the room differently. Plugins like
Parallax VSS offer a choice; Sonara offers none.

In the Stage view a source is a bar with no depth. Users must imagine how much floor a section
really takes, so a 14-player first violin section and a solo flute look the same. Sample libraries
usually state their section size, and nothing in the view uses it. Drags are free-form, so lining
sections up on whole meters is fiddly.

## Scope

| | |
|---|---|
| Subsystem | both |
| Touches real-time audio thread | yes. The stage pass renders the direct sound and reflections through the chosen mic setup; spaced arrays add a per-capsule arrival time to every tap. The audio-thread contract, ADR 0024 (stage render pass) and the "no allocation in `render`" test still bind |
| Adds or changes an OSC message | yes: `/stage/set` gains the mic setup. `/channel/{id}/stage` is unchanged (depth, display mode and player count are UI-only) |
| Changes a persisted format (`.sonara`) | yes: the project's `stage` block gains `mic`; each channel's `stage` block gains `depth`, `display` and `players`. Missing keys load as today's behaviour, so older projects sound and look the same apart from the new default depth |

## Glossary additions

- **Mic setup**: the stereo mic array the Stage listener records with. It sits at the Listener
  position, faces the front wall, and is one of the setups in REQ-001.
- **Coincident setup**: capsules at one point; left and right differ only in level (and sign).
- **Spaced setup**: capsules some distance apart; left and right also differ in arrival time.
- **Depth** (of a stage source): the front-to-back extent of its rectangle in meters, measured
  across its line. Visual only.
- **Display mode**: how the Stage view fills a source's rectangle: **Block** or **Section**.
- **Players**: the number of players in a Section-mode source.
- **Footprint**: the floor space one player needs, 1.0 m wide × 1.2 m deep.

## Requirements

### Mic setups (engine)

#### REQ-001 — Choice of mic setup

The project's stage shall have one mic setup, chosen from:

| Setup | Kind | Capsules |
|---|---|---|
| Pan | — | Today's constant-power stereo panner (the default) |
| XY | coincident | Two cardioids at ±45° |
| Blumlein | coincident | Two figure-8s at ±45° |
| M/S | coincident | Forward cardioid (mid) and sideways figure-8 (side), decoded to L/R at width 100% |
| AB | spaced | Two omnis 60 cm apart |
| ORTF | spaced | Two cardioids 17 cm apart at ±55° |
| Decca tree | spaced | Omnis: L and R 2 m apart, C 1.5 m forward of their midpoint; C feeds both outputs at −3 dB |

Every setup faces the front wall, centred on the Listener position.

- **Acceptance:** engine test per setup: `mic_setup_from_osc_value` round-trips each value; an
  unknown value falls back to Pan.

#### REQ-002 — Coincident setups follow their polar patterns

WHILE the mic setup is coincident, each tap's left and right gains shall be the two capsules'
polar responses (decoded for M/S) toward the tap's direction, with no arrival-time difference
between left and right.

- **Acceptance:** engine test on the listener model: XY, a source at the left capsule's axis
  (−45°) → left gain 1.0, right gain 0.5 (cardioid at 90° off axis). Blumlein, a source straight
  behind on the right (135°) → it lands on the **left** output at full level (inverted polarity)
  and right ≈ 0;
  a source at 90° → left and right have opposite signs. Left/right time difference is 0 for all.

#### REQ-003 — Spaced setups add arrival-time differences

WHILE the mic setup is spaced, the audio callback shall render every tap (direct sound and
reflections) at each capsule with that capsule's own delay and its polar gain toward that capsule,
so left and right differ in time as well as level.

- **Acceptance:** engine test: AB, an impulse from a source 90° to the right at 10 m → the right
  output's peak arrives (0.60 m / 343 m/s) ≈ 1.75 ms before the left's, ±1 sample at 48 kHz.
  A source straight ahead → both peaks at the same sample.
- **Example:** Decca tree, a source straight ahead at 10 m → C's impulse arrives first, at the
  same sample in both outputs, and L's and R's arrive later (1.55 m further, ≈ 4.5 ms).

#### REQ-004 — Comparable level across setups

A centred source 5 m in front of the listener shall have, for every mic setup, a direct-sound
output level within ±1.5 dB of the Pan setup's.

- **Acceptance:** engine test over all setups with a pink-noise input, measuring the RMS of
  L + R power.

#### REQ-005 — Switching mic setup without clicks

WHEN the mic setup changes, including during playback, the audio callback shall crossfade from the
old setup to the new one, with no discontinuity larger than the one a room change already
produces.

- **Acceptance:** engine test like `room_change_crossfades`: a steady input, switch Pan → Decca
  tree mid-render, max sample step stays below the bound that test uses.

#### REQ-006 — The tail ignores the mic setup

The shared late tail on the Stage return shall be the same for every mic setup.

- **Acceptance:** engine test: fitting the tail to two rooms that differ only in the mic setup
  gives identical tail parameters.

#### REQ-007 — Pan stays the default and unchanged

WHEN a project has no `mic` value, the stage shall use Pan, and the engine's output shall equal
spec 051's for the same project.

- **Acceptance:** the existing `stage::source` tests pass unchanged with the default setup.

### Mic setup (UI)

#### REQ-008 — Picking the mic setup

The Stage view's room panel shall let the user pick the mic setup, sending it to the engine,
recording an undo step and marking a preset room as modified like any other room value.

- **Acceptance:** Godot model test: `VirtualStage.set_mic_setup(DECCA)` → `osc_args()` carries the
  Decca value, `to_json()` holds `"mic": "decca"`, `preset_label()` ends in "(modified)".

### Snapping

#### REQ-009 — Snap by default

WHILE snapping is on (the default), dragging in the Stage view shall snap a source's centre to the
1 m grid, its size and depth to whole meters, and its rotation to 15° steps. WHILE Shift is held,
these shall be 0.1 m and 1° instead.

- **Acceptance:** Godot model test of the edit operations: a move to (3.37, 4.81) → (3.0, 5.0);
  with the fine step → (3.4, 4.8); an end drag giving size 2.6 m → 3.0 m (fine: 2.6 m); rotation
  22° → 15° (fine: 22°).
- **Note:** this replaces 051's "Shift snaps rotation to 15°".

#### REQ-010 — Snap toggle

The Stage view shall have a Snap toggle. WHILE it is off, drags shall be free as in spec 051.
The toggle's state shall be remembered between sessions as UI state, not in the project.

- **Acceptance:** Godot test: toggling off → a move to (3.37, 4.81) stays there; the value is read
  back from the UI config.

### Rectangles

#### REQ-011 — Sources drawn as rectangles

The Stage view shall draw each stage source as a rectangle, size wide (along its line) and depth
deep (across it), rotated by its rotation, in its channel's colour and labelled with its name.
A source at size 0 shall still be drawn as a dot.

- **Acceptance:** Godot model test of the rectangle's corners for a rotated source
  (`StageEdit` geometry); drawing itself is a live check.

#### REQ-012 — Editing depth

In the Stage view, dragging a rectangle's front or back edge shall change its depth symmetrically
about the centre, keeping the rectangle inside the room. The selected source's depth shall also be
editable in the source panel. Depth edits are undoable.

- **Acceptance:** Godot model test: depth drag on a rotated source, and clamp against the back
  wall.

#### REQ-013 — Default depth

WHEN a channel first enters Stage, its depth shall be 2 m. WHEN a project saved before this spec
loads, each source's depth shall be 2 m.

- **Acceptance:** Godot model test on `Channel` defaults and loading a `stage` block with no
  `depth`.

#### REQ-014 — Depth is visual only

Depth shall not change what the engine renders.

- **Acceptance:** `/channel/{id}/stage` arguments are identical for two sources that differ only in
  depth (Godot test on the OSC args).

### Display modes and sections

#### REQ-015 — Display mode per source

Each stage source shall have a display mode, Block (default) or Section, set in the Stage view's
source panel. Block fills the rectangle in the channel's colour.

- **Acceptance:** Godot model test: set, undo, save and load the mode.

#### REQ-016 — Section shows its players

WHILE a source is in Section mode, the Stage view shall draw its players as person icons, evenly
spread over the rectangle in a grid of rows and columns that matches the rectangle's shape.

- **Acceptance:** Godot model test of the layout function: 12 players in an 8 × 2.4 m rectangle →
  6 columns × 2 rows, every player inside the rectangle, spacing equal within each axis. Drawing
  is a live check.

#### REQ-017 — Player count

The Stage view shall let the user set a Section's player count from 1 to 64 (default 8 when a
source first switches to Section).

- **Acceptance:** Godot model test: values outside 1–64 are clamped.

#### REQ-018 — Section stays big enough for its players

WHILE a source is in Section mode, its rectangle shall always fit its players at the 1.0 × 1.2 m
footprint, meaning ⌊size / 1.0⌋ × ⌊depth / 1.2⌋ ≥ players:

- A size or depth drag shall stop at the smallest value that still fits.
- WHEN the player count rises or the source switches to Section and the players do not fit, the
  depth shall grow first (up to what the room allows), then the size.
- IF the room cannot hold the rectangle, THEN the rectangle shall be as large as the room allows
  and the players shall be drawn closer than their footprint.

- **Acceptance:** Godot model test: 12 players at 6 × 2.4 m (6 × 2 = 12) → shrinking size to 4 m
  stops at 6 m; 16 players from 6 × 2.4 → depth grows to 3.6 m (6 × 3 = 18); a 4 × 3 m room with
  64 players → clamped to the room, no error.

#### REQ-019 — Automation is not clamped by the section

WHILE a source's size is automated, the engine shall follow the automated size even below the
section's minimum, and the view shall draw the automated size. The section minimum applies only to
edits.

- **Acceptance:** Godot test: `displayed_state` under a size lane returns the lane's value.

### Persistence and undo

#### REQ-020 — Saved and undoable

The mic setup, and each source's depth, display mode and player count, shall be saved in the
project and restored on load, and every edit to them shall be one undo step.

- **Acceptance:** Godot round-trip test: `to_json` → `from_json` keeps every new value; undo after
  each setter restores the previous one.

## Non-functional

- **Real-time safety:** the stage pass may not allocate, lock or do I/O. The existing
  `render_does_not_allocate` test covers every mic setup.
- **Performance:** coincident setups cost the same as Pan. A spaced setup may cost at most 3× the
  Pan setup's stage-pass time per source (one read per capsule); measure with 32 sources in the
  largest room at 48 kHz / 256 frames.
- **Compatibility:** older projects load with Pan, depth 2 m and Block mode, and sound identical.

## Out of scope

- Aiming or rotating the mic array, mic height separate from the listener, and custom spacings
  or angles (each setup is fixed as listed in REQ-001).
- M/S width control, outrigger mics, separate close/room mic busses, surround and binaural arrays.
- Spreading a source acoustically over its depth (REQ-014).
- A per-source footprint or instrument-specific icons.
- Exporting the new values to DAWproject.

## Open questions

- [ ] None blocking. The capsule spacings in REQ-001 are textbook values. Change them now if you
      want others (e.g. a wider AB).
