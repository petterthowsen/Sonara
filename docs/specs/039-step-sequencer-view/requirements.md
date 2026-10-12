# Step Sequencer View — Requirements

## Problem

The Step Sequencer (spec 027) has 70 parameters: six pattern and timing controls plus On, Pitch,
Velocity and Chance for each of 16 steps. Today it shows only the generated Simple View, which
puts each step's four values in a column of knobs. That makes it slow to sketch a pattern and
hard to read at a glance, and nothing shows which step is playing. Spec 027 planned a custom view
(REQ-038, task T-028), but it was never built. This spec replaces REQ-038 and adds feedback for
steps that actually played.

## Scope

| | |
|---|---|
| Subsystem | Godot (the device panel view) and Engine (steps reached and fired, and step timing, added to the Step Sequencer's `note_state` stream) |
| Touches real-time audio thread | yes, but only to record which steps were reached and fired. Nothing new allocates or locks |
| Adds or changes an OSC message | yes. The `note_state` device data stream payload gains "steps reached" and "steps fired" since the last poll plus the step timing, which the Arpeggiator view must keep decoding |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no |

## Terms

- **Step lane**: a row of 16 cells, one per step, aligned under the same columns as the other lanes.
- **On row**: the step lane of On toggles.
- **Pitch lane**: the upper bar lane, showing each step's Pitch.
- **Lower lane**: the bar lane under the Pitch lane, showing Velocity or Chance.
- **Playhead**: the highlight on the current step's column.
- **Fired step**: an On step that played notes on its last pass (notes were held and it won its
  chance roll). A **reached step** is any step the sequence arrived at, whether it fired or not.

## Requirements

### Layout

#### REQ-001 — Panel view

The device panel shall show the Step Sequencer view as the panel view of the built-in Step
Sequencer. The DevicePanel "Simple" toggle shall still switch to the generated Simple View.

- **Acceptance:** live. Add a Step Sequencer: the step view appears. Turn on Simple: the knob
  grid appears. Turn it off again: the step view is back.

#### REQ-002 — Every control in one panel

The Step Sequencer view shall show every parameter of the device without pages or tabs. The
pattern and timing controls (Length, Mode, Velocity Source, Rate, Gate, Swing) sit in a column on
the left. To their right, from top to bottom, are a step-number row, the On row, the Pitch lane
and the Lower lane, sharing the same 16 columns. The view shall fit the device panel's fixed
height.

- **Acceptance:** Godot test. The view creates a control for each of the six shared parameters
  and 16 columns in each lane. Its minimum height is no more than the panel's content height.

#### REQ-003 — Lower lane switch

The Lower lane shall show Velocity by default. A two-option switch on the Lower lane shall change
it between Velocity and Chance. The choice lasts while the view exists and is not saved.

- **Acceptance:** Godot test. A new view shows Velocity values. Choosing Chance redraws the
  lane from the Chance parameters, and dragging in the lane then edits Chance.

### Editing

#### REQ-004 — Toggle and paint On

WHEN the user presses an On cell, the On row shall flip that step. WHILE the button stays held,
every On cell the pointer passes shall be set to the state the first press produced.

- **Acceptance:** Godot test. Steps 1–8 are off. A press on step 1 and a drag to step 8 turn all
  eight on. A press on step 3 (now on) and a drag to step 5 turn steps 3–5 off.

#### REQ-005 — Draw bars

WHEN the user presses in a bar lane, the lane shall set the step under the pointer to the value
under the pointer. WHILE dragging, the lane shall set every step the pointer crosses, including
steps it skipped between two mouse events, each to the value along the path at that step.

- **Acceptance:** Godot test. A press at step 2 at the top of the Pitch lane, then one motion
  event at step 6 at the zero line, sets steps 2–6. Step 2 gets +24, step 6 gets 0, and steps 3–5
  get values that step down between them.

#### REQ-006 — Pitch lane values

The Pitch lane shall edit Pitch in whole semitones from −24 to +24. Bars shall grow up or down
from a zero line, with guide lines at ±12.

- **Acceptance:** Godot test. Every value the lane writes is a whole semitone. A press halfway
  between the zero line and the top writes +12.

#### REQ-007 — Velocity and Chance values

The Lower lane shall edit Velocity or Chance in whole percent from 0 to 100. Bars shall grow up
from the bottom.

- **Acceptance:** Godot test. A press at the top of the lane writes 100 %, a press at the bottom
  writes 0 %, and every written value is a whole percent.

#### REQ-008 — Fine adjust one step

WHEN the user presses a bar with Shift held, the lane shall adjust only that step. Vertical motion
changes it relative to its current value at fine-drag speed, without jumping on the press and
without painting other steps.

- **Acceptance:** Godot test. Shift-press step 4 at Pitch +5, then drag up by 30 px: step 4 rises
  by fewer semitones than an unmodified drag of 30 px would give, and steps 3 and 5 don't change.

#### REQ-009 — Reset to default

WHEN the user Ctrl/Cmd-presses in a bar lane, the lane shall reset the step under the pointer to
its default (Pitch 0, Velocity 100 %, Chance 100 %). WHILE dragging, every step crossed is reset.

- **Acceptance:** Godot test. Steps 1–4 have Pitch +7. Ctrl-press on step 1 and a drag to step 3
  set steps 1–3 to 0. Step 4 stays at +7.

#### REQ-010 — Type an exact value

WHEN the user double-clicks a bar, the lane shall open a value editor for that step. Confirming
it sets the typed value, clamped to the lane's range and rounded to a whole unit.

- **Acceptance:** live. Double-click step 5 in the Pitch lane, type `-9` and press Enter: step 5
  shows −9.

#### REQ-011 — Value readout

WHILE the pointer hovers a bar lane or a drag is in progress, the lane shall show the step number
and that step's value in a floating readout that doesn't shift the layout, for example
`Step 5  +7 st` or `Step 12  80 %`.

- **Acceptance:** live. Hover the Pitch lane over step 5: the readout shows its value. Drag across
  steps and the readout follows the step being set.

#### REQ-012 — Off steps

The bar lanes shall draw the bars of Off steps dimmed. Drawing a bar shall not change the step's
On state.

- **Acceptance:** Godot test. Step 3 is off. Drawing across steps 1–4 in the Pitch lane changes
  step 3's Pitch, and step 3 stays off.

#### REQ-013 — Steps beyond Length

The step lanes shall show steps beyond Length dimmed more strongly than Off steps, and they stay
editable. WHEN Length changes, the dimming shall update at once.

- **Acceptance:** Godot test. Set Length to 6 and steps 7–16 report the beyond-length state.
  Drawing on step 10 still changes its value.

#### REQ-014 — Follow outside changes

WHEN a step parameter or Length changes from anywhere else (the Simple View, the parameter list,
a preset, automation, a project load or an engine correction), the Step Sequencer view shall show
the new value.

- **Acceptance:** Godot test. Setting step 7's Velocity to 40 % on the device instance redraws
  step 7 at 40 % in the Lower lane while it shows Velocity.

### Live feedback

#### REQ-015 — Steps reached and fired in the stream

The Step Sequencer's `note_state` stream shall report, along with the current step, which steps
were reached and which fired since the previous poll. That way a step that starts and ends
between two polls is still reported. An Off step, a step that lost its chance roll and a step
with no held notes are reached but not fired. Each poll starts the record afresh.

- **Acceptance:** engine unit test. Holding 60, step 2 has Chance 0 % and step 3 is off. Run
  steps 1–4 in one block, then poll: steps 1–4 are reported reached and steps 1 and 4 fired.
  Poll again with no new step: both sets are empty and the current step is still 4. The stream
  also reports how long ago the current step started and when the next two steps fall: at Rate
  1/16, 120 BPM and Swing 0, the gaps after the next step are both 125 ms.

#### REQ-016 — Playhead

WHILE the Step Sequencer is running (notes are held) and the view is shown, the view shall
highlight the current step's column across all lanes. Each stream update shall say when the
next steps fall. Between updates the view shall advance the playhead itself from that timing and
Length, so it moves once per step even when steps are shorter than the poll interval. The
playhead shall be delayed by the engine's reported output latency, so it lines up with what is
heard. WHEN an update arrives, the view shall resync to it. WHEN the stream reports no current
step, or no update arrives for 0.5 s, the highlight shall clear.

- **Acceptance:** Godot test with a fake clock and zero latency. A blob at t = 0 for step 1, with
  the next step due in 20 ms and 125 ms between steps: with no further blob the playhead shows
  step 1 at t = 10 ms, step 2 at t = 25 ms and step 3 at t = 150 ms. With 40 ms latency, step 2
  shows from t = 60 ms instead. A blob for step 5 then moves it to step 5, and a blob with no step
  clears it.
- **Acceptance:** live. At Rate 1/32 and 160 BPM with Length 8, hold a note: the highlight visits
  every step in order and doesn't drift from the audio.

#### REQ-017 — Fired and skipped steps

WHEN the stream reports a fired step, the view shall flash that step's On cell and bars more
strongly than the playhead and let the flash fade over about 150 ms. Steps fired between two
polls flash too. A step reached but not fired shall show only the playhead. The view shall not
flash a step from interpolation alone, because only the engine knows the chance roll.

- **Acceptance:** Godot test with fake stream blobs. A blob that reports steps 2–4 reached and
  steps 2 and 4 fired puts steps 2 and 4 in the fired state and leaves step 3 unflashed. A step
  the playhead reaches only through interpolation doesn't flash.

#### REQ-018 — Subscribe only while shown

The Step Sequencer view shall subscribe to the `note_state` stream only while it is shown. It
shall ignore blobs for other devices.

- **Acceptance:** Godot test. Showing the view subscribes, hiding it unsubscribes and clears the
  playhead, and a blob for another device path changes nothing.

## Non-functional

- **Real-time safety:** recording which steps were reached and fired means setting bits in two
  fixed-size fields on the audio thread, with no allocation, locks or I/O. The stream keeps its
  existing poll path.
- **Latency:** stream updates arrive at the polling rate (about 20 Hz). The interpolated
  playhead moves on time between updates. A fired flash can be up to one poll interval (about
  50 ms) late, but it is never lost.
- **Compatibility:** the Arpeggiator view and its tests keep decoding `note_state` blobs
  correctly after the change. No saved data changes.
- **Look:** colours come from theme roles and follow theme changes, as in
  `godot-ui-components.md` principle 5.

## Out of scope

- Lane context menu (reset lane, randomize, shift, reverse), a draggable Length marker on the
  step-number row, and a scale guide in the Pitch lane. These are possible follow-ups.
- Undo for step edits. The app has no undo for parameter edits yet.
- Assigning modulation from the lanes, and drawing modulation ranges on the bars.
- More than 16 steps, or per-step gate or length.
- Saving the Lower-lane choice.
- Changes to the Arpeggiator view beyond keeping it decoding the stream.

## Open questions

None. The decisions made during review:
- Drawing a bar leaves the step's On state alone.
- The Pitch lane always shows ±24, with Shift for fine adjustment.
- Fired-step feedback is in scope; the context menu, Length marker and scale guide are not.
- The view interpolates the playhead between stream updates, and the engine reports steps
  reached and fired since the last poll, so fast rates neither skip on screen nor lose flashes.
