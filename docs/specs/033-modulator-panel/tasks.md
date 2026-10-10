# Modulator panel — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Phases 1–2 are Godot-only. Phases 3–4 start with engine work that can run in parallel with
phases 1–2 (T-008…T-011 don't depend on any Godot task). Godot test commands assume
`Godot/tests/run_all.sh`; engine commands run from `Engine/`.

## Phase 1 — Layout

- [x] **T-001** [REQ-005, REQ-006] Rename `ModulatorTile` → `ModulatorPanel` and rebuild its
  layout: header (colour strip + name/rename), expanding display placeholder `Control`,
  centered wire button at the bottom; `DeviceCard` / `DeviceCardSelected` variation for
  selection; delete the per-tile `StyleBoxFlat` code; wire/pulse/hover/menu logic moved
  verbatim.
  - _Files_: `Godot/devices/modulators/ModulatorTile.gd` → `ModulatorPanel.gd` (plus `.uid`),
    `Godot/devices/modulators/ModulatorsPane.gd`, `Godot/tests/test_modulators_ui.gd`,
    `Godot/tests/test_device_modulators.gd`
  - _Output_: panels render with the new layout; no `ModulatorTile` references remain
  - _Verify_: `grep -rn ModulatorTile Godot/` is empty; `Godot/tests/run_all.sh modulator`
    passes; a test asserts the selected panel's `theme_type_variation == &"DeviceCardSelected"`
    and the wire button's horizontal center equals the panel's
  - _Depends on_: —

- [x] **T-002** [REQ-001, REQ-002, REQ-004, REQ-005] Replace the paged `GridContainer` with the
  column-major grid: `HBoxContainer` of 3-cell `VBoxContainer` columns, `SEP := 2`,
  `C = max(1, n / 3 + 1)`, `_rebuild_grid()` replacing `_rebuild_tiles()`, selection kept by
  `mod_id` across rebuilds. Remove `ChevronScrollContainer` and `TILE_COLUMNS`.
  - _Files_: `Godot/devices/modulators/ModulatorsPane.gd`
  - _Output_: panels in column-major order, trailing placeholder cells (empty buttons for now)
  - _Verify_: test: 0 → 1 column / 3 placeholders; 3 → 2 columns with panels in column 0;
    4 → 2 columns + 2 placeholders, panel 3 at column 1 row 0; deleting 4 → 3 → 2 shrinks
    to 1 column
  - _Depends on_: T-001

- [x] **T-003** [REQ-001] Square sizing: `_layout_panel_size()` on the pane's `resized`,
  `side = clamp(floor((avail_h − 2·SEP) / 3), PANEL_MIN_SIDE 56, PANEL_MAX_SIDE 110)` from the
  grid's parent height minus the title row; applied to every cell only when `side` changes.
  - _Files_: `Godot/devices/modulators/ModulatorsPane.gd`
  - _Output_: every cell is `side × side`; the pane widens one column per growth step
  - _Verify_: test: at a pane height of 330 every panel's `size.x == size.y` and the gap
    between neighbours is 2 px; resizing twice to the same height doesn't re-trigger a
    layout (counter stays put)
  - _Depends on_: T-002

- [x] **T-004** [REQ-002, REQ-003] Placeholders: flat `DeviceCard` button with a large
  `plus.svg`, tooltip "Add modulator", `PopupMenu` filled by `_refresh_kinds`; choosing a
  kind calls `add_modulator(kind)` and selects the result. Disabled with tooltip
  "Maximum of 8 modulators" at `MAX_MODULATORS`. Remove the header `MenuButton`
  (`_add_button`) and `_on_add_kind`'s old wiring.
  - _Files_: `Godot/devices/modulators/ModulatorsPane.gd`
  - _Output_: the header shows only the title; every `+` adds into the first free cell
  - _Verify_: test: the placeholder menu lists every registry kind; picking one on an empty
    device appends it, selects it and the detail column shows it; at 8 modulators the single
    placeholder is `disabled`
  - _Depends on_: T-002

## Phase 2 — Reorder

- [x] **T-005** [REQ-007, REQ-008] Model: `signal modulators_reordered`,
  `swap_modulators(a_mod_id, b_mod_id)`; drop the `mod_id` `sort_custom` in
  `_modulators_to_json`; pane rebuilds and `ModAssign.notify_changed()` on the signal.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/devices/modulators/ModulatorsPane.gd`,
    `Godot/devices/modulators/ModAssign.gd`
  - _Output_: array order is display and save order
  - _Verify_: test: swap keeps both ids, swaps `get_routes_into` `color_index`, emits
    `modulators_reordered` once; `to_json` → `from_json` round-trips the swapped order
  - _Depends on_: T-002

- [x] **T-006** [REQ-008, REQ-011] Order-safe engine sync: `sync_modulators_to_engine` sends
  every `add` + params first, then every route.
  - _Files_: `Godot/data/DeviceInstance.gd`
  - _Output_: a `mod/{B}/…` route on a modulator earlier in the array resolves on load
  - _Verify_: test with a recording OSC stub: every `modulator/add` precedes every
    `route/set`
  - _Depends on_: —

- [x] **T-007** [REQ-007] Drag to swap: `ModulatorDrag.gd` (payload `{device_id, mod_id}`,
  static `resolve(pane, drag, global_mouse) -> Target`, `commit()` → `swap_modulators`),
  `DropIndicator` outline; panel selects on release below a 6 px threshold, starts a drag
  above it, never from the wire button or rename `LineEdit`.
  - _Files_: `Godot/devices/modulators/ModulatorDrag.gd` (new),
    `Godot/devices/modulators/ModulatorPanel.gd`, `Godot/devices/modulators/ModulatorsPane.gd`,
    `Godot/tests/test_modulator_drag.gd` (new, modelled on `test_device_drop.gd`)
  - _Output_: dragging A onto B swaps them; nothing moves before the drop
  - _Verify_: `Godot/tests/run_all.sh modulator_drag`: own-device panel resolves valid;
    placeholder, self, another device's panel, outside the grid resolve invalid; commit
    swaps; a click without movement toggles selection
  - _Depends on_: T-005

## Phase 3 — Displays

- [x] **T-008** [REQ-009, REQ-010] Engine: `ModulatorState::display_state() -> (u8 stage,
  f32 x, f32 value)` per the design table (LFO phase; `adsr`/`ad` from `env.state()` and
  `env.value()`; everything else `value()`).
  - _Files_: `Engine/src/audio/modulation/state.rs`
  - _Output_: the per-kind display tuple, no new fields
  - _Verify_: `cargo test display_state`: LFO x tracks phase; ADSR under a held note reports
    attack → decay → sustain, then release after note-off; `velocity` reports `value()`
  - _Depends on_: —

- [x] **T-009** [REQ-009, REQ-010] Engine: append the trailing block to `modulation_payload`
  — `u16 ext_count`, then `{u8 kind, u8 len, bytes}` records, one `kind 2` per occupied slot;
  grow the `with_capacity` by the block's fixed maximum.
  - _Files_: `Engine/src/audio/modulation/host.rs`
  - _Output_: payload = unchanged kind 0/1 list + trailing block
  - _Verify_: `cargo test modulation_payload`: kind 0/1 bytes identical to before; one
    kind 2 per slot with the right values; `bytes.capacity()` equals the initial capacity
    after building a maximal payload (8 modulators, `MAX_ROUTES` kind 3 slots reserved)
  - _Depends on_: T-008

- [x] **T-010** [REQ-009, REQ-010] Godot: `ModLive._decode` returns the trailing block too —
  `kind 2` into `_mod_states[device][mod_id]` (replaced wholesale per payload), unknown
  kinds skipped by `len`, and kinds other than 0/1 in the counted list skipped rather than
  read as offsets. Add `signal modulator_states_changed(device)` and
  `static func modulator_state(device, mod_id) -> Dictionary`.
  - _Files_: `Godot/devices/modulators/ModLive.gd`
  - _Output_: per-modulator live state available to displays
  - _Verify_: test: an old-format payload (no block) decodes as before; a new payload
    fills `_mod_states`; an unknown trailing kind is skipped and the following record still
    decodes; the signal fires once per payload
  - _Depends on_: T-009 (byte layout)

- [x] **T-011** [REQ-009, REQ-010] `ModulatorDisplay.gd`: `_draw()` control bound to
  `(device, mod_id)`, redrawing on `modulator_states_changed` and `modulator_changed`.
  LFO: one cycle of Sine/Triangle/Saw/Square, S&H staircase glyph, dot at `(phase, value)`.
  `adsr`/`ad`: curve from base params, dot x from `(stage, level)` as in the design, no dot
  when idle. Generic: 40-sample ring-buffer trace, dot at the newest point, y-range by
  `bipolar`. Primary-accent line, white dot; static shape with no dot when no state.
  - _Files_: `Godot/devices/modulators/ModulatorDisplay.gd` (new),
    `Godot/devices/modulators/ModulatorPanel.gd`
  - _Output_: every panel shows a kind display
  - _Verify_: test: feeding states through `ModLive` moves the dot (exposed `dot_position()`)
    for an LFO, an ADSR in each stage and a `velocity` modulator; an unregistered kind
    string draws the generic display without errors; an empty state draws no dot
  - _Depends on_: T-001, T-010

## Phase 4 — Modulator→modulator

- [x] **T-012** [REQ-011] Engine, mono: `ModulatorState` gains `mod_offset` and
  `set_mod_offset(param_id, off)`; `advance`, `value` and `apply_params` read
  `clamp(base + offset)`; `get_param` returns the base. In the wrapper's control step, sum
  `ModTarget::Modulator` routes from the previous step's `self.values` and apply before
  `advance`, re-applying only past `OFFSET_EPSILON`; record each sum for the stream.
  - _Files_: `Engine/src/audio/modulation/state.rs`, `Engine/src/audio/modulation/host.rs`
  - _Output_: mod→mod routes audible on non-voice devices
  - _Verify_: `cargo test modulation`: LFO A → LFO B rate changes B's phase increment one
    control step later; an A→B→A cycle stays within bounds over 10 s; swapping which slots
    hold A and B gives identical output; `get_modulator_param` still returns the base
  - _Depends on_: —

- [x] **T-013** [REQ-011] Engine: `remove_modulator(B)` also clears every route whose target
  is `ModTarget::Modulator(B, _)`; `kind 3` records (`u8 mod_id, u32 param_id, f32 offset`)
  in the trailing block from T-012's sums.
  - _Files_: `Engine/src/audio/modulation/host.rs`
  - _Output_: no dangling routes; modulator-param offsets on the stream
  - _Verify_: `cargo test modulation`: after removing B, `modulator_routes()` has no
    `mod/B/…` entry; a payload with an A→B route carries one kind 3 record with A's
    contribution
  - _Depends on_: T-009, T-012

- [x] **T-014** [REQ-011] Engine, per voice: `VoiceModRoute` + `mod_routes` in
  `VoiceModSpec`, filled by `push_voice_mod_spec`; PolySynth `render_chunk` sums them from the
  pre-advance `state.value()`s per voice and calls `set_mod_offset` before `advance`.
  `AudioDevice::set_voice_mod_param_offset` (default no-op) carries mono-only-source (`cc`)
  offsets from the wrapper's control step into a fixed per-device array added to every
  voice.
  - _Files_: `Engine/src/audio/modulation/voice.rs`, `Engine/src/audio/modulation/host.rs`,
    `Engine/src/audio/devices/device.rs`,
    `Engine/src/audio/devices/instruments/polysynth/voice.rs`,
    `Engine/src/audio/devices/instruments/polysynth/mod.rs`
  - _Output_: mod→mod routes audible on PolySynth, per voice
  - _Verify_: `cargo test polysynth`: a voice's LFO B rate follows LFO A; a `cc` → LFO-rate
    route reaches every sounding voice; `VoiceModSpec` is still `Copy` (existing
    `state_is_copy_and_bounded`-style assertion); `cargo build --release` clean
  - _Depends on_: T-012

- [x] **T-015** [REQ-011] Godot model: `remove_modulator(B)` erases `mod/B/…` keys from every
  other modulator's `routes` and emits `route_changed`; `ModulatorPanel._target_name` names
  `mod/{id}/param/{pid}` as "{modulator name} › {param name}".
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/devices/modulators/ModulatorPanel.gd`
  - _Output_: no dangling routes in the model; readable route menu entries
  - _Verify_: test: remove B → A's routes have no `mod/B/` key and `route_changed` fired;
    `_target_name("mod/1/param/10")` returns "LFO 2 › Rate" (with matching names)
  - _Depends on_: T-001

- [x] **T-016** [REQ-011] `ModAssign` / `ModLive` modulator-parameter targets: target
  descriptor `{device, mod_id, param_id}` through `relative_target`, `ranges_for`,
  `amount_for`, `amount_text`, `_refresh_hint`; `attach_modulator` in both; `ModLive` key
  `"{device id}:mod{mod_id}:{param}"`, base value from `mod.get_param`, `kind 3` records
  routed to it. Valid only on the same device and not the assigning modulator itself.
  Device-parameter behaviour unchanged.
  - _Files_: `Godot/devices/modulators/ModAssign.gd`, `Godot/devices/modulators/ModLive.gd`
  - _Output_: modulator knobs can be targets and show live values
  - _Verify_: test: a kind 3 record for `(mod 1, param 0)` updates the modulator knob and
    not the device's param 0; `relative_target` returns `mod/1/param/10`; the assigning
    modulator's own knob is rejected; existing device-target tests still pass
  - _Depends on_: T-010, T-013 (layout)

- [x] **T-017** [REQ-011, REQ-012] Detail column: attach every `RotaryKnob` from
  `_build_param_control` via `ModAssign.attach_modulator` (enums, bools and
  `EnvelopeControl` stay unattached). Selecting another panel keeps assign mode.
  - _Files_: `Godot/devices/modulators/ModulatorsPane.gd`
  - _Output_: wire A → select B → drag on B's Rate creates `mod/B/param/<rate>` on A
  - _Verify_: test: with assign active for A and B selected, an amount drag on B's Rate knob
    sets `A.routes["mod/<B>/param/<rate>"]` and sends `modulator/<A>/route/set`; A's own
    knobs ignore the drag; selecting B didn't end assign mode
  - _Depends on_: T-016

## Phase 5 — Docs

- [x] **T-018** [REQ-009, REQ-011] Document the trailing block (`ext_count`, `{kind, len}`,
  kinds 2 and 3), the decoder rule for unknown kinds, and that `mod/…` routes are now
  evaluated (mono and per voice, one control step of delay). Note that the `modulation`
  payload is built on the audio callback.
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/godot-osc.md`,
    `docs/subsystems/engine-audio-thread.md` (if it lists device-data polling)
  - _Output_: protocol docs match the code
  - _Verify_: the Modulation data-format block shows the trailing block with byte sizes
    matching T-009/T-013 tests
  - _Depends on_: T-013

## Phase 6 — Live verification

- [x] **T-019** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: —
  - _Output_: GitHub issue for spec 033 commented with results and ticked `[x]`; `STATUS.md`
    notes anything unchecked
  - _Verify_: `cd Engine && ./run_release.sh`, then `godot --path Godot`:
    1. Empty device → 1 column of 3 `+`; add LFO → top-left, selected, settings on the
       right; add 2 more → second column appears; reach 8 → last `+` disabled.
    2. LFO panel: wave drawn, dot rides it; ADSR panel: play and hold a note, dot sweeps
       attack → sustain, returns on release; Velocity panel: trace moves per note.
    3. Drag panel 3 onto panel 1 → swapped, colours on modulated knobs follow; save,
       reload → same order, routes intact.
    4. Wire LFO A → LFO B Rate on an effect (e.g. filter): B's Rate knob breathes and the
       filter sweep audibly speeds/slows; repeat on PolySynth with B routed to cutoff.
    5. Delete B → A's route menu has no B entry; add a new modulator (reusing B's id) →
       it is not modulated.
    6. `Engine/logs/last_warn.log` has no route-parse or payload warnings.
  - _Depends on_: T-001 … T-018
