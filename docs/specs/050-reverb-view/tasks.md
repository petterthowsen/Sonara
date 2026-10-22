# Reverb View — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — engine envelope stream

- [x?] **T-001** [REQ-008, REQ-009] `EnvelopeScope` and the `"envelope"` stream on `ReverbDevice`.
  - _Files_: `Engine/src/audio/devices/effects/reverb.rs`
  - _Output_: consts `ENVELOPE_RECORD_FRAMES = 256`, `ENVELOPE_RING_CAPACITY = 256`,
    `ENVELOPE_RATE_HZ = 20.0`; `EnvelopeScope` (fixed record array, peaks, counters,
    `subscribed`, `record_seconds`) owned by `ReverbDevice`, set up in `new` / `prepare`, cleared
    in `reset`; fed in `process_sample` behind one `subscribed` branch; frames counted in
    `process_block`; `subscribe_data` / `unsubscribe_data` / `poll_device_data` (blob:
    `u32 count, f32 record_seconds, count × [in_db, wet_db]`). `update_sleep_state` unchanged.
  - _Verify_: `cargo build --release` clean; no allocation added on the per-sample path (review
    the diff: only array writes and `max`).
  - _Depends on_: —

- [x?] **T-002** [REQ-008, REQ-009, REQ-010] Engine tests for the stream.
  - _Files_: `Engine/src/audio/devices/effects/reverb.rs` (`mod tests`)
  - _Output_: `envelope_stream_is_silent_until_subscribed`, `envelope_blob_layout`,
    `envelope_records_follow_the_impulse_decay` (Decay 2 s → −60 dB at 2 s ± 10 %),
    `subscribed_reverb_still_sleeps`.
  - _Verify_: `cd Engine && CARGO_BUILD_JOBS=2 cargo test reverb -- --nocapture` all pass;
    `cargo fmt`.
  - _Depends on_: T-001

## Phase 2 — Godot model

- [x?] **T-003** [REQ-003, REQ-005, REQ-006] `ReverbData.gd` (`@tool`): param ids, `DEFAULTS`,
  tap tables and size scales mirrored from `reverb.rs` (comment names each Rust const; matching
  comment added above `EARLY_ROOM` and `Absorbent` in `reverb.rs`), `band_t60`, `cut_db`,
  `level_db`, `early_ticks`, `span_target`, `decode_envelope`.
  - _Files_: `Godot/devices/builtin/reverb/ReverbData.gd`, `Engine/src/audio/devices/effects/reverb.rs` (comments only)
  - _Output_: pure static functions, no node dependencies.
  - _Verify_: T-004 passes.
  - _Depends on_: T-001 (blob layout)

- [x?] **T-004** [REQ-003, REQ-005, REQ-006] Model tests.
  - _Files_: `Godot/tests/test_reverb_map.gd`
  - _Output_: contour times from REQ-003 (1 kHz ± 10 %, 30 Hz and 18 kHz ± 5 %); plateau values
    match the engine test `decay_eq_moves_the_band_t60s` (60 Hz → Decay × Low Mult, 10 kHz →
    Decay × High Mult, ± 20 %); span ≤ 1 s at Decay 0.3 s, ≥ 20 s at Decay 20 s; Freeze → `INF`;
    `decode_envelope` round-trips a hand-built blob; early ticks move with Size and Algorithm.
  - _Verify_: `Godot/tests/run_all.sh reverb_map` passes.
  - _Depends on_: T-003

## Phase 3 — drawn controls (`@tool`, previewable)

- [x?] **T-005** [REQ-003, REQ-004, REQ-005, REQ-006, REQ-011] `ReverbDecayMap.gd`: draws the map
  from a values dictionary (defaults to `ReverbData.DEFAULTS` with no device) as ~64 log-spaced
  frequency rows, axis labels, onset columns (Early, Diffusion blur and tail build-up), square-root time axis, contour, cut fades, Pre-Delay edge, eased span with
  `span_locked`, freeze and "≈ Tank FX" states. Redraws only on change.
  - _Files_: `Godot/devices/builtin/reverb/ReverbDecayMap.gd`
  - _Output_: a `@tool` `Control` that renders a default map when dropped into a scene.
  - _Verify_: opening a scratch scene with the node in the editor shows the default map (screenshot
    via the godot-ai `editor_screenshot` tool); `run_all.sh reverb_map` still passes.
  - _Depends on_: T-003

- [x?] **T-006** [REQ-007] Handles on `ReverbDecayMap`: hit-testing (knees > contour > cut lines >
  Pre-Delay edge), hover highlight, `ValueTooltip`, drag → `ParameterActions.set_real` inside
  `begin_gesture` / `end_gesture`, double-click → `ParameterActions.reset`, range clamping,
  decay handles disabled while frozen. Emits nothing to OSC directly; writes through the bound
  `DeviceInstance`.
  - _Files_: `Godot/devices/builtin/reverb/ReverbDecayMap.gd`
  - _Output_: all six handles from REQ-007 draggable.
  - _Verify_: covered by T-010's drag tests.
  - _Depends on_: T-005

