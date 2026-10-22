# Virtual Stage — Design

Implements [requirements.md](./requirements.md).

## Context

- `Engine/src/audio/channel/pan.rs`: `PanMode` (`StereoCombined`, `StereoDual`, `StereoBalance`,
  `Mono`; OSC values 0–3) and `Channel::get_pan_coefficients`, a static 2×2 matrix.
- `Engine/src/audio/channel/mod.rs`: `Channel` (buffers, `pan*`, `automation_pan`,
  `send_channels`, `latency: ChannelLatency`, `mix: MixBuffers`) and `Channel::set_sample_rate`,
  called by `CommandWorker::set_device_rate` (`audio/command_worker/audio_config.rs`) with the
  stream stopped.
- `Engine/src/audio/mixing/mod.rs`: `mix_and_output`. The passes are `device_prepass` (pooled),
  `copy_pre_fader`, `apply_fader_and_pan` → `fader_and_pan` (serial on the callback),
  `route_in_dependency_order`, and `write_hardware_outputs`.
- `Engine/src/audio/mixing/routing.rs`: `count_route_inputs`, `route_channel` (route and sends;
  moves buffers out with `mem::take`, edge delays from `latency.send_delays` and the `post`/`pre`
  rings), `begin_finish`, and `route_finished` (route targets fade and pan after their devices).
- `Engine/src/audio/mixing/solo.rs`: `assign_solo_roles`, `any_output`, `spread_solo_up`. Each
  walks a channel's route and sends.
- `Engine/src/audio/mixing/latency.rs`: `ChannelSignature` / `ChannelPlan` / `plan`, with one delay
  per edge (`route_delay`, `send_delays`).
- `Engine/src/audio/mixing/pool.rs`: `ChannelPool::run_jobs` and `PoolShared::step`, which runs
  `begin_device_chain` / `resume_device_chain` on a channel pointer (ADR 0020).
- `Engine/src/audio/channel/chain.rs`: `begin_device_chain`. It dispatches MIDI and then calls
  `begin_chain_from`.
- `Engine/src/audio/render_scratch.rs`: `MixBuffers` (per-channel scratch: `pre_fader_*`,
  `pending_inputs`, solo flags).
- `Engine/src/audio/automation.rs`: `AutomationTarget` (`ChannelPan` → `channel.automation_pan`,
  parsed from `channel/pan`).
- `Engine/src/audio/devices/effects/reverb.rs`: `ReverbDevice` with Hall FDN, `DECAY`,
  `PREDELAY`, `SIZE`, `EARLY` and `MIX` parameters, and its own tail sleep.
- `Engine/src/audio/render/`: offline export calls the same `mix_and_output`, so anything
  rendered there is identical offline (REQ-029).
- `Engine/src/osc/routes/channel.rs` (`/channel/{id}/pan_mode`), `Engine/src/audio/commands/`
  (`SetChannelPanMode`).
- `Godot/data/Channel.gd`: `PanMode` enum, `get_pan_state` / `set_pan_state` /
  `convert_pan_state` (undo snapshots), `to_json` / `from_json`, `sync_to_engine`, and the return
  helpers (`is_aux_return`, …).
- `Godot/data/Project.gd`: `create_channel`, `remove_channel`, `to_json` / `from_json`,
  `connect_to_engine`.
- `Godot/data/AutomationTarget.gd`: `Kind` enum and the wire spelling.
- `Godot/mixer/PanControl.gd`: the pan-mode popup (`_on_mode_selected`, through
  `PropertyCommand` / `HistoryUtil`).
- `Godot/devices/DeviceWindowManager.gd` plus `Godot/devices/frame/DeviceFrame.gd` /
  `FrameWindow.gd`: floating frames and the one attached frame. `Editor.attach_frame` /
  `detach_frame` put it in `primary_panel`.
- `Godot/editor/SelectionSync.gd`: keeps track and channel selection consistent.
- `Godot/dawproject/DawProjectExporter.gd` (`_pan_position`) and `TransferReport.gd` (`add`).

## Approach

