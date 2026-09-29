# Tempo Map Playback and Device Transport — Requirements

## Problem

The arranger's tempo lane (`TempoTrack`) edits a project tempo map that is saved with the project,
but nothing plays it. The audio callback advances the transport at the single static project
tempo, so tempo points have no audible effect. Godot's playhead interpolation and time ruler also
assume one static tempo, so once the engine follows the map the UI would drift from it.

Devices and CLAP plugins receive no transport information at all, not even the static tempo or
whether the transport is playing, so tempo-synced plugins (delays, LFOs, arpeggiators) fall back
to their own internal tempo.

## Scope

| | |
|---|---|
| Subsystem | both |
| Touches real-time audio thread | yes — the transport clock and audio clip playback read the tempo map per frame |
| Adds or changes an OSC message | yes — a new message carries the tempo map to the engine |
| Changes the plugin subprocess protocol | yes — each processed block carries transport info to the plugin host |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no — `tempo_map` is already saved in `.sonara`; the engine persists nothing |

## Definitions

- **Tempo map** — tempo points `(tick, bpm)`, linearly interpolated in ticks between points, held
  at the first point's BPM before it and the last point's BPM after it. Empty means the static
  project tempo applies. (Matches `TempoMap.get_bpm_at_tick` in Godot.)
- **Effective tempo** at a tick — the tempo map's value there, or the static project tempo when
  the map is empty.

## Requirements

### REQ-001 — Engine receives the tempo map

WHEN the project connects to the engine, or the tempo map changes in Godot (add, move, delete,
clear, undo, redo, project load), the engine shall hold a copy of the tempo map equal to Godot's.

- **Acceptance:** engine log line on receipt reports the point count; a unit test on the handler
  parses a message with N points into N engine tempo points in tick order.
- **Example:** points `(0, 120), (7680, 60)` in Godot → engine map with the same two points.

### REQ-002 — Transport advances at the effective tempo

WHILE the transport is playing, the audio callback shall advance the playhead at the effective
tempo of the current tick, re-evaluated at least once per audio frame.

- **Acceptance:** unit test — with map `(0, 120), (3840, 60)` at 48 kHz, crossing ticks 0 → 3840
  takes 4·ln 2 s ≈ 133 084 frames (±1 frame per beat), and ticks 3840 → 4800 take 48 000
  frames (±1).
- **Example:** constant map `(0, 60)` at 48 kHz, 960 PPQ → 1 beat (960 ticks) takes 48 000 frames,
  regardless of the static project tempo (e.g. 120).

### REQ-003 — Empty map keeps today's behaviour

IF the tempo map is empty, THEN the audio callback shall advance at the static project tempo,
exactly as before this feature.

- **Acceptance:** the existing `processing.rs` tests pass unchanged; unit test — empty map at
  120 BPM / 48 kHz advances 10.24 ticks per 256 frames.

### REQ-004 — Tempo ramps are continuous

WHILE the playhead is between two tempo points with different BPM, the audio callback shall use
the linearly interpolated BPM, so a ramp from 60 to 120 BPM over 4 beats has no audible step at
buffer boundaries.

- **Acceptance:** unit test — the per-frame tick advance across a ramp is monotonic and changes by
  no more than the ramp slope allows between consecutive frames, including across buffer boundaries.

### REQ-005 — MIDI stays sample-accurate

The audio callback shall keep dispatching clip MIDI at the exact frame where each tick is crossed
under a varying tempo, and shall not dispatch any tick twice or skip any tick.

- **Acceptance:** unit test — over a ramp spanning several buffers, the collected ticks are
  contiguous and strictly increasing, with non-decreasing frame offsets within each buffer.

### REQ-006 — Audio clips follow the tempo

WHILE an audio clip instance plays, its playback rate shall equal effective tempo ÷ the clip's
recorded BPM, re-evaluated at least once per audio frame.

- **Acceptance:** unit test on the rate computation; live — an audio clip recorded at 120 BPM over
  a 120 → 60 BPM ramp slows (and drops in pitch) smoothly and stays aligned with the grid.

### REQ-007 — Seeking into an audio clip lands on the right sample

WHEN playback starts or seeks to a tick inside an audio clip instance, the clip shall start at the
source position for that tick on the clip's own recorded-BPM timeline, independent of the project
tempo.

- **Example:** clip recorded at 120 BPM, 48 kHz source, seek 1 beat into the instance → source
  frame 24 000, whether the effective tempo is 60, 120 or 200 BPM.
- **Acceptance:** unit test on the offset computation with those three tempos.

### REQ-008 — Looped audio clips loop on the clip timeline

WHILE a looped audio clip instance plays, its loop boundaries shall be the loop start and length
converted on the clip's recorded-BPM timeline, independent of the effective tempo.

- **Acceptance:** unit test — loop of 1 beat on a 120 BPM / 48 kHz clip wraps at 24 000 source
  frames under both 60 and 200 BPM effective tempo.

