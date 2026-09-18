# 0004 — Sample-accurate MIDI via (tick, frame_offset) pairs

Status: accepted

## Context

Note events are authored in ticks (musical time), but must land on exact audio samples for
tight timing, independent of project tempo, PPQ, or buffer size.

## Decision

Each callback precomputes `(tick, frame_offset)` pairs for the buffer, using the real
device sample rate — never the project setting. Instruments receive events through the
single contract point `AudioDevice::send_midi_event(..., frame_offset)` and queue them
(sorted) for their next `process_block`. Devices must consume `frame_offset` directly and
never convert it back to ticks. Live MIDI from Godot plays with a fixed one-buffer latency
(drain of the lock-free `MidiEventQueue` at callback start).

## Consequences

- Envelopes and plugin voices line up exactly with buffer positions.
- Any device that recomputes offsets from ticks reintroduces drift — this is a hard rule.
- Sequencing resolution is 960 PPQ; Middle C = C3 = MIDI note 60.

References: `docs/subsystems/engine-architecture.md`, `docs/subsystems/engine-audio-thread.md`
