# 015: Compressor view redesign, Fader and LevelMeter components

Status: proposal, not approved.

Rebuild `CompressorDefaultView` as a wide, single-screen layout modelled on ZeroEQ's
compressor: Threshold and Ratio faders, the transfer curve, In / GR / Out meters and an Output
fader, from left to right. Two reusable components come out of it: a `Fader` (a vertical value
control styled like `RotaryKnob`) and a `LevelMeter` (a configurable dB meter). Simple View
gets a `fader` control kind, so the generated views can use the new Fader too.

## 1. Where things stand

### The view
- `Godot/devices/builtin/CompressorDefaultView.gd` (430 lines) is a registered Panel view
  (`DeviceViewFactory`, line 13). It is not a Simple View. It stacks four parts vertically:
  curve plus history next to the meters, a row of 7 `LabeledKnob`s plus Style and toggles, and a
  collapsible Detector pane.
- **Overflow.** `DevicePanel.HEIGHT` is 350 px, and the header tabs take part of that. The view's
  minimum is 520×300 before the knob row and the Detector pane are counted (the curve needs at
  least 140 px, the history 120 px, and each knob row about 50 px). Opening the Detector pane makes
  it worse. The EQ fits because it asks for at most 420×250 (`EqDefaultView._get_minimum_size`).
- **Meters.** The meters are an inner class `Meters` that draws through `MeterDraw`. They are
  mono: the engine records `max(|L|, |R|)`. They show only the last record's peak, with no
  ballistics and no RMS. `_apply_dynamics` hard-codes 48 kHz when it computes the hold fall time.
- **Why the meters don't move: not confirmed yet.** The code path looks right when read: the
  panel binds before `_on_view_shown`, the engine log shows `Subscribed to 'dynamics' data on
  channel 1 device 1`, master is a route target and runs `forward_device_events` from
  `begin_finish`, and `AudioEngineOSC` forwards any `/data` blob. Phase 0 tracks it down at
  runtime before anything is rebuilt on top of it.

### Engine (`Engine/src/audio/devices/compressor.rs`)
- Parameters: Threshold −60..0 dB (linear), Ratio 1..30 (`skewed`, ∞ at the top), Knee 0..24,
  Range 0..60, Attack 0.05..200 ms (log), Release 5..2000 ms (log), Auto Release, Style
  (Clean/Glue/Punch/Opto), Detection (Peak/RMS), Stereo Link, Channels (Stereo/Mid/Side),
  SC Low Cut, SC Listen, Makeup −12..+24 dB, Auto Gain, Mix.
- `"dynamics"` stream: one record per 64 frames holding `in_peak_db`, `out_peak_db` and `gr_db`.
  Records go into a 1024-entry ring that is drained at about 20 Hz. Documented in
  `docs/subsystems/osc-protocol.md` §"Compressor dynamics stream".
- There is **no external sidechain input** (spec 012, decision 7, deferred). The view
  must not show a Side-Chain toggle that does nothing.

### Components we already have
| Component | Fit for this job |
|---|---|
| `VolumeSlider` (`components/VSlider.gd`) | Mixer-specific. dB range −60..+6, depends on a `$SmartLineEdit` child scene, absolute jump-on-press, flat bar look. Not a good base for a general fader. |
| `Meter` (`components/meter/Meter.gd`, 671 lines) | The mixer strip meter. It combines meter, fader and ticks, takes linear input, and has good ballistics (peak release, hold, RMS attack/release). Too tied to the strip to reuse whole. |
| `Volumeter` | Track header meter and fader. Repeats Meter's ballistics. |
| `MeterDraw` | Static bar drawing in the mixer palette. Keep it as the low-level painter. |
| `RotaryKnob`, `HorSlider` | The interaction contract the Fader has to match (`godot-ui-components.md` §3), the mod contract (`ModDisplay`), and `value_arc_color` as the accent. |
| `DbGrid`, `CompressorCurve`, `CompressorHistory` | Keep `DbGrid` and `CompressorCurve` (its drag node is already good). `CompressorHistory`'s buffer and threshold drag become the base of the new Scope. |

The peak/hold/RMS ballistics now exist twice (Meter and Volumeter). A third copy in a new meter
would break principle 4 ("when two controls start copying the same behavior, extract it").

## 2. Proposed design

### 2.1 Layout (Panel view, target about 780×250, fits the 350 px panel)

