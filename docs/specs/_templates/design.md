# <Feature> — Design

<!-- How it will be built. Every file and symbol named here must already exist, or be created
     by a task in tasks.md. Verify with search_files before writing a path — a spec that
     invents `FooManager.gd` is worse than no spec.
     Read AGENTS.md and the matching .cursor/rules/*.mdc for this subsystem first. -->

Implements [requirements.md](./requirements.md).

## Context

<!-- The existing machinery this has to fit into, with real paths and symbol names.
     e.g. `Engine/src/audio/commands.rs` — `AudioCommand` enum, applied by
     `audio/command_worker.rs` while holding the state lock only briefly. -->

- `<path>` — <what it does that matters here>

## Approach

<!-- The shape of the change, in prose. 1-3 paragraphs. Why this way and not the obvious
     alternative — the alternative that was rejected belongs here too. -->

## Thread and ownership

<!-- Which thread owns the new state, and how every other thread reaches it.
     For engine work this is the section that gets reviewed hardest. -->

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| <field> | command thread | preallocated scratch buffer, read under `try_lock` | yes / no |

## Data and protocol changes

<!-- OSC messages: address, argument types, direction, and the exact places that must change
     (handler in `osc/server.rs`, command in `audio/commands.rs`, `OSC_PROTOCOL.md`,
     `PLUGIN_OSC_PROTOCOL.md` for the subprocess).
     Godot models: which signal and setter are added, and how `sync_to_engine()` sends it.
     Persisted key: the `Settings.gd` registration and the default. -->

## File-by-file change list

| File | Change |
|---|---|
| `<path>` | <what changes> |

## Migration and compatibility

<!-- What happens to existing projects, config.json contents, saved layouts.
     "Nothing is persisted" is a valid answer — write it down. -->

## Test plan

<!-- Where the tests go: `mod tests` blocks inside the Rust source file for the engine,
     `Godot/ai/tests/` for GDScript. Name the test, not just the area.
     Include what can only be verified live (with the engine and Godot running) and say so. -->

- **Unit:** `cargo test <name>` — <what it proves>
- **Godot:** `godot --headless --path Godot -s <script>` — <what it proves>
- **Live:** <exact steps, e.g. `./test_osc.sh`, or the OSC message to send>

## Risks

| Risk | Mitigation |
|---|---|
| <e.g. dropouts under load> | <e.g. measure with `/engine/load` while a CLAP plugin GUI is open> |

## Open questions

- [ ] <unresolved decision — resolve before the tasks gate>
