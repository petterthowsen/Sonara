# Step Sequencer View — Design

Implements [requirements.md](./requirements.md).

## Context

Engine (`Engine/src/audio/devices/note_fx/`):

- `step_sequencer.rs`: `StepSequencer` implements `NoteProcessor`.
  - `play_step(cx, at, k)` sets `self.step` and returns early for an Off step, an empty held set
    or a lost chance roll (`self.rng.next_f32() >= step.chance`). Otherwise it emits notes.
  - `run_until(cx, until)` pulls steps from `self.clock.next(cx.now(), until)` and maps each to
    pattern index `k = index mod Length`.
  - `state(&self, out: &mut NoteState)` fills `step`, `key` and `held` while `running`, which is
    true while notes are held.
  - Parameter IDs: `LENGTH` 0, `MODE` 1, `VELOCITY_SOURCE` 2, `RATE` 10, `GATE` 11, `SWING` 12,
    and `step_on/pitch/velocity/chance(k)` = 100 + 10k + 0..3.
  - Device id `sonara.builtin.step_sequencer` (`factory.rs`).
- `clock.rs`: `StepClock`.
  - `next(now, until)` computes the next step's start `at` and returns `None` when `at >= until`.
    That start is computed and then discarded today.
  - Also relevant: `step_samples()`, private `swing_beats(k)` (odd grid indices are delayed by
    `swing × rate / 2`) and `next_k`.
- `host.rs`: `NoteFxHost<P>`.
  - `NoteState { step, key, branch, held }`, with `NoteState::clear`.
  - `subscribe_data("note_state")` sets `state_subscribed`.
  - `poll_device_data()` encodes `step, key, branch, held_count, held…`.
  - Trait `NoteProcessor` has `const HAS_STATE` and `fn state(&self, out)`. It is implemented by
    `step_sequencer.rs` and `arpeggiator.rs`.
- `Engine/src/audio/mixing/mod.rs:64` polls `device.poll_device_data()` on the audio callback at
  about 20 Hz.

Godot:

- `Godot/devices/builtin/ArpeggiatorDefaultView.gd` is the template for a view on the
  `note_state` stream: `AudioEngineOSC.subscribe_device_data` in `_on_view_shown`, unsubscribe
  in `_on_view_hidden`, and filter `device_data_received` by `osc_path()`.
- `Godot/devices/builtin/NoteStrip.gd`: `NoteStrip.decode(blob)` is the one `note_state`
  decoder. It ignores bytes past the held keys.
- `Godot/devices/builtin/SaturatorDefaultView.gd` is the pattern for hand-built bound controls:
  build in code, configure from `DeviceParameter` in `_setup()`, attach with `ModAssign.attach`,
  write through `DeviceInstance.set_parameter_real`, refresh in `_on_device_parameter_changed`.
- `Godot/devices/DeviceViewFactory.gd`: `BUILTIN_PANEL_SCENES`. `_use_simple_view` already honours
  the "Simple" toggle once a device has a panel view.
- `Godot/devices/DeviceView.gd`: `_on_bind`, `_on_unbind`, `_on_view_shown`, `_on_view_hidden`
  and `_on_device_parameter_changed`, which the base class connects in `bind_to_device`.
- `Godot/devices/device_lane/DevicePanel.gd`: `HEIGHT := 350.0`.
- Components:
  - `components/CompactHSlider.gd` (`CompactSlider`: `step`, `default_value`, `value_text_callback`,
    the mod contract)
  - `components/SegmentedControl.gd`
  - `components/ValueTooltip.gd` (`attach`, `set_text`, `place_above`)
  - `components/FloatingValueEditor.gd` (`open`, `committed`, `position_above`)
  - `components/FineDrag.gd` (`begin_at`, `update`)
  - `components/ThemedColors.gd`
  - `core/theme/ThemeBuilder.gd` (`_set_colors(t, &"CompactSlider", …)`)
- `Godot/input/HotkeyActions.gd`: `CONTEXTS` (`device_panel`), `STATES`, `CONTEXT_LABELS`,
  `GESTURES`. `Hotkeys.begin_state` / `end_state` drive the help bar during a gesture.
