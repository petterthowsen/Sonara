# Parameter Automation — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Gates before any task is marked `[x]`: `cargo test` and `cargo fmt` for engine tasks,
`godot --headless --path Godot -s <script> -- --test` for GDScript tasks.

## Phase 1 — Engine foundation

- [x] **T-001** [REQ-002, REQ-005] Create the automation module: `AutomationTarget` (with `parse`
  / `Display` for the target string), `CurveKind`, `AutomationPoint`, the curve evaluator, the
  `TENSION_RANGE` constant and the dB/pan normalization helpers.
  - _Files_: `Engine/src/audio/automation.rs`, `Engine/src/audio/mod.rs`
  - _Output_: module compiles and is re-exported; targets round-trip through their string form
    including nested device paths; the three curve shapes evaluate
  - _Verify_: `cargo test automation_target_roundtrip automation_curve_shapes -- --nocapture` —
    tension `0.0` returns exactly 0.5 at the midpoint of a 0→1 segment
  - _Depends on_: —

- [x] **T-002** [REQ-001, REQ-006, REQ-007, REQ-010] Add `AutomationLane` with cursor-based
  `value_at(tick)` and the point mutators that keep the sorted-by-tick invariant, and hang lanes
  off `Track`.
  - _Files_: `Engine/src/audio/automation.rs`, `Engine/src/audio/types.rs`
  - _Output_: `Track::automation_lanes: Vec<AutomationLane>`; `value_at` allocates nothing, walks
    the cursor forward, and binary-searches only on a backward tick jump
  - _Verify_: `cargo test automation_holds_outside_points automation_empty_lane_is_inert
    automation_cursor_is_bounded -- --nocapture` — the 10,000-point lane test asserts a bounded
    per-step comparison count and `O(log n)` re-seek
  - _Depends on_: T-001

- [x] **T-003** [REQ-003, REQ-004] Add the channel overrides and make the mixer prefer them
  without touching the base fields.
  - _Files_: `Engine/src/audio/types.rs`
  - _Output_: `Channel::automation_volume` / `automation_pan` as `Option<f32>`; `get_gain()`
    denormalizes the override to dB when set, `get_pan_coefficients()` prefers `automation_pan`;
    `volume_db` and `pan` are never written by either path
  - _Verify_: `cargo test automation_overrides_base_but_preserves_it -- --nocapture`
  - _Depends on_: T-001

- [x] **T-004** [REQ-010] Add the `AudioDevice::set_parameter_at(param_id, value, frame_offset)`
  hook, defaulting to `set_parameter`, documented as the seam for sample-accurate automation.
  - _Files_: `Engine/src/audio/devices/mod.rs`
  - _Output_: default method on the trait; no device overrides it in phase 1
  - _Verify_: `cargo build --release` succeeds with no device changes required
  - _Depends on_: —

- [x] **T-005** [REQ-012] Add the seven `AudioCommand` variants and their apply arms.
  - _Files_: `Engine/src/audio/commands.rs`
  - _Output_: create / delete / bypass / add_point / update_point / remove_point / clear applied
    against `Track::automation_lanes`; **no** `EngineStatus` is sent from any arm (the echo trap)
  - _Verify_: `cargo test` passes; grep the new arms to confirm no `status_tx.send`
  - _Depends on_: T-002

- [x] **T-006** [REQ-012] Handle `/track/{id}/automation/...` in the OSC server, parsing the
  target string and dispatching the new commands.
  - _Files_: `Engine/src/osc/server.rs`
  - _Output_: all seven addresses dispatch; an unparseable target logs one warning and is dropped
  - _Verify_: with the engine running, `oscsend localhost 7000
    /track/0/automation/create ss lane1 channel/volume` then
    `oscsend localhost 7000 /track/0/automation/lane1/add_point iifsf 1 0 0.2 linear 0.0` —
    `Engine/logs/last_info.log` shows the lane created and the point added
  - _Depends on_: T-005

## Phase 2 — Engine behaviour

