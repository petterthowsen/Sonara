# Sidechain modulator view, gain and amount; modulator capacity — Design

Implements [requirements.md](./requirements.md).

## Context

Engine (`Engine/src/`):

- `audio/modulation/kinds.rs` holds the per-kind parameter tables. The sidechain block is
  `SC_LOW_CUT` 0, `SC_HIGH_CUT` 10, `SC_ATTACK` 20, `SC_RELEASE` 30, `SC_SOURCE` 40 in
  `SC_SPECS`, with `SC_SLOTS: [u8; 50]`. `MAX_KIND_PARAMS = 5` sizes `ModParams.norm`.
- `audio/modulation/state.rs`
  - `ScState` holds two `Svf`s with `FilterMode::Hp12` / `Lp12` coefficients and an
    `EnvFollower` (peak). `ScState::update` rebuilds the cached coefficients.
  - `ModulatorState::feed_sidechain(&[f32])` runs the filters and the follower per sample.
  - `ModulatorState::sc_value()` maps the follower level from −60…0 dBFS onto 0…1.
  - `ModulatorState` is `Copy` and currently 328 bytes, measured for this spec.
- `audio/dsp/svf.rs` already has `FilterMode::Lp24` and `Hp24`: two cascaded stages inside a
  single `Svf`, tuned as a 4-pole Butterworth at resonance 0 through `resonance_to_k`.
- `audio/modulation/host.rs` — `ModulatedDevice`:
  - `mods: [Option<ModulatorState>; MAX_MODULATORS]`, with `CONTROL_STEP = 64`.
  - `feed_device_in` feeds Device In per control step, in `CONTROL_STEP` stack chunks.
  - `AudioDevice`-side `feed_sidechain(mod_id, &[f32])` receives cross-channel taps from
    `audio/mixing/sidechain.rs`, one whole previous block at a time.
  - `modulation_payload` builds the `modulation` stream with a trailing ext block of `{u8 kind,
    u8 len, bytes}` records; kind 2 is the modulator state and kind 3 the mod→mod offset.
  - `poll_device_data` answers `modulation` when due, otherwise the wrapped device.
  - `configure_data` and `apply_data_build` forward to the wrapped device.
- `audio/mixing/mod.rs` `forward_device_events` polls each device on the audio callback, up to
  `DATA_FRAMES_PER_BLOCK = 4` frames per block, one per data type. Every stream allocates its
  payload `Vec` there (an existing, accepted pattern, also used by the EQ).
- `audio/command_worker/devices.rs` handles `configure_data` under the lock, runs the returned
  `DataBuild` with the lock released, installs the result with `apply_data_build` under the
  lock, and drops whatever comes back after releasing it.
- `audio/devices/effects/eq.rs` has a private `Analyser`: two `Spectrum::with_window(size, 0.0,
  Window::BlackmanHarris)` plus two `LogSpectrum`, transformed in `poll_device_data` at
  `ANALYSER_RATE_HZ`. `dsp/spectrum.rs` provides `Spectrum::push(f32)`, `transform()` and
  `power()`; `dsp/log_spectrum.rs` provides `LogSpectrum::configure`, `set_ballistics`,
  `update` and `db`.
- `audio/modulation/mod.rs` has `MAX_MODULATORS = 8`. `audio/modulation/matrix.rs` has
  `MAX_ROUTES = 64`. `audio/modulation/voice.rs` `VoiceModSpec` holds kinds and params per
  modulator plus routes. `audio/devices/instruments/polysynth/voice.rs` `Voice.mods` holds one
  `[Option<ModulatorState>; MAX_MODULATORS]` per voice, with `MAX_POLYPHONY = 64` voices, and
  `mod_touched: [u8; MAX_MODULATORS]` is a bitmask over parameter-table slots.

Godot (`Godot/`):

