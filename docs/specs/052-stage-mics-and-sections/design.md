# Stage Mic Setups and Sections — Design

Implements [requirements.md](./requirements.md). Builds on spec 051 and ADR 0024.

## Context

- `Engine/src/audio/stage/mod.rs`: `RoomModel` (a `Copy` room handed to every source under the
  lock), `StageParams`, `OutputMode`, `R_REF`, `SPEED_OF_SOUND`.
- `Engine/src/audio/stage/panner.rs`: the `Panner` trait and `StereoPanner` (constant power from
  the azimuth, returns a "rear" amount for the HF cut). This is today's whole listener.
- `Engine/src/audio/stage/image_source.rs`: `taps(room, point, listener, distance_delay)` gives a
  `TapSet` (direct, 6 first-order, 18 second-order `Tap`s: `delay_s`, `gain`, `dir` in the
  listener frame, `damping`, `surface`). `direct_tap()` is the direct path alone. The receiver
  position is already a parameter, so it can be a capsule position.
- `Engine/src/audio/stage/source.rs`: `StageSource`. Two history `Line`s, one `read()` per tap
  per block into `scratch.tmp`, then `pan_add()` with a `TapRamp { delay, left, right }` that ramps
  from last block's value. `Bank` holds one room's tap state and damping filters; a room change
  clones it into `Fade` and crossfades the reflections over 50 ms (`ROOM_FADE_S`). The direct path
  (`render_direct`, `direct_taps`, `direct_lp`) is outside the bank and just ramps.
  Tests: `room_change_crossfades`, `render_does_not_allocate`, `impulse_arrives_with_distance_delay_only_when_on`.
- `Engine/src/audio/stage/tail.rs`: `StageTail::configure(&RoomModel)` reads dimensions, decay,
  tail level, damping and output mode only.
- `Engine/src/audio/commands/stage.rs`: `set_stage()` hands the clamped room to every source
  (`StageSource::set_room`) and tail.
- `Engine/src/osc/routes/stage.rs`: `parse_stage_set()`, `STAGE_SET_ARGS = 22`, `a.exactly(..)`.
  Route tests in `Engine/src/osc/routes/mod.rs` (`stage_set_args()`).
- `Godot/data/Stage.gd` (`VirtualStage`): room values, `osc_args()`, `to_json()` / `_read()`,
  `_edited()` (marks a preset modified, sends, emits `changed`).
- `Godot/data/Channel.gd`: `stage_*` fields, `get_stage_state()` / `set_stage_state()` (undo
  snapshots *and* the saved `stage` block in `to_json()` / `from_json()`), `_stage_edited()`.
- `Godot/stage/StageEdit.gd`: pure edit operations on stage-state dictionaries: `ends`,
  `half_extent`, `clamp_state`, `move_by`, `drag_end` (with `snap_deg`), `set_size`, `set_rotation`.
- `Godot/stage/StageCanvas.gd`: drawing (`_draw_source`: a line or a dot), `hit_test`, `_handles`,
  `_drag_to(pos, snap)` (Shift → `ROTATION_SNAP_DEG`), `_release` records `PropertyCommand`s.
- `Godot/stage/StageView.gd` + `StageView.tscn`: room panel (`%OutputOption`, …), source panel
  (`%SourceSize`, `%SourceRotation`, `%SumOption`, `%HasRoom`), `_edit_room()` and
  `_edit_source_states()` for undo.