**The fader pass stays as it is, and a new pooled stage pass runs after it.** A stage source's pan
coefficients are the identity matrix, so the fader pass applies only its fader gain. A new pass
between `apply_fader_and_pan` and `route_in_dependency_order` then renders every stage source on
the channel worker pool. It writes the spatialized direct sound back into the channel buffer and
the source's reflections into a new per-channel scratch pair, `mix.stage_left/right`. Applying the
fader first is equivalent because the stage render is linear, and it means the fader sets the
source's level into the room too. Pre-fader sends read the pre-pan copy, so for a stage source
they stay unspatialized. That's consistent with how they work today: pre-fader sends reapply only
the static pan matrix, which is the identity here.

*Rejected:* rendering the stage inside the device chain's pool job. Orchestral templates are
mostly plugin channels, and a chain that parks at a plugin is finished by `drain_parked` on the
callback thread, so most stage work would end up serial. *Rejected:* rendering inside
`fader_and_pan`, which is serial. 64 sources wouldn't fit there.

**The Stage return is fed by a stage edge.** Each stage source gets a third kind of outgoing edge,
`Channel::stage_feed: Option<ChannelId>`, next to its route and sends. The command thread sets it
to the Stage return's id while the source is in Stage mode and a return exists. The edge is
counted in `count_route_inputs`, walked in `solo.rs`, given a delay in the latency plan, and mixed
in `route_channel` from `mix.stage_left/right`. So ordering, solo (REQ-019), mute (REQ-020) and
latency compensation behave like a send, without being a send. *Rejected:* a hidden `Send`
appended to `send_channels`. Godot addresses sends by index (`channel/send/{index}` automation,
`/channel/{id}/send/...`), and a hidden entry would break that indexing.

**The Stage return is a bus with a flag.** In Godot it is a `BUS` channel with
`is_stage_return = true`. It inherits routing, the fader, solo, devices, sends and deletion
handling from bus channels, and the flag only adds what's specific to it: it can't be deleted
while sources exist, it can't be a stage source itself, and its name and colour are fixed. In the
engine, the channel registered by `/stage/return` gets a `stage_tail: Option<Box<StageTail>>`,
which `begin_device_chain` runs before the user devices. *Rejected:* a new channel kind, which
would touch every `channel_type` match in Godot to add nothing.

**DSP model.** The room is a shoebox (width × depth × height, at most 60 × 40 × 25 m) with six
surfaces. Each has a broadband reflection gain and a high-frequency damping value, which the
Godot material table converts from absorption coefficients. For each source the engine computes:

- **Direct sound:** one point (mono, or stereo at size 0 using the size-0 sum mode) or two
  points (L and R, `size` m apart along `rotation`). Gain is `r_ref / max(r, 0.5)` with
  `r_ref = 5 m`, capped at +6 dB, so a source at the default depth sounds about as loud as when it
  was panned (REQ-002). Air absorption is a one-pole low-pass whose cutoff falls with distance.
  The direction to the listener goes through a `Panner`, which gives constant-power stereo from
  azimuth. Sources behind the listener get a gentle extra high-frequency cut.
- **Reflections:** image sources. The first order uses 6 images per point (12 for a stereo source
  with size > 0). The second order uses 18 images from the point's mono sum. Each tap is a
  delay, a gain (1/r times the surface gains) and a `Panner` direction. First-order taps sum into
  one stereo bus per surface, and each bus gets that surface's damping filter. Second-order taps
  sum into one bus with an averaged filter. With Distance delay off, every tap's delay is its
  path length minus the direct path length (REQ-008).
- **Render loop:** per tap over the block, not per sample over taps. Each tap's delay and gain are
  linear ramps from the block start to the block end, so the inner loop is a fractional delay
  read with two multiply-adds that the compiler can vectorize. At about 32 taps per source this
  keeps 64 sources well inside the budget.
- **Movement:** the target position, size and rotation (base value or automation) go through a
  ~30 ms one-pole smoother evaluated at the block boundary. Taps are recomputed per block from the
  smoothed values and ramp within the block, so there are no clicks (REQ-026). A moving source
  gets a natural Doppler shift.
