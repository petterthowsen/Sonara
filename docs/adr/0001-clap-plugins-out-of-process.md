# 0001 — CLAP plugins run out-of-process

Status: accepted

## Context

Third-party CLAP plugins are untrusted native code: they crash, they need GUI/event-loop
integration that fights the engine's threads, and they can destabilise a real-time process.

## Decision

Each CLAP plugin instance runs in a dedicated subprocess (`plugin_host` binary). The engine
talks to it through the `audio/ipc` layer: a length-prefixed TCP command protocol plus
lock-free shared-memory ring buffers (memfd on Unix) for audio and MIDI. `SubprocessClapAdapter`
implements the `AudioDevice` trait on the engine side.

## Consequences

- Crash isolation, GUI compatibility, and a sandbox boundary come for free.
- Two binaries must be built with the same profile — `ProcessManager` spawns `plugin_host`
  from the engine executable's own directory, so a bare `cargo run` (which builds only
  `engine`) breaks CLAP with "plugin_host binary not found". The run scripts use `--bins`.
- The audio thread interacts only via `try_lock` on `LoadingState` and non-blocking ring
  buffer APIs; while a plugin is Loading/Failed the adapter passes audio through.
- Fire-and-forget commands (`SetParameter`, `OpenGui`, `Reset`) so edits apply while audio
  is stopped; only non-audio threads may issue blocking IPC (`GetParameter`).

References: `docs/subsystems/engine-plugin-architecture.md`
