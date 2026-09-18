# 0007 — The audio engine is the master clock

Status: accepted

## Context

Transport time could live in the sequencer, the UI, or the audio callback. Anything other
than the audio callback drifts against actual sound.

## Decision

The audio callback is the sole authority on transport time: it advances the transport,
maintains both `current_tick` and `current_sample_position`, and reports playhead/meters
to Godot at ~20 Hz. Godot interpolates locally for smooth display. All tick/sample
conversions go through `ProjectSettings::{ticks_to_samples, samples_to_ticks}` with the
device sample rate passed explicitly. Audio clip playback positions are tracked
continuously frame-by-frame (fractional samples), never recalculated from tick position,
because that aliases at high stretch factors.

## Consequences

- UI transport state is a cached mirror, only as fresh as the last status packet.
- Seek/stop reset per-instance clip playback positions in the engine, not the UI.
- Any time math that bypasses `ProjectSettings` conversions is suspect.

References: `docs/subsystems/engine-architecture.md`, `docs/subsystems/engine-audio-thread.md`
