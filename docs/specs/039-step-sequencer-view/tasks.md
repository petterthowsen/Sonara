# Step Sequencer View — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — engine: marks and timing on `note_state`

- [x?] **T-001** [REQ-015, REQ-016] Make `StepClock` keep the step it declines and compute gaps.
  - Add `upcoming: Option<Step>`, set in `next()` when the computed step starts at or after
    `until`, and cleared in `reset()` and while idle.
  - Add `pub fn upcoming(&self) -> Option<Step>`.
  - Add `pub fn gap_samples(&self, k: i64) -> f64`: rate plus the swing difference between
    `k + 1` and `k`, at the current tempo.
  - Tests: `upcoming_is_the_step_next_declined`, `gap_samples_include_swing` (1/16 at 120 BPM,
    Swing 50 %: 7500 and 4500 frames at 48 kHz).
  - _Files_: `Engine/src/audio/devices/note_fx/clock.rs`
  - _Output_: the next step's start and the two following gaps can be read without advancing the
    clock
  - _Verify_: `cargo test clock` passes; `cargo fmt`
  - _Depends on_: —

- [x?] **T-002** [REQ-015] Extend `NoteState` and the `note_state` blob.
  - Add the fields `reached`, `fired`, `elapsed_ms`, `next_in_ms`, `gap_a_ms` and `gap_b_ms`.
    `clear()` sets the masks to 0 and the timings to `0xFFFF`.
  - `NoteProcessor::state` takes `&mut self`. Update the trait doc and the `arpeggiator.rs`
    signature.
  - `poll_device_data` appends six little-endian `u16`s after the held keys.
  - `subscribe_data("note_state")` drains one `state()` into `self.state` and discards it.
  - Test: `subscribing_drops_marks_from_before_the_subscription`.
  - _Files_: `Engine/src/audio/devices/note_fx/host.rs`,
    `Engine/src/audio/devices/note_fx/arpeggiator.rs`
  - _Output_: a 12-byte longer blob. For the Arpeggiator: masks 0 and timings `0xFFFF`
  - _Verify_: `cargo test note_fx::host` and `cargo test arpeggiator` pass; `cargo fmt`
  - _Depends on_: —

- [x?] **T-003** [REQ-015] Record reached and fired steps and the timing in the Step Sequencer.
  - Add the fields `reached`, `fired`, `step_at` and `block_end`.
    - `play_step` sets the reached bit and `step_at` first, and the fired bit after the chance
      roll passes with at least one held note.
    - `run_until` stores `until` in `block_end`.
  - `state(&mut self)` fills the masks and then zeroes them.
    - The timings are converted to ms with the sample rate and saturated at `0xFFFE`.
    - `elapsed` is `block_end − step_at`.
    - `next_in` is `upcoming.at − block_end`.
    - `gap_a` and `gap_b` come from `gap_samples(upcoming.index)` and
      `gap_samples(upcoming.index + 1)`.
    - All timings are `0xFFFF` while not running.
  - `forget_all` and the held-set-empty path clear the masks.
  - Update `the_note_state_stream_shows_the_step_and_held_keys` for the new bytes.
  - Add `the_stream_reports_steps_reached_and_fired_since_the_last_poll`: the REQ-015 example,
    then an empty second poll with step 4 still current.
  - Add `the_stream_reports_the_step_timing`: gaps 125 and 125 ms at Swing 0, 156 and 94 ±1 at
    Swing 50 %.
  - _Files_: `Engine/src/audio/devices/note_fx/step_sequencer.rs`
  - _Output_: the stream carries the REQ-015 marks and the timing
  - _Verify_: `cargo test step_sequencer` and `cargo test note_fx` pass (conformance included);
    `cargo fmt`
  - _Depends on_: T-001, T-002

- [x?] **T-004** [REQ-015] Decode the new fields in Godot.
  - `NoteStrip.decode` also returns `reached`, `fired`, `elapsed_ms`, `next_in_ms`, `gap_a_ms`
    and `gap_b_ms`.
    - When the trailing 12 bytes are missing, masks are 0 and timings -1.
    - `0xFFFF` decodes to -1.
  - Add a decode case to an existing arpeggiator test, or a new
    `tests/test_note_state_decode.gd`, covering a short blob and a long blob.
  - _Files_: `Godot/devices/builtin/NoteStrip.gd`, `Godot/tests/test_note_state_decode.gd` (new)
  - _Output_: one decoder for both blob lengths
  - _Verify_: `Godot/tests/run_all.sh note_state_decode arpeggiator` passes
  - _Depends on_: T-002

## Phase 2 — the lane component

- [x?] **T-005** [REQ-005, REQ-006, REQ-007] Build `StepLane` with pure maths and BARS drawing.
  - Mode enum, exports, `no_signal` data setters, column geometry (`column_rect`, `step_at_x`,
    group gaps).
  - Static `value_at_y` (snapped and clamped) and `fill_between`.
  - BARS `_draw`: background, group separators, guides and zero line, bars from `origin`, Off and
    beyond-length dimming, playhead tint and fired overlay.
  - `ThemedColors` with theme type `StepLane`.
  - _Files_: `Godot/components/StepLane.gd` (new)
  - _Output_: a lane that draws values. No input yet
  - _Verify_: `Godot/tests/run_all.sh step_lane` passes the maths section (top, middle and bottom
    mapping; whole units; `fill_between` from 2 to 6)
  - _Depends on_: —

