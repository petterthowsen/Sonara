# Engine Performance and Latency Compensation — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine gates after every engine task: `cargo fmt` and `cargo test` from `Engine/`. Godot gates:
`Godot/tests/run_all.sh <words>`. Live checks need a release build (`./run_release.sh`). Ask
before starting an engine on port 7000 or touching PipeWire's forced quantum.

## Phase 1: Timing, end to end (A)

- [x?] **T-001** [REQ-002, REQ-005] Device timing in the chain runner
  - _Files_: `Engine/src/audio/devices/containers/container.rs`, `Engine/src/audio/devices/containers/*.rs` and `Engine/src/audio/devices/effects/{multiband,reverb,delay}.rs`, `Engine/src/audio/devices/instruments/polysynth/mod.rs` (the `process_serial_chain` callers pass `timing = false` and a no-op)
  - _Output_:
    - `run_chain`/`resume_chain`/`process_serial_chain` take `timing: bool` and `on_device_time: &mut impl FnMut(usize, u64)`.
    - `process_block` and `begin_block` + `finish_block` are timed with `Instant`.
    - Sleeping pass-through records nothing.
  - _Verify_: `cargo test chain_timer_counts_each_device` passes; all existing container tests pass
  - _Depends on_: —

- [x?] **T-002** [REQ-001, REQ-002] Per-channel device and channel timers
  - _Files_: `Engine/src/audio/channel/mod.rs`, `Engine/src/audio/channel/chain.rs`, `Engine/src/audio/render_scratch.rs`, `Engine/src/audio/mixing/mod.rs`, `Engine/src/audio/mixing/routing.rs`, `Engine/src/audio/state.rs`
  - _Output_:
    - New `DeviceTimer` and `ChannelTimer`, plus `Channel::device_timers: [DeviceTimer; 64]`, `MixBuffers::{timer, timing}` and `EngineState::{perf_timing, perf_subscribers}`.
    - The channel timer covers chain begin and resume plus `route_finished`, and excludes time parked.
    - `end_block(block_ns)` runs per channel at the end of `mix_and_output`.
  - _Verify_: `cargo test timing_off_records_nothing channel_timer_excludes_parked_wait` passes
  - _Depends on_: T-001

- [x?] **T-003** [REQ-001, REQ-003, REQ-004] Subscription commands, perf report and OSC
  - _Files_: `Engine/src/audio/commands/mod.rs`, `Engine/src/audio/commands/status.rs`, `Engine/src/audio/command_worker/mod.rs`, `Engine/src/audio/command_worker/perf.rs` (new), `Engine/src/osc/routes/audio.rs`, `Engine/src/osc/routes/mod.rs`, `Engine/src/osc/encode.rs`
  - _Output_:
    - `SetPerfSubscription` (counted), with `/engine/perf/subscribe` and `/engine/perf/unsubscribe`.
    - `report_perf` collects and resets the timers every 500 ms while subscribed.
    - `/status/channel_perf` and `/status/engine_perf` are encoded. `engine_perf` reports threads = 0 and latency = 0 until Phases 3 and 4 fill them in.
  - _Verify_:
    - `cargo test perf_report_drops_removed_channels` passes, plus encode tests for both messages (address and type tags).
    - Live: `oscsend localhost 7000 /engine/perf/subscribe` makes `oscdump 7001` show `/status/channel_perf` every 500 ms. After unsubscribe they stop.
  - _Depends on_: T-002

- [x?] **T-004** [REQ-001, REQ-002, REQ-004] Godot model: EngineStatus perf parsing and subscription
  - _Files_: `Godot/data/EngineStatus.gd`, `Godot/tests/test_engine_perf.gd` (new)
  - _Output_:
    - `ChannelPerf` and `EnginePerf` with `from_osc`, plus `channel_perf_received` and `engine_perf_received`.
    - `subscribe_perf`/`unsubscribe_perf` send the OSC.
  - _Verify_: `Godot/tests/run_all.sh engine_perf` passes (parsing, with a variable device count)
  - _Depends on_: T-003

