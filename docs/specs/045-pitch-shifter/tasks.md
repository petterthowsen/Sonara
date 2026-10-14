# Pitch Shifter — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine tests run from `Engine/`. Unit tests live in `pitch_shifter.rs`'s `mod tests`. Build-heavy
work runs one agent at a time with `CARGO_BUILD_JOBS=2`.

## Phase 1 — device skeleton, registered end to end

- [ ] **T-001** [REQ-001, REQ-010, REQ-017] Create `PitchShifterDevice` with the 8-parameter table
  from the design (IDs, modules, units, ranges, defaults). Add the `SmoothedParam`s, `apply()`
  (Pitch rounded to whole semitones), `set_parameter`/`set_param_mod`/`get_parameter`,
  `set_transport` (tempo), `prepare` (lines sized to `MAX_SWEEP_SECONDS + MAX_JITTER_OFFSET +
  headroom`), `reset`, enable/activate, and a `process_block` that so far does only the input
  sanitising and the Mix (`dry_wet_gains`, short-circuit at wet 0) with a silent wet. Register the
  device in `effects/mod.rs`, `EFFECT_IDS` and `create_effect`.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`,
    `Engine/src/audio/devices/effects/mod.rs`, `Engine/src/audio/devices/factory.rs`
  - _Output_: `sonara.builtin.pitch_shifter` appears in `builtin_device_infos()` with 8 parameters
  - _Verify_: `cargo test effect_conformance` passes with the new id included, with no
    `KNOWN_FAILING` entry
  - _Depends on_: —

## Phase 2 — DSP behaviour

- [ ] **T-002** [REQ-003, REQ-004, REQ-006, REQ-011] Granular core: the shared phasor at the
  smoothed Grain Hz (clamped 1–100), `TAPS = 2` with windows `(2/TAPS)·sin²(π·φ_k)`, integrated
  per-channel tap delays (start values for pitch up and pitch down, slope `1 − r`, clamp to
  `[D_MIN, max_delay]`), and the cached `r = 2^(cents/1200)` from the smoothed
  `100·Pitch + Fine`. Spread is not added yet. `latency_frames()` stays at the default 0.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: tests `pitch_semitones_hit_the_target_frequency`, `fine_cents_offset_the_pitch`,
    `zero_shift_is_a_constant_delay`
  - _Verify_: `cargo test pitch_shifter` + `cargo test effect_conformance`
  - _Depends on_: T-001

- [ ] **T-003** [REQ-005] Grain-rate behaviour tests: the crossfade AM period is ≈ 1/Grain, and
  there are sidebands at 100 Hz but not at 5 Hz. If the measurement shows the core doesn't match,
  fix the core.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: test `grain_rate_sets_the_crossfade_period`
  - _Verify_: `cargo test grain_rate_sets_the_crossfade_period`
  - _Depends on_: T-002

- [ ] **T-004** [REQ-005a] Grain Sync: when Sync isn't Off, `f_g = 1 / division_seconds(sync,
  tempo)`, clamped to 1–100 Hz. A tempo change moves the phasor's rate only, never its position.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: test `synced_grain_follows_tempo` (1/16 at 120 BPM → 125 ms ±5 %, Off → Hz, and no
    jump on a tempo change)
  - _Verify_: `cargo test synced_grain_follows_tempo`
  - _Depends on_: T-003

- [ ] **T-005** [REQ-009] Spread: left uses `+Spread` cents and right uses `−Spread`, each with its
  own cached ratio, sharing the phasor.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: test `spread_detunes_left_up_right_down` (including L == R at Spread 0 for a mono
    input)
  - _Verify_: `cargo test spread_detunes_left_up_right_down`
  - _Depends on_: T-002

- [ ] **T-006** [REQ-007] Jitter: a seeded `Rng`, a per-cycle rate scale of `1 + 0.5·J·u` floored
  at 1 Hz, a per-tap start offset of `J·u₀₁·min(0.25·T, MAX_JITTER_OFFSET)`, and the pitch-up
  start delay using `T_max`. Both draws are skipped at J = 0. `reset` reseeds the generator.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: test `jitter_zero_is_periodic_and_jitter_is_seeded`. `zero_shift_is_a_constant_delay`
    still passes.
  - _Verify_: `cargo test pitch_shifter`
  - _Depends on_: T-003

- [ ] **T-007** [REQ-008, REQ-013, REQ-015] Feedback and tail: the 30 Hz low cut, the 8 kHz high
  cut, `soft_clip`, and `input + feedback·fb_in` pushed after the reads. Add `TailSleep` with
  `update_tail()` on the parameters that set the tail, `on_block` in `process_block`, and
  `is_sleeping`/`mark_activity`/`update_sleep_state`.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: tests `feedback_cascades_and_stays_bounded`, `non_finite_input_never_leaks`,
    `sleep_waits_out_the_feedback_tail`
  - _Verify_: `cargo test pitch_shifter` + `cargo test effect_conformance` (the tail dies out at
    the defaults, and reset clears the tail)
  - _Depends on_: T-002

- [ ] **T-008** [REQ-012, REQ-014] Robustness tests: automating Pitch from −12 to +12 over one bar
  has a bounded max sample step, and the peak test holds at 44.1, 48 and 96 kHz after `prepare`.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: tests `pitch_automation_glides_without_clicks`, `prepare_resizes_for_sample_rate`
  - _Verify_: `cargo test pitch_shifter`
  - _Depends on_: T-005, T-006, T-007

- [ ] **T-009** [REQ-016] CPU benchmark: an ignored `cpu_pitch_shifter` (the `cpu_chorus` shape,
  run at Pitch +7, Jitter 50 %, Feedback 50 %, Spread 20) compared with `cpu_chorus` on the same
  machine.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`
  - _Output_: both numbers recorded in this task when it is checked off
  - _Verify_: `cargo test --release cpu_pitch_shifter -- --ignored --nocapture` and
    `cargo test --release cpu_chorus -- --ignored --nocapture`. Pitch Shifter ≤ Chorus (Classic).
  - _Depends on_: T-008