- `Sonara.get_config` / `set_config`: UI state (pattern used by `ClipEditor.gd`'s audition toggle).

## Approach

**Engine: a mic setup is a set of capsules.** A new `mic.rs` describes each setup as up to three
capsules. Each one has an offset from the Listener (listener frame), an aim direction, a
first-order polar pattern `a + (1 − a)·cos θ` (omni a = 1, cardioid 0.5, figure-8 0) and an output
mix (`[left, right]`). Mid/Side is mid → (1, 1), side → (1, −1). For Decca, C → (0.707, 0.707). Each setup
gets a normalization gain, computed when the array is built, that gives a source straight ahead at
`R_REF` (5 m) `L² + R² = 1`, the same as `StereoPanner`. Coincident capsules sum coherently and
spaced capsules sum in power. Each capsule's contribution includes the distance law from *its own*
position (`R_REF / r_capsule`), so the Decca centre mic's 1.5 m head start is folded into the
normalization. That gives REQ-004 at the reference distance. At other distances the setups differ
slightly, as real arrays do. (Revised during T-004: the first version ignored distance and left
Decca 2.2 dB hot.)

- **Pan** keeps `StereoPanner` untouched, so REQ-007 holds by construction.
- **Coincident** setups (XY, Blumlein, M/S) have every capsule at the Listener, so a tap is still
  one read. The capsule gains are summed into the existing L/R gain pair. They cost the same as Pan.
- **Spaced** setups (AB, ORTF, Decca) render each tap once per capsule. `taps()` is called with
  the capsule's position as the receiver, so each capsule gets its own path length, direction and
  polar gain. With Distance delay off, every delay is measured from the point's *earliest* capsule
  arrival (not from the Listener), so the stage adds no fixed latency. With it on, they are absolute
  flight times. Reads per tap = capsule count (2 or 3), within the 3× budget.

`TapRamp` becomes per-capsule: `[CapsuleRamp; MAX_CAPSULES]` where `CapsuleRamp` is today's
`{delay, left, right}`, plus the number in use. Every loop runs `0..reads`. All arrays stay fixed
size, so nothing new is allocated.

The mic setup is a field of `RoomModel` (`mic: MicSetup`). It travels in `/stage/set`, it is
`Copy`, and a change already goes through `set_room` → `Fade`, which crossfades the reflections.
The direct sound gets the same crossfade: its state (`direct_taps`, `direct_valid`, `direct_lp`)
moves into `Bank`, and while a `Fade` is running and the old bank's mic differs, the direct sound
renders from both banks with the fade's sin/cos gains. When the mic is unchanged the direct path
keeps ramping as today, so listener moves don't fade. `StageTail` never reads `mic` (REQ-006).

Rejected: emulating spaced arrays after panning (a per-output delay or a decorrelation filter on
the stereo result). It can't give each reflection its own time difference, which is what makes AB
and the Decca tree sound wide, and it would put two different "time difference" models in the
stage. Also rejected: replacing the `Panner` trait with the mic array. The trait stays the layout
seam for future surround and binaural output. The mic array only sits beside it for stereo.

**Godot: rectangles, sections, snapping, all in `StageEdit`.** The source's state dictionary
gains `depth`, `display` and `players`. Since `get_stage_state()` is both the undo snapshot and
the saved block, persistence and undo come for free (REQ-020). `/channel/{id}/stage` does not
change, because depth is visual only. `StageEdit` gets the geometry (`corners`), the depth drag,
the section layout, the section minimum and snapping. All of them are pure functions so the model
tests cover them, as the memory note on shallow UI tests asks. `StageCanvas` only draws them and
routes drags. Snapping is on by default. The canvas passes a step (1 m / 0.1 m with Shift; 15° / 1°)
into the edit functions, or 0 when the Snap toggle is off.

Section layout: among column counts `c` in 1..n with `r = ceil(n / c)`, the canvas keeps those
whose grid fits the footprint (`c·1.0 ≤ size`, `r·1.2 ≤ depth`). It picks the one with the fewest
empty seats, and on a tie the cell shape closest to the footprint's. If none fits (only in a room
too small, or under automation, REQ-019), it takes the `c` whose cell shape is closest to the
footprint and draws players closer together. The last row is centred. The 12-player 8 × 2.4 m
example gives 6 × 2.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `RoomModel::mic: MicSetup` | command thread (`set_stage`) | copied into every `StageSource` under the lock, read by the stage pass | yes, `Copy` |
| `Bank::mic: MicArray` (capsules, normalization) | built in `Bank::new` / `set_room` from `room.mic` (a `const`-style constructor, no allocation) | the stage pass, inside the source | yes, fixed arrays |
| `Bank::{first, second}: [TapRamp]` now per capsule (`[CapsuleRamp; 3]`) | the source (stage pass) | only the source | yes, fixed size, part of the bank allocated in `StageSource::new` |
| `Bank::{direct_taps, direct_valid, direct_lp}` (moved from `StageSource`) | the source | only the source; cloned into `Fade` under the lock by `set_room` (a `Copy`/`Clone` of fixed arrays, as today) | yes |
| `Scratch::{direct_l, direct_r}` (new, `max_frames`) | allocated in `StageSource::new` | the stage pass, for the crossfaded direct render | yes |
| `Line` history, grown by `MAX_ARRAY_SPAN_M / SPEED_OF_SOUND` | allocated in `StageSource::new` | the stage pass | yes |

The UI-only values (depth, display, players, snap) never reach the engine.

## Data and protocol changes

**OSC `/stage/set`** (Godot → engine): append `i:mic` as the 23rd argument:
0 Pan, 1 XY, 2 Blumlein, 3 M/S, 4 AB, 5 ORTF, 6 Decca tree; other values → Pan. The route accepts
22 arguments (mic = Pan, so an old sender keeps working) or 23. `STAGE_SET_ARGS` becomes the 23
form plus a `STAGE_SET_ARGS_V1 = 22` accepted alongside it. Changes: `osc/routes/stage.rs`,
`audio/stage/mod.rs` (`RoomModel`), `docs/subsystems/osc-protocol.md`. No status message changes.