- `devices/modulators/ModulatorDisplay.gd` draws a generic `_trace` of 40 samples for
  non-LFO, non-envelope kinds, fed by `ModLive.modulator_states_changed`.
- `devices/modulators/ModLive.gd`
  - `_on_data` decodes the `modulation` stream.
  - `_decode_ext` reads kinds 2 and 3.
  - `modulator_state(device, mod_id)` exposes the kind 2 state.
  - The stream is subscribed while a view of the device is shown (`view_shown` / `view_hidden`).
- `devices/modulators/options/SidechainOptions.tscn` / `.gd` has the Source menu and four
  `ModParamSlot` knobs. `ModulatorOptions.MAX_HEIGHT = 240`.
- `devices/modulators/options/ModParamSlot.gd` binds `RotaryKnob`, `OptionButton` and
  `CheckButton`, and attaches knobs through `ModAssign.attach_modulator`.
- `components/CompactHSlider.gd` (`CompactSlider`) is a value slider. `ModAssign` works on it
  unchanged, and it has `set_value_no_signal`, `min_value`, `max_value`, `default_value` and
  `value_text_callback`.
- `components/visualization/FreqAxis.gd` provides `hz_to_x` and `draw_grid` for a
  log-frequency plot.
- `core/AudioEngineOSC.gd` provides `subscribe_device_data`, `unsubscribe_device_data`,
  `configure_device_data` and the `device_data_received(osc_path, data_type, blob)` signal.
- `data/Modulator.gd` `get_param` returns `params.get(id, 0.0)`. A missing parameter therefore
  reads 0, not its default. `data/DeviceInstance.gd` loads saved `params` as-is, has
  `MAX_MODULATORS := 8`, and `devices/modulators/ModulatorsPane.gd` hard-codes the tooltip
  "Maximum of 8 modulators".

## Approach

**DSP (REQ-001 to REQ-003).**
- Append two parameters to the sidechain table: `SC_GAIN` = 50 ("Gain", dB, `linear(-24, 24)`,
  default 0) and `SC_AMOUNT` = 60 ("Amount", %, `linear(0, 100)`, default 100). This raises
  `MAX_KIND_PARAMS` to 7.
- `ScState` caches the linear gain and multiplies each fed sample by it before the filters.
- Both filters switch to `Hp24` / `Lp24`, which `Svf` already provides with no size change.
- `sc_value()` becomes `amount × map(level)`.

**Panel line (REQ-004, REQ-005).**
- The panel display needs a dense history, not the 20 Hz snapshot. A new **kind 4** ext record
  in the existing `modulation` stream carries it: `u8 mod_id, f32 point_seconds, u8 count,
  count × u8`. Each point is the output's peak over one control step (64 frames), quantized
  0…255. Peaks need display resolution only, and a `u8` keeps a poll's worth within the
  record's `u8 len`.
- `ModulatorState` tracks the raw follower peak since the last take. Mapping is monotonic, so
  the peak is mapped once at take time.
- The wrapper appends one point per control step into a fixed ring per modulator slot, only
  while `modulation` is subscribed, and drains it into the payload.
- Old decoders skip kind 4 by `len`.
- Godot's display keeps a 2 s time-stamped point buffer per sidechain panel. Each frame it scrolls
  it by elapsed time, drawn one interval behind like the dot, and draws it as a
  max-per-pixel-column polyline on a fixed 0…1 scale.

**Spectrum (REQ-006, REQ-007).**
- A new wrapper-owned data stream, `"sidechain"`. Godot subscribes it and then selects the
  modulator with `data/configure "sidechain" "mod_id" <id>`.
- The first configure returns a `DataBuild` that allocates a `MiniAnalyser` (a new reusable
  `dsp/` block, below): pre = after Gain, post = after the filters, 128 points, with the FFT
  size following the EQ's 4096-at-48 kHz rule. Later configures only change the selected id.
- While subscribed with an analysis installed, the wrapper feeds the selected modulator through a
  tap that pushes each sample's `(pre, post)` pair into the two spectra.
