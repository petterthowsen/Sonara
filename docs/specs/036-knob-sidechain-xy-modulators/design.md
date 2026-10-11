# Knob, Sidechain and XY modulators — Design

Implements [requirements.md](./requirements.md). Paths and symbols below were
checked against the tree on 2026-10-11.

## Context

- `Engine/src/audio/modulation/kinds.rs` — `ModulatorKind` (8 variants:
  `Lfo, Adsr, Ad, Velocity, Keytrack, Random, Release, MidiCc`; `COUNT = 8`,
  `ALL`, `index() = self as usize`), `id()`/`name()`/`table()`,
  `bipolar()` (kind-fixed; only Lfo/Keytrack/Random), `is_envelope()`,
  `is_mono_only()` (only `MidiCc`), `ModParams`, `MAX_KIND_PARAMS = 5`. Tables
  are `&'static ParamTable` built with `spec(id, name, module, unit, kind,
  default)` and `Kind::{Float{..}, Enum(&'static [&str]), Bool}` via the
  `linear()`/`log()` helpers in `Engine/src/audio/devices/param_table.rs`.
- `Engine/src/audio/modulation/state.rs` — `ModulatorState` (`Copy`,
  fixed-size): `kind`, `params`, `mod_offset`, `sample_rate`, per-kind state
  (LFO, envelope, held/last note, velocity, release, random/rng,
  `cc_target`/`cc_value`); `advance`, `value()`, `reset()`.
- `Engine/src/audio/modulation/host.rs` — `ModulatedDevice` (`CONTROL_STEP =
  64`). `process_block` splits the block into ≤ 64-frame steps and calls
  `control_step(frames)` before each inner sub-block; `process_block_with_extra`
  (aux-source path) calls `control_step(sample_count)` **once for the whole
  block**; `begin_block` (async/plugin inner) calls `control_step_impl(frames,
  base, true)` per step. `is_sleeping()` is `modulator_count() == 0 &&
  dev().is_sleeping()` — a device with any modulator never reports sleeping
  (ADR-0014). `send_cc` latches `cc` modulators.
- `Engine/src/audio/modulation/voice.rs` — `VoiceModSpec`; `is_mono_only()`
  kinds are excluded and evaluated on the mono path.
- `Engine/src/audio/mixing/mod.rs` `mix_and_output` — aux sources → device
  prepass → pre-fader sends → fader/pan → `route_in_dependency_order` →
  hardware writes. Channel `buffer_left/right` are cleared at the start of
  each block and filled during it, so **another channel's buffer is never a
  valid "last block" source during the device passes**.
- `Engine/src/audio/channel/mod.rs` — `Channel { buffer_left, buffer_right,
  peak_*, rms_*, … }`, `device_at_path_mut`.
- `Engine/src/audio/dsp/svf.rs` — `Svf`, `SvfCoefs::new(g, k, mode)`,
  `cutoff_to_g`, `FilterMode` (all `Copy`).
  `Engine/src/audio/dsp/env_follower.rs` — `EnvFollower::new(attack_ms,
  release_ms, sr, Detection::{Peak, Rms})`, `set_times`, `process`, `value`
  (`Copy`).
- The compressor (spec 015) has an **internal** detector low cut only; there
  is no existing cross-channel audio tap anywhere in the engine.
- `Godot/data/DeviceInstance.gd` — `MAX_MODULATORS := 8`,
  `add_modulator(kind)` (lowest free id, `_unique_modulator_name`),
  `duplicate_modulator`, `remove_modulator` (also erases dangling
  `mod/{id}/…` routes), `swap_modulators(a, b)` (array swap, no OSC; used by
  `ModulatorDrag`), `rename_modulator`, `set_modulator_param`,
  `is_modulator_kind_bipolar(kind)`, `get_routes_into` (fills each route's
  `bipolar` from the **kind** at line ~833), `sync_modulators_to_engine`,
  `_modulators_to_json`.
- `Godot/data/DeviceRegistry.gd` — kind advertisement decode (`bipolar` at
  ~376).
