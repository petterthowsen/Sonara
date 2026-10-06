# Plugin Architecture: Subprocess-Based CLAP Hosting

## Overview

- CLAP plugins live in dedicated subprocesses for crash isolation, GUI compatibility, and sandboxing.
- Engine/device code talks to the subprocess through the reusable `audio/ipc` layer (command protocol + shared-memory ring buffers).
- `SubprocessClapAdapter` integrates the subprocess host into the audio device graph without blocking the audio thread.

## Structure

- `audio/ipc/` (format agnostic, used by both binaries):
  - `process_manager.rs`: `ProcessManager` maps a host key to a host process (`PluginProcess`) and an `InstanceId` to its `InstanceConnection`. Each host has one control socket, a reader thread, and one doorbell region. It also holds the `HostingPolicy`.
  - `hosting.rs`: Hosting modes (`HostingMode`: Together, ByVendor, ByPlugin, Individually) and `HostingPolicy` (global mode + per-plugin overrides), which turns (plugin id, vendor, instance id) into a `HostAssignment` (mode + host key).
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
  - `audio_thread.rs`: The **audio thread**. Owns every instance's `PluginAudioProcessor` and shared block (one `InstanceSlot` each), waits on the doorbell and calls `process()` for exactly the engine's block of whichever instances have a request pending.
  - `commands.rs`: Command dispatcher on the main thread; owns initialization/activation, shared-block mapping, parameter/GUI commands, and hands the processor to the audio thread on activation.
  - `operations.rs`: Higher-level helpers for loading CLAP bundles, creating GUI instances, and wiring parent windows.
  - `host.rs`: CLAP host implementation (`SubprocessHost*`) including timer management, GUI resize notifications and the latency extension.
  - `state.rs`: `PluginState` (main thread) and the `ParamMap` (engine index ↔ CLAP id, rebuilt after the plugin rescans and published to the audio thread).
  - `logging.rs`: The host's logging (Phase 6): its own log file, stderr for the crash tail, WARN+ forwarded to the engine, and the per-instance `instance_span`.
  - `probe.rs`: `plugin_host --probe`, which loads one plugin standalone and reports what it does.
- `bin/plugin_host.rs`: Entry point. `plugin_host 3 --host-key <key> --log-dir <dir>` as the engine starts it: takes the control socket's descriptor number (3) and maps the doorbell descriptor (4), setting close-on-exec on both so processes a plugin spawns don't inherit them. `plugin_host --probe …` runs the probe instead.

## Lifecycle

- Each adapter gets an `InstanceId` from `ProcessManager::allocate_instance_id()`. Every message carries it, so several instances can share one host process.
- **Hosting modes** (Phase 5): the adapter asks `ProcessManager::assign_host(plugin_id, vendor, instance_id)` for its host key: `instance-<id>` (Individually, the default), `plugin:<id>` (By plug-in), `vendor:<vendor>` (By vendor) or `all` (Together). A per-plugin override wins over the global mode. The vendor comes from the plugin scanner, which reads the one bundle on demand when Godot loaded its plugin list from cache without scanning. Godot sends the policy with `/plugins/hosting`.
- When the policy changes, `CommandWorker::poll_devices` sees ready plugins whose `desired_host()` differs from `host_assignment()` and moves each one (`move_plugin`): close its GUI, `SaveState`, then `begin_reload`, which respawns it under the new key and restores the blob. Loading plugins are moved once they are ready.
- Removing an instance from a host other instances still use sends `PluginCommand::Unload` (the host closes its GUI, deactivates and drops it, and removes its audio slot); the last instance shuts the host down. Finding a host and registering an instance's route happen under the `hosts` lock, so a host can't be released while a new instance claims it.
- While an `Initialize` runs in a shared host (loading can block its main thread for seconds), another request timing out does not mark the host hung.
- `spawn_loading_thread` loads the plugin asynchronously: `ProcessManager::spawn_instance` spawns the host (or reuses a live one for the host key), creates the instance's shared block and sends `Initialize` with its memfd attached; then Activate, GetParameterInfo and StartProcessing, then `PluginLoad` is set ready with the block and the host doorbell.
- `PluginLoad` is an atomic state plus a set-once `PluginShared` (block + doorbell) pointer, so the audio thread reads it without locking and passes audio through while the plugin is loading or failed. It also carries the plugin's reported latency.
- Background loading threads may emit engine `AudioCommand`s (e.g., for transport sync); keep cross-thread communication through provided channels only.

