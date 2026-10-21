# 0023 — Cross-channel MIDI is delivered in a serial pre-pass before the pooled render

Status: accepted (spec 049, `docs/specs/049-midi-send/`). Extends ADR 0020.

## Context

MIDI Send forwards the note events reaching a channel's chain to other channels. The channel
worker pool (ADR 0020) renders independent channel chains in parallel, so a send that emitted while
its own channel rendered on a worker could reach a target that is already rendering or done. That
adds a block of latency and makes the output depend on scheduling, which ADR 0020 forbids (output
with N workers must be sample-identical to one).

## Decision

- **Forward before rendering.** At the top of `mix_and_output`, `midi_send::forward` walks the
  senders in dependency order (every sender after anything that sends to it). For each it runs
  `dispatch_notes` early (live MIDI plus the note phase), marks the channel `notes_dispatched` so
  the render skips it, and delivers the MIDI Send's outbox to each target at the same frame. The
  pre-pass is serial, note-only work, so the pool is untouched.
- **The graph is built by the command thread.** `rebuild_midi_sends` (mirroring `rebuild_taps`)
  validates targets, adds edges in a fixed order (sender id, device index, target id), refuses any
  edge that would close a loop, writes effective targets into each device and returns the sender
  order and the `blocked` sets. The callback iterates the result read-only; the old order is
  dropped after unlock. Children mode is resolved in Godot (the engine has no mixer nesting), so
  the engine only ever sees a concrete target list.
- **MIDI Send lives in the top-level chain only.** Containers and slots run their note phases
  inside their own `process_block` during the render, where a send would emit too late. The engine
  refuses it at a nested path and the UI refuses the drop.
- **Fixed capacities.** Target lists, the sounding tables and the event buffers are preallocated.
  A full table drops new note-ons (logged at most once a second) and never drops note-offs.

## Consequences

Forwarding adds no latency and keeps the pool deterministic. The cost is serial work on the
callback proportional to the number of senders (zero for projects without one). A sender
deactivated while notes are sounding on its targets does not release them (the send is skipped);
the notes end with the transport or a normal REQ-010 trigger. Later note devices that forward
events between channels (Voice Pick, Key Range, Divisi) can reuse the pre-pass.