- **Room changes:** a new `RoomModel` copied into a source starts a 50 ms equal-power crossfade
  between the old and new tap sets (REQ-027). During the fade, the source renders both sets.
- **Tail:** `StageTail` owns a `ReverbDevice` set to Hall, `EARLY` 0, `MIX` 100 %, `DECAY` the
  room's decay time, `SIZE` from the room volume, and `PREDELAY` the room's mean second-order tap
  delay. The Stage return's input (the sum of all reflections) feeds it, and its output is
  reflections + tail × tail gain. Godot calibrates the tail gain per preset so the onset matches
  the reflections' level (REQ-011). In `Reflections only` mode the tail is bypassed. The device's
  own `TailSleep` keeps an idle tail cheap, and the Stage return runs every block as a route
  target, so the tail rings out (REQ-014).

**Layout-agnostic seam.** `Panner` is a trait with `fn gains(&self, dir: Vec3, out: &mut [f32])`,
and the source writes into `out.len()` output buses. The stereo panner is the only implementation
in this spec. Surround (VBAP) and binaural panners plug in at this seam later.

**Godot.** `Project.stage: Stage` is the project's one stage model. It follows the
self-synchronizing pattern and sends `/stage/set` from its setters and `sync_to_engine()`. Stage
source parameters live on `Channel` (`stage_x … stage_has_room`) with `get_stage_state` /
`set_stage_state` snapshots for undo, mirroring the pan state. The Stage view is a `StageView`
page shown in a `DeviceFrame` that has no devices. A new `DeviceWindowManager.open_stage()` gives
it the same window, attach and detach behaviour as device frames. Edit operations (move, resize
and rotate, clamp, multi-move) live in a pure `StageEdit` class so they can be tested headless
(REQ-022).

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `EngineState::stage: StageState` (`room: RoomModel`, `return_channel_id`) | command thread | callback reads under the state lock | yes, `RoomModel` is `Copy` |
| `Channel::stage_params: StageParams` (position, size, rotation, sum mode, has room) | command thread | callback and pool read under the lock | yes, `Copy` |
| `Channel::automation_stage: [Option<f32>; 5]` | audio callback (automation pass) | stage pass | yes |
| `Channel::stage: Option<Box<StageSource>>` (delay lines, tap sets, smoothers, a `RoomModel` copy) | built by the command thread **outside** the lock (sized for the current sample rate and the largest room), swapped in under it; dropped through `CommandEffects` | stage pass on a pool thread or the callback, one job per channel | yes, only preallocated buffers |
| `Channel::stage_feed: Option<ChannelId>` | command thread | routing, solo, latency passes | yes |
| `Channel::stage_tail: Option<Box<StageTail>>` | built by the command thread outside the lock; swapped in on `/stage/return` | `begin_device_chain` of the Stage return (pool or callback) | yes |
| `MixBuffers::stage_left/right` | preallocated with the other `MixBuffers` | written by the stage pass, read by `route_channel` | yes |
| `PoolShared` job kind (`Chain` / `Stage`) | callback, per generation | workers read it with the generation | yes, an atomic |

Room changes: the command thread copies the new `RoomModel` into `state.stage.room` and into every
source's `StageSource` under the lock. That's a few hundred bytes per source, and the crossfade
happens on the audio side. Sample-rate changes rebuild `StageSource` and `StageTail` in
`Channel::set_sample_rate` (the stream is stopped, so allocating is allowed). Delay lines hold
`max_path / 343 m/s` seconds: about 0.7 s for the largest room, which is about 270 KB per stereo
source at 48 kHz.

This changes the "pan is a static matrix applied in pass 2" rule (`AGENTS.md`,
engine-architecture.md) and extends ADR 0020 with a second job kind. **New ADR 0024: Stage render
pass**, which records both.

## Data and protocol changes

OSC (Godot → engine). All of these are new except the pan-mode value:

