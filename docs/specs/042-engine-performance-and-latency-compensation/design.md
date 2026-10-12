# Engine Performance and Latency Compensation — Design

Implements [requirements.md](./requirements.md). Builds on the stability plan's Phase 8a
(parallel plugin dispatch, done) and covers its 8b (realtime priority), "parallel channel
processing" and "plugin latency compensation" items (`docs/engine-stability-plan.md`, Phase 8).

New files and symbols are marked **(new)**. Everything else exists today.

## Context

- `Engine/src/audio/stream.rs`:
  - `build_stream` holds the data callback: `LoadWindow`, and the `EngineStatus::EngineStats` send every `STATS_INTERVAL` (500 ms).
  - `run_live_block` locks the state and runs `process_audio` and then `mix_and_output`, in chunks of at most `MAX_BLOCK_FRAMES`.
  - `CallbackCounters` is the set of atomics shared with the command thread.
  - cpal's `realtime-dbus` feature promotes the callback thread. That is the source of `realtime_denied`.
- `Engine/src/audio/mixing/mod.rs` — `mix_and_output` runs the passes in this order:
  1. `count_route_inputs`
  2. `process_aux_sources`
  3. `device_prepass`
  4. `copy_pre_fader`
  5. `apply_fader_and_pan`
  6. `route_in_dependency_order`, which runs `begin_finish`, then `drain_parked`, then `route_finished`
  7. `write_hardware_outputs`
  8. `sc_taps.snapshot`

  `channel_ids` comes from `HashMap` key order.
- `Engine/src/audio/mixing/routing.rs` — `route_channel` mixes a finished channel into its route target (`add_scaled`), its sends (post-fader via `add_scaled`, pre-fader from `mix.pre_fader_*` with the pan reapplied) and nothing else. `drain_parked` resumes parked chains in park order.
- `Engine/src/audio/channel/chain.rs`:
  - `Channel::begin_device_chain` dispatches notes and calls `begin_chain_from`, which runs `container::run_chain`.
  - `resume_device_chain` calls `container::resume_chain`.
  - `complete_chain_step` deinterleaves the result back into the channel buffers.
- `Engine/src/audio/devices/containers/container.rs`:
  - `run_chain` and `resume_chain` are the single place every top-level device's `process_block`, `begin_block` and `finish_block` is called from.
  - `process_serial_chain` wraps them for containers.
  - `ChainCursor` and `ChainStep` are defined here too.
- `Engine/src/audio/render_scratch.rs` — `RenderScratch` (`channel_ids`, `parked`, `ready`, preallocated to `MAX_CHANNELS` = 1024) and `MixBuffers` (per-channel `Channel::mix`).
- `Engine/src/audio/devices/device.rs` — `AudioDevice: Send`, `latency_frames()` (default 0), `is_enabled`/`set_enabled`, and `begin_block`/`finish_block`.
- `Engine/src/audio/devices/clap_host/subprocess_adapter/`:
  - `mod.rs` holds `SubprocessClapAdapter`: `begin_block`/`finish_block`, the `Dry` paths (not loaded, disabled, late), `latency_frames()` from `load.latency_frames()`, `set_active_state(active, latency)`, `PluginBlockStats` and `record_block_done`.
  - `plugin_ipc.rs` holds `PluginIpcHandle`.
- `Engine/src/audio/command_worker/`:
  - `mod.rs`: the `CommandWorker` loop calls `poll_devices` every `DEVICE_POLL_INTERVAL` (20 ms). `AudioSettings` lives here.
  - `device_tick.rs`: `PolledPlugin`, `record_plugin_stats` and `report_plugin_stats`, which sends `EngineStatus::PluginStats` (`<device addr>/stats`) once a second.
  - `audio_config.rs`: `apply_audio_config`, `report_audio_config` and `reactivate_plugin`.
- `Engine/src/audio/ipc/protocol.rs` — `BlockControl` (`process_ns`) and `Doorbell { word, _reserved: [u8; 60] }`. `PluginEvent` is the host → engine event enum.
- `Engine/src/audio/ipc/shared_memory.rs` — `HostSharedMemory::doorbell()`. `ipc/futex.rs` provides `wait`, `wake` and `ring` (`ring` wakes every waiter).
- `Engine/src/plugin_host/`:
  - `audio_thread.rs::spawn` starts the `plugin-audio` thread.
  - `host.rs` has `HostLatencyImpl::changed` and `SharedHandler::request_restart`, both of which only log today.
  - `vst3/commands.rs` already re-activates after a latency change (`take_reactivate_requested`).
