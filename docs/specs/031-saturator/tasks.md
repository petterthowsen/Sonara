# Saturator — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine tests run from `Engine/`. Unit tests live in `saturator.rs`'s and `saturate.rs`'s `mod tests`.

## Phase 1 — shaper curves and the device skeleton

- [ ] **T-001** [REQ-003] Add `asym_clip(x, b) = soft_clip(x + b) − soft_clip(b)` and a knee'd
  `hard_clip(x)` (linear to ±0.9, quadratic knee, flat at ±1) to `dsp/saturate.rs`. Leave the
  existing functions and tests untouched.
  - _Files_: `Engine/src/audio/dsp/saturate.rs`
  - _Output_: both functions with tests: `asym_clip(0, b) == 0`; `asym_clip` is odd at `b = 0`;
    `hard_clip` is continuous, monotonic and bounded ±1; `hard_clip` reaches ±1 sooner than `soft_clip`
  - _Verify_: `cargo test saturate`
  - _Depends on_: —

- [ ] **T-002** [REQ-001, REQ-011] Create `SaturatorDevice` with the 17-parameter table from the
  design (IDs, ranges and defaults; `QUALITY` `not_automatable`), `SmoothedParam`s, `apply()`,
  `prepare`/`reset`, `latency_frames() -> 0`, and a pass-through `process_block` that already does
  Input → Mix (bit-exact dry at 0 %) → Output. Register it in `effects/mod.rs`, `EFFECT_IDS` and
  `create_effect`.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`, `Engine/src/audio/devices/effects/mod.rs`,
    `Engine/src/audio/devices/factory.rs`
  - _Output_: `sonara.builtin.saturator` shows up in `builtin_device_infos()` with 17 parameters
  - _Verify_: `cargo test effect_conformance` passes with the new id included (no `KNOWN_FAILING`
    entry); `cargo test saturator`
  - _Depends on_: —

- [ ] **T-003** [REQ-002, REQ-003, REQ-008] Wet path core: drive gain → shaper selected by `TYPE`
  (Soft/Tube/Hard; Tape uses Soft for now) with `BIAS` → DC blocker, at 1× only. Smooth Drive and
  Bias per sample.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: audible saturation; tests `soft_type_is_odd_and_tube_type_is_not`,
    `mix_zero_is_bit_exact_at_maximum_drive`, `output_has_no_dc`, `nan_and_inf_input_stay_finite`
  - _Verify_: `cargo test saturator` + `cargo test effect_conformance`
  - _Depends on_: T-001, T-002

- [ ] **T-004** [REQ-011] Type crossfade: on a `TYPE` change, run the old and new shaper side by side
  for `SWITCH_FADE_MS` and crossfade (the `filter.rs` `fade_inc` pattern).
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: test `type_change_does_not_click` (all 12 type pairs, mid-signal)
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-003

## Phase 2 — oversampling, dynamics and gain

- [ ] **T-005** [REQ-007, REQ-013] Wrap only the shaper in an `Oversampler`. Use two instances, both
  prepared for 4× in `prepare`. A `QUALITY` change resets the idle instance, starts it at the new
  factor and crossfades over `SWITCH_FADE_MS`. Nothing is allocated in `process_block`.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: tests `oversampling_reduces_aliasing`, `quality_switch_does_not_click`,
    `latency_is_zero_at_every_quality`
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-004

- [ ] **T-006** [REQ-004] Level dependence: an RMS `EnvFollower` (10 ms / 150 ms) before the shaper.
  Effective drive = `drive_db + LEVEL_DEPEND × clamp(env_db + 18, −12, +12)`, updated per
  `CTRL_BLOCK`. At 0 % the term is exactly 0.0.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: tests `level_depend_widens_the_thd_gap`, `level_depend_zero_nulls_against_static_curve`
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-003

- [ ] **T-007** [REQ-009] Auto Gain: when type, static drive or bias changes, run one period of a
  −18 dBFS sine through the current shaper at control rate and set the smoothed compensation to the
  RMS difference. Do not compensate the level-dependent boost. `OUTPUT` is applied after it.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: tests `auto_gain_tracks_drive`, `input_trim_is_gain_and_output_trim_is_gain`
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-006

## Phase 3 — tone and tape

- [ ] **T-008** [REQ-010] Tone: Low Cut (one-pole HPF, Off at 0) before drive, and High Cut (one-pole
  LPF, Off at the top) plus Tilt (a ±6 dB one-pole shelf pair, pivot 1 kHz) after the DC blocker. Each
  is exactly bypassed at its neutral value.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: test `post_tone_cuts_harsh_band_but_keeps_lows` (2–5 kHz down ≥ 6 dB; the fundamental
    and the harmonics below 1 kHz within 1 dB)
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-003

- [ ] **T-009** [REQ-005] Tape stages behind a smoothed `tape_gate` (1 only while Type is Tape,
  ramped over `SWITCH_FADE_MS` with the type crossfade):
  - head bump as a one-pole low-shelf (the design's proposal; confirm here, or switch to a biquad
    and update the design);
  - level-dependent HF loss, with a one-pole LPF cutoff driven by an `EnvFollower`;
  - squash, as soft-clip peak compression.

  Each stage is exactly neutral at amount × gate = 0 and skips its work once the gate has settled at 0.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: tests `tape_hf_loss_follows_level`, `tape_controls_inactive_outside_tape`, tape
    peak-to-RMS lower than Soft's at the same settings, Soft↔Tape switch does not click
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-004, T-008

- [ ] **T-010** [REQ-006] Wow & flutter and noise. The delay is `depth × (1 + lfo) / 2`, mixing a
  ≈ 0.5 Hz wow sine with a ≈ 6 Hz flutter sine; it reads the input directly below
  `MIN_HERMITE_DELAY`, and the line is sized in `prepare` for 5 ms at 192 kHz. Noise is a seeded
  `PinkNoise` at the `NOISE` level, Off by default. Both are scaled by `tape_gate`.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: tests `wow_zero_has_no_delay`, `wow_from_zero_does_not_click`,
    `noise_off_silence_in_silence_out`, `noise_on_is_seeded`
  - _Verify_: `cargo test saturator` + `cargo test effect_conformance` (the tail and `reset` checks
    still pass with wow on)
  - _Depends on_: T-009

## Phase 4 — sleep, CPU, data stream

- [ ] **T-011** [REQ-014] Hook up `DeviceSleepState` (ADR 0008) like the other effects. On wake, the
  envelope followers and filters start from reset, so the first hit is clean.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: test: 10 s of silence → device sleeps → a drum-like burst renders identical to a fresh
    device, with no click at the transition
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-010

- [ ] **T-012** [REQ-015] CPU benchmark: an `#[ignore]`d test that renders 10 s through Saturator
  (Tape, drive 24 dB, wow on) and Filter at 1× and 4×, 512 frames at 48 kHz, and asserts the
  Saturator costs ≤ 1.5× the Filter.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: ratio printed and asserted
  - _Verify_: `cargo test --release saturator_cpu -- --ignored --nocapture`
  - _Depends on_: T-010

