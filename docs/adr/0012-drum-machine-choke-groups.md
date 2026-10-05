# 0012 — Drum Machine choke groups

Status: superseded by 0015 (choke targets). The `choke(frame_offset)` seam and the 3 ms fade
still apply; only the group model was replaced.

## Context

Closed and open hi-hats (and muted variants of other drum voices) must silence each other: a
closed hat cuts the ringing open hat, and vice versa. Spec 013's drum devices are separate,
small, one-shot instruments (decision 1), and note-off is ignored (decision 3), so a device
alone cannot know that a sibling pad should stop when it starts. Choking is a relationship
between pads, not a property of one drum.

Choke groups are therefore a Drum Machine feature (spec 013, decision 8), not something a drum
device implements. They change the Drum Machine's persisted state and its OSC surface, so they
get their own ADR.

## Decision

- A Drum Machine slot carries a **choke group**: `0` means none, `1`–`8` are groups. Group 0 is
  the default.
- When a note-on (`velocity > 0`) routes to a slot whose group is non-zero, the Drum Machine
  calls `choke(frame_offset)` on every **other** slot in the same group, using the **same frame
  offset** as the triggering note. Routing is real-time safe: a fixed-capacity scan of the slot
  list, no allocation.
- `AudioDevice` gains `fn choke(&mut self, _frame_offset: usize) {}`, defaulting to a no-op, so
  devices that cannot choke are unaffected. `DrumHost` (every drum device) implements it: it
  queues the offset and, in the next block, begins a ~3 ms linear fade to silence on the final
  mono mix at that offset. When the fade reaches 0 the host resets both voices, so it can sleep.
- The offset makes the choke sample-accurate, matching the triggering note.
- The group crosses OSC as `/channel/{id}/device/{path}/slot/{n}/choke <i:group>` and is stored
  per slot in the Drum Machine's state.

## Consequences

- Choke groups belong to the container, so any Drum Machine pad (a drum, a Sampler, a Chain, a
  CLAP plugin) can be choked if it honours `AudioDevice::choke`; devices that don't simply keep
  sounding.
- Each drum device only needs to know how to fade itself; it never learns about its siblings.
  The same `choke` seam could later serve other grouping features.
- The fade is a fixed ~3 ms regardless of the drum's own decay, and it resets the voices rather
  than letting their tails finish, which is what hat choking requires.
- DAWproject has no mapping for choke groups. Export keeps them in Sonara's own `State` JSON and
  lists them in the transfer report (`drum_choke_group`) as **lost** when moving to other
  applications; they are restored only from a Sonara project.

References: `docs/specs/013-drum-synths/plan.md`, `docs/subsystems/osc-protocol.md`
