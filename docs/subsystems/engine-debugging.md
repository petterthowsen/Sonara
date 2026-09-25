# Debugging

## Log File Layout
- Runtime logs live in `Engine/logs/`.
- The engine writes three live files per session: `last_info.log` (exactly INFO), `last_warn.log` (WARN+), and `last_combined.log` (INFO+).
- When Godot sends `/project/init`, the server rotates the live files to timestamped `logs/session_<YYYYMMDD_HHMMSS>_{info|warn|combined}.log` and recreates the `last_*` trio.
- Rotation keeps the newest five archives per severity and deletes older ones, so scrape logs before triggering many sessions in a row.

## Forwarding to Godot
- `osc::server` relays log messages to Godot via `/log` with `[level, message]`; `AudioEngineOSC` emits `engine_log_message(level, message)` and prints WARN/ERROR to the editor console.

## Godot logs
Godot also logs into `Godot/logs/last.log` (including engine warn and above via OSC). 

## Practical Tips
- Use `tail` and `grep` intelligently to find specific events.
- For archived evidence, attach the freshest `logs/session_*.log` trio after reproduction—the filenames encode wall-clock order.
## Audio thread performance
- `/status/engine_stats` (2 Hz) carries load average and peak, xruns, lock misses and block size. `EnginePanel` shows them; a counter turns red for 5 s after it goes up.
- The OSC status thread logs one INFO line per minute: `Engine stats (60s, <frames> frames): load avg …, load peak …, xruns/min …, lock misses/min …`. These are the numbers for the Measurements table in `docs/engine-stability-plan.md`.
- Plugin dropouts (`plugin_underruns`) count blocks where a CLAP plugin's output wasn't ready and the adapter padded it with silence. The command thread logs a WARN per affected plugin every 10 s: `Plugin <id> (channel … device …) in the last 10s: N dropout blocks …`. Crackling with 0 xruns but rising plugin dropouts is the plugin host, not the engine or PipeWire.
- Xruns are mostly detected from callback gaps: cpal 0.15's ALSA backend recovers underruns without calling the error callback.
- Crackling with 0 xruns and normal load usually means an underrun inside PipeWire, which the engine can't see. Run `timeout 6 pw-top -b -n 3`. A growing ERR count on the output sink, or a sink QUANT larger than the engine's buffer, confirms it. Check `pw-metadata -n settings 0` for a leftover `clock.force-quantum` and clear it with `pw-metadata -n settings 0 clock.force-quantum 0`.

## Plugin host IPC
- `SONARA_IPC_TRACE=1 ./run_release.sh` logs every control-channel frame as INFO, decoded as `Debug`: `[ipc] send …` / `[ipc] recv …` in the engine log (from the engine side) and on stderr from each `plugin_host` (inherited). Each line shows the frame size and how many file descriptors rode along.
- Match a request to its reply by `request_id` (per host process). `request_id: 0` is fire-and-forget. A late reply after a timeout is dropped with a DEBUG line.
- Every message names its `instance_id`; the engine log line `Plugin <id> initialized as instance <n> (host pid <pid>)` maps it to a plugin and process.

## Plugin hosts (Phase 6)
- **Logs.** Each `plugin_host` writes `Engine/logs/plugins/<host key>-<pid>.log` (DEBUG and up; e.g. `instance-3-12345.log`, `plugin_michaelwillis.dragonfly.room-12345.log`). Every line about an instance carries `instance{id=… plugin=…}`, so a shared host's file can be grepped per plugin. The engine log names the file when it spawns the host (`Plugin host <key> logs to …`), and a crash report ends with it. `SONARA_PLUGIN_LOG=trace ./run_release.sh` changes the file's filter (`EnvFilter` syntax). The newest 50 files are kept.
- WARN and ERROR from a host also land in the engine's `last_warn.log` and Godot's `/log` as `Plugin <name> (instance <n>, host <key> (pid <pid>)): …`, capped at 20 per second per host.
- **Stats.** The device header tooltip shows a plugin's process time (average and peak share of the block, µs) and its dropouts; `EnginePanel` lists the worst three (hover for ten). An amber ring on the device light means 8+ missed deadlines in a row. The numbers come from `<device addr>/stats`, once a second, timed inside the host (IPC excluded). A plugin whose peak share is low but which still drops out points at the handshake or scheduling, not the plugin's DSP.
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