**Godot models**
- `VirtualStage`: `enum MicSetup { PAN, XY, BLUMLEIN, MID_SIDE, AB, ORTF, DECCA }` (the OSC values),
  `var mic_setup := MicSetup.PAN`, `set_mic_setup(mode)` (clamps, `_edited()`), and `const
  MIC_IDS := ["pan", "xy", "blumlein", "ms", "ab", "ortf", "decca"]` and `MIC_LABELS`.
  `osc_args()` appends `int(mic_setup)` after the materials. `to_json()` writes `"mic": <id>`;
  `_read()` reads it, falling back to Pan for missing or unknown ids. `apply_preset()` leaves the
  mic alone (like Distance delay and output mode). Changes go through `_edited()`, so a preset
  room is marked modified (REQ-008).
- `Channel`: `stage_depth: float = VirtualStage.DEFAULT_SOURCE_DEPTH` (2.0),
  `enum StageDisplay { BLOCK, SECTION }`, `stage_display := StageDisplay.BLOCK`,
  `stage_players: int = VirtualStage.DEFAULT_PLAYERS` (8). `get_stage_state()` adds `depth`,
  `display`, `players`; `set_stage_state()` reads them, clamping depth ≥ 0 and players to 1–64.
  `place_in_stage_from_pan()` sets depth 2 m. A missing key keeps the field default, so older
  projects get 2 m and Block (REQ-013). `_stage_osc_args()` / `/channel/{id}/stage` are unchanged.
- `VirtualStage` constants: `DEFAULT_SOURCE_DEPTH := 2.0`, `PLAYER_FOOTPRINT := Vector2(1.0, 1.2)`,
  `MIN_PLAYERS := 1`, `MAX_PLAYERS := 64`, `DEFAULT_PLAYERS := 8`.

**Persisted**: project `stage.mic` (string id); channel `stage.depth`, `stage.display`
(`"block"` / `"section"`), `stage.players`.

