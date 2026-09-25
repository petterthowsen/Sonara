# Plugin Architecture: Subprocess-Based CLAP Hosting

## Overview

- CLAP plugins live in dedicated subprocesses for crash isolation, GUI compatibility, and sandboxing.
- Engine/device code talks to the subprocess through the reusable `audio/ipc` layer (command protocol + shared-memory ring buffers).
- `SubprocessClapAdapter` integrates the subprocess host into the audio device graph without blocking the audio thread.

## Structure

- `audio/ipc/` (format agnostic, used by both binaries):
  - `process_manager.rs`: `ProcessManager` maps a host key to a host process (`PluginProcess`) and an `InstanceId` to its `InstanceConnection`. Each host has one control socket, a reader thread, and one doorbell region.
  - `shared_memory.rs`/`platform_shm.rs`: Per-instance block memory (planar audio + event arrays + `BlockControl`) and the per-host `HostSharedMemory` doorbell, both backed by `memfd` (Unix) or OS-specific shared memory.
  - `futex.rs`: `wait`/`wake`/`ring` on a shared `u32`, used for the block handshake.
  - `protocol.rs`: The one protocol module: `HostRequest`/`HostMessage` envelopes, `PluginCommand`/`PluginResponse`/`PluginEvent`, the shared-memory layout, `BlockEvent`.
  - `wire.rs`: Framing on the control socket: `u32` length prefix + bincode, file descriptors attached as `SCM_RIGHTS`.
- `clap_host/subprocess_adapter/`:
  - `mod.rs`: Adapter entry point, implements `AudioDevice`, maintains cached state, and delegates.
  - `lifecycle.rs`: Background loading thread, `PluginLoad` transitions, and loading the instance through `ProcessManager`.
  - `parameter.rs`: Metadata cache and fire-and-forget `SetParameter`.
  - `gui.rs`: OpenGui/CloseGui/HasGui requests.
  - `plugin_ipc.rs`: `PluginIpcHandle`, blocking requests that don't borrow the adapter, so the command thread can release the state lock first.
- `plugin_host/` (subprocess crate):
  - `mod.rs`: Module wiring and re-exports for subprocess host.
  - `event_loop.rs`: The **main thread**. A reader thread decodes requests; the main loop handles commands, GUI callbacks, timers and `params.flush`, and is the only writer on the socket.
  - `audio_thread.rs`: The **audio thread**. Owns the plugin's `PluginAudioProcessor` and the instance's shared block, waits on the doorbell and calls `process()` for exactly the engine's block.
  - `commands.rs`: Command dispatcher on the main thread; owns initialization/activation, shared-block mapping, parameter/GUI commands, and hands the processor to the audio thread on activation.
  - `operations.rs`: Higher-level helpers for loading CLAP bundles, creating GUI instances, and wiring parent windows.
  - `host.rs`: CLAP host implementation (`SubprocessHost*`) including timer management, GUI resize notifications and the latency extension.
  - `state.rs`: `PluginState` (main thread) and the `ParamMap` (engine index ↔ CLAP id, rebuilt after the plugin rescans and published to the audio thread).
- `bin/plugin_host.rs`: Entry point. Takes the control socket's descriptor number (3) and maps the doorbell descriptor (4), setting close-on-exec on both so processes a plugin spawns don't inherit them.

## Lifecycle

- Each adapter gets an `InstanceId` from `ProcessManager::allocate_instance_id()`. Every message carries it, so several instances can later share one host process (hosting modes) without a protocol change. For now the host key is `instance-<id>` ("Individually"), and a host rejects a second `Initialize`.
- `spawn_loading_thread` loads the plugin asynchronously: `ProcessManager::spawn_instance` spawns the host (or reuses a live one for the host key), creates the instance's shared block and sends `Initialize` with its memfd attached; then Activate, GetParameterInfo and StartProcessing, then `PluginLoad` is set ready with the block and the host doorbell.
- `PluginLoad` is an atomic state plus a set-once `PluginShared` (block + doorbell) pointer, so the audio thread reads it without locking and passes audio through while the plugin is loading or failed. It also carries the plugin's reported latency.
- Background loading threads may emit engine `AudioCommand`s (e.g., for transport sync); keep cross-thread communication through provided channels only.