- `poll_device_data` transforms both at ~30 Hz and sends one blob: a header `[mod_id,
  sample_rate, low_cut_hz, high_cut_hz]`, then the `MiniAnalyser` points (`lo_hz, hi_hz`, 128
  pre dB values, 128 post dB values), as little-endian f32.
- The cut values are the *effective* (modulated) frequencies, or 0 while a filter is bypassed,
  so the markers follow modulation without Godot recomputing offsets.

**Reusable mini analyser (engine and Godot).** Both halves are written so other views can use
them later, and neither knows about sidechains:

- Engine: `dsp/mini_analyser.rs` `MiniAnalyser`, two signals (A and B) over a shared FFT size
  and point count. It provides `new(sample_rate, points)` (allocates), `push(a, b)`, `reset()`,
  `due(frames) -> bool` (its own ~30 Hz clock) and `write_points(&mut Vec<u8>)` (transforms
  both, then appends `lo_hz, hi_hz, points × A dB, points × B dB` as f32). Callers write their
  own header in front of it. It is built from `Spectrum` and `LogSpectrum`, like the EQ's
  analyser, but has no options.
- Godot: `components/visualization/MiniSpectrum.gd` `MiniSpectrum`, a `Control` that holds no
  OSC state. It provides `set_curves(back: PackedFloat32Array, front: PackedFloat32Array,
  lo_hz, hi_hz)`, `markers: Array[float]` (Hz; ≤ 0 hides one) and themable back-fill and
  front-line colours. It draws a faint `FreqAxis` grid, the back curve as a filled area, the
  front curve as a line, and the markers. It eases toward each new frame, so 30 Hz data looks
  smooth. A static `decode_points(blob, offset)` helper reads the `MiniAnalyser` layout.
- The sidechain options own the stream (subscribe, configure, decode the header) and feed a
  `MiniSpectrum`.

**Rejected alternatives.**
- *Extract the EQ's `Analyser` itself.* It carries resolution and speed options and
  alternates pre and post frames for its own stream format. Moving the EQ onto `MiniAnalyser`
  is possible later, but it is out of scope here, so the EQ doesn't change.
- *Reuse `SpectrumRenderer.gd`.* It is built around linear FFT bins, styles and legends, not
  log-spaced points, which makes it too heavy for a 150 px panel.
- *A separate `sidechain_history` stream for the panel line.* It would need its own ref-counted
  subscription in Godot. The `modulation` stream is already subscribed exactly while the panel
  is visible, and its ext block was designed to grow this way.
- *Moving PolySynth voice modulators to a compact per-voice list for the capacity increase.*
  The measured cost at 32 slots is 64 × 32 × ~345 B ≈ 0.7 MB per PolySynth instance (from
  0.17 MB), which is acceptable. The fixed arrays stay. Revisit only if PolySynth instance
  memory becomes a problem.

**Capacity (REQ-011).**
- `MAX_MODULATORS` goes to 32 and `MAX_ROUTES` to 128. Everything is sized from these
  constants already.
- `mod_touched` stays a `u8`, because it masks parameter slots (7), not modulators.
- Godot's `DeviceInstance.MAX_MODULATORS` goes to 32, and the pane tooltip formats the
  constant.

