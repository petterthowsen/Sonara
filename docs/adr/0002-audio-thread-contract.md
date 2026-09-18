# 0002 — The audio callback never blocks, allocates, or does I/O

Status: accepted

## Context

The audio callback is real-time: any block, allocation, or I/O causes an audible dropout
and there is no way to recover a missed deadline.

## Decision

The callback follows a strict contract:

- Locks: bounded `try_lock` (`lock_state_for_callback`, budget ~1 ms) — if the command
  thread holds the state, the callback outputs silence for that buffer and retries the next one.
- No heap allocation, no I/O, no blocking channel `recv()`; commands are drained with `try_recv()`.
- All buffers are preallocated at init (`render_scratch.rs`: `RenderScratch`, per-channel
  `MixBuffers`); `std::mem::take` is used to get two mutable borrows of a preallocated buffer.
- Anything the command thread does while holding the state lock must also be fast; slow
  work (plugin scans, device create/teardown, plugin IPC) runs on the command thread with
  the lock released.

## Consequences

- A stalled command thread degrades to silence, never to a system-wide underrun loop.
- Every new buffer type must be pre-sized at init; "just allocate one small Vec here" is a
  bug even when it happens to work.
- Log with `info!`/`warn!`/`error!` macros, never `println!`.

References: `docs/subsystems/engine-audio-thread.md`, `docs/subsystems/engine-architecture.md`