## Audio + IPC Flow

- Processing is **synchronous per block** (Phase 3). The engine does not run ahead of the plugin.
- Audio thread interaction, once `PluginLoad` is ready:
  1. `SubprocessClapAdapter::process_block` finishes any request a previous block left outstanding (its output is discarded), writes the planewise input and the staged input events into the instance's shared block, stores `request_seq` and rings the host's doorbell (`futex_wake`).
  2. The host's audio thread wakes on the doorbell, builds CLAP events from the input event array (sorted by `sample_offset`) and calls `process()` for exactly that block.
  3. The host writes the output planes and its own output parameter events, stores `done_seq`, and rings the doorbell back.
  4. The engine spins briefly, then `futex_wait`s until `done_seq` reaches its `request_seq` or the callback deadline passes.
- A missed deadline passes dry input through, increments `deadline_misses` / `PLUGIN_UNDERRUNS`, and the late result is discarded by sequence number on the next block. Eight consecutive misses log a WARN.
- The deadline is **one absolute time per callback**, published by the engine callback in `audio/block_clock.rs` (70% of the block, `SONARA_PLUGIN_DEADLINE_FRACTION` overrides it).
- Notes and automation are staged in an adapter-local list and copied into the shared event array inside `process_block`, so the shared block is never written while the host may be reading it. `set_parameter_at`/`send_midi_event` therefore carry the engine's frame offset and reach the plugin sample-accurately.
- When the plugin is loading, failed or disabled the adapter passes audio through without touching the block.
- The control channel is a Unix socketpair created at spawn; the host gets its end as descriptor 3 and the host doorbell as descriptor 4. Messages are length-prefixed bincode frames; the instance's shared block travels with the `Initialize` frame as `SCM_RIGHTS`.
- Engine side, a request registers a reply slot under a fresh `request_id`, writes its frame (holding the writer mutex only for the write) and waits with a timeout. The host's reader thread completes the slot when the matching `HostMessage::Response` arrives; a reply after the timeout is dropped. `request_id` 0 (`NO_REPLY`) is fire-and-forget; errors the host returns for such commands are logged as WARN. No lock is held while waiting, so a slow request (GUI open) never blocks other senders.
- Unsolicited `HostMessage::Event`s (`ParameterValueChanged`, `GuiResizeRequest`) go to a per-instance channel. The command thread drains it every 20 ms (`CommandWorker::poll_devices`) and turns events into `EngineStatus`es.
- Parameter changes the plugin makes while **processing** don't use the socket: the host writes them into the block's output event array with the engine's parameter index, and the adapter hands them to the command thread from `process_block`.

## Audio Thread Contract

- Never block, allocate, or take contended locks on the audio thread; prefer `try_lock()` and skip work if unavailable.
- Treat IPC data defensively: stale responses or partial buffer availability must not panic or block.
- The shared block is planewise (stereo) and only written inside `process_block`, while the host cannot be reading it. Never touch it from `send_midi_event`, `set_parameter_at` or the command thread.

## IPC Commands

- Engine issues Initialize, Activate(`sample_rate`), StartProcessing, Shutdown, Reset, OpenGui/CloseGui, SaveState/LoadState.
- `Activate` carries the sample rate and re-activates (deactivate → activate) when the rate changes; the reply reports the plugin's latency. `GetParameterInfo` rebuilds and republishes the parameter map.
- `SetParameter` is fire-and-forget: while the plugin is processing the main thread queues it to the audio thread, which applies it at offset 0 of the next block; while stopped it is applied with `params.flush()`.
- `Reset` is handled on the audio thread (CLAP requires it there) and clears queued events. `Shutdown` exits the whole host process.
- Set `SONARA_IPC_TRACE=1` to log every frame on both sides, decoded as `Debug`.
- `GetParameterInfo` and `GetParameter` expect responses; only non-audio threads should call them.

## Parameter Handling

- Engine ↔ Godot use normalized 0.0–1.0 values; `parameter.rs` handles conversion with min/max stored in `ParamInfo`.
- Cache parameter metadata in `Arc<Mutex<Vec<ParamInfo>>>` before signalling Ready so UI consumers receive a complete list.
- `parameter.rs` issues blocking IPC from non-audio threads only; guard shared state with `Mutex`/`Option` locks that never appear on the realtime path.

