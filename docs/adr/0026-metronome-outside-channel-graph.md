# 0026 — The metronome lives outside the channel graph

Status: accepted (spec 053, `docs/specs/053-metronome/`). Follows the browser preview of spec 037.

## Context

Sonara needs a metronome that follows tempo ramps, time signature changes and loops, sounds from the
drum instruments the engine already has, and never ends up in an export. The click has to play on the
main output whatever the master fader does, and it has to land on the exact frame of each beat.

## Decision

- **An engine-owned `Metronome`, mixed in after the master like the browser preview.**
  `EngineState::metronome` owns two preallocated drum hosts (Kick for Beep, Snare for Wood), a
  fixed-capacity pattern table (32 signatures, 128 steps each) and a 16-entry trigger queue.
  `run_live_block` calls `Metronome::render` after `mix_and_output` and the preview. It adds the
  click into master's hardware pair, with master's output delay, so it lines up with the audio.
- **Scheduling reads the block's tick events.** The step grid is deterministic from the time
  signature map, so the scheduler keeps a cursor per monotonic run of tick events (the block start
  and each loop wrap) and fires when a tick equals the cursor's. Each bar looks its own signature up.
  Clicks use the sample-accurate frame of the tick, one frame earlier than the beat's exact frame,
  like clip MIDI.
- **The click never enters a channel.** It skips master's devices and fader, and the offline render
  reads channel buffers directly, so exports never contain it without any special case.
- **Sound and on/off are user settings; patterns are project data.** Godot sends real values
  (Hz, seconds, dB, semitones) and the engine maps them onto the drum voices' parameters, a base note
  and per-level velocity.
- **Resolutions are 1/4, 1/8 and 1/16 over OSC.** The default pattern for a 1/32 signature uses 1/32
  steps inside the engine, which `/metronome/pattern` cannot carry, so those signatures can only play
  the default.

## Rejected

A hidden metronome channel holding a drum device, fed with generated MIDI. It would reuse the device
and MIDI paths, but the channel would be in the graph: routing, solo, meters and the latency plan
would all have to know it, export would have to skip it, and it would sit before master's fader and
effects. Scheduling clicks in Godot (live MIDI at beat times) was also rejected: it is jittery by a
UI frame and cannot be sample-accurate.
