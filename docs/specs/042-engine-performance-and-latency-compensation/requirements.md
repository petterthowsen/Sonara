# Engine Performance and Latency Compensation — Requirements

## Problem

After spec 041 the engine reaches PipeWire natively with realtime scheduling, but three gaps
remain from the same performance review (#1):

1. **No visibility below the plugin level.** The Engine panel shows the callback's total load and
   per-plugin times. When a project overloads, the user can't see which channel or built-in
   device is responsible. We also can't tell whether one core is the limit.
2. **Everything but plugins runs on one core, and plugin hosts have no realtime priority.**
   Plugins on different channels already process in parallel in their host processes. Every
   built-in device (PolySynth, Sampler, sfizz, Reverb, …) still runs serially on the callback
   thread, while the other cores sit idle. The plugin hosts' audio threads run at normal
   priority, so any desktop activity can make a plugin miss its deadline.
3. **Plugin latency isn't compensated.** A plugin or device that reports latency (a linear-phase
   EQ, a lookahead limiter, an oversampled plugin) delays its channel relative to every other
   channel. Parallel paths that meet on a bus or master then comb-filter or flam, for example a
   drum bus with a parallel compression send. Users notice this as phasey or smeared mixes.

## Scope

| | |
|---|---|
| Subsystem | both. Engine: the audio callback's mixer passes, the device chain runner, the plugin host's audio thread, the command thread's stats reporting. Godot: the Engine panel, Settings › Audio |
| Touches real-time audio thread | yes. The callback measures device and channel times, hands channels to other realtime threads, and runs alignment delays. The plugin host's audio thread changes its scheduling |
| Adds or changes an OSC message | yes. Device and channel stats (with subscribe and unsubscribe), plugin host realtime state, the processing-thread setting, channel and output latency |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. `config.json` gains the processing-thread setting (missing key = Auto). Projects are unchanged: latency comes from the devices at runtime |

## Terms

- **Block time**: the duration of one audio block (frames ÷ sample rate). Loads are shares of it.
- **Device time**: the time a top-level device in a channel's chain takes per block, measured
  on the thread that runs it. For a container or slotted device, this includes its children.
  For a plugin, it is the time the engine thread spends on it, including waiting for the host.
- **Channel time**: the device times of a channel plus its fader, pan and routing work.
- **Processing thread**: a thread, other than the audio callback's, that runs channels' device
  chains during a block.
- **Device latency**: the frames by which a device delays its output, as the device reports it.
- **Path latency**: the latency a channel's signal has accumulated when it reaches a route or
  send target: its own chain's device latency plus the largest path latency among its inputs.
- **Compensation**: delaying the earlier signals that meet at a channel so that all of them
  arrive aligned.

## Requirements

### A. Timing in the Engine panel

#### REQ-001 — Channel times

While the Engine panel's performance popup is open, it shall list the channels by their
processing time per block (average and peak over the last report interval, as % of the block
time), heaviest first.

- **Acceptance:** a project with one PolySynth channel playing 16 voices and one idle audio
  channel shows the PolySynth channel at the top with a non-zero load. The idle channel shows
  near zero or is absent.
- **Example:** 256 frames at 48 kHz (5.33 ms block). A channel averaging 1.1 ms shows "21%",
  with a peak of e.g. "34%".

#### REQ-002 — Top-level device times

For each listed channel, the Engine panel shall show the time of each device in the channel's
top-level chain. A container or slotted device shows one figure that includes its children. A
plugin shows both the engine's time on it and the host's own process time (reported today).

- **Acceptance:** a Chain holding a Reverb and a Delay shows one row for the Chain, not separate
  rows for its children. A CLAP plugin row shows two figures, and the host figure matches what
  the panel shows today.

#### REQ-003 — Reported only while watched

The engine shall send channel and device timing only while at least one client has the
Engine panel's performance popup open. Within one report interval of the popup closing, it
shall stop sending them.

- **Acceptance:** with the popup closed, `oscdump 7001` shows no channel or device stats
  messages. Opening the popup makes them appear at the report rate, and closing it stops them.

#### REQ-004 — Removed channels and devices disappear

WHEN a channel or device is removed, the Engine panel shall drop its row within one report
interval.