- [x?] **T-005** [REQ-001, REQ-002, REQ-004] Engine panel channel table
  - _Files_: `Godot/editor/EnginePanel.gd`, `Godot/tests/test_engine_perf.gd`
  - _Output_:
    - The popup subscribes on show and unsubscribes on hide and `_exit_tree`.
    - The channel table is sorted by load, with indented top-level device rows (names from the project's channel devices; plugins also show "host N%" from `plugin_stats`).
    - Stale rows are dropped after 2 intervals.
  - _Verify_:
    - `Godot/tests/run_all.sh engine_perf` passes: heaviest channel first, a container is one row, a stale channel is dropped.
    - Live: PolySynth with 16 voices plus an idle audio track; the PolySynth tops the list.
  - _Depends on_: T-004

- [ ] **T-006** [REQ-005] Measure the timing cost
  - _Files_: — (results go in `STATUS.md`)
  - _Output_: callback load with timing on vs off for a 32-channel × 4-device project at 256 frames
  - _Verify_: the difference is ≤ 1% of the block time, recorded in `STATUS.md`
  - _Depends on_: T-005

## Phase 2: Realtime scheduling for plugin hosts (B)

- [x?] **T-007** [REQ-006, REQ-007] Promote the plugin host's audio thread
  - _Files_: `Engine/Cargo.toml`, `Engine/src/audio/realtime.rs` (new), `Engine/src/audio/mod.rs`, `Engine/src/audio/ipc/protocol.rs`, `Engine/src/audio/ipc/shared_memory.rs`, `Engine/src/plugin_host/audio_thread.rs`
  - _Output_:
    - `promote_current_thread` wrapper.
    - `Doorbell::audio_realtime` (`_reserved` → 56) and `HostSharedMemory::audio_realtime()`.
    - The `plugin-audio` thread promotes itself before `AudioWorker::new`, stores 1 or 2, and logs the result.
  - _Verify_:
    - `cargo test doorbell_layout_is_unchanged` passes.
    - Live: `chrt -p <plugin-audio tid>` shows `SCHED_FIFO`/`SCHED_RR`.
    - `./test_plugin_osc.sh` passes with rtkit running and with rtkit stopped.
  - _Depends on_: —

- [x?] **T-008** [REQ-006] Report host realtime state
  - _Files_: `Engine/src/audio/devices/clap_host/subprocess_adapter/plugin_ipc.rs`, `Engine/src/audio/command_worker/device_tick.rs`, `Engine/src/audio/commands/status.rs`, `Engine/src/osc/encode.rs`, `Godot/data/DeviceInstance.gd`, `Godot/editor/EnginePanel.gd`, `Godot/tests/test_plugin_stats.gd`
  - _Output_:
    - `PluginIpcHandle::host_realtime()`.
    - `PluginStats` carries it as `<device>/stats` argument 8.
    - `PluginStats.host_realtime` in Godot. The panel names hosts whose request was denied.
  - _Verify_: an encode test for the 9-argument `/stats`; `Godot/tests/run_all.sh plugin_stats` passes with 8 and with 9 arguments
  - _Depends on_: T-007, T-005

## Phase 3: Channel worker pool (C)

- [x?] **T-009** [REQ-009] Audit for shared mutable state across channels
  - _Files_: — (findings in `STATUS.md`; fixes become extra tasks here)
  - _Output_: a list of every `static`, `thread_local!`, `Arc<Mutex…>`/`Arc<RefCell…>` and global reached from `AudioDevice::process_block` in `audio/devices`, `audio/modulation` and `audio/dsp`, each marked safe or to-fix
  - _Verify_: the list is in `STATUS.md`, and each to-fix item has a follow-up task appended below
  - _Depends on_: —

- [x?] **T-010** [REQ-009] Deterministic channel order
  - _Files_: `Engine/src/audio/mixing/mod.rs`
  - _Output_: `channel_ids.sort_unstable()` after it is filled
  - _Verify_: `cargo test channel_ids_are_sorted` passes; all mixing tests pass
  - _Depends on_: —

- [x?] **T-011** [REQ-008, REQ-011, REQ-012] `ChannelPool` core
  - _Files_: `Engine/src/audio/mixing/pool.rs` (new), `Engine/src/audio/mixing/mod.rs` (`mod pool`)
  - _Output_:
    - `ChannelPool::new/threads/realtime_summary/Drop` and `PoolShared` with the documented `unsafe` invariant.
    - `run_jobs` (publish, claim, per-thread park queue, drain, wait on `done_count`).
    - `worker_loop` (promotes itself through `realtime::promote_current_thread`, bounded spin then futex).
    - `rt_debug` wrapping on workers.
  - _Verify_: `cargo test pool_completes_with_paused_workers pool_drop_joins_workers` passes; a debug assertion rejects a duplicate job pointer
  - _Depends on_: T-007 (realtime wrapper), T-009

- [x?] **T-012** [REQ-008, REQ-009] Use the pool in the pre-pass and the routing sweeps
  - _Files_: `Engine/src/audio/mixing/mod.rs`, `Engine/src/audio/mixing/routing.rs`, `Engine/src/audio/render_scratch.rs`, `Engine/src/audio/state.rs`
  - _Output_:
    - `EngineState::pool` and `RenderScratch::jobs` (addresses as `usize`).
    - `device_prepass` and each sweep of `route_in_dependency_order` run eligible chains through `run_jobs` when the pool has workers and there are 2 or more jobs.
    - Events and `route_finished` stay serial, in order.
    - Timers (T-002) still work on workers.
  - _Verify_: `cargo test pool_output_matches_single_thread` passes (bit-identical, 50 blocks, 0 vs 4 workers); the full `cargo test` passes
  - _Depends on_: T-010, T-011, T-002

- [x?] **T-013** [REQ-010, REQ-011] Processing threads command and live resize
  - _Files_: `Engine/src/audio/commands/mod.rs`, `Engine/src/audio/command_worker/mod.rs`, `Engine/src/audio/command_worker/audio_config.rs`, `Engine/src/audio/command_worker/perf.rs`, `Engine/src/osc/routes/audio.rs`
  - _Output_:
    - `SetProcessingThreads` with the Auto rule `min(cores / 2, 8) − 1`.
    - The pool is built outside the lock, swapped in under it, and the old one is dropped after unlock. It is rebuilt with the stream on a rate change.
    - `EnginePerf` reports the thread count and the realtime summary.
  - _Verify_:
    - A `cargo test` for the Auto rule (12 → 5, 2 → 0, 32 → 7).
    - Live: `oscsend localhost 7000 /engine/threads/set i 4` during playback; `/status/engine_perf` shows 4 within 1 s, and the xrun count rises by at most 1.
  - _Depends on_: T-012, T-003

- [x?] **T-014** [REQ-010, REQ-011] Godot: Processing threads setting and panel header
  - _Files_: `Godot/settings/Settings.gd`, `Godot/data/AudioConfig.gd`, `Godot/editor/EnginePanel.gd`, `Godot/tests/test_audio_config.gd`, `Godot/tests/test_engine_perf.gd`
  - _Output_:
    - `audio/processing_threads` (Auto, 1..cores) under Audio › Performance.
    - AudioConfig sends `/engine/threads/set` on change and on `engine_connected`.
    - The panel header shows "N threads · realtime".
  - _Verify_: `Godot/tests/run_all.sh audio_config engine_perf` passes (Auto → 0, "4" → 4; header text)
  - _Depends on_: T-013, T-005

- [ ] **T-015** [REQ-008] Measure the speed-up
  - _Files_: — (results in `STATUS.md`)
  - _Output_: load for 8 × (PolySynth with 16 voices + Reverb) at 256 frames, with 1 and with 4 threads
  - _Verify_: load with 4 threads is under 50% of the load with 1, recorded in `STATUS.md`. `./test_osc.sh` and `./test_plugin_osc.sh` pass at 1 and at Auto
  - _Depends on_: T-014

## Phase 4: Latency compensation (D)

- [x?] **T-016** [REQ-013] `StereoBlockDelay`
  - _Files_: `Engine/src/audio/dsp/block_delay.rs` (new), `Engine/src/audio/dsp/mod.rs`
  - _Output_: `prepare`, `write`, `add_delayed` and `read_delayed` over two `DelayLine`s
  - _Verify_: `cargo test block_delay_reads_back_exact` passes
  - _Depends on_: —

- [x?] **T-017** [REQ-013, REQ-017] Latency signature and plan
  - _Files_: `Engine/src/audio/mixing/latency.rs` (new), `Engine/src/audio/channel/mod.rs` (`ChannelLatency`)
  - _Output_:
    - `LatencySignature` and `plan()`: in and out latency per channel, plus route, send and hardware delays.
    - Return channels start at the aux device's latency.
    - Cycles are safe, the plan is clamped to 1 s, and over-limit channels are listed.
  - _Verify_: `cargo test plan_aligns_parallel_paths plan_survives_cycles_and_clamps` passes
  - _Depends on_: T-016

- [x?] **T-018** [REQ-013] Apply edge delays in the mixer
  - _Files_: `Engine/src/audio/mixing/routing.rs`, `Engine/src/audio/mixing/mod.rs`
  - _Output_:
    - `route_finished` writes the post ring and the pre ring.
    - `route_channel` reads route and send edges through the rings when the delay is > 0, and `write_hardware_outputs` reads through `hw_delay`.
    - A 0-delay edge takes the old path.
  - _Verify_: `cargo test parallel_paths_null_at_master zero_latency_project_unchanged` passes; T-012's pool test still passes
  - _Depends on_: T-017

- [x?] **T-019** [REQ-015, REQ-016, REQ-017] Command thread refresh and reporting
  - _Files_: `Engine/src/audio/command_worker/latency.rs` (new), `Engine/src/audio/command_worker/mod.rs`, `Engine/src/audio/command_worker/audio_config.rs` (`set_device_rate`), `Engine/src/audio/command_worker/perf.rs`, `Engine/src/audio/devices/device.rs` (`update_latency` default)
  - _Output_:
    - `refresh_latency` runs every poll: rebuild on signature change, allocate outside the lock, swap under it, drop after unlock, warn on over-limit.
    - `ChannelPerf.out_latency` and `EnginePerf.output_latency_frames`/`over_limit_channels` are filled in.
  - _Verify_:
    - A `cargo test` where adding a latency test device to a channel changes its plan within one `refresh_latency` call.
    - Live: the panel shows the channel's latency after a linear-phase EQ plugin is added.
  - _Depends on_: T-018, T-003

- [x?] **T-020** [REQ-015] Bypass delay in the CLAP adapter
  - _Files_: `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs`
  - _Output_:
    - `bypass_delay` is sized in `set_active_state`.
    - Every `Dry` outcome (disabled, not loaded, late, request outstanding) delays the dry input by `latency_frames`.
    - `set_latency_frames` is added.
  - _Verify_: `cargo test bypassed_plugin_keeps_latency` passes; existing adapter tests pass
  - _Depends on_: T-016

- [ ] **T-021** [REQ-015] Runtime latency changes from plugins
  - _Files_: `Engine/src/plugin_host/host.rs`, `Engine/src/plugin_host/event_loop.rs`, `Engine/src/plugin_host/commands.rs`, `Engine/src/plugin_host/vst3/commands.rs`, `Engine/src/audio/ipc/protocol.rs`, `Engine/src/audio/command_worker/device_tick.rs`
  - _Output_:
    - The CLAP `request_restart` and `latency.changed` callbacks set a flag. The event loop then re-activates the plugin and sends `PluginEvent::LatencyChanged` when the value differs. VST3 sends it after its existing re-activation.
    - `poll_devices` applies the new value through `set_active_state`.
  - _Verify_:
    - A `cargo test` for `LatencyChanged` handling, using a fake connection or the existing poll test helpers.
    - Live: change a lookahead setting on a plugin that reports latency changes; the panel's latency follows within 1 s.
  - _Depends on_: T-019, T-020

- [ ] **T-022** [REQ-014] Containers align their branches
  - _Files_: `Engine/src/audio/devices/containers/chain.rs`, `Engine/src/audio/devices/containers/layer.rs`, `Engine/src/audio/devices/containers/drum_machine.rs`
  - _Output_:
    - Chain: sum.
    - Layer and Drum Machine: per-slot and per-pad delays to their maximum, extra outs included, and the disabled path delayed.
    - `update_latency` overrides.
  - _Verify_: `cargo test layer_aligns_slots drum_machine_aligns_pads` passes
  - _Depends on_: T-019

- [ ] **T-023** [REQ-014] Slotted devices and Multiband
  - _Files_: `Engine/src/audio/devices/effects/multiband.rs`, `Engine/src/audio/devices/effects/reverb.rs`, `Engine/src/audio/devices/instruments/polysynth/mod.rs`
  - _Output_:
    - Multiband: per-band delays, and the disabled path delayed.
    - Reverb: the dry path is delayed by the Wet FX latency.
    - PolySynth: reports its FX slot latency.
  - _Verify_: `cargo test multiband_aligns_bands` passes, plus a Reverb test (a Wet FX latency device keeps dry and wet aligned) and a PolySynth `latency_frames` test
  - _Depends on_: T-022

- [ ] **T-024** [REQ-018] Renders trim the compensation latency
  - _Files_: `Engine/src/audio/render/worker.rs`
  - _Output_:
    - `Tap.skip` is set from its channel's `out_frames` (analysis taps likewise).
    - `render_tail` renders at least `max(skip)` extra frames.
  - _Verify_: `cargo test render_trims_latency` passes (onset at frame 0 ± 1, same length as without the device); existing render tests pass
  - _Depends on_: T-019

- [ ] **T-025** [REQ-016, REQ-017] Engine panel latency display
  - _Files_: `Godot/editor/EnginePanel.gd`, `Godot/tests/test_engine_perf.gd`
  - _Output_:
    - Per-channel latency in samples and ms.
    - A "Plugin latency: X ms" header line.
    - Over-limit channels shown in `COLOR_ALERT`.
  - _Verify_: `Godot/tests/run_all.sh engine_perf` passes ("Drums 512 smp (10.7 ms)" at 48 kHz)
  - _Depends on_: T-019, T-014

## Phase 5: Docs

- [x?] **T-026** [REQ-all] OSC protocol doc
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: `/engine/perf/subscribe`, `/engine/perf/unsubscribe`, `/engine/threads/set`, `/status/channel_perf`, `/status/engine_perf` and `<device>/stats` argument 8 are documented
  - _Verify_: every address in design.md's protocol table appears in the doc with its arguments
  - _Depends on_: T-003, T-008, T-013

- [ ] **T-027** [REQ-all] Engine and plugin subsystem docs
  - _Files_: `docs/subsystems/engine-architecture.md`, `docs/subsystems/engine-audio-thread.md`, `docs/subsystems/engine-plugin-architecture.md`, `docs/engine-stability-plan.md`
  - _Output_:
    - Pool and compensation in "Mixing".
    - Command classification rows (including `update_latency` allocating under the lock) and stage map entries.
    - Processing-thread contract.
    - Doorbell realtime field, `LatencyChanged` and the bypass delay.
    - Phase 8 checklist pointers to spec 042.
  - _Verify_: each file mentions the new state names from design.md's ownership table
  - _Depends on_: T-024

- [ ] **T-028** [REQ-all] ADRs and glossary
  - _Files_: `docs/adr/0020-channel-worker-pool.md` (new), `docs/adr/0021-latency-compensation-at-summing-points.md` (new), `CONTEXT.md`
  - _Output_: both ADRs in the existing ADR format; glossary entries for processing thread, path latency and compensation
  - _Verify_: the ADRs follow the structure of `docs/adr/0019-vst3-hosting.md`; glossary terms match requirements.md "Terms"
  - _Depends on_: T-024

## Phase 6: Live verification and tracking

- [ ] **T-029** [REQ-all] Live verification
  - _Files_: — (results in `STATUS.md`)
  - _Output_: design.md "Live checks" 1–5 run on a release build
  - _Verify_:
    1. Perf messages appear only while the popup is open.
    2. `chrt -p` shows realtime for `plugin-audio` and the workers.
    3. The REQ-008 load ratio.
    4. The inverted-copy null test with a latency plugin, bypassed and active.
    5. Render onset at frame 0.

    Every REQ is marked `[x]` in this file only when its check passed.
  - _Depends on_: T-015, T-025, T-027

- [ ] **T-030** [REQ-all] Update issue #1
  - _Files_: GitHub issue #1 (petterthowsen/Sonara)
  - _Output_:
    - Checklist items: "Plugin latency compensation" and "Realtime thread priority configuration" become `[x?]`, then `[x]` after T-029.
    - "CPU affinity…" stays open.
    - A comment links spec 042 and summarises the measurements.
  - _Verify_: `gh issue view 1` shows the updated checklist and the comment (ask the user before posting)
  - _Depends on_: T-029

## Coverage

| REQ | Tasks |
|---|---|
| REQ-001 | T-002, T-003, T-004, T-005 |
| REQ-002 | T-001, T-002, T-004, T-005 |
| REQ-003 | T-003 |
| REQ-004 | T-003, T-004, T-005 |
| REQ-005 | T-001, T-006 |
| REQ-006 | T-007, T-008 |
| REQ-007 | T-007 |
| REQ-008 | T-011, T-012, T-015 |
| REQ-009 | T-009, T-010, T-012 |
| REQ-010 | T-013, T-014 |
| REQ-011 | T-011, T-013, T-014 |
| REQ-012 | T-011 |
| REQ-013 | T-016, T-017, T-018 |
| REQ-014 | T-022, T-023 |
| REQ-015 | T-019, T-020, T-021 |
| REQ-016 | T-019, T-025 |
| REQ-017 | T-017, T-019, T-025 |
| REQ-018 | T-024 |