```
 THRESH  RATIO  ┌──────── CURVE ────────┐  IN    GR    OUT   OUTPUT
   0 ┬     1 ┬  │                     ╱ │  ▌▌    ▐    ▌▌      +24 ┬
 -12 │     2 │  │                ●──╱   │  ▌▌    ▐    ▌▌          │
 -24 █     4 │  │            ╱╱╱        │  ▌▌    ▐    ▌▌      +6  │
 -40 █     8 █  │        ╱╱             │  ▌▌         ▌▌       0  █
 -60 █    ∞  █  │    ╱╱                 │  ▌▌         ▌▌     -12  █
 [-22.1] [4.0:1]│ [Auto Gain] [Curve|Scope]│ -5.7 -5.6 -5.9  [+0.0]
                                             [Peak|RMS]
 ───────────────────────────────────────────────────────────────────────
 Knee ──●────── 6.0 dB   Attack ───●── 10 ms    Style [Clean|Glue|Punch|Opto]
 Mix  ───────●  100 %    Release ───●─ 150 ms   [Auto Rel]
```

All accents use the theme primary, `#624d99`, the mixer fader's fill (see 2.6).

- **Columns, left to right:** Threshold fader, Ratio fader, visualization, meters, Output fader.
  The visualization column takes the spare width. The others are fixed.
- **Threshold fader** draws a thin live input-level bar inside its track (the detector level, see
  2.4). You can then see the signal cross the threshold without looking at the curve. This does
  more for "immediately understandable" than anything else on the panel.
- **Visualization:** a `Curve | Scope` segmented control, with the choice stored in the app config
  (`devices/compressor/view`). The meters stay visible in both modes.
  - **Curve:** a dB grid with the transfer curve, and a dot on the curve that moves with the
    detector level. The drag node stays (Threshold sideways, Ratio up and down).
  - **Scope:** a scrolling oscilloscope of about 4 s, newest on the right, that replaces the
    current `CompressorHistory`. It draws a mirrored dB envelope around a centre line, with the
    threshold as a line on both sides. Each column is painted in three parts:
    - **primary:** the input up to the threshold;
    - **gray:** the input above the threshold;
    - **red:** the gain reduction, hanging from the threshold line towards the centre, so the
      length of the red is the number of dB being cut.

    The threshold lines can be dragged, as on today's history.
- **Meters:** In L/R, GR and Out L/R, with a numeric readout under each group (click it to reset).
  A **`Peak | RMS` metering toggle** under the meters switches every meter and readout between
  peak and RMS, as ZeroComp does. In Peak mode the bar is the peak with a peak-hold line. In RMS
  mode the bar is the RMS, the hold line and readout follow it, and the GR meter is unchanged. It
  is a view setting saved in the same config key, not a device parameter. It is a separate thing
  from the compressor's *Detection* parameter (Peak/RMS), which moves to the Detector tab so the
  main page doesn't have two Peak/RMS switches. GR fills from the top, and its scale follows
  Range (12 / 24 / 48 dB).
- **Output fader = Makeup** (−12..+24 dB). It fills from 0 dB, up or down. An **Auto Gain**
  toggle sits under the curve, like ZeroEQ's Makeup button. While it is on, the fader shows the
  estimated auto makeup as a ghost marker.
- **Bottom strip:** Knee, Mix, Attack and Release as `HorSlider`s with scale labels and a value
  box. Style is a segmented control (Clean / Glue / Punch / Opto, our four engine styles. We
  don't copy ZeroEQ's VCA/Opto/FET/Vari-Mu). Auto Release is a toggle.
- **Detector page (decided):** Detection, Stereo Link, Channels, SC Low Cut, SC Listen and Range
  move to a second header tab (`get_header_tabs()` → `["Main", "Detector"]`). DevicePanel already hosts view tabs,
  so this costs no height. The collapsible pane is removed.
- **Value boxes** under each fader: the exact value at rest. Double-click or click to type
  (`FloatingValueEditor`). Ctrl-click resets to the default.

### 2.2 `Fader` (`Godot/components/Fader.gd`), new

The vertical sibling of `RotaryKnob`. It is generic and has no dB assumptions.

- **Value model:** `min_value` / `max_value` / `value_default`, plus `logarithmic`, or a
  `to_position` / `from_position` Callable pair for skewed tapers. The compressor's Ratio is
  `skewed(1, 30, 2)`, so `DeviceParameter.value_to_normalized` can be passed straight in.
  `value_text_callback` / `value_format` / `unit` behave as on RotaryKnob.
- **Look:** a dark track, a fill in `fill_color` (default `UiColors.PRIMARY`, the same as the
  mixer fader), and a cap-style handle. `fill_origin`: BOTTOM, or a value
  (0 dB for Output) the fill grows from in either direction. Optional `scale_marks:
  Array[{value, label}]` drawn on the left or right (`scale_side`), with labels placed through
  the same mapping as the fill.
