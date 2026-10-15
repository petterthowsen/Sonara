# 0022 — The UI owns the engine process

Status: accepted (spec 046, `docs/specs/046-beta-release/`).

## Context

Until the beta, the developer started the engine by hand (`run_engine.sh`) and then the Godot UI.
A user who installs a package has no terminal. The UI therefore has to find, start and stop the
engine, while the developer workflow (engine started separately, UI attaches) must keep working.
Three failure modes matter: a second engine fighting for UDP 7000, an engine that survives a
crashed UI, and an engine killed so hard that PipeWire's forced quantum stays set.

## Decision

- **Attach or launch, decided by a bind probe.** The `EngineProcess` autoload binds UDP
  `127.0.0.1:7000` with `PacketPeerUDP`. If the bind fails, an engine owns the port: the UI attaches
  and never stops it (`owned` stays false). If it succeeds, the UI releases the port and starts the
  engine binary (next to the UI executable in an install, `Engine/target/release/engine` in a dev
  run) with `--log-dir <dir> --parent-pid <ui pid>`. The probe is instant; waiting for a heartbeat
  would add about a second to every launch. It is valid because the engine's Rust `UdpSocket` sets
  no `SO_REUSEADDR` (checked in spec 046 T-001 against a plain-socket holder).
- **Graceful stop first.** On quit the UI sends `/engine/quit` through a socket of its own, polls
  `OS.is_process_running` for up to 3 s, then `OS.kill`s (SIGKILL). `/engine/quit` makes the OSC
  server loop return so `main` takes its normal path and restores PipeWire's forced quantum and
  rate. SIGKILL skips that restore, so it is only the fallback.
- **Parent-death signal against orphans.** With `--parent-pid`, the engine calls
  `prctl(PR_SET_PDEATHSIG, SIGTERM)` at start and exits at once if `getppid()` already differs from
  the given pid (the UI died before the call). The SIGTERM reaches the existing `ctrlc` handler,
  which restores the PipeWire quantum.
- **The signal follows the parent thread, not the process.** The kernel sends `PDEATHSIG` when the
  *thread* that forked the child exits. `EngineProcess` therefore calls `OS.create_process` only
  from Godot's main thread (button handlers and `await`s in `Editor` and `EnginePanel` resume on
  it), which lives as long as the UI process. Never spawn the engine from a `Thread` or a
  `WorkerThreadPool` task: the engine would get SIGTERM when that worker ends. A comment in
  `EngineProcess.gd` says so.
- **One UI at a time.** A PID file in `$XDG_RUNTIME_DIR/sonara/ui.pid`, valid while the process
  lives and runs the same executable (`/proc/<pid>/exe`), makes a second launch show a message and
  quit before it creates sockets or starts an engine. A bind probe on 7001 was rejected because
  Godot may set `SO_REUSEADDR` on UDP sockets, which would make it unreliable.

## Rejected alternatives

- **Heartbeat watchdog in the engine** (exit when the UI's messages stop). It would kill an engine
  that is only waiting through a long UI stall such as a big project sync, and the engine already
  sends heartbeats the other way for the UI's benefit.
- **Always spawn a private engine and let it pick a free port.** Needs configurable OSC ports,
  which are out of scope, and breaks the attach workflow.

## Consequences

- `run_engine.sh`, `run_release.sh` and `godot --path Godot` still work: the UI attaches, or in a
  dev run starts the release engine if one is built.
- An engine started by the UI logs to the same place as one started by a script
  (`~/.local/state/sonara/logs/engine/`).
- `PR_SET_PDEATHSIG` is Linux-only, in line with the project (Windows and macOS are out of scope).
- New OSC messages: `/engine/quit` and `/status/engine_info` (see `docs/subsystems/osc-protocol.md`).
