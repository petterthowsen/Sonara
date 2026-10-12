# Saturator — Design

Implements [requirements.md](./requirements.md).

Paths and symbols below were re-checked against the tree on 2026-10-11 (after specs 032–036 landed).

## Context

- `Engine/src/audio/devices/effects/filter.rs` — **the template for this device.** Already ships the
  exact pattern needed: ID blocks of ten per module (`FILTER_TYPE: ParamId = 0` … `MIX = 30`,
  `GAIN = 31`), `flatten(&[&FILTER_MODULE, &LFO_MODULE, …])`, `slot_table`, `static TABLE: ParamTable`,
  a `QUALITY` enum `&["1x", "2x", "4x"]`, `DRIVE`, `MIX` (linear crossfade, 0 % bit-exact dry,
  decision 5), `CTRL_BLOCK: usize = 32`, `SWITCH_FADE_MS: f32 = 10.0`, `RAMP_MS: f32 = 5.0`, and a
  type-and-character switch that runs old and new side by side for 10 ms and crossfades (decision 8).
  Copy the shape; don't invent a new one. **Two things not to copy:** the Filter smooths with
  `SmoothedParam` (`dsp/smoothing.rs`, `sm_drive` etc.), not a `Ramp` — `Ramp` is private to
  `compressor.rs`; and its `QUALITY` change just calls `oversampler.set_factor` with no crossfade,
  which does not meet REQ-007's "no click" (see *Oversampling switch* below).
- `Engine/src/audio/devices/param_table.rs` — `Kind`/`linear`/`log`/`skewed`, `ParamSpec`,
  `spec(...)`, `.hidden()`, `.not_automatable()`, `flatten`, `slot_table`, `ParamTable`, `ParamValues`.
- `Engine/src/audio/devices/device.rs` — the `AudioDevice` trait: `process_block`, `set_parameter` /
  `set_parameter_at` (the sample-accurate automation seam), `device_id`, `device_category`,
  `audio_ports`, `parameters`, `reset`, `prepare`, `latency_frames`, `is_sleeping` /
  `mark_activity` / `update_sleep_state`, `subscribe_data` / `unsubscribe_data` /
  `configure_data` / `apply_data_build` / `poll_device_data`, `as_any_mut`.
- `Engine/src/audio/dsp/saturate.rs` — the existing helpers: `soft_clip` (rational tanh, clamped to
  ±3), `fast_tanh` (clamped to ±4, output bounded ±1), `drive_params(drive_db) -> (gain, blend)`,
  `drive(x, gain, blend)`. **Both shapers are odd by construction** — the file's own tests assert
  `soft_clip(x) + soft_clip(-x) == 0`. Odd-only means REQ-003's asymmetric/even-harmonic character
  cannot be built from these as-is.