- **Overlays:** `overlay_level` (0..1 or NAN), a thin live bar inside the track. This is the
  Threshold column's input level. `ghost_value` (NAN for none) is a faint marker for the Auto
  Gain estimate.
- **Interaction:** the full §3 row. The handle grab uses `FineDrag.begin_at` (no jump), a click
  on the track jumps to the pointer, Shift gives fine drag, double-click types a value,
  Ctrl/Cmd-click resets (`reset_requested`), and `last_edit_kind` is set. It shows a hover/drag
  `ValueTooltip` on the side away from the scale.
- **Mod contract:** `mod_ranges`, `mod_assign_*` and `mod_live_values`, as on VolumeSlider (a
  bar down the edge).
- **Decision: new component, not a VolumeSlider refactor.** VolumeSlider is wired to the mixer
  scene and its tests. Phase 6 can turn it into a thin `Fader` preset once Fader has proved
  itself, so the mixer isn't put at risk in the same change.

### 2.3 `LevelMeter` (`Godot/components/meter/LevelMeter.gd`) and `MeterBallistics`, new

- **`MeterBallistics` (RefCounted):** the time-based peak release (dB/s), peak hold (time, then
  fall), and RMS attack/release one-pole, lifted from `Meter.gd`. It takes dB in and
  `step(delta)`, and reports `settled` so the owner can stop `_process`.
- **`LevelMeter` (Control):** N bars (1, 2, or any count), each fed with `push(index, peak_db,
  rms_db = NAN)`.
  - `mode`: LEVEL (fills up from the bottom) or REDUCTION (fills down from the top, GR).
  - `min_db` / `max_db`, `scale_marks`, `scale_side` (left, right or none).
  - `color_mode`: ZONES (safe / warn / red, with `warn_db` and `clip_db`) or SOLID (one
    `bar_color`, default `UiColors.PRIMARY`). The compressor uses ZONES with the safe colour set
    to primary, so levels read blue-purple and still turn orange and red near clipping.
  - `display`: PEAK, RMS or BOTH. BOTH draws RMS solid with the peak translucent behind it (as in
    Meter), or RMS as a separate `rms_style = LINE`. The compressor switches every meter between
    PEAK and RMS with one toggle (2.1). The hold line and readout follow whichever value is shown.
  - `hold_time`, `release_db_per_sec`, `hold_release_db_per_sec`: the "falls smoothly at
    various speeds" setting.
  - `readout`: NONE, TOP or BOTTOM. It shows the held max peak, and a click resets it. Optional
    `caption` ("IN", "GR", "OUT").
  - `unit`: "dB" for now. LUFS needs K-weighting and gating in the engine, which is out of
    scope, but the API takes any dB-like value, so a LUFS stream can drive it later.
- **Not merged with the mixer `Meter`** for now. The strip meter is fader, ticks and meter in one
  scene, and the mixer is the most used surface. Phase 6 moves `Meter` and `Volumeter` onto
  `MeterBallistics` (behavior-preserving, tests first). Whether Meter's bars should become a
  `LevelMeter` can be decided after that.

### 2.4 Engine: a meter summary on the `"dynamics"` blob

The per-64-frame records stay as they are (the Scope draws them). For the meters, append one **summary** after the
records, covering the whole poll window:

```
u32 count | count × (in_peak_db, out_peak_db, gr_db) |
summary: in_peak_l, in_peak_r, out_peak_l, out_peak_r,       (dBFS)
         in_rms_l,  in_rms_r,  out_rms_l,  out_rms_r,        (dBFS, mean square over the window)
         detector_db, gr_max_db                              (10 × f32)
```

- The Scope needs no new data: each column draws from one record's `in_peak_db` and `gr_db`. The
  records stay peak-based even in RMS metering mode, because the scope draws a waveform envelope.
- `detector_db` is the level the gain computer actually sees: after SC Low Cut and Channels, and
  RMS when Detection is RMS. The live dot on the curve and the Threshold fader's input bar use it,
  so they sit exactly where compression starts. Today's dot uses the raw input peak, which is
  misleading once SC Low Cut or RMS detection is on.
- The new accumulators are a handful of per-sample `max`, `+=` and `*` operations, all in
  preallocated fields, so the audio-thread contract is unaffected. Older decoders still work,
  because the summary comes after the records. `CompressorData.decode` reads it when the blob is
  long enough.
- Update `osc-protocol.md`, and extend the `dynamics_records_decode_*` tests in `compressor.rs`
  (summary present, L/R peaks correct for a hard-panned sine, RMS of a sine ≈ peak − 3 dB).
