---
trigger: always_on
---

# Programming Guidelines

## Rules and Principles

1. Files should never be more than 1000 lines and ideally less than 600 lines. If this occurs, refactor asap.
2. DRY: Don't repeat yourself. Using the same logic twice? Abstract.
3. KISS: Prefer simple boring solutions over clever tricks - especially hacky workarounds.
4. Confusing organization? Stop and re-think, ask the user (I.E "Should I move X to Y and reorganize this?")
5. Fail fast, print to console during feature development and testing. For debuggng, add extensive logs and ask the user to report back.