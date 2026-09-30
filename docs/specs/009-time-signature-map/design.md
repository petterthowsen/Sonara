# Time Signature Changes — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/data/Project.gd` — `time_numerator` / `time_denominator` (base signature), `ruler_lanes`,
  `tempo_map` with `_sync_tempo_map_to_engine()` (sends `/transport/tempo_map` on connect and on
  every `changed`), `to_json` / `from_json` (`ruler_lanes`, `tempo_map`).
- `Godot/data/TempoMap.gd` — the model to mirror: `changed` signal, `snapshot()` / `restore()`,
  `to_json()` / `from_json()`.
- `Godot/history/commands/TempoMapStateCommand.gd` — before/after snapshot command, recorded with
  `HistoryUtil.record()` after the edit is applied.
- `Godot/components/GridHelper.gd` — the grid. Holds base `time_numerator` / `time_denominator`,
  `tempo_map`, `get_visible_grid_lines()`, `snap_ticks()`, `get_snap_interval()`,
  `get_subdivision_interval()`, static `bar_ticks()` / `bbt_of()`. Shared by all arranger views.
- `Godot/components/Ruler.gd` — draws the bar/beat ruler from `get_visible_grid_lines()`.
  `Godot/arranger/timeline/TimelineTrack.gd` and `AutomationLaneRow.gd` draw grid from the same call.
- `Godot/arranger/ruler/MarkerTrack.gd`, `MarkerItem.gd`, `TempoTrack.gd` — lane UX to imitate.
- `Godot/arranger/Arranger.gd` + `Arranger.tscn` — `markers_toggle` / `tempo_toggle`, `tempo_track`,
  `_apply_ruler_row_visibility()`, ruler-lane restore near line 738, bind/unbind of lane nodes.
  Header order today: `RealTimeRuler`, `MarkerTrack`, `Ruler`, `TempoTrack`.
- `Godot/editor/Editor.gd` — `set_time_signature()`, `_apply_time_signature_silent()`,
  `_update_transport_ui()` (BBT readout uses `GridHelper.bbt_of` with the base signature).
- `Engine/src/audio/transport.rs` — `Transport::at(map, settings, tick_pos, sample_rate, playing)`
  builds `bar_number`, `bar_start_beats`, `time_sig_num/den` from the static signature. Called once
  per block from `audio/processing.rs` (`Transport::at(&state.tempo_map, …)`).
- `Engine/src/audio/tempo_map.rs`, `commands.rs` (`AudioCommand::SetTempoMap`, `EngineState.tempo_map`),
  `command_worker.rs` (`set_tempo_map`, `clear_project`), `osc/server.rs` (`["transport", "tempo_map"]`,
  `parse_tempo_map_args` and its tests) — the pattern to copy for the new map.
- `docs/subsystems/osc-protocol.md` — OSC reference.

## Approach

**Model.** A `TimeSignatureMap` (Godot) and `TimeSignatureMap` (engine) hold *signature changes*
`(bar, numerator, denominator)`, bar 1-based, sorted by bar, strictly increasing, all ≥ 2. The base
signature is not in the map: it stays `Project.time_numerator/denominator` and is passed to the map's
lookups, as `TempoMap` takes the static tempo. Storing bars (not ticks) makes REQ-009 free: editing the
base moves later changes' ticks but not their bars. Ticks are derived by walking the changes: the tick of
bar `b` is the sum of the bar lengths before it. Both sides use the same walk.

**Rejected: storing each change by tick.** Ticks are what clips and tempo points use, but a change
must sit on a bar line, and a base edit would leave it off the line; keeping ticks valid would mean
rewriting the map on every base edit and undo of it.

**Grid.** `GridHelper` gets a `time_signature_map` (connected like `tempo_map`, so a change emits
`changed`). The map exposes a cached list of segments `{bar, tick, num, den, bar_ticks, beat_ticks}`
(rebuilt when the map, the base signature or PPQ changes). `get_visible_grid_lines()` walks the segments
overlapping the visible range and emits bar lines with their real bar numbers, beat and subdivision lines
per segment. Snapping is segment-relative: `snap_ticks(t)` uses the interval of the segment containing
`t`, counted from the segment's start tick and clamped below the next segment's start, so a snap never
lands past a bar line that changes meter. With an empty map there is one segment starting at tick 0, so
every result is identical to today (REQ-012).

`get_ticks_per_bar()` / `get_ticks_per_beat()` stay base-signature values: the clip editor, marker
sizing and AI clip text keep them (REQ-013). New tick-aware variants `get_ticks_per_bar_at(tick)` /
`get_ticks_per_beat_at(tick)` serve the arranger. Playhead BBT uses `TimeSignatureMap.bbt_at_tick()`.