- Out of scope, noted only: `poll_device_data` allocates a `Vec` on the audio thread
  (`Vec::with_capacity`). The EQ and the spectrum analyser do the same. That belongs in a separate
  fix of the `poll_device_data` trait shape, not in this spec.

### 2.5 Simple View

- Add a `fader` control kind (`SimpleControlKinds.FADER`, footprint 1×3) that builds a `Fader`
  bound to the normalized parameter, the same way `_build_knob` binds a knob. This makes the
  component available to any generated view. Strategies may prefer it for gain/output/threshold
  roles where a row has three free rows of height (optional, see Phase 5).
- Extract the segmented button row from `SimpleControl._build_segmented` into
  `components/SegmentedControl.gd`, so the compressor's Style, Detection and Display controls and
  Simple View share one look.
- `HorSlider` gains optional `scale_marks` (the "0 6 12 18 24" under Knee in the mockup), drawn by
  the same small `ScaleMarks` helper the Fader uses.

### 2.6 Theme primary colour (first step of consolidating the theme)

The theme primary is the blue-purple `#624d99` (`Color(0.384, 0.302, 0.6)`), the mixer fader's
fill. Today it is hard-coded in `components/meter/Meter.gd` (`fader_color`),
`mixer/MixerChannel.tscn` (three `fill_color`s) and `devices/compact/CompactParameterControl.tscn`.
Meanwhile `RotaryKnob.value_arc_color`, `HorSlider`, `HDualSlider` and `VolumeSlider` default to
Godot's `ORANGE` / `DARK_ORANGE`.

- Add `Godot/core/UiColors.gd` (`class_name UiColors`, static consts): `PRIMARY`,
  `PRIMARY_ALT` (the teal `alt_fill_color` in MixerChannel), `TRACK_BG`, `HANDLE`, and the meter
  palette moved from `MeterDraw` (`METER_WARN`, `METER_CLIP`, `METER_BG`). `MeterDraw` keeps its
  constants as aliases, so callers don't break.
- New components (`Fader`, `LevelMeter`, `SegmentedControl`) default to `UiColors`.
- **In this spec:** the compressor view uses `UiColors` only. **Follow-up, a separate change:**
  switch the existing control defaults (knob arc, sliders) and the hard-coded scene values to
  `UiColors`, and decide whether it becomes a Godot `Theme` resource with type variations. That
  touches the whole app, so it should get its own visual review rather than ride along here.
- `godot-ui-components.md` principle 5 currently says level meters use green-yellow as the safe
  colour. Update it to "safe = primary". Decide there whether the mixer meter follows now or in
  the theme follow-up (proposal: in the follow-up, so all surfaces change together).

## 3. Phased implementation plan

Each phase ends green (`cargo test`, `Godot/tests/run_all.sh`) and can be committed on its own.

### Phase 0: Find out why the meters don't move (small)
- [x] Add `logger.debug` to `CompressorDefaultView`: subscribe/unsubscribe, the first blob
      received (size, count), and the `meters.size` at that moment. Add a rate-limited
      `info!` in `CompressorDevice::poll_device_data` (records drained, subscribed flag).
- [x] The user reproduces with the compressor on master and on a track, and reports both logs.
      Candidates: blobs never arrive (status channel full, or a path mismatch for nested
      devices), blobs arrive and the meters are squeezed or clipped by the overflowing layout, or
      they work but the 20 Hz last-record peak with no ballistics reads as broken.
- [x] Fix the cause if it's small. Replace the hard-coded 48 kHz in `_apply_dynamics` with the
      configured sample rate, which `history.set_sample_rate` already reads.

### Phase 1: `UiColors`, `MeterBallistics` + `LevelMeter` (Godot only)
- [x] `core/UiColors.gd` as in 2.6. `MeterDraw` constants become aliases.
- [x] `components/meter/MeterBallistics.gd`: the ballistics from `Meter.gd`, as dB in, time-based.
- [x] `components/meter/LevelMeter.gd` with the options in 2.3, including `display`
      PEAK/RMS/BOTH. It stops `_process` when settled.
- [x] `tests/test_level_meter.gd`: release rate, hold then fall, RMS smoothing, switching
      `display` moves the hold line and readout to the shown value, REDUCTION fill direction,
      zone colours at warn/clip, readout reset on click.
- [x] `godot-ui-components.md`: add to the Shared pieces table, and note ZONES vs SOLID under
      principle 5.