## Phase 3 — Godot integration

- [ ] **T-010** [REQ-018] Add an ignored `dump_pitch_shifter_view_fixture` (the Phaser's dump
  shape) and generate the fixture. Add `test_pitch_shifter_view.gd`, modelled on
  `test_phaser_view.gd`: all 8 parameters are placed, Pitch `is_whole_number()`, and Sync is a
  dropdown.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs`,
    `Godot/tests/fixtures/simple_view/pitch_shifter_params.json`,
    `Godot/tests/test_pitch_shifter_view.gd`
  - _Output_: the fixture and a passing layout test
  - _Verify_: `cargo test --lib dump_pitch_shifter_view_fixture -- --ignored`, then
    `Godot/tests/run_all.sh pitch_shifter`
  - _Depends on_: T-001

## Phase 4 — docs

- [ ] **T-011** [REQ-001] Document the device: a Built-In Devices entry with the parameter IDs (and
  the 1 Hz sync clamp) in `osc-protocol.md`, the AGENTS.md built-in list, the `effects/` line in
  engine-architecture.md, and **Grain** in the glossary.
  - _Files_: `docs/subsystems/osc-protocol.md`, `AGENTS.md`,
    `docs/subsystems/engine-architecture.md`, `CONTEXT.md`
  - _Output_: all four mention `pitch_shifter` / Grain
  - _Verify_: `grep -n "pitch_shifter" docs/subsystems/osc-protocol.md AGENTS.md docs/subsystems/engine-architecture.md`
    and `grep -n "Grain" CONTEXT.md`
  - _Depends on_: T-007

## Phase 5 — live verification

- [ ] **T-012** [REQ-001, REQ-002, REQ-011, REQ-015, REQ-017, REQ-018] Live check with the
  engine and Godot running (`Engine/run_release.sh`, then `godot --path Godot`). If the user's
  engine is already on port 7000, ask first.
  - _Files_: —
  - _Output_: results noted on the tracking issue
  - _Verify_:
    1. Add Pitch Shifter from the browser. Every knob shows st, cents, Hz or %, and Pitch steps in
       whole semitones.
    2. On a vocal or synth loop: +12 gives an octave up; Grain 5 Hz sounds smooth and Grain 80 Hz
       sounds buzzy; Sync 1/16 follows the tempo.
    3. Spread 10 cents at Mix 50 % gives a wide doubler. Feedback 60 % at +12 gives rising shimmer
       stairs.
    4. Inside the Delay's FB FX at +12, each repeat climbs. Inside a Multiband FX band, only that
       band shifts.
    5. The channel latency is unchanged. With Feedback 80 %, the device sleeps after the tail (in
       the logs or the device header).
    6. Save and reopen: the values are identical.
  - _Depends on_: T-009, T-010, T-011

- [ ] **T-013** [REQ-007] Listening decision on `TAPS`: compare 2 with 4 on a sustained pad at
  Jitter 0 % and 60 %. Keep 2 unless 4 is clearly better. Record the choice in design.md.
  - _Files_: `Engine/src/audio/devices/effects/pitch_shifter.rs` (only if the constant changes),
    `docs/specs/045-pitch-shifter/design.md`
  - _Output_: the decision recorded, with any constant change
  - _Verify_: `cargo test pitch_shifter` still passes after any change, and the user confirms by
    ear
  - _Depends on_: T-012

## Coverage

| REQ | Tasks |
|---|---|
| 001 | T-001, T-011, T-012 |
| 002 | T-012 |
| 003, 004 | T-002 |
| 005 | T-003 |
| 005a | T-004 |
| 006 | T-002, T-006 |
| 007 | T-006, T-013 |
| 008 | T-007 |
| 009 | T-005 |
| 010 | T-001 |
| 011 | T-002, T-012 |
| 012 | T-008 |
| 013 | T-007 |
| 014 | T-008 |
| 015 | T-007, T-012 |
| 016 | T-009 |
| 017 | T-001, T-012 |
| 018 | T-010, T-012 |