**UI config** (not a user setting, so not `Settings.gd`): `Sonara.get_config("stage_view/snap", true)`.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/stage/mic.rs` (new) | `MicSetup` (`From<i32>`), `Capsule`, `MicArray::for_setup()`, `MAX_CAPSULES = 3`, `MAX_ARRAY_SPAN_M`, `is_spaced()`, `reads()`, `coincident_gains(dir, &mut [f32; 2]) -> rear` (Pan delegates to `StereoPanner`), `capsule_gains(c, dir) -> [f32; 2]`, `capsule_position(c, listener) -> Vec3` (listener → room frame: x, −y, z), normalization. Unit tests |
| `Engine/src/audio/stage/mod.rs` | `pub mod mic;`, `RoomModel::mic` (default Pan), module doc line |
| `Engine/src/audio/stage/source.rs` | `CapsuleRamp`, per-capsule `TapRamp`, `pan_add` per capsule; `Bank` gets `mic` and the direct state; `tap_ramp` / `render_bank` / `render_direct` loop over capsules (spaced: per-capsule `taps()` with earliest-arrival referencing); direct crossfade on a mic change through `Fade`; `Scratch::{direct_l, direct_r}`; history + array span. Tests |
| `Engine/src/audio/stage/tail.rs` | Test only: `configure` ignores the mic |
| `Engine/src/osc/routes/stage.rs` | Accept 22 or 23 args; read `mic` |
| `Engine/src/osc/routes/mod.rs` | Route tests: 23-arg form sets the mic, 22-arg form gives Pan, 24 is refused |
| `Godot/data/Stage.gd` | `MicSetup`, `mic_setup`, `set_mic_setup`, ids/labels, `osc_args`, JSON, new constants |
| `Godot/data/Channel.gd` | `StageDisplay`, `stage_depth`, `stage_display`, `stage_players`; state get/set; default in `place_in_stage_from_pan` |
| `Godot/stage/StageEdit.gd` | `half_extent` takes depth (rectangle's bounding box) so `clamp_state` / `move_by` / `set_size` / `set_rotation` keep the whole rectangle inside; `corners(state)`; `snap_point`, `snap_length`; `move_by(..., anchor, step)` snaps the anchor source's centre and shifts the group by the same delta; `drag_end(..., snap_deg, length_step)` snaps size; `drag_edge(room, state, point, step)` (depth, symmetric); `set_depth`, `set_display`, `set_players`; `section_grid(n, size, depth) -> Vector2i`, `player_positions(state) -> Array[Vector2]`, `section_fits`, `fit_section(room, state)` (grow depth, then size, clamp to room); every size/depth edit stops at the section minimum |
| `Godot/stage/StageCanvas.gd` | Draw a filled rotated rectangle (Block) or outline + player icons (Section: head circle + shoulder arc at each `player_positions` point, icon scaled to the spacing); dots unchanged at size 0; hit-test inside the rectangle; edge handles (front/back midpoints) and `Drag.EDGE`; `snap_enabled` from config; steps from Shift; tooltip text |
| `Godot/stage/StageView.gd`, `Godot/stage/StageView.tscn` | Snap toggle (writes the config); room panel Mic option; source panel Depth spin, Display option, Players spin (shown for Section); edits through `_edit_source_states` / `_edit_room` |
| `Godot/tests/test_stage_edit.gd` | Snap, corners, depth drag, section grid, section minimum, fit-on-grow, room-too-small |
| `Godot/tests/test_stage_model.gd` | Mic setter/args (23)/JSON/modified; channel defaults and old-project load; depth-only change keeps the OSC args; round trip and undo of the new values |
| `Godot/tests/test_stage_view.gd` | Snap toggle reads/writes the config; Players spin visible only in Section |
| `docs/subsystems/osc-protocol.md` | `/stage/set` 23rd argument |
| `docs/adr/0025-stage-mic-capsules.md` (new) | Mic setups as capsules rendered per tap; rejected post-pan alternative; Panner stays the layout seam |
| `docs/subsystems/engine-architecture.md` | Stage pass bullet: mic setups and per-capsule reads |
| `CONTEXT.md` | Mic setup, Coincident/Spaced setup, Depth, Display mode, Section, Players, Footprint |
| `CHANGELOG.md` | Unreleased lines: mic setups; rectangles, sections, snapping |

## Migration and compatibility

- Projects without `stage.mic` load as Pan and render exactly as spec 051 did (REQ-007).
- Channels without `depth` / `display` / `players` get 2 m, Block and 8 players. Their positions
  aren't moved on load. The next edit clamps the whole rectangle into the room, which can nudge a
  source that sits within 1 m of a wall.
- An engine receiving a 22-argument `/stage/set` (older UI) uses Pan. A 23-argument message on an
  older engine is refused (`exactly(22)`). UI and engine ship together, so that is acceptable.

## Test plan

- **Unit (engine, `mic.rs`)**: `mic_setup_from_osc_value` (round trip, unknown → Pan);
  `xy_follows_cardioids` (−45° → L 1.0 · norm, R 0.5 · norm); `blumlein_rear_swaps_sides` (135° →
  |L| full, R ≈ 0, L negative); `blumlein_sides_are_antiphase` (90°); `front_power_matches_pan`
  for every setup; `coincident_capsules_have_no_offset`.
- **Unit (engine, `source.rs`)**: `ab_time_difference` (90° right at 10 m → R peak leads L by
  1.75 ms ± 1 sample at 48 kHz; straight ahead → same sample); `decca_centre_arrives_first`
  (C equal in L and R, L/R 1.55 m later); `mic_setups_match_pan_level` (pink noise, centred at
  5 m, every setup within ±1.5 dB); `mic_change_crossfades` (Pan → Decca mid-render, max step under
  `room_change_crossfades`' bound); `render_does_not_allocate` extended to loop over every setup;
  the existing tests unchanged (REQ-007); `#[ignore] stage_cost_per_mic_setup` (32 sources,
  largest room, 48 kHz / 256 frames, prints the time per setup against Pan).
- **Unit (engine, `tail.rs`)**: `tail_ignores_mic` (`configure` gives the same reverb parameters
  for rooms that differ only in `mic`). This is the REQ-006 check, replacing the weaker Has room
  test in the requirements.
- **Unit (engine, routes)**: `cargo test stage_set` for the 22/23/24-argument forms.
- **Godot**: `Godot/tests/run_all.sh stage` (the four `test_stage_*.gd` scripts).
- **Live**: open View > Stage with a few sections. Check the snapping feel (1 m, Shift 0.1 m), the
  rectangle and edge-handle drags, the player icons at different zooms, and that a section won't
  shrink below its players. Switch mic setups during playback: no clicks; Blumlein's rear
  reflections swapped; AB/Decca audibly wider than XY. Check CPU in the engine load display with a
  spaced setup and ~30 sources.

## Risks

| Risk | Mitigation |
|---|---|
| Spaced setups triple the read cost of every tap, the stage pass's main cost | Measured by `stage_cost_per_mic_setup`; coincident setups stay at one read. If it is over budget, first try sharing second-order taps from the array centre with per-capsule delays only (the second order is the bulk) |
| A capsule offset puts a "receiver" outside the room when the listener sits near a wall | `capsule_position` is clamped into the room (`clamp_point`), like the listener |
| Earliest-arrival referencing shifts as a source moves, slightly changing every delay | Delays already ramp per block (that is the Doppler path), so it glides; covered by `position_jump_has_no_step` |
| Figure-8 anti-phase content (Blumlein, M/S) collapses in mono | Inherent to the setups; documented in the changelog line, not mitigated |
| The rectangle clamp nudges old sources near walls on their first edit | Only on edit, never on load; noted under Migration |

## Open questions

- [ ] None.
