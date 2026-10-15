# Debugging

## Log File Layout
- Runtime logs live in `$XDG_STATE_HOME/sonara/logs/engine/` (default `~/.local/state/sonara/logs/engine/`), whoever started the engine. `--log-dir <path>` overrides it; the engine publishes the directory in `SONARA_LOG_DIR` so plugin hosts follow. Nothing is written to the working directory or the install folder. Help > Open Logs Folder in the UI opens the parent `logs/` folder.
- The engine writes three live files per session: `last_info.log` (exactly INFO), `last_warn.log` (WARN+), and `last_combined.log` (INFO+).
- When Godot sends `/project/init`, the server rotates the live files to timestamped `logs/session_<YYYYMMDD_HHMMSS>_{info|warn|combined}.log` and recreates the `last_*` trio (in the same directory).
- Rotation keeps the newest five archives per severity and deletes older ones, so scrape logs before triggering many sessions in a row.

## Forwarding to Godot
- `osc::server` relays log messages to Godot via `/log` with `[level, message]`; `AudioEngineOSC` emits `engine_log_message(level, message)` and prints WARN/ERROR to the editor console.

## Godot logs
The UI logs into `~/.local/state/sonara/logs/ui/last.log` (including engine warn and above via OSC), via `AppPaths.ui_log_dir()`. Headless tests (`-- --test`) keep `Godot/logs/last.log` so a test run never touches the real log; `tests/run_all.sh` also writes `Godot/logs/tests_last.log`.

## Practical Tips
- Use `tail` and `grep` intelligently to find specific events.
- For archived evidence, attach the freshest `logs/session_*.log` trio after reproduction—the filenames encode wall-clock order.
## Audio thread performance
- `/status/engine_stats` (2 Hz) carries load average and peak, xruns, lock misses and block size. `EnginePanel` shows them; a counter turns red for 5 s after it goes up.
- The OSC status thread logs one INFO line per minute: `Engine stats (60s, <frames> frames): load avg …, load peak …, xruns/min …, lock misses/min …`. These are the numbers for the Measurements table in `docs/engine-stability-plan.md`.
- Plugin dropouts (`plugin_underruns`) count blocks where a CLAP plugin's output wasn't ready and the adapter padded it with silence. The command thread logs a WARN per affected plugin every 10 s: `Plugin <id> (channel … device …) in the last 10s: N dropout blocks …`. Crackling with 0 xruns but rising plugin dropouts is the plugin host, not the engine or PipeWire.
- Xruns come from different sources per driver. PipeWire (native): cpal reports them through its error callback (`ErrorKind::Xrun`), and the callback-gap detection and pw-top's ERR count are not used. ALSA: mostly callback gaps (the backend recovers underruns without calling the error callback), plus pw-top's ERR count on the engine's node when PipeWire sits underneath.
- Crackling with 0 xruns and normal load on ALSA usually means an underrun inside PipeWire, which the engine can't see. Run `timeout 6 pw-top -b -n 3`. A growing ERR count on the output sink, or a sink QUANT larger than the engine's buffer, confirms it.
- On the PipeWire driver the engine itself forces `clock.force-quantum` and `clock.force-rate` (to the buffer size and sample rate) while it runs, and restores the old values on a clean exit, Ctrl+C/SIGTERM or a switch to ALSA. After a crash or SIGKILL they stay set: check `pw-metadata -n settings 0` and clear them with `pw-metadata -n settings 0 clock.force-quantum 0` and `pw-metadata -n settings 0 clock.force-rate 0`.
- If another application (e.g. a DAW started later) changes the forced values, the engine follows it and `/audio/config` `mismatch` says "Another application forces PipeWire to …"; the next buffer or rate change forces again. The engine leaves such values alone on exit.
- `/audio/config` carries the measured output latency and whether realtime scheduling was granted (`realtime`: granted/denied/unknown); the info lines in Settings › Audio › Output show them.

## Plugin host IPC
- `SONARA_IPC_TRACE=1 ./run_release.sh` logs every control-channel frame as INFO, decoded as `Debug`: `[ipc] send …` / `[ipc] recv …` in the engine log (from the engine side) and on stderr from each `plugin_host` (inherited). Each line shows the frame size and how many file descriptors rode along.
- Match a request to its reply by `request_id` (per host process). `request_id: 0` is fire-and-forget. A late reply after a timeout is dropped with a DEBUG line.
- Every message names its `instance_id`; the engine log line `Plugin <id> initialized as instance <n> (host pid <pid>)` maps it to a plugin and process.