- [x?] **T-006** [REQ-005, REQ-008, REQ-009, REQ-012, REQ-013] Add BARS gestures.
  - Press and paint with gap-fill. Shift fine on one step through `FineDrag.begin_at` with an
    accumulator. Ctrl/Cmd reset painting.
  - `value_edited` fires only on change. `edit_started` and `edit_ended`.
  - The `Hotkeys.begin_state` / `end_state` calls go in the gesture setter.
  - Tests cover the REQ-005, 008, 009, 012 and 013 acceptance cases and "no signal without a
    change". Place the lane away from (0, 0).
  - _Files_: `Godot/components/StepLane.gd`, `Godot/tests/test_step_lane.gd` (new)
  - _Output_: drawable bars
  - _Verify_: `Godot/tests/run_all.sh step_lane` passes
  - _Depends on_: T-005

- [x?] **T-007** [REQ-004] Add TOGGLES mode.
  - Draw `toggle_on` and `toggle_off` cells.
  - A press flips the step and remembers the new state. A drag sets every crossed step to it,
    with gap-fill.
  - Add tests for the REQ-004 cases.
  - _Files_: `Godot/components/StepLane.gd`, `Godot/tests/test_step_lane.gd`
  - _Output_: the On row behaviour
  - _Verify_: `Godot/tests/run_all.sh step_lane` passes
  - _Depends on_: T-006

- [x?] **T-008** [REQ-010, REQ-011] Add the readout and typed entry.
  - `ValueTooltip` shows `"Step %d  %s"` above the lane on hover and during a drag, and hides on
    exit when not dragging.
  - Double-click opens a `FloatingValueEditor` above the column. The commit parses a number,
    allowing a trailing `%` or `st`, then rounds and clamps it.
  - Add a test that a committed `"-9"` sets -9 and `"30 st"` clamps to 24.
  - _Files_: `Godot/components/StepLane.gd`, `Godot/tests/test_step_lane.gd`
  - _Output_: the progressive-visibility rows of the control checklist
  - _Verify_: `Godot/tests/run_all.sh step_lane` passes
  - _Depends on_: T-006

- [x?] **T-009** [non-functional: look] Theme colours, help bar and gallery.
  - Add the `StepLane` colours to `ThemeBuilder` and regenerate `Sonara_Theme.tres`.
  - Add the `step_lane` context, the `step_lane_draw` state, their labels and the four `GESTURES`
    rows. `Hotkeys.set_context(self, "step_lane")` goes in `_ready`.
  - Add a gallery card.
  - _Files_: `Godot/core/theme/ThemeBuilder.gd`, `Godot/assets/Sonara_Theme.tres`,
    `Godot/input/HotkeyActions.gd`, `Godot/components/StepLane.gd`,
    `Godot/components/gallery/ComponentGallery.tscn`, `Godot/components/gallery/ComponentGallery.gd`
  - _Output_: the lane follows theme changes and the help bar names its gestures
  - _Verify_: `godot --headless --path Godot -s core/theme/build_theme_resource.gd -- --test`
    regenerates without errors. `Godot/tests/run_all.sh` passes in full, so no help-bar or theme
    test breaks
  - _Depends on_: T-007, T-008

## Phase 3 — playhead model

- [x?] **T-010** [REQ-016, REQ-017] Build `StepPlayhead`.
  - `feed`, `step_at` and `take_flashes`, as specified in the design.
  - The old schedule stays in force until the new one's first entry.
  - The playhead clears after 500 ms with no feed.
  - Pending flashes trigger when the playhead enters the step, or at once (already there, passed,
    or past 100 ms).
  - With unknown timing the current step is held without advancing.
  - _Files_: `Godot/devices/builtin/StepPlayhead.gd` (new),
    `Godot/tests/test_step_playhead.gd` (new)
  - _Output_: the step and flashes to show at any moment, with a fake clock
  - _Verify_: `Godot/tests/run_all.sh step_playhead` passes:
    - the REQ-016 timeline: 10, 25, 150 ms, and 60 ms with 40 ms latency;
    - resync to step 5;
    - clear on none and after 500 ms;
    - REQ-017: 2 and 4 flash, 3 doesn't, and interpolation alone doesn't flash.
  - _Depends on_: T-004

## Phase 4 — the view

