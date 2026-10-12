# 0020 — Channel device chains run on a realtime worker pool the callback joins

Status: accepted (spec 042, `docs/specs/042-engine-performance-and-latency-compensation/`).

## Context

Plugin hosts already process in parallel (Phase 8a, ADR 0001), but every built-in device
(PolySynth, Sampler, sfizz, Reverb, …) ran serially on the callback thread while the other cores
sat idle. A project of eight PolySynth channels with Reverbs could overload one core. ADR 0002
forbids allocation, blocking and the state lock on the callback, so a general-purpose scheduler
(rayon-style work stealing) is out: it allocates and spawns non-realtime threads.

## Decision

- **The unit of work is a channel's device chain.** `ChannelPool` (`mixing/pool.rs`) exists only
  inside the two mixer passes that already treat channels as independent: the device pre-pass
  (channels nothing routes into) and one sweep of `route_in_dependency_order` (the `ready` list).
  One channel's chain is never split across threads.
- **The callback thread is a participant.** It publishes the job list and a generation, rings a
  futex, claims jobs through the same atomic counter as the workers, and then waits only for jobs
  a worker has *started*. A job no worker reached is run by the callback, so a late, paused or
  descheduled worker can never stall a block.
- **Raw pointers, one invariant.** `PoolShared` holds channel addresses in a preallocated array.
  A thread dereferences one only between claiming its index for the current generation and
  adding it to `done_count`; the callback holds the state lock for the whole span and doesn't
  touch the channel map meanwhile. The invariant is documented on `PoolShared`. This is the one
  `unsafe` handoff in the engine, in one module.
- **Order-dependent work stays serial on the callback thread**, in `ready` order: device events,
  fader and pan, routing and summing, aux sources, hardware output, ring writes. `channel_ids` is
  sorted every block (`sort_unstable`). So the output with N threads is sample-identical to the
  output with one.
- **Workers obey the audio-thread contract** (ADR 0002): no allocation, no blocking I/O, no state
  lock; they wait on futexes and atomics, spinning about 20 µs first. A chain that parks at a
  plugin goes into the claiming thread's own preallocated park queue, so plugins on different
  channels still overlap and a thread waiting on a plugin doesn't hold up built-in channels.
- **Realtime scheduling.** Each worker promotes itself once at start through
  `audio/realtime.rs`, the helper the plugin host's audio thread also uses (rtkit blocks, so never
  on a thread that is already realtime). A denial is reported, not an error.
- **Lifetime.** The command thread builds the pool outside the lock, swaps it into
  `EngineState::pool` under it, and drops (joins) the old one after unlock. Settings › Audio ›
  Processing threads (`/engine/threads/set`) changes it live. Auto is `min(cores / 2, 8) − 1`
  workers, leaving cores for plugin hosts and the desktop; 1 means no workers and the unchanged
  single-threaded code path.

## Consequences

Independent built-in channels scale with cores, and the setting goes back to 1 if a device is
found to share mutable state across channels (a `static`, an `Arc<Mutex<_>>` cache). New devices
must keep their state per instance or atomic; `pool_output_matches_single_thread` runs the full
device set at 0 and 4 workers and compares every sample. Workers on idle cores can compete with
plugin hosts, which is why Auto leaves half the cores free. The pool does not reduce the load of
one heavy channel (out of scope), and the lock-free state work (#1 phase 2) is still separate.
Extends ADR 0002; supersedes nothing.
