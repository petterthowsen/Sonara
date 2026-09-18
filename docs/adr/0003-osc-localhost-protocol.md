# 0003 — Engine and UI talk over OSC on localhost UDP

Status: accepted

## Context

The Godot UI and the Rust engine are separate processes with separate lifetimes; the UI must
tolerate the engine being absent (engine not started, crashed, restarted).

## Decision

They communicate exclusively via OSC over UDP on localhost: Godot sends to port 7000, the
engine replies to port 7001. Addresses are resource-based with embedded IDs (RESTful style):
`/channel/{id}/volume`, `/clip/{id}/load_state`. The OSC server (main thread) turns messages
into `AudioCommand`s for the command thread; engine-side events flow back as `EngineStatus`
→ OSC → Godot signals. Status and meters are sent at ~20 Hz, not per buffer.

## Consequences

- The UI must reconcile state on (re)connect: data models resend full state via
  `sync_to_engine()`, and `req_id` tokens correlate async audio-file jobs whose late
  completions must be ignored.
- Adding a message means touching `osc/server.rs`, `audio/commands.rs`, and
  `OSC_PROTOCOL.md` together.
- 20 Hz status means Godot interpolates the playhead locally for smoothness.
- Text/binary payloads (waveform levels, device data streams) travel as OSC blobs.

References: `docs/subsystems/osc-protocol.md`, `docs/subsystems/godot-osc.md`
