# Native PipeWire Output — Requirements

## Problem

The engine reaches PipeWire through PipeWire's ALSA compatibility layer, with a ring of four
buffers that is kept full. Every block waits behind about three others before PipeWire takes it,
so output latency is roughly four times the buffer size: about 85 ms at a 1024-frame buffer under
a 2048-frame quantum, where Bitwig (on its native PipeWire driver) shows 42.7 ms. Small buffers
make it worse, not better: at 512 frames the ring holds exactly one quantum and the engine
underruns about five times a second. The audio callback also runs without realtime scheduling,
so other processes can delay it. Users notice the lag when playing a MIDI keyboard and when
comparing Sonara with other DAWs on the same machine.

## Scope

| | |
|---|---|
| Subsystem | both. Engine: the output stream, the PipeWire graph handling, device listing. Godot: Settings › Audio (a Driver setting, device names, the info and warning lines) |
| Touches real-time audio thread | yes. The callback is reached through a different driver, and it must handle blocks larger than the engine's largest block |
| Adds or changes an OSC message | yes. `/audio/config/set` gains the driver; `/audio/device` gains a display name; `/audio/config` gains the driver, the reported output latency and the realtime state |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. `config.json` gains `audio/driver`. A saved `audio/output_device` from the ALSA driver doesn't name a PipeWire device; it is handled as a missing device (REQ-005) |

## Terms

- **Driver**: the way the engine reaches the sound system: **PipeWire** (a native PipeWire
  node) or **ALSA** (an ALSA device, which may be PipeWire's ALSA bridge or real hardware).
- **Quantum**: the number of frames the PipeWire graph processes per cycle. It is shared by
  every application in the graph.
- **Forced quantum / forced rate**: the `clock.force-quantum` and `clock.force-rate` values in
  PipeWire's `settings` metadata. While set, the graph runs exactly that quantum and rate,
  whatever applications ask for.

## Requirements

### Driver

#### REQ-001 — PipeWire driver plays without an extra ring

WHILE the PipeWire driver is selected, the audio callback shall render each graph cycle's block
directly for that cycle, so the engine adds no buffering beyond the graph's own quantum.

- **Acceptance:** with the buffer at 1024 frames at 48 kHz, the output latency the engine reports
  in Settings (REQ-012) is at most 2 × 1024 frames (42.7 ms) plus the hardware's own latency;
  live, a MIDI note played against Bitwig on the same machine sounds equally prompt.
- **Example:** 2048-frame buffer, 48 kHz → about 43–85 ms, where today it is about 170 ms.

#### REQ-002 — Driver setting

Settings › Audio › Output shall offer a Driver choice of PipeWire and ALSA, defaulting to
PipeWire.

- **Acceptance:** the Driver row lists both; a fresh `config.json` runs the PipeWire driver.

#### REQ-003 — Switching driver applies live

WHEN the user changes the driver, the engine shall stop the output stream, open the system
default device on the new driver and resume, the same way a device change applies today.

- **Acceptance:** switching PipeWire → ALSA → PipeWire during playback keeps the transport
  running; `/audio/config` reports the new driver each time.

#### REQ-004 — PipeWire unavailable

IF the PipeWire driver is selected and PipeWire isn't running, THEN the engine shall open the
ALSA driver instead and say so in the Settings notice, keeping the Driver setting unchanged.

- **Acceptance:** with `PIPEWIRE_RUNTIME_DIR` pointing at an empty directory, the engine starts on
  ALSA and `/audio/config` carries a notice naming PipeWire.

#### REQ-005 — Devices belong to a driver

The device list shall show the selected driver's output devices by a readable name, and a saved
device that the selected driver doesn't have shall be handled like a missing device today (the
system default plays, the setting is kept, the notice says so).

- **Acceptance:** on the PipeWire driver the list shows the sinks by their PipeWire descriptions
  (e.g. "Ryzen HD Audio Controller Analog Stereo"), not ALSA names such as `pipewire` or
  `hw:CARD=Generic`; a `config.json` with `audio/output_device = "pipewire"` starts on the default
  sink with a notice.

#### REQ-006 — ALSA driver keeps a short ring

WHILE the ALSA driver is selected, the engine shall keep at most two buffers queued in the ALSA
ring.

- **Acceptance:** the engine's startup log shows an ALSA buffer of two periods; on the
  `pipewire` ALSA device with a 1024-frame buffer, reported latency is at most about 3 × 1024
  frames plus the hardware's latency.

### Buffer size and the PipeWire graph

#### REQ-007 — The engine forces its buffer size and rate