| Address | Args | Effect |
|---|---|---|
| `/channel/{id}/pan_mode` | `i 4` | New value `Stage`. The engine refuses it on master and on the Stage return (warn log, mode unchanged). The restriction to instrument, audio and group channels is enforced in Godot. |
| `/channel/{id}/stage` | `f x, f y, f z, f size, f rotation_deg, i sum_mode (0 L+R, 1 Mid), i has_room` | Sets `stage_params`. Meters, room coordinates (origin at the front-left floor corner). |
| `/stage/set` | `f width, f depth, f height, f listener_x, f listener_y, f listener_z, f decay_s, f tail_db, i distance_delay, i output_mode (0 Full, 1 Reflections, 2 Direct)`, then 6 × (`f gain, f hf_damping`) for front, back, left, right, floor, ceiling | Replaces `state.stage.room`. |
| `/stage/return` | `i channel_id` (0 = none) | Registers the Stage return and sets every source's `stage_feed`. |

Status: none new. Godot already knows every value it sent, and shows automated positions by
evaluating `AutomationLane.get_value_at_tick` at the playhead.

Automation targets: `channel/stage/{x|y|z|size|rotation}`. The normalized 0–1 value maps onto the
room's span for that axis, 0–`max(width, depth)` for size, and −180–180° for rotation. Engine:
`AutomationTarget::StageParam { param }`. Godot: `AutomationTarget.Kind.STAGE_PARAM`.

Commands: a new `audio/commands/stage.rs` with `SetStage`, `SetStageReturn` and
`SetChannelStage`. `SetChannelPanMode` to Stage takes the slow path, because the `StageSource` is
built outside the lock.

`.sonara` (additive):
- Project: `"stage": {preset, modified, width, depth, height, listener: [x, y, z], materials:
  {front, …}, decay_s, tail_db, distance_delay, output_mode}`, written only once a stage exists.
- Channel: `"pan_mode": "STAGE"`, and `"stage": {x, y, z, size, rotation, sum_mode, has_room,
  placed}`. `is_stage_return` is saved with the channel's other flags.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/stage/mod.rs` (new) | `StageState`, `RoomModel` (`Copy`, limits), `StageParams`, `OutputMode`, constants (`R_REF`, `SPEED_OF_SOUND`, max room) |