**Old projects (REQ-010).** `Modulator.get_param` falls back to the kind parameter's default
when a value is absent, so a sidechain loaded without Amount reads 100 % in the UI. The engine
already starts every parameter at its table default and only receives the values Godot sends.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `ScState` gain cache, `sc_peak` (in `ModulatorState`) | audio callback, under the state lock | command thread sets params under the lock (existing path) | yes — `Copy`, fixed size |
| `ModulatedDevice.sc_hist: [[u8; SC_HISTORY_CAP]; MAX_MODULATORS]` + lengths | audio callback (append per control step, drain in `modulation_payload`) | nothing else | yes — inline fixed arrays (32 × 256 B = 8 KB per wrapper) |
| `ModulatedDevice.sc_subscribed`, `sc_mod: Option<u8>` | command thread (`subscribe_data` / `configure_data`, under the lock) | audio callback reads them | yes |
| `ModulatedDevice.sc_analysis: Option<Box<MiniAnalyser>>` | built by a `DataBuild` on the command thread, lock released; installed by `apply_data_build` under the lock | audio callback pushes samples and transforms in `poll_device_data` | yes — preallocated; push and transform don't allocate (`spectrum.rs` contract) |
| Replaced `MiniAnalyser` | command thread | returned from `apply_data_build`, dropped after the lock is released (existing path) | yes |
| Spectrum payload `Vec<u8>` | audio callback | `forward_device_events` → status channel | as today: one small allocation per poll, the existing pattern for every stream |

Unsubscribing keeps the installed analysis idle (no feed, no transform), so nothing is dropped
under the lock. It is dropped with the wrapper.

## Data and protocol changes

No new OSC address. Existing addresses carry:

- **`modulation` stream, new ext record kind 4** (Rust → Godot), one per sidechain modulator
  with points this poll:
  `u8 mod_id, f32 point_seconds, u8 count, count × u8 peak` (peak / 255 = output 0…1),
  `len = 6 + count`, `count ≤ SC_HISTORY_CAP` (249).
- **`sidechain` data stream** (new data type on `data/subscribe`, `data/unsubscribe`,
  `data/configure`, `data`):
  - Configure key `"mod_id"` takes the modulator id as a float. It is required after every
    subscribe; the view resends it, as the EQ does with its options.
  - Rust → Godot blob, little-endian f32: `[mod_id, sample_rate, low_cut_hz, high_cut_hz]`,
    then `lo_hz, hi_hz`, 128 pre dB values and 128 post dB values. A cut value of 0 means the
    filter is bypassed. The floor is −160 dB.
- **Persisted:** sidechain modulators save parameters 50 (Gain) and 60 (Amount) in their
  `params` dict through the existing generic path. No format version change.