- [x?] **T-011** [REQ-001, REQ-002, REQ-003] Build the view and register it.
  - The left column (CompactSliders, the Rate `OptionButton`, `SegmentedControl`s) with
    `ModAssign.attach` on the sliders.
  - The step-number row, the On row, the Pitch lane, the Velocity | Chance switch and the Lower
    lane.
  - Register it in `BUILTIN_PANEL_SCENES`.
  - _Files_: `Godot/devices/builtin/StepSequencerDefaultView.gd` / `.tscn` (new),
    `Godot/devices/DeviceViewFactory.gd`, `Godot/tests/test_step_sequencer_view.gd` (new)
  - _Output_: the Step Sequencer opens in the step view
  - _Verify_: `Godot/tests/run_all.sh step_sequencer_view` passes:
    - six shared controls, and 16 columns in each lane;
    - minimum height ≤ the panel's content height;
    - the factory returns this view for `sonara.builtin.step_sequencer` with Simple off, and
      `SimpleView` with it on.
  - _Depends on_: T-009

- [x?] **T-012** [REQ-003, REQ-012, REQ-013, REQ-014] Bind and sync the parameters.
  - `_setup` and `_refresh` read the parameters with `get_parameter_real`.
  - Lane edits go to `set_parameter_real` on the step id for the lane's current field. The On
    row writes 1 or 0.
  - `_on_device_parameter_changed` updates only the affected column, `off_mask`, `length` or
    left control.
  - Switching to Chance swaps the lane's values and its edit target.
  - _Files_: `Godot/devices/builtin/StepSequencerDefaultView.gd`,
    `Godot/tests/test_step_sequencer_view.gd`
  - _Output_: the view edits and follows the device
  - _Verify_: `Godot/tests/run_all.sh step_sequencer_view` passes:
    - REQ-003: Chance redraws, and a drag edits Chance;
    - REQ-014: step 7 Velocity 40 % redraws;
    - Length 6 sets the lanes' `length`;
    - an On edit updates the bars' `off_mask`.
  - _Depends on_: T-011

- [x?] **T-013** [REQ-016, REQ-017, REQ-018] Add live feedback.
  - Subscribe and unsubscribe as in `ArpeggiatorDefaultView`.
  - `_on_data` checks the path, decodes and feeds `StepPlayhead` with the latency from
    `AudioConfig.config["latency_ms"]` (0 when absent).
  - `_process` runs only while active. It pushes `step_at` into the lanes and the number row, and
    turns `take_flashes` into 150 ms decaying levels.
  - Hiding clears everything.
  - _Files_: `Godot/devices/builtin/StepSequencerDefaultView.gd`,
    `Godot/tests/test_step_sequencer_view.gd`
  - _Output_: playhead and flashes in the panel
  - _Verify_: `Godot/tests/run_all.sh step_sequencer_view` passes:
    - REQ-018: subscribe on show, unsubscribe and clear on hide, a foreign path ignored;
    - a fed blob with fired step 3 leaves step 3's flash above 0.
  - _Depends on_: T-010, T-012

## Phase 5 — docs

- [x?] **T-014** [REQ-015] Document the `note_state` stream.
  - Document the full blob layout, including the six trailing `u16`s and the `0xFFFF` meaning,
    under "Device Data Stream". Name which devices send it (Arpeggiator, Step Sequencer, note
    containers).
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: the stream is documented for the first time
  - _Verify_: `grep -n "note_state" docs/subsystems/osc-protocol.md` shows the layout, including
    `gap_b_ms`
  - _Depends on_: T-003

- [x?] **T-015** [REQ-all] Update the subsystem docs and close out spec 027 T-028.
  - Add `StepLane` to Shared pieces and the custom-drawn list in `godot-ui-components.md`.
  - Add a "Step Sequencer view" section to `godot-device-views.md`: layout, `StepPlayhead`,
    latency.
  - Mark spec 027 T-028 as "superseded by spec 039".
  - _Files_: `docs/subsystems/godot-ui-components.md`, `docs/subsystems/godot-device-views.md`,
    `docs/specs/027-note-effects/tasks.md`
  - _Output_: the docs match the code
  - _Verify_: every file in the design's change list is named in at least one doc or test;
    `grep -n "StepLane" docs/subsystems/*.md` hits both docs
  - _Depends on_: T-013

## Phase 6 — live verification

- [ ] **T-016** [REQ-001, REQ-010, REQ-011, REQ-016, REQ-017, non-functional] Live pass.
  - Run the engine (`Engine/run_release.sh`) and Godot. Ask before touching the PipeWire quantum.
  - Steps:
    1. Add a Step Sequencer before an instrument. Toggle Simple on and off (REQ-001).
    2. Draw across Pitch and Velocity, switch to Chance, then double-click step 5 and type `-9`
       (REQ-010). Watch the readout follow the drag (REQ-011).
    3. Length 6, hold a note: the highlight walks 1–6 and clears on release (REQ-016).
    4. Rate 1/32 at 160 BPM, Length 8: every step is visited, in time with the audio, at the
       current buffer size and under the forced 2048 quantum. If it lags, apply the
       graph-quantum fix from the design's Risks.
    5. Set some steps to Chance 50 %: only audible hits flash (REQ-017).
  - _Files_: —
  - _Output_: the result recorded in `STATUS.md` (what was and wasn't checked); tasks marked `[x]`
  - _Verify_: the steps above, observed by the user
  - _Depends on_: T-013, T-014, T-015
