# Plugin Architecture: Subprocess-Based CLAP Hosting

## Overview

- CLAP plugins live in dedicated subprocesses for crash isolation, GUI compatibility, and sandboxing.
- Engine/device code talks to the subprocess through the reusable `audio/ipc` layer (command protocol + shared-memory ring buffers).
- `SubprocessClapAdapter` integrates the subprocess host into the audio device graph without blocking the audio thread.

## Structure

- `audio/ipc/` (format agnostic, used by both binaries):
  - `process_manager.rs`: `ProcessManager` maps a host key to a host process (`PluginProcess`) and an `InstanceId` to its `InstanceConnection`. Each host has one control socket and a reader thread.
  - `shared_memory.rs`/`platform_shm.rs`: Lock-free interleaved audio + MIDI ring buffers backed by `memfd` (Unix) or OS-specific shared memory.
  - `protocol.rs`: The one protocol module: `HostRequest`/`HostMessage` envelopes, `PluginCommand`/`PluginResponse`/`PluginEvent`, shared-memory layout.
  - `wire.rs`: Framing on the control socket: `u32` length prefix + bincode, file descriptors attached as `SCM_RIGHTS`.
- `clap_host/subprocess_adapter/`:
  - `mod.rs`: Adapter entry point, implements `AudioDevice`, maintains cached state, and delegates.
  - `lifecycle.rs`: Background loading thread, `PluginLoad` transitions, and loading the instance through `ProcessManager`.
  - `parameter.rs`: Metadata cache and fire-and-forget `SetParameter`.
  - `gui.rs`: OpenGui/CloseGui/HasGui requests.
  - `plugin_ipc.rs`: `PluginIpcHandle`, blocking requests that don't borrow the adapter, so the command thread can release the state lock first.
- `plugin_host/` (subprocess crate):
  - `mod.rs`: Module wiring and re-exports for subprocess host.
  - `event_loop.rs`: A reader thread decodes requests; the main loop interleaves them with audio processing, timers, GUI callbacks and parameter echo, and is the only writer on the socket.
  - `commands.rs`: Command dispatcher; owns initialization/activation, shared memory setup, parameter/GUI commands.
  - `operations.rs`: Higher-level helpers for loading CLAP bundles, creating GUI instances, and wiring parent windows.
  - `host.rs`: CLAP host implementation (`SubprocessHost*`) including timer management and GUI resize notifications.
  - `state.rs`: Runtime state container (`PluginState`), the `ParamMap` (engine index ↔ CLAP id, rebuilt after the plugin rescans), and helpers for audio processing and output event handling.
- `bin/plugin_host.rs`: Thin entry point. Takes the control socket's descriptor number (3) as its only argument, sets close-on-exec on it so processes a plugin spawns don't inherit it, and calls `run_plugin_host()`.

## Lifecycle

- Each adapter gets an `InstanceId` from `ProcessManager::allocate_instance_id()`. Every message carries it, so several instances can later share one host process (hosting modes) without a protocol change. For now the host key is `instance-<id>` ("Individually"), and a host rejects a second `Initialize`.
- `spawn_loading_thread` loads the plugin asynchronously: `ProcessManager::spawn_instance` spawns the host (or reuses a live one for the host key), creates the shared memory and sends `Initialize` with the memfd attached; then Activate and GetParameterInfo, then `PluginLoad` is set ready.
- `PluginLoad` is an atomic state plus a set-once shared-memory pointer, so the audio thread reads it without locking and passes audio through while the plugin is loading or failed.
- Background loading threads may emit engine `AudioCommand`s (e.g., for transport sync); keep cross-thread communication through provided channels only.

## Audio + IPC Flow

- Audio thread interaction:
  - Read `PluginLoad::shared_memory()`. While loading or failed it is None: copy inputs to outputs and exit early.
  - Once ready, write interleaved buffers via non-blocking ring-buffer APIs.
  - Always check write/read counts; drop extra input frames and zero-fill outputs when the peer under-produces.
  - MIDI arrives via `AudioDevice::send_midi_event(note, velocity, is_on, frame_offset)`; the adapter forwards it as CLAP `note_on/off` with `sample_offset = frame_offset` so plugins stay sample-accurate.
- The control channel is a Unix socketpair created at spawn; the host gets its end as descriptor 3. Messages are length-prefixed bincode frames; the memfd travels with the `Initialize` frame as `SCM_RIGHTS`.
- Engine side, a request registers a reply slot under a fresh `request_id`, writes its frame (holding the writer mutex only for the write) and waits with a timeout. The host's reader thread completes the slot when the matching `HostMessage::Response` arrives; a reply after the timeout is dropped. `request_id` 0 (`NO_REPLY`) is fire-and-forget; errors the host returns for such commands are logged as WARN. No lock is held while waiting, so a slow request (GUI open) never blocks other senders.
- Unsolicited `HostMessage::Event`s (`ParameterValueChanged`, `GuiResizeRequest`) go to a per-instance channel. The command thread drains it every 20 ms (`CommandWorker::poll_devices`) and turns events into `EngineStatus`es.
- Subprocess polls the shared-memory buffers inside its event loop; the engine can add signaling (eventfd) later without changing the adapter contract.

## Audio Thread Contract

- Never block, allocate, or take contended locks on the audio thread; prefer `try_lock()` and skip work if unavailable.
- Treat IPC data defensively: stale responses or partial buffer availability must not panic or block.
- Ring buffers encode stereo frames; keep writes/reads aligned to `sample_count * channels`.

## IPC Commands

- Engine issues Initialize, Activate, StartProcessing, Shutdown, Reset, OpenGui/CloseGui.
- `SetParameter`, `StartProcessing` and `Reset` are fire-and-forget; the host denormalizes parameter values and calls `params.flush()` immediately so edits apply even while audio is stopped. `Shutdown` exits the whole host process.
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

- When a host exits, its reader thread sees the socket close, fails every waiting request at once and marks the host disconnected. The next command-thread tick marks the plugin failed (pass-through audio) and sends `failed:subprocess crashed` to Godot.
- Removing a device shuts its host down: `Shutdown`, then `SIGKILL` if it hasn't exited within 1 s.
- Shared-memory handles stay owned by `ProcessManager`; dropping the last `Arc` cleans up OS resources automatically.
- When debugging, confirm the subprocess binary is alive and still holds the shared-memory FD (e.g., `/proc/<pid>/fd/3`).
