# <Feature> — Requirements

<!-- What the system must do. No technology choices, no file names, no "how".
     Every requirement gets an id: REQ-001, REQ-002, …
     Requirements are testable or they are not requirements. -->

## Problem

<!-- 2-5 sentences: what is wrong or missing today, and who notices. -->

## Scope

| | |
|---|---|
| Subsystem | Engine / Godot / both / docs only |
| Touches real-time audio thread | no / yes — if yes, design must respect the audio-thread contract |
| Adds or changes an OSC message | no / yes — if yes, protocol docs are part of the definition of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no / yes — if yes, name the migration |

## Requirements

<!-- EARS patterns:
     Ubiquitous      The <system> shall <response>.
     Event-driven    WHEN <trigger>, the <system> shall <response>.
     State-driven    WHILE <state>, the <system> shall <response>.
     Optional        WHERE <feature is configured>, the <system> shall <response>.
     Unwanted        IF <condition>, THEN the <system> shall <response>.
     Use the real subsystem name (the audio callback, the mixer, the clip editor), not "the app". -->

### REQ-001 — <short title>

The <system> shall <observable response>.

- **Acceptance:** <the check that proves it — a command, a test, or a live observation>
- **Example:** <input → expected result, with real values>

### REQ-002 — <short title>

WHEN <trigger>, the <system> shall <response>.

- **Acceptance:** …

## Non-functional

<!-- Only the ones that actually bind. Delete the rest. -->

- **Real-time safety:** <what the audio callback may and may not do>
- **Latency / performance:** <budget, or "unchanged">
- **Compatibility:** <older projects/config, engine↔Godot version skew>

## Out of scope

- <explicitly not doing this, so design doesn't invent it>

## Open questions

- [ ] <question that blocks design.md — resolve before the design gate>
