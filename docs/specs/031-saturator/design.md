# Saturator — Design

Implements [requirements.md](./requirements.md).

Every path and symbol below was checked against the tree with `search_files` before being written.

## Context

- `Engine/src/audio/devices/effects/filter.rs` — **the template for this device.** Already ships the
  exact pattern needed: ID blocks of ten per module (`FILTER_TYPE: ParamId = 0` … `MIX = 30`,
  `GAIN = 31`), `flatten(&[&FILTER_MODULE, &LFO_MODULE, …])`, `slot_table`, `static TABLE: ParamTable`,
  a `QUALITY` enum `&["1x", "2x", "4x"]`, `DRIVE`, `MIX` (linear crossfade, 0 % bit-exact dry,
  decision 5), `CTRL_BLOCK: usize = 32`, `SWITCH_FADE_MS: f32 = 10.0`, `RAMP_MS: f32 = 5.0`, and a
  type-and-character switch that runs old and new side by side for 10 ms and crossfades (decision 8).
  Copy the shape; don't invent a new one.
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
  (static drawing helpers), `EqViewState.gd`; components `Godot/components/RotaryKnob.gd`,
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
| Soft | `soft_clip` / `fast_tanh` (existing, odd) | the reference character |
| Tube | **new** asymmetric: `soft_clip(x + bias)` minus the DC the bias adds | even harmonics; `Bias` is the control |
| Tape | Soft curve + the tape stage group active | level-dependent HF loss, head bump, squash |
| Hard | **new** hard clip with a small knee | sharper corner than Soft; more odd energy |

The tape-only stages (head bump, HF loss, squash, wow & flutter, hiss) are **always allocated and
always run**, with neutral coefficients for the other types (0 dB bump, unity HF, no squash, 0 %
wow/noise). That keeps the type switch a coefficient change on a fixed chain instead of a
structural change, and it is what makes the 10 ms crossfade cheap: only the shaper's output is
blended (old curve vs new curve) while the post chain never changes identity. This mirrors how
`filter.rs` handles `TYPE`/`CHARACTER` with `SWITCH_FADE_MS` and `fade_inc`.

**Transparent controls, per the requirements gate.** Every behaviour that changes the sound is a
visible, automatable parameter — `LEVEL_DEPEND`, `BIAS`, `INPUT`, `HF_LOSS`, `SQUASH`, `WOW`,
`NOISE`, `HEAD_BUMP`. Nothing is hidden inside a type. Changing the type therefore does **not**
rewrite the user's other settings (this closes requirements' open question 1); type-typical starting
points are shipped as presets instead. `LEVEL_DEPEND` at 0 % must be *exactly* the static path —
same code, boost of 0 dB — so REQ-004's "converges with level dependence at minimum" is provable by
a null test.

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
| `Oversampler` high-rate buffers | audio thread | `prepare(sample_rate, max_frames)` sized once for the maximum factor (4×); never resized while running | yes — buffers allocated in `prepare`, not in `process_block` |
| `ParamValues` + `Ramp`s (drive, input, output, mix, bias, tone, tape amounts) | command thread writes, audio thread reads | `set_parameter` / `set_parameter_at`; read through the same `Ramp` pattern as `filter.rs` (`Ramp::new(real(...))`) | yes |
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
- Payload: one fixed-size record per update — the transfer curve (N points over input −1…+1, f32)
  followed by harmonic magnitudes (M bins, dB, f32), the curve generated from the **actual shaper**
  at the current settings, so the view cannot drift from the DSP (REQ-012).
- Rate: on subscription and on any parameter change that affects the curve, not per block — the
  curve is a pure function of parameters, so there is nothing to stream continuously.
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
| `Godot/devices/builtin/SaturatorDefaultView.gd` | **New.** Panel view: knob rows per module, transfer-curve panel, harmonic display, oversampling selector, type selector. Reuses `RotaryKnob`/`LabeledKnob`, `meter/`, and `EqResponse.gd`'s drawing helpers. |
| `Godot/devices/builtin/SaturatorDefaultView.tscn` | **New.** Scene for the above. |
| `Godot/devices/builtin/SaturatorCurve.gd` | **New.** Draws the transfer curve + harmonics from the decoded `"curve"` record (template: `CompressorCurve.gd`, decoder: `CompressorData.gd`). |
| `Godot/devices/builtin/SaturatorViewState.gd` | **New, small.** View-local prefs (show harmonics, curve/history toggle) through the app config, like `CompressorViewState.gd` / `EqViewState.gd`. |
| `Godot/devices/DeviceViewFactory.gd` | Register `"sonara.builtin.saturator"` in `BUILTIN_PANEL_SCENES`. |
| `Godot/data/PresetLibrary.gd` | Add a bundled/read-only factory preset folder that is seeded into the user preset root on first use — see Open questions; if that mechanism is not worth it for v1, REQ-016's factory-preset half is descoped instead. |
| `Godot/presets/saturator/*.sonpreset` | **New.** Six factory presets: one per type plus two "bus"/"gentle" examples. |
| `TODO.md` | One-line entry for the spec (per `docs/specs/README.md`). |

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
  - `harmonics_grow_with_input_level` — same drive at −18 and −6 dBFS; `LEVEL_DEPEND` 0 % makes the
    two THDs converge (REQ-004).
  - `input_trim_is_gain_and_output_trim_is_gain` — measured between `INPUT` and `OUTPUT` at the
    granularity of the ramps (REQ-009).
  - `mix_zero_is_bit_exact_at_maximum_drive` — belt-and-braces on top of the conformance check.
  - `type_change_does_not_click` — render through a type change and assert no sample-to-sample jump
    above a threshold (REQ-011), the way filter's own switch tests do.
  - `tape_hf_loss_follows_level` — high-frequency energy of a 6 kHz sine falls as input level rises
    with `HF_LOSS` up, and is unchanged with it at 0 (REQ-005).
  - `noise_and_wow_off_is_deterministic` — two identical renders are bit-identical with `WOW`/`NOISE`
    at 0 (REQ-006); silence in → silence out.
  - `oversampling_reduces_aliasing` — 7 kHz sine driven hard: non-harmonic energy at 4× is lower
    than at 1× at matched output level (REQ-007).
  - `nan_and_inf_input_stay_finite` — the `∞`/`NaN` injection test (REQ-013).
  - `curve_record_matches_the_shaper` — sweep −1…+1 through the device's own shaper and compare with
    the curve it would stream (REQ-012).
  - `latency_is_zero_at_every_quality` (REQ-007).