- `Godot/data/AudioConfig.gd`: `config["latency_ms"]` holds the running output latency.
- `Godot/clip_editor/value_lanes/ValueLaneStemArea.gd` and `ValueLaneEdits.gd` are the clip
  editor's velocity lanes.

## Approach

**One reusable lane component, three lanes.**
- Add `components/StepLane.gd`, a custom-drawn `Control` with two modes:
  - `TOGGLES` draws the On row.
  - `BARS` draws the Pitch and Lower lanes.
- It knows nothing about devices. It holds `values: PackedFloat32Array` (real units), the range,
  an `origin` (the bars' base: 0 for Pitch, the minimum for percent lanes), `value_step` (1), the
  default and the display state (Off mask, Length, playhead, flash levels).
- It reports edits through signals, following the component rules in `godot-ui-components.md`.
- All lanes share one column geometry (`column_rect(k)` / `step_at_x(x)`), so a column lines up
  in every lane.
- The gesture maths is static and pure (`StepLane.value_at_y`, `StepLane.fill_between`), so it
  can be tested headless, like `ValueLaneEdits`.

Rejected alternatives:
- Reusing `ValueLaneStemArea`: it is bound to `MidiEditor` notes, undo history and a
  `NoteValueDescriptor` with per-note stems.
- Generalising it: that would mean rewriting a 600-line clip-editor control for a different
  model.
- `VSlider.gd` (`VolumeSlider`): a single fader with a text field. Sixteen of them can't be
  painted across, and they'd duplicate modulation chrome the lanes don't use (modulation is out
  of scope).
- `DragToggleButton`: its painting rule ("the state the first press produced") is copied into
  `TOGGLES` mode. The class itself paints across scene-tree groups of `Button`s, which is heavier
  than one drawn row and can't share the bar lanes' column geometry.

**Engine timing, view interpolation.**
- The step sequencer already knows the exact start of the next step: `StepClock::next` computes
  it, then discards it.
- Each poll now also reports:
  - which steps were reached and fired since the last poll (two `u16` bit masks);
  - how long ago the current step started;
  - when the next step falls;
  - the two step gaps after it, which differ when Swing is set.
- A small pure class, `StepPlayhead.gd`, turns that into the step to show at any moment. It
  delays everything by `AudioConfig.config["latency_ms"]`.
- Rejected: recomputing the timing in GDScript from Rate, Swing and the tempo map. That would
  duplicate `StepClock` (tempo ramps, swing parity of the grid index, the free-running anchor
  while stopped) and would drift whenever the two disagree.

**Fired flashes.**
- A fired bit can arrive after the interpolated playhead has already reached that step, or
  before.
- `StepPlayhead` keeps a pending-flash mask. A pending step flashes when the displayed playhead
  enters it. If the playhead is already on it, has passed it, or doesn't get there within 100 ms,
  it flashes at once.
- Interpolation never creates a flash on its own (REQ-017).

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `StepSequencer.reached`, `.fired: u16` | audio callback (set in `play_step`) | drained by `state()` from `poll_device_data`, also on the audio callback | yes, bit ops |
| `StepSequencer.step_at`, `.block_end: u64` | audio callback (`play_step`, `run_until`) | read in `state()` | yes |
| `StepClock.upcoming: Option<Step>` | audio callback (`next`) | read in `state()` through `StepClock::upcoming()` | yes |
| Drain on subscribe | command thread, inside `subscribe_data` under the state lock | calls `processor.state(&mut self.state)` once and discards it | yes: `held` has capacity `HELD_CAPACITY`, no allocation |
| `StepPlayhead` model, lane values | Godot main thread | `device_data_received`, `parameter_changed` | n/a |

`poll_device_data` already allocates a `Vec` and a `String` on the audio callback for every
stream. That is outside this spec and unchanged; it's noted under Risks.

## Data and protocol changes

### `note_state` blob (engine → Godot), extended

The existing prefix is unchanged. Six little-endian `u16` fields are appended after the held
keys:

| Offset | Field | Meaning |
|---|---|---|
| 0 | `u8 step` | current step, 0-based (0xFF none) |
| 1 | `u8 key` | last sounding key (0xFF none) |
| 2 | `u8 branch` | (0xFF none) |
| 3 | `u8 held_count` | |
| 4… | `held_count × u8` | held keys ascending |
| +0 | `u16 reached` | bit k: step k was reached since the last poll |
| +2 | `u16 fired` | bit k: step k fired since the last poll |
| +4 | `u16 elapsed_ms` | from the current step's start to the end of the last rendered block |
| +6 | `u16 next_in_ms` | from the end of the last rendered block to the next step's start |
| +8 | `u16 gap_a_ms` | from the next step to the one after it |
| +10 | `u16 gap_b_ms` | the gap after that; the gaps then alternate a, b, a, … |

- Timing fields are `0xFFFF` when unknown: not running, or an effect without a step clock. Values
  are rounded milliseconds, saturated at `0xFFFE`.
- The Arpeggiator fills only the masks it can (none: both 0) and `0xFFFF` timing. Its view keeps
  working because `NoteStrip.decode` reads the prefix only, and the new fields are optional for
  it.
- Gaps: `StepClock::gap_samples(k)` = `(rate_beats + swing_beats(k+1) − swing_beats(k)) × 60 /
  tempo × sample_rate` at the current tempo. `gap_a` is the gap from the upcoming index `n`,
  `gap_b` the gap from `n+1`.
- No new OSC address. The subscribe and unsubscribe messages are unchanged.
- `docs/subsystems/osc-protocol.md` doesn't document `note_state` at all yet (spec 027 missed
  it). This spec adds the full layout under "Device Data Stream".

