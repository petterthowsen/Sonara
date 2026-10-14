# Sidechain modulator view, gain and amount; modulator capacity — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine commands run from `Engine/`. Godot tests: `Godot/tests/run_all.sh <words>`.

## Phase 1 — engine foundations

- [ ] **T-001** [REQ-011] Raise the capacity: `MAX_MODULATORS` = 32, `MAX_ROUTES` = 128.
  - _Files_: `Engine/src/audio/modulation/mod.rs`, `Engine/src/audio/modulation/matrix.rs`, `Engine/src/audio/modulation/host.rs` (test)
  - _Output_: the constants are raised; new test `a_device_holds_32_modulators_and_128_routes`
  - _Verify_: `cargo test a_device_holds_32_modulators_and_128_routes` passes; `cargo test modulation` passes (all capacity-sized arrays recompile and the existing tests still pass)
  - _Depends on_: —

- [ ] **T-002** [REQ-011] Bound the PolySynth's per-instance modulator memory.
  - _Files_: `Engine/src/audio/devices/instruments/polysynth/mod.rs` (test)
  - _Output_: `voice_state_stays_bounded` prints and asserts `size_of::<VoiceModSpec>()` and `MAX_POLYPHONY × MAX_MODULATORS × size_of::<Option<ModulatorState>>()` (bound 1 MB)
  - _Verify_: `cargo test voice_state_stays_bounded -- --nocapture` passes; record the printed sizes in this task
  - _Depends on_: T-001, T-004

- [ ] **T-003** [REQ-001, REQ-002] Add the Gain (50) and Amount (60) parameters to the sidechain table.
  - _Files_: `Engine/src/audio/modulation/kinds.rs`
  - _Output_: `SC_GAIN`, `SC_AMOUNT`, `SC_SPECS` with 7 entries, `SC_SLOTS: [u8; 70]`, `MAX_KIND_PARAMS` = 7; the kind table test lists them with their defaults (0 dB and 100 %)
  - _Verify_: `cargo test kinds` passes
  - _Depends on_: —

- [ ] **T-004** [REQ-001, REQ-002, REQ-003] Sidechain DSP: gain before the filters, 24 dB/oct cuts, Amount on the output.
  - _Files_: `Engine/src/audio/modulation/state.rs`
  - _Output_: `ScState` uses `Hp24` / `Lp24` and caches the gain; `ScState::update` takes the gain; `sc_value()` = `amount × map(level)`; new tests `the_sidechain_gain_lifts_the_follower`, `the_sidechain_amount_scales_the_output`, `the_sidechain_cuts_are_24_db_per_octave`
  - _Verify_: `cargo test the_sidechain` passes, including the existing `the_sidechain_cuts_drop_out_of_band_tones` and `the_sidechain_follower_maps_the_level_onto_the_value`; `state_is_copy_and_bounded` passes
  - _Depends on_: T-003

- [ ] **T-005** [REQ-004, REQ-006, REQ-007] Peak tracking, the sample tap and the effective cuts on `ModulatorState`.
  - _Files_: `Engine/src/audio/modulation/state.rs`
  - _Output_: `feed_sidechain_tap(mono, impl FnMut(f32, f32))` with `feed_sidechain` delegating to it; `take_sc_peak()` (mapped, scaled, then reset); the silent decay in `advance` tracks the peak; `sc_cuts()` returns 0 for a bypassed filter; test `the_sidechain_peak_catches_a_short_transient`, plus a test that the tap sees the gained pre sample and the filtered post sample
  - _Verify_: `cargo test the_sidechain` passes
  - _Depends on_: T-004

- [ ] **T-006** [REQ-006] Reusable `MiniAnalyser`.
  - _Files_: `Engine/src/audio/dsp/mini_analyser.rs` (new), `Engine/src/audio/dsp/mod.rs`
  - _Output_: `new(sample_rate, points)`, `push(a, b)`, `reset()`, `due(frames)`, `write_points(&mut Vec<u8>)`; tests: a 1 kHz tone pushed on A peaks at the nearest point in A while B stays at the floor; `write_points` appends `(2 + 2 × points) × 4` bytes; `due` fires about 30 times a second
  - _Verify_: `cargo test mini_analyser` passes
  - _Depends on_: —