- `Engine/src/audio/render/worker.rs` — `Render::render_block` calls `process_audio` and `mix_and_output`, then copies each `Tap` (`channel_id`, `WavOutput`) out of the channel buffers. `render_range` and `render_tail` drive it.
- `Engine/src/audio/dsp/delay_line.rs` — `DelayLine` (power-of-two mono ring, `prepare` on the command thread, `push`/`read`).
- `audio_thread_priority` 0.35.1 is in `Cargo.lock` through cpal. It provides `promote_current_thread_to_real_time(frames, rate)`. cpal calls it from a helper thread, because the rtkit D-Bus call must not run on a realtime thread.
- Godot:
  - `Godot/editor/EnginePanel.gd`: the performance popup with `performance_text` (RichTextLabel) and `rank_plugins`, which uses `DeviceInstance.plugin_stats`.
  - `Godot/data/EngineStatus.gd`: listens to `/status/engine_stats`.
  - `Godot/data/AudioConfig.gd`: the audio settings autoload.
  - `Godot/data/PluginHosting.gd`: the pattern for a setting that is sent on change and on `engine_connected`.
  - `Godot/settings/Settings.gd`: the audio settings registry.

## Approach

This is one spec in four parts. They are built in the order measure → realtime → parallel →
compensate, and each part is usable on its own.

**A. Timing.** The chain runner is the one place every top-level device runs. `run_chain` and
`resume_chain` gain an `on_device_time(idx, ns)` callback, next to `on_sleep_change`. The channel
adds each figure to a fixed per-channel array of device timers. The mixer times each channel's
own work (chain begin and resume, pan, routing) into a channel timer. It does not count the time
a parked chain waits while other channels run. Two `Instant::now()` reads per device per block
cost about 40 ns. Timing only runs while it is switched on: one flag in `EngineState`, set while
Godot subscribes. That keeps REQ-005 trivially met when nobody is watching.

The command thread collects the timers under the lock every 500 ms, as `poll_devices` already
does for plugins, and sends one `/status/channel_perf` per channel that ran. A plugin's host-side
figure stays where it is today (`<device>/stats`). The panel joins the two by device path.

**Rejected:** sending timing from the callback, as `EngineStats` does. It needs a status per
channel per interval from the audio thread. The command thread already has the lock cadence, and
an allocation-free reset.

**B. Realtime for plugin hosts.** `plugin_host`'s audio thread calls
`audio_thread_priority::promote_current_thread_to_real_time` once at spawn, before it is
realtime, because the D-Bus call blocks. It writes the result into a new `Doorbell` field carved
from `_reserved`. The engine reads it from the shared memory (no protocol message) and reports it
as a new trailing argument of `<device>/stats`. The processing threads in part C promote
themselves the same way.

**C. Channel worker pool.** The unit of work is a channel's device chain. The pool exists only
inside the two mixer passes that already treat channels as independent:

- `device_prepass`: channels nothing routes into.
- One sweep of `route_in_dependency_order`: the `ready` list.

For each pass, the callback thread works like this:

1. It writes raw pointers to the channels into a preallocated job array. Every pointer is to a
   different channel, and the map isn't touched until step 4.
2. It publishes a job count and a generation, and rings a futex.
3. It claims jobs itself through the same atomic index as the workers.
4. It waits until every claimed job is done.

A job runs `begin_device_chain`. When a chain parks at a plugin, the thread keeps it in its own
park queue and claims the next job. Once no jobs are left, it drains its queue, which is
Phase 8a's pattern per thread. Plugins on different channels therefore still overlap, and a
thread waiting on a plugin doesn't hold up built-in channels.

A job a thread never started is simply claimed by the callback (REQ-012). Only started jobs are
waited for. That wait is bounded by the job's own work, exactly as when the callback runs it
itself.

Everything that is order-dependent stays serial on the callback thread, in `ready` list order:
fader and pan, routing and summing, aux sources, device events, hardware output. Summation order
therefore can't change. `channel_ids` is sorted every block, a non-allocating `sort_unstable`, so
the order is the same in every engine instance (REQ-009). Processing threads = 1 (or no worker
threads) takes the existing code path untouched.

**Rejected:** work-stealing across the whole graph (rayon-style). It allocates, spawns
non-realtime threads, and parallelism per channel is what the dependency structure gives anyway.
**Also rejected:** splitting one channel's chain across threads (out of scope).

**D. Latency compensation at the summing points.** Each channel gets:

- `in_latency`: the largest `out_latency` among the channels routing or sending into it.
- `out_latency`: `in_latency` plus the sum of its top-level devices' `latency_frames()`.

Every edge (route, each send, the hardware write) delays the source by
`target.in_latency − source.out_latency` (hardware: the largest writer's `out_latency` minus the
source's). The delay is applied in `route_channel` and `write_hardware_outputs` by reading the
source's block from a per-channel stereo ring at that offset. The ring is written once per block
in `route_finished`. A channel whose edges all have 0 delay owns no ring, and takes today's
`add_scaled` path, so a project without latency is sample-identical to today.

The command thread computes the plan (`LatencyPlan`, new). It checks a cheap latency signature
every `DEVICE_POLL_INTERVAL` and rebuilds only when the signature changes, which covers REQ-015
for graph edits and latency changes without hooking every command. Rings are allocated outside
the lock and swapped in under it. Old rings go back through `CommandEffects`-style drop-after-unlock.

Containers align their parallel branches internally:

- Layer slots, Drum Machine pads and Multiband bands are delayed to the container's maximum.
- Reverb delays its dry path by its Wet FX latency.
- PolySynth's FX slot is serial, so it adds.

Each container reports the result as its own `latency_frames()`. The CLAP adapter and the
containers delay their dry or bypass path by their latency (decision: bypass keeps latency).
CLAP plugins that change latency at runtime get the restart path VST3 already has. The host
sends a new `PluginEvent::LatencyChanged`, and `poll_devices` updates the adapter.

**Rejected:** shifting clip and MIDI scheduling earlier per channel (the "negative delay"
approach). It needs look-ahead in every MIDI and clip source and in automation. Delaying at the
summing points is local to the mixer and correct for routes, sends and buses alike. Its cost is
that all output is late by the total latency, which the requirements accept.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `EngineState::perf_timing: bool` (new) | command thread (subscribe/unsubscribe, under lock) | callback reads it under the lock it already holds | yes |
| `Channel::device_timers: [DeviceTimer; MAX_TIMED_DEVICES]` (new, 64, inline, no heap) | callback / processing thread working on that channel | command thread reads and resets under the state lock every 500 ms | yes: plain adds, never resized |
| `MixBuffers::timer: ChannelTimer` (new) | same as above | same | yes |
| `ChannelPool` (new): worker `JoinHandle`s and the `Arc<PoolShared>` | command thread creates and drops it (outside the lock), swaps it into `EngineState::pool` under the lock | callback: `&PoolShared` under the state lock | yes: atomics and futex only |
| `PoolShared` (new): job array `[AtomicPtr<Channel>; MAX_CHANNELS]`, `job_count`, `next_job`, `done_count` (`AtomicU32`, futex word), `generation` (`AtomicU32`, futex word), `frames`, `shutdown` | callback publishes jobs; workers claim, run and finish them | workers only dereference job pointers between a generation bump and `done_count` reaching `job_count`; the callback holds the state lock for that whole span and doesn't touch the map | yes. The `unsafe` invariant is documented on `PoolShared` |
| Per-worker park queue (new): `VecDeque<*mut Channel>` with capacity `MAX_CHANNELS` | the worker | — | yes, preallocated |
| `PoolShared::realtime: AtomicU8` per worker (new) | worker, once at start | command thread (reporting) | yes |
| `Doorbell::audio_realtime: AtomicU32` (new, from `_reserved`) | plugin host's audio thread, once at spawn | engine command thread through `HostSharedMemory` | yes |
| `LatencyPlan` (new) per channel: `in_latency`, `out_latency`, `route_delay`, `send_delays: SmallVec`, `hw_delay`, `pre_ring`/`post_ring: Option<StereoBlockDelay>` | command thread builds it, outside the lock for allocation | installed into `Channel::latency` (new field) under the lock; callback reads it | yes: rings preallocated to `max delay + MAX_BLOCK_FRAMES` |
| `StereoBlockDelay` (new, `dsp/block_delay.rs`) | owner of the ring (channel or container) | callback writes a block, then reads at an offset | yes |
| Container branch delays (Layer, Drum Machine, Multiband, Reverb dry) | command thread sizes them in a new `AudioDevice::update_latency()` call | callback | yes on the callback. `update_latency` may allocate **under the lock** when a branch's latency grows. This is listed as a known gap in the command classification, like `LoadDeviceFile` |
| `SubprocessClapAdapter` bypass delay (`StereoBlockDelay`) | command thread sizes it in `set_active_state` (outside the lock, like today's activation) | callback, on every `Dry` path | yes |

## Data and protocol changes

New and changed OSC messages, all documented in `docs/subsystems/osc-protocol.md`:

| Address | Dir | Args | Notes |
|---|---|---|---|
| `/engine/perf/subscribe` | Godot → engine | — | Starts timing and stats. Counted, so two subscribers need two unsubscribes |
| `/engine/perf/unsubscribe` | Godot → engine | — | At 0 subscribers timing stops (`perf_timing = false`) |
| `/status/channel_perf` | engine → Godot | `i channel_id, f load_avg, f load_peak, i out_latency_frames, i device_count, (f device_avg, f device_peak) × device_count` | Every 500 ms per channel that ran in the interval, while subscribed. Loads are shares of the block time |
| `/status/engine_perf` | engine → Godot | `i processing_threads, s threads_realtime, i output_latency_frames, i over_limit_channels, i sample_rate` | Every 500 ms while subscribed. `threads_realtime` is `granted`, `denied`, `partial` or `none` (0 threads) |
| `/engine/threads/set` | Godot → engine | `i threads` | 0 = Auto (`min(cores / 2, 8) − 1`, at least 0), otherwise 1..cores, where 1 = no workers. Applied live |
| `<device addr>/stats` | engine → Godot | existing 8 args + `i host_realtime` | 0 = unknown, 1 = granted, 2 = denied. Godot treats it as optional |

Engine commands (`Engine/src/audio/commands/mod.rs`, classified in `engine-architecture.md`
"Command classification"):

- `AudioCommand::SetPerfSubscription { subscribe: bool }`: command thread only.
- `AudioCommand::SetProcessingThreads { threads: u32 }`: build/teardown. The pool is built outside the lock and swapped in under it.
- `EngineStatus::ChannelPerf { … }` and `EngineStatus::EnginePerf { … }`, encoded in `osc/encode.rs`.

Plugin IPC (`docs/subsystems/engine-plugin-architecture.md`):

- `Doorbell` gains `audio_realtime: AtomicU32` (0 unknown, 1 granted, 2 denied). `_reserved` shrinks from 60 to 56 bytes, so the struct size is unchanged.
- `PluginEvent::LatencyChanged { frames: u32 }` (new). The host sends it after it re-activates a plugin whose latency changed (CLAP `request_restart` or `latency.changed`, and the existing VST3 re-activation).

Godot:

- `Settings.gd` registers `audio/processing_threads` (Type.CHOICE, default `"Auto"`, choices `"Auto"` plus `"1"`…`str(OS.get_processor_count())`) under Audio › Performance.
- `AudioConfig.gd` sends `/engine/threads/set` on change and on `engine_connected`. It never goes through `/audio/config/set`, so a thread change doesn't reopen the stream.
- `EngineStatus.gd` gains `ChannelPerf` and `EnginePerf` classes, the `channel_perf_received` and `engine_perf_received` signals, and `subscribe_perf()`/`unsubscribe_perf()`. `EnginePanel` calls these on popup show and hide.
- `DeviceInstance.PluginStats` gains `host_realtime`.

Persisted: `config.json` gains `audio/processing_threads`. A missing key means Auto. Projects are
unchanged.

## File-by-file change list

### Engine: timing (A)

| File | Change |
|---|---|
| `Engine/src/audio/devices/containers/container.rs` | `run_chain`, `resume_chain` and `process_serial_chain` take `on_device_time: &mut impl FnMut(usize, u64)`. Time `process_block`, and `begin_block` + `finish_block` (plugin engine time, wait included). Sleeping pass-through counts 0. Gated by a `timing: bool` argument, so containers pass `false` |
| `Engine/src/audio/channel/mod.rs` | `Channel` gains `device_timers: [DeviceTimer; MAX_TIMED_DEVICES]` and `latency: ChannelLatency` (part D). `DeviceTimer { total_ns: u64, peak_ns: u32, blocks: u32 }` (new) with `add` and `take` |
| `Engine/src/audio/channel/chain.rs` | `begin_chain_from` and `resume_device_chain` pass the timer closure (`start + idx`, ignored past `MAX_TIMED_DEVICES`). They time themselves into `mix.timer` when `timing` is on |
| `Engine/src/audio/render_scratch.rs` | `MixBuffers` gains `timer: ChannelTimer` (new) and `timing: bool` (copied from `EngineState::perf_timing` at the start of `mix_and_output`) |
| `Engine/src/audio/mixing/mod.rs`, `routing.rs` | Time `route_finished` and pan into `mix.timer`. At the end of `mix_and_output`, `timer.end_block(block_ns)` for every channel, with `block_ns` from `frames` and `state.device_sample_rate` |
| `Engine/src/audio/state.rs` | `EngineState` gains `perf_timing: bool`, `perf_subscribers: u32` and `pool: ChannelPool` (C) |
| `Engine/src/audio/command_worker/perf.rs` **(new)** | `CommandWorker::report_perf` collects and resets the timers under the lock every 500 ms while subscribed, sends `ChannelPerf` per channel with `blocks > 0`, then `EnginePerf`. Called from the loop next to `poll_devices` |
| `Engine/src/audio/command_worker/mod.rs` | `mod perf;`, dispatch `SetPerfSubscription` and `SetProcessingThreads`, `perf_since: Instant` |
| `Engine/src/audio/commands/mod.rs`, `status.rs` | The commands and statuses above, plus classification rows |
| `Engine/src/osc/routes/audio.rs` | Routes `/engine/perf/subscribe`, `/engine/perf/unsubscribe` and `/engine/threads/set` as `["engine", …]` arms next to `/audio/config/*` |
| `Engine/src/osc/routes/mod.rs` | `Some("audio" \| "engine")` dispatches to `audio::route` |
| `Engine/src/osc/encode.rs` | Encode `ChannelPerf` and `EnginePerf`, and append `host_realtime` to `PluginStats` |

### Engine: realtime for plugin hosts (B)

| File | Change |
|---|---|
| `Engine/Cargo.toml` | Direct dependency `audio_thread_priority = "0.35.1"` (already in the lock through cpal) |
| `Engine/src/audio/ipc/protocol.rs` | `Doorbell::audio_realtime`, `_reserved: [u8; 56]`. A size assertion test |
| `Engine/src/audio/ipc/shared_memory.rs` | `HostSharedMemory::audio_realtime() -> &AtomicU32` (offset 4, after `word`) |
| `Engine/src/plugin_host/audio_thread.rs` | In `spawn`'s closure, before `AudioWorker::new`: promote with `(MAX_PERIOD_FRAMES, 48_000)` and store 1 or 2. Log granted or denied once |
| `Engine/src/audio/realtime.rs` **(new)** | `promote_current_thread(label) -> RealtimeState`, shared by the plugin host and the processing threads (a thin wrapper that logs) |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/plugin_ipc.rs` | `PluginIpcHandle::host_realtime() -> u32`, read through `connection()?.host_shared()` |
| `Engine/src/audio/command_worker/device_tick.rs` | `PolledPlugin` carries `host_realtime`. `report_plugin_stats` puts it in `PluginStats` |

### Engine: worker pool (C)

| File | Change |
|---|---|
| `Engine/src/audio/mixing/pool.rs` **(new)** | `ChannelPool { shared: Arc<PoolShared>, workers: Vec<JoinHandle<()>> }`: `new(threads, frames_hint, rate)`, `threads()`, `realtime_summary()`, and `Drop` (shutdown, ring, join; command thread only). `PoolShared` as in the ownership table. `run_jobs(&self, jobs: &mut [*mut Channel], frames, mode)` is the callback side: publish, ring, claim, drain own parks, wait on `done_count` (spin, then futex). `worker_loop` is the worker side: promote to realtime, wait on `generation`, claim, run, park, drain, add to `done_count`, ring. `JobMode::{Prepass { start_from_aux }, Finish}` chooses the start index the way `device_prepass` and `begin_finish` do today |
| `Engine/src/audio/mixing/mod.rs` | Sort `channel_ids`. `device_prepass` collects the eligible channels' pointers into `RenderScratch::jobs` (new, capacity `MAX_CHANNELS`) and calls `pool.run_jobs` when `pool.threads() > 0` and there are at least 2 jobs, otherwise the existing loop. Then `forward_device_events` serially in `channel_ids` order |
| `Engine/src/audio/mixing/routing.rs` | `route_in_dependency_order` → per sweep: the `begin_finish` bookkeeping (`done = true`, skip muted or non-target) stays serial, then the eligible ready channels run through `pool.run_jobs` (or the existing begin/drain), then `forward_device_events` and `route_finished` serially in `ready` order |
| `Engine/src/audio/render_scratch.rs` | `RenderScratch::jobs: Vec<*mut Channel>`. It is `!Send`, so it holds `usize` addresses instead (cast at use) to keep `EngineState: Send` |
| `Engine/src/audio/command_worker/mod.rs` | `SetProcessingThreads`: resolve Auto, build `ChannelPool::new` outside the lock, swap it under the lock, drop the old one after unlock. Also rebuilt with the stream in `apply_audio_config` (the rate goes to rtkit) |
| `Engine/src/audio/rt_debug.rs` | Workers wrap each job in `check_callback`. `report` runs on a worker after every generation that hit a violation (outside the checked region) |

### Engine: latency compensation (D)

| File | Change |
|---|---|
| `Engine/src/audio/dsp/block_delay.rs` **(new)** | `StereoBlockDelay` over two `DelayLine`s: `prepare(max_delay, max_block)`, `write(left, right, frames)`, and `add_delayed(delay, gain, frames, out_l, out_r)` / `read_delayed(…)` (frame `i` reads `frames − i + delay` back) |
| `Engine/src/audio/mixing/latency.rs` **(new)** | `LatencySignature` (built under the lock: per channel id, the route, the send targets, the top-level `latency_frames()` sum, and the aux-source device latency). `plan(signature, rate) -> LatencyPlan`: a topological walk like `count_route_inputs`, cycle-safe (cycle edges get delay 0). Clamps to `rate` frames (1 s) and records over-limit channels (REQ-017). Return channels start at their aux-source device's latency |
| `Engine/src/audio/channel/mod.rs` | `ChannelLatency { in_frames, out_frames, route_delay, send_delays: Vec<u32>, hw_delay, post: Option<StereoBlockDelay>, pre: Option<StereoBlockDelay> }` (new), default all zero / `None` |
| `Engine/src/audio/mixing/routing.rs` | `route_finished` writes the block into `latency.post` (and `latency.pre` from `mix.pre_fader_*`) when present. In `route_channel`, `add_scaled` and the pre-fader loop read through the ring when the edge delay is > 0 |
| `Engine/src/audio/mixing/mod.rs` | `write_hardware_outputs` reads through `latency.post` with `hw_delay` |
| `Engine/src/audio/command_worker/latency.rs` **(new)** | `CommandWorker::refresh_latency`, every poll: build the signature under the lock. If it changed, call `update_latency()` on every device (which sizes container branch delays), plan, allocate rings outside the lock, swap them into `Channel::latency` under the lock, drop the old ones after unlock, and warn per over-limit channel. Also run on the rate change in `set_device_rate` |
| `Engine/src/audio/devices/device.rs` | `fn update_latency(&mut self, sample_rate: f32) -> u32 { self.latency_frames() }` (new default). Containers override it, recurse into their children, and size their branch delays |
| `Engine/src/audio/devices/containers/chain.rs` | `latency_frames` = sum of children. `update_latency` recurses |
| `Engine/src/audio/devices/containers/layer.rs` | Per-slot `StereoBlockDelay` to the slot maximum, applied to the slot output before it mixes and to separate-out buses. `latency_frames` = max. The disabled path delays the dry input by it |
| `Engine/src/audio/devices/containers/drum_machine.rs` | As Layer, per pad and per extra out |
| `Engine/src/audio/devices/effects/multiband.rs` | Per-band delay to the band maximum, before the sum. Disabled path delayed |
| `Engine/src/audio/devices/effects/reverb.rs` | Dry path delayed by the Wet FX slot latency. `latency_frames` = Wet FX latency (Tank FX is a loop slot and takes no plugin) |
| `Engine/src/audio/devices/instruments/polysynth/mod.rs` | `latency_frames` = FX slot chain latency (serial) |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs` | `bypass_delay: StereoBlockDelay`, sized in `set_active_state` to `latency + MAX_BLOCK_FRAMES`. Every `Dry` outcome in `finish_block` and `process_block` reads the dry input through it at `latency_frames`. `set_latency_frames(frames)` (new) for `LatencyChanged` |
| `Engine/src/plugin_host/host.rs` | `request_restart` and `HostLatencyImpl::changed` set a `restart_requested` flag on `SubprocessHostShared` |
| `Engine/src/plugin_host/event_loop.rs` / `commands.rs` | In the main loop: when the flag is set and the plugin is active, deactivate, activate, `query_latency`, and send `PluginEvent::LatencyChanged { frames }` when it differs |
| `Engine/src/plugin_host/vst3/commands.rs` | After the existing latency re-activation, send `LatencyChanged` |
| `Engine/src/audio/ipc/protocol.rs` | `PluginEvent::LatencyChanged { frames: u32 }` |
| `Engine/src/audio/command_worker/device_tick.rs` | Handle `LatencyChanged`: `with_plugin(… set_active_state(true, frames))` (resizes the bypass delay outside the lock first). The next `refresh_latency` picks it up |
| `Engine/src/audio/render/worker.rs` | `Tap` gains `skip: u64` = its channel's `out_frames` at render start (analysis taps likewise). Copy only after `skip` frames. `render_tail` renders at least `max(skip)` extra frames, so files keep their length (REQ-018). Master tap = master's `out_frames` |

### Godot

| File | Change |
|---|---|
| `Godot/settings/Settings.gd` | Register `audio/processing_threads` |
| `Godot/data/AudioConfig.gd` | `THREADS_KEY`, `threads_value()` (Auto → 0), and send `/engine/threads/set` on setting change and `engine_connected`. Header comment documents the message |
| `Godot/data/EngineStatus.gd` | `ChannelPerf` and `EnginePerf` classes and parsers, signals, and `subscribe_perf`/`unsubscribe_perf` (send the OSC; this is the model, so the UI doesn't send it) |
| `Godot/data/DeviceInstance.gd` | `PluginStats.host_realtime` (optional arg 8), shown in `describe()` |
| `Godot/editor/EnginePanel.gd` | Subscribe on popup show, unsubscribe on hide and `_exit_tree`. Keep the latest `ChannelPerf` per channel (dropped after 2 intervals without an update, REQ-004). Render a "Channels" table: name, load, peak and latency, with indented top-level device rows (name from `channel.devices[i]`; for plugins, also "host N%"). Above it a header line: "N threads · realtime", "Plugin latency: X ms", plus the plugin hosts' realtime state when any is denied. Over-limit channels in `COLOR_ALERT` |

### Docs

| File | Change |
|---|---|
| `docs/subsystems/osc-protocol.md` | Every message in the table above |
| `docs/subsystems/engine-architecture.md` | "Mixing" covers the pool and the compensation edges. "Command classification" gains the new commands and marks `update_latency` growth as allocating under the lock. The stage read/write map gains `device_timers`, `latency` and `pool` |
| `docs/subsystems/engine-audio-thread.md` | Processing threads follow the audio thread contract. The pointer-handoff invariant. Timing |
| `docs/subsystems/engine-plugin-architecture.md` | Host audio thread realtime, `Doorbell::audio_realtime`, `LatencyChanged`, bypass delay |
| `docs/engine-stability-plan.md` | Phase 8 checklist: 8b, parallel channels and latency compensation point to spec 042 |
| `docs/adr/0020-channel-worker-pool.md` **(new)** | Channel-granular realtime pool, callback participates, serial summing. Supersedes nothing; extends ADR 0002 |
| `docs/adr/0021-latency-compensation-at-summing-points.md` **(new)** | Delay at edges, bypass keeps latency, all output late by the total |
| `CONTEXT.md` | Glossary: processing thread, path latency, compensation |

## Migration and compatibility

- Projects: unchanged. Latency is runtime state.
- `config.json`: `audio/processing_threads` is added with default `"Auto"`.
- Engine ↔ Godot skew: an older Godot never subscribes (no perf stats, no timing cost) and never sends `/engine/threads/set` (the engine uses Auto). It ignores `<device>/stats` argument 8. A newer Godot against an older engine gets no `/status/*_perf`, and the panel keeps today's content.
- Plugin hosts: engine and `plugin_host` are always built together (run scripts). The `Doorbell` size is unchanged.
- Audio output: a project without latency-reporting devices is sample-identical to today (0-delay edges take the old path). With latency devices, every output is late by the total, and renders trim it (REQ-018).

## Test plan

Unit tests (`cargo test <name>` from `Engine/`):

| Test | Where | Proves |
|---|---|---|
| `chain_timer_counts_each_device` | `devices/containers/container.rs` tests | one `on_device_time` per running device. Sleeping devices count 0 (REQ-002) |
| `timing_off_records_nothing` | `mixing/mod.rs` tests | `perf_timing = false` leaves every timer at zero (REQ-003, REQ-005) |
| `channel_timer_excludes_parked_wait` | `mixing/routing.rs` tests | with `FakePlugin`, the channel time doesn't include other channels' work (REQ-001) |
| `perf_report_drops_removed_channels` | `command_worker/perf.rs` | REQ-004 |
| `doorbell_layout_is_unchanged` | `ipc/protocol.rs` | `size_of::<Doorbell>() == 64` |
| `pool_output_matches_single_thread` | `mixing/pool.rs` | the same graph (instruments, effects, buses, pre and post sends, a cycle, a return channel, `FakePlugin`) rendered for 50 blocks with 0 and with 4 workers is bit-identical (REQ-009) |
| `pool_completes_with_paused_workers` | `mixing/pool.rs` | workers parked on a test barrier, so the callback runs every job and the output is still correct (REQ-012) |
| `pool_drop_joins_workers` | `mixing/pool.rs` | no leaked threads after resize to 0 |
| `channel_ids_are_sorted` | `mixing/mod.rs` | deterministic order |
| `block_delay_reads_back_exact` | `dsp/block_delay.rs` | delay 0, 1, n, and n > block across block boundaries |
| `plan_aligns_parallel_paths` | `mixing/latency.rs` | the REQ-013 example gives a delay of 512 on A→Drums, Drums.out = 512, sends included |
| `plan_survives_cycles_and_clamps` | `mixing/latency.rs` | REQ-017 |
| `parallel_paths_null_at_master` | `mixing/routing.rs` | a 100-frame latency test device on one of two inverted paths: master below −120 dBFS after the first block of the delay (REQ-013) |
| `zero_latency_project_unchanged` | `mixing/routing.rs` | the existing routing golden values are unchanged, with no rings allocated |
| `layer_aligns_slots` / `drum_machine_aligns_pads` / `multiband_aligns_bands` | the container files | REQ-014 |
| `bypassed_plugin_keeps_latency` | `subprocess_adapter/mod.rs` | the disabled and late `Dry` paths are delayed by `latency_frames` |
| `render_trims_latency` | `render/worker.rs` | REQ-018: onset at frame 0, equal length |

Godot (`Godot/tests/run_all.sh engine_perf plugin_stats`):

- `Godot/tests/test_engine_perf.gd` **(new)**: `EngineStatus` parses `/status/channel_perf` and `/status/engine_perf`. The panel's table text names the heaviest channel first, drops stale channels, and shows latency.
- `Godot/tests/test_plugin_stats.gd`: the optional `host_realtime` argument.
- `Godot/tests/test_audio_config.gd`: the `processing_threads` → `/engine/threads/set` value mapping.

Live checks (release build, with the user's permission for the engine on port 7000):

1. Open the performance popup and check that `oscdump 7001` shows the perf messages. Close it and check that they stop.
2. `chrt -p` on the `plugin-audio` and `sonara-worker-*` threads.
3. 8 × PolySynth (16 voices) + Reverb at 256 frames, with Processing threads at 1 and then 4. Compare the load (REQ-008).
4. A linear-phase EQ plugin on one of two inverted copies routed to master gives silence. Bypass it: still silence.
5. Render a range with the latency plugin on the drums and check the onset in a waveform view.

`./test_osc.sh` and `./test_plugin_osc.sh` must pass with Processing threads at 1 and at Auto.

## Risks

| Risk | Mitigation |
|---|---|
| A device has hidden shared mutable state across channels (a static, or a cache shared through an `Arc`) and races under the pool | Audit task before enabling: grep for `static`, `thread_local!`, `Arc<Mutex`/`Arc<RefCell` in `audio/devices`, `audio/modulation` and `audio/dsp`. Known today: the `rt_debug` thread-locals (handled), `PLUGIN_UNDERRUNS` (atomic), and `BlockClock` (atomics). `pool_output_matches_single_thread` runs under `cargo test` with the full device set |
| `unsafe` channel-pointer handoff | One module (`pool.rs`), one documented invariant, the callback holds the lock for the whole span, and Miri-free unit tests plus a debug assertion that no pointer appears twice |
| rtkit refuses some threads (per-user burst limit with many hosts plus workers) | Each thread reports its own state. `partial` is shown in the panel. Processing still works without realtime |
| Workers on idle cores compete with plugin hosts | Auto leaves half the cores free. The setting goes down to 1 |
| Spinning workers burn CPU while stopped | Spin is bounded (about 20 µs) before the futex wait. Workers sleep on `generation` between blocks |
| The latency signature misses a change (for example a device's latency changes without a graph edit) | The signature includes every top-level `latency_frames()` (containers recurse), so polling catches it within 20 ms |
| Allocation under the lock when a container branch delay grows | Rare (only on a latency change). Listed in the command classification. A follow-up moves it out with the phase 2 lock removal |
| Timer attribution is off for one interval after a device move | Accepted. Timers reset every interval (REQ-004's window) |
| PDC adds latency to live playing | Accepted for this spec (requirements: Out of scope) |

## Open questions

- [x] None. (PolySynth's slot code is in `instruments/polysynth/mod.rs`; `/engine/*` needs a dispatch arm in `osc/routes/mod.rs`.)