### `NoteProcessor` trait

- `fn state(&self, out)` becomes `fn state(&mut self, out)`. It drains the since-last-poll marks.
- The doc comment states that it is called once per poll and once on subscribe, to drop stale
  marks.
- `NoteState` gains `reached: u16`, `fired: u16`, `elapsed_ms: u16`, `next_in_ms: u16`,
  `gap_a_ms: u16` and `gap_b_ms: u16`. `clear()` resets the masks to 0 and the timing fields to
  `0xFFFF`.

### Godot

- `NoteStrip.decode` also returns `reached`, `fired`, `elapsed_ms`, `next_in_ms`, `gap_a_ms` and
  `gap_b_ms` when the blob carries them. Otherwise masks are 0 and timings -1. Existing keys are
  unchanged.
- No new synced properties. The view writes step parameters through
  `DeviceInstance.set_parameter_real`, which already sends OSC and emits `parameter_changed`.
- No persisted keys. The Lower-lane choice is a view field.

## View layout (fits `DevicePanel.HEIGHT` = 350)

```
┌ left column (≈120 px) ┐┌ step area: 16 columns × 22 px, 2 px gaps (≈382 px) ───────────┐
│ Length   [   8   ]    ││  1  2  3  4 │ 5  6  7  8 │ 9 …                    step numbers 14│
│ Rate     [ 1/16 ▾]    ││ ■  □  ■  ■ │ ■  □  □  ■ │ …                        On row 18   │
│ Gate     [ 100 % ]    ││ ┊ ▆       ▂ │    ▅       │   +24 / +12 guides / 0 line           │
│ Swing    [  0 %  ]    ││ ┊    ▇  ▃  │ ▃     ▆    │                         Pitch ≈130   │
│ Mode   [Chord|Mono]   ││ [Velocity|Chance]                                  switch 18   │
│ Vel  [In×Step|Step]   ││ ▇ ▇ ▅ ▇ │ ▃ ▇ ▇ ▅ │ …                             Lower ≈90   │
└───────────────────────┘└───────────────────────────────────────────────────────────────┘
```

- Beat groups of 4 steps get a slightly wider gap and a faint separator, so the columns read in
  beats.
- Pitch and Lower expand to fill the panel's remaining height. Minimum heights are 100 and 60,
  so the view's minimum height (≈ 14 + 18 + 100 + 18 + 60 + separations ≈ 230) stays below the
  panel's content height.
- Left column:
  - `CompactSlider` for Length (1–16, `step` 1), Gate and Swing (whole percent);
  - an `OptionButton` for Rate, filled from `DeviceParameter.enum_values`;
  - `SegmentedControl` for Mode and Velocity Source (labels "In × Step" and "Step").
  - Sliders get `ModAssign.attach`, so modulation assign works on them as on other device
    views.