- **Acceptance:** remove a listed device while the popup is open. Its row is gone within a
  second.

#### REQ-005 — Measurement doesn't cost noticeable load

Measuring channel and device times shall add no more than 1% of the block time to the callback's
average load, in a project with 32 channels of 4 devices each at 256 frames.

- **Acceptance:** compare the Engine panel's load with timing compiled in and with it disabled
  (a build-time switch or test harness), same project, same position.

### B. Realtime scheduling for plugin hosts

#### REQ-006 — Plugin host audio threads get realtime scheduling

Each plugin host process's audio thread shall run with realtime scheduling when the system
grants it. The engine shall report in the log and in the Engine panel, per host process, whether
it was granted.

- **Acceptance:** on the dev machine (rtkit running), `chrt -p <plugin-audio tid>` shows
  `SCHED_FIFO` or `SCHED_RR`, and the Engine panel says realtime was granted for every host
  process. With rtkit stopped, the log and panel say it was denied, and plugins still process.

#### REQ-007 — A denied request doesn't break hosting

IF realtime scheduling is denied for a plugin host, THEN the plugin shall load, process and
report its stats exactly as it does today.

- **Acceptance:** `./test_plugin_osc.sh` passes with rtkit stopped.

### C. Parallel channel processing

#### REQ-008 — Independent channels process on several cores

WHERE more than one processing thread is configured, the mixer shall process the device chains
of channels that don't depend on each other at the same time on different cores. That covers
channels nothing routes into, and route targets whose inputs have all finished.

- **Acceptance:** a project with 8 channels, each with a PolySynth playing 16 voices plus a
  Reverb, at 256 frames: the callback's average load with 4 threads is under 50% of its load with
  1 thread on the dev machine (12 cores).

#### REQ-009 — Same output as single-threaded

For any project and block, the master output with N processing threads shall be
sample-identical to the output with one.

- **Acceptance:** an engine test renders the same graph (instruments, effects, buses, sends,
  a routing cycle, a return channel) with 1 and with 4 threads and compares every sample.

#### REQ-010 — Processing threads setting

Settings › Audio shall offer a **Processing threads** setting: Auto (the default) or a number
from 1 to the machine's core count. 1 means everything runs on the callback thread, as today.
WHEN the setting changes, the engine shall apply it without a restart, within one second.

- **Acceptance:** switching between 1 and 4 during playback changes the thread count shown in
  the Engine panel within a second, with no more than one dropout.
- **Example:** Auto on a 12-core machine means 5 processing threads plus the callback thread,
  leaving the other cores for plugin hosts and the desktop. Auto is `min(cores / 2, 8) − 1`.

#### REQ-011 — Processing threads get realtime scheduling

The processing threads shall request realtime scheduling the same way as the callback thread.
The Engine panel shall show how many processing threads are running and whether they got
realtime scheduling.

- **Acceptance:** `chrt -p` on each processing thread shows `SCHED_FIFO` or `SCHED_RR`
  on the dev machine. The Engine panel shows "4 threads · realtime".

#### REQ-012 — A late processing thread can't stall the block

IF a processing thread hasn't started a channel by the time the callback is ready for it, THEN
the callback shall process that channel itself. A block shall never wait for a channel that no
thread has started.

- **Acceptance:** an engine test pauses every processing thread and checks that the block
  still completes, with the correct output, on the callback thread alone.

### D. Latency compensation

#### REQ-013 — Parallel paths are aligned where they meet

WHEN signals with different path latencies meet at a channel (a bus, master, or a hardware
output pair), the mixer shall delay the earlier ones so that all of them arrive aligned to the
sample. This applies to routes and to pre- and post-fader sends.

- **Acceptance:** two audio tracks play the same clip into master, one with polarity inverted
  and one with a test device that reports 100 frames of latency and delays by 100 frames.
  Master outputs silence (below −120 dBFS). Without compensation it doesn't.
- **Example:** track A (0 frames) and track B (a 512-frame linear-phase EQ) both route to Drums
  bus. A is delayed by 512 frames before it mixes into Drums, and Drums' path latency is 512.

#### REQ-014 — Container latency