- [ ] **T-013** [REQ-012] `"curve"` data stream (the compressor's `"dynamics"` pattern).
  `subscribe_data` accepts only `"curve"`. Each fixed-size record is a header
  (`effective_drive_db`, `env_db`), then 128 curve points over −1…+1, then 16 harmonic magnitudes in
  dB. The curve body is rebuilt only when type, static drive or bias changes, sharing the evaluation
  with T-007. Records are emitted at the poll rate while subscribed, and nothing is built when
  unsubscribed.
  - _Files_: `Engine/src/audio/devices/effects/saturator.rs`
  - _Output_: test `curve_record_matches_the_shaper` (each streamed point equals the shaper output
    for that input), plus record size and unknown-name rejection
  - _Verify_: `cargo test saturator`
  - _Depends on_: T-007

## Phase 5 — docs

- [ ] **T-014** [REQ-001, REQ-012] Document the Saturator in the built-in device list and the
  `"curve"` stream (subscription name, byte layout, rate) under "Device Data Stream (Rust → Godot)".
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: the stream is documented well enough to write the decoder from it
  - _Verify_: the layout in the doc matches the `BYTES` constant and the encode order in `saturator.rs`
  - _Depends on_: T-013

## Phase 6 — engine live check (generated simple view)

- [ ] **T-015** [REQ-002, REQ-007, REQ-011, REQ-014, REQ-015] Live check with the generated simple
  view, before any custom UI exists.
  - _Files_: `STATUS.md`
  - _Output_: notes on what was and wasn't checked
  - _Verify_: `./run_release.sh` + `godot --path Godot`. Then:
    - add the Saturator to a channel, to a slot chain and to Multiband FX band 2 (only that band
      distorts);
    - automate Drive over two bars (no zipper noise);
    - switch Type and Quality while a drum loop plays (no clicks);
    - leave 10 s of silence, then play a hit (it is intact);
    - watch `/engine/load` with several instances at 4× (no xruns over one minute).
  - _Depends on_: T-014

## Phase 7 — custom view (last)

- [ ] **T-016** [REQ-012] `SaturatorData.gd`: decode the `"curve"` record (template:
  `CompressorData.gd`).
  - _Files_: `Godot/devices/builtin/SaturatorData.gd`
  - _Output_: typed access to the header, the curve points and the harmonics
  - _Verify_: covered by T-018's test (decoding a hand-built record)
  - _Depends on_: T-014

- [ ] **T-017** [REQ-012] `SaturatorCurve.gd`: draw the transfer curve, an operating-point dot from
  `effective_drive_db`/`env_db`, and harmonic bars with odd and even harmonics coloured differently.
  Use `UiTheme` colours.
  - _Files_: `Godot/devices/builtin/SaturatorCurve.gd`
  - _Output_: a drawable control fed by `SaturatorData`
  - _Verify_: T-018 test asserts it draws something for a non-empty record
  - _Depends on_: T-016

- [ ] **T-018** [REQ-005, REQ-012] `SaturatorDefaultView.gd/.tscn`: a single panel with no tabs that
  holds all 17 parameters and fits `DevicePanel.HEIGHT`:
  - the type selector, and the curve with its harmonic bars;
  - Drive, Bias, Dynamics and Input;
  - a tone row (Low Cut, High Cut, Tone);
  - a tape row, dimmed unless Type is Tape;
  - Mix, Output, Auto Gain and Quality.

  Subscribe to `"curve"` in `_on_view_shown` and unsubscribe in `_on_view_hidden`. Register the view
  in `BUILTIN_PANEL_SCENES`. Add `SaturatorViewState.gd` only if a view-local preference turns out to
  be needed.
  - _Files_: `Godot/devices/builtin/SaturatorDefaultView.gd`, `.tscn`, `Godot/devices/DeviceViewFactory.gd`,
    `Godot/tests/devices/test_saturator_view.gd`
  - _Output_: the custom panel replaces the simple view
  - _Verify_: `Godot/tests/run_all.sh saturator` (curve draws; subscribe on show and unsubscribe on
    hide; the tape row is dimmed for non-Tape types); live: the panel fits without clipping
  - _Depends on_: T-017

## Phase 8 — presets (blocked on a decision)

- [x] **T-019** [REQ-016] **Decide first:** add a bundled, read-only factory-preset source to
  `PresetLibrary.gd`, or descope REQ-016's preset half for v1. If presets are descoped, mark
  REQ-016's preset half descoped in requirements.md and close this task.
  **Decided 2026-10-11: descoped for v1.** requirements.md REQ-016 and design.md's open
  questions + file list are updated.
  - _Files_: `docs/specs/031-saturator/requirements.md` or `Godot/data/PresetLibrary.gd`
  - _Output_: the decision is recorded in the design's open questions
  - _Verify_: the open question in design.md is checked off
  - _Depends on_: —

- [x] **T-020** [REQ-016] (Only if T-019 keeps presets.) **Descoped with T-019's decision — nothing to implement.** Implement the bundled source and ship six
  presets: Soft, Tube (bias raised), Tape, Hard (4x), Gentle Bus and Drum Crush.
  - _Files_: `Godot/data/PresetLibrary.gd`, `Godot/presets/saturator/*.sonpreset`, a test under
    `Godot/tests/`
  - _Output_: the presets appear in the Saturator's preset list, read-only, next to user presets
  - _Verify_: `Godot/tests/run_all.sh preset`; live: each preset loads and sounds like its name
  - _Depends on_: T-019, T-018

## Phase 9 — wrap-up

- [ ] **T-021** [REQ-016, REQ-all] Final live pass, plus save → reopen persistence: set Tape and
  drive 12 dB, save, reopen, and the values come back identical. Then open a tracking GitHub issue
  (labels `engine`, `godot`, `device`, `builtins`), or comment on the existing one, with the result.
  - _Files_: `STATUS.md`
  - _Output_: all REQs are verified or explicitly noted as not checked
  - _Verify_: the save/reopen round trip; the issue comment links this spec
  - _Depends on_: T-018 (and T-020 if presets are kept)
