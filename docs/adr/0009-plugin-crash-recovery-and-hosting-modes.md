# 0009 — Plugin crashes are recoverable per host process; hosting modes group plugins

Status: accepted

## Context

Out-of-process hosting (ADR-0001) stops a plugin crash from taking the engine down, but the
plugin was still gone for the rest of the session. One process per instance is also expensive
when a project holds many instances: every process costs memory, and every block costs a
context switch per instance.

## Decision

- **Crashes are detected, reported and recoverable.** A watcher thread per host process
  (`pidfd`) records how it exited, and a pipe keeps the last lines of its stderr. A host that
  hangs (no response within the timeout) is killed and treated as crashed. The device goes to
  `Crashed`: the audio thread passes audio through without touching IPC, and Godot gets
  `{device}/crashed` plus `loading_state "crashed:<reason>"`. `{device}/reload` respawns the host
  and restores the plugin from its last saved state, which the adapter refreshes periodically.
- **A crash belongs to the host process, not the device.** Every instance in a dead host crashes
  together, and reloading one reloads all of them.
- **Hosting modes are user-selectable**, as in Bitwig: `individually` (default), `by_plugin`,
  `by_vendor` or `together`, with per-plugin overrides (`/plugins/hosting`). `ProcessManager`
  computes a host key from the mode and reuses a live host with that key. Changing the mode
  applies live through the reload path: save state, respawn under the new key, restore.
- The protocol addresses plugin **instances**, so grouping never needs a protocol change. An
  in-engine mode was designed and skipped: it would give up the isolation this whole design
  exists for.

## Consequences

- A crashing plugin costs the user a click, not a restart, and loses at most the changes since
  the last state save.
- Grouping trades isolation for performance: in `together`, one bad plugin takes every plugin
  down with it (the engine keeps running). The default stays `individually` until measurements
  justify another.
- Crash UI, reload and GUI handling must work per host, not per device: several
  `{device}/crashed` messages share one `pid`.
- The adapter keeps a recent state blob for every plugin, which costs a periodic `SaveState`
  round trip off the audio thread.

References: `docs/engine-stability-plan.md` (phases 4–5), `docs/subsystems/engine-plugin-architecture.md`,
`docs/subsystems/osc-protocol.md`