| `Engine/src/audio/stage/image_source.rs` (new) | Pure tap computation: `taps(room, point, listener, distance_delay) -> TapSet` (first and second order, direct path) |
| `Engine/src/audio/stage/panner.rs` (new) | `Panner` trait, `StereoPanner` |
| `Engine/src/audio/stage/source.rs` (new) | `StageSource`: delay lines, smoothers, current/next `TapSet` and crossfade, surface filters, air absorption, `render(&mut self, buf_l, buf_r, out_stage_l, out_stage_r, params, frames)` |
| `Engine/src/audio/stage/tail.rs` (new) | `StageTail` wrapping `ReverbDevice`, `configure(&RoomModel)`, `process` |
| `Engine/src/audio/mod.rs` | `pub mod stage;` |
| `Engine/src/audio/channel/pan.rs` | `PanMode::Stage` (OSC value 4); `get_pan_coefficients` returns the identity matrix for Stage |
| `Engine/src/audio/channel/mod.rs` | Fields `stage_params`, `automation_stage`, `stage`, `stage_feed`, `stage_tail`; `set_sample_rate` rebuilds the stage objects; `render_stage(frames)` |
| `Engine/src/audio/channel/chain.rs` | `begin_device_chain`: run `stage_tail` on the buffers when `start == 0`, before `begin_chain_from` |
| `Engine/src/audio/render_scratch.rs` | `MixBuffers::stage_left/right`, preallocated like `pre_fader_*` |
| `Engine/src/audio/mixing/mod.rs` | New `stage_pass` between `apply_fader_and_pan` and `route_in_dependency_order` (pooled with `JobKind::Stage`, serial fallback); skip silenced and `Has room`-only work as needed |
| `Engine/src/audio/mixing/pool.rs` | `JobKind` per generation; `PoolShared::step` dispatches `Stage` jobs to `Channel::render_stage` (never parks) |
| `Engine/src/audio/mixing/routing.rs` | `count_route_inputs` counts `stage_feed`; `route_channel` mixes `mix.stage_*` (delayed through a `stage` ring when needed); `route_finished` renders the stage for a stage source that is a route target |
| `Engine/src/audio/mixing/solo.rs` | `any_output` and `spread_solo_up` walk `stage_feed` |
| `Engine/src/audio/mixing/latency.rs` | `ChannelSignature` / `ChannelPlan` carry the stage edge; `stage_delay` in the plan |
| `Engine/src/audio/channel/mod.rs` (`ChannelLatency`) | `stage_delay: u32`, `stage: Option<StereoBlockDelay>` |
| `Engine/src/audio/automation.rs` | `AutomationTarget::StageParam`, parse and display `channel/stage/*`, apply and release into `automation_stage` |
| `Engine/src/audio/commands/stage.rs` (new), `Engine/src/audio/commands/mod.rs` | `SetStage`, `SetStageReturn`, `SetChannelStage`; pan mode Stage builds the `StageSource` off-lock |
| `Engine/src/audio/command_worker/mod.rs` | Slow path for pan mode Stage and `SetStageReturn` (build off-lock, swap under the lock, drop through `CommandEffects`) |
| `Engine/src/audio/command_worker/latency.rs` | Rebuild the latency plan when a `stage_feed` changes, like a send change |
| `Engine/src/osc/routes/stage.rs` (new), `Engine/src/osc/routes/mod.rs`, `Engine/src/osc/routes/channel.rs` | `/stage/set`, `/stage/return`, `/channel/{id}/stage`; pan mode 4 |
| `docs/adr/0024-stage-render-pass.md` (new) | Stage pass, identity pan for Stage, second pool job kind, stage edge |
| `docs/subsystems/osc-protocol.md` | The four messages above |
| `docs/subsystems/engine-architecture.md`, `AGENTS.md` | Mixing passes: the stage pass; Stage return and tail; pan rule wording |
| `CONTEXT.md` | Stage, Stage source, Stage return, Listener, Size, Has room |
| `Godot/data/Stage.gd` (new) | `class_name VirtualStage` (a global `Stage` clashes with `Envelope.Stage`): room values, materials, preset name and `modified`, signals, setters, `sync_to_engine()`, `to_json` / `from_json` |
| `Godot/data/StagePresets.gd` (new) | The five presets and the material table (absorption → gain and damping) |
| `Godot/data/Channel.gd` | `PanMode.STAGE`; `can_use_stage()` (instrument, audio and group channels only); stage fields, `stage_changed` signal, `get_stage_state` / `set_stage_state`, initial placement from pan (REQ-002); `is_stage_return`; `to_json` / `from_json`; `sync_to_engine` sends `/channel/{id}/stage` |
| `Godot/data/Project.gd` | `stage` member; `ensure_stage_return()` when a channel enters Stage (REQ-017); `remove_channel` refuses the Stage return while sources exist (REQ-018); `stage_sources()`; save, load and `connect_to_engine` send the stage and `/stage/return` |
| `Godot/data/AutomationTarget.gd` | `Kind.STAGE_PARAM` with the `channel/stage/{param}` spelling |
| `Godot/mixer/PanControl.gd` | Stage entry in the mode popup (hidden where `can_use_stage()` is false); in Stage mode, shows a "Stage" button that opens the Stage view |
| `Godot/stage/StageEdit.gd` (new) | Pure edit operations: move, resize-rotate from an end drag, clamp to room, multi-move, height for a selection |
| `Godot/stage/StageCanvas.gd` (new) | Draws the room, listener and source bars; hit-testing; drags through `StageEdit` and `PropertyCommand` |
| `Godot/stage/StageView.gd` / `StageView.tscn` (new) | Canvas, room panel (preset, dimensions, materials, decay, tail, distance delay, output mode), source panel (height, sum mode, has room) |
| `Godot/devices/DeviceWindowManager.gd`, `Godot/devices/frame/DeviceFrame.gd` | `open_stage()` / `close_stage()`; a frame with no devices that hosts a custom page and title (the channel header is hidden) |
| `Godot/editor/MainMenu.gd` | View > Stage |
| `Godot/editor/SelectionSync.gd` | Helpers mapping Stage view selection to channels and back (REQ-024) |
| `Godot/dawproject/DawProjectExporter.gd` | `_pan_position` maps Stage X onto pan; one `TransferReport.add` entry for the stage (REQ-030) |
| `CHANGELOG.md` | Unreleased: Virtual Stage |

