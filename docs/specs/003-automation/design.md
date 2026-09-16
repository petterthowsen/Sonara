# Parameter Automation — Design

Implements [requirements.md](./requirements.md).

## Context

Engine:

- `Engine/src/audio/commands.rs` — the `AudioCommand` enum and `EngineState` (tracks, channels,
  clips, `render_scratch`, the atomics for tick and playing state). `SetDeviceParameter` is
  applied here at line 1508: it resolves `channel.device_at_path_mut()`, normalizes through
  `ParamSetValue`, calls `device.set_parameter()`, **and echoes
  `EngineStatus::PluginParameterValueChanged` back to Godot**. That echo is the trap automation
  must avoid — see [Base values](#base-values-and-the-echo-trap).
- `Engine/src/audio/command_worker.rs` — `CommandWorker::handle` / `apply_locked`, which take the
  state lock briefly.
- `Engine/src/audio/processing.rs` — `process_audio` is the per-buffer entry point.
  `collect_tick_events(start_tick, acc, frame_count, ticks_per_sample, emit_start_tick,
  tick_events)` produces the `(tick, frame_offset)` pairs. `process_audio` returns early when
  `state.get_is_playing()` is false, *after* scheduling live MIDI.
- `Engine/src/audio/mixing.rs` — `mix_and_output`; pass 2 (line 566) applies
  `channel.get_smoothed_gain()` per sample, then pan.
- `Engine/src/audio/types.rs` — `Channel` (`volume_db`, `pan`, `send_channels: Vec<Send>`, private
  `current_gain` / `smoothing_alpha`), `Track` (`id`, `channel_id`, `clip_instances`),
  `Channel::get_gain()` (line 573) and `get_smoothed_gain()` (line 583),
  `Channel::device_at_path_mut()` (line 900), `ParamSetValue` (line 7).
- `Engine/src/audio/devices/mod.rs` — the `AudioDevice` trait, `set_parameter(ParamId, ParamValue)`
  (line 253) documented as "called between audio blocks", `send_midi_event(…, frame_offset)`
  (line 238) which *does* take a frame offset, `ParamInfo` with `is_automation_safe` (line 179),
  `ParamId = u32`, `ParamValue = f32` (always normalized), and `DeviceSleepState::mark_activity()`
  (line 56) which wakes a sleeping device.
- `Engine/src/audio/devices/container.rs` — `DevicePath(pub Vec<usize>)` with `Display` joining
  indices with `/`, and `parse_osc_device_addr`.
- `Engine/src/audio/render_scratch.rs` — `RenderScratch`, all lists preallocated with capacity.
- `Engine/src/audio/engine.rs` line 402 — the callback calls `process_audio` then `mix_and_output`.
- `Engine/src/audio/mod.rs` — the module list a new module must join.
- `Engine/src/audio/devices/sfizz_device.rs` — the only device exposing MIDI CCs as parameters
  (`STANDARD_CC_CONTROLS`, line 23; `GROUP_CC`, line 37). CCs are ordinary `ParamInfo` entries
  with `group == "cc"`, so **automating a CC needs no new engine mechanism**.

Godot:

- `Godot/data/AutomationLane.gd` / `AutomationPoint.gd` — the stubs. `AutomationLane` has
  `parameter_path`, `points`, `visible`, `height`, `color`, `to_json`/`from_json` and an O(n)
  `get_value_at_tick`. `AutomationPoint` has `tick`, `value`, `curve_type`
  (`LINEAR/BEZIER/STEP/EXPONENTIAL`), `tension`. Neither has an id; neither sends OSC.
- `Godot/data/Track.gd` — `automation_lanes: Array` (line 60), written by `to_json` (line 566),
  **not** read by `from_json` (the TODO at line 597). `connect_to_engine()` (line 396) sends
  `/track/{id}/create` then syncs each clip instance; `disconnect_from_engine()` (line 425).
  `JSON_FIELDS` + `JsonFields.write/read`.
- `Godot/data/Channel.gd` — `devices: Array[DeviceInstance]` (line 120), `sync_to_engine()`
  (line 254).
- `Godot/data/DeviceInstance.gd` — `get_parameters()`, `get_parameters_in_group("param"|"cc")`
  (line 213), `has_cc_parameters()` (line 226), `children`, `position`, `name`, `osc_path()`.
- `Godot/data/DeviceParameter.gd` — `id`, `name`, `unit`, `is_automation_safe` (line 33),
  `group` (line 37), `param_type`, `enum_values`.
- `Godot/core/Midi.gd` — note/frequency statics only. **No CC name table exists anywhere.**
- `Godot/arranger/tracklist/TrackItem.gd` / `TrackList.gd` — `TrackItem` is the track header; its
  bottom-4px gutter drives the resize gesture (`_gui_input` line 124, `_input` line 165) writing
  `track.height`. `TrackList` is a `VBoxContainer` of `TrackItem`s ordered by
  `_update_visual_order()` (line 806).
- `Godot/arranger/timeline/Timeline.gd` / `TimelineTrack.gd` — `Timeline` holds
  `timeline_tracks: Array[TimelineTrack]`, its own `_update_visual_order()` (line 227),
  `clip_selection_manager`, `clip_clipboard: ClipSelection`, and the clip
  `copy_selection_to_clipboard` / `cut_…` / `paste_clipboard_at` / `duplicate_selection` family
  (lines 827–950). `TimelineTrack` sizes itself from `track.height` and draws the grid via
  `timeline.grid_helper`.
- `Godot/arranger/timeline/ClipSelectionManager.gd` — the model to mirror: selection, the
  grid-snapped time range (`range_start_tick` / `range_end_tick` / `has_range` /
  `get_full_range`), the paste anchor (`anchor_track`, `anchor_tick`, `get_paste_tick`,
  `get_duplicate_tick`), and the box-select gesture.
- `Godot/components/GridHelper.gd` — `ticks_to_pixels`, `pixels_to_ticks`, `snap_ticks`,
  `get_visible_grid_lines`, `changed`.
- `Godot/history/` — `Command` base (`do`/`undo`/`can_merge`/`merge_with`), `HistoryUtil.execute`
  / `record` / `execute_many` / `record_many` / `record_property`, `MacroCommand`,
  `PropertyCommand`, and `ClipRangeActions` (`overlapping`, `piece`, `clear`, `delete_range`,
  `move_range`) as the range-operation precedent.
- `Godot/settings/Settings.gd` — `_register(Setting.new(key, label, Type, default, CATEGORY, …))`
  and `_RENAMED_KEYS`.
- `Godot/arranger/Arranger.gd` — owns the `VScroll` → `HSplit` → (`TracksPanel/VBox/TrackList`,
  `TimelinePanel/HScroll/Timeline`) layout that makes the two columns scroll as one.

Docs:

- **`AGENTS.md` is stale on one point:** it names `OSC_PROTOCOL.md`, which does not exist. The
  real protocol reference is `.cursor/rules/osc-protocol.mdc` (clip-note messages at lines 96–101).
  This spec updates that file, and fixes the `AGENTS.md` reference as part of the docs task.

## Approach

Lanes are engine state owned by `Track`, evaluated on the audio callback, and authored in Godot
which sends **incremental point edits** over a new `/track/{id}/automation/*` OSC group — the same
granularity as `/clip/{id}/add_note`.

The central design decision is that automation **never writes a base value**. A resolved value is
computed per buffer and applied as an *override* that sits alongside the base, so REQ-004 holds by
construction rather than by remembering to restore. For channel volume and pan the override is a
new `Option<f32>` field on `Channel` consulted by `get_gain()`; for device parameters — which have
no base/override split in the `AudioDevice` trait — the lane captures the device's pre-automation
value the first time it takes over and writes it back when it stops. This is also the seam
Bitwig-style modulation plugs into later: a modulator stack becomes additional contributions
folded in at the same point, and nothing downstream of the resolve changes.

The **rejected alternative** was letting automation call the existing `AudioCommand::SetDeviceParameter`
path from a timer or from Godot. It fails three ways: it mutates the base value (so the project
file would drift every time the song plays), it echoes `PluginParameterValueChanged` to Godot on
every change (so the UI's stored value is clobbered and then saved), and it cannot be
sample-accurate because commands are applied between buffers by another thread. A second rejected
alternative was storing lanes keyed by target in a project-global map: cleaner for buses, but it
divorces a lane from the track whose row shows it, and phase 1 has no bus automation to justify
the indirection.

Evaluation is **cursor-based**, not scanning: each lane keeps an index into its sorted points that
walks forward with the playhead and binary-searches only when the tick jumps backwards (seek,
loop). Evaluation runs every buffer *before* `process_audio`'s `is_playing` early return, so a
seek while stopped resolves and applies (REQ-008) at no extra cost — when the tick has not moved
the value is unchanged and the per-lane dedup skips the apply, which is also what keeps the plugin
IPC ring quiet (REQ-011).

Granularity is **one resolve per buffer** in phase 1. To keep finer granularity reachable without
touching every device later, `AudioDevice` gains a defaulted `set_parameter_at(param_id, value,
frame_offset)` that forwards to `set_parameter`. Phase 1 always passes frame offset 0; the method
exists so a later pass can drive CLAP (whose parameter events are already frame-stamped) and
`polysynth` sample-accurately. Channel volume and pan need no such hook — they already smooth per
sample through `get_smoothed_gain()`.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `Track::automation_lanes: Vec<AutomationLane>` | command thread (mutates under the state lock) | audio callback reads and evaluates under the existing bounded `try_lock` | yes — no allocation on the read path |
| `AutomationLane::points: Vec<AutomationPoint>` | command thread — every insert/remove/reorder happens there | audio callback indexes it, never sorts or grows it | yes; the sorted-by-tick invariant is established off the callback |
| `AutomationLane::cursor: usize` | audio callback (sole writer) | not read elsewhere | yes — a plain index, no allocation |
| `AutomationLane::last_applied: Option<f32>` | audio callback (sole writer) | not read elsewhere | yes — drives REQ-011 dedup |
| `AutomationLane::captured_base: Option<f32>` | audio callback (sole writer) | restored by the callback when the lane stops applying; also cleared by the command thread on lane delete while it holds the lock | yes |
| `Channel::automation_volume` / `automation_pan: Option<f32>` | audio callback — written by the automation pass, consulted by `get_gain()` and pass 2 of `mix_and_output` in the same buffer | nothing outside the callback reads them | yes |
| Lane structural edits (create, delete, bypass, point add/update/remove) | main thread parses OSC → command thread applies | `AudioCommand` variants over the existing crossbeam channel | n/a — off the callback |

Points are sorted on insert by the command thread, which is O(n) memmove per point edit while
holding the state lock. For interactive dragging (one point per message) that is trivially fast.
A paste of many points arrives as many messages and so is many small inserts; see
[Risks](#risks).

## Value model

```
resolved(param, tick) = clamp(lane_value(tick), 0.0, 1.0)   when an enabled, resolvable lane exists
                      = base                                 otherwise
```

Every automated value is **normalized 0.0–1.0**, matching the existing OSC and IPC contract
("Parameters cross the OSC and IPC boundary as normalized 0.0–1.0 values", `AGENTS.md`). Channel
volume normalizes the existing `-60.0 … +12.0 dB` range, and pan the existing `-1.0 … +1.0`; the
conversions live next to the target definition so the Rust and GDScript sides share one
definition of each range. Phase 2 modulation folds in as `base_or_automation + Σ contributions`
at the same clamp — no other code changes shape.

### Base values and the echo trap

`AudioCommand::SetDeviceParameter` sends `EngineStatus::PluginParameterValueChanged` back to
Godot, where `DeviceInstance` stores it in `parameter_values` and `Project` saves it. If the
automation path reused that command, every playback would rewrite the user's saved base value.
The automation apply path therefore calls `device.set_parameter_at()` **directly and sends no
status**. The visible consequence, accepted for phase 1: device knobs do not animate during
playback. Animating them without corrupting the base needs a separate "automated value" status
that the UI renders but never persists — noted in [Follow-ups](#follow-ups), out of scope here.

## Curves

Three shapes, matching REQ-005 and replacing the stub's unused `BEZIER` / `EXPONENTIAL`:

- `Linear` — `lerp(a, b, t)`.
- `Step` — hold `a` until the next point's tick.
- tension — the same linear ramp warped by the point's `tension: f32` in `-1.0 … 1.0`:
  `t' = t.powf(exp2(-tension * TENSION_RANGE))`, so `0.0` is exactly linear (satisfying REQ-005's
  "tension 0.0 evaluates to exactly 0.5 at the midpoint"), positive tension eases in and negative
  eases out. `TENSION_RANGE` is a shared constant so the Rust and GDScript evaluators agree to
  within the 0.001 the requirement allows.

The shape is a property of the **left** point of a segment (the stub already stores `curve_type`
per point, so this keeps its layout). Before the first point and after the last, the nearest
point's value is held (REQ-006).

Phase 1 ships all three shapes in the format, in both evaluators and in the lane row's drawing,
but only `Linear` and `Step` are reachable from the UI — through the point context menu (REQ-019).
No phase-1 control writes `tension`, so every point saved by phase 1 has tension `0.0`. This is
deliberate: it keeps the persisted format and the parity tests final, so adding the deferred
tension handle later is a pure UI change.

## Data and protocol changes

### New OSC messages (Godot → Rust)

Target addressing is one string, so the same spelling serves OSC, the `.sonara` file, and the AI
assistant. It reuses `DevicePath`'s `Display` form (indices joined with `/`):

| Target | String |
|---|---|
| channel volume | `channel/volume` |
| channel pan | `channel/pan` |
| send amount, index 2 | `channel/send/2` |
| device at path `0`, param 7 | `device/0/param/7` |
| nested device at path `0/1`, param 7 | `device/0/1/param/7` |

| Address | Args | Description |
|---|---|---|
| `/track/{id}/automation/create` | `s:lane_id, s:target` | Create a lane on the track for `target` |
| `/track/{id}/automation/{lane_id}/delete` | — | Remove the lane and restore the base value |
| `/track/{id}/automation/{lane_id}/bypass` | `i:0_or_1` | Bypass (restores base) or re-enable |
| `/track/{id}/automation/{lane_id}/add_point` | `i:point_id, i:tick, f:value, s:curve, f:tension` | Add a point; `curve` is `linear` or `step` |
| `/track/{id}/automation/{lane_id}/update_point` | `i:point_id, i:tick, f:value, s:curve, f:tension` | Update a point in place |
| `/track/{id}/automation/{lane_id}/remove_point` | `i:point_id` | Remove one point |
| `/track/{id}/automation/{lane_id}/clear` | — | Remove every point, keep the lane |

`value` is normalized 0.0–1.0. `point_id` is an int allocated by Godot, mirroring `note_id` in
`/clip/{id}/add_note`. No Rust → Godot messages are added: automation deliberately does not echo
(see the echo trap above).

### New `AudioCommand` variants

In `Engine/src/audio/commands.rs`: `CreateAutomationLane { track_id, lane_id, target }`,
`DeleteAutomationLane { track_id, lane_id }`, `SetAutomationLaneBypass { track_id, lane_id,
bypassed }`, `AddAutomationPoint { track_id, lane_id, point }`, `UpdateAutomationPoint { track_id,
lane_id, point }`, `RemoveAutomationPoint { track_id, lane_id, point_id }`,
`ClearAutomationLane { track_id, lane_id }`.

### Godot data model

`AutomationLane.gd` follows the self-syncing pattern from `.cursor/rules/godot-osc.mdc`: setters
mutate, send OSC, then emit. New signals: `point_added(point)`, `point_removed(point_id)`,
`point_changed(point)`, `bypass_changed(bypassed)`, `visibility_changed(visible)`,
`height_changed(height)`, `resolved_changed(resolved)`. `Track` gains
`automation_lane_added(lane)` / `automation_lane_removed(lane)` and syncs lanes inside
`connect_to_engine()` after the clip-instance loop.

### Persisted format

`.sonara` — `Track.to_json()` already emits `automation_lanes`; the entries gain `id`,
`target` (the string above), `bypassed`, and per-point `id`. `Track.from_json()` starts reading
them. `AutomationPoint.from_json` maps the retired `BEZIER` / `EXPONENTIAL` curve names to
`LINEAR` so a hand-edited or stub-era file still loads.

`config.json` — one new setting registered in `Settings.gd`:
`appearance/automation_lane_height` (`Type.INT`, default 40, matching the stub's `height`,
constrained to 20–200), used as the height of a newly created lane. Read through
`Settings.get_value` per `AGENTS.md`. No `_RENAMED_KEYS` entry is needed (new key).

## File-by-file change list

### Engine

| File | Change |
|---|---|
| `Engine/src/audio/automation.rs` | **New.** `AutomationTarget` enum (`ChannelVolume`, `ChannelPan`, `SendAmount{index}`, `DeviceParam{device_path, param_id}`) with `parse` / `Display` for the target string; `CurveKind` (`Linear`, `Step`); `AutomationPoint { id, tick, value, curve, tension }`; `AutomationLane { id, target, points, bypassed, cursor, last_applied, captured_base }` with `value_at(tick)` (cursor-based, no allocation), `insert_point`, `update_point`, `remove_point` keeping the sorted invariant; the `TENSION_RANGE` constant and the dB/pan normalization helpers; `apply_automation(state, tick)` driving every track's lanes. `mod tests` covering REQ-002 through 007, 010 and 011. |
| `Engine/src/audio/mod.rs` | Add `pub mod automation;` and re-export the public types. |
| `Engine/src/audio/types.rs` | `Track` gains `automation_lanes: Vec<AutomationLane>`. `Channel` gains `automation_volume: Option<f32>` and `automation_pan: Option<f32>`. `Channel::get_gain()` prefers `automation_volume` (denormalized to dB) over `volume_db`; `get_pan_coefficients()` prefers `automation_pan`. Base fields are untouched by both. |
| `Engine/src/audio/devices/mod.rs` | Add `fn set_parameter_at(&mut self, param_id, value, _frame_offset: usize)` to `AudioDevice`, defaulting to `self.set_parameter(param_id, value)`, documented as the extension point for sample-accurate automation. No existing device overrides it in phase 1. |
| `Engine/src/audio/processing.rs` | Call `automation::apply_automation(state, state.get_current_tick())` near the top of `process_audio`, **before** the `if !state.get_is_playing() { return; }` early return, so seek-while-stopped applies (REQ-008). |
| `Engine/src/audio/commands.rs` | The seven new `AudioCommand` variants and their apply arms: resolve the track, mutate the lane, and on delete/bypass restore `captured_base` through `set_parameter_at` and clear the channel overrides. Lane apply arms send **no** `EngineStatus`. |
| `Engine/src/audio/mixing.rs` | Pass 2 reads the channel overrides through the existing `get_smoothed_gain()` / pan calls — no structural change, but the automated-gain path needs a regression test that smoothing still runs per sample. |
| `Engine/src/osc/server.rs` | Handle `/track/{id}/automation/...`, parsing the target string via `AutomationTarget::parse` and dispatching the new commands. |

### Godot — data

| File | Change |
|---|---|
| `Godot/data/AutomationLane.gd` | Rewrite. `id`, `target: AutomationTarget`, `points: Array[AutomationPoint]` kept sorted, `bypassed`, `visible`, `height`, `color`, `resolved`. Setters send OSC and emit; `add_point` / `update_point` / `remove_point` / `clear_points` send the incremental messages (REQ-012). Replace the O(n) `get_value_at_tick` with a sorted binary search plus the shared curve evaluator. `to_json` / `from_json` for the new fields. |
| `Godot/data/AutomationPoint.gd` | Add `id`. Reduce `CurveType` to `LINEAR`, `STEP`; `from_json` maps `BEZIER` / `EXPONENTIAL` → `LINEAR`. Keep `tension`. |
| `Godot/data/AutomationTarget.gd` | **New.** Value object: `kind`, `device_path: Array[int]`, `param_id`, `send_index`. `to_string()` / `static parse()` matching the engine spelling, `resolve(channel) -> DeviceInstance` (null for channel targets), `display_name(channel)` producing `Filter / Freq` and `Piano / CC1 Mod Wheel` (REQ-017), and `is_resolvable(channel)` for REQ-024. Shares the curve evaluator and the dB/pan normalization with the engine by definition — the constants are duplicated and locked by the parity test. |
| `Godot/data/Track.gd` | Type `automation_lanes` as `Array[AutomationLane]`; add `add_automation_lane` / `remove_automation_lane` / `get_automation_lane_for(target)` and the two signals; **read lanes in `from_json()`**, replacing the line-597 TODO; sync lanes in `connect_to_engine()` and clear them in `disconnect_from_engine()`. |
| `Godot/core/Midi.gd` | Add the standard MIDI CC name table and `static func cc_name(cc: int) -> String` (standard name, else `CC{n}`) plus `cc_display_name(cc, device_supplied := "")` preferring a device-supplied label (REQ-016). |

### Godot — history

| File | Change |
|---|---|
| `Godot/history/AutomationActions.gd` | **New.** Static helpers mirroring `ClipActions` / `ClipRangeActions`: `create_lane`, `delete_lane`, `add_point`, `delete_points`, `move_points`, `set_curve`, and the range operations `copy_segment`, `clear_range`, `paste_segment` (REQ-021). |
| `Godot/history/commands/AutomationLaneCreateCommand.gd` | **New.** Create/undo a lane. |
| `Godot/history/commands/AutomationLaneDeleteCommand.gd` | **New.** Delete a lane, restoring every point on undo. |
| `Godot/history/commands/AutomationPointsAddCommand.gd` | **New.** Add one or more points as one entry. |
| `Godot/history/commands/AutomationPointsRemoveCommand.gd` | **New.** Remove a set of points, restoring them on undo. |
| `Godot/history/commands/AutomationPointsTransformCommand.gd` | **New.** Move/reshape a set of points; `can_merge` lets a drag coalesce into one entry (REQ-022's single-undo-per-gesture). |

### Godot — arranger UI

| File | Change |
|---|---|
| `Godot/arranger/AutomationRowOrder.gd` | **New.** The single ordering helper both columns call: given the project's tracks, produce the flat row sequence (track row, then its visible lane rows, per track in visual order). Keeps `TrackList._update_visual_order()` and `Timeline._update_visual_order()` from drifting (REQ-013). |
| `Godot/arranger/tracklist/AutomationLaneHeader.gd` + `.tscn` | **New.** The lane header row: `Device / Param` label, bypass toggle, delete button, and the same bottom-gutter resize gesture as `TrackItem` writing `lane.height` (REQ-017, REQ-013). |
| `Godot/arranger/tracklist/AutomationLaneMenu.gd` | **New.** The dropdown: one checkbox per existing lane driving `lane.visible`, and a `+ Add new` entry opening the picker (REQ-014). |
| `Godot/arranger/tracklist/AutomationParameterPicker.gd` | **New.** Builds the parameter list from the track's linked `Channel`: channel volume, pan, one entry per send, then per device in `channel.devices` order its `get_parameters_in_group("param")` and `get_parameters_in_group("cc")` as separate groups, CC entries named through `Midi.cc_display_name`. Skips `is_automation_safe == false` and parameters that already have a lane (REQ-015). |
| `Godot/arranger/tracklist/TrackItem.gd` + `.tscn` | Add the disclosure arrow and the lane-menu button; emit `automation_disclosure_toggled` / `automation_menu_requested` for `TrackList` to act on. Track-level `lanes_expanded` state (REQ-014). |
| `Godot/arranger/tracklist/TrackList.gd` | Instantiate and order `AutomationLaneHeader` rows via `AutomationRowOrder`; react to the new `Track` lane signals. |
| `Godot/arranger/timeline/AutomationLaneRow.gd` + `.tscn` | **New.** The timeline-side lane row: draws the grid the way `TimelineTrack._draw_grid()` does (clipped to the visible scroll range), draws the curve and its points, and owns input — double-click insert, drag to move, ctrl-click and box select (REQ-018, REQ-020). Renders step segments as a hold-then-jump and honours a point's stored `tension` when drawing, even though no phase-1 gesture writes it. |
| `Godot/arranger/timeline/AutomationPointContextMenu.gd` | **New.** Right-click menu on a point or the current selection: set curve shape to Linear or Step, and Delete. Modelled on `ClipContextMenu.gd` (REQ-019). |
| `Godot/arranger/timeline/AutomationPointSelectionManager.gd` | **New.** Modelled on `ClipSelectionManager`: selection set, box-select, the grid-snapped time range, the last-clicked anchor, and the clipboard payload for segment cut/copy/paste/duplicate (REQ-020, REQ-021). |
| `Godot/arranger/timeline/Timeline.gd` | Instantiate and order `AutomationLaneRow`s via `AutomationRowOrder`; route cut/copy/paste/duplicate to the automation selection manager when the automation selection is the active one, otherwise to the existing clip path. |
| `Godot/settings/Settings.gd` | Register `appearance/automation_lane_height` (`Type.INT`, default 40, `CATEGORY_APPEARANCE`), then set `min_val` / `max_val` / `step` on the stored `Setting` the way the virtual-keyboard INT settings do (lines 118–124). |

### Docs

| File | Change |
|---|---|
| `.cursor/rules/osc-protocol.mdc` | Document the seven `/track/{id}/automation/*` messages and the target-string grammar. |
| `AGENTS.md` | Fix the stale `OSC_PROTOCOL.md` reference to `.cursor/rules/osc-protocol.mdc`, and add automation to the "Channels and devices" notes. |
| `.cursor/rules/godot-architecture.mdc` | Add the automation row/lane structure alongside the existing "Lane layout and note maps" section. |
| `TODO.md` | Mark the phase-1 half of the "Modulation" item (line 176–177). |

## Migration and compatibility

- **Projects saved before this change** carry either no `automation_lanes` key or the stub's
  point shape (no `id`, possibly `BEZIER` / `EXPONENTIAL`). `Track.from_json()` treats a missing
  key as zero lanes; a lane without an `id` is assigned a fresh one; a point without an `id` is
  assigned one by index; retired curve names load as `LINEAR`. Nothing errors (REQ-023).
- **A lane whose `target` no longer resolves** — channel re-routed or device removed — is kept in
  the project, marked `resolved = false`, never synced to the engine, and rendered as unresolved
  (REQ-024). The engine independently drops a lane whose target cannot be resolved at apply time,
  restoring `captured_base` first, and logs it once rather than per buffer.
- **Version skew:** an older engine ignores unknown OSC addresses, so a newer Godot loses
  automation but nothing breaks. A newer engine never requires `/automation/*` to arrive.
- **The stub's `color` field** is retained and used for the curve stroke, so nothing is dropped.

## Test plan

- **Unit (`Engine/src/audio/automation.rs`, `mod tests`):**
  - `cargo test automation_target_roundtrip` — every target string parses and re-prints,
    including nested device paths (REQ-002).
  - `cargo test automation_resolves_each_target` — the four target kinds each move the right
    live value on a constructed `EngineState` (REQ-002).
  - `cargo test automation_overrides_base_but_preserves_it` — resolved gain follows the ramp while
    `volume_db` is unchanged; bypass restores it (REQ-003, REQ-004, REQ-009).
  - `cargo test automation_curve_shapes` — five positions across linear, step and tension, with
    tension `0.0` exactly linear (REQ-005).
  - `cargo test automation_holds_outside_points` and `automation_empty_lane_is_inert`
    (REQ-006, REQ-007).
  - `cargo test automation_cursor_is_bounded` — a 10,000-point lane walked sample-by-sample
    advances the cursor monotonically with a bounded per-step comparison count, and a backwards
    seek re-seeks in `O(log n)` (REQ-010).
  - `cargo test automation_dedups_unchanged_values` — a constant lane over 100 buffers emits one
    apply (REQ-011).
- **Godot (`Godot/tests/`, extending `TestBase`):**
  - `godot --headless --path Godot -s tests/test_automation_model.gd -- --test` — lane and point
    JSON round-trip, old-format and missing-key loading, bypass/visibility persistence, and an
    unresolvable target surviving a reload (REQ-001, REQ-009, REQ-023, REQ-024).
  - `… -s tests/test_automation_curve_parity.gd -- --test` — the GDScript evaluator matches the
    expected values from the Rust curve tests to within 0.001 (REQ-005).
  - `… -s tests/test_automation_range_ops.gd -- --test` — copy a 1-bar segment, paste at bar 3,
    assert shifted ticks and preserved curves; undo returns the prior state (REQ-021, REQ-022).
  - `… -s tests/test_midi_cc_names.gd -- --test` — CC 1/7/10/11/64/74 resolve to standard names,
    an unassigned number falls back to `CC{n}`, and no number 0–127 returns empty (REQ-016).
  - `Godot/tests/run_all.sh` to confirm nothing else regressed.
- **Live (engine + Godot running):** these cover every UI requirement, which headless cannot.
  - Start `Engine/run_release.sh`, then `godot --path Godot`. Add a lane on an instrument track's
    channel volume; draw a ramp; play and hear it; confirm `Engine/logs/last_info.log` shows the
    lane applying and **no** per-buffer log spam (REQ-003, REQ-010).
  - With the transport stopped, `oscsend localhost 7000 /transport/seek i 9600`, then play a note
    and confirm the level matches the lane at that tick (REQ-008).
  - Drag one point and confirm exactly one `update_point` in the engine log (REQ-012).
  - Show two lanes, resize one, scroll: header and timeline row stay aligned and equal in height
    (REQ-013).
  - Disclosure arrow, lane menu checkboxes, `+ Add new` on a channel with two devices — confirm
    device order and that CC entries appear as their own group (REQ-014, REQ-015).
  - Ctrl-click multi-drag, box select, the point context menu's Linear/Step toggle, and
    cut/copy/paste/duplicate against a time range (REQ-019 – REQ-021).
  - Drag five selected points, undo once, all five return (REQ-022).
  - Delete a device that has a lane: the lane stays marked unresolved, the parameter returns to
    base, and `Engine/logs/last_warn.log` has one message, not a flood (REQ-024).
  - With a CLAP plugin loaded, automate one of its parameters and watch `/engine/load` while its
    GUI is open (REQ-011 and the IPC risk below).
- **Gates:** `cargo test` and `cargo fmt` for the engine; `Godot/tests/run_all.sh` for GDScript.

## Risks

| Risk | Mitigation |
|---|---|
| The 5 ms fader smoothing (`smoothing_alpha`, `types.rs:583`) lags a steep volume ramp, smearing fast fades and making gate-style step automation audibly soft. | Measure with a step lane on channel volume. If the lag is audible, shorten the constant while `automation_volume` is `Some`, or ramp `current_gain` toward the resolved value across the buffer. Do not remove the smoothing — it is what prevents zipper noise. |
| Plugin parameter automation floods the IPC ring: one message per automated param per buffer is a few hundred per second each. | REQ-011's dedup is the primary defence. Verify ring capacity and backpressure in `Engine/src/audio/ipc/` before shipping, and confirm with a CLAP plugin under a moving lane plus an open GUI. |
| Automating a parameter on a **sleeping** device (`DeviceSleepState`, ~3 s of silence) either has no effect or wakes it every buffer, defeating the optimization. | Call `mark_activity()` only when the resolved value actually changes — the dedup already gives exactly that signal. Add a live check that a sleeping delay wakes on a moving lane but stays asleep under a constant one. |
| Two `_update_visual_order()` implementations (`TrackList.gd:806`, `Timeline.gd:227`) must agree row-for-row or the columns visibly desync while scrolling. | `AutomationRowOrder.gd` is the single source of ordering; both call it and neither computes order itself. Scroll-alignment is an explicit live check. |
| Point inserts are O(n) memmove under the state lock; a large paste arrives as many messages. | Fine for interactive editing. If a paste of hundreds of points stutters, add a batched `add_points` message rather than making the callback sort. |
| The engine's and Godot's curve evaluators drift, so the drawn curve stops matching what is heard. | `test_automation_curve_parity.gd` asserts against the same expected values as the Rust curve test; `TENSION_RANGE` is a named constant on both sides, changed only in tandem. |
| `AutomationLaneRow.gd` absorbs curve drawing, input and hit-testing, and could pass the 600-line guideline in `.cursor/rules/godot-code-style.mdc`. | Less pressing now that the tension handle and draw tool are deferred. Selection and clipboard already live in `AutomationPointSelectionManager`; if the row still grows too large, split drawing into a sibling the way `MidiclipRenderer.gd` is split from `TimelineClip.gd`. |

## Follow-ups

Deliberately not in this spec, recorded so the design is not re-litigated later:

- **The mid-segment tension handle.** `tension` is already in the format, in both evaluators and
  in the lane row's drawing, so phase 2 adds the hover-and-drag gesture and nothing else. Until
  then every stored point has tension `0.0`.
- **The freehand draw tool.** Needs a tool-mode toggle in `Arranger.gd` (transient UI state, not a
  setting) plus a stroke handler on `AutomationLaneRow`; no data or protocol change.
- **Animating knobs during playback** needs a non-persisting "automated value" status; the echo
  trap above is why it cannot reuse `PluginParameterValueChanged`.
- **Sample-accurate device automation** is what `set_parameter_at`'s frame offset exists for.
- **Modulators** fold in at the single clamp in the value model.
- **Bus and master automation** needs lane ownership independent of tracks.
- **Widening exposed MIDI CCs** is a device-side change; `Midi.cc_name` makes it cheap.

## Open questions

None.