## Phase 2 — engine streams

- [ ] **T-007** [REQ-004, REQ-009] Kind 4 history records in the `modulation` stream.
  - _Files_: `Engine/src/audio/modulation/host.rs`
  - _Output_: `SC_HISTORY_CAP` = 249; `sc_hist` and `sc_hist_len` appended once per control step while `stream_subscribed`; kind 4 records in `modulation_payload` with `point_seconds = CONTROL_STEP / sample_rate`; the capacity formula is extended; test `a_subscribed_wrapper_sends_sidechain_history`; `the_payload_capacity_covers_the_maximal_trailing_block` covers 32 sidechain modulators with full histories
  - _Verify_: `cargo test modulation::host` passes
  - _Depends on_: T-001, T-005

- [ ] **T-008** [REQ-006, REQ-007, REQ-009] The `"sidechain"` data stream on `ModulatedDevice`.
  - _Files_: `Engine/src/audio/modulation/host.rs`
  - _Output_: `subscribe_data` / `unsubscribe_data` handle `"sidechain"`; `configure_data("sidechain", "mod_id", id)` sets `sc_mod` and returns a `DataBuild` for a `MiniAnalyser` the first time; `apply_data_build` installs a downcast `MiniAnalyser` and otherwise forwards; `feed_device_in` and `feed_sidechain` tap the selected modulator while subscribed; `poll_device_data` sends `[mod_id, sample_rate, low_cut_hz, high_cut_hz]` + `write_points` when due, after `modulation` and before the inner device; tests `the_sidechain_stream_reports_pre_and_post`, `an_unsubscribed_wrapper_sends_no_sidechain_data`; the existing `modulation`-starves-`spectrum` regression test still passes
  - _Verify_: `cargo test modulation::host` passes; `cargo test` (all) passes; `cargo fmt --check` is clean
  - _Depends on_: T-006, T-007

## Phase 3 — Godot

- [x?] **T-009** [REQ-010] A missing modulator parameter reads its default.
  - _Files_: `Godot/data/Modulator.gd`, `Godot/tests/test_sidechain_view.gd` (new)
  - _Output_: `get_param` falls back to `get_parameter(id)`'s normalized default (0.0 when the kind is unknown); a test loads a sidechain without params 50 and 60 and reads 0 dB and 100 %
  - _Verify_: `Godot/tests/run_all.sh sidechain modulators` passes
  - _Depends on_: T-003

