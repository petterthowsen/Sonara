# 0021 — Latency is compensated by delaying signals where they meet

Status: accepted (spec 042, `docs/specs/042-engine-performance-and-latency-compensation/`).

## Context

A device that reports latency (a linear-phase EQ, a lookahead limiter, an oversampled plugin)
delays its channel against every other channel. Parallel paths that meet on a bus or master, such
as a drum bus with a parallel compression send, comb-filter or flam. `AudioDevice::latency_frames()`
already existed (default 0) and CLAP and VST3 plugins already reported it.

## Decision

- **Delay at the edges, not at the sources.** Each channel has an `in_latency` (the largest
  `out_latency` among the channels routing or sending into it) and an `out_latency` (`in_latency`
  plus its top-level devices' `latency_frames()`). Every edge (route, each send, the hardware
  write) delays its source by `target.in_latency − source.out_latency`, by reading the source's
  block from a per-channel stereo ring (`StereoBlockDelay`) written once per block. A channel whose
  edges all have delay 0 owns no ring and takes the plain `add_scaled` path, so a project without
  latency is sample-identical to before.
- **The command thread plans.** `refresh_latency` runs every device poll (20 ms): it calls
  `AudioDevice::update_latency` on every top-level device, builds a cheap `LatencySignature`
  under the lock and, only when the signature or the rate changed, computes a `LatencyPlan`
  (a cycle-safe topological walk; cycle edges get delay 0), allocates rings outside the lock,
  swaps them in under it and drops the old state after unlock. Rings that still reach the needed
  delay are kept, so unaffected channels keep their history. This covers graph edits and latency
  changes without hooking each command. The signature needs no new command.
- **Maximum 1 second** at the running rate. Above it the mixer compensates to the maximum, warns
  once per channel and reports it.
- **Containers align their own parallel branches** with `AlignDelay` (Layer and Drum Machine
  slots, Multiband bands, the Reverb dry path, a Chain's dry path) and report the result as their
  `latency_frames()`: the largest branch plus the serial devices. Reverb and PolySynth count a
  slot only while it is live.
- **A bypassed device keeps its latency.** The CLAP adapter delays its dry or bypass path by
  `latency_frames()` (`bypass_delay`), and every container's bypassed path does the same, so
  bypassing never shifts timing.
- **Plugins that change latency at runtime** get a restart path: CLAP `request_restart` and
  `latency.changed` re-activate the plugin in the host, which sends `PluginEvent::LatencyChanged`
  (VST3 already re-activated). The engine applies it with `set_latency_frames` and the next poll
  replans.
- **Everything is late by the total latency.** Playback, automation and the playhead are not
  shifted. Offline renders skip each tap's `out_frames` (master: the output latency), so exported
  files start on the timeline and keep their length (REQ-018).

## Rejected

Shifting clip and MIDI scheduling earlier per channel ("negative delay"). It needs look-ahead in
every MIDI and clip source and in automation, and still doesn't help routes, sends and buses.
Delaying at the summing points is local to the mixer.

## Consequences

Parallel paths null to the sample, at the cost of one fixed output delay equal to the largest path
latency, which also delays live monitoring (a monitoring exemption is a later spec). Two known
gaps: `update_latency` and the adapter's `set_latency_frames` can allocate under the state lock
when a latency changes (listed in the command classification), and the sidechain modulator taps
(spec 036) are not compensated.