- [x] **T-007** [REQ-003, REQ-008] Add `apply_automation(state, tick)` and call it in
  `process_audio` **before** the `is_playing` early return.
  - _Files_: `Engine/src/audio/automation.rs`, `Engine/src/audio/processing.rs`
  - _Output_: every enabled, resolvable lane resolves once per buffer and applies to its target,
    whether or not the transport is running
  - _Verify_: `cargo test automation_resolves_each_target -- --nocapture` — all four target kinds
    move the right live value on a constructed `EngineState`
  - _Depends on_: T-002, T-003, T-004

- [x] **T-008** [REQ-004, REQ-009, REQ-024] Capture and restore the device base value, and drop
  unresolvable lanes safely.
  - _Files_: `Engine/src/audio/automation.rs`, `Engine/src/audio/commands.rs`
  - _Output_: `captured_base` is filled the first time a lane drives a device param and written
    back on bypass, delete, or when the target stops resolving; channel overrides are cleared in
    the same cases; an unresolvable target logs once, not per buffer
  - _Verify_: `cargo test automation_overrides_base_but_preserves_it -- --nocapture` extended to
    cover bypass, delete and a removed device
  - _Depends on_: T-007

- [x] **T-009** [REQ-011] Dedup unchanged values and wake sleeping devices only on a real change.
  - _Files_: `Engine/src/audio/automation.rs`
  - _Output_: `last_applied` gates the apply; `DeviceSleepState::mark_activity()` is called only
    when the value actually changes
  - _Verify_: `cargo test automation_dedups_unchanged_values -- --nocapture` — a constant lane
    over 100 buffers emits one apply
  - _Depends on_: T-007

- [x?] **T-010** [REQ-003] Resolve the fader-smoothing risk: check whether the 5 ms constant
  audibly smears a step-shaped volume lane, and adjust only if it does.
  - _Files_: `Engine/src/audio/types.rs`, `Engine/src/audio/mixing.rs`
  - _Output_: either a written finding that the existing smoothing is acceptable, or a shortened
    constant / per-buffer ramp while `automation_volume` is `Some` — with the anti-zipper
    smoothing still in place either way
  - _Verify_: live — a step lane alternating 0.0 / 1.0 every beat on a channel volume; listen for
    a soft rather than gated transition, and confirm `cargo test` mixing tests still pass
  - _Depends on_: T-007

## Phase 3 — Godot data model

- [x] **T-011** [REQ-005, REQ-012] Rewrite the lane and point models with ids, OSC-sending
  setters, and the GDScript curve evaluator.
  - _Files_: `Godot/data/AutomationLane.gd`, `Godot/data/AutomationPoint.gd`
  - _Output_: `AutomationPoint` gains `id` and reduces `CurveType` to `LINEAR` / `STEP` (mapping
    retired names on load); `AutomationLane` gains `id`, `target`, `bypassed`, `resolved`, the new
    signals, binary-search `get_value_at_tick`, and incremental `add_point` / `update_point` /
    `remove_point` / `clear_points` that send OSC then emit
  - _Verify_: `godot --headless --path Godot -s tests/test_automation_curve_parity.gd -- --test` —
    the GDScript evaluator matches T-001's expected values to within 0.001
  - _Depends on_: T-001

- [x] **T-012** [REQ-002, REQ-017, REQ-024] Add the target value object.
  - _Files_: `Godot/data/AutomationTarget.gd`
  - _Output_: `to_string()` / `parse()` matching the engine spelling exactly, `resolve(channel)`,
    `display_name(channel)` yielding `Filter / Freq`, and `is_resolvable(channel)`
  - _Verify_: covered by T-013's model test — target strings round-trip and match the strings
    T-001 accepts
  - _Depends on_: T-011