- **Conformance (automatic):** `cargo test effect_conformance` — the new id is picked up from
  `EFFECT_IDS`, so parameter round trip, defaults, bypass, Mix 0 %, every sample rate, block-size
  independence, `reset`, tail, and modulation offsets all run without new code (REQ-008, REQ-011).
- **Godot:** `godot --headless --path Godot -s <script>` — a small test that builds a
  `SaturatorDefaultView` with a fake instance and asserts the curve node draws something and that
  the view subscribes to `"curve"` in `_on_view_shown` and unsubscribes in `_on_view_hidden`
  (REQ-012, plus the scoped-listener rule).
- **Live:** engine + Godot running — add the Saturator to a channel and to a Multiband FX band (it
  must insert in both, REQ-002), automate Drive over two bars and listen for zipper noise, sweep the
  type selector while playing a drum loop and listen for clicks, and watch engine load at 4× with
  several instances for the CPU budget (REQ-015). Record what was and wasn't checked in `STATUS.md`
  and mark the `TODO.md` entry.

## Risks

| Risk | Mitigation |
|---|---|
| Underspecified tape stage turns into a hobby project (hysteresis modelling) | The tape character is explicitly *not* a circuit model: level-dependent HF loss (one-pole cutoff driven by an `EnvFollower`), a one-pole low-shelf head bump, and soft-clip-based squash. Keep it to those three plus modulation; anything more is a follow-up spec. |
| Bias + drive + level dependence produce DC or thumps | DC blocker after the shaper; `Bias` does not move it; a DC-offset test on the output. |
| Type crossfade doubles post-chain state and gets complex | Only the shaper output is blended; the post chain's coefficients are neutral for non-tape types, so nothing needs duplicating. If that turns out false, fall back to filter.rs's old/new side-by-side instance pattern. |
| Oversampling buffers allocated on the wrong path | Allocate for the maximum factor in `prepare` only; `set_factor` may only switch which region is used. |
| Alias claims that can't be substantiated | REQ-007 asks for a *relative* measurement (4× lower than 1× at matched output), not an absolute dB claim. |
| CPU cost at 4× across many instances | Measure with `/engine/load` in the live check; keep the shaper to a handful of multiplies (the existing rational tanh is 4 mults) and run control-rate work at `CTRL_BLOCK` frames. |
| Factory presets need a mechanism that does not exist (`PresetLibrary` has no bundled source) | Either add the read-only bundled folder + seed-on-first-use, or descope REQ-016's preset half before the tasks gate. Decide before implementation, not during. |

## Open questions

- [ ] Factory presets: add the bundled-preset mechanism to `PresetLibrary.gd`, or descope
      REQ-016's preset half for v1? (Blocks the tasks gate — it is a task either way.)
- [ ] Head bump shape: one-pole low-shelf built from `one_pole.rs` (cheap, 6 dB/oct) or a new
      dedicated biquad? `FilterMode` in `dsp/svf.rs` has no shelf variant, so either way it is new
      code; propose the one-pole version and confirm at the first task.
- [ ] Does the harmonic display belong in the Panel view (space: `DevicePanel.HEIGHT` is 350 px, and
      spec 015 already reports the compressor overflowing it) or in a Window view like the EQ's
      bands companion?
- [ ] Curve record size: N curve points and M harmonic bins need fixed values; propose 128 and 32,
      confirm against the spectrum analyser's existing bin count so the view code can be shared.
- [ ] Should the type selector's four types also appear as a preset per type (proposed), or does the
      type knob make per-type presets redundant?