## StepLane (`components/StepLane.gd`)

- `class_name StepLane extends Control`. `enum Mode { TOGGLES, BARS }`.
- Exports:
  - `mode`, `step_count` (16), `group_size` (4);
  - `min_value`, `max_value`, `origin`, `default_value`, `value_step` (1.0);
  - `guide_values: PackedFloat32Array` (Pitch: ±12);
  - `unit` and `value_text_callback: Callable(value) -> String`.
- Data setters, none of which emit:
  - `set_values_no_signal(PackedFloat32Array)` and `set_value_no_signal(k, v)`;
  - `off_mask: int` (BARS dims those bars, REQ-012);
  - `length: int` (steps ≥ length dim more strongly, REQ-013);
  - `playhead: int` (-1 none);
  - `set_flash(k, level)` (0..1).
- Signals:
  - `value_edited(step: int, value: float)`, emitted only on a real change;
  - `edit_started`, `edit_ended`.
- Gestures (BARS):
  - Press: set the step under the pointer to `value_at_y(y)`, snapped to `value_step` and
    clamped.
  - Drag: `fill_between(k0, v0, k1, v1)` sets every column from the last processed column to the
    current one, with values linearly interpolated along the path (REQ-005).
  - Shift-press: grab only that step. `FineDrag.begin_at` on the bar top, then relative motion at
    fine scale, with the value accumulated underneath so slow motion still reaches the next whole
    unit (REQ-008).
  - Ctrl/Cmd-press or drag: every crossed step is set to `default_value` (REQ-009).
  - Double-click: `FloatingValueEditor` above the column, pre-filled with the text. The commit
    parses a number (a trailing `%` or `st` is allowed), rounds and clamps it (REQ-010).
  - Hover and drag: `ValueTooltip` above the lane with `"Step %d  %s"` (REQ-011).
- Gestures (TOGGLES):
  - Press flips the step and remembers the new state; drag sets every crossed step to it
    (REQ-004).
  - Steps between two motion events are filled, as in BARS.
- Drawing:
  - background in `bg`; columns as rounded rects; group separators in `grid`;
  - guides and the zero line in `grid`;
  - bars in `bar` from `origin` to the value; Off bars in `bar_off`;
  - beyond-length columns at a lower alpha, plus a `beyond` overlay;
  - a playhead column tint (`playhead`) and a fired overlay (`fired` × flash level);
  - toggles: `toggle_on` and `toggle_off` cells.
- Theming:
  - theme type `StepLane` through `ThemedColors` with items `bg`, `grid`, `bar`, `bar_off`,
    `toggle_on`, `toggle_off`, `playhead`, `fired` and `beyond`;
  - defined in `ThemeBuilder.gd` from the palette roles `well`, `grid_line`, `accent_primary`,
    `text_disabled`, `control_bg`, `text_bright` and `accent_secondary`;
  - `Sonara_Theme.tres` regenerated.
- Help bar:
  - context `step_lane` (parent `device_panel`) and state `step_lane_draw`;
  - `GESTURES` rows: drag "draw steps", Shift+drag "fine adjust", Ctrl+drag "reset to default",
    double-click "exact value".

## StepPlayhead (`devices/builtin/StepPlayhead.gd`)

- `class_name StepPlayhead extends RefCounted`. It is pure, and every method takes `now_ms`, so
  tests drive a fake clock.
- `feed(state: Dictionary, now_ms: float, latency_ms: float, length: int)`:
  - If `step` is -1, clear.
  - Otherwise build a schedule anchored at `D = now_ms + latency_ms`:
    - the current step `s` from `D − elapsed_ms`;
    - step `(s+1) mod length` at `D + next_in_ms`;
    - then alternating `gap_a`, `gap_b`.
  - The previous schedule stays in force until the new one's first entry, so a late blob never
    jumps the playhead backwards before its time.
  - The `fired` bits go into the pending-flash mask.
  - If the timing is unknown (-1), show `s` and don't advance.
- `step_at(now_ms) -> int`: -1 when cleared, or when `now_ms` is 500 ms past the last feed
  (REQ-016).