## Migration and compatibility

Old projects have no `stage` keys and load unchanged. An older build that reads `"pan_mode":
"STAGE"` falls back through `PanMode.get(..., channel.pan_mode)` to its default, and ignores the
`stage` keys. The Stage return then loads as a plain bus. No `config.json` change.

## Test plan

- **Unit (engine, `mod tests` blocks):**
  - `stage::image_source`: `first_reflection_earlier_near_wall` (REQ-009), `height_changes_floor_ceiling_taps` (REQ-010), `distance_delay_off_keeps_relative_tap_delays` (REQ-008)
  - `stage::source`: `farther_is_quieter_and_duller` and `left_source_is_left` (REQ-004), `size_spreads_stereo_inputs` (REQ-006), `mono_ignores_size` (REQ-007), `position_jump_has_no_step` (REQ-026), `has_room_writes_no_reflections` (REQ-013)
  - `stage::tail`: `tail_decay_matches_room` (REQ-011), `output_modes` (REQ-012)
  - `mixing::routing`: `stage_source_direct_follows_route` (REQ-005), `stage_return_receives_reflections`, `stage_return_rings_out` (REQ-014)
  - `mixing::solo`: `solo_keeps_soloed_source_room_only` (REQ-019), `muted_source_feeds_no_room` (REQ-020)
  - `mixing::pool`: `stage_pass_pooled_matches_serial`
  - `automation`: `stage_x_automation_moves_balance` (REQ-025)
  - `render`: `stage_offline_matches_realtime` (REQ-029)
  - A `stage_64_sources_budget` bench test (ignored by default) for the performance target.
- **Godot (`Godot/tests/`):**
  - `test_stage_pan_mode.gd` (REQ-001, 002, 003, 017, 018)
  - `test_stage_model.gd` (REQ-015, 016, 023, 028 round-trip)
  - `test_stage_edit.gd` (REQ-022)
  - `test_stage_view.gd` (REQ-021, 024; kept shallow)
  - The automation-target case added to the existing automation target test (REQ-025)
  - `test_dawproject_export.gd` gets a stage case (REQ-030)
- **Live:** two string patches (one stereo, one mono) and a brass patch as stage sources in the
  Scoring Stage and Church presets. Move them during playback, automate X, switch presets while
  playing, solo one source, and listen for clicks, the reflections-to-tail transition, and
  front/back depth. Read the stage pass cost in the Engine panel's channel timers with 64 sources.

## Risks

| Risk | Mitigation |
|---|---|
| Stage pass too slow serially when there are no processing threads (Processing threads = 1) | Per-tap block loops, static taps skip the ramp, second order from the mono sum. Measure with the bench test at 1 thread; if over budget, drop second-order taps for distant sources first |
| Delay line memory at 192 kHz (about 1 MB per source) | Size the lines for the current room's max path rounded up to a bucket, and rebuild off-lock when the room grows. Start with sizing for the largest room and measure |
| Wet libraries with `Has room` still sound detached from dry ones | That's expected; document it. A later spec could add "reflections only, reduced" per source |
| `DeviceFrame` assumes a channel and devices in places | A dedicated task audits `DeviceFrame` for null `channel` / empty devices before the Stage view is hosted there |
| Tail onset doesn't line up with the reflections in some presets | Godot calibrates `tail_db` and `PREDELAY` per preset; the live check per preset is a task |
| An ADR 0020 change (second job kind) affects every pooled pass | `JobKind` is set per generation, with no change to the claim/park protocol; the pooled-vs-serial equality test |

## Open questions

None.
