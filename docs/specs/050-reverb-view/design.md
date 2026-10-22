# Reverb View — Design

Implements [requirements.md](./requirements.md).

## Context

- `Engine/src/audio/devices/effects/reverb.rs` — `ReverbDevice`. `process_sample(in_l, in_r, held)`
  is the single per-sample path for every algorithm and slot combination (called from the three
  loops in `render`); it returns the wet pair after tone, ducking and width, before Wet FX and
  Mix. `Absorbent` is the Decay EQ (two cascaded TPT one-pole low shelves at Low Freq and two
  high shelves at High Freq, gains from `shelf_db`). `early()` reads `early_taps(algo)` (tables
  `EARLY_ROOM`, `EARLY_HALL`, `EARLY_PLATE`, ms at Size 50 %) scaled by
  `SIZE_MIN_SCALE + size × (SIZE_MAX_SCALE − SIZE_MIN_SCALE)` and normalized by
  `early_norms()`. Sleep is `TailSleep`, driven by `update_sleep_state`. No data stream today.
- `Engine/src/audio/devices/effects/compressor.rs` — the pattern to copy: `subscribe_data`,
  `unsubscribe_data`, `poll_device_data`, a fixed `RING_CAPACITY` record array, `poll_interval`
  from `DATA_RATE_HZ`, `push_record` on the audio path.
- `Engine/src/audio/mixing/mod.rs` `forward_device_events` — polls `poll_device_data` for every
  device each block and forwards `EngineStatus::DeviceData` (existing path; the blob `Vec` is
  built there for every stream today).
- `Godot/devices/builtin/saturator/SaturatorDefaultView.gd` (+ `.tscn`) — the newest panel view:
  controls tagged with `metadata/param`, `_build` / `_setup`, `_sync_subscription` against the
  `AudioEngineOSC` autoload looked up through `load_osc`, `device_data_received`.
- `Godot/devices/builtin/saturator/SaturatorData.gd`, `compressor/CompressorData.gd` — constants,
  engine-mirroring math and the blob decoder in one `RefCounted`.
- `Godot/devices/builtin/eq/EqCurveEditor.gd` — a drawn editor with draggable nodes, writing
  through `ParameterActions.set_real`.
- `Godot/history/ParameterActions.gd` — undoable edits; `begin_gesture` / `end_gesture` merge a
  drag's edits per parameter into one step.
- `Godot/components/ValueTooltip.gd` (`ValueTooltip.attach`), `LabeledKnob.gd`, `RotaryKnob.gd`,
  `SegmentedControl.gd`, `DeviceSlotButton.gd` (click toggles `container.toggle_slot(key)`;
  `bind_to_slot`).
- `Godot/devices/DeviceViewFactory.gd` `BUILTIN_PANEL_SCENES` — registers panel views; the
  Simple View toggle already overrides a registered panel view.
- `Godot/data/DeviceInstance.gd` — `slot_devices(key)`, `slots_changed`, `enabled`,
  `enabled_changed`, `get_parameter_real`.
- `Godot/devices/device_lane/DevicePanel.gd` `HEIGHT = 350.0`.

## Approach

**The decay map is computed in Godot, not measured.** `ReverbData.gd` mirrors the engine's
decay math: for each frequency it evaluates the `Absorbent` shelves' magnitude exactly (TPT
one-pole = bilinear with prewarp, so `LP(f) = 1 / (1 + j·tan(πf/fs)/g)` with
`g = tan(π·fc/fs)`), per section, at the gains `shelf_db` gives for a reference line length
`REF_LINE_S = 0.05` s. The band T60 is then `T(f) = 60·d / (60·d/Decay − S_dB(f))`. On the
shelf plateaus this is exactly `Decay × Mult`, independent of `d`, and in between it follows the
engine's skirts. The level at time `t` and frequency `f` is
`−60·(t − PreDelay)/T(f) + cut_dB(f)`, where `cut_dB` is the 12 dB/oct SVF high-pass and
low-pass magnitude at Low Cut and High Cut. Early-reflection ticks come from the same tap
tables (copied into `ReverbData.gd` with a comment naming the Rust constants), placed at
`PreDelay + ms × size_scale`, with brightness from gain × norm × Early; both channels' taps are
drawn as full-height (broadband) columns in one row. Diffusion is a visual estimate, not
mirrored from the engine (whose diffuser feeds only the tank): each column is blurred over
± Diffusion × 12 ms (fainter as it widens), and the tail's opacity fades in from Pre-Delay over
`(15 ms + (1 − Diffusion) × 120 ms) × size_scale` (`tail_build_s`, `tail_onset`), so low
Diffusion reads as discrete echoes ahead of a late-building tail and high Diffusion as a wash
running into a dense one. Time runs on a square-root axis, `x = sqrt(t / span)`, so the onset
(~100 ms) gets about a fifth of the width at a 3 s span instead of a few pixels; the grid labels
show the warp (ms under 1 s, lines skipped when their labels would crowd). The envelope strip
stays linear: it is a scrolling history ending at "now", not anchored at t = 0. The map is
redrawn only when a parameter or the span changes.

