# Modulator panel — Design

Implements [requirements.md](./requirements.md). Every path and symbol below was verified
against the tree before writing. Where the code contradicted the first draft of
requirements.md, the correction is listed under
[Requirement amendments](#requirement-amendments-applied).

## Context

- `Godot/devices/modulators/ModulatorsPane.gd` — the pane being rebuilt: `HBoxContainer`
  with a left `VBoxContainer` (title + `+` `MenuButton`, then a `ChevronScrollContainer`
  paging a `TILE_COLUMNS := 2` `GridContainer` of `ModulatorTile`s) and a right detail
  `ScrollContainer` (built per kind in `_refresh_detail`; knobs/enums/bools in
  `_build_param_control`, envelopes in `_build_envelope_detail`, flowed by
  `_layout_param_columns`). `_remembered` keeps the selected mod id per device.
  **The detail controls are not attached to `ModAssign` or `ModLive` today.**
- `Godot/devices/modulators/ModulatorTile.gd` — today's tile: `PanelContainer` 86×42,
  colour strip + name + `LineEdit` rename + wire `Button` (`_on_wire_toggled` →
  `ModAssign.begin/end`, `_sync_wire` pulse) + right-click `PopupMenu` (routes,
  Rename/Duplicate/Delete). `_gui_input` emits `selected` on **left press**.
  `_target_name` names `param/…` and `child/…` targets only — a `mod/…` target falls
  through and shows the raw string.
- `Godot/data/Modulator.gd` — the model: `mod_id`, `kind`, `name`, `params`, `routes`;
  every mutator goes through the owner `DeviceInstance`.
- `Godot/data/DeviceInstance.gd`:
  - `MAX_MODULATORS` (8, ids 0..7, as in the engine).
  - `add_modulator(kind)` (line ~637) appends with the next free id;
    `duplicate_modulator` appends; `remove_modulator` (line ~708) removes the entry and
    sends `modulator/{id}/remove` — it does **not** touch other modulators' routes that
    target the removed one.
  - `get_routes_into(target)` (line ~796) reports `color_index` = array index, which
    `ModAssign.ranges_for` turns into knob arc colours.
  - `sync_modulators_to_engine()` (line ~816) sends, **per modulator in array order**,
    `add` → params → routes.
  - `_modulators_to_json()` (line ~2405) sorts the saved array by `mod_id` (line 2422);
    `from_json` (~line 2522) rebuilds `modulators` in JSON array order.
- `Engine/src/audio/modulation/host.rs`:
  - `ModulatedDevice` keeps `mods: [Option<ModulatorState>; MAX_MODULATORS]` keyed by
    `mod_id` — there is no engine-side order.
  - `ModTarget::Modulator(u8, ParamId)` exists and parses from `mod/{mod_id}/param/{id}`
    (line ~625), but is **stored, not evaluated**: the control step skips it
    (line ~472, comment "Phase 9: modulator-to-modulator routes are stored but not
    evaluated"), `apply` ignores it (line ~545) and it never reaches `push_contrib`.
  - `remove_modulator` (line ~734) clears routes *out of* the removed slot only.
  - `modulation_payload()` (line ~299) builds `u16 count` + kind 0/1 records into a
    `Vec::with_capacity(..)`; `poll_device_data()` (line ~1211) returns it while
    subscribed.
- `Engine/src/audio/mixing/mod.rs` `forward_device_events` (line ~50) calls
  `poll_device_data()` **on the audio callback**, inside `mix_and_output`. The existing
  payload `Vec` and the `"modulation".to_string()` are therefore allocated on the audio
  thread at ~20 Hz per subscribed device (pre-existing; the spectrum stream does the
  same).
- `Engine/src/audio/modulation/state.rs` — `ModulatorState`: `lfo.phase` (`f64` 0..1),
  `env` (`AdsrEnvelope`, `state()` → `AdsrState`, `value()`), `apply_params()` caches
  envelope times; `value()` is −1..1 for `lfo`/`keytrack`, 0..1 otherwise.
  `ModulatorKind::Release` is the **note-off release velocity**, not an envelope;
  `is_envelope()` covers `adsr` and `ad` only.
- `Engine/src/audio/modulation/voice.rs` — `VoiceModSpec`: the static modulator
  definitions + `Own` routes a voice-modulating device (PolySynth,
  `polysynth/voice.rs`) evaluates per voice. Mod→mod routes are not part of it.
- `Engine/src/audio/modulation/lfo.rs` — `LFO_SHAPES = ["Sine", "Triangle", "Saw",
  "Square", "S&H"]`.
- `Godot/devices/modulators/ModLive.gd` — subscribes the `modulation` stream while a view
  of the device is shown; `_decode` (~line 274) reads `u16 count` records and treats
  **every non-1 kind as an offset**; controls keyed `"{device id}:{param}"`.
- `Godot/devices/modulators/ModAssign.gd` — assign state (`begin`, `end`, `focus`), and an
  API keyed throughout by `(device, param_id)`: `relative_target`, `ranges_for`,
  `amount_for`, `amount_text` (reads `device.get_parameter`), `attach`, `_refresh_hint`.
- `Godot/components/ModDisplay.gd` — `source_color(index)`.
- `Godot/devices/device_lane/DevicePanel.gd` — `HEIGHT := 350.0` (fixed); selection via
  `theme_type_variation = &"DeviceCardSelected" if selected else &"DeviceCard"`
  (line ~50, also used by `CompactDevicePanel.gd`).
- `docs/subsystems/godot-drag-and-drop.md` — the DnD contract (commit on drop only,
  static `resolve(owner, drag, global_mouse) -> Target` with `commit()`,
  `DropIndicator`, `DragDrop.current_drag`); models: `devices/DeviceDrag.gd`,
  `devices/DeviceDropTarget.gd`, `tests/test_device_drop.gd`.
- Existing tests: `Godot/tests/test_modulators_ui.gd`, `Godot/tests/test_device_modulators.gd`.
- `Godot/assets/icons/plus.svg`, `Godot/assets/icons/cable.svg`.

## Approach

Four phases:

1. **Layout** — the left side becomes a 3-row, column-major grid of square panels with
   trailing placeholder cells; the `+` header button and the pager go away.
2. **Reorder** — swap-by-drag, array order persisted (drop the `mod_id` sort), engine sync
   made order-safe.
3. **Displays** — the `modulation` payload gains a trailing, length-prefixed record block
   with one per-modulator state record; `ModLive` decodes it and each panel draws a
   kind-specific display with the white dot.
4. **Modulator→modulator** — this is **new engine work**, not just UI: the engine
   evaluates `ModTarget::Modulator` routes (one control step of delay, so order- and
   cycle-safe), reports their offsets in the trailing block, and cleans dangling routes on
   removal; Godot's `ModAssign`/`ModLive` learn modulator-parameter targets.

Rejected:
- An engine `reorder` command — slots are id-keyed; re-numbering ids would break every
  route that names a modulator.
- Expanding the selected panel in place — the detail column exists, is tested, and keeps
  cells a constant size.
- Encoding modulator-parameter offsets as `kind 0` records — `kind 0` addresses a
  parameter by child path + param id; a modulator param would resolve to the device's own
  parameter with the same id and light the wrong knob.
- Evaluating mod→mod routes in dependency order within one step — needs a topological sort
  and a cycle rule on the audio thread; a one-step delay gives the same result within one
  control step and handles cycles for free.

## Grid layout

- **Column-major.** REQ-001/004 ("filling all 3 grows a second column", "1 column of panels
  + 1 column of placeholders") describe the first column filling top to bottom.
  `GridContainer` fills row-major, so the grid is an `HBoxContainer` of column
  `VBoxContainer`s (3 cells each), both with separation `SEP := 2`. Cell `i` sits in
  column `i / 3`, row `i % 3`.
- Columns `C = max(1, n / 3 + 1)` (integer division) → placeholders `P = 3·C − n` are
  1–3; `n = 0` → 1 column of 3 placeholders; `n = 3` → 2 columns; deleting 4 → 3 keeps
  2 columns (panels + placeholders); deleting 3 → 2 drops to 1 column (REQ-004).
- **Capacity.** At `n == MAX_MODULATORS` (8): `C = 3`, `P = 1`. That placeholder is shown
  **disabled** (dimmed `+`, tooltip "Maximum of 8 modulators") so REQ-002's "never zero
  placeholders" holds without offering an add that `add_modulator` would refuse.
- **Square side.** `DevicePanel.HEIGHT` is fixed, so the side is a function of the
  pane's available height only: `side = clamp(floor((avail_h − 2·SEP) / 3),
  PANEL_MIN_SIDE, PANEL_MAX_SIDE)` with `PANEL_MIN_SIDE := 56` (header + wire button +
  a minimal display) and `PANEL_MAX_SIDE := 110`. `avail_h` is the grid's **parent**
  height minus the title row; computed in `_layout_panel_size()` on the grid parent's
  `resized` — **not** the pane's, which fires before its children are re-fitted, so a
  reveal settles the pane at the final height while the parent is still stale and
  `side` never recomputes (corrected after implementation; the pane's `resized` left
  the displays at zero height until something else resized the pane) — and applied
  only when `side` changes. Because the grid's minimum height is
  `3·side + 2·SEP ≤ avail_h` by construction, setting it can't grow the pane and re-fire
  `resized` (no feedback loop). Every cell (panel or placeholder) gets
  `custom_minimum_size = Vector2(side, side)` and `SIZE_SHRINK_BEGIN` both ways so it
  stays square.
- **No pager.** The `ChevronScrollContainer` is dropped; the pane widens one column
  (`side + SEP`) per growth step and the device lane's horizontal `ScrollContainer`
  (`DeviceLane.gd`) is the only scrolling surface. Max width: 3 columns ≈ 334 px.
- `_rebuild_tiles()` → `_rebuild_grid()`: compute `C`, place `ModulatorPanel`s in array
  order, then placeholders. Rebuilt on `modulator_added`, `modulator_removed` and
  `modulators_reordered` (≤ 8 entries; a rebuild is cheap). Rebuild keeps the selection
  by `mod_id`.

## Panel and placeholder

- `ModulatorTile.gd` is **renamed to `ModulatorPanel.gd`**. Content `VBoxContainer`:
  1. Header: colour strip (2 px, `ModDisplay.source_color(array index)`) + name label
     (+ inline `LineEdit` rename, as today; the label clips).
  2. Display: `ModulatorDisplay`, `SIZE_EXPAND_FILL` (phase 3; until then an empty
     expanding `Control`).
  3. Bottom: the wire `Button` (`cable.svg`), centered (`SIZE_SHRINK_CENTER`, REQ-006);
     `_on_wire_toggled`/`_sync_wire`/pulse moved verbatim.
- Input changes (needed for drag, below): left **press** records the press position;
  **release without crossing the drag threshold** emits `selected` (today it selects on
  press, which would toggle selection at the start of every drag). Right-click menu and
  hover → `ModAssign.set_hover` unchanged.
- Selection: `theme_type_variation = &"DeviceCardSelected" if selected else
  &"DeviceCard"` (REQ-005). The per-tile `StyleBoxFlat` code is deleted.
- `_target_name` gains the `mod/{id}/param/{pid}` case → `"{modulator name} › {param
  name}"` (needed by REQ-011's disconnect path; today it prints the raw string).
- **Placeholder**: a flat `Button` with the `DeviceCard` variation, `plus.svg` scaled to
  ~40 % of the side, tooltip "Add modulator". Pressing it opens a `PopupMenu` filled by the
  pane's existing `_refresh_kinds` (registry-driven). Picking a kind calls the existing
  `add_modulator(kind)` and selects the result.
  - Placement: placeholders always trail the panels, so **the new modulator lands in the
    first free cell** (array index `n`), whichever `+` was clicked. A sparse grid (holes
    between panels) would need a persisted position per modulator, which REQ-008 rules
    out. See amendment A3. No `add_modulator_at` is added.

## Order and reorder

- `DeviceInstance` gains `signal modulators_reordered` and
  `swap_modulators(a_mod_id: int, b_mod_id: int)` — swaps the two array entries, keeps both
  `mod_id`s, emits `modulators_reordered`. No OSC: engine evaluation is by slot and route,
  never by order.
- Listeners of `modulators_reordered`: the pane (rebuild) and `ModAssign.notify_changed()`
  — knob arcs take their colour from the array index (`get_routes_into` →
  `color_index`), so every modulated knob on the device must recolour.
- Persistence: delete the `out.sort_custom` at `_modulators_to_json` line 2422; the array
  serializes in display order. `from_json` already appends in array order (REQ-008).
  Presets use the same serializer, so they keep order too.
- **Sync order fix.** `sync_modulators_to_engine` becomes two passes: every `add` + params
  first, then every route. Today a route `mod/{B}/…` sent while handling A fails in the
  engine's `parse_target` ("no modulator B") when B comes later in the array — latent
  because no UI creates mod routes yet, guaranteed once REQ-011 ships and reorder decouples
  array order from id order.
- **Drag**: new `ModulatorDrag.gd` (payload `{device_id, mod_id}`, modelled on
  `DeviceDrag.gd`), started from a panel press-and-move past a 6 px threshold, but not when
  the press began on the wire button or the rename `LineEdit`. The pane is the single drop
  host: static `resolve(pane, drag, global_mouse) -> Target` maps the mouse to a panel
  cell. Invalid: another device's panel, a placeholder, outside the grid, or the dragged
  panel itself. Indicator: `DropIndicator` outline of the target panel. Commit calls
  `swap_modulators`. Nothing moves during the drag; a cancelled drag needs no cleanup.
  Assign mode is left as it is by a reorder (it's keyed by `mod_id`).

## Display data (engine)

Per-modulator state for the display, read from existing state — **no new engine state**
(the requirements' non-functional rule):

| Kind | `stage` | `x` | `value` |
|---|---|---|---|
| `lfo` | 0 | `lfo.phase as f32` | `value()` (−1..1) |
| `adsr`, `ad` | `env.state()` as u8: 0 idle, 1 attack, 2 decay, 3 sustain, 4 release | 0.0 | `env.value()` |
| everything else (`velocity`, `keytrack`, `random`, `release`, `cc`, future) | 0 | 0.0 | `value()` |

`ModulatorState::display_state() -> (u8, f32, f32)` returns that row. The envelope dot's
x position is derived in Godot from `(stage, level)` (below), so no "progress through
stage" counter is added.

### Payload layout

Old decoders read `u16 count` records and stop; `ModLive._decode` treats any kind ≠ 1 as an
offset, so new kinds **must not** go into that counted list. New data goes in a trailing
block after it:

```
u16 record_count                 ; kind 0/1 records, unchanged
record_count × kind 0/1 record   ; unchanged
u16 ext_count                    ; absent in old engines → decoder stops here
ext_count × {
  u8 kind
  u8 len                         ; bytes that follow, so unknown kinds are skippable
  len bytes
}
  kind 2 (modulator state, len 10):        u8 mod_id, u8 stage, f32 x, f32 value
  kind 3 (modulator-param offset, len 9):  u8 mod_id, u32 param_id, f32 offset
```

- One `kind 2` per occupied slot (≤ 8), one `kind 3` per evaluated `ModTarget::Modulator`
  target (≤ `MAX_ROUTES`).
- Version skew: old Godot ignores the trailing bytes; old engine sends none → displays are
  static with no dot. The `len` byte lets a future record kind be added without another
  layout change.
- The new `ModLive` decoder **skips** kind 0/1-list records whose kind is neither 0 nor 1
  (today it misreads them as offsets).

### Audio-thread cost (corrected)

`modulation_payload()` runs on the audio callback (`forward_device_events` →
`poll_device_data`). The `Vec` it returns is already allocated there today; this design
does not add an allocation: the `with_capacity` grows by the fixed maximum of the trailing
block, `2 + 8·12 + MAX_ROUTES·11` bytes, so the extra bytes never reallocate. The work is
O(8 + MAX_ROUTES) copies at ~20 Hz, only while subscribed. Moving device-data
serialization off the callback (preallocated buffers swapped to the command thread) is a
separate, pre-existing debt and out of scope — see amendment A1.

## Modulator→modulator evaluation (engine)

- **Effective parameters.** `ModulatorState` keeps `params` (base, what `set_param`
  writes and the UI shows) and adds `mod_offset: [f32; N]` (N = the kind table's
  capacity, fixed array). Everything that reads a parameter for evaluation
  (`advance`, `value`, `apply_params`) reads `clamp(base + offset, 0, 1)`. `get_param`
  still returns the base.
- **Order.** In the control step, before `advance`, each `ModTarget::Modulator(m, p)`
  route contributes `amount · values_prev[src]` (the previous step's `self.values`),
  summed per `(m, p)`. Offsets are applied with `set_mod_offset(p, off)`, which re-runs
  `apply_params` only when the offset moved by more than `OFFSET_EPSILON` (envelope times
  are cached; LFO rate is read per advance). One control step of delay makes evaluation
  independent of slot and array order (REQ-007) and makes cycles (A→B→A, A→A) bounded
  delayed feedback rather than a hazard.
- **Self-routes** (`mod/{own id}/…`) are allowed by the engine (bounded by the delay) but
  not offered by the UI; see below.
- **Stream.** Each evaluated target's summed offset goes into a `kind 3` record.
- **Removal.** `remove_modulator(B)` additionally clears every route whose target is
  `ModTarget::Modulator(B, _)`; Godot's `remove_modulator(B)` erases `mod/B/…` keys from
  every other modulator's `routes` (and emits `route_changed`). Otherwise a modulator added
  later that reuses id B inherits the dangling routes.
- **Voice-modulating devices (PolySynth) — decision D1: per-voice.** Per-voice routes are
  evaluated inside the device from `VoiceModSpec`, which carries static params and `Own`
  routes only. Mono-only evaluation would make B's knob breathe in the UI while the
  per-voice B that drives the sound stays still, so mod→mod is evaluated per voice too:
  - `VoiceModSpec` gains `mod_routes: [VoiceModRoute; MAX_ROUTES]` + `mod_route_len`,
    where `VoiceModRoute { mod_slot, target_slot, param_id, amount }`. It stays `Copy`
    and fixed-size; `push_voice_mod_spec` fills it from `ModTarget::Modulator` routes
    whose source and target are both voice-evaluated kinds.
  - `polysynth/voice.rs` `render_chunk` already samples `state.value()` before
    `advance`; it sums `mod_routes` from those values into a per-voice
    `[[f32; N]; MAX_MODULATORS]` scratch and calls `set_mod_offset` on the target state
    before advancing — the same one-step delay as the mono path, per voice.
  - **Mono-only source → voice-evaluated target** (a `cc` modulator wired to an LFO's
    rate on PolySynth): the `cc` source doesn't exist per voice. The wrapper evaluates
    that offset on its mono pass and hands it to the device every control step through a
    new `AudioDevice::set_voice_mod_param_offset(mod_slot, param_id, offset)` (default
    no-op, like `set_param_mod`); the device stores it in a fixed
    `[[f32; N]; MAX_MODULATORS]` and adds it to every voice's per-voice offset.
  - A voice-evaluated source → mono-only target (`cc` kind's own params) is evaluated on
    the mono path only, which is where that target lives.
  - The wrapper's mono copies of B are modulated as well, so the display and the `kind 3`
    stream behave identically on both kinds of device.

## Displays (Godot)

- `ModLive` decodes the trailing block: `kind 2` → `_mod_states[device_instance_id][mod_id]
  = {stage, x, value}` (replaced wholesale per payload, like `_live`); `kind 3` → `_live`
  entries under modulator-param keys (below). It emits a new
  `signal modulator_states_changed(device)` once per payload. Displays connect to it — no
  per-panel `_process` polling. `static func modulator_state(device, mod_id) ->
  Dictionary` returns `{}` when no record arrived. No new subscription: the pane is inside
  a shown device view, which already keeps the stream subscribed.
- New `Godot/devices/modulators/ModulatorDisplay.gd` — a `_draw()` `Control` bound to
  `(device, mod_id)`; redraws on `modulator_states_changed` for its device and on
  `modulator_changed(mod_id)` (shape params). The dot is white; the line uses the
  theme's primary accent (REQ-009). While live states flow, the dot interpolates: each
  frame it blends the live phase from the previous sample towards the latest one over the
  observed payload interval (~50 ms), so it glides at frame rate instead of stepping at
  ~20 Hz; stage changes and stream gaps snap.
  - **LFO**: one cycle of the `LFO_SHAPE` param's wave (Sine/Triangle/Saw/Square drawn
    analytically; **S&H** drawn as a fixed staircase glyph, since its values are random).
    Only the phase is live: the dot rides the *drawn curve* at the interpolated phase
    (wrapped modulo one cycle, so it re-enters from the left edge), never an interpolated
    value — lerping across a square wave's cycle end looked wrong.
  - **`adsr` / `ad`**: the curve from the base params (same `ENV_STAGE_PARAM` mapping as
    the pane), time-proportional segments with a fixed-width sustain segment for `adsr`.
    Dot x derived from `(stage, level)`: attack → `level` along the attack segment;
    decay → `(1 − level) / (1 − sustain)` along decay; sustain → middle of the sustain
    segment; release → `1 − level / max(sustain, ε)` along release (exact when released
    from sustain, approximate when released mid-attack); idle → no dot.
  - **Generic** (`velocity`, `keytrack`, `random`, `release`, `cc`, unknown): a ~2 s ring
    buffer (40 samples at 20 Hz) of `value` drawn as a trace, dot at the newest point,
    y-range by the kind's `bipolar` flag (REQ-010). An unknown kind never errors.
  - The dot interpolates between payloads (see above), so it moves at frame rate; the
    ring-buffer trace itself still advances at the stream rate (~20 Hz).
- Missing state (old engine, before first payload): static shape, no dot.

## Modulator→modulator assign (Godot)

- **Keys.** Modulator parameter ids collide with device parameter ids (both start near 0),
  so modulator-param targets get their own key space: route target
  `mod/{mod_id}/param/{param_id}` and `ModLive` key `"{device id}:mod{mod_id}:{param_id}"`.
- **API.** `ModAssign`'s `(device, param_id)` helpers are generalised to take a target
  descriptor `{device, mod_id (−1 = device param), param_id}`: `relative_target`
  (returns `mod/…` for a modulator param, same-device only), `ranges_for`, `amount_for`,
  `amount_text` (reads the modulator's `DeviceParameter`, so a log-scaled Rate shows
  octaves), `_refresh_hint`. `attach_modulator(node, device, mod_id, param_id)` is the
  entry point; `ModLive.attach_modulator` reads the base value from
  `mod.get_param(param_id)` instead of the device.
- **Valid targets**: same device as the assigning modulator; not the assigning modulator
  itself (its own controls show while it is selected and must not light up); knobs only.
  Enum and bool controls stay unassignable, as on devices.
- **What is attached**: the `RotaryKnob`s from `_build_param_control`. The `adsr`/`ad`
  stage times live in `EnvelopeControl` handles, which are not knobs — they are **not**
  assign targets in this spec (amendment A4).
- **Flow**: press A's wire (assign mode) → click B's panel (selection does not end assign
  mode; verified in `ModulatorTile._gui_input` / `ModulatorsPane._on_tile_clicked`) → drag
  on B's Rate knob. Amounts go through the existing `Modulator.set_route` /
  `DeviceInstance` path, which already sends `modulator/{id}/route/set`.
- Disconnect: the panel menu's route list, with the new `_target_name` case.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| modulator slots, `mod_offset` | audio callback (control step) under state lock; command thread writes base params | `try_lock` | yes — fixed arrays |
| mod→mod offset sum (mono) | audio callback, wrapper control step | — | yes — fixed `[f32; MAX_ROUTES]` scratch, no alloc |
| mod→mod offsets (per voice) | audio callback, PolySynth `render_chunk` | `VoiceModSpec` hand-off, `set_voice_mod_param_offset` | yes — fixed per-voice arrays, spec is `Copy` |
| payload incl. trailing block | **audio callback** (`forward_device_events` → `poll_device_data`) | — | no new allocation beyond the existing pre-sized `Vec` (pre-existing debt, A1) |
| `modulators` array order | Godot main thread | pane, save/load, sync | n/a |
| `ModLive._mod_states` | Godot main thread | displays via signal | n/a |

## Data and protocol changes

- No new OSC address. The `modulation` payload gains the trailing `ext_count` block with
  record kinds 2 and 3 — document in `docs/subsystems/osc-protocol.md` (the
  **Modulation** data-format block, which already lists kinds 0/1) and in
  `docs/subsystems/godot-osc.md`.
- `modulator/{id}/route/set` with a `mod/…` target now has an audible effect (it was
  accepted and ignored). Update `osc-protocol.md`'s route description accordingly.
- Persisted format: no new keys; `modulators` array order changes meaning from "id order"
  to "display order". Old saves are id-sorted, which is also their creation order.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/devices/modulators/ModulatorsPane.gd` | Column-major grid, `_rebuild_grid`, placeholders (incl. disabled-at-capacity), `+` button and pager removed, `_layout_panel_size`, drop host; detail knobs attach via `ModAssign.attach_modulator` |
| `Godot/devices/modulators/ModulatorTile.gd` → `ModulatorPanel.gd` | Square layout, display area, centered wire button, `DeviceCard(Selected)`, select-on-release, drag start, `_target_name` `mod/…` case |
| `Godot/devices/modulators/ModulatorDisplay.gd` | **New**: LFO / envelope / generic displays with white dot |
| `Godot/devices/modulators/ModulatorDrag.gd` | **New**: payload + `resolve` + swap commit |
| `Godot/data/DeviceInstance.gd` | `swap_modulators`, `modulators_reordered`; drop the `mod_id` sort; two-pass `sync_modulators_to_engine`; `remove_modulator` erases `mod/{id}/…` routes on siblings |
| `Godot/devices/modulators/ModAssign.gd` | Target descriptor generalisation, `attach_modulator`, same-device / not-self rule, recolour on reorder |
| `Godot/devices/modulators/ModLive.gd` | Trailing-block decode (kinds 2, 3; skip unknown), `_mod_states`, `modulator_states_changed`, `attach_modulator`, mod-param keys |
| `Engine/src/audio/modulation/state.rs` | `mod_offset`, effective-param reads, `set_mod_offset`, `display_state()` |
| `Engine/src/audio/modulation/host.rs` | Evaluate `ModTarget::Modulator` (one-step delay); `kind 3` contributions; trailing block in `modulation_payload` + capacity; `remove_modulator` clears routes into the removed slot; tests |
| `Engine/src/audio/modulation/voice.rs` | `VoiceModRoute`, `mod_routes` in `VoiceModSpec` |
| `Engine/src/audio/devices/device.rs` | `AudioDevice::set_voice_mod_param_offset` (default no-op) |
| `Engine/src/audio/devices/instruments/polysynth/voice.rs`, `polysynth/mod.rs` | Per-voice mod→mod offsets in `render_chunk`; store wrapper-pushed mono-source offsets |
| `docs/subsystems/osc-protocol.md`, `docs/subsystems/godot-osc.md` | Trailing block, kinds 2/3, mod→mod now evaluated |
| `Godot/tests/test_modulators_ui.gd`, `Godot/tests/test_device_modulators.gd` | Update `ModulatorTile` references; new coverage below |

## Migration and compatibility

- Old projects load in their saved (id-sorted) order — identical to today.
- Old engine + new Godot: no trailing block → static displays, no dots; mod→mod routes
  are stored but silent (as today).
- New engine + old Godot: trailing bytes ignored.
- Old projects can't contain mod→mod routes (no UI ever created them), so enabling their
  evaluation changes no existing sound.

## Test plan

- **Engine unit** (`cargo test modulation`):
  - payload: kind 0/1 list unchanged byte-for-byte; trailing block has one `kind 2` per
    occupied slot with correct stage/x/value for an LFO and an ADSR under a held note;
    `len` lets a decoder skip; capacity covers the maximum (no realloc — assert
    `capacity()` unchanged after build).
  - mod→mod: LFO A → LFO B rate changes B's phase increment one control step later;
    A→B→A cycle stays bounded; swapping slot assignment doesn't change output.
  - `remove_modulator(B)` drops routes into B.
  - per-voice: `push_voice_mod_spec` carries a mod→mod route; a PolySynth voice's LFO B
    rate follows LFO A; a `cc` → LFO-rate route reaches every voice through
    `set_voice_mod_param_offset`.
- **Godot** (`Godot/tests/run_all.sh modulator`):
  - grid: 0 → 1 column / 3 placeholders; 3 → 2 columns, column-major positions; 4 → 2
    columns + 2 placeholders; delete 4 → 3 → 2 shrinks; 8 → one disabled placeholder.
  - placeholder menu lists every registry kind; pick → appended and selected.
  - `swap_modulators` keeps ids, swaps colours (`get_routes_into` `color_index`),
    save/load round-trips order; sync sends all adds before any route.
  - drag resolver: own-device panel valid; placeholder, self, other device invalid;
    commit swaps (mirroring `test_device_drop.gd`).
  - selection: selected panel uses `DeviceCardSelected`; click-without-drag toggles.
  - `ModLive._decode`: old payload (no trailing block), new payload, unknown trailing kind
    skipped; kind 3 lands on the `mod`-namespaced key, not the device param with the same
    id.
  - assign: modulator-param knob accepts a route from another modulator, rejects the
    owning modulator; `remove_modulator` erases sibling `mod/…` routes.
- **Live** (`./run_release.sh` + `godot --path Godot`): LFO + ADSR on a device, play a
  note — dots ride the wave and envelope; LFO A → LFO B Rate, B's Rate knob breathes
  **and B's audible rate changes**, on an effect device and on PolySynth; drag-reorder, save,
  reload, order persists and routes still resolve; check `Engine/logs/last_warn.log` for
  route-parse warnings on load.

## Requirement amendments (applied)

These were found while checking the design against the code, approved, and folded into
requirements.md:

- **A1** — the `modulation` payload is built on the audio callback, not off it; the
  real-time rule is now "no allocation beyond the existing pre-sized buffer".
- **A2** — modulator evaluation is not unchanged: it gains mod→mod offsets, mono and
  per-voice.
- **A3** — REQ-003: a new modulator goes to the first free cell.
- **A4** — `release` (release velocity) uses the generic display; envelope stage handles
  are not assign targets; deleting a modulator removes routes into it.
- **A5** — REQ-002: at 8 modulators the remaining placeholder is disabled.

## Decisions

- **D1** — mod→mod on voice-modulating devices is evaluated per voice (see
  [Modulator→modulator evaluation](#modulatormodulator-evaluation-engine)).

## Risks

| Risk | Mitigation |
|---|---|
| Mod→mod one-step delay audible | The delay is one `CONTROL_STEP` (64 frames, ≈ 1.3 ms at 48 kHz) — below what a modulated LFO rate or envelope time can expose; document it |
| `apply_params` churn when an envelope time is modulated every step | Re-apply only past `OFFSET_EPSILON`; envelope coefficient update is O(1) |
| `ModAssign` generalisation regresses device-parameter assign | Existing `test_modulators_ui.gd` / `test_device_modulators.gd` cover device targets; run before and after |
| `ModulatorPanel` rename breaks references | Grep `ModulatorTile` (pane + tests) during implementation |
| Square side too small on a smaller `DevicePanel.HEIGHT` | `PANEL_MIN_SIDE` floor; display collapses before header/wire do |