**Lane.** `TimeSignatureTrack` (new, `Control`, same setup as `MarkerTrack`: 24 px, clip, own popup
menu, double-click detection, shared `GridHelper`) draws one flag item per change via
`TimeSignatureItem` (new, `Control`): a colored tab at the bar line with the `N/D` label. It handles its
own input like `MarkerItem` (drag, double-click edit, right-click menu). Editing shows a `LineEdit` over the item; Enter
applies through `TimeSignatureMap.parse()`, Escape or invalid text keeps the old value.
Point items (not ranges) because a change has no end: it holds until the next one.

**Edits and undo.** All edits (add, edit value, move, delete) go through model methods on
`TimeSignatureMap` and are recorded as `TimeSignatureMapStateCommand` (before/after `snapshot()`), the
same shape as `TempoMapStateCommand`. Drags record one command on release, as `TempoTrack` does.

**Add refinements.** Bar 1 cannot hold a change (it would duplicate the base), so adding at bar 1 uses
bar 2; adding on a bar that already has a change edits that change instead.

**Engine.** `TimeSignatureMap` holds `Vec<(u32, u16, u16)>` sorted by bar. `Transport::at` gets a
`&TimeSignatureMap` parameter and walks the changes to find the segment containing `tick_pos`
(number of changes is tiny, no allocation, no cache), giving `bar_number` (0-based as today),
`bar_start_beats` and `time_sig_num/den`. Building and swapping happens on the command thread with the
lock released, like `set_tempo_map`.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `EngineState.time_signature_map` | command thread writes (swap under the lock, old value dropped after unlock) | audio callback reads in `Transport::at`, once per block, inside the existing state `try_lock` | yes — plain iteration over a small `Vec`, no allocation |
| Base signature (`ProjectSettings`) | command thread (`SetTimeSignature`) | audio callback, same lock | unchanged |

## Data and protocol changes

- **OSC** `/transport/time_signature_map` — args `i:bar, i:numerator, i:denominator, …` (triples),
  Godot → engine. Replaces the whole map. No args clears it. Malformed or out-of-range triples are
  dropped with a warning, and the rest applied. Values outside numerator 1–32, denominator 1/2/4/8/16/32,
  bar ≥ 2 are dropped. Duplicate bars keep the last one.
  Places: handler in `Engine/src/osc/server.rs` (with `parse_time_signature_map_args`),
  `AudioCommand::SetTimeSignatureMap` in `Engine/src/audio/commands.rs` (added to the slow-command list
  next to `SetTempoMap`, dispatched in `command_worker.rs`), and `docs/subsystems/osc-protocol.md`.
- **Godot sync:** `Project._sync_time_signature_map_to_engine()`, called from `connect_to_engine()` and
  on the map's `changed`, mirrors `_sync_tempo_map_to_engine()`. The base signature keeps using
  `/transport/time_signature`.
- **Plugin subprocess IPC:** no change, `tsig_num/tsig_den` already travel per block.
- **Persisted:** `.sonara` gains `"time_signature_map": [{"bar": 5, "numerator": 7, "denominator": 8}, …]`
  and `ruler_lanes["time_signature"]`. Missing keys load as empty map / lane hidden (the
  `from_json` loop over `ruler_lanes` keeps defaults for absent lanes).
