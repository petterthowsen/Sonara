# 0015 — Drum Machine choke targets

Status: accepted. Supersedes 0012 (the relationship model only; the `choke` seam and the fade
stay as 0012 describes them).

## Context

0012 gave each Drum Machine pad a **choke group** (0 = none, 1–8). A group is symmetric: every
pad in it chokes every other pad in it. That covers a closed/open hat pair, but not a directed
relationship such as "the closed hat cuts the open hat, but the open hat does not cut the closed
hat", or "the crash cuts the ride but not the other way round". Spec 020 adds a pad context menu
with "Choke targets" and "Choked by" lists, which needs a directed model.

Directed targets can express every group (each member targets all the others), so keeping both
would only give two ways to say the same thing.

## Decision

- A Drum Machine pad stores its **choke targets**: the sibling pads a note-on on it chokes. The
  relation is directed. **Choked by** is not stored; it is derived from the siblings' targets, so
  there is one source of truth.
- Godot stores targets by the pads' stable child `id` (`DeviceInstance.choke_targets`), so they
  survive pad moves, reorders and save/load. A preset or duplicate that refreshes ids remaps the
  targets to the new ids (`DeviceInstance.refresh_ids_in_json`).
- The engine receives each pad's targets as a **128-bit note mask**:
  `/channel/{id}/device/{path}/slot/{n}/choke_targets <b:16 bytes>`, little-endian, bit *k* =
  the pad on note *k*. `DrumSlot.choke_targets: u128` is fixed-size, needs no allocation, and does
  not care about slot index changes. Godot re-sends every pad's mask whenever a pad's note
  changes or a pad is added or removed.
- On a note-on the Drum Machine calls `choke(frame_offset)` on every other slot whose note bit is
  set in the triggering slot's mask, at the same frame offset (same fixed-cost scan as 0012). The
  slot's own bit is ignored, and a note-off never chokes.
- `AudioDevice::choke` and the 3 ms `DrumHost` fade are unchanged from 0012.
- Projects saved with choke groups migrate on load: every pad in a non-zero group gets every
  other member of that group as a target, and the `choke_group` field is dropped.

## Consequences

- One-way chokes are possible, and the hat pair keeps working as two mutual targets.
- A removed pad's id stays in its siblings' in-memory targets so undo of the removal restores the
  choke, but it leaves the engine masks, the "choked by" list and the saved project.
- DAWproject still has no mapping. Export keeps targets in Sonara's own `State` JSON and lists
  them in the transfer report as `drum_choke`.

References: `docs/specs/020-drum-machine-pads/plan.md` (Phase 3), ADR 0012,
`docs/subsystems/osc-protocol.md`