- `Godot/devices/modulators/` — `ModulatorsPane.gd` (grid, `+` menu,
  detail column), `ModulatorPanel.gd` (tile, `_wire` button), 
  `ModulatorDisplay.gd` (per-kind `_draw`, live dot, trace ring),
  `ModAssign.gd` (`begin/end`, `ranges_for`), `ModLive.gd`,
  `ModulatorDrag.gd` (`commit` → `swap_modulators`).
- `Godot/components/XYSlider.gd` — `x_min/x_max/y_min/y_max`,
  `value_x/value_y`, `set_values`, `set_values_no_signal`, `values_changed`,
  `show_value_labels`, `show_axis_lines`, `handle_radius`.
- `Godot/components/ModDisplay.gd` — `source_color(index)`, `span(base,
  amount, bipolar)`.

## Approach

Four kinds appended to `ModulatorKind` (`Knob`, `XyX`, `XyY`, `Sidechain`),
all evaluated in the existing control-step pass, plus:

- a **sidechain tap pool** in the engine state: the mixer snapshots the
  post-fader output of every *subscribed* channel at the end of each block
  into preallocated buffers, and the next block feeds those frames to the
  subscribing modulators;
- a Godot-level **XY pair**: the engine sees two plain modulators; Godot
  groups them into one tile.

Rejected: an engine-native compound modulator (touches every enum, loop and
payload for one use case); sidechain as a chain *device* (it must be a
modulation source that drives parameters through routes); reading
`Channel::buffer_*` directly from inside a device (devices can't reach other
channels, and those buffers are cleared and refilled mid-block); audio-rate
follower output (the modulator system is control-rate by design).

## Kinds (engine)

Appended **after `MidiCc`** in this order: `Knob, XyX, XyY, Sidechain`;
`COUNT` 8 → 12. Existing `index()` values are unchanged. `MAX_KIND_PARAMS`
stays 5.

| Kind | id | name | params (ids in blocks of ten) | `bipolar()` | mono-only |
|---|---|---|---|---|---|
| Knob | `knob` | Knob | 0 Value `linear(0,1)` default 0; 10 Polarity `Enum["Unipolar","Bipolar"]` default 0 | false (per instance, D1) | no |
| XyX | `xyx` | XY X | 0 Position `linear(0,1)` default 0.5 | **true** (D7) | no |
| XyY | `xyy` | XY Y | 0 Position `linear(0,1)` default 0.5 | **true** (D7) | no |
| Sidechain | `sidechain` | Sidechain | 0 Low Cut `log(20,20000)` Hz default 20; 10 High Cut `log(20,20000)` Hz default 20000; 20 Attack `0..500 ms` skew default 5; 30 Release `5..2000 ms` skew default 150; 40 Source `linear(0,999)` stepped, default 0 (D2) | false | **yes** |

- **Knob** — `value() = if polarity == Bipolar { 2x − 1 } else { x }`;
  `advance` is a no-op.
- **XY** — `value() = 2·pos − 1`; centred pad = no offset. No DSP.
- **Sidechain** — `ModulatorState` gains `sc: ScState` (`Copy`):
  `{ low: Svf, high: Svf, low_coefs: SvfCoefs, high_coefs: SvfCoefs,
  low_on: bool, high_on: bool, cached_low_hz: f32, cached_high_hz: f32,
  follower: EnvFollower }`. Coefficients are recomputed in `advance` only when
  the effective cut (param + `mod_offset`) moved past `OFFSET_EPSILON`.
  `low_on = low_hz > 20.5`, `high_on = high_hz < 19_500` (bypass at
  extremes, REQ-007). Detection is `Detection::Peak`.
  - New method `ModulatorState::feed_sidechain(&mut self, mono: &[f32])` runs
    each frame through `low → high → follower`. `advance` itself does no audio
    work for this kind.
  - `value()` = `((20·log10(max(level, 1e-6)) + 60) / 60).clamp(0, 1)` —
    −60…0 dBFS → 0…1 (D5).
  - Mono collapse of the tap: `0.5·(L + R)` per frame, done by the caller.
- **Poly path** — `is_mono_only()` returns true for `MidiCc | Sidechain`.
  `knob`/`xyx`/`xyy` stay poly-eligible (param-only values, identical per
  voice).
- **Payload** — `display_state()` rows: knob/xy → `(stage 0, x 0, value)`;
  sidechain → `(stage 0, x 0, value)`. No payload format change.

## Sidechain taps (engine)

