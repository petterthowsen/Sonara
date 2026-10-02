# 0013 — Multiband FX has six fixed band positions with per-band Active

Status: accepted

## Context

Multiband FX (spec 016) splits a signal into bands and runs a slot chain on each. The band count
could be a parameter (N bands, crossovers between them) or the bands could be fixed positions that
are switched on and off. The choice decides what is persisted and what automation targets. A
count-based layout renumbers bands whenever one is added or removed, so a parameter ID or a child
index means a different band afterwards.

## Decision

- There are **six fixed band positions** in frequency order. Band 1 is always the lowest range,
  band 6 the highest; positions never reorder. Each has an `Active` parameter and any 2–6 are
  active (default {1, 3, 5}). There is no band-count parameter.
- **Every position has the same parameter block** whether active or not (IDs `10·p + 0..4`, plus
  Mix `0` and Output `1`). Automation on a band's controls therefore survives other bands being
  toggled.
- **Each band owns its low edge** (`Low Edge`, bands 2–6). An active band covers its edge up to the
  next active band's edge; the lowest active band extends to 0 Hz and the highest to Nyquist. The
  crossovers are the edges of all active bands except the lowest. The engine keeps them ascending
  itself, so automation or a bad preset cannot cross bands.
- A Multiband FX **always has exactly six children**, the slot chains of bands 1–6. Band position
  is child index + 1. Chains are never removed or reordered; disabling a band empties its chain.
- `Active` is not automation-safe: changing it changes the topology.

## Consequences

- Project files, presets and automation reference bands by stable position, not by count.
- Toggling a band moves audio between neighbours (the disabled range merges into the band below),
  which is handled by a short fade in the engine and by Godot placing edges on enable.
- Hand-edited or older projects may have a different child count. The engine tolerates it (a
  missing child is a pass-through band, a 7th is dropped) and Godot pads missing chains on load.
- DAWproject has no mapping for this container; it goes in the transfer report.

References: `docs/specs/016-multiband-fx/plan.md`, `docs/subsystems/osc-protocol.md`
