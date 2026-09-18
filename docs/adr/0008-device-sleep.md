# 0008 — Devices sleep after ~3 s of idle

Status: accepted

## Context

Dozens of devices processing silence every buffer wastes CPU that a real-time DAW cannot
spare.

## Decision

Each device carries a `DeviceSleepState`: after `DEFAULT_SLEEP_TIMEOUT` (3 s) with no
signal above `SLEEP_THRESHOLD` and no MIDI/parameter activity, it sleeps and
`Channel::process_device_chain` skips its processing. MIDI input (or any activity) wakes
it immediately via `mark_activity`. Sleep transitions are reported to Godot as
`/channel/{id}/device/{pos}/sleep`.

## Consequences

- Idle channels cost almost nothing; a project can hold many tracks.
- Effects with tails (reverb/delay) ring out naturally because activity resets the timer,
  and route targets keep processing even with no input once they receive any signal.
- Devices must call `mark_activity` on real input or they will wrongly sleep mid-tail.

References: `docs/subsystems/engine-architecture.md`