### Phase 2: `Fader` (Godot only)
- [ ] `components/ScaleMarks.gd` (tick and label layout through a value→position Callable).
- [ ] `components/Fader.gd` as in 2.2, including the mod contract and `overlay_level` /
      `ghost_value`.
- [ ] `tests/test_fader.gd` following `test_value_controls.gd`: grab without a jump, track click
      jumps, Shift fine drag, Ctrl-click reset and `reset_requested`, typed entry, a skewed
      taper round-trip, `fill_origin` at 0 dB, no signal on a no-op. Add the Fader to
      `test_mod_assign_ui.gd`.
- [ ] `components/SegmentedControl.gd` (button row in `UiColors`, `selected` + `*_no_signal`), so
      the compressor view can use it in Phase 4.
- [ ] Docs: shared pieces table and the §3 gesture table row.

### Phase 3: Engine meter summary
- [ ] `compressor.rs`: per-side peak and mean-square accumulators for in/out, and a
      `detector_db` max over the window. Append the 10-float summary in `poll_device_data`.
- [ ] Tests as listed in 2.4. Update `osc-protocol.md`.
- [ ] `CompressorData.decode` returns a `summary` dictionary when one is present. Update
      `test_compressor_view.gd`'s decode test.

### Phase 4: Rebuild `CompressorDefaultView`
- [ ] New layout from 2.1. Delete the inner `Meters` class and the Detector pane. Add the Main /
      Detector header tabs.
- [ ] Feed the Threshold `overlay_level` and `CompressorCurve.live_input_db` from
      `summary.detector_db`, the meters from the summary, and `ghost_value` from the static auto
      makeup (half the reduction at 0 dBFS, as the engine computes it; add a
      `CompressorData.auto_makeup_db`).
- [ ] `CompressorCurve`: square-friendly (it keeps its aspect ratio inside the column), drawn in
      `UiColors`, with the dot fed from `detector_db`.
- [ ] `CompressorScope` replaces `CompressorHistory`. It keeps the rolling buffer, the
      sample-rate capacity and the threshold drag, and adds the mirrored primary / gray / red
      drawing from 2.1. Add a headless test that checks the three segment heights for one
      column (input above the threshold with known GR).
- [ ] View state `{display: CURVE|SCOPE, metering: PEAK|RMS}` in the app config at
      `devices/compressor/view`, as the EQ does with `EqViewState`. The `Peak | RMS` toggle sets
      `display` on every `LevelMeter` in the view.
- [ ] `_get_minimum_size()` ≤ (780, 250) for the panel, with a larger size when opened as a
      window (as `EqDefaultView._is_window`).
- [ ] Update `test_compressor_view.gd`: fader drags set Threshold, Ratio and Makeup, the
      header tabs switch pages, meters receive the summary, and the view fits the panel height.
- [ ] Manual check with the engine running (with the user): drums through the compressor, and
      confirm the GR meter, the dot and the threshold bar agree.

### Phase 5: Simple View integration
- [ ] Switch `SimpleControl._build_segmented` to `SegmentedControl` (built in Phase 2).
- [ ] `SimpleControlKinds.FADER` + `SimpleControl._build_fader` / refresh / mod wiring.
- [ ] `HorSlider.scale_marks`.
- [ ] Optional: let `GenericStrategy` pick `fader` for output and gain roles when the packer has
      vertical room (`GridPacker`). Check `test_simple_layout_generator.gd`.

### Phase 6: Consolidation (optional, separate PRs)
- [ ] `Meter.gd` and `Volumeter.gd` use `MeterBallistics` (no visual change; existing tests
      plus a ballistics comparison test).
- [ ] `VolumeSlider` becomes a `Fader` preset (dB −60..+6, flat style) if the mixer look can be
      matched exactly.

## 4. Decisions

1. **Colours:** the theme primary `#624d99` is the accent for faders, meters (safe zone) and the
   curve/scope input. It lives in `UiColors` (2.6). The app-wide theme consolidation is a follow-up.
2. **Visualization:** a `Curve | Scope` toggle. Curve is the grid with the transfer curve and a
   live dot. Scope is the oscilloscope: primary input, gray above the threshold, red GR hanging
   from the threshold line.
3. **Detector controls:** on a second header tab ("Detector").
4. **Modulation and automation on the new faders:** later. The `Fader` implements the mod
   contract, but the compressor view doesn't wire mod assign in this spec.
5. **Metering:** a `Peak | RMS` toggle switches all meters and readouts, as ZeroComp does.

## 5. Still open

- Does the scope's red overlap the primary fill (drawn over it, which reads as "this much was
  pushed down"), or replace it? Proposal: drawn over it with full opacity, so the remaining
  primary is what passes uncompressed.