### REQ-009 — Godot playhead follows the map

WHILE the transport plays, the Godot editor's interpolated playhead shall advance at the effective
tempo at the playhead, so it does not visibly jump when the engine's playhead report arrives.

- **Acceptance:** Godot test — with map `(0, 60)` and static tempo 120, one second of interpolation
  advances 960 ticks, not 1920.

### REQ-010 — Time ruler shows real time

The arranger's time ruler shall label positions with elapsed seconds computed through the tempo
map, integrated from tick 0.

- **Example:** map `(0, 120), (3840, 60)`: the ramp is 4 beats, so tick 3840 → 4·ln 2 ≈ 2.773 s,
  and 60 BPM holds after it, so tick 4800 → ≈ 3.773 s.
- **Acceptance:** Godot test on the tick → seconds conversion with those values; live — ruler
  labels match.

### REQ-011 — Transport tempo display under a tempo map

WHILE the tempo map has points, the transport tempo field shall show the effective tempo at the
playhead and shall not be editable. WHILE the map is empty, it shall behave as today.

- **Acceptance:** live — add a point, the field shows its BPM and is read-only; play across a ramp
  and the value changes; clear the map and the field is editable again with the static tempo.

### REQ-012 — Devices receive transport info every block

Before each device in a channel chain processes a block, the mixer shall give it the transport
state at the block's first frame: effective tempo, tempo change per sample, playing flag, song
position in beats and in seconds, the start tick and number of the current bar, and the time
signature. This holds whether the transport is playing or stopped, and whether or not the tempo
map has points.

- **Acceptance:** unit test — a test device records the transport it was given; after one block
  at tick 1920, 120 BPM, 4/4, playing, it saw position 2.0 beats, 1.0 s, bar start 0 beats,
  bar number 0, playing = true.
- **Example:** stopped at tick 0 with an empty map at 140 BPM → tempo 140, tempo change 0,
  playing = false, position 0.

### REQ-013 — Transport song position is consistent with the tempo map

The transport's seconds position shall be the elapsed time from tick 0 through the tempo map (the
same values the time ruler shows, REQ-010), and its beat position shall be the tick ÷ PPQ.

- **Acceptance:** unit test — with map `(0, 120), (3840, 60)`, the transport at tick 4800 reports
  5.0 beats and ≈ 3.773 s.

### REQ-014 — Tempo ramps are reported to devices

WHILE a block lies within a tempo ramp, the transport's tempo change per sample shall equal the
ramp's BPM slope at the block start converted to per-sample units, and it shall be 0 on a
constant-tempo stretch or when stopped.

- **Acceptance:** unit test — map `(0, 60), (3840, 120)`, block starting at tick 0 at 48 kHz →
  tempo 60 and tempo change = (60 BPM / 3840 ticks) × ticks per sample at 60 BPM
  = 60 / 3840 × 0.02 ≈ 3.125 × 10⁻⁴ BPM per sample.

### REQ-015 — CLAP plugins receive the transport

WHEN a CLAP plugin processes a block, the plugin host shall pass it a CLAP transport event built
from the block's transport state (REQ-012), with the tempo, tempo-increment, beats-timeline,
seconds-timeline, time-signature and playing flags set, and the loop, recording and pre-roll
flags cleared.

- **Acceptance:** unit test — the plugin host's conversion from the block's transport to a CLAP
  transport event yields the expected flags and fixed-point beat/second values; live — a
  tempo-synced CLAP delay or arpeggiator follows the project tempo, and follows a tempo ramp.

### REQ-016 — Built-in devices are unaffected

Built-in devices shall accept the transport and may ignore it; no built-in device changes its
sound in this feature.

- **Acceptance:** existing device unit tests pass unchanged.

## Non-functional

- **Real-time safety:** the audio callback shall not allocate, block or lock to read the tempo map;
  replacing the map shall not free memory on the audio thread. Building and handing over the
  transport each block shall not allocate, either in the engine or in the plugin host.
- **Latency / performance:** per-frame tempo evaluation shall be O(1) amortised (no search from the
  start of the map per frame).
- **Compatibility:** projects without `tempo_map` load with an empty map and sound identical. An
  older engine ignoring the new message plays at the static tempo (warning in the log, no crash).

## Out of scope

- Loop, recording and pre-roll transport fields. The engine doesn't track the loop region (Godot
  loops by seeking), so plugins see a loop wrap as a jump in position.
- Built-ins that use the transport: tempo-synced parameters on the delay, and passing tempo and
  position to sfizz. The data will be there; adopting it comes later.
- Time-stretching that preserves pitch; clips keep varispeed behaviour.
- Curves other than linear, time signature changes, and DAWproject import/export of the map.
- Editing the tempo map from the engine side or the AI tools.

## Open questions

- (none — audio-clip behaviour, Godot scope and spinbox behaviour were decided up front)
