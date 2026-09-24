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

## Allocation checker (`rt-debug`)
- `SONARA_FEATURES=rt-debug ./run_release.sh` (or `cargo build --release --features rt-debug`) installs `assert_no_alloc`'s counting allocator and wraps the callback body in `assert_no_alloc`. Violations are counted, not fatal.
- Every 0.5 s the callback logs a WARN `rt-debug: audio thread (de)allocations since last report (<total> total): <section>: <count>, …`. Sections are named regions marked with `rt_debug::section(name, || …)` (`audio/rt_debug.rs`). Wrap a suspect region in a new section to narrow a violation down; allocations outside any inner section show as `callback (unattributed)`.
- The crate also prints `Tried to (de)allocate memory in a thread that forbids allocator calls!` to stderr once per offending callback.
