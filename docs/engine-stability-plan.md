# Engine stability, plugin hosting and audio device settings

Implementation plan for these TODO.md items: Audio Engine › Audio Thread, "Make sample rate and
buffer size configurable", Devices & Plugins › "Crash / Error handling" and "Improve logging of
plugins". It also sets up "Plugin latency compensation".

## Checklist

- [x] Phase 0: Measurement (load peaks, xruns, lock misses, an allocation checker). Baseline numbers still to record
- [x] Phase 1: Audio thread hygiene (RT priority and memlock moved to Phase 8). Needs an `rt-debug` live run
- [x] Phase 2: Plugin host control channel (Unix socket, reader thread, one protocol module). Needs a live knob-move check
- [x] Phase 3: Synchronous plugin processing (per-block handshake over shared memory)
- [x] Phase 4: Plugin crash detection and recovery
- [x] Phase 5: Plugin hosting modes (together, by vendor, by plug-in, individually; within engine skipped). Needs a Godot UI check
- [x] Phase 6: Plugin debuggability (logs, stats, probe mode, debugger wrapper). Needs a Godot UI check
- [x] Phase 7: Audio device settings (device, sample rate, buffer size, from the UI). Needs a Godot UI check and a forced-quantum run
- [ ] Phase 8: Later work (lock-free engine state, CPU affinity, latency compensation)

Do the phases in order unless the dependency notes say otherwise. This plan is the design: no separate specs.
When a phase has to deviate from it, update this file first. Phase 3 must already implement the
per-instance addressing and doorbell that Phase 5 relies on.

After each engine phase, run `cargo test` from `Engine/`, then `./test_osc.sh` and
`./test_plugin_osc.sh` against a release build. After each Godot phase, run
`Godot/tests/run_all.sh`. Mark TODO items `[x?]` when a phase is done and `[x]` only after a live
check.

## Dependencies

```
0 ──> 1 ──> 2 ──> 3 ──> 4 ──> 5 ──> 6
      │           │
      └─────> 7 <─┘  (7 needs 3's deactivate/activate path to change a plugin's sample rate)
```

Phase 5 needs Phase 4: changing the hosting mode respawns plugins and restores their state
through the same reload path that crash recovery uses.

Phase 0 comes first because everything after it needs before-and-after numbers. Phase 7 can
start after Phase 1 if the settings UI is more urgent. In that case, CLAP plugins are respawned
(not re-activated) on a sample-rate change until Phase 3 exists.

## What already exists (don't rebuild it)