## Plugin hosts (Phase 6)
- **Logs.** Each `plugin_host` writes `<engine log dir>/plugins/<host key>-<pid>.log` (DEBUG and up; e.g. `instance-3-12345.log`, `plugin_michaelwillis.dragonfly.room-12345.log`). Every line about an instance carries `instance{id=… plugin=…}`, so a shared host's file can be grepped per plugin. The engine log names the file when it spawns the host (`Plugin host <key> logs to …`), and a crash report ends with it. `SONARA_PLUGIN_LOG=trace ./run_release.sh` changes the file's filter (`EnvFilter` syntax). The newest 50 files are kept.
- WARN and ERROR from a host also land in the engine's `last_warn.log` and Godot's `/log` as `Plugin <name> (instance <n>, host <key> (pid <pid>)): …`, capped at 20 per second per host.
- **Stats.** The device header tooltip shows a plugin's process time (average and peak share of the block, µs) and its dropouts; `EnginePanel` lists the worst three (hover for ten). An amber ring on the device light means 8+ missed deadlines in a row. The numbers come from `<device addr>/stats`, once a second, timed inside the host (IPC excluded). A plugin whose peak share is low but which still drops out points at the handshake or scheduling, not the plugin's DSP.
- **Load and RAM in the tooltip.** The device header tooltip also reads "Load 3.2% (peak 7.1%) · RAM 412 MB (shared by 2)" (`DeviceInstance.Usage`). Load is the engine-timed `(avg, peak)` from `/status/channel_perf` (IPC included, top-level devices only); RAM is `<device addr>/memory`. The engine reports them only while subscribed: `EnginePanel` subscribes while its popup is open and for 5 s after a device header is hovered (`request_device_stats`), so the first tooltip after a long pause can lack figures until the next 500 ms report. The popup also shows `RAM: engine · plugins · total`.
- **Probe a plugin on its own**: `Engine/target/release/plugin_host --probe ~/.clap/Foo.clap [--id <plugin id>] [--rate 44100] [--block 256]`. It prints the plugin's descriptor, parameters, ports, latency, a state round trip, and timing and output peak for 1 s of silence plus 1 s with a C3 note. No engine or Godot involved; run it under `gdb --args` or `valgrind` directly.
- **Run every host under a debugger or tool**: `SONARA_PLUGIN_HOST_WRAPPER="gdb -q -batch -ex run -ex bt --args" ./run_release.sh` prints a backtrace in the engine's terminal when a host crashes. `SONARA_PLUGIN_HOST_WRAPPER=valgrind` works the same way (expect plugins to run far slower).
- **Attach to a host**: `SONARA_PLUGIN_HOST_WAIT=1 ./run_release.sh`. Each host logs `Plugin host <key> (pid N) is waiting for a debugger: gdb -p N` (also on Godot's `/log`) and waits; attach with `gdb -p N` and `continue`. It exits by itself if the engine stops first.
- Both variables switch off hung-host killing and stretch request timeouts to 2 minutes, so a host at a breakpoint isn't killed. The engine logs a WARN at startup when they are set. The host's stderr then goes to the engine's terminal, not the crash report.
- **Simulating a crash:** `kill -SEGV <pid>` does nothing the first time. Rust's runtime catches SIGSEGV for its stack-overflow check; for a fault that isn't a stack overflow it resets the handler and returns, expecting the faulting instruction to fault again. A `kill` has no faulting instruction, so only the second SIGSEGV kills. Send it twice, or use `kill -ABRT`/`kill -KILL`. A real segfault in a plugin dies at once.

## Allocation checker (`rt-debug`)
- `SONARA_FEATURES=rt-debug ./run_release.sh` (or `cargo build --release --features rt-debug`) installs `assert_no_alloc`'s counting allocator and wraps the callback body in `assert_no_alloc`. Violations are counted, not fatal.
- Every 0.5 s the callback logs a WARN `rt-debug: audio thread (de)allocations since last report (<total> total): <section>: <count>, …`. Sections are named regions marked with `rt_debug::section(name, || …)` (`audio/rt_debug.rs`). Wrap a suspect region in a new section to narrow a violation down; allocations outside any inner section show as `callback (unattributed)`.
- Confirming a clean run: the INFO log shows `rt-debug: audio thread allocation checker is active` once, then `rt-debug: N audio thread (de)allocations in the last minute` every minute, including when N is 0. If the first line is missing, the binary wasn't built with the feature.
- The crate also prints `Tried to (de)allocate memory in a thread that forbids allocator calls!` to stderr once per offending callback.