- [x] **T-013** [REQ-001, REQ-023] Wire lanes into `Track`: typed array, accessors, signals,
  `from_json` loading, and engine sync.
  - _Files_: `Godot/data/Track.gd`
  - _Output_: `automation_lanes: Array[AutomationLane]`; `add_automation_lane` /
    `remove_automation_lane` / `get_automation_lane_for`; the line-597 TODO replaced by real
    loading; lanes synced in `connect_to_engine()` and cleared in `disconnect_from_engine()`
  - _Verify_: `godot --headless --path Godot -s tests/test_automation_model.gd -- --test` — lane
    and point JSON round-trip, a missing `automation_lanes` key loads as zero lanes, a stub-era
    point with `BEZIER` loads as `LINEAR`, and bypass/visibility/height persist
  - _Depends on_: T-012

- [x] **T-014** [REQ-016] Add the MIDI CC name lookup.
  - _Files_: `Godot/core/Midi.gd`
  - _Output_: the standard CC name table, `cc_name(cc)` falling back to `CC{n}`, and
    `cc_display_name(cc, device_supplied := "")` preferring a device-supplied label
  - _Verify_: `godot --headless --path Godot -s tests/test_midi_cc_names.gd -- --test` — CC
    1/7/10/11/64/74 return standard names, an unassigned number returns `CC{n}`, and no number
    0–127 returns an empty string
  - _Depends on_: —

- [x?] **T-015** [REQ-013] Register the lane-height setting.
  - _Files_: `Godot/settings/Settings.gd`
  - _Output_: `appearance/automation_lane_height` (`Type.INT`, default 40, `CATEGORY_APPEARANCE`)
    with `min_val` / `max_val` / `step` set the way the virtual-keyboard INT settings are
  - _Verify_: `Godot/tests/run_all.sh` passes, and live the key appears in the Settings dialog
    under Appearance and a newly created lane uses its value as its row height
  - _Depends on_: —

## Phase 4 — Undo/redo

- [x] **T-016** [REQ-022] Add the lane-level commands and the actions façade.
  - _Files_: `Godot/history/AutomationActions.gd`,
    `Godot/history/commands/AutomationLaneCreateCommand.gd`,
    `Godot/history/commands/AutomationLaneDeleteCommand.gd`
  - _Output_: `create_lane` / `delete_lane` routed through `HistoryUtil`; deleting a lane restores
    every point on undo
  - _Verify_: covered by T-017's history test — create then delete a lane, undo twice, the lane
    and its points return
  - _Depends on_: T-013

- [x] **T-017** [REQ-022] Add the point commands, with drag coalescing.
  - _Files_: `Godot/history/commands/AutomationPointsAddCommand.gd`,
    `Godot/history/commands/AutomationPointsRemoveCommand.gd`,
    `Godot/history/commands/AutomationPointsTransformCommand.gd`,
    `Godot/history/AutomationActions.gd`
  - _Output_: add / delete / move / set-curve as single history entries; `can_merge` collapses a
    continuous drag into one entry
  - _Verify_: `godot --headless --path Godot -s tests/test_automation_history.gd -- --test` —
    a five-point move undoes as one step and restores the original ticks and values. Model the
    test on the existing `Godot/tests/test_command_history.gd`
  - _Depends on_: T-016

## Phase 5 — Arranger UI

- [x?] **T-018** [REQ-013, REQ-017] Add the shared row ordering and the lane header row.
  - _Files_: `Godot/arranger/AutomationRowOrder.gd`,
    `Godot/arranger/tracklist/AutomationLaneHeader.gd` + `.tscn`,
    `Godot/arranger/tracklist/TrackList.gd`
  - _Output_: one ordering helper both columns call; a header row showing `Device / Param` with
    bypass and delete controls and the same bottom-gutter resize gesture as `TrackItem`, writing
    `lane.height`
  - _Verify_: live — show two lanes, resize one, scroll: header and timeline row stay equal in
    height and aligned
  - _Depends on_: T-013, T-015, T-016

- [x?] **T-019** [REQ-014] Add the track-header disclosure and the lane menu.
  - _Files_: `Godot/arranger/tracklist/TrackItem.gd` + `.tscn`,
    `Godot/arranger/tracklist/AutomationLaneMenu.gd`
  - _Output_: a disclosure arrow toggling the track's lane rows, and a dropdown with one checkbox
    per lane driving `lane.visible` plus a `+ Add new` entry
  - _Verify_: live — toggle disclosure and confirm rows appear/disappear; uncheck one lane and
    confirm only it hides while its points are kept
  - _Depends on_: T-018