*Rejected:* streaming a measured impulse response or a spectrogram from the engine. It would
show Diffusion and Tank FX truthfully, but a 30 s IR can't be rendered on the audio thread, an
offline render needs a cloned device on another thread, and a spectrogram of music doesn't show
the parameters' effect. The parameter model is exact where the user aims (the plateaus and
the 1 kHz decay), costs nothing in the engine, and makes the handles possible.

**The live strip is a new `"envelope"` data stream on the Reverb**, built like the compressor's
`"dynamics"`: a small `EnvelopeScope` struct inside `ReverbDevice` with a preallocated record
array. `process_sample` feeds it `max(|in_l|, |in_r|)` and `max(|wl|, |wr|)` behind one
`if self.scope.subscribed` branch. Every `RECORD_FRAMES = 256` frames it stores
`[in_peak_db, wet_peak_db]`. `poll_device_data` drains it at about 20 Hz. The blob header
carries `record_seconds` (256 / sample rate), so Godot needs no sample-rate lookup. The wet tap
is before Wet FX and Mix, so the tail shows even at Mix 0 % and with a Wet FX chain that adds
latency. The stream does not touch `update_sleep_state` (REQ-010), unlike the compressor.

**Godot keeps the strip on a wall clock.** `ReverbEnvelopeStrip` holds a ring of the last
`MAX_HISTORY_S = 64` s of records (the longest span is 0.5 s + 30 s × 2 rounded up to 60 s). On
each `_process` it advances "now". Arriving records fill the ring at the write head, and if the
head lags "now" by more than `GAP_S = 0.15` s, the gap is filled with floor records, so a
sleeping or bypassed reverb scrolls silence. Drawing bins the ring into one min/max column per
pixel over the current span.

**Handles.** `ReverbDecayMap` hit-tests in this priority: knees, the 1 kHz contour, cut lines,
the Pre-Delay edge. Press calls `ParameterActions.begin_gesture()`, motion calls `set_real`,
release calls `end_gesture()`, so each changed parameter gets one undo step (REQ-007).
Mappings:

| Handle | Position | Drag → value |
|---|---|---|
| Contour | (PreDelay + T(1 kHz), 1 kHz) | Decay ← Decay × (t − PreDelay)/(T(1 kHz)) |
| Low knee | (PreDelay + Decay × LowMult, LowFreq) | x → LowMult = (t − PreDelay)/Decay; y → LowFreq |
| High knee | (PreDelay + Decay × HighMult, HighFreq) | x → HighMult; y → HighFreq |
| Pre-Delay edge | vertical line at PreDelay | x → PreDelay |
| Cut lines | horizontal lines at Low Cut, High Cut | y → frequency |

Values are clamped to the `ParamInfo` range. Double-click calls `ParameterActions.reset` on the
handle's parameter(s). Hover draws the handle highlighted and shows a `ValueTooltip` with the
same text the knob would show (`"%.2f s"`, `"×%.2f"`, Hz with k above 1000). While a drag is in
progress, `span_locked = true` (REQ-005). The span target is
`snap(PreDelay + max_f T(f) × 1.1)` over the steps `[0.5, 1, 2, 3, 5, 8, 10, 15, 20, 30, 45, 60]` s,
eased with a 150 ms exponential. While frozen, it keeps the last unfrozen target.