| File | What it does now |
|---|---|
| `Engine/src/audio/engine.rs` | Opens one cpal output stream on the **default** device. `PREFERRED_SAMPLE_RATE` (48 kHz) and `PREFERRED_BUFFER_FRAMES` (1024) are constants. A watchdog thread restarts the stream if callbacks stall (`CALLBACK_STALL_TIMEOUT`). `lock_state_for_callback` does a bounded `try_lock` (`STATE_LOCK_BUDGET` = 1 ms) and outputs silence on failure. Sends an **average** `EngineStatus::EngineLoad` once per interval. |
| `Engine/src/audio/command_worker.rs` | Applies `AudioCommand`s and does slow work (scan, device create/drop, plugin IPC) with the state lock released. This is where reconfiguration work belongs. |
| `Engine/src/audio/devices/factory.rs` | `DeviceFactory` builds devices with a fixed `sample_rate` and `max_buffer_size`. `AudioDevice` has no `prepare(sample_rate, max_frames)`, so a device only learns its rate at construction. |
| `Engine/src/audio/io/decoder.rs` | Clips are decoded and resampled **to the device rate** at load time, so a rate change means reloading clip PCM. |
| `Engine/src/audio/ipc/` | `ProcessManager` (one subprocess per plugin, TCP control socket per process from a port allocator starting at 9000, memfd passed over a Unix socket). `shared_memory.rs` holds SPSC audio and MIDI ring buffers. `protocol.rs` defines `PluginCommand`/`PluginResponse` as JSON lines. It already has `SaveState`/`LoadState`. |
| `Engine/src/plugin_host/` | The subprocess. `protocol.rs` is a **second copy** of the IPC types. `event_loop.rs` runs one loop that does commands, audio, timers, GUI callbacks and parameter echo, and sleeps 1 ms when idle. |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/` | `AudioDevice` for CLAP. `LoadingState` sits behind a `Mutex` that the audio thread `try_lock`s. |
| `Godot/editor/EnginePanel.gd` | Engine load graph fed by `/status/engine_load`. Extend it; don't add a second panel. |
| `Godot/settings/Settings.gd` | Settings registry. It already has `CATEGORY_AUDIO` but no settings are registered in it. `.scene(path)` allows a custom control scene. |

## Problems this plan fixes

**Plugin audio is not synchronous.** `SubprocessClapAdapter::process_block` writes input to the
ring buffer and reads back whatever output happens to be there. The subprocess polls with a 1 ms
sleep and processes chunks of 64 to 512 frames, whatever is available (`plugin_host/state.rs`).
Consequences:
- Output latency is variable and at least one block. When the subprocess is late, the adapter
  zero-fills the output, which is audible as crackles.
- MIDI `sample_offset` is relative to the engine's block, but the subprocess processes different
  chunks, so plugin MIDI isn't sample-accurate.
- Every plugin in a chain adds its own latency, so latency compensation can't be done.

**The plugin host is single-threaded.** GUI callbacks, timers, `params.flush()` and parameter
echo share the loop with audio processing, so a slow GUI frame delays audio. Each
parameter-change echo calls `get_info` on every parameter to map a CLAP id to an index (O(n) per
change).

**The audio thread does syscalls and allocates.** `mixing.rs` calls
`poll_parameter_changes()`, which calls `set_read_timeout` (a syscall), reads the socket and
parses JSON into a new `Vec`, once per CLAP device per buffer. The other items listed in TODO.md
are still open too: unbounded status sends, the sleep-change `Vec`, and the String clone in
`audio_playback_positions`.

**No scheduling guarantees.** Neither the audio callback nor the plugin host runs with RT
priority, and memory isn't locked.

**No visibility.** The UI shows only average load. Xruns, lock misses, per-plugin process time and
missed deadlines aren't counted anywhere.

**Output device and rate are fixed.** Channel IDs 1000+ are assigned to every enumerated device,
but the stream always opens the default one. A master routed to 1001 plays nothing different.

---

## Phase 0: Measurement

Goal: numbers for every later phase, and a tool that catches allocations on the audio thread.

1. Add a new `EngineStatus::EngineStats` with these fields: `load_avg`, `load_peak` (worst
   single block in the interval), `xruns`, `lock_misses` (silence from
   `lock_state_for_callback`), `callbacks`, `frames` (last block size).
   - Count xruns from the cpal error callback and from callback gaps longer than 1.5× the block
     duration.
   - Send it at 2 Hz on `/status/engine_stats` and keep `/status/engine_load` until Godot
     switches over.
   - Update `OSC_PROTOCOL.md`.
2. Show peak load, xruns and lock misses in `EnginePanel.gd` next to the existing graph.
3. Add the `assert_no_alloc` crate behind a `rt-debug` cargo feature and wrap the callback body
   in `assert_no_alloc(|| …)`. Log violations rather than aborting, so they can be found without
   crashing. Look up the crate API with Context7 before starting.
4. Add a benchmark project and scenario: 8 CLAP instances (Dragonfly Hall on a bus, plus
   instruments), 4 audio clips, playback for 60 s. Record baseline numbers in **Measurements**
   below.

Verify: with `--features rt-debug`, the benchmark project logs the known allocations
(`poll_parameter_changes` among them). The numbers appear in the panel and in the table.

As built (differences from the steps above):
- Godot switched to `/status/engine_stats` in the same change, so `EngineStatus::EngineLoad` and
  `/status/engine_load` were removed rather than kept alongside.
- `xruns`, `lock_misses` and `callbacks` are running totals (in shared atomics, so they survive a
  watchdog stream restart), sent as OSC int32. Per-minute rates are the difference between two
  reports. godOSC's int64 (`h`) decoding is unreliable, which is why they aren't sent as longs.
- cpal 0.15's ALSA backend recovers underruns silently (`TODO: Notify the user` in its source),
  so the error callback rarely fires and the 1.5× gap check is the real xrun signal.
- Blind spot: underruns inside PipeWire's ALSA layer don't reach the engine at all. On
  2026-09-24 a runtime `clock.force-quantum = 1488` made the graph cycle larger than the engine's
  1024-frame buffer. Audio crackled constantly while the panel showed 0 xruns, and only `pw-top`'s
  ERR column on the sink showed it. Phase 7 step 7 makes the engine detect this.
- Load depends heavily on the graph quantum. The same project showed 17% avg / 22% peak at a
  1488-frame quantum and 50% / 80% at 256 frames, the quantum the engine itself requests (cpal
  asks for periods of a quarter of the 1024-frame buffer). Fixed per-block costs such as per-plugin
  IPC dominate at small blocks. Record the quantum (`frames`) in every Measurements row.
- `assert_no_alloc` is used with default features off plus `warn_release`/`warn_debug`: its
  default makes it a no-op in release builds. It only counts per thread, so
  `audio/rt_debug.rs` adds named `section`s that attribute violations to regions of the callback
  and logs them (WARN) at 2 Hz. `SONARA_FEATURES=rt-debug ./run_release.sh` builds with it.
- The OSC status thread logs one INFO line per minute with load avg, load peak, xruns/min and lock
  misses/min, ready to copy into **Measurements**.

### Benchmark scenario

Built from plugins in `~/.clap`. Save it as `benchmark.sonara` (outside the repo, since it
references local plugin paths) and use it unchanged for every row of **Measurements**.

- 4 instrument channels, each playing a looping 8-bar MIDI clip with chords (8+ voices):
  2× LibreStrings, 1× polysynth, 1× sfizz with an SFZ instrument.
- 2 of those instrument channels also get a CLAP insert: an LSP compressor and an LSP EQ.
- 4 audio channels with a looping audio clip each (stereo, ≥ 30 s long, at least one at 44.1 kHz
  so resampling is in play).
- 1 bus "Reverb" with Dragonfly Hall Reverb; every channel sends to it.
- 1 bus "Room" with Dragonfly Room Reverb; the audio channels route to it.
- Master: Dragonfly Plate Reverb (low mix) and an LSP limiter.

That's 8 CLAP instances (2 LibreStrings, 2 on inserts, 3 Dragonfly, 1 limiter). To measure: start
the engine fresh, open the project, press play, wait for two `Engine stats` lines in
`Engine/logs/last_info.log`, and record the second one. Then repeat with one Dragonfly GUI open
and note it as a separate row ("… + GUI"), since GUI work shares the plugin host's loop until
Phase 3.

## Phase 1: Audio thread hygiene and RT priority

Goal: the callback does no allocation, no syscalls and no blocking.

1. Take `poll_parameter_changes` off the audio thread. As an interim fix until Phase 2, run it
   on the command thread on a 20 ms tick and forward the changes as `EngineStatus`. Remove the
   call in `mixing.rs`.
2. Bound the status channel (`crossbeam::channel::bounded`, sized for about 1 s of statuses) and
   switch the audio-thread sends to `try_send`. Meter and playhead statuses may be dropped when
   the channel is full. Loading and error statuses never come from the callback.
3. Fix the remaining allocations TODO.md lists:
   - Preallocate the sleep-change list in `RenderScratch`.
   - Key `audio_playback_positions` by clip-instance id (integer) instead of `String`, or
     preallocate it.
   - Check the "removed, needs live verification" items with the Phase 0 checker.
4. RT priority:
   - Give the callback thread `SCHED_FIFO` with rtkit as the fallback. Check with Context7
     whether cpal 0.15's ALSA backend (or its `audio_thread_priority` feature) already does this
     before writing it ourselves.
   - Call `mlockall(MCL_CURRENT | MCL_FUTURE)` at startup.
   - Log once at startup whether RT priority and memlock were granted, and report it in
     `EngineStats`, since `/etc/security/limits.d` is often missing.
5. Replace `LoadingState`'s `Mutex` with an atomic state plus a pointer the audio thread can read
   without locking (`arc-swap` or an `AtomicU8` plus a preset `Arc<SharedMemory>`). This removes
   the `try_lock` in `process_block` and in `send_midi_event`.

Verify: `rt-debug` run of the benchmark project reports zero allocations. Lock misses and xruns
are no worse than baseline. The startup log shows RT granted.

As built (2026-09-24):
- **Step 4 (RT priority, `mlockall`) is deferred to Phase 8** by decision: stability and
  correctness come first. Findings for when it's picked up: cpal 0.15 can't promote the thread
  (0.17 has `audio_thread_priority`, 0.18 `realtime-dbus`); on the dev machine `ulimit -r` is 0,
  so only rtkit works, and the D-Bus dev headers that Mozilla's `audio_thread_priority` crate
  needs aren't installed. `RLIMIT_MEMLOCK` is finite (~3.8 GB), and with `MCL_FUTURE` any
  allocation past it aborts the engine, so only use `MCL_FUTURE` when the limit is unlimited.
- **Command-thread device tick** (`CommandWorker::poll_devices`, every 20 ms between commands):
  polls CLAP parameter changes, sends queued automation writes, detects dead plugin subprocesses
  (marks them failed and tells Godot), forwards SFZ parameter lists, and logs per-plugin audio
  problems every 10 s. It holds the state lock only to collect handles.
- **`LoadingState`** is now `PluginLoad`: an `AtomicU8` state plus a `OnceLock<Arc<SharedMemory>>`.
  The CLAP adapter's `process_block` and `send_midi_event` no longer lock, log or do IPC; problems
  are counted and reported by the tick.
- **Found beyond the TODO list:**
  - Automation called CLAP `get_parameter` from the callback, a blocking IPC round trip with a
    100 ms timeout, and `set_parameter_at` wrote to the socket. `get_parameter` now reads a value
    cache and `set_parameter_at` queues for the tick (≤ 20 ms late until Phase 3).
  - `visit_devices_mut` allocated a `DevicePath` (`Vec`) per device per buffer. `DevicePath` is now
    an inline `Copy` array with `MAX_DEVICE_DEPTH` = 8, enforced on parse and insert.
  - `poll_parameter_changes` left a 100 µs read timeout on the plugin socket, so later blocking
    requests (GUI open, activate) could time out. Each receive now sets its own timeout, and
    `try_recv_response` queues synchronous replies instead of dropping them.
- Sleep changes go into a per-channel preallocated list. Clip read positions moved onto
  `ClipInstance::playback_position` (no map, no `String` key).
- The status channel is bounded (8192, ~1.6 MB). The callback uses `try_send`, and so does the log
  forwarder: the status thread also logs, so a blocking send there could deadlock.
- `EngineStats` gained `plugin_underruns` (CLAP blocks padded with silence, i.e. plugin dropouts),
  shown in `EnginePanel` and in the per-minute log line. This fills the Measurements column.
- Known left: `poll_device_data` (spectrum analyzer) allocates its payload while subscribed.
  `rt-debug` attributes it to the `poll_device_data` section.

## Phase 2: Plugin host control channel

Goal: control traffic never touches the audio thread, and a request never holds a process lock
for seconds.

1. Merge `audio/ipc/protocol.rs` and `plugin_host/protocol.rs` into one module that both binaries
   use through `lib.rs`.
2. Replace the TCP socket and port allocator with a Unix `socketpair`. The memfd can travel over
   that same socket.
3. Frame messages with a length prefix and encode them with `postcard` or `bincode` instead of
   JSON lines. Keep a `SONARA_IPC_TRACE=1` env var that logs every message decoded as `Debug`.
4. Give each `PluginProcess` a dedicated reader thread.
   - Responses carry a `request_id` and complete a waiting request, each with a timeout.
   - Unsolicited messages (parameter changes, GUI resize, log lines) go to a channel that the
     command thread drains.
   - `PluginProcess` no longer needs a `Mutex` for reads.
5. In the host, build a `clap_id → index` map once after `GetParameterInfo`. Invalidate it on
   `rescan`. This replaces the O(n) scan per change.
6. Address plugin **instances**, not processes.
   - Every command, response and unsolicited message carries an `instance_id`.
   - `ProcessManager` maps a host key to a host process, and an `instance_id` to its host.
   - Every host still holds one instance until Phase 5. Getting the addressing right now keeps
     Phase 5 from being a protocol break.

Verify: `test_plugin_osc.sh` passes. Open a plugin GUI and move a knob: the value reaches Godot.
Opening a GUI doesn't produce lock misses (Phase 0 counter).

As built (2026-09-25):
- **Protocol** is `audio/ipc/protocol.rs`; `plugin_host/protocol.rs` and `plugin_host/ipc_utils.rs`
  are gone. Envelopes: `HostRequest { instance_id, request_id, command }` engine → host, and
  `HostMessage::Response { instance_id, request_id, response }` / `HostMessage::Event { instance_id,
  event }` host → engine. The unsolicited variants moved out of `PluginResponse` into
  `PluginEvent`. `request_id` 0 (`NO_REPLY`) is fire-and-forget; the engine logs any `Error` the host
  returns for one. `LoadState`/`StateSaved` carry `Vec<u8>` instead of base64 (neither is implemented
  in the host yet).
- **Wire** (`audio/ipc/wire.rs`): `u32` LE length + **bincode 1** (already a dependency, so no
  `postcard`), 256 MB frame limit. File descriptors ride on a frame as `SCM_RIGHTS` via
  `sendmsg`/`recvmsg`, so the memfd comes with `Initialize` instead of a separate handshake, and
  readers never buffer past a frame. `SONARA_IPC_TRACE=1` logs every frame on both sides.
- **Socket**: `UnixStream::pair()`; the host gets its end as descriptor 3 (its only argument) and
  sets close-on-exec on it again, so processes a plugin spawns don't keep the socket open.
- **Engine side**: `PluginProcess` has a reader thread that completes waiting requests by
  `request_id` (reply slot is a `bounded(1)` channel; timeout removes the slot, a late reply is
  dropped) and routes events to a per-instance channel that `CommandWorker::poll_devices` drains.
  Writes hold a mutex only for the write. When the socket closes, every waiting request fails at
  once and the next tick marks the plugin failed. The 5 s `start_monitoring` thread was removed.
- Plugin GUI resize requests now reach the window (`PluginEvent::GuiResizeRequest` →
  `EngineStatus::PluginGuiResizeRequest`); before, `poll_parameter_changes` dropped them.
- **Host side**: a reader thread feeds requests to the main loop over a channel; the main loop is
  the only writer and waits on that channel for 1 ms when idle instead of sleeping. The merged loop
  otherwise stays until Phase 3.
- **Parameter map** (`plugin_host/state.rs` `ParamMap`): engine index ↔ CLAP id and range, built on
  `GetParameterInfo` (or first use) and used by echo, `SetParameter` and `GetParameter`. The host
  now registers `HostParams`: `rescan` with INFO or ALL drops the map, and `request_flush` triggers a
  flush while no GUI is open. The engine isn't told the parameter list changed; that needs its own
  status.
- **Instances**: `ProcessManager::allocate_instance_id()` per adapter, replacing the device-path
  `process_key` (which could collide when devices moved). `ProcessManager` maps host key → host and
  instance id → `InstanceConnection`; `spawn_instance` reuses a live host for its key. The key is
  `instance-<id>` until Phase 5. A host rejects a second `Initialize`. A host counts as in use while
  any instance's event route is registered, so one still loading keeps it alive.
- Host shutdown is bounded (Phase 4 step 5, done early): `Shutdown`, then `SIGKILL` after 1 s.
- Tests: `wire.rs` (framing, large frames, fd passing, EOF) and `process_manager.rs` (out-of-order
  replies, timeout + late reply, event routing, host exit) against an in-process fake host.
- Live check: Dragonfly Room loads over the new channel (spawn to ready ~8 ms, where the old path
  slept 100 ms). Parameter set + echo, GUI open/close, device removal (host exits in ~10 ms) and
  `kill -9` of the host (bypassed within one tick, engine keeps running) all work, with 0 lock
  misses. **Still to check by hand:** move a knob in a plugin GUI and see the value in Godot.
- `test_osc.sh` and `test_plugin_osc.sh` are stale: they use removed addresses (`/sine/*`), the old
  `/project/init` arguments and `add_device` without the `clap` type and file, so they exit 0 without
  loading a plugin. The live check above sent the current messages by hand.

## Phase 3: Synchronous plugin processing

Goal: a plugin processes exactly the engine's block, with sample-accurate events, inside a
deadline. A missed deadline costs one block of silence for that plugin, never the whole engine.

Design (settle the open details while implementing and record them here):

- **Shared memory layout** per plugin instance:
  - a control header;
  - planar input and output buffers sized `max_frames × max_channels`, which also makes room
    for the multi-out ports TODO.md wants;
  - an input event array (notes, parameter changes with `sample_offset`, transport);
  - an output event array (parameter changes from the plugin, note output).

  This replaces the three ring buffers. A host process also has one shared **doorbell** word
  that the engine rings for any of its instances (needed for Phase 5).
- **Handshake**:
  1. The engine writes the instance's block and events, stores the instance's
     `request_seq += 1`, and rings the host's doorbell with `futex_wake`. eventfd would also
     work; **futex is used** (`audio/ipc/futex.rs`), because it needs no extra descriptor and
     the host already maps the doorbell region.
  2. The host's audio thread wakes and processes every instance whose `request_seq` is ahead of
     its `done_seq`.
  3. The engine spins briefly, then `futex_wait`s until `done_seq == request_seq` or the
     deadline passes.
  4. On success it copies the output and applies the output events.

  On timeout it outputs silence (instrument) or dry input (effect) and increments the plugin's
  overrun counter. The late result is discarded by sequence number.
- **Deadline**: one absolute deadline per callback, not a share per plugin. Every plugin wait in
  the callback is against callback start + a fraction of the block time (start at 70%,
  configurable). Fixed per-plugin shares would cut off a slow plugin while fast ones leave their
  time unused. After N consecutive misses, the plugin is flagged in the UI (Phase 6 stats).
- **Room for parallelism**: requests are "start" and "wait" as two separate steps, so the engine
  can later start several independent instances before waiting on any of them (Phase 8). Don't
  build it now, but don't design it out.
- **Host threads** follow CLAP's threading model:
  - one RT audio thread per host process that waits on the doorbell and calls `process()` for
    each ready instance;
  - the main thread for commands, GUI, timers, `on_main_thread` and `params.flush()` when not
    processing.

  The `event_loop.rs` merged loop goes away.
- **Adapter**: `process_block` does the handshake. `send_midi_event` and a new
  `set_parameter_at` write into the input event array, so CLAP automation becomes
  sample-accurate.
- **Latency**: query the CLAP latency extension at activation and expose it on `AudioDevice` (a
  `latency_frames()` default method returning 0). Phase 8's latency compensation uses it.
- **Sample-rate and block-size change**: deactivate → activate with the new values on the command
  thread. Phase 7 needs this.

Alternative considered and rejected: keep async processing with a fixed one-block delay and
report it as latency. It's simpler, but latency adds up across chains and doesn't fix
GUI-induced stalls.

Verify:
- A unit test of the handshake runs against an in-process fake host (a thread standing in for
  the subprocess), including the timeout path.
- Live: the benchmark project plays without crackles, overruns stay 0, and a clip playing through
  a plugin null-tests against the same audio with the plugin bypassed.
- A MIDI note at a known offset shows up at the same sample in the output.

As built (2026-09-25):
- **Doors, not eventfd.** The engine rings a host with `futex_wake` on one `u32` in a per-host
  `HostSharedMemory` region; eventfd would need another descriptor and an extra `read`. The
  region is the host's descriptor 4 (`HOST_SHARED_MEMORY_FD`), passed at spawn next to the
  control socket (3), so Phase 5's shared hosts already have their one doorbell.
- **Shared block replaced the three ring buffers.** `SharedMemoryLayout` is now
  `max_frames × max_channels` planar input, the same for output, an input and an output event
  array (`MAX_BLOCK_EVENTS` = 256 `BlockEvent`s each, 16 bytes: `sample_offset`, `kind`, `note`,
  `value`, `id`) and a `BlockControl`. `BlockControl` carries
  `request_seq`/`done_seq`/`input_frames`/`output_frames`/event counts/`status`; the two sequence
  numbers are the only `Release`/`Acquire` pair that orders everything else. `AudioRingBuffer`,
  `MidiEventQueue`, `ControlData`, `RingBufferStats` and `MidiEvent` are gone.
- **Handshake.** Engine: finish any outstanding request (discard its output), write input planes
  and events, `request_seq += 1` (Release), ring. Host: wake, process exactly that block, write
  output planes and output events, `done_seq = request_seq` (Release), ring back. Engine: spin
  `HANDSHAKE_SPIN_ITERATIONS` = 400 times, then `futex_wait` with the doorbell word read before
  the last `done_seq` check (no lost wakeup).
- **Deadline.** `audio/block_clock.rs` publishes one absolute deadline per callback (the engine
  callback calls `publish(processing_start, block_duration)`; default fraction 0.7, overridable
  with `SONARA_PLUGIN_DEADLINE_FRACTION`, clamped to 0.1–0.95). All adapters read it, so a slow
  plugin cannot borrow time from the next one.
- **Late results.** On a deadline miss, audio passes through and `deadline_misses` /
  `PLUGIN_UNDERRUNS` increase. The next block first waits for the outstanding request and
  discards its output, then publishes its own; buffers are never reused while the host reads
  them. Eight consecutive misses log a WARN (Phase 6 turns this into UI state).
- **Events are staged, then published.** Deviation from the design above: `send_midi_event` and
  `set_parameter_at` **do not** write the shared array directly. They append to an adapter-local
  preallocated list, and `process_block` copies it into the shared array just before publishing.
  Writing from the setters would race with the host reading the previous block's array, and would
  replay stale events after a miss. Offsets are unchanged, so automation is still sample-accurate.
- **Host threads.** `plugin_host/audio_thread.rs` runs the doorbell loop and owns the
  `PluginAudioProcessor` and the block; `event_loop.rs` keeps the main thread for commands, GUI,
  timers and `params.flush`. The processor moves between them over a command channel
  (`SetProcessor`/`TakeProcessor`); `PluginInstance` stays on the main thread (it is `!Send`).
  Activate builds the processor, hands it over and releases the main thread; Deactivate takes it
  back and calls `instance.deactivate`.
- **Parameter changes while processing** are queued to the audio thread (applied at offset 0 of
  the next block) instead of `params.flush()` on the main thread; while stopped they still use
  `flush` so edits apply immediately. The plugin's own output parameter changes come back in the
  block's output event array (engine parameter index, normalized) and the command thread reports
  them — no socket round trip.
- **Latency**: `PluginLatency` is queried after activation and returned in
  `PluginResponse::ActivateResult { latency_frames }`; `PluginLoad` caches it and
  `AudioDevice::latency_frames()` (default 0) exposes it for Phase 8. `HostLatency` is registered
  so plugins can report changes.
- **Sample-rate change**: `PluginCommand::Activate { sample_rate }` deactivates first when the
  rate differs, so Phase 7's `prepare` can reuse it. A block-size change still needs a new
  `Initialize` because the shared block is sized there; Phase 7 step 2 owns that.
- **`StartProcessing`/`StopProcessing`** remain as commands but no longer gate processing: the
  audio thread processes exactly the blocks the engine publishes while the plugin is activated.
  `Reset` moved to the audio thread (CLAP calls it there) and only clears state and queued events.
- **Found beyond the plan:** the host main loop busy-spun at 100% CPU because servicing the
  plugin side always marked the iteration busy; it now always blocks on the request channel for
  1 ms. `StartProcessing` after `Activate` was already the case, so lifecycle's extra
  `StartProcessing` is now redundant (kept for compatibility).
- Tests: `subprocess_adapter` has three tests against an in-process fake host — block round trip
  is sample-exact, a late host costs exactly one block and its result is discarded, and
  notes/automation reach the host with their `sample_offset`. `shared_memory`, `futex` and
  `block_clock` have their own unit tests.
- Live check (2026-09-25, 1024-frame setting → 1488-frame graph quantum): 5 CLAP instances
  (2 Dragonfly reverbs, LSP compressor, LSP limiter, LibreStrings) loaded into 5 hosts, 60 s of
  playback: `load avg 4.0%, peak 17.4%, xruns 0, lock misses 0, plugin dropouts 0`, no WARN
  lines. Each host logs `Using doorbell FD 4` and maps the instance block at fd 6; a parameter
  change during playback was queued to the audio thread and echoed back.
- **Not verified live:** the audible null test (no capture path on the dev machine), MIDI
  sample-accuracy end to end (unit-tested at the block level only), sample-rate change (needs
  Phase 7's UI), and the Phase 2 GUI knob → Godot check.
- `./test_osc.sh` and `./test_plugin_osc.sh` still exit 0 without loading a plugin (stale
  addresses and an `add_device` call without the `clap` type and file), so they prove only that
  the engine survives them. The live checks above sent the current messages by hand.

## Phase 4: Crash detection and recovery

1. Watch each child with a `pidfd` (or `waitpid` on a watcher thread). On exit, set the atomic
   state to `Crashed { signal, exit_code }` and send a status with the reason and the last 20
   lines of the host's stderr, captured through a pipe.
2. The audio thread sees `Crashed` and passes audio through (or outputs silence for an
   instrument) without touching IPC.
3. Add a new OSC message `/device/reload` that respawns the host and restores its state. Use the
   last `SaveState` blob, which the adapter refreshes on project save and periodically (e.g.
   every 30 s while dirty). The device UI shows a crashed state with a Reload button.
4. Every blocking request has a timeout. A hung host (no response in 5 s, or N consecutive
   overruns while not processing) is killed and treated as crashed.
5. Shutdown: send `Shutdown`, wait a short grace period, then `SIGKILL`. No orphaned hosts after
   the engine exits (the host already exits when the socket closes; keep it that way).
6. A crash affects every instance in the host. Build the crash state and Reload per host
   process, not per device, even though each host holds one instance until Phase 5.

Verify: `kill -SEGV` a running host during playback. The engine keeps playing, the UI shows the
crash, and Reload brings the plugin back with its parameters.

As built (2026-09-25):
- **Crash state is per host process**, as the plan asks. `HostCrash { host_key, pid, exit,
  stderr_tail }` lives on `PluginProcess`; `PluginLoad` gained a `CRASHED` variant, distinct from
  `FAILED`, so the audio thread passes audio through (it only touches the block while `READY`) and
  the device can be reloaded. `CommandWorker::poll_devices` is the only reporter, so the crash
  status is sent once per device.
- **Watching (step 1).** One watcher thread per host polls a `pidfd` (`SYS_pidfd_open`, falling
  back to a 20 ms sleep when the syscall is unavailable) and reaps the child with `try_wait`, so
  `HostExit` carries both the signal and the exit code. A second thread drains stderr into a
  bounded 20-line ring (reads capped at 4 KiB, so an unterminated line can't grow the buffer). The
  command thread never calls `wait()`; `PluginProcess::shutdown` waits on the watcher's recorded
  exit instead.
- **Status (step 1).** New OSC `<device addr>/crashed [reason:s, stderr:s, pid:i]` next to the
  existing `<device addr>/loading_state`, which now carries `"crashed:<reason>"`. **Deviation:**
  reload is the device-addressed action `<device addr>/reload`, not the plan's global
  `/device/reload`, because every other device command is addressed that way. The engine also
  logs the reason and the host's stderr tail.
- **Reload (step 3).** `PluginCommand::SaveState`/`LoadState` are now implemented in the host
  (CLAP's state extension, main thread) and the `HostState` extension is registered so `mark_dirty`
  reaches the engine. `PluginLoadRequest` is shared by the first load and the reload: the reload
  shuts the crashed instance down, spawns a host for the same instance id, restores the last blob,
  activates, and sends `DeviceReady` to re-advertise the parameter list. When the blob restored,
  it is authoritative: the host reads every parameter back (`GetParameter`) and `DeviceReady`
  carries the values, which the engine caches and reports to Godot after the list (Godot resets
  values to defaults when a list arrives). Only without a blob, or when `LoadState` fails, does
  it **re-send the engine's cached parameter values**, so plugins without a state extension still
  come back with their parameters. The first version always re-sent the cache, which overwrote
  changes the plugin made without reporting them (a preset loaded in its GUI). A fresh `PluginLoad` is installed under the state lock, so the audio thread keeps
  passing audio through until the new host is ready. It runs on a background thread.
- **State blobs (step 3).** The adapter marks its blob dirty on `mark_dirty` or any parameter
  change (the host reports `mark_dirty` once per saved blob; `SaveState` re-arms it) and the command thread refreshes it at most once per 30 s; `/plugin/save_state` and
  `/plugin/load_state` are implemented too (they were empty stubs). `PluginLoadRequest.alive` is
  cleared by the adapter's `Drop`, so a load or reload in flight for a removed device shuts its
  host down instead of orphaning it.
- **Timeouts (step 4).** `REQUEST_TIMEOUT` is now 5 s (10 s before). A request that times out
  marks the host hung, and so does a published block that stays unfinished (`done_seq` doesn't
  move while a request is outstanding) for `HUNG_STALL_TIMEOUT` = 1 s of wall time; either makes
  the command thread `SIGKILL` the host and treat it as crashed on the next tick. The first
  version counted 32 consecutive missed deadlines instead, which also killed plugins that were
  only slower than their share of the shared deadline (they miss every block but finish each one
  late) and scaled with the buffer size (43 ms at 64 frames). A slow plugin now only drops out.
- **Shutdown (step 5).** Unchanged in shape: `Shutdown`, 1 s grace, `SIGKILL`; the watcher reaps,
  and `Drop` kills without waiting (no zombie, no orphan). The host still exits when the control
  socket closes.
- **For Phase 5:** the reload path (and `mark_plugin_crashed`) already talks about host processes,
  but one host holds exactly one instance until Phase 5, so `shutdown_instance` may shut the whole
  host down. When hosts are shared, reload has to re-initialise only the crashed instance (the
  protocol already addresses instances, so no wire change is needed).
- Engine tests: crash exit code + stderr tail from a real `/bin/sh` child, bounded stderr ring,
  hung flag on request timeout, `PluginLoad::CRASHED` passing audio through, `begin_reload`'s
  request contents and the 30 s state-save throttle.
- Godot: `PopupMessage.tscn` (title, scrollable body, Copy, Close, caller-supplied action buttons)
  instanced in `Editor.tscn`; `DeviceInstance` gains a `crashed` signal, a `reload()` that sends
  `<device addr>/reload`, and shows the popup with a Reload button; `DevicePanel` shows a Reload
  button while crashed; `DeviceLightButton` draws the crashed state red.
- **Live check (2026-09-25).** Dragonfly Room Reverb loaded into its own host on channel 2 and
  playing (`/transport/play`): `kill -SEGV <host pid>` while playing. The engine stayed up
  (playhead kept advancing, `load avg` fell from ~12% to ~2.7% as the plugin was bypassed, 4
  plugin dropouts, 0 xruns, 0 lock misses), logged the crash 5 ms after the socket closed, and
  sent `/log` + `loading_state "crashed:killed by signal 11 (SIGSEGV)"` +
  `/crashed "killed by signal 11 (SIGSEGV)" "" 1036847`. Sending `/channel/2/device/0/reload`
  spawned a new host (new pid), reported `loading` → `ready`, re-advertised all 17 parameters and
  re-sent `param/4/value 0.5` — the value the user had set before the crash. Stopping the engine
  left no `plugin_host` process behind.
- **Live check: hung host (2026-09-25).** Same setup, but `kill -STOP <host pid>` instead: the
  plugin missed 8 deadlines (WARN), then 32 in a row → the command thread logged
  `missed 32 deadlines in a row; killing its host` (now: `hasn't finished a block in 1s`), `SIGKILL`ed it and marked the device crashed
  (`killed by signal 9 (SIGKILL)`). `/reload` brought it back on a new pid with all 17 parameters.
  The first attempt exposed a real bug this check caught: the new host inherited the dead host's
  `consecutive_misses`, so the hung-host check killed it 20 ms after it came up. `begin_reload`
  now clears the miss counters (asserted in the reload unit test).
- **Live check: full state round trip (2026-09-25).** Loaded the same plugin, changed `Size`, waited
  past the 30 s interval → `Refreshed saved state of plugin ... (350 bytes)`. After `kill -SEGV`
  the reload logged `Restored 350 bytes of plugin state`, activated on a new pid and stayed up.
- **Not verified:** nothing in Godot calls `/plugin/save_state` or `/plugin/load_state` yet (the
  project file doesn't persist plugin state), and the plugin GUI knob → Godot check from Phase 2 is
  still open.
- `./test_osc.sh` and `./test_plugin_osc.sh` still exit 0 without loading a plugin (the staleness
  noted in Phase 2), so they only prove the engine survives them.

## Phase 5: Plugin hosting modes

Goal: the user chooses how plugins are grouped into host processes, trading isolation for
performance, as Bitwig does.

| Mode | Host key | What goes in each host process |
|---|---|---|
| Within engine | none | Nothing. The plugin runs inside the engine process |
| Together | `"all"` | All plugins |
| By vendor | vendor string | Every plugin from one vendor |
| By plug-in | plugin id | Every instance of one plugin |
| Individually | unique per instance | One instance (the current behavior) |

1. When a plugin loads, `ProcessManager` computes the host key from the mode. It reuses a live
   host with that key or spawns a new one. Instances then load into that host by `instance_id`
   (Phase 2 addressing, Phase 3 doorbell).
2. Add the setting `plugins/hosting_mode` (CHOICE) in `Settings.gd`, default **Individually**.
   Revisit the default with Phase 0 numbers: if many instances cost real CPU in context
   switches, switch to **By plug-in**. When one instance of a plugin crashes, the others usually
   have the same bug, so grouping them loses little isolation.
3. A per-plugin override ("always host this plugin individually"), stored by plugin id and set
   from the device context menu. It wins over the global mode. This helps with plugins known to
   crash.
4. Changing the mode, globally or for one plugin, applies live. Every affected instance is saved,
   respawned under its new host key, and restored, using the Phase 4 reload path.
5. **Within engine** comes last and is marked in the UI as the risky option, since a plugin crash
   takes the engine down with it.
   - Start from the unused in-process adapter in `clap_host/adapter.rs`. Bring it up to the
     Phase 3 event handling (sample-accurate notes and parameters, output events, latency).
   - Its GUIs must run on the `WindowManager` thread.
   - Skip this mode entirely if the other four cover the need.
6. Show each device's host (mode and pid) in the device header tooltip, next to the Phase 6
   stats.

Verify:
- With "Together", a project with 8 plugins runs one `plugin_host` process (`pgrep -c plugin_host`).
- With "By plug-in", two instances of the same plugin share a host and a third plugin gets its
  own.
- Switching modes during playback keeps every plugin's parameters.
- `kill -SEGV` on a shared host marks every instance in it as crashed, and Reload restores all
  of them.
- Compare Phase 0 numbers between "Individually" and "Together" on the benchmark project and
  record them in **Measurements**.

As built (2026-09-25):
- **Policy** (`audio/ipc/hosting.rs`): `HostingMode` {Together, ByVendor, ByPlugin, Individually}
  and `HostingPolicy` (global mode + overrides by plugin id). `assign(plugin_id, vendor,
  instance_id)` returns a `HostAssignment` (mode + key): `all`, `vendor:<vendor>`, `plugin:<id>` or
  `instance-<id>`. `ProcessManager` holds the policy; the adapter takes its assignment at
  construction and keeps it.
- **Vendor.** The adapter used to report "Unknown". `CommandWorker::add_device` now asks
  `PluginScanner::vendor_of`, which reads the one bundle when the plugin wasn't scanned this session
  (Godot loads its plugin list from `plugins.json`, so a project can load before any scan). Vendor
  strings are taken literally: Dragonfly Room says "Michael Willis" but Dragonfly Hall says "Michael
  Willis and Rob vd Berg", so By vendor puts them in different hosts.
- **Multi-instance host.** The host's main thread keeps a `HashMap<InstanceId, PluginState>`; each
  command runs against that instance's slot (so the per-command "not initialized" answers cover
  unknown ids). The audio thread keeps one `InstanceSlot` per instance (processor, block, parameter
  map, queued parameters, steady time) and processes every slot with a request pending; the event
  scratch buffers are shared. clack caches bundle entries per library, so loading one `.clap` twice
  in a process runs its `init` once.
- **New command `Unload`.** Removing an instance from a host other instances still use sends
  `Unload` (the host closes its GUI, deactivates it, drops it and removes its audio slot; answer
  `Unloaded`). The last instance shuts the host down as before. `host_for` registers the new
  instance's event route under the `hosts` lock and `release_host_if_unused` checks it under the
  same lock, so a host can't be released while a new instance is claiming it.
- **Live moves (step 4).** Godot sends the whole policy as `/plugins/hosting <mode> [plugin_id
  mode]*`. The command thread stores it and runs a device tick at once; the tick flags every
  ready plugin whose `desired_host()` differs from its assignment and `move_plugin` closes its GUI
  (reporting `gui/closed`), takes a fresh `SaveState`, then calls `begin_reload`. `begin_reload`
  now re-evaluates the policy, so the Phase 4 reload path does the respawn, the unload from the
  old host and the restore. A plugin that is still loading is moved once it is ready. Audio passes
  through a moving plugin until it is ready again (~20–40 ms per plugin live).
- **Crashes in a shared host (Phase 4 follow-up).** `PluginLoad` remembers its host pid. A Reload
  of one crashed device reloads every crashed device whose pid matches, so one click restores the
  whole host. Godot shows one crash popup per dead pid (it says the host was shared) instead of
  one per device.
- **Hung detection.** Loading a plugin can keep a shared host's main thread busy for seconds, so
  while an `Initialize` is in flight in a host, another request timing out no longer marks that
  host hung (an `Initialize` that times out still does).
- **Doorbell lost wakeup (found while making the audio thread multi-instance).** The engine's
  publish only called `futex_wake`, without bumping the word, and the host read the word after
  checking for work. A publish landing between the two left the host asleep for its 2 ms idle
  timeout. The engine now `ring()`s (bump + wake) and the host reads the word before checking.
- **Step 5, Within engine: skipped.** The other four modes cover the need, and this one would bring
  back the crash-takes-the-engine-down failure Phases 3–4 removed. `clap_host/adapter.rs` stays
  unused.
- **Step 6.** New status `<device addr>/host [mode:s, host_key:s, pid:i]` after every load,
  reload and move. `DeviceInstance` stores it (`host_mode`, `host_key`, `host_pid`,
  `host_changed`) and `DevicePanel`'s header tooltip shows "Plugin host: By plug-in (pid N)".
  Phase 6 adds the stats next to it.
- **Godot.** Setting `plugins/hosting_mode` (Settings › Audio › Plugins; choices Individually, By
  plug-in, By vendor, Together; default Individually). `data/PluginHosting.gd` (owned by
  `AssetService`) maps the labels to engine names, keeps overrides in the `plugins/hosting_overrides`
  config key and sends `/plugins/hosting` at start, on engine (re)connect, before `/project/init`
  and on every change. The device context menu has an "Always host individually" check box for
  CLAP devices. The default stays **Individually**: the measurements below show no CPU gain from
  grouping at this quantum.
- Tests: `hosting.rs` (keys per mode, overrides), `osc/server.rs` (`/plugins/hosting` parsing),
  `process_manager.rs` (a shared host outlives all but its last instance and gets `Unload`; a
  timeout during another instance's `Initialize` isn't a hang), `subprocess_adapter` (reload follows
  the current policy and drops the GUI), Godot `tests/test_plugin_hosting.gd`.
- **Live check (2026-09-25, engine only, messages sent by hand; 1024-frame setting → 1488-frame
  graph quantum).** 2× Dragonfly Room, Dragonfly Hall, LSP Compressor Stereo and LSP Filter Stereo
  on four channels, transport playing. Individually: 5 hosts. `by_plugin` during playback: 4 hosts
  (both Rooms in one pid), each plugin restored its state blob, and the Rooms' parameter 4 values
  set beforehand (0.123, 0.777) came back. `by_vendor`: 3 hosts (see the vendor strings above).
  `together`: 1 host. Every move sent `<device>/host` with the new pid. `kill -SEGV` on the
  `all` host: all 5 devices reported `crashed` with the same pid, and `/reload` on one device
  brought all 5 back into one new host with their parameters. The 5 blocks each plugin missed
  while the host was dying are the only deadline misses in the run. Together plus a
  `michaelwillis.dragonfly.room individually` override: 3 hosts (each Room alone). Removing the LSP
  Filter from the shared host sent `Unload` and the host kept running. Stopping the engine left no
  `plugin_host` behind. 0 xruns and 0 lock misses throughout.
- **Odd, explained in Phase 6:** the first `kill -SEGV` on the shared host had no effect (the process
  stayed in `Sl`); a second one a minute later killed it. Rust's runtime handles SIGSEGV for its
  stack-overflow check and, for any other fault, resets the handler to the default and returns so
  the fault repeats. A `kill` doesn't repeat, so only the second one kills (`SigCgt` bit 11 set
  before, clear after the first). Not a Sonara bug; a real segfault dies at once.
- **Not verified:** anything through the Godot UI (the setting, the context-menu check box, the
  header tooltip, the single crash popup), a plugin GUI open during a move, and the benchmark
  project numbers.
- `./test_osc.sh` and `./test_plugin_osc.sh` weren't run: they are still stale (see Phase 2) and
  prove only that the engine survives them. The live check above covers this phase.

## Phase 6: Debuggability

1. Each host writes its own log file, `logs/plugins/<host-key>-<pid>.log`, with the plugin
   instance's name in every line (a shared host logs several plugins). Forward WARN and higher to the engine over the control channel so they
   reach Godot's `/log`.
2. Per-plugin stats go into `EngineStats` or a new `/status/device_stats`: average and maximum
   process time, overruns, and a deadline-miss rate. Show them in the device header tooltip,
   and in `EnginePanel` as a "worst plugins" list.
3. Add `SONARA_PLUGIN_HOST_WRAPPER`, a command prefix for spawning the host, e.g.
   `gdb -ex run --args` or `valgrind`. Add `SONARA_PLUGIN_HOST_WAIT=1` to make the host pause for
   a debugger to attach and print its pid.
4. Add `plugin_host --probe <path.clap> [--id <plugin-id>]`. It loads the plugin standalone,
   prints its descriptor, parameters, ports and latency, processes 1 s of silence plus a note,
   and reports timing. This isolates plugin bugs without the engine or Godot.
5. Update `docs/subsystems/engine-plugin-architecture.md` and `engine-debugging.md`.

As built (2026-09-25):
- **Logs (step 1).** `plugin_host/logging.rs`. The engine starts hosts as `plugin_host 3
  --host-key <key> --log-dir <Engine/logs/plugins>`; the host writes `<key>-<pid>.log` (key made
  file-safe by `protocol::log_file_name`, shared by both binaries) at DEBUG and up through an
  unbuffered file, so the lines before a crash survive. `SONARA_PLUGIN_LOG` overrides the file
  filter. stderr stays at INFO for the crash tail, now without ANSI codes when piped (the tail used
  to carry colour escapes into the crash popup). The engine logs the path on spawn, prunes
  `logs/plugins` to the newest 50 at startup, and sends the path as a 4th `/crashed` argument that
  the crash popup shows.
- **Instance names.** One root `instance{id plugin}` tracing span per instance, owned by
  `SubprocessHostShared` (so plugin `HostLog` callbacks from any thread enter it) and entered by the
  main loop per command and per main-thread service call, and by the audio thread only when it logs.
  `Initialize` runs in a provisional span named after the plugin id until the descriptor name is
  known. The first version created the instance's span inside the provisional one, so every later
  line showed both; `parent: None` fixed it.
- **Forwarding.** New `HostMessage::Log { instance_id, plugin, level, message }`. A tracing layer
  in the host turns WARN/ERROR into it (instance read from the span), rate-limited to 20 per second
  with one "N more … not forwarded" line; the main loop sends it. The engine reader thread re-logs it
  as `Plugin <name> (instance <n>, host <key> (pid <pid>)): …`, which the existing log forwarder
  sends to `/log`. A failed send of a forwarded line logs at DEBUG so it can't loop.
- **Stats (step 2).** Device-addressed `<device addr>/stats` (like `/host` and `/crashed`), not a
  global `/status/device_stats`: `[load_avg, load_peak, process_avg_us, process_max_us, blocks,
  deadline_misses, total_misses, struggling]`, once a second per plugin that processed (one zero
  report when it stops). Process time is measured by the host around `process()` and stored in
  `BlockControl::process_ns` (taken from `_reserved`), so it excludes IPC. `PluginBlockStats` gained
  the sums, max, peak share and longest miss run; `struggling` = 8+ misses in a row
  (`MISSES_BEFORE_WARNING`), which is the "flagged in the UI" Phase 3 promised. Godot:
  `DeviceInstance.PluginStats` + `stats_changed`; the device header tooltip shows the numbers, the
  device light gets an amber ring while struggling, and `EnginePanel` appends the three worst
  (dropouts first, then peak share) with ten in its tooltip. A crash clears the device's stats.
- **Debugger (step 3).** `SONARA_PLUGIN_HOST_WRAPPER` is split like a shell (quotes, backslash) and
  prepended to the host command. `SONARA_PLUGIN_HOST_WAIT=1`: the host logs its pid, allows any
  ptracer (`PR_SET_PTRACER_ANY`, because Yama's default scope blocks `gdb -p` from a non-parent) and
  polls `TracerPid` until a debugger has attached **and continued** (a stopped process can't see the
  attach). Deviation: while waiting it also polls the control socket for hang-up and exits, found
  live: a host waiting when the engine was killed was orphaned. Either variable makes
  `HostLaunch::is_debugging()` true: host stderr goes to the engine's terminal, request timeouts
  become 2 minutes, and neither request timeouts nor stalled blocks mark the host hung. Under a
  wrapper the child pid is the wrapper's, so the crash reason names it ("gdb exited with code 0
  (the host ran under it; …)") and the log path isn't known exactly.
- **Probe (step 4).** `plugin_host --probe <path.clap> [--id] [--rate] [--block]` (`probe.rs`),
  reusing `load_plugin`. Beyond the plan it lists the bundle's plugins, the extensions in use, a
  state save/load round trip (what crash recovery relies on), and a note when the plugin's ports
  aren't the one stereo in / one stereo out the engine passes. Exit code 1 on any error.
- Tests: `logging.rs` (instance attribution incl. the nesting case, rate limit), `protocol.rs`
  (log file names), `process_manager.rs` (wrapper splitting, debug mode never hung, forwarded logs
  aren't routed as events, log pruning, wrapper crash reason), `subprocess_adapter` (stats from the
  host's `process_ns`, a miss run flagged across `take_stats`), Godot `tests/test_plugin_stats.gd`.
- **Live check (2026-09-25, engine only, messages by hand; 1488-frame graph quantum).** Dragonfly
  Room and LibreStrings in two hosts: both log files written with `instance{id=… plugin=…}` on each
  instance line; `/stats` once a second (~32 blocks, Room ~2% avg / 4% peak, LibreStrings 2.6%
  rising to 5% after a note-on); `kill -ABRT` → `/crashed` with the log path and a clean stderr
  tail. `SONARA_PLUGIN_HOST_WAIT=1`: the engine and host both warned with the `gdb -p` line; after
  `gdb -p <pid> -ex continue` the plugin became ready and the host's warning arrived on `/log` via
  forwarding; killing the engine while a host waited left no host behind. `SONARA_PLUGIN_HOST_WRAPPER
  ="gdb -q -batch -ex run -ex bt --args"`: plugin ran and reported stats under gdb, `kill -SEGV`
  printed the backtrace in the engine's terminal and the device was marked crashed. Probe on
  Dragonfly Room (effect: silent output, as expected with silent input) and LibreStrings (−26 dBFS
  on the note).
- **Not verified:** the Godot UI (header tooltip, amber ring, EnginePanel list, log path in the
  popup) and valgrind as a wrapper (not installed). `./test_osc.sh`/`./test_plugin_osc.sh` weren't
  run (still stale, see Phase 2); the live check above covers this phase.

## Phase 7: Audio device settings

Goal: choose the output device, sample rate and buffer size in Settings → Audio. Changes apply
live and persist.

Engine:
1. Move stream ownership out of `AudioEngine::with_status_channel` into a `StreamManager` (the
   existing stream thread plus watchdog) that can `reconfigure(device, rate, buffer_frames)`.
   Enumerate devices with the rates and buffer ranges each one supports.
2. Add an `AudioDevice::prepare(sample_rate, max_frames)` default method. Implement it for
   polysynth, delay, sfizz, sampler, drum machine, the containers and the spectrum analyzer.
   The CLAP adapter does deactivate/activate (Phase 3). `DeviceFactory` gets its rate updated.
3. The reconfigure sequence runs on the command thread:
   1. stop the stream;
   2. with the lock released, `prepare` every device at the new rate;
   3. update `device_sample_rate`;
   4. start the stream on the new device;
   5. report the actual configuration, which may differ from what was requested.

   A buffer-only change skips step 2 when the new size is ≤ the preallocated max.
4. Clips are resampled to the device rate at load (`decoder.rs`). After a rate change, send
   `/audio/config/changed`. Godot then re-issues the clip loads it owns (the existing
   `load_audio_file` path with new `req_id`s). Until they finish, clips play silent rather than
   at the wrong pitch.
5. New OSC messages, all documented in `OSC_PROTOCOL.md`:
   - `/audio/devices/request` → `/audio/device` (one per device: name, default flag, supported
     rates, min/max buffer) → `/audio/devices/complete`;
   - `/audio/config/set <device> <rate> <buffer>`;
   - `/audio/config <device> <rate> <buffer> <latency_ms>` (sent on change and on request).
6. Hardware outputs become **channel pairs on the selected device** (see Decisions).
   - Open the stream with all of the device's output channels.
   - 1000 = outputs 1/2, 1001 = 3/4, and so on. Master defaults to 1000.
   - Replace the per-device enumeration in `engine.rs`. `/audio/config` reports how many output
     pairs exist so Godot's routing menus list real outputs.
   - A project whose master points at a pair that doesn't exist on the current device falls
     back to 1000 and logs a warning. It doesn't lose the setting.

7. **PipeWire quantum awareness.** The engine must not run with a buffer smaller than the graph
   quantum, and must not silently push PipeWire to a smaller quantum than the user chose.
   - The buffer-size setting is the **period** (frames per callback). cpal 0.15's ALSA backend
     sets the period to a quarter of `BufferSize::Fixed`, so the engine asks for four periods
     (`PREFERRED_PERIOD_FRAMES * 4` in `engine.rs`, done 2026-09-24; before that a 1024 buffer
     asked PipeWire for `node.latency = 256/48000` and pulled the whole graph down to 256). Keep
     that mapping when the value becomes a setting, and recheck it after a cpal upgrade or when
     switching to the JACK backend (7b).
   - At stream start and every few seconds on the watchdog thread, read the running graph
     quantum and rate (`pw-metadata -n settings 0` for `clock.force-quantum` / `clock.force-rate`,
     or the driver node's quantum through `pw-dump`; use `libpipewire` bindings later if parsing
     CLI output proves fragile). Skip this when PipeWire isn't running.
   - If the quantum is larger than the stream buffer, or the forced rate differs from the stream
     rate: log a WARN, report it in `/audio/config` (`graph_quantum`, `graph_rate`, `mismatch`), and
     reopen the stream with a buffer of at least the quantum, using the Phase 7 reconfigure path.
     Never write PipeWire's settings metadata ourselves: it's system-wide state the user or another
     tool owns.
   - Count these PipeWire-side problems as xruns in `EngineStats` when they can be detected (the
     driver node's error counter from `pw-dump`, sampled with the quantum). This closes the Phase 0
     blind spot.
   - Settings shows the graph quantum next to the engine's buffer size, with a warning when they
     conflict and the `pw-metadata` command that caused it.

Godot:
1. Add an `AudioConfig` model in `data/` (or a small autoload) that owns the device list and the
   current config, sends the OSC, and emits `devices_changed` / `config_changed`. UI never sends
   OSC directly.
2. Register `audio/output_device`, `audio/sample_rate` and `audio/buffer_size` in `Settings.gd`
   under `CATEGORY_AUDIO`. The device list comes from the engine, so use a custom
   `.scene(...)` control that fills its options from `AudioConfig`. Show the resulting latency in
   ms and the actual values the engine reports.
3. Apply the saved config at startup, before `/project/init`. If the saved device is missing,
   fall back to the default and show a notice.

Optional 7b: backend choice (ALSA or JACK). cpal has a `jack` feature, and PipeWire's JACK
emulation usually gives lower, more stable latency than its ALSA plugin. Check the current cpal
version and feature set with Context7 first. The cpal upgrade from 0.15 may be a task of its own.

Verify: switch device, rate (44.1 ↔ 48 kHz) and buffer size during playback of the benchmark
project. Audio resumes, clips play at the correct pitch, plugins keep their state, and the
settings survive a restart. During playback with a 256-frame buffer, run
`pw-metadata -n settings 0 clock.force-quantum 1488` (then `… 0` to undo): the engine warns,
reopens with a big enough buffer (512), and `pw-top` shows no growing ERR count on the engine's
node. (At the default 1024 frames, a 1488 quantum fits the 4096-frame buffer and nothing happens;
see As built.)

As built (2026-09-25):
- **Stream ownership (step 1).** `audio/stream.rs` holds the stream thread ("audio-stream"), which
  owns the CPAL stream and the watchdog and takes `Resolve`/`Start`/`Stop` requests through
  `StreamControl`; the callback, `LoadWindow`, `send_meters` and `lock_state_for_callback` moved
  there from `engine.rs`. Deviation: no `reconfigure(device, rate, buffer)` in one call. The
  command thread drives the steps, because it has to prepare devices between resolving a config
  (which fixes the rate) and starting it. `Stop` drops a healthy stream so the device is freed for
  reopening; the watchdog still leaks stalled ones (`mem::forget`). `list_output_devices` opens
  every device to query it, so it runs on a throwaway thread.
- **Config selection.** f32 configs only, as before. The period is clamped to 32–2048: cpal's ALSA
  callback delivers all free space (up to 4 periods), and that must fit the 8192-frame
  preallocation (`MAX_BLOCK_FRAMES`), so a buffer change never reallocates. A device that can't
  run the requested rate opens at its default rate (and says so). Channels: every channel of a
  device with a fixed set of counts (e.g. `hw:` of an interface), but the default count (2) on
  plugin devices that accept any count (`pipewire`, `plughw`); cpal lists those as 1–32.
- **`prepare` (step 2).** `AudioDevice::prepare(sample_rate, max_frames)`, default no-op. Delay
  resizes its ring for the same maximum time; polysynth rebuilds its voices; sampler rebuilds its
  voices (its sample keeps its own rate, which playback already compensates for); sfizz retunes a
  loaded synth; spectrum analyzer updates its interval. Containers keep the no-op: the command
  thread visits nested devices itself with `visit_devices_mut`. `Channel::set_sample_rate`
  recomputes fader smoothing. CLAP: `prepare` stores the rate, and the command thread re-activates
  every plugin whose `PluginLoad::activated_rate` differs (Phase 3's deactivate/activate path, same
  host and instance, so the plugin keeps its state). A plugin still loading when the rate changes
  finishes at the old rate; the device tick then re-activates it (`needs_reactivation`). Reloads and
  new devices use the new rate (`DeviceFactory::set_sample_rate`).
- **Sequence (step 3)** in `command_worker/audio_config.rs`: stop; resolve; prepare devices if the
  resolved rate differs (the lock is uncontended with the stream stopped; plugin re-activation runs
  with it released); start; report. Candidates, in order: the request; the default device with the
  same rate and buffer; the default config (48 kHz, 1024). A request equal to the running one only
  reports. The failure reasons go into `notice`.
- **Clips (step 4). Deviation:** clips don't go silent. `processing.rs` already plays a clip at
  `device_rate / clip.audio_sample_rate`, so PCM decoded at the old rate stays at the right pitch
  (linearly interpolated) until it is reloaded. `/audio/config/changed` updates the decoder's target
  rate (the status thread writes `AudioFileService`'s rate atomic before forwarding it) and Godot
  re-sends `load_audio_file` for every audio clip, which is silent from `BeginLoadAudioClip` until
  its new PCM arrives. Sampler and drum machine samples aren't reloaded: they already play through
  `sample_rate_ratio`.
- **OSC (step 5).** As planned, with more fields: `/audio/device [name, is_default, min_buffer,
  max_buffer, channels, rate…]`, and `/audio/config` carries the running config, the output pair
  count, the request, the graph quantum and rate, a `mismatch` text and a `notice` text (13
  arguments; see `OSC_PROTOCOL.md`).
- **Hardware outputs (step 6).** `OutputDevice` and the per-device enumeration in `engine.rs` are
  gone. `mix_and_output` clears the whole CPAL buffer first (**found**: it never did, so channels
  beyond master's pair, or all of them when master routed nowhere, replayed stale samples) and
  writes master to pair `id − 1000`. A missing pair plays on 1/2, and the command thread warns
  after a reconfigure or a master route change. Godot: `Channel.set_device_output` (**found**: the
  mixer wrote `device_output_id` directly, so choosing an output never reached the engine), and
  master's output menu lists `Outputs 1/2`, `3/4`, … from the running device, keeping a saved pair
  the device lacks, marked "(not on this device)".
- **PipeWire (step 7).** `audio/pipewire.rs`: a monitor thread runs `pw-top -b -n 2` every 3 s
  (running quantum, rate and ERR of the engine's node and its driver), `pw-dump` to find the
  engine's node (pipewire-alsa puts the process id on the **client** object; the node names it with
  `client.id`) and `pw-metadata -n settings 0` for the forced values. It exits when the tools are
  missing and pauses while PipeWire isn't running. ERR increases on the engine's node count as
  xruns; the driver's ERR is not counted, because other clients cause most of it (the dev machine's
  sink showed 3281). **Deviation in the rule:** the quantum is compared with the whole ALSA buffer
  (4 periods), not the period. Both observations fit that: the Phase 0 crackles were a 1488 quantum
  against a 256-frame period (1024-frame buffer), and a 2048 quantum against a 1024 period (4096
  buffer) runs with 0 ERR. It also can't lock itself up. If the engine raised its period to the
  quantum, its own `node.latency` would hold the quantum there after the forcing went away. The
  adapted period is the smallest power of two whose buffer holds the quantum, which stays below
  the quantum, so the engine returns to the requested period once the quantum drops. The quantum is
  converted to engine frames first (`GraphInfo::quantum_at`), since PipeWire resamples a stream at
  another rate. A graph at a different rate is reported (PipeWire resamples) but never followed.
  The engine doesn't switch its own rate. `mismatch` also covers the harmless case (quantum > period:
  latency follows the quantum), logged at INFO; an adapted buffer or a rate conflict is a WARN,
  logged once per change.
- **Xrun counting (found live).** At 44.1 kHz in a 48 kHz graph, PipeWire hands the engine blocks
  of 1024, 1881 and 2739 frames, and the Phase 0 gap check (gap > 1.5 × previous block) counted 49
  "xruns" in a minute while PipeWire's ERR for the node stayed 0. cpal's ALSA callback fills all
  free space, so the ring is full after every callback and underruns only if the next callback is
  later than the whole buffer lasts; the check now uses that (the 1.5× rule remains for
  device-default buffers of unknown size).
- **Godot.** `data/AudioConfig.gd` is an autoload (`AudioConfig`, after `Settings`): it owns the
  device list and the last `/audio/config`, sends `/audio/config/set` at start, on every engine
  (re)connect, before `/project/init` (from `Project.connect_to_engine`) and once per frame of
  setting changes, and emits `devices_changed`, `config_changed`, `sample_rate_changed` (Project
  reloads its audio clips) and `notice_raised` (Editor shows it in the shared popup; the saved
  setting is kept for when the device is back). Settings › Audio › Output registers
  `audio/output_device` ("" = system default), `audio/sample_rate` (48000) and `audio/buffer_size`
  (1024), all with `settings/AudioSettingControl.tscn`: options from the engine's device list, the
  running config, the PipeWire quantum, and the notice or mismatch in amber.
- Tests: `stream.rs` (channel choice, 4-period buffer within the device range, output pairs and
  latency), `pipewire.rs` (pw-top parsing, metadata, node lookup through the client, the buffer rule
  incl. rate conversion, mismatch text), `mixing.rs` (output pair, missing pair → 1/2, silence
  without a hardware route), `delay.rs` (prepare), `subprocess_adapter` (prepare marks an activated
  plugin for re-activation; reload uses the new rate), `osc/server.rs` (`/audio/config/set` parsing,
  `/audio/config` without a stream), Godot `tests/test_audio_config.gd`.
- **Live check (2026-09-25, engine only, messages by hand; PipeWire with `clock.force-quantum
  2048` and `clock.force-rate 48000` set on the machine).** Polysynth + delay on one channel,
  Dragonfly Room on another, transport playing. 48 → 44.1 kHz: stop, prepare, re-activate and
  restart took 23 ms; the host logged `Activate { sample_rate: 44100.0 }` on the same instance, the
  plugin kept processing (24 blocks/s, 0 misses), `pw-top` showed the node at 44100 with 0 ERR, and
  the rate conflict was reported and logged. 256 frames under the 2048 quantum opened a 512-frame
  period (node latency 512, 0 ERR). 96 kHz at 512 frames opened 1024 (2048 graph frames = 4096
  engine frames). A missing device fell back to the default with the notice "Couldn't use
  hw:CARD=Nope: output device 'hw:CARD=Nope' not found."; switching to `pipewire` worked; master on
  1001 warned and played on 1/2. 0 xruns and 0 lock misses throughout, and no `plugin_host` was
  left behind.
- **Not verified:** anything through the Godot UI (the Settings rows, the notice popup, clip reload
  after a rate change, the output menu, settings surviving a restart), changing
  `clock.force-quantum` during playback (not done: it's system-wide and wasn't cleared for this
  check), a multi-channel interface, and the benchmark project.
- `./test_osc.sh` and `./test_plugin_osc.sh` weren't run (still stale, see Phase 2); the live check
  above covers this phase.

## Phase 8: Later work

Drive these by Phase 0 numbers, not by default:
- **Lock-free engine state** (TODO.md "phase 2"). The audio thread owns `EngineState` and drains
  a lock-free command queue. Removed objects are sent back to be dropped off-thread. Worth doing
  if `lock_misses` stays above zero after Phase 1.
- **RT priority and memory locking** (moved from Phase 1): `SCHED_FIFO` with rtkit fallback for
  the callback thread, `mlockall`, report both in `EngineStats`. See the Phase 1 notes for what
  the dev machine allows.
- **CPU affinity** for the audio thread and plugin audio threads, as a setting.
- **Plugin latency compensation**, using `latency_frames()` from Phase 3 and the routing graph in
  `mixing.rs`.
- **Parallel plugin dispatch.** Plugins run in other processes, so the engine can start the
  first plugin of every independent channel at once and wait for them together. That gives
  multi-core processing almost for free. It relies on Phase 3's separate start and wait steps.
- **Parallel channel processing** of built-in devices across a worker pool, only if single-core
  load is still the bottleneck after parallel plugin dispatch.

## Decisions

- **Hardware outputs.** The engine opens one output device at a time, chosen in Settings. IDs
  1000+ are channel pairs on that device, not separate devices (Phase 7). This is how Bitwig and
  Ableton present outputs, and it makes routing to extra interface outputs work.
- **Plugin process grouping.** It's user-selectable, like Bitwig's hosting modes (Phase 5). The
  default is Individually until measurements say otherwise. The protocol addresses instances
  from Phase 2 onward, so grouping never needs a protocol change.
- **Deadline policy.** One absolute deadline per callback shared by all plugin waits, not a fixed
  share per plugin (Phase 3). A miss costs that plugin one block. Repeated misses are flagged in
  the UI.

## Measurements

Fill in with the Phase 0 benchmark project. Buffer = frames, load in % of block time.

| Phase | Buffer / rate | Load avg | Load peak | Xruns / min | Lock misses / min | Plugin overruns / min |
|---|---|---|---|---|---|---|
| Baseline (not the benchmark project; one Dragonfly Hall, read from the panel) | 1024 / 48k | 19% | 29% | 0 | – | n/a |
| Phase 3 (5 CLAP instances: 2 Dragonfly, LSP compressor, LSP limiter, LibreStrings; 60 s playback) | 1024 / 48k (1488-frame graph quantum) | 4.0% | 17.4% | 0 | 0 | 0 |
| Phase 5, Individually (4 CLAP effects: 2 Dragonfly Room, Dragonfly Hall, LSP compressor; no input; 60 s playback; 4 hosts) | 1024 / 48k (1488-frame graph quantum) | 8.1% | 12.6% | 0 | 0 | 0 |
| Phase 5, Together (same 4 effects, 1 host) | 1024 / 48k (1488-frame graph quantum) | 8.0% | 14.8% | 0 | 0 | 0 |

Add a row per phase, and for Phase 5 one row per hosting mode.