- [x?] **T-007** [REQ-008, REQ-010] `ReverbEnvelopeStrip.gd`: wall-clock history ring
  (`MAX_HISTORY_S = 64`), `push_records(records, record_seconds)`, gap fill after `GAP_S`,
  per-pixel min/max binning over `span`, input and wet traces, −60…0 dB grid. In the editor it
  draws a canned single-hit decay.
  - _Files_: `Godot/devices/builtin/reverb/ReverbEnvelopeStrip.gd`
  - _Output_: a `@tool` `Control` that previews in the editor.
  - _Verify_: editor screenshot shows the canned decay; T-010's gap-fill test.
  - _Depends on_: T-003

## Phase 4 — the view scene

- [x?] **T-008** [REQ-001, REQ-002, REQ-012] `ReverbDefaultView.tscn`: the full layout from
  design.md as editor-placed nodes. Columns Input, Space, centre (map, strip, Decay EQ /
  Modulation / Tank FX row), Tone, Wet FX tile, Out; Algorithm `SegmentedControl` in the top row.
  Every parameter control has `metadata/param`, and both `DeviceSlotButton` tiles have
  `metadata/slot`. It fits within `DevicePanel.HEIGHT`.
  - _Files_: `Godot/devices/builtin/reverb/ReverbDefaultView.tscn`
  - _Output_: a scene that opens in the editor showing the whole view with the default map and
    canned strip; no controls missing.
  - _Verify_: editor screenshot of the scene; the scene's minimum height is ≤ 350 minus the
    panel header.
  - _Depends on_: T-005, T-007

- [x?] **T-009** [REQ-001, REQ-004, REQ-009, REQ-010, REQ-011, REQ-012] `ReverbDefaultView.gd`:
  `_build` collects and wires `metadata/param` controls (saturator pattern; no runtime control
  creation), configures knobs from `ParamInfo`, binds slot tiles from `metadata/slot`, pushes
  values to the map on `_on_device_parameter_changed`, sets the strip span from the map's span,
  `_sync_subscription` for `"envelope"` through `load_osc`, watches Tank FX `slots_changed` and
  `enabled_changed`. Register it in `DeviceViewFactory.BUILTIN_PANEL_SCENES`.
  - _Files_: `Godot/devices/builtin/reverb/ReverbDefaultView.gd`, `Godot/devices/DeviceViewFactory.gd`
  - _Output_: a new Reverb opens in the custom view; the Simple toggle still swaps to Simple View.
  - _Verify_: the view opens for a new Reverb (T-010 dropped).
  - _Depends on_: T-006, T-008

- [ ] ~~**T-010**~~ Dropped: the view test was removed (UI tests stay surface level); the view is
  checked by hand (Phase 6), the map model by `test_reverb_map.gd`. Original task:
  [REQ-001, REQ-002, REQ-004, REQ-007, REQ-009, REQ-010, REQ-011, REQ-012] View tests.
  - _Files_: `Godot/tests/test_reverb_view.gd`
  - _Output_: one control per param id plus two slot tiles; x order from REQ-002 (stacked
    columns may tie); `set_parameter_real(DECAY)` changes the map's 1 kHz contour; synthetic
    drag on each handle moves its parameter the right way and stays in range, one undo per
    changed parameter restores it, and double-click resets it; show/hide sends subscribe and
    unsubscribe to a fake OSC; 0.5 s without blobs appends silence; a Tank FX device sets the
    approximate flag and removing it clears it; clicking a tile toggles the slot.
  - _Verify_: `Godot/tests/run_all.sh reverb` passes, and the full `Godot/tests/run_all.sh` shows
    no new failures.
  - _Depends on_: T-009

## Phase 5 — docs

- [x?] **T-011** [REQ-008] Document the `"envelope"` stream.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: "Reverb envelope stream" subsection (blob layout, rate, no options, the wet tap
    point, doesn't keep the device awake), and the "Data Types" list entry.
  - _Verify_: the doc's blob layout matches `poll_device_data` and `ReverbData.decode_envelope`.
  - _Depends on_: T-002

- [x?] **T-012** [REQ-001] Device views doc and changelog.
  - _Files_: `docs/subsystems/godot-device-views.md`, `CHANGELOG.md`
  - _Output_: the Reverb panel view listed with its files and the `ReverbData` ↔ `reverb.rs`
    mirror note; an `### Added` line under `[Unreleased]`.
  - _Verify_: read back both entries.
  - _Depends on_: T-009

## Phase 6 — live verification

- [ ] **T-013** [REQ-all] Live check with the engine and Godot running (ask before taking over
  port 7000 if a user engine is running).
  - _Files_: —
  - _Output_: notes in the spec's converge report on what was and wasn't checked.
  - _Verify_: Reverb on a channel with a drum loop:
    1. The map matches the knobs. Drag every handle and watch its knob follow, then undo each.
    2. A single snare hit gives an input spike and a wet slope that ends near the contour.
    3. Change the algorithm and watch the early columns change; sweep Diffusion and watch them blur into the tail.
    4. Turn Freeze on and see the frozen map, with the decay handles disabled.
    5. Stop the transport. The reverb sleeps and the strip keeps scrolling flat.
    6. Add a device to Tank FX and see "≈ Tank FX". Clicking each tile shows and hides its slot.
    7. Toggle Simple and get the Simple View back.
  - _Depends on_: T-010, T-011, T-012