- **Godot model:** `Modulator.get_param` falls back to the parameter default. There is no new
  signal or setter; Gain and Amount use the existing `set_modulator_param`.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/modulation/kinds.rs` | `SC_GAIN` = 50 and `SC_AMOUNT` = 60 constants and specs; `SC_SPECS` grows to 7 and `SC_SLOTS` to `[u8; 70]`; `MAX_KIND_PARAMS` = 7; kind tests updated |
| `Engine/src/audio/modulation/state.rs` | `ScState`: `Hp24`/`Lp24`, a gain cache (`cached_gain_db`, `gain`), `peak` (raw follower max); `ScState::update` takes the gain; `feed_sidechain` becomes a wrapper over a new `feed_sidechain_tap(mono, impl FnMut(f32, f32))`; `advance`'s silent decay also tracks the peak; `sc_value()` applies Amount; new `take_sc_peak() -> f32` (mapped and scaled) and `sc_cuts() -> (f32, f32)` (effective cuts, 0 = bypassed); `state_is_copy_and_bounded` comment updated; new tests |
| `Engine/src/audio/dsp/mini_analyser.rs` (new) | `MiniAnalyser` (see Approach); tests: a tone lands on the right point in A only, `write_points` length, `due` cadence |
| `Engine/src/audio/dsp/mod.rs` | `pub mod mini_analyser` |
| `Engine/src/audio/modulation/mod.rs` | `MAX_MODULATORS` = 32 |
| `Engine/src/audio/modulation/matrix.rs` | `MAX_ROUTES` = 128 |
| `Engine/src/audio/modulation/host.rs` | `SC_HISTORY_CAP` = 249; fields `sc_hist`, `sc_hist_len`, `sc_subscribed`, `sc_mod`, `sc_analysis`, `sc_frames`, `sc_interval`; append peaks per control step while `stream_subscribed`; kind 4 records in `modulation_payload`, with the capacity formula extended; `feed_device_in` and `feed_sidechain` use the tap for `sc_mod` while active; `subscribe_data` / `unsubscribe_data` / `configure_data` / `apply_data_build` / `poll_device_data` handle `"sidechain"` (downcast `MiniAnalyser`, otherwise forward); the blob is the `sidechain` header followed by `MiniAnalyser::write_points`; `the_payload_capacity_covers_the_maximal_trailing_block` updated; new tests |
| `Engine/src/audio/devices/instruments/polysynth/mod.rs` | none expected beyond recompiling (sized by the constants); `VoiceModSpec` and `Voice` size checked by test |
| `Godot/data/Modulator.gd` | `get_param` falls back to `get_parameter(id)`'s default, normalized |
| `Godot/data/DeviceInstance.gd` | `MAX_MODULATORS := 32` |
| `Godot/devices/modulators/ModulatorsPane.gd` | the tooltip uses `"Maximum of %d modulators" % device.MAX_MODULATORS` |
| `Godot/devices/modulators/ModLive.gd` | `_decode_ext` reads kind 4 (`{kind, mod_id, point_seconds, peaks: PackedFloat32Array}`); `_on_data` stores the histories per device; new `static func sidechain_history(device, mod_id) -> Dictionary` returns `{point_seconds, peaks, time}` for the latest payload |
| `Godot/devices/modulators/ModulatorDisplay.gd` | sidechain branch: a time-stamped point buffer (2 s) filled from `ModLive.sidechain_history` on `modulator_states_changed`, scrolled in `_process`, drawn on a 0…1 scale with max-per-column decimation; the dot at the newest point; falls back to `_trace` when no kind 4 arrives (old engine) |
| `Godot/components/visualization/MiniSpectrum.gd` (new) | the reusable `MiniSpectrum` control (see Approach) |
| `Godot/devices/modulators/options/SidechainOptions.tscn` / `.gd` | layout: Source menu and spectrum on the left; Gain, Low Cut, High Cut, Attack and Release knobs plus an Amount `CompactSlider` on the right; within `MAX_HEIGHT`; the script also owns the `"sidechain"` stream: subscribe and configure `mod_id` in `setup`, unsubscribe in `_exit_tree`, decode the header, and feed the `MiniSpectrum` (back = pre in gray, front = post in white, markers = cuts) |
| `Godot/devices/modulators/options/ModParamSlot.gd` | binds a `CompactSlider` (range 0…1 normalized, default, text callback, `value_changed`, `ModAssign.attach_modulator`; `refresh` uses `set_value_no_signal`) |
| `Godot/tests/test_modulators_ui.gd` | `_sidechain_kind_args` gains params 50 and 60; tests for the slots, the slider binding, the cap of 32 and the tooltip |
| `Godot/tests/test_sidechain_view.gd` (new) | decode of kind 4 and of the spectrum blob; line peak and scale; marker x; old-project default |
| `docs/subsystems/osc-protocol.md` | kind 4 record; the `"sidechain"` data type, configure key and blob |
| `docs/subsystems/godot-osc.md` | one line: the sidechain options subscribe `"sidechain"` themselves |

## Migration and compatibility

- **Old project, new build:** Gain and Amount are absent from the saved `params`, so they read
  their defaults on both sides (REQ-010). The only audible change is the 24 dB/oct slope.
- **Project with more than 8 modulators on a device, opened in an old build:** the old engine
  rejects ids ≥ 8 with a warning, so those modulators don't run. This is accepted and documented
  in the requirements.
- **New Godot, old engine:** `"sidechain"` subscribe fails with a warning, so the spectrum stays
  empty. No kind 4 records arrive, so the display falls back to `_trace`.
- **Old Godot, new engine:** kind 4 is skipped by `len`, and nothing subscribes `"sidechain"`.

## Test plan

- **Unit (engine)**, `cargo test` in `Engine/`:
  - `the_sidechain_gain_lifts_the_follower` (state.rs): −30 dBFS sine → 0.5 at 0 dB, 0.9 at +24 dB (REQ-001).
  - `the_sidechain_amount_scales_the_output` (state.rs): follower 0.8 → 0.4, 0.8 and 0 (REQ-002).
  - `the_sidechain_cuts_are_24_db_per_octave` (state.rs): ≥ 40 dB down two octaves out (REQ-003). The existing `the_sidechain_cuts_drop_out_of_band_tones` keeps passing.
  - `the_sidechain_peak_catches_a_short_transient` (state.rs): a 10 ms burst inside a step gives `take_sc_peak` ≈ the burst level after the step's value has decayed (REQ-004).
  - `a_subscribed_wrapper_sends_sidechain_history` (host.rs): kind 4 record decode, count matches the control steps polled (REQ-004).
  - `the_sidechain_stream_reports_pre_and_post` (host.rs): subscribe + configure + install the build; a 50 Hz tone with Low Cut 500 Hz → pre peak near 50 Hz, post ≥ 40 dB lower there; header cuts = (500, 0) (REQ-006, REQ-007).
  - `an_unsubscribed_wrapper_sends_no_sidechain_data` (host.rs) (REQ-009).
  - `a_device_holds_32_modulators_and_128_routes` (host.rs) (REQ-011).
  - `voice_state_stays_bounded` (polysynth/mod.rs): prints and bounds `size_of::<VoiceModSpec>()` and the per-instance voice modulator bytes (REQ-011 performance).
- **Godot**, `Godot/tests/run_all.sh modulators sidechain`:
  - `test_modulators_ui.gd`: Gain and Amount slots bound, Amount is a `CompactSlider`, the scene is within `MAX_HEIGHT`, the cap is 32 and the tooltip reads "Maximum of 32 modulators" (REQ-008, REQ-011).
  - `test_sidechain_view.gd`:
    - an 80-point history with one peak → the highest line point equals that peak (REQ-004);
    - Amount 50 % with follower 1.0 → the newest point at mid-height (REQ-005);
    - spectrum blob decode → 128 + 128 values, markers at `hz_to_x(200)`, no marker at 20 Hz (REQ-006, REQ-007);
    - a modulator loaded without params 50 and 60 reads 0 dB and 100 % (REQ-010).
- **Live** (engine and Godot running; ask before touching the user's engine on port 7000):
  1. A kick at 120 BPM on channel B, with an EQ on channel A carrying a sidechain whose Source is
     B. The panel line shows one peak per beat, scrolling smoothly.
  2. Open the options. The gray area is full range. With Low Cut at 1 kHz, the white line drops
     steeply below 1 kHz and a marker sits at 1 kHz.
  3. Amount at 50 % halves the line. Gain at +12 dB lifts both curves and the line.
  4. Add 9 or more modulators to one device. All are accepted, and the add cell disappears at 32.

## Risks

| Risk | Mitigation |
|---|---|
| Spectrum FFTs on the audio callback cost time with several sidechain views open | Only the selected modulator of a subscribed device runs; at ~30 Hz × two 4096-point FFTs this is the EQ's cost. Check `/engine/load` with two options panels open |
| `modulation` payload grows (up to 32 × 255 B of kind 4) | Only sidechain modulators emit kind 4, and only while subscribed; the payload capacity is preallocated per poll |
| The cross-channel feed puts a whole block's peak in the first control step | The display shows a ≤ 5 ms lead at 256 frames; accepted |
| PolySynth memory grows about fourfold | Measured by `voice_state_stays_bounded`; the compact per-voice list is the documented fallback |
| Godot draws a 1500-point line per sidechain panel per frame | Max-per-pixel-column decimation to the display width before drawing |

## Open questions

- [ ] None blocking.