A container shall report as its latency the largest latency among its parallel branches plus
the latency of its serial devices, and shall align its own parallel branches (Layer slots,
Drum Machine pads, Multiband bands) internally.

- **Acceptance:** a Layer with one slot holding a 100-frame latency device and one empty slot,
  playing the same signal with one slot inverted, outputs silence. The Layer reports 100 frames.

#### REQ-015 — Latency changes are applied

WHEN a device's latency changes (a plugin reports a new latency, or a device with latency is
added, removed, moved, bypassed or enabled), the mixer shall use the new compensation within
one second. At most one block around the change may be discontinuous, and the output shall
contain no stale or uninitialised samples.

- **Acceptance:** toggling a 100-frame latency device on a parallel path during playback keeps
  the null test of REQ-013 silent before and after, with at most one block of residue at the
  switch.

#### REQ-016 — Latency is visible

The Engine panel shall show each channel's path latency where it isn't zero, and the total
latency added before the hardware output (the largest path latency into any hardware pair).

- **Acceptance:** with the 512-frame EQ of the REQ-013 example, the panel shows
  "Drums 512 smp (10.7 ms)" and "Plugin latency: 10.7 ms" at 48 kHz.

#### REQ-017 — Compensation has a limit

IF a channel's path latency exceeds the maximum the mixer can compensate, THEN the mixer shall
compensate up to the maximum, and the engine shall log a warning naming the channel and show
it in the Engine panel.

- **Acceptance:** an engine test with a device that reports more than the maximum logs the
  warning and keeps processing. The other channels stay aligned up to the maximum.

#### REQ-018 — Renders stay on the timeline

An offline render (master or stems) shall start each file at the start of the rendered range,
with the compensation latency removed, and shall not cut the end of the range or the tail short.

- **Acceptance:** rendering a range that starts on a kick, with a 512-frame latency plugin on the
  drum channel, puts the kick's onset at frame 0 ± 1 of both the master file and the drum stem.
  The file lengths equal those of the same render with the plugin removed.
- Added during design (2026-10-12): without it, every export would start late by the path
  latency.

## Non-functional

- **Real-time safety:** the callback and the processing threads keep the audio thread contract:
  no allocation, blocking I/O, or waiting on the state lock. Waiting for a processing thread to
  finish a channel it has started is bounded the same way as waiting for a plugin. Alignment
  delay memory is allocated by the command thread, never on the callback.
- **Latency / performance:** REQ-005 bounds the cost of timing. REQ-008 sets the parallel
  speed-up. Compensation adds exactly the path latency and nothing else. A project with no
  latency-reporting devices has 0 frames of added latency.
- **Compatibility:** projects load unchanged. A `config.json` without the processing-thread key
  means Auto. An older Godot that never subscribes to stats gets none. One that never sends the
  thread setting gets Auto.

## Out of scope

- Timing of devices nested inside containers and device slots. Only top-level devices get
  figures; a container's figure includes its children.
- Spreading one channel's chain over several threads. The unit of parallel work is a channel.
- CPU affinity and pinning cores, and locking memory (`mlockall`).
- Several audio threads inside one plugin host process. A grouped hosting mode still runs its
  plugins one after another.
- A "reduced latency while monitoring" mode that exempts armed channels from compensation.
- Compensating the sidechain modulator taps (spec 036), which already follow their source one
  block late by design.
- Shifting playback, automation or the playhead earlier to hide the added latency from the
  timeline. All audio is delayed by the same amount, so channels stay aligned with each other.
- Removing the shared engine-state lock (#1, "phase 2").

## Open questions

Resolved 2026-10-12 (proposals accepted):

- [x] **Auto thread count:** `min(cores / 2, 8) − 1` processing threads (5 on the 12-core dev
  machine), at least 0, leaving cores for plugin host processes.
- [x] **Bypassed devices and latency:** a bypassed (disabled) device still reports its latency
  and delays its signal by it, so bypassing doesn't shift timing.
- [x] **Maximum compensation (REQ-017):** 1 second at the running rate, delay memory allocated
  only for the channels that need compensation.
- [x] **Live input on armed channels:** compensated like everything else; a monitoring exemption
  is a later spec (see Out of scope).
- [x] **Report interval** for channel and device stats: 500 ms, like `/status/engine_stats`.
