# <Feature> — Tasks

<!-- Ordered, dependency-aware. Every task traces to a REQ id and carries a checkable
     _Verify_ line — a task without one cannot be marked [x].
     Phase 1 is usually "wire the message end to end", then behaviour, then UI, then docs.
     Keep tasks small enough that one is one sitting. -->

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — <foundation>

- [ ] **T-001** [REQ-001] <what to build>
  - _Files_: `<path>`
  - _Output_: <the thing that exists when this is done>
  - _Verify_: `<command or observation that proves it>`
  - _Depends on_: —

- [ ] **T-002** [REQ-001] <what to build>
  - _Files_: `<path>`
  - _Output_: …
  - _Verify_: …
  - _Depends on_: T-001

## Phase 2 — <behaviour>

- [ ] **T-003** [REQ-002] <what to build>
  - _Files_: `<path>`
  - _Output_: …
  - _Verify_: …
  - _Depends on_: T-002

## Phase 3 — <UI / integration>

- [ ] **T-004** [REQ-003] <what to build>
  - _Files_: `<path>`
  - _Output_: …
  - _Verify_: …
  - _Depends on_: T-003

## Phase 4 — docs

- [ ] **T-005** [REQ-all] Update `OSC_PROTOCOL.md` for every new or changed message.
  - _Files_: `OSC_PROTOCOL.md`
  - _Output_: address, argument types and direction documented
  - _Verify_: every message added by this spec appears in the doc
  - _Depends on_: T-001

## Phase 5 — live verification

- [ ] **T-006** [REQ-all] Verify live with the engine and Godot running.
  - _Files_: —
  - _Output_: `TODO.md` entry marked `[x]`; `STATUS.md` notes what was and wasn't checked
  - _Verify_: <the exact manual steps, and what to listen/watch for>
  - _Depends on_: T-005