- `take_flashes(now_ms) -> PackedInt32Array`: returns the steps whose flash starts now, following
  the rule in Approach. The view turns each into a 150 ms decaying level (REQ-017).

## StepSequencerDefaultView (`devices/builtin/StepSequencerDefaultView.gd` / `.tscn`)

- Builds the left column, the step-number row (drawn by a small inner `Control` using the lanes'
  geometry), the On row (`StepLane` TOGGLES), the Pitch lane (BARS, −24..24, origin 0, guides
  ±12, `"%+d st"`), the switch (`SegmentedControl` Velocity | Chance) and the Lower lane (BARS,
  0..100, origin 0, `"%d %%"`).
- `_setup()` (from `_on_bind`) configures controls from the device's parameters and calls
  `_refresh()`. `_refresh()` reads every step parameter with `get_parameter_real` and pushes the
  values, `off_mask` and `length` into the lanes without signals.
- `_on_device_parameter_changed(id, _)` updates only what changed: one lane column for a step id,
  `length` for 0, `off_mask` for an On id, and the left-column control for the others (REQ-014).
- Lane edits go to `device.set_parameter_real(step_param(k, field), value)`. The On row writes
  1.0 or 0.0.
- `_on_view_shown` / `_on_view_hidden` follow `ArpeggiatorDefaultView`. Hiding also clears the
  `StepPlayhead` and the lanes' playhead and flashes (REQ-018).
- `_on_data` decodes with `NoteStrip.decode` and feeds `StepPlayhead` with
  `Time.get_ticks_msec()`, the latency from the `AudioConfig` autoload (looked up through the
  scene tree in test mode, 0 when absent) and the current Length.