WHILE the PipeWire driver runs a stream, the engine shall set PipeWire's forced quantum to the
buffer size setting and the forced rate to the sample rate setting.

- **Acceptance:** with the buffer at 512 and the rate at 48 kHz, `pw-metadata -n settings 0`
  shows `clock.force-quantum 512` and `clock.force-rate 48000`, and `pw-top` shows the engine's
  driver running a 512 quantum.

#### REQ-008 — Forced values follow setting changes

WHEN the buffer size or sample rate setting changes while the PipeWire driver runs, the engine
shall update the forced quantum and rate to the new values.

- **Acceptance:** changing the buffer 1024 → 256 in Settings changes `clock.force-quantum` to 256
  within one second, without restarting PipeWire.

#### REQ-009 — Forced values are restored

WHEN the engine stops its PipeWire stream (driver switch, engine shutdown), it shall restore the
forced quantum and rate that were set before it first forced them, unless another application
has changed them since.

- **Acceptance:** with `clock.force-quantum 0` before start, quitting the engine leaves it at 0.
  With Bitwig started after Sonara (writing 2048), quitting Sonara leaves 2048.

#### REQ-010 — Another application forces a different quantum

IF another application changes the forced quantum or rate while the engine runs, THEN the
engine shall keep playing at the graph's quantum and rate without re-forcing its own, and Settings
shall show which values are in force and that another application set them.

- **Acceptance:** with Sonara at 512, `pw-metadata -n settings 0 clock.force-quantum 2048` makes
  the engine run 2048-frame blocks without crackles; the Buffer Size row's warning shows the 2048
  quantum. Changing Sonara's buffer setting afterwards forces the new value again (REQ-008).

#### REQ-011 — Blocks of any size

The audio callback shall render a block of any length the driver delivers, including blocks
longer than the engine's largest preallocated block, without allocating.

- **Acceptance:** a unit test renders a 16384-frame callback with the engine's largest block at
  8192 frames and produces continuous output; `SONARA_FEATURES=rt-debug` reports no allocation
  during a live run with the quantum forced to 8192.

### Reporting

#### REQ-012 — Reported output latency

The engine shall report the output latency the driver measures (from rendering a block to it
reaching the hardware) in `/audio/config`, and Settings shall show it next to the buffer size.

- **Acceptance:** Settings › Audio shows "Output latency: N ms", where N comes from the driver's
  timestamps, not from the buffer size alone, and changes when the driver or buffer changes.

#### REQ-013 — Realtime scheduling

The audio callback's thread shall run with realtime scheduling when the system grants it, and
the engine shall report in the log and in Settings whether it was granted.

- **Acceptance:** on the dev machine (rtkit running, `ulimit -r` 0), the startup log states that
  realtime scheduling was granted and `chrt -p <callback thread id>` shows `SCHED_FIFO` or
  `SCHED_RR`; with rtkit stopped, the log and Settings say it was denied and playback still works.

#### REQ-014 — Xruns are counted on both drivers

The engine shall count the driver's underruns in the existing xrun counter on both drivers.

- **Acceptance:** forcing a 64-frame quantum with a heavy project makes the Engine panel's xrun
  count rise on the PipeWire driver, as it does today on ALSA.

## Non-functional

- **Real-time safety:** the callback keeps the audio thread contract: no allocation, blocking, I/O
  or waiting on a lock. Writing PipeWire's metadata and reading the graph never happen on the
  callback thread.
- **Latency / performance:** REQ-001 and REQ-006 bound the added latency. Per-block CPU cost is
  unchanged.
- **Compatibility:** projects are unaffected. An older Godot sending `/audio/config/set` without
  the driver argument gets the PipeWire driver. Building the engine needs the PipeWire development
  headers (`libpipewire-0.3-dev`), which become a documented prerequisite.

## Out of scope

- A JACK driver (possible later through the same driver setting).
- Audio input and recording.
- Reading MIDI input in the engine instead of through Godot (a separate latency source), and
  getting computer-keyboard notes past Godot's once-per-frame input handling (planned as follow-up
  task T-013).
- Realtime scheduling for plugin host processes, per-device timing and multithreaded channel
  processing (separate specs from the same performance review).
- Restoring PipeWire's forced values after the engine crashes or is killed; they stay until the
  engine starts again or the user clears them.
- Plugin latency compensation (#1).

## Open questions

- [x] REQ-007 forces the rate as well as the quantum, like Bitwig, so other applications resample
  to Sonara's rate while it runs. Decided 2026-10-12: force both.