### Device In

`ModulatedDevice::control_step_impl` gains the step's input slice
(`&inputs[in_range]`, interleaved stereo; empty for instruments). Before the
modulators advance, every `Sidechain` modulator whose Source is 0 is fed the
step's frames (mono-collapsed into a stack `[f32; CONTROL_STEP]`, chunked when
`frames > CONTROL_STEP` — the `process_block_with_extra` whole-block path).
All three call sites (`process_block`, `process_block_with_extra`,
`begin_block`) pass their inputs. No capture buffer is stored. An instrument
has no input, so Device In reads silence (documented).

### Channel source

- `EngineState` gains `sc_taps: SidechainTaps` (new
  `Engine/src/audio/mixing/sidechain.rs`):
  `slots: Vec<TapSlot { channel_id: ChannelId, mono: Vec<f32>, frames: usize }>`
  with each `mono` preallocated to the engine's max block size, and
  `subscribers: Vec<TapSubscriber { channel_id, device_path, mod_id, slot }>`.
  Both are rebuilt **only by the command thread** (allocation happens before
  the lock is taken; the swap is under the lock, the old `Vec`s are dropped
  after release via `CommandEffects`).
- **Rebuild triggers:** modulator add/remove, a sidechain Source param change
  (it crosses into a different channel id), channel add/remove, device
  add/remove/move, `/project/init`. The rebuild walks every channel's chain
  (containers included) for `Sidechain` modulators with Source ≥ 1 and
  allocates one slot per distinct source channel that exists. A source id that
  does not exist gets no slot → the subscriber is skipped → the follower
  decays to 0 (REQ-006 "removed channel → silence").
- **Snapshot (end of `mix_and_output`):** for each slot, copy
  `0.5·(L+R)` of the source channel's final buffer (post-fader, post-pan;
  master is post-master-fader) into `mono`, set `frames`. Muted or
  solo-silenced channels snapshot silence.
- **Feed (start of the next callback, before the device passes):** for each
  subscriber, `channel.device_at_path_mut(path)` → downcast to
  `ModulatedDevice` → `feed_sidechain(mod_id, &slot.mono[..frames])`. The
  whole previous block is fed at once (D3: one block of latency, ≤ 5.3 ms at
  256 frames / 48 kHz). If the tap and current block sizes differ, the
  follower simply sees the previous block's frames.
- Cost per block: one ≤ max-block mono copy per **source channel** (not per
  modulator) plus 2 SVF + follower per frame per subscriber.

### Sleep

No change. `ModulatedDevice::is_sleeping()` already returns false whenever
it has any modulator, and `control_step` runs every sub-block even when the
inner device sleeps (the inner sub-block is then passed through). A unit test
pins this for `sidechain` (REQ-009). `accepts_note_input` is **not** touched
(a sidechain must not route notes into an effect).

## Godot

### Model

- `Godot/data/Modulator.gd` — `is_bipolar() -> bool`: for `knob` reads
  Polarity (param 10) ≥ 0.5; otherwise `owner.is_modulator_kind_bipolar(kind)`.
  `DeviceInstance.get_routes_into` uses `mod.is_bipolar()` instead of the
  kind lookup, so a Bipolar knob's arc is drawn centred (REQ-002).
- **New `Godot/data/XYPad.gd`** (`RefCounted`): holds `x: Modulator`,
  `y: Modulator`. API: `position() -> Vector2` (normalized 0..1),
  `set_position(v: Vector2)` (two `owner.set_modulator_param(id, 0, …)`
  calls), `mod_ids() -> Array[int]`, `name` (= `x.name`). The pair adds no
  sync code: each slot syncs through `sync_modulators_to_engine` as today.
- `DeviceInstance` additions:
  - `add_xy_pad() -> XYPad` — needs two free ids (`_lowest_free_mod_id`
    twice); refuses with a warning when fewer than two are free (nothing
    added). Appends `xyx` then `xyy` at the end of the array. Name: x gets
    `_unique_modulator_name("XY Pad")`, y gets `"<x name> Y"`.
  - `remove_xy_pad(pad)`, `duplicate_xy_pad(pad)` — two-slot variants built
    on the existing functions; duplicate inserts the copy pair adjacent at the
    end.
  - `rename_modulator` on an `xyx` that heads a pair also renames its `xyy`
    to `"<name> Y"`.
  - `move_modulator_block(from_index, count, to_index)` — moves 1 or 2
    contiguous entries and emits `modulators_reordered`; `ModulatorDrag`
    uses it instead of `swap_modulators` whenever a pair is involved (a swap
    would split a pair, D4).
  - `xy_pairs() -> Array[XYPad]` — scans the flat array: an `xyx` immediately
    followed by an `xyy` forms a pair.