- [x?] **T-010** [REQ-011] Godot capacity 32 and the tooltip.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/devices/modulators/ModulatorsPane.gd`, `Godot/tests/test_modulators_ui.gd`
  - _Output_: `MAX_MODULATORS := 32`; the tooltip is formatted from the constant; the cap test uses 32 and "Maximum of 32 modulators"
  - _Verify_: `Godot/tests/run_all.sh modulators` passes
  - _Depends on_: —

- [x?] **T-011** [REQ-004] `ModLive` decodes kind 4.
  - _Files_: `Godot/devices/modulators/ModLive.gd`, `Godot/tests/test_sidechain_view.gd`
  - _Output_: `_decode_ext` reads kind 4 into `{kind, mod_id, point_seconds, peaks}`; `_on_data` stores the histories per device; `sidechain_history(device, mod_id)` returns them; a test decodes a hand-built blob with kinds 2, 3 and 4 and an unknown kind 9
  - _Verify_: `Godot/tests/run_all.sh sidechain modulators` passes
  - _Depends on_: T-007

- [x?] **T-012** [REQ-004, REQ-005] Scrolling sidechain line in `ModulatorDisplay`.
  - _Files_: `Godot/devices/modulators/ModulatorDisplay.gd`, `Godot/tests/test_sidechain_view.gd`
  - _Output_: for kind `sidechain`, a 2 s time-stamped buffer filled from `sidechain_history`, scrolled per frame one interval behind, drawn with max-per-column decimation on a 0…1 scale, the dot at the newest point; the generic `_trace` is the fallback when no kind 4 arrives; tests: an 80-point history with one peak gives a highest point equal to it, and a newest value of 0.5 sits at mid-height
  - _Verify_: `Godot/tests/run_all.sh sidechain modulators` passes
  - _Depends on_: T-011

- [x?] **T-013** [REQ-006, REQ-007] Reusable `MiniSpectrum` control.
  - _Files_: `Godot/components/visualization/MiniSpectrum.gd` (new), `Godot/tests/test_sidechain_view.gd`
  - _Output_: `set_curves`, `markers`, back and front colours, easing, the `FreqAxis` grid, and a static `decode_points(blob, offset)`; tests: decoding a hand-built blob gives 128 + 128 values and `lo_hz` / `hi_hz`; a marker at 200 Hz is drawn at `hz_to_x(200)`; a marker ≤ 0 is hidden
  - _Verify_: `Godot/tests/run_all.sh sidechain` passes
  - _Depends on_: —

- [x?] **T-014** [REQ-008] `ModParamSlot` binds a `CompactSlider`.
  - _Files_: `Godot/devices/modulators/options/ModParamSlot.gd`, `Godot/tests/test_modulators_ui.gd`
  - _Output_: `_find_control` finds a `CompactSlider`; it is bound normalized with its default, the text callback, `value_changed` → `set_param` and `ModAssign.attach_modulator`; `refresh` uses `set_value_no_signal`
  - _Verify_: `Godot/tests/run_all.sh modulators` passes
  - _Depends on_: —

- [x?] **T-015** [REQ-006, REQ-007, REQ-008] New Sidechain options layout and stream.
  - _Files_: `Godot/devices/modulators/options/SidechainOptions.tscn`, `Godot/devices/modulators/options/SidechainOptions.gd`, `Godot/tests/test_modulators_ui.gd`
  - _Output_: the Source menu and `MiniSpectrum` on the left; the Gain, Low Cut, High Cut, Attack and Release knobs and the Amount `CompactSlider` on the right; `setup` subscribes `"sidechain"` and configures `mod_id`; `_exit_tree` unsubscribes; blobs whose `mod_id` matches are decoded into the spectrum (pre gray, post white, cut markers); `_sidechain_kind_args` gains params 50 and 60; the tests check both new slots are bound and the scene is within `MAX_HEIGHT`
  - _Verify_: `Godot/tests/run_all.sh modulators sidechain` passes
  - _Depends on_: T-009, T-013, T-014

## Phase 4 — docs

- [ ] **T-016** [REQ-004, REQ-006] Protocol and subsystem docs.
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/godot-osc.md`
  - _Output_: the kind 4 record documented in the `modulation` section; the `"sidechain"` data type, its configure key, its blob and the `MiniAnalyser` point layout documented; one line in godot-osc.md on the options' own subscription
  - _Verify_: both docs mention kind 4, `"sidechain"` and the `mod_id` configure key; the layouts match the T-007 and T-008 code
  - _Depends on_: T-007, T-008

## Phase 5 — verification

- [ ] **T-017** [REQ-all] Full gates.
  - _Files_: —
  - _Output_: the gate results recorded here
  - _Verify_: `cargo fmt --check` and `cargo test` in `Engine/` pass; `Godot/tests/run_all.sh` passes in full
  - _Depends on_: T-001 – T-016

- [ ] **T-018** [REQ-all] Live check with the engine and Godot running (ask first if the user's engine holds port 7000).
  - _Files_: —
  - _Output_: notes in this task on what was and wasn't checked
  - _Verify_:
    1. A kick at 120 BPM on channel B; an EQ on channel A with a sidechain sourced from B. The panel shows one peak per beat, scrolling without steps.
    2. Options open: the gray area is full range; Low Cut 1 kHz makes the white line drop steeply below 1 kHz, with a marker at 1 kHz.
    3. Amount 50 % halves the line's height; Gain +12 dB lifts both curves and the line.
    4. Nine or more modulators on one device are all accepted, and the add cell disappears at 32.
    5. `/engine/load` stays comparable with two options panels open.
  - _Depends on_: T-017