- [x?] **T-020** [REQ-015, REQ-016] Add the parameter picker.
  - _Files_: `Godot/arranger/tracklist/AutomationParameterPicker.gd`
  - _Output_: channel volume, pan, one entry per send, then per device in `channel.devices` order
    its `"param"` group and its `"cc"` group as separate groups with CC entries named through
    `Midi.cc_display_name`; skips `is_automation_safe == false` and already-automated parameters
  - _Verify_: live — a channel with `polysynth` at 0 and `delay` at 1 lists the polysynth first;
    an SFZ device shows `Cutoff` under device params and `CC1 Mod Wheel` under CC params; a
    parameter that already has a lane is absent
  - _Depends on_: T-014, T-019

- [x?] **T-021** [REQ-013, REQ-018] Draw the timeline lane row.
  - _Files_: `Godot/arranger/timeline/AutomationLaneRow.gd` + `.tscn`,
    `Godot/arranger/timeline/Timeline.gd`
  - _Output_: grid drawn the way `TimelineTrack._draw_grid()` does (clipped to the visible scroll
    range), plus the curve and its points; step segments render as hold-then-jump and stored
    `tension` is honoured when drawing; rows instantiated and ordered via `AutomationRowOrder`
  - _Verify_: live — a lane with four points of mixed linear/step shapes draws correctly at two
    zoom levels and scrolls in step with the clip lanes
  - _Depends on_: T-018

- [x?] **T-022** [REQ-018] Add point insert, move and delete on the lane row.
  - _Files_: `Godot/arranger/timeline/AutomationLaneRow.gd`,
    `Godot/history/AutomationActions.gd`
  - _Output_: double-click inserts at the snapped tick and the value under the cursor, drag
    repositions in both axes with horizontal snapping via the shared `GridHelper`, and the delete
    action removes the selection — all through the history commands
  - _Verify_: live — insert, drag and delete a point; confirm exactly one `update_point` message
    per drag in `Engine/logs/last_info.log` and that the audible value follows (REQ-012)
  - _Depends on_: T-017, T-021

- [x?] **T-023** [REQ-019] Add the point context menu.
  - _Files_: `Godot/arranger/timeline/AutomationPointContextMenu.gd`,
    `Godot/arranger/timeline/AutomationLaneRow.gd`
  - _Output_: right-click on a point or the selection offers Linear, Step and Delete, modelled on
    `ClipContextMenu.gd`
  - _Verify_: live — set a point to Step, confirm the drawn curve holds flat and the engine holds
    the value audibly; set it back to Linear and the ramp returns
  - _Depends on_: T-022

- [x?] **T-024** [REQ-020] Add point selection and multi-select.
  - _Files_: `Godot/arranger/timeline/AutomationPointSelectionManager.gd`,
    `Godot/arranger/timeline/AutomationLaneRow.gd`
  - _Output_: selection set, ctrl-click extend, box-select within a lane row, and the last-clicked
    anchor — mirroring `ClipSelectionManager`'s modifiers
  - _Verify_: live — ctrl-click three points and drag them as one group (one undo step);
    box-select a span and confirm only points inside it are selected
  - _Depends on_: T-022

- [x?] **T-025** [REQ-021] Add range-aware cut, copy, paste and duplicate.
  - _Files_: `Godot/arranger/timeline/AutomationPointSelectionManager.gd`,
    `Godot/arranger/timeline/Timeline.gd`, `Godot/history/AutomationActions.gd`
  - _Output_: the grid-snapped time range and clipboard payload; `Timeline` routes the four
    operations to the automation manager when the automation selection is active, else to the
    existing clip path
  - _Verify_: `godot --headless --path Godot -s tests/test_automation_range_ops.gd -- --test` —
    a 1-bar segment copied and pasted at bar 3 lands at shifted ticks with curves intact, and
    undo restores; model the anchor assertions on the existing
    `Godot/tests/test_clip_paste_anchor.gd`. Plus live confirmation that range and anchor
    behaviour matches clip paste
  - _Depends on_: T-024