- `Engine/src/audio/dsp/oversampler.rs` — `Oversampler::new/prepare(max_frames)/set_factor/factor/reset/process`;
  polyphase IIR half-band, 1×/2×/4×, "at 1× nothing is resampled" (per `filter.rs`'s own note), and
  no added latency is reported (spec 012 decision 2).
- `Engine/src/audio/dsp/env_follower.rs` — `EnvFollower::new(attack_ms, release_ms, sample_rate, detection)`,
  `set_times`, `process(x) -> f32`, `value()`, plus `time_coef(ms, sample_rate)`.
- `Engine/src/audio/dsp/one_pole.rs` — `one_pole_g(hz, sample_rate)`, `OnePole::{lowpass, highpass, allpass}`,
  and `one_pole_magnitude_db(g, high, freq, sample_rate)` (the exact-response helper the EQ view uses).
- `Engine/src/audio/dsp/delay_line.rs` — `DelayLine::{prepare, prepare_seconds, push, read, read_linear, read_hermite}`
  → a modulated, interpolated read exists, which is what wow & flutter needs.
- `Engine/src/audio/dsp/noise.rs` — seeded `Rng`, `WhiteNoise`, `PinkNoise` (used by the drums).
- `Engine/src/audio/dsp/spectrum.rs` — `Spectrum::new/with_window/push/bin_count/reset` (the analyser's FFT).
- `Engine/src/audio/dsp/denormal.rs` — `flush_denormals_to_zero()`.
- `Engine/src/audio/dsp/test_util.rs` — `sine`, `impulse`, `white_noise`, `pink_noise`, `log_sweep`,
  `stereo`, `render(device, input, block_sizes)`, `peak`, `rms`, `to_db`, `tone_amplitude`,
  `spectrum_db`, `time_to_db`. Everything the test plan needs already exists.
- `Engine/src/audio/devices/factory.rs` — `EFFECT_IDS` (8 entries) and `create_effect`'s match.
  `builtin_device_infos()` builds effects from `EFFECT_IDS` via `create_effect`, so an effect needs
  **no change to the `others` array** (that length only changes when a *container* is added, as 016
  notes for Multiband).
- `Engine/src/audio/devices/effects/effect_conformance.rs` — `every_builtin_effect_conforms` runs a
  fixed battery over every id in `EFFECT_IDS`: parameter round trip, defaults match metadata,
  bypass bit-exact, **Mix 0 % bit-exact dry**, finite at 44.1/48/96/192 kHz, block-size independence,
  `reset` clears the tail, tail dies out, modulation offsets, plus the wrapped-in-`ModulatedDevice`
  variant. A new effect inherits all of it by being listed; `KNOWN_FAILING` is empty today.
- `Engine/src/audio/devices/effects/compressor.rs` — the precedent for (a) a data stream:
  `"dynamics"` records, fixed byte size (`BYTES` constant), `subscribe_data` rejecting unknown
  names, `poll_device_data`; (b) an "Off + range" parameter: `SC_LOW_CUT` uses
  `skewed(0.0, 500.0, 2.0)` where 0 is Off; (c) static, estimated Auto Gain (decision 6).
- `Engine/src/audio/devices/effects/eq.rs` — the precedent for a **visualisation stream derived from
  the actual DSP**: `"spectrum"`, plus `configure_data`/`apply_data_build` for off-thread work.
- Godot: `Godot/devices/DeviceViewFactory.gd` (`BUILTIN_PANEL_SCENES` — id → preloaded scene; views
  attach on `DeviceRegistry.device_registered`); `Godot/devices/builtin/CompressorDefaultView.gd` +
  `CompressorCurve.gd` + `CompressorData.gd` + `CompressorViewState.gd` (curve drawing + a decoded
  data stream + view-local state kept in the app config); `Godot/devices/builtin/EqResponse.gd`
  (static drawing helpers), `EqViewState.gd`; the panel height `DevicePanel.HEIGHT`
  (350 px, `Godot/devices/device_lane/DevicePanel.gd`) — the panel view holds every control
  (companion views only show while the auxiliary window is open, so nothing essential goes there;
  tabs only for ~30+ parameters); the generated simple view (spec 004) covers the device until the
  custom view exists; components `Godot/components/RotaryKnob.gd`,
  `LabeledKnob.gd`, `Fader.gd`, `meter/`; `Godot/data/PresetLibrary.gd` + `DevicePreset.gd`
  (`.sonpreset` files under `Settings.get_value("presets/path")`).
- `docs/subsystems/osc-protocol.md` — documents `/channel/{id}/device/{path}/data/subscribe`,
  `/data/unsubscribe` and the "Device Data Stream (Rust → Godot)" section.
- `docs/subsystems/godot-device-views.md` — view registration and the
  `_on_view_shown`/`_on_view_hidden` subscription rule.

## Approach

One new built-in effect, `sonara.builtin.saturator`, in `devices/effects/saturator.rs`, built on the
`filter.rs` pattern: a static parameter table in module blocks of ten, an `Oversampler` wrapped
around **only** the waveshaper, a linear Mix crossfade that is bit-exact at 0 %, and a 10 ms
crossfade when the type changes.

The signal path, per channel, wet side only:

```
Input trim → Pre HPF → drive gain (× level-dependent boost)
    → [Oversampler]  shaper(type, bias)  [/Oversampler] → DC blocker
    → head bump → level-dependent HF loss → squash → Post LPF → Tilt
    → Auto Gain → Output
```

then `Mix` crossfades dry and wet linearly (spec 012 decision 5); the dry side is the untouched
input, so Mix 0 % is bit-exact by construction and `check_mix_zero_is_bit_exact_dry` passes.

**Four types, one shaper slot.** Types differ only in the curve and in which tape-only stages are
active:

| Type | Curve | Notes |
|---|---|---|
| Soft | `soft_clip` (existing, odd) | the reference character |
| Tube | **new** `asym_clip(x, b) = soft_clip(x + b) − soft_clip(b)` | even harmonics; `Bias` sets `b`. The subtraction removes the *static* DC; the signal-dependent DC that remains is what the DC blocker is for |
| Tape | Soft curve + the tape stage group gated in | level-dependent HF loss, head bump, squash, optional wow/noise |
| Hard | **new** `hard_clip(x)`: linear to ±(1 − k), a quadratic knee of width `k` = 0.1, flat at ±1 | sharper corner than Soft; the type most in need of oversampling |

`Bias` applies to every type (it is a transparent control, not a Tube secret); Tube is simply the
type whose default preset raises it. At `Bias` 0 every curve is odd.

**Tape gate.** The tape stages (head bump, HF loss, squash, wow & flutter, noise) are always
allocated and always run. Their user amounts are multiplied by a smoothed `tape_gate` scalar
(`SmoothedParam`, `SWITCH_FADE_MS`): 1 while Type is Tape, 0 otherwise. Every stage is written so
that amount 0 is exactly neutral (0 dB bump, HF-loss cutoff pinned above Nyquist ⇒ coefficient
bypass, no squash, wow depth 0, noise gain 0). So a type switch is: shaper output crossfaded old→new
over 10 ms (as `filter.rs` does with `SWITCH_FADE_MS`/`fade_inc`) **and** the tape gate ramped over
the same 10 ms. Nothing in the post chain changes identity, so nothing needs duplicating. Once the
gate has settled at 0, the tape stages short-circuit (skip work) to save CPU.

**Level dependence.** An `EnvFollower` (RMS, 10 ms attack / 150 ms release) on the pre-shaper signal
gives `env_db`. Effective drive per control block is
`drive_db + LEVEL_DEPEND × clamp(env_db − (−18), −12, +12)` — up to ±12 dB of extra drive around a
−18 dBFS reference. At `LEVEL_DEPEND` 0 the term is exactly 0.0, so the code path equals the static
curve (REQ-004's null test).

**Oversampling switch.** Two `Oversampler`s, both `prepare`d for 4×. A `QUALITY` change starts the
new factor on the idle one (after `reset`) and crossfades the two shaper outputs over
`SWITCH_FADE_MS`, then retires the old one. Only during that 10 ms does the device pay for two
shapers. This is the fix the Filter does not have; if it proves out it can be back-ported there.

**Wow & flutter.** Delay time = `depth_samples × (1 + lfo)` / 2 with `lfo ∈ [−1, 1]` (a slow wow sine
≈ 0.5 Hz plus a faster flutter ≈ 6 Hz, at a fixed ratio), read with `read_hermite` but never below
`MIN_HERMITE_DELAY` — below that, read the input directly. So at depth 0 the delay is 0 (no comb
filtering against the dry side, REQ-006), and raising depth from 0 is continuous (no click). The line
is sized in `prepare` for the maximum depth (≈ 5 ms at 192 kHz).

**Auto Gain.** Whenever the curve is rebuilt (see the `"curve"` stream), evaluate one period of a
−18 dBFS sine through the current shaper at the *static* drive and set compensation to
`−(output_rms_db − input_rms_db)`, smoothed. That is the same static, estimated approach as the
compressor (spec 012 decision 6), but measured from the real curve instead of a formula, so it is
right for every type and bias. The level-dependent boost is deliberately not compensated (it is the
effect).

**Transparent controls, per the requirements gate.** Every behaviour that changes the sound is a
visible, automatable parameter — `LEVEL_DEPEND`, `BIAS`, `INPUT`, `HF_LOSS`, `SQUASH`, `WOW`,
`NOISE`, `HEAD_BUMP`. Nothing is hidden inside a type. Changing the type therefore does **not**
rewrite the user's other settings (this closes requirements' open question 1); type-typical starting
points are shipped as presets instead. `LEVEL_DEPEND` at 0 % must be *exactly* the static path —
same code, boost of 0 dB — so REQ-004's "converges with level dependence at minimum" is provable by
a null test.

### Parameters

17 parameters in four module blocks of ten, as `filter.rs`. Ranges are proposals to confirm at the
first task; the shapes (`linear`/`log`/`skewed`, "0 = Off") follow existing devices.

| ID | Const | Name | Range / kind | Default |
|---|---|---|---|---|
| 0 | `TYPE` | Type | Enum `Soft, Tube, Tape, Hard` | Soft |
| 1 | `DRIVE` | Drive | 0 … 36 dB | 6 dB |
| 2 | `BIAS` | Bias | −1 … +1 (linear) | 0 |
| 3 | `LEVEL_DEPEND` | Dynamics | 0 … 100 % | 0 % |
| 4 | `INPUT` | Input | −24 … +24 dB | 0 dB |
| 5 | `QUALITY` | Quality | Enum `1x, 2x, 4x`, `not_automatable` | 2x |
| 10 | `PRE_HPF` | Low Cut | Off, 20 … 1000 Hz (`skewed`, 0 = Off — `SC_LOW_CUT` pattern) | Off |
| 11 | `POST_LPF` | High Cut | 1 kHz … 20 kHz, top = Off | Off |
| 12 | `TILT` | Tone | −6 … +6 dB (pivot 1 kHz) | 0 dB |
| 20 | `HF_LOSS` | HF Loss | 0 … 100 % | 50 % |
| 21 | `HEAD_BUMP` | Head Bump | 0 … 6 dB | 2 dB |
| 22 | `SQUASH` | Squash | 0 … 100 % | 30 % |
| 23 | `WOW` | Wow | 0 … 100 % | 0 % |
| 24 | `NOISE` | Noise | Off, −90 … −40 dBFS | Off |
| 30 | `MIX` | Mix | 0 … 100 % | 100 % |
| 31 | `OUTPUT` | Output | −24 … +24 dB | 0 dB |
| 32 | `AUTO_GAIN` | Auto Gain | Bool | On |

`TYPE` is automatable (it crossfades); `QUALITY` is not, matching the CPU-cost nature of the switch.
Tape defaults (20–22) are non-zero so that selecting Tape is immediately audible (REQ-005); they do
nothing until the tape gate opens. All continuous parameters are modulation targets through the
existing modulator path (specs 018/036); `effect_conformance`'s `check_modulation_offsets` covers it.

**Rejected alternative: separate devices per character.** Five devices would duplicate the shared
80 % (drive staging, oversampling, tone, mix, auto gain, parameter table, view) five times, and the
suite already expresses variants as one device with a type parameter (`filter.rs`). Rejected also:
a hidden per-type level-dependence curve — the requirements gate asked for transparent controls.

**Rejected alternative: a static waveshaper with no level tracking.** Cheaper, but
`docs/daw-device-research.md` §4 names level-dependent behaviour as the property that separates a
musical saturation from a "painted on" one, and REQ-004 makes it a requirement.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| Two `Oversampler`s (current + switching) | audio thread | `prepare(max_frames)` sized once for the maximum factor (4×); never resized while running | yes — buffers allocated in `prepare`, not in `process_block` |
| `ParamValues` + `SmoothedParam`s (drive, input, output, mix, bias, tone, tape amounts, `tape_gate`) | audio thread (parameters arrive through `set_parameter` / `set_parameter_at` under the state lock) | `apply(param_id, real)` sets targets, as `filter.rs` | yes |
| `EnvFollower`s (level dependence, HF-loss tracking, squash) | audio thread | internal to the device; reset by `reset()` | yes |
| `OnePole`s (pre HPF, post LPF, tilt, DC blocker), tape HF-loss filter, head-bump state | audio thread | internal | yes |
| `DelayLine` (wow & flutter) | audio thread | `prepare_seconds` in `prepare`; **not touched at all** when the wow knob is 0, so a wow-free render is deterministic | yes |
| Curve/harmonic record buffer | audio thread writes, command thread reads | `poll_device_data` copies one fixed-size record (the `"dynamics"` pattern) | yes — fixed-size, preallocated, filled on the record boundary |
| Data-stream subscription flag | command thread | `subscribe_data` / `unsubscribe_data`; the audio thread only tests the flag | yes |

No new thread, no new lock, no new shared structure: everything is per-device state already owned
by the audio thread, exactly as `filter.rs` and `compressor.rs` do it.

## Data and protocol changes

**No new OSC message.** Device parameters travel the existing normalized path
(`/channel/{id}/device/{path}/param/{id}`, values 0.0–1.0 per ADR 0005), and the built-in device
list is generated from `EFFECT_IDS`, so Godot learns about the Saturator from `/builtin/request` →
`/builtin/info` → `/builtin/complete` with no protocol addition.

**One new device data stream: `"curve"`** (Rust → Godot), following `"dynamics"`/`"spectrum"`:

- Subscribed via the existing `/channel/{id}/device/{path}/data/subscribe [s:data_type]` with
  `data_type = "curve"`; any other name is rejected by `subscribe_data`, as in `compressor.rs`.
- Payload: one fixed-size record — a header (`effective_drive_db`, `env_db`), the transfer curve
  (128 points over input −1…+1, f32) and the first 16 harmonic magnitudes (dB, f32) of a sine at the
  current operating level through that curve. Both are generated from the **actual shaper function**
  at the current settings, so the view cannot drift from the DSP (REQ-012).
- Cost split: the curve + harmonics are a pure function of (type, static drive, bias) and are rebuilt
  only when one of those changes, at control rate (128 shaper calls + a 16-bin DFT over one period ≈
  a few thousand multiplies, well under one block). The header changes continuously with the
  envelope and is refreshed every record.
- Rate: records are emitted at the existing device-data poll rate while subscribed (the
  `"dynamics"` pattern), so the operating-point dot moves live; the curve body only differs when it
  was rebuilt. Not subscribed → nothing is built or copied.
- `docs/subsystems/osc-protocol.md` gains the stream under the "Device Data Stream (Rust → Godot)"
  section as its own task, alongside the device-list mention.

**Godot synced properties / settings:** none. Parameter metadata arrives from `/builtin/info`, so
`Godot/data/Device.gd`, `DeviceInstance.gd` and `Settings.gd` need no change — the view is the only
Godot code. That is worth stating because the usual "three edits plus the doc" rule applies to
*new messages*, and this spec adds none.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/devices/effects/saturator.rs` | **New.** `SaturatorDevice`: parameter table (17 params in 4 module blocks), signal path above, `Oversampler` around the shaper, type crossfade, tape stage group, `"curve"` stream, `reset`, `prepare`, `latency_frames() -> 0`, plus its `mod tests`. |
| `Engine/src/audio/dsp/saturate.rs` | Add the asymmetric shaper (`asym_clip(x, bias)` with its DC removed), a knee'd `hard_clip`, and a `dc_block` helper; keep the existing odd-only functions and their tests untouched. |
| `Engine/src/audio/devices/effects/mod.rs` | `mod saturator;` + `pub use saturator::SaturatorDevice;`. |
| `Engine/src/audio/devices/factory.rs` | Add `"sonara.builtin.saturator"` to `EFFECT_IDS` and a `create_effect` arm. No `others` change. |
| `docs/subsystems/osc-protocol.md` | Document the `"curve"` device data stream (subscription, record layout, rate). |
| `Godot/devices/builtin/SaturatorDefaultView.gd` | **New, last task.** Panel view holding all 17 parameters, no tabs: type selector, transfer curve with operating-point dot and harmonic bars beside it, Drive/Bias/Dynamics/Input knobs, tone row (Low Cut/High Cut/Tone), tape row shown inactive unless Type is Tape, Mix/Output/Auto Gain, quality selector — fitted to `DevicePanel.HEIGHT`. Reuses `RotaryKnob`/`LabeledKnob`, `meter/`. Until it lands, the generated simple view is the UI, so the engine tasks are testable from Godot on their own. |
| `Godot/devices/builtin/SaturatorDefaultView.tscn` | **New.** Scene for the above. |
| `Godot/devices/builtin/SaturatorCurve.gd` | **New.** Draws the transfer curve + harmonics from the decoded `"curve"` record (template: `CompressorCurve.gd`, decoder: `CompressorData.gd`). |
| `Godot/devices/builtin/SaturatorViewState.gd` | **New, small.** View-local prefs (show harmonics, curve/history toggle) through the app config, like `CompressorViewState.gd` / `EqViewState.gd`. |
| `Godot/devices/DeviceViewFactory.gd` | Register `"sonara.builtin.saturator"` in `BUILTIN_PANEL_SCENES` (with the custom view task). |
| `Godot/data/PresetLibrary.gd` | **Not touched** — factory presets descoped for v1 (see Open questions, decided 2026-10-11). |
| GitHub issue | One tracking issue (labels `engine`, `godot`, `device`, `builtins`) — the backlog moved to GitHub Issues per `AGENTS.md`; `docs/specs/README.md` still says `TODO.md` and should be updated separately. |

Explicitly **not** touched: `Godot/settings/Settings.gd` (no user-facing setting is added),
`Engine/src/audio/devices/factory.rs`'s `others` array, `effect_conformance.rs` (the new effect is
covered automatically by `EFFECT_IDS`), `Engine/src/audio/commands/` and `Engine/src/osc/`
(no new message).

## Migration and compatibility

- **Nothing is persisted that did not exist before.** New device → new project entries; nothing in
  the parameter path changes shape. Existing projects are untouched.
- A project saved with the Saturator will not load in an engine that predates this spec (unknown
  device id) — the same situation as every previously added effect, and the reason it is additive
  rather than a parameter renumbering.
- No `_RENAMED_KEYS` entry is needed because no settings key is added or renamed.
- `Mix` follows the suite convention (0 % bit-exact dry, linear), so nothing about existing
  automation behaviour changes.

## Test plan

- **Unit, `cargo test` (`saturator.rs` `mod tests`):**
  - `soft_type_is_odd_and_tube_type_is_not` — a 300 Hz sine through Soft has no 2nd harmonic above
    the floor; through Tube with `Bias` raised the 2nd harmonic is present (REQ-003). Uses
    `test_util::sine` + `spectrum_db` + `tone_amplitude`.
  - `level_depend_widens_the_thd_gap` — THD(−6 dBFS) − THD(−18 dBFS) is larger at `LEVEL_DEPEND`
    100 % than at 0 % (REQ-004).
  - `level_depend_zero_nulls_against_static_curve` — at 0 % the output is bit-identical to a
    reference render of the static shaper (REQ-004).
  - `tape_controls_inactive_outside_tape` — Soft with `HF_LOSS`/`HEAD_BUMP`/`SQUASH` at max nulls
    against Soft with them at 0 (REQ-005).
  - `quality_switch_does_not_click` / `wow_from_zero_does_not_click` — same jump-threshold check as
    the type switch (REQ-006, REQ-007).
  - `wow_zero_has_no_delay` — at Mix 100 % and Drive 0, impulse in → impulse out at frame 0 (REQ-006).
  - `auto_gain_tracks_drive` — −18 dBFS sine, drive 0 → 36 dB with Auto Gain on stays within ±3 dB RMS
    (REQ-009).
  - `post_tone_cuts_harsh_band_but_keeps_lows` — REQ-010's 6 dB / 1 dB figures.
  - `output_has_no_dc` — Tube, bias max, drive max: mean of output < −60 dBFS after settling.
  - `input_trim_is_gain_and_output_trim_is_gain` — measured between `INPUT` and `OUTPUT` at the
    granularity of the ramps (REQ-009).
  - `mix_zero_is_bit_exact_at_maximum_drive` — belt-and-braces on top of the conformance check.
  - `type_change_does_not_click` — render through a type change and assert no sample-to-sample jump
    above a threshold (REQ-011), the way filter's own switch tests do.
  - `tape_hf_loss_follows_level` — high-frequency energy of a 6 kHz sine falls as input level rises
    with `HF_LOSS` up, and is unchanged with it at 0 (REQ-005).
  - `noise_off_silence_in_silence_out` and `noise_on_is_seeded` — silence in → zeros with `NOISE`
    Off; two renders with noise on are bit-identical (REQ-006).
  - `oversampling_reduces_aliasing` — 7 kHz sine driven hard: non-harmonic energy at 4× is lower
    than at 1× at matched output level (REQ-007).
  - `nan_and_inf_input_stay_finite` — the `∞`/`NaN` injection test (REQ-013).
  - `curve_record_matches_the_shaper` — sweep −1…+1 through the device's own shaper and compare with
    the curve it would stream (REQ-012).
  - `latency_is_zero_at_every_quality` (REQ-007).
- **Conformance (automatic):** `cargo test effect_conformance` — the new id is picked up from
  `EFFECT_IDS`, so parameter round trip, defaults, bypass, Mix 0 %, every sample rate, block-size
  independence, `reset`, tail, and modulation offsets all run without new code (REQ-008, REQ-011).
- **CPU:** a `#[ignore]`d release-mode benchmark rendering 10 s through Saturator and Filter at 1× and
  4× and asserting the ratio from REQ-015 (`cargo test --release saturator_cpu -- --ignored`).
- **Godot:** `Godot/tests/devices/test_saturator_view.gd`, run via `Godot/tests/run_all.sh saturator` — builds a
  `SaturatorDefaultView` with a fake instance and asserts the curve node draws something and that
  the view subscribes to `"curve"` in `_on_view_shown` and unsubscribes in `_on_view_hidden`
  (REQ-012, plus the scoped-listener rule).
- **Live:** engine + Godot running — add the Saturator to a channel and to a Multiband FX band (it
  must insert in both, REQ-002), automate Drive over two bars and listen for zipper noise, sweep the
  type selector while playing a drum loop and listen for clicks, and watch engine load at 4× with
  several instances for the CPU budget (REQ-015). Record what was and wasn't checked in `STATUS.md`
  and comment on the tracking issue.

## Risks

| Risk | Mitigation |
|---|---|
| Underspecified tape stage turns into a hobby project (hysteresis modelling) | The tape character is explicitly *not* a circuit model: level-dependent HF loss (one-pole cutoff driven by an `EnvFollower`), a one-pole low-shelf head bump, and soft-clip-based squash. Keep it to those three plus modulation; anything more is a follow-up spec. |
| Bias + drive + level dependence produce DC or thumps | DC blocker after the shaper; `Bias` does not move it; a DC-offset test on the output. |
| Type crossfade doubles post-chain state and gets complex | Only the shaper output is blended; the tape stages are faded by the `tape_gate` scalar and are exactly neutral at 0, so nothing needs duplicating. If that turns out false, fall back to filter.rs's old/new side-by-side instance pattern. |
| Oversampling buffers allocated on the wrong path | Allocate for the maximum factor in `prepare` only (both instances); `set_factor` may only switch which region is used. |
| Wow delay comb-filters against dry at partial Mix | Inherent to modulated delay; depth-scaled delay means it only happens when wow is actually on. Documented in the view tooltip. |
| Hard type aliases badly at 1× | Default `QUALITY` is 2x; the Hard factory preset uses 4x. |
| Noise keeps a sleeping-eligible device awake, or sleep cuts hiss abruptly | Sleep is decided on input silence (ADR 0008), so hiss stops after the idle period; noise is faded with the wet path on wake/sleep like any tail. |
| Alias claims that can't be substantiated | REQ-007 asks for a *relative* measurement (4× lower than 1× at matched output), not an absolute dB claim. |
| CPU cost at 4× across many instances | Measure with `/engine/load` in the live check; keep the shaper to a handful of multiplies (the existing rational tanh is 4 mults) and run control-rate work at `CTRL_BLOCK` frames. |
| Factory presets need a mechanism that does not exist (`PresetLibrary` has no bundled source) | Either add the read-only bundled folder + seed-on-first-use, or descope REQ-016's preset half before the tasks gate. Decide before implementation, not during. |

## Open questions

- [x] Factory presets: add the bundled-preset mechanism to `PresetLibrary.gd`, or descope
      REQ-016's preset half for v1? (Blocks the tasks gate — it is a task either way.)
      **Decided 2026-10-11: descoped for v1** — no bundled-preset mechanism is added;
      REQ-016's preset half is marked descoped in requirements.md.
- [x] Head bump shape: one-pole low-shelf built from `one_pole.rs` (cheap, 6 dB/oct) or a new
      dedicated biquad? `FilterMode` in `dsp/svf.rs` has no shelf variant, so either way it is new
      code; propose the one-pole version and confirm at the first task.
      **Confirmed 2026-10-11 (T-009 as-built):** one-pole low shelf — TPT `OnePole::lowpass` at
      100 Hz, low band = lp, high band = x − lp, exact bypass at gain 0.
- [x] Harmonic display placement — in the panel view next to the curve. The panel holds everything;
      no companion view (it only shows with the auxiliary window open) and no tabs (17 parameters).
      The custom view is the last task; the generated simple view covers the device before that.
- [x] Curve record size — 128 curve points and 16 harmonics. Harmonic bars are not FFT bins, so
      sharing the spectrum analyser's bin count would not have bought shared view code.
- [ ] Parameter ranges and defaults in the table above — confirm at the first task.
- [ ] Should the type selector's four types also appear as a preset per type (proposed), or does the
      type knob make per-type presets redundant?
