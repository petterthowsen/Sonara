# 016: Multiband FX container

Status: proposal, not approved.

A built-in container device, **Multiband FX** (`sonara.builtin.multiband`). It has six **band
positions** in fixed frequency order: band 1 is always the lowest, band 6 always the highest. Any 2–6
of them are **active**. The input is split into the active bands with Linkwitz-Riley crossovers. Each
active band runs through its own slot chain (any devices: Compressor, EQ, Saturator, CLAP plugins…),
and the bands are summed back. Crossovers can be dragged freely between their active neighbours.
The main use is multiband compression. With every band empty, the device is transparent in magnitude
(phase-shifted, see D5).

Task markers follow `docs/specs/README.md`: `[ ]` open, `[x?]` implemented, `[x]` verified (the
task's _Verify_ line was actually run).

## 1. Where things stand (read before starting)

- **Containers already exist.** `Engine/src/audio/devices/container.rs` (`DeviceContainer`,
  `DevicePath`, `insert_into_vec`/`remove_from_vec`/`move_in_vec`), `chain.rs` (serial) and
  `layer.rs` (parallel, variable slot count). Multiband FX is structurally a Layer that feeds each
  slot one band, where a Layer feeds every slot the same input. **Use `layer.rs` as the template.**
- **Slot chains.** In Godot every child of a Layer or Drum Machine is a Chain ("slot chain",
  `Godot/data/SlotChain.gd`). The engine sees an ordinary `ChainDevice` per child. Multiband FX
  uses the same rule: child *i* is the slot chain of band position *i + 1*.
- **Gating on "Layer-like"** happens through `Device.container_focuses_one_child()`
  (`Godot/data/Device.gd:213`) and `SlotChain.is_slot_parent`. Layer-specific behavior (slot
  volume/mute/solo OSC, note maps, separate outs, aux returns) is gated by
  `AuxReturnSync.is_layer` / `DeviceInstance` checks against `"sonara.builtin.layer"`. Multiband FX
  must take the slot-chain path and **none** of the Layer-specific paths.
- **DSP block to reuse:** `Engine/src/audio/dsp/linear_svf.rs` (`LinearSvf`, `SvfCoefs`,
  `SvfShape::{LowPass, HighPass, AllPass}`). Its coefficients can change per sample, and
  `SvfCoefs::magnitude_db` gives the exact response, which the UI can draw.
- **Parameter tables:** `Engine/src/audio/devices/param_table.rs` (`ParamSpec`, `flatten`,
  `slot_table`, `log`, `linear`, `Kind::Bool`). See `filter.rs` or `compressor.rs` for a device
  built on it.
- **Factory:** `Engine/src/audio/devices/factory.rs`: `create_builtin` match arm, plus the
  `others` array in `builtin_device_infos` (update its length).
- **Views:** `Godot/devices/DeviceViewFactory.gd` maps device id → scene. Layer's view is
  `devices/builtin/LayerDefaultView.gd` + `devices/container/LayerSlotRow.gd`. The EQ's
  `EqResponse.gd` / `EqCurveEditor.gd` show how to draw a log-frequency axis and drag handles on it.
- ADRs to respect: 0002 (audio thread contract), 0005 (normalized params), 0006 (self-syncing
  models), 0008 (device sleep), 0010 (automation overrides base values).

## 2. Decisions (settled, don't revisit)

| # | Decision |
|---|---|
| D1 | **Six fixed band positions, any 2–6 active.** Band 1 is always the lowest frequency range and band 6 the highest; positions never reorder. Each band has an `Active` parameter. There is no band-count parameter: the count is the number of active bands. Default active set: **{1, 3, 5}**. Then enabling 2, 4 or 6 splits Low, Mid or High respectively (sub, low-mid, air). `Active` is **not automatable**. |
| D2 | **Fixed parameter IDs.** Every band position has the same parameter block whether it's active or not (table below). Automation on a band's controls survives other bands being toggled. |
| D3 | **Each band owns its low edge.** Band *p* (2..6) has a `Low Edge` frequency. An active band covers `[its low edge, low edge of the next active band)`. The lowest active band extends down to 0 Hz and its `Low Edge` is ignored. The highest active band extends to Nyquist. The **crossovers** are therefore the low edges of every active band except the lowest. With K active bands there are K−1 crossovers. An inactive band's edge does nothing. |
| D4 | **Crossover topology: cascade, low first**, over the *active* bands only. Crossover *j* (0-based, ascending) splits the remainder into `low_j` (the j-th active band) and the rest. The last active band is what remains after the final split. The device maps compacted index → band position. |
| D5 | **Filters: LR4** = two cascaded 2nd-order Butterworth stages (`LinearSvf`, Q = 1/√2) for LP and for HP. LP+HP of one LR4 equals a 2nd-order allpass at the same frequency with Q = 1/√2 (`SvfShape::AllPass`). **Phase compensation:** the j-th active band passes through the allpass of every crossover `k > j`. That makes (K−1)(K−2)/2 allpasses: 1 at 3 bands, 10 at 6. The bands' sum is then flat in magnitude (an allpass in phase) and zero latency. No linear-phase mode in v1. |
| D6 | **Movable crossovers, clamped by active neighbours.** In the UI, every crossover handle can be dragged, but not past the neighbouring active crossovers: it's clamped to `(prev × MIN_RATIO, next / MIN_RATIO)`, with `MIN_RATIO = 1.1` and the range bounded by 20 Hz–20 kHz. Inactive bands' edges don't block anything. The engine enforces the same order independently, so automation or a bad preset can't cross bands: `eff[0] = raw[0]`, `eff[j] = max(raw[j], eff[j-1] × MIN_RATIO)`, then clamped to `≤ 20 kHz` and `< 0.45 × sample_rate`. |
| D7 | **Enabling a band places its edge.** When band *p* is enabled, it splits the active band whose range contains position *p*. If *p*'s stored `Low Edge` lies inside that range (with `MIN_RATIO` margin on both sides), it's kept. Otherwise it's set to the geometric mean of that range. If *p* becomes the new lowest active band (it sits below every active band), it takes over the old lowest band's role, and the old lowest band's `Low Edge` becomes a crossover. That edge is placed the same way. This happens in Godot, as part of the enable command (G1.4). |
| D8 | **Disabling a band removes its devices.** If the band's slot chain holds devices, a confirmation dialog appears first ("Disable High Mid? Its 2 devices will be removed."). Disable + device removal is one undoable action. Undo brings the devices back. The disabled band's range merges into the active band below it, or into the one above if it was the lowest. Fewer than 2 active bands is not allowed: the toggle is disabled when only 2 are active. |
| D9 | **Six slot chains, always.** A Multiband FX always has exactly 6 children, the slot chains for bands 1–6, created when the device is added. Band position = child index + 1. Slot chains are never removed, reordered or dragged out; "Clear Band" empties one. An inactive band's chain is always empty (D8), so there's no hidden state to persist. |
| D10 | **The engine tolerates other child counts.** A missing child = a pass-through band (its gain/mute/solo still apply). A 7th `insert_child` is dropped with a `warn!` (`insert_child` can't fail). Inactive band positions are never processed, even if their child holds devices (for example from a hand-edited project). |
| D11 | **Per-band controls are device parameters** (gain, mute, solo), not Layer slot commands, so they're automatable and saved through the generic parameter path. The Layer `/slot/*` OSC commands are **not** used for Multiband FX. |
| D12 | **Mix (dry/wet)** uses a phase-aligned dry: the input through the allpass of every active crossover. A Mix below 100 % then doesn't comb-filter. |
| D13 | **Smoothing.** Crossover frequencies are smoothed in log-frequency (`SmoothedParam`, ~20 ms). Coefficients are rebuilt every 16 samples while a ramp is active, and not at all when settled. **When the active set changes** (the topology changes, so crossover slots get new frequencies), the device ramps the output to 0 over 5 ms, switches topology, resets the splitter's filter state (but not the children), snaps the smoothers, and ramps back up over 5 ms. That's a small state machine in the device, with no allocation. |
| D14 | Category `DeviceCategory::Effect`. No MIDI ports, no extra output buses (no per-band separate outs in v1). |

### Parameter table

IDs follow the blocks-of-ten convention in `param_table.rs`. Band *p* (1..6) uses the block `10·p`.

| ID | Name | Kind | Default |
|---|---|---|---|
| 0 | Mix | linear 0..100 % | 100 |
| 1 | Output | linear −24..+24 dB | 0 |
| 10·p + 0 | Band *p* Active | Bool, **not automation-safe** | on for p ∈ {1, 3, 5} |
| 10·p + 1 | Band *p* Low Edge (p ≥ 2 only; there's no ID 11) | log 20..20000 Hz | p2 60, p3 200, p4 700, p5 2500, p6 8000 |
| 10·p + 2 | Band *p* Gain | linear −24..+24 dB | 0 |
| 10·p + 3 | Band *p* Mute | Bool | off |
| 10·p + 4 | Band *p* Solo | Bool | off |

With the defaults, the active bands are Low < 200 Hz, Mid 200 Hz–2.5 kHz and High > 2.5 kHz.
Enabling 2, 4 or 6 adds a split at 60 Hz, 700 Hz or 8 kHz.

Solo works as in Layer: when any *active* band is soloed, only soloed bands reach the sum. Muted and
soloed-out bands **still process their slot chain**, the same as Layer `render_slots`, so compressor
state and tails don't jump when they're unmuted.

### Band names (Godot, display only)

Names follow the number of active bands, low to high: 2 → Low/High; 3 → Low/Mid/High;
4 → Low/Low Mid/High Mid/High; 5 → Sub/Low/Mid/High Mid/High; 6 → Sub/Low/Low Mid/Mid/High Mid/Air.
A slot chain the user has renamed keeps its name. Keep a flag on the chain, or compare against the
auto-name table.

## 3. Engine

### Phase E0: Crossover DSP block
- [x] **E0.1** Add `Engine/src/audio/dsp/crossover.rs` (register it in `dsp/mod.rs`): a stereo
  `MultibandSplitter` working on a compacted list of up to 5 ascending crossovers (it knows nothing
  about band positions). Use fixed-size storage only (arrays, no `Vec` growth after `new`). Each
  crossover holds per-channel LP stage ×2, HP stage ×2, and one `AllPass` `LinearSvf` per
  compensation slot. Preallocate for the 6-band case: 10 compensation allpasses, plus 5 dry
  allpasses for D12.
  API sketch: `new(sample_rate)`, `set_targets(&[f32], count)` (smoothed internally; the list must
  be ascending, so the caller applies D6 first), `set_topology(count)` + `snap()` + `reset()` for
  D13, `split(input: &[f32], bands: &mut [Vec<f32>; 6], dry_aligned: &mut [f32], sample_count)`
  writing interleaved stereo into `bands[0..count+1]`.
  - Computing LP and HP from one shared first SVF stage is allowed as an optimization, but not
    required. Correctness first.
  - _Verify_: unit tests in `mod tests`. (a) Null test: for every band count 2..6, white noise →
    split → sum of bands has a magnitude response flat within ±0.1 dB from 30 Hz to 18 kHz
    (compare the sum against `dry_aligned` sample by sample to 1e-4, which also proves D12).
    (b) A sine at the geometric center of each band carries ≥ 90 % of its energy in that band.
    (c) Each band's LR4 slope is ≈ −24 dB/oct one octave past its crossover (±3 dB).
    (d) Sweeping a crossover 20 Hz → 20 kHz over 1 s with noise input produces no NaN/inf and
    stays below +6 dBFS peak.

### Phase E1: `MultibandDevice`
- [x] **E1.1** Add `Engine/src/audio/devices/multiband.rs` (register it in `devices/mod.rs`,
  `pub use`). Struct: `children: Vec<Box<dyn AudioDevice>>` (capacity 6, reserved in `new`), the
  `MultibandSplitter`, `band_bufs: [Vec<f32>; 6]`, `child_out`, `sum`, `dry`, all sized
  `max_buffer_size * 2` in `new`, the normalized param array from the table, the active-position
  list as `[u8; 6]` + len, the D13 fade state, `enabled`.
- [x] **E1.2** Topology from params: each block, derive the active positions (ascending). If fewer
  than 2 are active (a bad preset), treat the device as pass-through and `warn!` once. Derive the
  raw crossovers = `Low Edge` of every active position except the first, apply D6 ordering, and
  hand them to the splitter. If the active set differs from the last block, run the D13 fade.
  Keep all of this allocation-free.
- [x] **E1.3** `DeviceContainer` impl following `LayerDevice`. `insert_child` beyond 6 → `warn!`
  and drop (D10). `move_child`/`remove_child` are implemented (the generic paths need them), but
  Godot never calls them for this device (D9).
- [x] **E1.4** `process_block`: when disabled, copy input to output. Otherwise split → for the j-th
  active band at position p: if child `p-1` exists, `process_block(band_bufs[j] → child_out)`,
  else use `band_bufs[j]` as is → apply band p's smoothed gain → add into `sum` if audible
  (mute/solo). Then `out = (dry_aligned × (1 − mix) + sum × mix) × output × topology_fade`.
  Smooth gain, mix and output (`SmoothedParam`, ~10 ms). Inactive positions and their children are
  not touched. No allocation, no locks, no `println!` (ADR 0002).
- [x] **E1.5** Param plumbing through `param_table` (`parameters()`, `set_parameter`,
  `get_parameter`, defaults). `device_id` `"sonara.builtin.multiband"`, `device_name`
  `"Multiband FX"`, category `Effect`. `reset()` resets the splitter, every child, and the buffers.
  `mark_activity()` forwards to children. `as_container`/`as_container_mut`/`is_container` → true.
- [x] **E1.6** Sleep (ADR 0008): don't add a sleep state to the container itself. Children
  (Chains) already handle their own. Check that a Multiband FX with silent input and empty bands
  costs only the splitter. Document the per-sample cost (≈ 60 biquads at 6 bands) in the module
  doc.
- [x] **E1.7** Recursive walks: check that `apply_transport` and every other recursive walk in
  `mod.rs` / `container.rs` reaches Multiband children through `as_container_mut` (they should,
  generically). Look for any `"sonara.builtin.layer"` / `downcast` special cases in the engine that
  should also cover multiband. Expectation: none.
  - _Verify_ (E1.x): unit tests in `multiband.rs`, using a test gain device like the one in
    `layer.rs` tests: (a) defaults ({1,3,5}, empty children) = flat magnitude; (b) a ×0 child on
    band 3 removes only the 200 Hz–2.5 kHz energy; (c) active set {1, 3, 6}: band 6's child gets
    everything above band 6's edge, and band 3's child gets band 3's edge up to band 6's edge
    (bands 4 and 5's ranges merged into 3); (d) mute and solo semantics; (e) an inactive band's
    child is never called, even when it holds a device (count calls in a test device);
    (f) out-of-order edges among active bands are still split in ascending order (D6);
    (g) toggling a band mid-stream gives no sample-to-sample jump above the 5 ms ramp's slope;
    (h) a 7th `insert_child` is dropped; (i) Mix 0 % equals the phase-aligned dry to 1e-5;
    (j) fewer than 2 active → pass-through; (k) `cargo test` green and `cargo build --release`
    clean.

### Phase E2: Registration, OSC, docs
- [x?] **E2.1** `factory.rs`: add a `create_builtin` arm and an entry in the `others` array of
  `builtin_device_infos` (bump the array length). Don't add it to `EFFECT_IDS`: it's a container,
  like Layer, and the effect conformance test assumes leaf effects. Optionally run the relevant
  conformance checks on an empty Multiband FX in its own test.
- [x?] **E2.2** No new OSC messages are expected: params, child add/remove and device data go
  through the existing generic paths. If you add one anyway (for example the E2.3 stream), follow
  AGENTS.md: `osc/server.rs` handler + `audio/commands.rs` command + `docs/subsystems/osc-protocol.md`.
- [ ] **E2.3** _(optional, can ship after Godot phase G2)_ A `"bands"` device data stream: per
  active band, its position and post-chain peak dB, plus the effective crossovers (after D6
  clamping), at about 20 Hz via `poll_device_data`, using a preallocated buffer as `compressor.rs`
  does for `"dynamics"`. Used by the view for per-band meters and to show clamped crossovers.
- [x?] **E2.4** `docs/subsystems/osc-protocol.md`: add a **Multiband FX (`sonara.builtin.multiband`)**
  section next to Layer (line ~295) with the parameter table, the band position = child index + 1
  rule, the active-band/edge semantics (D3), and the stream format if E2.3 was done.
- [x?] **E2.5** `CONTEXT.md`: add glossary terms **Multiband FX**, **Band** (position vs active),
  **Crossover**, **Low Edge**, **Band slot chain**.
- [x?] **E2.6** Add `docs/adr/0013-multiband-fixed-band-positions.md` (short, in the existing ADR
  format). It records D1 + D2 + D3 + D9: six fixed positions with per-band Active, band = child
  index, each band owning its low edge, and fixed parameter IDs. It's a persisted-format decision.
  - _Verify_ (E2): run the engine (`./run_release.sh`), then from Godot or
    `oscsend localhost 7000 /builtin/request` check that the device appears in the `/builtin/info`
    list with its parameters.

## 4. Godot

### Phase G1: Model, add flow, band toggling
- [ ] **G1.1** `Godot/data/Device.gd`: `container_focuses_one_child()` includes
  `"sonara.builtin.multiband"`, so children become slot chains, one band open at a time.
  Add `is_multiband()` (or a `MULTIBAND_ID` const on `SlotChain`, alongside `CHAIN_ID`).
- [ ] **G1.2** `Device.creates_instrument_track()` currently returns true for every container.
  Multiband FX must behave like an effect: dropping it on an empty tracklist/mixer creates an
  audio track or is refused, the same as the Compressor.
- [ ] **G1.3** When a Multiband FX instance is created (`history/commands/DeviceAddCommand.gd` or the
  instance's own setup), create its 6 empty slot chains via `SlotChain.empty` (D9). Name them with
  the band-name table.
- [ ] **G1.4** Band toggling: one undoable history command per toggle.
  - **Enable** band *p*: set `Active`, then place edges per D7 (one or two `Low Edge` params).
    Refresh the auto names.
  - **Disable** band *p*: refuse if only 2 are active. If its slot chain has devices, show a
    confirmation dialog first (Godot `ConfirmationDialog`; follow how existing destructive actions
    confirm, if any). The command removes the chain's devices and clears `Active`. Undo restores
    both. Reuse the existing device-remove command's snapshot/restore instead of writing a new one.
    Refresh the auto names.
  - Look at how existing commands in `Godot/history/commands/` batch several changes.
- [ ] **G1.5** Guard the Layer-only paths. Every place that checks `is_slot_parent` /
  `container_focuses_one_child` and then does something Layer- or Drum-Machine-specific must exclude
  Multiband FX: `AuxReturnSync` (no returns), `NoteMapWatcher` / `NoteMapResolver` (no note maps),
  `DeviceInstance.set_slot_volume` and the other slot mix controls (D11: they must not send Layer
  `/slot/*` OSC to a Multiband parent), `DevicePreset.gd:110/181` (per-child handling).
  `grep -rn "is_slot_parent\|container_focuses_one_child\|is_layer\|slot_volume" Godot --include=*.gd`
  and go through every hit.
- [ ] **G1.6** Block structural edits that would shift band positions (D9): removing, reordering or
  dragging a band slot chain out of a Multiband FX (`DeviceDropUtil.gd`, `DeviceContextMenu.gd`,
  device lane delete). Dropping a device *onto* a band adds it inside that band's existing slot
  chain. Check that `SlotChain.for_parent` targets the band chain instead of appending a 7th child.
  Dropping onto an inactive band isn't possible, because inactive bands aren't shown (G2.2). Add a
  "Clear Band" context action that removes the devices inside the band's chain (undoable).
- [ ] **G1.7** Persistence: save/load uses the generic container path. Check that a project
  round-trips with a non-default active set (e.g. {1, 3, 6}) and devices in its bands. Check that
  slot chains are not re-wrapped on load (`_wrap_slot_children` must leave Multiband children that
  are already Chains alone). On load, a Multiband FX with fewer than 6 children gets the missing
  empty chains appended.
  - _Verify_ (G1): new `Godot/tests/test_multiband_model.gd` (extends `TestBase`, run with
    `-- --test`): add → 6 chains, active {1,3,5}, names Low/Mid/High; enable 4 → its edge lands
    inside Mid's range (D7), names become Low/Low Mid/High Mid/High; enable 6 with its stored edge
    outside High's range → the edge moves to the geometric mean; disable a band holding a device →
    device removed, undo → back; disabling down to 1 active band is refused; enabling a band below
    the lowest active one makes the old lowest band's edge a valid crossover; slot volume setter on a
    band chain sends no `/slot/` OSC (stub `AudioEngineOSC` as the existing tests do); save → load
    round-trip. `Godot/tests/run_all.sh` green. The confirmation dialog itself is UI, so test the
    command, not the dialog.

### Phase G2: View
- [ ] **G2.1** `Godot/devices/builtin/MultibandDefaultView.gd/.tscn`, registered in
  `DeviceViewFactory.gd`. It must fit `DevicePanel.HEIGHT` (350 px minus header; see the overflow
  note in spec 015). Layout:
  ```
  ┌ [1][2][3][4][5][6]  ← band toggles ──────────────── Mix ◯  Out ◯ ┐
  │  20      100        1k         10k   20k                         │
  │  ░░░░░░░│▒▒▒▒▒▒▒▒▒▒▒▒▒▒│▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓                       │  ← active band regions in slot
  │       200 Hz         2.5 kHz                                     │    colors, draggable crossovers
  ├──────────────────────────────────────────────────────────────────┤
  │ ● Low   [M][S]  gain ◯  ▌meter   ▸ (opens band slot)             │
  │ ● Mid   [M][S]  gain ◯  ▌meter   ▸                               │
  │ ● High  [M][S]  gain ◯  ▌meter   ▸                               │
  └──────────────────────────────────────────────────────────────────┘
  ```
  - Band toggles: six small toggles in position order, which call the G1.4 command (the disable
    path may open the confirmation dialog). The toggle is disabled when it would leave fewer than
    2 bands active. The tooltip gives the band's current name and range.
  - Crossover strip: log axis 20 Hz–20 kHz (borrow the mapping from `EqResponse.gd`). Each active
    band's region is filled in its slot color (`DeviceInstance.slot_color`). One handle per
    crossover (= `Low Edge` of each active band except the lowest). Dragging sets that band's
    `Low Edge` param, clamped per D6 between the neighbouring active crossovers. The tooltip shows
    Hz. Double-click to type a value, if the existing components support it. Drawing the LR4
    response per band is optional: compute it in GDScript from the LR4 formula; there's no need
    to call the engine.
  - Band rows: one per active band, low to high, modelled on `LayerSlotRow.gd` but bound to the D11
    **params** (Gain knob, Mute/Solo toggles), not slot mix controls. Clicking a row opens that
    band's slot chain in the device lane (`device.toggle_slot(device.slot_key_for(child))`, as in
    `LayerDefaultView`).
  - Meters: only if E2.3 exists. Subscribe in `_on_view_shown`, unsubscribe in `_on_view_hidden`.
  - Follow `docs/subsystems/godot-ui-components.md` (existing `RotaryKnob`, toggles, theme primary
    accent).
- [ ] **G2.2** Device lane: band slot chains show their band name and color, and only active bands
  are offered (`DeviceInstance.slot_keys()` returns only active bands' chains for Multiband FX). If
  the open band is disabled, close its slot.
  - _Verify_ (G2): `godot --path Godot` against a release engine. Add Multiband FX to a drum loop
    track, enable and disable bands (including the confirmation on a band with a device, and undo),
    and drag every crossover against its neighbours. Put a Compressor in Low and a Reverb in High,
    and listen. Mute/solo each band. Toggle a band during playback and listen for clicks. Save,
    reload, and confirm the state. Take a screenshot for the user.

### Phase G3: Integration odds and ends
- [ ] **G3.1** Device presets (`DevicePreset.gd`): saving and loading a Multiband FX preset includes
  the active set, edges and band chains with their devices.
- [ ] **G3.2** DAWproject (`docs/subsystems/dawproject.md`): check how Layer/Chain export today and
  give Multiband FX the same treatment (most likely: not representable, so it gets an entry in the
  transfer report). Don't invent a mapping.
- [ ] **G3.3** AI tools (`Godot/ai/tools/DeviceToolUtil.gd`, `AiTool.gd`): adding a device "into"
  a Multiband FX must target an active band (by position or name) and must not append a 7th child.
  Add an optional `band` argument where tools accept a container parent, or refuse with a clear
  message. Skip this if the tools don't support nesting at all today.
- [ ] **G3.4** `TODO.md`: mark the spec's backlog line `[x?]`. The user marks it `[x]` once verified.

## 5. Suggested hand-off order

E0 → E1 → E2.1/E2.4–E2.6 (engine done, `cargo test` green) → G1 → G2 → G3 → E2.3 + meters last.
The engine phases are independent of Godot and can be reviewed on their own. Commit at the end of
each phase.

## 6. Out of scope (v1)

Linear-phase crossovers; per-band separate outputs or aux returns; per-band sidechain; a spectrum
analyzer behind the crossover strip (cheap to add later from the EQ's spectrum stream); MIDI into
band chains; more than 6 bands.