### Pane / panel

- **`+` menu** (`ModulatorsPane._refresh_kinds`) — hides `xyy`; lists `xyx`
  as "XY Pad"; `_on_add_kind("xyx")` → `device.add_xy_pad()` (D6).
- **Grid** (`_rebuild_grid`) — walks the array; a pair yields one tile
  (`ModulatorPanel.setup_pair(pad)`), an orphan `xyx`/`xyy` a plain tile.
- **Tile** (`ModulatorPanel`) — `setup_pair(pad)`: header (name/rename from
  x), `XYPadPanel` as the display, and two wire buttons "X" and "Y" in an
  `HBoxContainer` (`SHRINK_CENTER`). Each is `toggle_mode`, `flat = true`,
  `cable.svg` icon, and colored by its slot's array index
  (`ModDisplay.source_color`): `font_color`, `font_hover_color`,
  `font_pressed_color`, `icon_normal_color`, `icon_hover_color`,
  `icon_pressed_color` overrides. Toggle → `ModAssign.begin(owner, slot
  mod_id)`. `_sync_wire` becomes `_sync_wires()` over
  `[[button, mod_id], …]` so one or two buttons share the pulse/`is_active_for`
  logic. Right-click menu lists routes of both slots.
  - REQ-010 also applies to the existing single `_wire` (same overrides from
    `_color()`).
- **`XYPadPanel.gd`** (new) — wraps an `XYSlider` (`0..1` ranges,
  `show_value_labels = false`, `show_axis_lines = false`, small
  `handle_radius`); `values_changed` → `pad.set_position`; refreshes with
  `set_values_no_signal` on `modulator_changed`. Draws the white live dot
  from both slots' `kind 2` values (mapped back from −1..1), interpolated like
  `ModulatorDisplay`. It uses `MOUSE_FILTER_STOP` and handles its own
  `_gui_input`, so a press on the pad never starts tile select/drag;
  `ModulatorPanel` skips its drag-threshold logic for presses inside the pad
  rect.
- **Display** (`ModulatorDisplay`) — `knob`: an arc glyph at the Value
  (centred arc when Bipolar); `sidechain`: the generic level trace (already
  the fallback).
- **Options panel** (`_refresh_detail`):
  - `knob` — generic param controls in `KNOB_ORDER := [0, 10]`.
  - pair — one 140×140 `XYSlider` bound to both slots, the same way as
    `XYPadPanel`.
  - `sidechain` — generic controls for 0/10/20/30 in `SC_ORDER`; Source (40)
    is a custom `OptionButton`: "Device In" (0) + every project channel by
    name (master included, hardware outputs excluded), item metadata =
    channel id, written via `set_modulator_param` as the normalized id. It is
    rebuilt when the project's channel list changes. A stored id that no
    longer exists shows as "(missing channel)".

### Persistence

No new keys: a pad saves as two `Modulator`s (`xyx` then `xyy`, adjacent);
the sidechain Source saves its channel id like any param. On load,
`from_json` rebuilds the flat array and the pane pairs adjacent entries. A
hand-edited save whose slots are no longer adjacent renders as two plain
tiles (D4). DAWproject export ignores modulators as today.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `ModulatorState.sc` (filters, follower) | audio callback (control step / tap feed), under the state lock | command thread sets params under the lock | yes — `Copy`, fixed-size, per-frame DSP |
| `EngineState.sc_taps` slots and subscribers | command thread builds (lock released), swaps under the lock | callback: snapshot at end of mix, feed at block start | yes — preallocated; callback never resizes |
| Device In frames | audio callback, stack buffer per step | — | yes |
| `XYPad`, pair grouping, source menu | Godot main thread | pane, save/load | n/a |

## Data and protocol changes