## Audio + IPC Flow

- Processing is **synchronous per block** (Phase 3). The engine does not run ahead of the plugin.
- Audio thread interaction, once `PluginLoad` is ready:
  1. `SubprocessClapAdapter::process_block` finishes any request a previous block left outstanding (its output is discarded), writes the planewise input and the staged input events into the instance's shared block, stores `request_seq` and rings the host's doorbell (`ring`: bump the word, then `futex_wake`, so a host that just checked for work doesn't sleep through it; the host reads the word before checking).
  2. The host's audio thread wakes on the doorbell, builds CLAP events from the input event array (sorted by `sample_offset`) and calls `process()` for exactly that block.
  3. The host writes the output planes and its own output parameter events, stores `done_seq`, and rings the doorbell back.
  4. The engine spins briefly, then `futex_wait`s until `done_seq` reaches its `request_seq` or the callback deadline passes.
- **Transport.** Each block also carries the transport at its first frame. The mixer pushes it to every device through `AudioDevice::set_transport` (playing or stopped), and `begin_block` copies it into the `BlockTransport` region of the instance's shared memory (between the output events and `BlockControl`, 64-byte aligned) *before* the `request_seq` Release store; the host reads it after its Acquire load. `BlockTransport` is `#[repr(C)]`: `tempo`, `tempo_inc` (BPM per sample), `song_pos_beats`, `song_pos_seconds`, `bar_start_beats` (all f64), `bar_number: i32`, `flags: u32` (bit 0 = playing), `tsig_num`/`tsig_den: i16`. The host's `fill_transport_event` maps it to a `clap_event_transport` (tempo, beats, seconds and time-signature flags always set, plus `IS_PLAYING`; loop, record and pre-roll cleared) and passes it to `process()`. Engine and host are built together, so the region has no version field.
- A missed deadline passes dry input through, increments `deadline_misses` / `PLUGIN_UNDERRUNS`, and the late result is discarded by sequence number on the next block. Eight consecutive misses log a WARN.
- The deadline is **one absolute time per callback**, published by the engine callback in `audio/block_clock.rs` (70% of the block, `SONARA_PLUGIN_DEADLINE_FRACTION` overrides it).
- **Offline renders** (`audio/render/`) put `BlockClock` in offline mode: the render publishes its own deadline per block (`OFFLINE_BLOCK_TIMEOUT`, 2 s), kept apart from the live one so a late live publish can't shorten it. A miss still passes dry audio through, but the adapter also counts it on the clock (`record_offline_miss`) and the render fails rather than write the gap. The command thread doesn't kill stalled hosts while the clock is offline. Before rendering, the render sends each ready plugin `SetRenderMode { offline: true }` (the host calls `clap_plugin_render.set`; `RenderModeSet { applied }` is false without the extension) and a blocking `Reset`, whose reply means the host queued the reset on its audio thread ahead of the first render block. Afterwards it switches them back to realtime and resets them again.
- Notes and automation are staged in an adapter-local list and copied into the shared event array inside `process_block`, so the shared block is never written while the host may be reading it. `set_parameter_at`/`send_midi_event` therefore carry the engine's frame offset and reach the plugin sample-accurately.
- **Modulation offsets** (spec 018 Phase 5) travel the same way as `EVENT_PARAM_MOD` blocks: normal units in, plain units out. The `ModulatedDevice` wrapper pushes one stamped event per control step (whole CLAP blocks are never split, so `begin_block`/`finish_block` stay async), the adapter stages them in `set_param_mod_at`, and the host turns each into a `ParamModEvent` with a wildcard PCKN (global, not per note). The amount is `entry.mod_amount(offset) = offset × (max − min)`; the base value is never written. A parameter is a target only when its `CLAP_PARAM_IS_MODULATABLE` flag reaches `ParamInfo::is_modulatable`, and offsets are dropped while the plugin is loading — the wrapper re-sends the current ones after `DeviceReady` (a reloaded or crashed plugin lost its modulation state).
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

- Engine issues Initialize, Activate(`sample_rate`), StartProcessing, Shutdown, Reset, OpenGui/CloseGui, SetGuiVisible, SetGuiSize, SaveState/LoadState, SetRenderMode.
- `Activate` carries the sample rate and re-activates (deactivate → activate) when the rate changes; the reply reports the plugin's latency. `GetParameterInfo` rebuilds and republishes the parameter map.
- `SetParameter` is fire-and-forget: while the plugin is processing the main thread queues it to the audio thread, which applies it at offset 0 of the next block; while stopped it is applied with `params.flush()`.
- `Reset` is handled on the audio thread (CLAP requires it there) and clears queued events. `Unload` removes one instance from a shared host. `Shutdown` exits the whole host process.
- Set `SONARA_IPC_TRACE=1` to log every frame on both sides, decoded as `Debug`.
- `GetParameterInfo` and `GetParameter` expect responses; only non-audio threads should call them.

## Parameter Handling

- Engine ↔ Godot use normalized 0.0–1.0 values; `parameter.rs` handles conversion with min/max stored in `ParamInfo`.
- Cache parameter metadata in `Arc<Mutex<Vec<ParamInfo>>>` before signalling Ready so UI consumers receive a complete list.
- `parameter.rs` issues blocking IPC from non-audio threads only; guard shared state with `Mutex`/`Option` locks that never appear on the realtime path.

## GUI Support

- `WindowManager` (winit thread, `window_manager.rs`) owns one **host window** per open GUI, keyed by the device's window key. `OscServer` creates it on `gui/open`, gets its X11 handle, and sends `AudioCommand::OpenPluginGui`; `SubprocessClapAdapter::open_gui_with_handle()` forwards the handle over IPC (`PluginCommand::OpenGui { window_handle }`). The host window stays the plugin's CLAP parent for as long as the GUI is open.
- The plugin host opens the GUI embedded in that handle. A plugin that doesn't support embedded mode opens floating instead (`open_plugin_gui` falls back), and `PluginResponse::GuiOpened { width, height, is_resizable, floating }` says so. Asking for an already open GUI reports its real size.
- `SetGuiVisible { visible }` calls CLAP `gui.show()`/`hide()`. `SetGuiSize { width, height }` runs `adjust_size` → `set_size` → `get_size` and answers `PluginResponse::GuiSize`. Both are `AudioCommand`s (`SetPluginGuiVisible`, `SetPluginGuiSize`) that the command thread runs with the state lock released, like `open_plugin_gui`.
- Statuses: `EngineStatus::PluginGuiOpened { width, height, resizable, floating }` after every open (forwarded as `gui/opened`), `PluginGuiResizeRequest` when the plugin resizes or a size request settles (forwarded as `gui/size`), and `PluginGuiClosed` (`gui/closed`). The main loop also acts on them: it resizes a floating host window to the plugin, shows the host window once the GUI is open, and destroys the unused host window when an open came back `floating`. Runtime resizes flow `HostGui::request_resize()` → `PluginEvent::GuiResizeRequest` → command thread tick → `EngineStatus::PluginGuiResizeRequest`.
- Close lifecycle is synchronized: the engine destroys the host window only after the subprocess answers `PluginResponse::GuiClosed` (`EngineStatus::PluginGuiClosed`). A user closing a floating window starts on the window thread, which sends `AudioCommand::ClosePluginGui` and waits for the same answer, to avoid X11 errors.
- `SubprocessClapAdapter` keeps `gui_open` state, resets it even on IPC errors, and sends a final `PluginGuiClosed` in `Drop` so orphaned windows are reclaimed if the device is removed or the adapter is dropped unexpectedly.

### Embedding into Godot windows (spec 022, ADR 0016)

- Experimental, X11 only, behind the `plugins/embed_gui` setting. The host window is reparented into the X11 window of the Godot window that shows the device frame; only the host window moves, so attach, detach and tab switches never reopen the GUI.
- `HostWindow` holds the window, its embed state (`Embed { parent, rect: EmbedRect }`) and its visibility. `update_mapping` alone decides whether it is mapped (shown by the GUI opening, and not hidden with `SetVisible`).
- `WindowCommand`s: `Create` (can embed before the first map), `Embed`, `Bounds`, `Unembed`, `SetVisible`, `Release`, `Resize`, `Show`, `Destroy`. `Embed`, `Unembed` and `Release` answer once the X server has the reparent (`XSync`), and `WindowManager::embed_window`/`unembed_window`/`release_window` wait for that (1 s bound). The OSC server then sends `gui/embedded parent_xid` (0 = out of Godot's windows), which Godot waits for before it hides or frees a window: hiding a native Godot window destroys its X window and every child in it.
- `mod x11_embed` works on winit's own Xlib connection, so its requests are ordered with winit's. It keeps Godot 4.7's X11 behaviour in check: the host window is override-redirect (Godot drops redirected map/configure requests), always covers its whole Godot parent at (0,0) (Godot takes a direct child's ConfigureNotify as its own resize), and is clipped to the viewport by an XShape bounding region. Position and scrolling move the plugin's own window inside it. `withdraw` takes a floating host window away from the WM before its first embed, with a bounded wait. An embedded host window ignores the plugin's resize requests: the viewport stays where Godot put it.
- `gui/close` sends `Release` first (unmap, reparent to the root while unmapped), then `ClosePluginGui`.

## Failure Handling

- Every host gets a watcher thread: a `pidfd` poll loop (`SYS_pidfd_open`, falling back to a 20 ms
  sleep where unavailable) that reaps the child and records `HostExit { signal, exit_code }`, plus
  a stderr drain thread keeping the last 20 lines (bounded reads, so a host that never emits a
  newline can't grow the buffer).
- A crash state is per **host process**, not per device: `HostCrash { host_key, pid, exit,
  stderr_tail, log_path, wrapper }`. `PluginLoad` gains a `CRASHED` state so the audio thread passes audio through
  and the UI can offer a reload. `CommandWorker::poll_devices` sees `!is_alive()` (or `is_hung()`),
  marks the device crashed, sends `<device addr>/loading_state = "crashed:<reason>"` and
  `<device addr>/crashed [reason, stderr, pid, log_path]`, and logs the host's stderr tail.
- Hung hosts: a blocking request that exceeds `REQUEST_TIMEOUT` (5 s) sets a `hung` flag on the
  host, and a published block the host leaves unfinished for `HUNG_STALL_TIMEOUT` (1 s of wall
  time, `done_seq` not moving) means it isn't processing. Either one makes the command thread kill
  the process and treat it as crashed. A plugin that is only slow (finishes every block late) just
  drops out; it is never killed. Neither check applies to a host under a debugger (below).
- Reload (`<device addr>/reload` → `AudioCommand::ReloadDevice`) shuts the crashed instance down,
  spawns a fresh host for the same instance id, restores the last saved state blob
  (`PluginCommand::LoadState`), re-activates, re-sends the engine's cached parameter values
  (covers plugins without a state extension) and waits for `DeviceReady` to re-advertise the
  parameters. It runs on a background thread (`PluginLoadRequest::spawn`) with a fresh
  `PluginLoad`, so the audio thread keeps passing audio through until the new host is ready.
- State blobs: the host implements CLAP's state extension (`save`/`load` on the main thread).
  `mark_dirty` (HostState registered) or any parameter change sets the adapter's dirty flag; the
  command thread refreshes the blob at most once per 30 s while dirty, and on `{device}/state/save`
  (project save; see the OSC reference). `{device}/state/load` also replaces the saved blob.
  Each request carries an `alive` flag cleared by the adapter's `Drop`, so a load in flight for a
  removed device cleans its host up instead of orphaning it.
- Removing a device shuts its host down: `Shutdown`, then `SIGKILL` if it hasn't exited within 1 s
  (the watcher reaps it; nothing waits on a zombie).
- Shared-memory handles stay owned by `ProcessManager`; dropping the last `Arc` cleans up OS
  resources automatically.
- When debugging, confirm the subprocess binary is alive and still holds its descriptors
  (`/proc/<pid>/fd/3` is the control socket, `/proc/<pid>/fd/4` the doorbell). A plugin that misses
  deadlines logs a WARN after 8 consecutive misses and shows up in `EngineStats::plugin_underruns`.

## Debuggability (Phase 6)

- **Per-host log files.** Each host writes `Engine/logs/plugins/<host key>-<pid>.log` (key made
  file-safe by `protocol::log_file_name`): DEBUG and up, unbuffered, so the lines before a crash
  are on disk. `SONARA_PLUGIN_LOG` (an `EnvFilter` directive) changes the file's filter. The engine
  logs `Plugin host <key> logs to <path>` on spawn, keeps the newest `PLUGIN_LOGS_KEPT` (50) files
  at startup, and puts the path in the crash status and popup.
- **Instance in every line.** Work for an instance runs inside its `instance{id=… plugin=…}` span
  (`logging::instance_span`, a root span created once per instance and stored in
  `SubprocessHostShared`/`PluginState`). The main loop enters it per command and per
  `service_plugin_side`, plugin log callbacks (`HostLog`, any thread) enter it themselves, and the
  audio thread enters it only on the paths that log. Before a plugin has loaded, its `Initialize`
  runs in a provisional span named after the plugin id.
- **Forwarded warnings.** A tracing layer in the host turns WARN and ERROR events into
  `HostMessage::Log { instance_id, plugin, level, message }` (instance and plugin read from the
  enclosing span), at most 20 per second; the rest are counted and reported in one line. The main
  loop sends them; the engine's reader thread logs them as `Plugin <name> (instance <n>, host <key>
  (pid <pid>)): <message>`, so they reach `last_warn.log` and Godot's `/log`. INFO and DEBUG stay in
  the host's file.
- **Per-plugin stats.** The host times each `process()` call and stores it in
  `BlockControl::process_ns`. The adapter adds it to `PluginBlockStats` (blocks, process time sum
  and max, block time, peak share, longest miss run) on the audio thread; the command thread merges
  a second's worth and sends `<device addr>/stats` (`EngineStatus::PluginStats`). `struggling` is 8+
  consecutive misses (`MISSES_BEFORE_WARNING`). Godot shows it in the device header tooltip, an
  amber ring on the device light, and a worst-plugins list in `EnginePanel`.
- **Debugger support.** `SONARA_PLUGIN_HOST_WRAPPER` (shell-split, e.g. `gdb -q -batch -ex run -ex
  bt --args` or `valgrind`) is prepended to the host command line. `SONARA_PLUGIN_HOST_WAIT=1` makes
  each host log its pid, allow any process to ptrace it (`PR_SET_PTRACER_ANY`, since Yama's default
  scope only lets a parent attach) and wait until a debugger is attached and continues; it exits if
  the engine hangs up meanwhile. Either variable puts `ProcessManager` in debug mode
  (`HostLaunch::is_debugging`): the host's stderr goes to the engine's terminal instead of the
  tail pipe, requests wait up to 2 minutes, and neither a request timeout nor a stalled block marks
  the host hung. Under a wrapper the child pid is the wrapper's, so the crash reason names the
  wrapper and the log path is only known by pattern.
- **Probe.** `plugin_host --probe <path.clap> [--id <plugin id>] [--rate <hz>] [--block
  <frames>]` loads one plugin without the engine: prints the bundle's plugins, the descriptor, the
  extensions the host uses, parameters, audio and note ports, a state save/load round trip and the
  latency, then processes 1 s of silence and 1 s with a C3 note (held 0.5 s) through the same
  stereo-in/stereo-out buffers the engine passes, reporting per-block time and output peak. Exit
  code 1 on any error. It runs on one thread, so `gdb --args plugin_host --probe …` reproduces
  plugin bugs directly.
