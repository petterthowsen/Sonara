# 0001 — CLAP plugins run out-of-process

Status: accepted

## Context

Third-party CLAP plugins are untrusted native code: they crash, they need GUI/event-loop
integration that fights the engine's threads, and they can destabilise a real-time process.

## Decision

CLAP plugins run in `plugin_host` subprocesses, never inside the engine. By default each
instance gets its own process; hosting modes can group instances (see ADR-0009). The engine
talks to a host through the `audio/ipc` layer: a length-prefixed binary control protocol over a
Unix `socketpair`, plus a per-instance shared-memory block (memfd) that carries audio and
frame-stamped events, processed synchronously each callback through a futex doorbell.
`SubprocessClapAdapter` implements the `AudioDevice` trait on the engine side.

## Consequences

- Crash isolation and GUI compatibility come for free. This is process isolation, not a
  security sandbox: the host runs with the user's permissions.
- Two binaries must be built with the same profile — `ProcessManager` spawns `plugin_host`
  from the engine executable's own directory, so a bare `cargo run` (which builds only
  `engine`) breaks CLAP with "plugin_host binary not found". The run scripts use `--bins`.
- The audio thread only reads an atomic load state (`PluginLoad`) and waits on the shared
  block up to one deadline per callback; while a plugin is Loading, Failed or Crashed the
  adapter passes audio through, and a missed deadline costs that plugin one block.
- Fire-and-forget commands (`SetParameter`, `OpenGui`, `Reset`) so edits apply while audio
  is stopped; only non-audio threads may issue blocking IPC (`GetParameter`).

References: `docs/subsystems/engine-plugin-architecture.md`, `docs/engine-stability-plan.md` (phases 2–3), ADR-0009
