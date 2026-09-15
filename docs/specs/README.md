# Specs

Spec-driven development, Kiro style: agree on *what* and *how* in markdown before writing code,
then implement task by task against an approved plan.

No tooling — these are plain files. The procedure and the approval gates live in the
`spec-driven-development` Hermes skill, which reads the templates in `_templates/`.

## Layout

```
docs/specs/<NNN>-<slug>/
├── requirements.md   # what the system must do — EARS statements, REQ-xxx ids, no "how"
├── design.md         # how it will be built — grounded in real files and symbols
└── tasks.md          # ordered, dependency-aware steps, each traced to a REQ id
```

`<NNN>` is the next free number; `<slug>` is a short kebab-case feature name.
One directory per feature. Specs are historical records once implemented — don't rewrite
them to match what was actually built, except through the divergence gate below.

## Phase gates

Each artifact is approved before the next is written. Implementation starts only once
`tasks.md` is approved.

```
context → requirements.md ──approve──> design.md ──approve──> tasks.md ──approve──> implement → converge
```

If implementation must deviate from `design.md`: stop, explain the conflict, get approval,
**update `design.md` first**, then write the code.

## Task markers

Same convention as `TODO.md`:

| Marker | Meaning |
|---|---|
| `[ ]` | open |
| `[x?]` | implemented, not yet verified |
| `[x]` | verified — the task's `_Verify_` criterion was actually run |

## How this relates to the other tracking files

- `TODO.md` — the cross-feature backlog. A spec's tasks are the detail *inside* one item; add a
  one-line entry there when a spec starts, and mark it `[x?]`/`[x]` when the spec converges.
- `STATUS.md` — scratchpad for a single live investigation (what works, what doesn't). Use it
  while implementing a spec that is being debugged against a running engine.
- `docs/*.md` — architecture notes and audits that outlive a single feature. A spec should
  *link* to them, not duplicate them.