- **Text format** (`TimeSignatureMap.parse(text) -> Vector2i`, invalid → `Vector2i.ZERO`): trims whitespace,
  `N/D`, integers only, N 1–32, D in {1, 2, 4, 8, 16, 32}. The top-bar field keeps its own parser.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/data/TimeSignatureMap.gd` (new) | Model: `changes`, `add_change` / `update_change` / `remove_change`, `snapshot` / `restore`, `to_json` / `from_json`, static `parse`, `segments(base_num, base_den, ppq)` (cached), `tick_of_bar`, `bar_at_tick`, `bbt_at_tick`, `signature_at_tick`. `changed` signal. |
| `Godot/history/commands/TimeSignatureMapStateCommand.gd` (new) | Before/after snapshot command. |
| `Godot/data/Project.gd` | `time_signature_map` var (with setter wiring like `tempo_map`), `ruler_lanes["time_signature"] = false`, `_sync_time_signature_map_to_engine()`, `to_json` / `from_json`. |
| `Godot/components/GridHelper.gd` | `time_signature_map` var; segment-based `get_visible_grid_lines()`, `snap_ticks()` / `floor_ticks()`, `get_ticks_per_bar_at` / `get_ticks_per_beat_at`, `ticks_to_bbt()` via the map. `from_project` passes the map. |
| `Godot/arranger/Arranger.gd` | Bind the map to the grid on project load; new `time_signature_toggle`, `time_signature_track`; `_apply_ruler_row_visibility()` and lane restore include it; bind/unbind. |
| `Godot/arranger/Arranger.tscn` | `TimeSignatureTrack` node between `Ruler` and `TempoTrack`; `TimeSignatureToggle` button beside the other ruler toggles. |
| `Godot/arranger/ruler/TimeSignatureTrack.gd` (new) | Lane: draw, add via double-click / menu, click routing, undo recording, Ctrl-click range gesture signals like `MarkerTrack`. |
| `Godot/arranger/ruler/TimeSignatureItem.gd` (new) | One flag: layout from `grid_helper`, drag along bar lines within neighbours, inline `LineEdit`, right-click menu (Edit, Delete). |
| `Godot/editor/Editor.gd` | `_update_transport_ui()` BBT via the map. |
| `Godot/arranger/timeline/Timeline.gd`, `Godot/components/TimelineScrollBar.gd` | Leave as is (minimum-length heuristics on the base signature). |
| `Engine/src/audio/time_signature_map.rs` (new) | Engine map: `from_changes` (sort, dedupe, validate), `segment_at(tick, base_num, base_den, ppq)`. Unit tests. |
| `Engine/src/audio/mod.rs` | `pub mod time_signature_map;` |
| `Engine/src/audio/transport.rs` | `Transport::at` takes `&TimeSignatureMap`; per-segment bar maths; update tests. |
| `Engine/src/audio/processing.rs` | Pass `&state.time_signature_map` in the `Transport::at` call. |
| `Engine/src/audio/commands.rs` | `AudioCommand::SetTimeSignatureMap(Vec<(u32, u16, u16)>)`, `EngineState.time_signature_map`, slow-command list entry. |
| `Engine/src/audio/command_worker.rs` | `set_time_signature_map`, dispatch; `clear_project` takes it. |
| `Engine/src/osc/server.rs` | Handler `["transport", "time_signature_map"]`, `parse_time_signature_map_args` + tests. |
| `docs/subsystems/osc-protocol.md` | Document the message. |
| `docs/subsystems/godot-architecture.md` | One line on the lane and `TimeSignatureMap`. |
| `STATUS.md`, `TODO.md` | Track the feature. |

## Migration and compatibility

Old `.sonara` files have no `time_signature_map`: they load with an empty map and the lane hidden,
and behave exactly as before. Files saved by this version and opened by an older one lose the
changes (unknown keys are ignored). An engine without the new message ignores it, so playback keeps
the base signature. Godot and engine ship together, so there is no other skew to handle.

## Test plan

- **Unit (Rust):** `cargo test time_signature` in `time_signature_map.rs` — segment ticks and bar
  numbers; `cargo test transport` — snapshot at 7679 / 7680 with change `(3, 7, 8)`, existing tests unchanged;
  `cargo test parse_time_signature_map_args` in `server.rs` — valid triples, out-of-range dropped, duplicate bars,
  empty clears.
- **Godot:** new `Godot/tests/test_time_signature_map.gd` (parser table, segment ticks, bbt, move between
  neighbours, base edit keeps bars, snapshot/restore undo, JSON round trip, grid lines and snapping in a
  4/4 → 7/8 map); extend `Godot/tests/test_ruler_lanes_persist.gd` with `time_signature`; run
  `Godot/tests/run_all.sh` for the empty-map regression.
- **Live:** start the engine and Godot, toggle the lane, add 7/8 at bar 3, check bar numbers and beat lines,
  add/edit/drag/delete/undo; play across the change with a tempo-synced CLAP plugin and check its bar
  position; save, reopen; check `Engine/logs/last_info.log` for the "Time signature map set" line.

## Risks

| Risk | Mitigation |
|---|---|
| Grid code paths that assume constant bar length (`TimelineTrack`, `AutomationLaneRow`, `GridRenderer`) break | They all call `get_visible_grid_lines()`, which returns real bar numbers; check them live with a mixed map. |
| Snap and ruler lines disagree at a change | Both use the same segment list; unit test on segment boundaries. |
| Time ruler (`RealTimeRuler`) unaffected | It uses ticks → seconds only; the tempo map keeps its tick meaning. |

## Open questions

- [ ] None.