- [x?] **T-026** [REQ-024] Render unresolvable lanes.
  - _Files_: `Godot/arranger/tracklist/AutomationLaneHeader.gd`,
    `Godot/arranger/timeline/AutomationLaneRow.gd`, `Godot/data/AutomationLane.gd`
  - _Output_: a lane whose target stops resolving is marked, drawn distinctly, and stops syncing
    to the engine while keeping every point
  - _Verify_: live — delete a device that has a lane; the row stays marked unresolved, the
    parameter returns to its base value, and `Engine/logs/last_warn.log` has one message, not a
    flood
  - _Depends on_: T-008, T-021

## Phase 6 — Docs

- [ ] **T-027** [REQ-all] Document the protocol and fix the stale reference.
  - _Files_: `.cursor/rules/osc-protocol.mdc`, `AGENTS.md`,
    `.cursor/rules/godot-architecture.mdc`, `TODO.md`
  - _Output_: the seven `/track/{id}/automation/*` messages and the target-string grammar
    documented; `AGENTS.md`'s `OSC_PROTOCOL.md` reference corrected to
    `.cursor/rules/osc-protocol.mdc` and automation noted under "Channels and devices"; the
    automation row/lane structure added to the Godot architecture rule; the `TODO.md` entry marked
  - _Verify_: every message added by T-006 appears in the protocol doc with its argument types
    and direction; no reference to `OSC_PROTOCOL.md` remains (`grep -rn OSC_PROTOCOL.md .`)
  - _Depends on_: T-006

## Phase 7 — Live verification

- [ ] **T-028** [REQ-all] Verify the whole feature live with the engine and Godot running.
  - _Files_: `STATUS.md`, `TODO.md`
  - _Output_: `TODO.md` phase-1 item marked `[x]`; `STATUS.md` records what was and was not
    checked, including the T-010 smoothing finding
  - _Verify_: run `Engine/run_release.sh`, then `godot --path Godot`, and walk:
    (1) automate channel volume with a ramp — hear it, no per-buffer log spam;
    (2) transport stopped, `oscsend localhost 7000 /transport/seek i 9600`, play a note — level
    matches the lane at that tick;
    (3) automate an SFZ CC lane and a built-in device param — both move;
    (4) load a CLAP plugin, automate one parameter, watch `/engine/load` with its GUI open — no
    dropouts and no IPC backlog;
    (5) automate a delay's parameter, leave it constant for >3 s — the device still sleeps; move
    the lane — it wakes;
    (6) bypass then delete a lane — the parameter returns to its base value both times, and the
    saved project still holds the original base;
    (7) reopen a project saved before this feature — loads with zero lanes, no error in
    `Godot/logs/last.log`
  - _Depends on_: T-010, T-023, T-025, T-026, T-027

## Requirement coverage

| REQ | Tasks |
|---|---|
| REQ-001 | T-002, T-013 |
| REQ-002 | T-001, T-007, T-012 |
| REQ-003 | T-003, T-007, T-010 |
| REQ-004 | T-003, T-008 |
| REQ-005 | T-001, T-011 |
| REQ-006 | T-002 |
| REQ-007 | T-002 |
| REQ-008 | T-007, T-028 |
| REQ-009 | T-008 |
| REQ-010 | T-002, T-004 |
| REQ-011 | T-009, T-028 |
| REQ-012 | T-005, T-006, T-011, T-022 |
| REQ-013 | T-015, T-018, T-021 |
| REQ-014 | T-019 |
| REQ-015 | T-020 |
| REQ-016 | T-014, T-020 |
| REQ-017 | T-012, T-018 |
| REQ-018 | T-021, T-022 |
| REQ-019 | T-023 |
| REQ-020 | T-024 |
| REQ-021 | T-025 |
| REQ-022 | T-016, T-017 |
| REQ-023 | T-013, T-028 |
| REQ-024 | T-008, T-012, T-026 |