## GUI Support

- `WindowManager` (winit thread) creates and tracks host windows. `OscServer` requests a window, receives the X11 handle, then calls `AudioCommand::OpenPluginGui` so `SubprocessClapAdapter::open_gui_with_handle()` can forward that handle through IPC (`PluginCommand::OpenGui { window_handle }`). Plugins that ignore the handle still work in floating mode.
- Initial sizing and resizability come from CLAP host API: adapter queries `gui_ext.get_size()`/`can_resize()` and forwards the dimensions to the main thread via `EngineStatus::PluginGuiResizeRequest`. The OSC main loop resizes + shows the window before the user ever sees it.
- Runtime resize requests flow `HostGui::request_resize()` → `PluginEvent::GuiResizeRequest` → command thread tick → `EngineStatus::PluginGuiResizeRequest` → main loop → `WindowManager::resize_window()`. All GUI-related statuses are handled in the main loop and are not forwarded back to Godot.
- Close lifecycle is synchronized: engine only destroys the window after the subprocess responds with `PluginResponse::GuiClosed`, which emits `EngineStatus::PluginGuiClosed`. User-initiated closes originate from the window thread, which triggers `AudioCommand::ClosePluginGui` and waits for the same acknowledgment to avoid X11 errors.
- `SubprocessClapAdapter` keeps `gui_open` state, resets it even on IPC errors, and sends a final `PluginGuiClosed` in `Drop` so orphaned windows are reclaimed if the device is removed or the adapter is dropped unexpectedly.

## Failure Handling

- Every host gets a watcher thread: a `pidfd` poll loop (`SYS_pidfd_open`, falling back to a 20 ms
  sleep where unavailable) that reaps the child and records `HostExit { signal, exit_code }`, plus
  a stderr drain thread keeping the last 20 lines (bounded reads, so a host that never emits a
  newline can't grow the buffer).
- A crash state is per **host process**, not per device: `HostCrash { host_key, pid, exit,
  stderr_tail }`. `PluginLoad` gains a `CRASHED` state so the audio thread passes audio through
  and the UI can offer a reload. `CommandWorker::poll_devices` sees `!is_alive()` (or `is_hung()`),
  marks the device crashed, sends `<device addr>/loading_state = "crashed:<reason>"` and
  `<device addr>/crashed [reason, stderr, pid]`, and logs the host's stderr tail.
- Hung hosts: a blocking request that exceeds `REQUEST_TIMEOUT` (5 s) sets a `hung` flag on the
  host; 32 consecutive missed plugin deadlines (`HUNG_MISSES`) means the host isn't processing.
  Either one makes the command thread kill the process and treat it as crashed.
- Reload (`<device addr>/reload` → `AudioCommand::ReloadDevice`) shuts the crashed instance down,
  spawns a fresh host for the same instance id, restores the last saved state blob
  (`PluginCommand::LoadState`), re-activates, re-sends the engine's cached parameter values
  (covers plugins without a state extension) and waits for `DeviceReady` to re-advertise the
  parameters. It runs on a background thread (`PluginLoadRequest::spawn`) with a fresh
  `PluginLoad`, so the audio thread keeps passing audio through until the new host is ready.
- State blobs: the host implements CLAP's state extension (`save`/`load` on the main thread).
  `mark_dirty` (HostState registered) or any parameter change sets the adapter's dirty flag; the
  command thread refreshes the blob at most once per 30 s while dirty, and on `/plugin/save_state`.
  Each request carries an `alive` flag cleared by the adapter's `Drop`, so a load in flight for a
  removed device cleans its host up instead of orphaning it.
- Removing a device shuts its host down: `Shutdown`, then `SIGKILL` if it hasn't exited within 1 s
  (the watcher reaps it; nothing waits on a zombie).
- Shared-memory handles stay owned by `ProcessManager`; dropping the last `Arc` cleans up OS
  resources automatically.
- When debugging, confirm the subprocess binary is alive and still holds its descriptors
  (`/proc/<pid>/fd/3` is the control socket, `/proc/<pid>/fd/4` the doorbell). A plugin that misses
  deadlines logs a WARN after 8 consecutive misses and shows up in `EngineStats::plugin_underruns`.

