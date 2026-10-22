# 0024 — Stage sources are placed in a room by a pooled pass after the fader

Status: accepted (spec 051, `docs/specs/051-virtual-stage/`). Extends ADR 0020 and ADR 0021.

## Context

The Virtual Stage replaces pan with a position in a shoebox room. Each stage source needs
direct sound placed by distance and direction, plus image-source reflections that feed a shared
Stage return with a late tail. At 64 sources that is about 32 taps each, far more than the
serial fader pass can carry on the callback thread. The old rule said pan is a static 2×2
matrix applied once per channel in pass 2 (and once per route target in pass 3).

## Decision

- **A new stage pass runs after the fader and pan pass.** `stage_pass` (`mixing/mod.rs`) sits
  between `apply_fader_and_pan` and `route_in_dependency_order`. For each stage source
  (`Channel::stage` is `Some`) it calls `Channel::render_stage`: the direct sound replaces the
  channel buffer and the reflections go to `mix.stage_left/right`. Applying the fader first is
  equivalent because the render is linear, and it lets the fader set the level into the room.
  A route target that is also a stage source skips the pass and renders in `route_finished`,
  after its inputs have mixed in and its fader has applied. A silenced source still renders so
  its delay lines stay in step with the stream.
- **Stage pan is the identity.** `PanMode::Stage` (OSC value 4) returns the identity matrix from
  `get_pan_coefficients`, so the fader pass applies only the fader gain. The pan rule becomes:
  pan is a static matrix applied in pass 2 and once per route target in pass 3, and for a stage
  source that matrix is the identity because the stage pass does the placing. Pre-fader sends
  reapply the same matrix, so they stay unspatialized.
- **The pass is pooled with a second job kind.** `JobKind { Chain, Stage }` is set per
  generation (an atomic beside the generation counter). `PoolShared::step` runs `Channel::
  render_stage` for `Stage` jobs, which are self-contained and never park. The claim/park
  protocol and the pool invariant from ADR 0020 are unchanged, and `stage_pass_pooled_matches_
  serial` checks the output is sample-identical with 4 workers and with none. With no pool the
  pass runs serially on the callback.
- **The Stage return is fed by a stage edge.** `Channel::stage_feed: Option<ChannelId>` is a
  third kind of outgoing edge beside the route and the sends, set by the command thread. It is
  counted in `count_route_inputs` (so the return finishes after every source), walked by
  `any_output` and `spread_solo_up` (solo keeps a soloed source's room, mute silences it), and
  mixed in `route_channel` from `mix.stage_*`. It is not a hidden `Send`: Godot addresses sends
  by index (`channel/send/{index}`), and a hidden entry would shift them.
- **The stage edge is latency compensated.** The edge is part of `LatencySignature` and the
  plan, and carries its own `stage_delay` with a `stage` `StereoBlockDelay` ring, like a send.
  `max_delay()` deliberately excludes `stage_delay`: it sizes the route and send rings, and the
  stage ring is prepared from `stage_delay` itself. The plan is rebuilt when a `stage_feed`
  changes.
- **The Stage return is a bus with a tail.** `/stage/return` gives the bus a `stage_tail`
  (`StageTail`, a Hall reverb at 100 % mix), which `begin_device_chain` runs before the user
  devices. The bus runs every block as a route target, so the tail rings out.
- **Objects are built off the lock.** `StageSource` and `StageTail` allocate their delay lines
  in `new` (on the command thread, outside the state lock) and are swapped in under it; the
  audio side never allocates (a test-only global allocator in the `stage::source` tests checks).
- **Automation overrides are applied inside `render_stage`.** `automation_stage` holds the
  normalized override per parameter and `effective_stage_params` maps it onto the room's spans,
  so the pooled pass, the serial pass and `route_finished` all see it.
- **Offline equals real time.** Export calls the same `mix_and_output`. The render resets the
  stage delay lines and tails with the devices so earlier playback doesn't leak into a file.

## Rejected

Rendering inside the device chain's pool job: orchestral templates are mostly plugin channels,
and a chain parked at a plugin is finished on the callback thread, so most of the stage work
would end up serial. Rendering inside `fader_and_pan`, which is serial. A new channel kind for
the Stage return, which would touch every `channel_type` match in Godot.

## Consequences

Stage sources scale across the pool, and the output is sample-identical at any thread count. The
cost is a second pass over the stage sources each block and about 270 KB of delay lines per
source at 48 kHz in the largest room (about 1 MB at 192 kHz). Anything that walks a channel's
outgoing edges now has a third kind to handle. Surround and binaural panners plug in behind the
`Panner` trait later without changing the pass structure.