- `_process` runs only while the playhead model is active or a flash is decaying. Each frame it
  pushes `step_at(now)` and the flash levels into all three lanes and the number row, and stops
  when idle.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/devices/note_fx/clock.rs` | `upcoming: Option<Step>` set in `next()` when it declines a step at or after `until`, cleared in `reset()`. `pub fn upcoming(&self) -> Option<Step>`, `pub fn gap_samples(&self, k: i64) -> f64`. Tests. |
| `Engine/src/audio/devices/note_fx/host.rs` | `NoteState` gains the six fields; `clear()` sets them. `NoteProcessor::state` takes `&mut self`. `subscribe_data` drains one `state()` on subscribe. `poll_device_data` appends the six `u16` LE. Test that a pre-subscribe step leaves no marks. |
| `Engine/src/audio/devices/note_fx/step_sequencer.rs` | `reached`, `fired`, `step_at`, `block_end` fields. `play_step` sets the bits and `step_at`; `run_until` records `block_end`. `state(&mut self)` fills the masks and timing, then zeroes the masks. Reset and the held-set-empty path clear them. Tests (REQ-015). Update the existing stream test's expected bytes. |
| `Engine/src/audio/devices/note_fx/arpeggiator.rs` | `state(&mut self, …)` signature only. |
| `Godot/devices/builtin/NoteStrip.gd` | `decode` returns the optional new fields. |
| `Godot/components/StepLane.gd` (new) | The lane component. |
| `Godot/core/theme/ThemeBuilder.gd` | `StepLane` colours. |
| `Godot/assets/Sonara_Theme.tres` | Regenerated with `core/theme/build_theme_resource.gd`. |
| `Godot/input/HotkeyActions.gd` | `step_lane` context, `step_lane_draw` state, labels, gesture rows. |
| `Godot/devices/builtin/StepPlayhead.gd` (new) | Interpolation and pending flashes. |
| `Godot/devices/builtin/StepSequencerDefaultView.gd` / `.tscn` (new) | The view. |
| `Godot/devices/DeviceViewFactory.gd` | `"sonara.builtin.step_sequencer"` in `BUILTIN_PANEL_SCENES`. |
| `Godot/components/gallery/ComponentGallery.tscn` / `.gd` | A `StepLane` card (Pitch-style bars with guides, a toggles row). |
| `Godot/tests/test_step_lane.gd` (new) | Lane gesture tests. |
| `Godot/tests/test_step_playhead.gd` (new) | Fake-clock interpolation and flash tests. |
| `Godot/tests/test_step_sequencer_view.gd` (new) | View binding, switch, refresh, stream tests. |
| `docs/subsystems/osc-protocol.md` | Document the `note_state` stream with its full layout. |
| `docs/subsystems/godot-ui-components.md` | `StepLane` in Shared pieces and the custom-drawn list. |
| `docs/subsystems/godot-device-views.md` | A "Step Sequencer view" section. |
| `docs/specs/027-note-effects/tasks.md` | T-028 marked superseded by spec 039. |

## Migration and compatibility

- Nothing is persisted. Existing projects open unchanged and show the new view, unless the user
  has the Simple toggle on for this device.
- Older Godot builds decoding a newer blob ignore the trailing bytes. The Godot decoder handles a
  blob without the trailing bytes too (masks 0, timing -1), so a version mismatch degrades to an
  un-interpolated playhead with no flashes.

## Test plan

- **Unit (engine):**
  - `cargo test step_sequencer`
    - `the_stream_reports_steps_reached_and_fired_since_the_last_poll`: the REQ-015 example
      (1–4 reached, 1 and 4 fired, empty on the next poll).
    - `the_stream_reports_the_step_timing`: 1/16 at 120 BPM, so `gap_a` = `gap_b` = 125; with
      Swing 50 % the gaps are 156 and 94 (±1).
    - `the_note_state_stream_shows_the_step_and_held_keys`: updated bytes.
  - `cargo test clock`
    - `upcoming_is_the_step_next_declined`
    - `gap_samples_include_swing`
  - `cargo test note_fx::host`
    - `subscribing_drops_marks_from_before_the_subscription`
  - `cargo test arpeggiator`: still passes.
- **Godot:**
  - `Godot/tests/run_all.sh step_lane`: REQ-004 (paint on and off), REQ-005 (a single motion
    from step 2 to 6 fills 3–5 with stepped values), REQ-006 and REQ-007 (whole units, top,
    middle and bottom mapping), REQ-008 (Shift only moves one step, less than unmodified),
    REQ-009 (Ctrl drag resets), REQ-012 (Off mask doesn't change on draw), REQ-013 (beyond-length
    is still editable), and no signal when the value doesn't change.
  - `Godot/tests/run_all.sh step_playhead`: the REQ-016 timeline (10, 25, 150 ms; 60 ms with
    latency; resync to 5; clear on none; clear after 500 ms of silence), the REQ-017 flashes
    (2 and 4 flash, 3 doesn't; interpolation alone never flashes), and a blob without timing.
  - `Godot/tests/run_all.sh step_sequencer_view`: REQ-002 (six controls, 16 columns per lane,
    minimum height ≤ 350 − header), REQ-003 (switch to Chance redraws and edits Chance), REQ-014
    (setting step 7 Velocity redraws), REQ-018 (subscribe and unsubscribe, foreign path ignored).
  - `Godot/tests/run_all.sh arpeggiator`: still passes.
- **Live:** with the engine and Godot running:
  - REQ-001 (Simple toggle round trip);
  - REQ-010 (type `-9`);
  - REQ-011 (readout follows the drag);
  - REQ-016 (Length 6 walks 1–6; 1/32 at 160 BPM visits every step in time with the audio;
    release clears);
  - REQ-017 (steps at Chance 50 % flash only when heard).

## Risks

| Risk | Mitigation |
|---|---|
| The playhead drifts from the audio under a large PipeWire quantum, since the engine's `latency_ms` may not include the graph quantum | Verify live at the forced 2048 quantum. If it lags, add `graph_quantum / graph_rate` from `AudioConfig.config` to the latency (a one-line change in the view) |
| Changing `NoteProcessor::state` to `&mut self` touches the Arpeggiator | Signature only; `cargo test arpeggiator` must stay green |
| `poll_device_data` allocates on the audio callback (existing, all streams) | Out of scope. Not made worse: the blob grows by 12 bytes in an existing `Vec::with_capacity` |
| Redrawing three lanes every frame while playing | `_process` runs only while active. Each lane is one `_draw` of about 16 rects |
| A tempo change mid-step makes the interpolated playhead briefly wrong | It resyncs on the next poll, at most about 50 ms later |

## Open questions

None.