**Freeze** (REQ-006): every `T(f)` returns `INF`. The map shades the full plane after
Pre-Delay at 0 dB with a snowflake mark top-right, and the handles that set decay (contour and
the knees' x) are disabled.

**Tank FX note** (REQ-011): the view watches `slots_changed` and each Tank FX device's
`enabled_changed`. `approximate = slot_devices("tank_fx").any(enabled)` draws "≈ Tank FX" in the
map corner and dashes the contour.

### Scene first, previewable in the editor

The whole layout lives in `ReverbDefaultView.tscn`, with every column, knob, toggle, segmented
control and both `DeviceSlotButton` tiles placed as nodes and editable in the Godot editor.
Parameter controls carry `metadata/param` (the parameter name), and slot tiles carry
`metadata/slot` (`"tank_fx"` / `"wet_fx"`). `_build` only collects and wires them; the script
creates no controls. `ReverbData`, `ReverbDecayMap` and `ReverbEnvelopeStrip` are `@tool`. Without
a device, the map draws the engine's default parameter values (`ReverbData.DEFAULTS`), and in the
editor (`Engine.is_editor_hint()`) the strip draws a canned decay of one hit, so the scene shows a
realistic picture when opened. Only drawn content (map rows, ticks, traces) is generated at
runtime.

### Layout (fits DevicePanel.HEIGHT 350)

```
Room|Hall|Plate                                                     (header row)
┌Input──┐┌Space──┐┌───────── decay map (≈ 380 × 150) ─────────┐┌Tone──┐┌──────┐┌Out───┐
│PreDly ││Size   ││                                          ││LowCut││Wet FX││Duck  │
│Early  ││Decay  │├───────── envelope strip (≈ 380 × 40) ─────┤│HiCut ││ tile ││Width │
│Diffuse││❄Freeze││LoM LoF HiM HiF │ Rate Depth │ [Tank FX]   ││      ││      ││Mix   │
└───────┘└───────┘└──────────────────────────────────────────┘└──────┘└──────┘└──────┘
```

Each bracket is a column, and columns run left to right in signal order. The centre column's
bottom row (Decay EQ → Modulation → Tank FX tile) sits horizontally between Space and Tone,
so the x order in REQ-002 holds. Stacked knobs inside one column are the "ties" REQ-002 allows.
Knobs are `LabeledKnob` at the saturator's `KNOB_FONT_SIZE`. Algorithm is a `SegmentedControl`
on the first row. Freeze is a `CheckBox` styled like the compressor's toggles.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `EnvelopeScope` (record array `[[f32; 2]; RING_CAPACITY]`, `ring_len`, `record_frames`, peaks, `frames_since_poll`, `poll_interval`, `subscribed`) | audio callback (inside `ReverbDevice`) | command thread via `subscribe_data` / `unsubscribe_data` under the state lock (existing device-data path) | yes — fixed array, no allocation on push; `poll_interval` set in `prepare` |
| Envelope blob `Vec<u8>` | audio callback, in `poll_device_data` | `forward_device_events` → `EngineStatus::DeviceData` | same as every existing stream (the existing data-stream convention allocates the blob; not new here) |
| Map model values, span, history ring | Godot main thread | `DeviceInstance.parameter_changed`, `AudioEngineOSC.device_data_received` | n/a |

## Data and protocol changes

- **No new OSC address.** The existing `/channel/{id}/device/{path}/data/subscribe` and
  `.../data/unsubscribe` messages and the device data reply (Godot side:
  `AudioEngineOSC.subscribe_device_data` / `device_data_received`) carry a new data type
  `"envelope"` for `sonara.builtin.reverb`. It has no `data/configure` options. Add it to the
  "Data Types" list as well.
- **Blob** (little-endian): `u32 count`, `f32 record_seconds`, then `count` records of
  `f32 in_peak_db, f32 wet_peak_db` (floor −120 dB). About 20 Hz while subscribed and awake.
  `RING_CAPACITY = 256` records (≈ 1.3 s at 48 kHz, enough for the largest buffer between
  polls); records past capacity are dropped, not overwritten.
- Documented as a new "Reverb envelope stream" subsection in `docs/subsystems/osc-protocol.md`
  next to the compressor's `"dynamics"`.
- No model, setting or persisted key changes.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/devices/effects/reverb.rs` | `EnvelopeScope` struct + consts (`ENVELOPE_RECORD_FRAMES`, `ENVELOPE_RING_CAPACITY`, `ENVELOPE_RATE_HZ`); field on `ReverbDevice`, set up in `new` / `prepare` (`poll_interval`, `record_seconds`), cleared in `reset`; feed in `process_sample`; count frames in `process_block`; `subscribe_data` / `unsubscribe_data` / `poll_device_data` in `impl AudioDevice`; tests |
| `Godot/devices/builtin/reverb/ReverbData.gd` (new) | param ids, tap tables, `SIZE_MIN_SCALE`/`MAX`, `REF_LINE_S`, `band_t60(f, values, sr)`, `cut_db(f, values)`, `level_db(t, f, values)`, `early_ticks(values)`, `span_target(values)`, `decode_envelope(blob)` |
| `Godot/devices/builtin/reverb/ReverbDecayMap.gd` (new) | `Control`: draws the map from `ReverbData`, span easing, handles, hit-testing, gestures, tooltips, freeze and approximate states |
| `Godot/devices/builtin/reverb/ReverbEnvelopeStrip.gd` (new) | `Control`: wall-clock history ring, gap fill, per-pixel binning, two traces, `span` set by the view |
| `Godot/devices/builtin/reverb/ReverbDefaultView.gd` (new) | `DeviceView`: `_build` wires `metadata/param` controls (saturator pattern), binds slot tiles, `_sync_subscription` for `"envelope"`, pushes values and span to the map and strip, watches Tank FX |
| `Godot/devices/builtin/reverb/ReverbDefaultView.tscn` (new) | the layout above |
| `Godot/devices/DeviceViewFactory.gd` | add `"sonara.builtin.reverb"` to `BUILTIN_PANEL_SCENES` |
| `Godot/tests/test_reverb_map.gd` (new) | model tests (REQ-003, 005, 006) |
| `Godot/tests/test_reverb_view.gd` (new) | view tests (REQ-001, 002, 004, 007, 009, 010, 011, 012) |
| `docs/subsystems/osc-protocol.md` | "Reverb envelope stream" subsection |
| `docs/subsystems/godot-device-views.md` | list the Reverb panel view with the other built-in views |
| `CHANGELOG.md` | `### Added` line under `[Unreleased]` |

## Migration and compatibility

Nothing is persisted. Projects with a Reverb open in the new view. Users who turned on
"Simple" for a Reverb keep the Simple View. An older engine without the stream returns an error
to `subscribe_data`. The map still works and the strip scrolls silence.

## Test plan

- **Unit (engine):** in `reverb.rs` `mod tests`:
  - `envelope_stream_is_silent_until_subscribed`: `poll_device_data` is `None` before subscribing and after unsubscribing (REQ-009).
  - `envelope_records_follow_the_impulse_decay`: Decay 2 s, Mix 100 %; subscribe, render one impulse in 512-frame blocks, poll, and fit the slope of `wet_peak_db` between −10 and −40 dB. It extrapolates to −60 dB at 2 s ± 10 % (REQ-008).
  - `envelope_blob_layout`: the header count matches the records and `record_seconds` is 256/sr.
  - `subscribed_reverb_still_sleeps`: after the tail, `update_sleep_state(false)` reports sleeping while subscribed (REQ-010).
  - Run with `cargo test reverb -- --nocapture`.
- **Godot:** `Godot/tests/run_all.sh reverb` runs `test_reverb_map.gd` (contour times from REQ-003, span bounds and lock, freeze `INF`) and `test_reverb_view.gd`, which uses a `DeviceInstance` built from the reverb's `ParamInfo` list and a fake OSC injected through `load_osc`, like `test_saturator_view.gd`. That test checks one control per param id, x order, map refresh on `set_parameter_real`, synthetic drags on each handle plus undo, subscribe/unsubscribe on show/hide, gap fill after 0.5 s with no blobs, Tank FX approximate flag, and slot tile toggling.
- **Live:** start the engine and app, put a Reverb on a channel with a drum loop:
  1. The map matches the knobs. Drag each handle and watch its knob follow, then undo.
  2. A single snare hit draws an input spike and a wet slope that ends near the map's contour.
  3. Stop the transport. The reverb goes to sleep (sleep light) and the strip keeps scrolling flat.
  4. Add a device to Tank FX and see "≈ Tank FX" appear.

## Risks

| Risk | Mitigation |
|---|---|
| Tap tables and shelf math in `ReverbData.gd` drift from `reverb.rs` | Comments in both files name the mirror. The model test asserts the plateau values that `decay_eq_moves_the_band_t60s` asserts in the engine. Note the mirror in `godot-device-views.md`. |
| The map overstates accuracy (Diffusion build-up, modulation, Tank FX) | REQ-011 approximate flag; contour drawn as a soft gradient, not a hard edge |
| Drawing a 380 × 150 gradient each change is slow in GDScript | Draw one triangle mesh (`canvas_item_add_triangle_array`): 65 log-spaced frequency edges × ~57 time columns (even in x plus 8 across the onset, since dB is no longer linear in x on the square-root axis), not per pixel; redraw only on change |
| Strip history ring cost at 96 kHz (375 records/s × 64 s) | 24 k pairs in a `PackedFloat32Array`, binned per pixel on draw at ~20 Hz; fine |
| Extra branch in the hot per-sample path | One predictable bool check when unsubscribed; peaks are two `max` per sample when subscribed |

## Open questions

- none