- No new OSC address. `/builtin/modulator_info` reports 12 kinds and four new
  `/builtin/modulator_kind` records (`knob`, `xyx`, `xyy`, `sidechain`).
- `docs/subsystems/osc-protocol.md`: new kinds, Sidechain Source = channel id
  (0 = Device In), one-block cross-channel latency, post-fader tap point.
- `docs/subsystems/engine-architecture.md`: kinds list, `is_mono_only`
  covers `sidechain`, sidechain tap snapshot/feed in the mixing section.
- `docs/subsystems/godot-osc.md`: XY pair (two slots, one tile, adjacency).
- Persisted: additive `kind` values only.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/modulation/kinds.rs` | Four variants appended; ids/names/tables (`KNOB_VALUE`, `KNOB_POLARITY`, `XY_POS`, `SC_LOW_CUT`, `SC_HIGH_CUT`, `SC_ATTACK`, `SC_RELEASE`, `SC_SOURCE`); `bipolar` (Xy*), `is_mono_only` (Sidechain); tests |
| `Engine/src/audio/modulation/state.rs` | `ScState`, `feed_sidechain`, `value()`/`advance`/`reset` for the new kinds; tests |
| `Engine/src/audio/modulation/host.rs` | Inputs passed into `control_step_impl` (Device In feed, all three call sites); `feed_sidechain(mod_id, frames)`; `sidechain_sources()` for the rebuild walk; tests (incl. never-sleeps) |
| `Engine/src/audio/mixing/sidechain.rs` | **New**: `SidechainTaps`, snapshot and feed |
| `Engine/src/audio/mixing/mod.rs` | Snapshot call at the end of `mix_and_output` |
| `Engine/src/audio/engine.rs` | Feed call at block start, before the device passes |
| `Engine/src/audio/state.rs` | `sc_taps` field |
| `Engine/src/audio/command_worker/*.rs` | Rebuild on the triggers listed above |
| `Engine/src/osc/encode.rs` | Tests only (12 kinds advertised) |
| `Godot/data/Modulator.gd` | `is_bipolar()` |
| `Godot/data/XYPad.gd` | **New** pair model |
| `Godot/data/DeviceInstance.gd` | `add_xy_pad`, `remove_xy_pad`, `duplicate_xy_pad`, `move_modulator_block`, `xy_pairs`, pair rename, `get_routes_into` uses `is_bipolar()` |
| `Godot/devices/modulators/ModulatorsPane.gd` | `+` menu, pair-aware grid, detail branches, Source menu |
| `Godot/devices/modulators/ModulatorPanel.gd` | `setup_pair`, two wire buttons, `_sync_wires`, flat/coloured wires, pad press isolation |
| `Godot/devices/modulators/XYPadPanel.gd` | **New** compact pad + live dot |
| `Godot/devices/modulators/ModulatorDisplay.gd` | `knob` glyph |
| `Godot/devices/modulators/ModulatorDrag.gd` | Pair payload, `move_modulator_block` |
| `docs/subsystems/osc-protocol.md`, `engine-architecture.md`, `godot-osc.md` | See above |
| `Godot/tests/test_modulators_ui.gd`, `test_device_modulators.gd` | See test plan |

## Migration and compatibility

- Old projects contain none of the new kinds → load identically.
- New project + old engine: unknown kinds → warning on add, modulator inert
  (same as the spec 032 `cc` rollout).
- Old Godot + new engine: extra advertised kinds just appear in the menu
  (`xyx`/`xyy` as two plain kinds; harmless).
- An XY pad uses **2** of the 8 slots; `add_xy_pad` refuses when < 2 are free.

## Test plan

- **Engine unit** (`cargo test modulation`, `cargo test sidechain`):
  - `from_id` ↔ `id` round-trip, `COUNT == 12`, existing indices unchanged,
    tables ≤ `MAX_KIND_PARAMS`.
  - knob: unipolar value = param; bipolar = 2x − 1; route offsets a Delay
    Mix by the REQ-001/002 numbers.
  - xy: value = 2·pos − 1; default 0.5 → 0.
  - sidechain Device In: a sine into a wrapped Delay's input raises the
    value; silence decays it to 0; the whole-block
    `process_block_with_extra` path (block > 64) feeds every frame.
  - filters: Low Cut 500 Hz drops a 50 Hz tone ≥ 20 dB; High Cut 500 Hz
    drops a 5 kHz tone ≥ 20 dB; extremes match the raw level.
  - level map: 0 dBFS → 1, −60 dBFS and below → 0.
  - taps: subscriber on channel A, source B → value follows B one block
    late; source id missing → no slot, value decays to 0, no panic; two
    modulators on one source share one slot.
  - sleep: wrapped sleepy device with a sidechain stays non-sleeping and its
    value tracks the feed after > 3 s of silent input.
  - payload rows for the four kinds; `/builtin/modulator_info` count 12.
- **Godot** (`Godot/tests/run_all.sh modulator`):
  - `add_xy_pad` → 2 entries, adjacent, one tile; 7 used → refused;
    delete/duplicate/rename keep the pair; save/load round-trips.
  - drag a pair past a plain tile and a plain tile past a pair → pairs stay
    adjacent.
  - X/Y buttons start assign mode for their own slot; flat + colour overrides
    present on both pair and plain wire buttons.
  - `XYPadPanel.set_values(0.3, 0.8)` → both slots' param 0 set (model).
  - knob Bipolar → `get_routes_into` reports `bipolar = true`.
  - sidechain Source menu lists Device In + channels; selecting writes the
    channel id; a missing id shows "(missing channel)".
- **Live** (`Engine/run_release.sh` + `godot --path Godot`):
  - dynamic EQ: EQ on channel A, sidechain source B, Low Cut 200 Hz,
    High Cut 2 kHz → band gain at −0.5; loop on B → band dips in time.
  - ducking: source B → Utility gain on bass channel A.
  - XY pad: two destinations move together; rename/duplicate/delete/drag the
    pair; save/reload; `Engine/logs/last_warn.log` clean.

## Decisions

- **D1** — Knob polarity is a per-instance **parameter**; `bipolar()` stays
  kind-fixed (false for Knob) and Godot reads the instance via
  `Modulator.is_bipolar()`.
- **D2** — Sidechain Source stores a **channel id** as a stepped
  `linear(0, 999)` param (0 = Device In, 1 = master, 2–999 user channels;
  hardware outputs ≥ 1000 are not sources). Ids are stable across reorder and
  rename; a static enum can't hold project channels.
- **D3** — Cross-channel taps are snapshotted post-fader at the end of the
  block and fed whole at the start of the next (one block of latency);
  Device In is fed per control step from the live input (no latency).
- **D4** — XY is a **Godot-level pair** over two engine slots, identified by
  array adjacency (`xyx` then `xyy`); every array mutation keeps pairs
  contiguous (`move_modulator_block`); a broken pair degrades to two tiles.
- **D5** — The follower is peak-detected and mapped −60…0 dBFS → 0…1, so the
  route amount alone sets depth (a linear amplitude would make anything below
  −20 dBFS nearly inert). No threshold/gain param (`MAX_KIND_PARAMS` is full).
- **D6** — The pane hides `xyy` and renames `xyx` → "XY Pad"; the engine
  advertises both truthfully.
- **D7** — XY axes are bipolar (`2·pos − 1`) so a centred pad applies no
  offset; a unipolar macro is what Knob is for.
- **D8** — The tap point is post-fader, post-pan (what the listener hears
  from that channel). Pre-fader taps are out of scope.

## Risks

| Risk | Mitigation |
|---|---|
| Tap rebuild misses a trigger → stale subscriber path | Rebuild from one function on every structural change; the feed treats a path that no longer resolves to a `ModulatedDevice` as skip, never panic |
| Snapshot cost with many sources | One mono copy per distinct source channel; measure `/engine/load` with 8 sidechains on a busy project |
| Filter recompute per control step | Cached coefficients, recompute only past `OFFSET_EPSILON` |
| Pair invariants break (drag, duplicate, hand-edited save) | `move_modulator_block`, tests pin drag both ways; degrade to two tiles |
| `ModulatorPanel` refactor breaks plain tiles | `test_modulators_ui.gd` before/after |
| A modulated device never sleeps → CPU | Existing behaviour (ADR-0014), not new; the sidechain adds 2 SVF + follower per frame |
| Old engine + new save | Same warning path as spec 032 (REQ-011) |
