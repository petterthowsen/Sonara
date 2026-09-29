# Tempo Map Playback and Device Transport — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/data/TempoMap.gd` — points `{id, tick, bpm}` sorted by tick, `changed` signal,
  `get_bpm_at_tick(tick, fallback_bpm)` (linear in ticks, held outside the points), `to_json()`.
  Its doc comment says the engine doesn't play it yet.
- `Godot/data/Project.gd` — `var tempo_map: TempoMap`, replaced wholesale in `from_json()`.
  `_on_engine_confirmed_connected()` pushes clips, channels and tracks after `/project/init`.
- `Godot/editor/Editor.gd` — `_process()` free-runs `_playhead_precise` at
  `project.tempo * ppq / 60`; `ticks_to_seconds()` feeds the transport time label;
  `_update_transport_ui()` sets `tempo_spinbox`; `open_project()` binds a project.
- `Godot/components/GridHelper.gd` — `ticks_to_seconds()` / `seconds_to_ticks()` at the static
  `tempo`; used by `components/RealTimeRuler.gd` (the time ruler). `changed` signal redraws rulers.
- `Godot/arranger/Arranger.gd` — `_on_project_activated()` copies `project.tempo` into the shared
  `grid_helper` and binds `tempo_track`; `_unbind_from_project()` undoes it.
- `Engine/src/audio/types.rs` — `ProjectSettings { tempo, time_numerator, time_denominator, ppq,
  sample_rate }` with constant-tempo `ticks_to_samples()`; `AudioPlayback::calculate_stretch_factor`.
- `Engine/src/audio/processing.rs` — `process_audio()` computes one `ticks_per_sample` per
  buffer from `state.settings.tempo`. `collect_tick_events()` (MIDI) and the "audio clip render"
  loop each advance their own tick cursor from that scalar. Audio clips seek with
  `settings.ticks_to_samples()` at the project tempo, advance by `stretch_factor`, and compute
  loop bounds in seconds at the project tempo.
- `Engine/src/audio/commands.rs` — `AudioCommand::SetTempo`, `EngineState` (shared with the
  callback), `process_command()` (fast commands, state lock held).
- `Engine/src/audio/command_worker.rs` — `apply_locked()`, `clear_project()`, and the
  "take under the lock, `drop()` after" pattern (`clear_devices()`).
- `Engine/src/osc/server.rs` — `["transport", "tempo"]` handler.
- `Engine/src/audio/render_scratch.rs` — `RenderScratch`, `MAX_TICK_EVENTS` (8192 frames + 1).
- `Engine/src/audio/devices/mod.rs` — `AudioDevice` trait; `container.rs` — `DeviceContainer`
  (`child_count`, `child_mut`), reached via `AudioDevice::as_container_mut()`.
- `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs` — `SubprocessClapAdapter::
  begin_block()` fills the shared input planes and events, then stores `request_seq` (Release).
- `Engine/src/audio/ipc/protocol.rs` — `SharedMemoryLayout` (planes, events, `BlockControl`),
  `BlockEvent` (`#[repr(C)]`, plain memory ordered by the sequence numbers).
  `ipc/shared_memory.rs` — `SharedMemory` accessors `control()`, `input_events()`.
- `Engine/src/plugin_host/audio_thread.rs` — calls clack `started.process(..., Some(slot.steady),
  None)`; the last argument is `transport: Option<&TransportEvent>`.
- clack (`clack_host::events::event_types::TransportEvent`, pinned checkout `5deaa1b`): pub fields
  `header, flags: TransportFlags, song_pos_beats: BeatTime, song_pos_seconds: SecondsTime, tempo,
  tempo_inc, loop_*, bar_start: BeatTime, bar_number, time_signature_numerator/denominator`;
  `BeatTime::from_float`, `SecondsTime::from_float`; `EventHeader::new_core(0, EventFlags::empty())`.

## Approach

**One tempo curve, the same maths on both sides.** The engine gets a copy of the map as a flat
`(tick, bpm)` list over OSC, replacing the whole map on every change. Per-point messages (like
automation lanes use) were rejected: `TempoMap` only emits a bare `changed`, undo restores whole
snapshots, and a map is tens of points, so a full replace is simpler and can't drift. A new
engine `TempoMap` (`audio/tempo_map.rs`) evaluates BPM at a fractional tick and the elapsed
seconds to a tick. Seconds come from the closed-form integral of a linear-in-ticks ramp:
`60·L/(b1−b0)·ln(b1/b0)/ppq` (or `60·L/(b·ppq)` when flat). Cumulative seconds at each point are
precomputed when the map is built, so a lookup is one segment. Godot's `TempoMap.gd` gets the same
integral, plus its inverse for the time ruler.

**Per-frame rates, computed once per buffer.** `process_audio` fills a preallocated per-frame
`ticks_per_sample` slice by walking the map with a forward cursor from the block's start
position. It does one binary search per buffer, then O(1) per frame. `collect_tick_events` and
the audio-clip loop both read that one slice instead of a scalar. They already advanced
separate cursors with identical arithmetic, and sharing the slice keeps them in step. An empty
map fills the slice with today's constant. Rejected alternative: one tempo per buffer. It is
simpler, but ramps would step at every buffer boundary, which breaks REQ-004.

**Audio clips on their own timeline.** A clip's source position for an offset of `t` ticks is
`t/ppq · 60/recorded_bpm · clip_sr`, which doesn't depend on the project tempo. Seek (REQ-007) and
loop bounds (REQ-008) use this helper, and the per-frame advance is
`frame_bpm/recorded_bpm · clip_sr/device_sr`. This also fixes today's seek offset, which used the
project tempo and was wrong whenever the project tempo differed from the clip's recorded BPM.
(Clip PCM is resampled to the device rate on load, so `clip_sr/device_sr` is 1 in practice. The
current code has that ratio inverted, which never showed.)

**Transport snapshot, pushed down the chain.** `process_audio` builds one `Transport` value per
callback at the block's first frame, before the not-playing early return, and hands it to every
device on every channel through a new default-no-op `AudioDevice::set_transport`. A helper walks
containers through `as_container_mut()`, so `chain`, `layer` and `drum_machine` need no
overrides. Rejected alternative: a shared `Arc` cell like `BlockClock`. It needs no trait change,
but the choice made at requirements time was "via the trait", and pushing per block keeps
devices free of synchronisation. `SubprocessClapAdapter` stores the value, and `begin_block`
copies it into a new `BlockTransport` region of the instance's shared memory, next to the events
and ordered by the same `request_seq` Release/Acquire pair. The plugin host turns it into a
clack `TransportEvent` kept in its per-instance slot, and passes `Some(&event)` to `process()`.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `EngineState.tempo_map: TempoMap` | command thread (builds, swaps) | audio callback reads it under the existing bounded `try_lock` | yes: built off-lock, swapped with `mem::replace` under the lock, old map dropped by the command thread after unlock |
| `RenderScratch.frame_tick_rates: Vec<f64>` | audio callback | preallocated to 8192 frames (the `MAX_TICK_EVENTS` bound) | yes: `clear()` + `push` within capacity |
| `Transport` (per-callback `Copy` value) | audio callback | passed by reference to `set_transport` on each device | yes: stack value, no allocation |
| `SubprocessClapAdapter.transport: Transport` | audio callback | written by `set_transport`, copied into shared memory by `begin_block` | yes |
| `BlockTransport` in shared memory | engine audio callback writes; plugin host audio thread reads | ordered by `request_seq` Release (engine) / Acquire (host), like `BlockEvent`s | yes: plain `#[repr(C)]` copy |
| `InstanceSlot.transport_event: TransportEvent` (plugin host) | plugin host audio thread | rebuilt in place each block | yes: preallocated in the slot |
| Godot `TempoMap` → OSC | Godot main thread | `Project` listens to `tempo_map.changed` | n/a |

## Data and protocol changes

**OSC (Godot → engine):** `/transport/tempo_map` with args `i:tick, f:bpm, i:tick, f:bpm, …`,
sorted by tick. No args means empty (use the static tempo).

- The handler in `osc/server.rs` (`["transport", "tempo_map"]`) parses pairs, skips a malformed
  trailing value with a warning, and sends `AudioCommand::SetTempoMap(Vec<(Tick, f32)>)`.
- The engine sorts the points by tick and clamps BPM to 20–999, the same bounds as
  `TempoMap.clamp_bpm`.
- Size: 8 bytes of data plus 2 type-tag bytes per point, so 1000 points is about 10 KB, well
  within localhost UDP. Godot warns above 4000 points.
- Documented in `docs/subsystems/osc-protocol.md` under Transport.

**Plugin subprocess shared memory:**

- New `#[repr(C)] BlockTransport { tempo: f64, tempo_inc: f64, song_pos_beats: f64,
  song_pos_seconds: f64, bar_start_beats: f64, bar_number: i32, flags: u32, tsig_num: i16,
  tsig_den: i16, _reserved: [u8; 20] }`.
  - `flags` bit 0 = playing. The has-tempo, beats, seconds and time-signature flags are always
    set by the host.
- `SharedMemoryLayout` gains `transport_offset` (64-byte aligned, between the output events and
  `BlockControl`), and `SharedMemory` gains a `transport()` accessor.
- The engine and `plugin_host` are always built together (spawned from the same directory), so
  no version field is added.
- Documented in `docs/subsystems/engine-plugin-architecture.md`.

**Engine types:**

- `audio/tempo_map.rs`:
  - `TempoPoint { tick: Tick, bpm: f64 }`
  - `TempoMap { points: Vec<TempoPoint>, seconds_ppq: Vec<f64> }`, where `seconds_ppq` holds the
    cumulative seconds × ppq at each point, so it doesn't depend on ppq.
  - `TempoMap::from_points(Vec<(Tick, f32)>)`, `is_empty`, `bpm_at(tick: f64, fallback) -> f64`,
    `slope_bpm_per_tick_at(tick: f64) -> f64`, `seconds_at(tick: f64, fallback, ppq) -> f64`.
  - `TempoCursor` for the per-frame forward walk.
  - `fill_tick_rates(map, settings, start_pos: f64, frames, sample_rate, out: &mut Vec<f64>)`.
- `audio/transport.rs`:
  - `Transport { tempo, tempo_inc, playing, song_pos_beats, song_pos_seconds, bar_start_beats,
    bar_number, time_sig_num, time_sig_den }` (`Copy`, `Default`).
  - `Transport::at(map, settings, tick_pos: f64, sample_rate, playing)`.
  - The bar length is `ppq·4·num/den` ticks, because the engine has one static time signature.
  - `tempo_inc` is `slope_bpm_per_tick × ticks_per_sample` when playing, and 0 when stopped.

**Godot models:**

- `TempoMap.gd` gains `seconds_at_tick(tick: float, fallback_bpm, ppq) -> float` and
  `tick_at_seconds(seconds, fallback_bpm, ppq) -> float`. Its doc comment is updated.
- `Project.gd` turns `tempo_map` into a property with a setter that reconnects `changed` to
  `_sync_tempo_map_to_engine()`. That method sends `/transport/tempo_map` when connected, and
  `_on_engine_confirmed_connected()` calls it after the track sync.
- `GridHelper.gd` gains `var tempo_map: TempoMap`. The setter connects `tempo_map.changed` to
  `changed.emit()`. `ticks_to_seconds` / `seconds_to_ticks` delegate to the map when it is set
  and non-empty.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/audio/tempo_map.rs` (new) | `TempoPoint`, `TempoMap`, `TempoCursor`, `fill_tick_rates`, closed-form seconds; `mod tests` |
| `Engine/src/audio/transport.rs` (new) | `Transport` and `Transport::at`; `mod tests` |
| `Engine/src/audio/mod.rs` | `pub mod tempo_map; pub mod transport;` |
| `Engine/src/audio/commands.rs` | `AudioCommand::SetTempoMap(Vec<(Tick, f32)>)`; `EngineState.tempo_map` (+ `Default`) |
| `Engine/src/audio/command_worker.rs` | `SetTempoMap` → `set_tempo_map()`: build off-lock, `mem::replace` under the lock, drop after unlock, log point count; `clear_project()` resets the map the same way |
| `Engine/src/osc/server.rs` | `["transport", "tempo_map"]` handler |
| `Engine/src/audio/render_scratch.rs` | `frame_tick_rates: Vec<f64>` preallocated to 8192 |
| `Engine/src/audio/processing.rs` | Build `Transport` at block start and push it to all devices before the not-playing return. Fill `frame_tick_rates`. `collect_tick_events` takes `&[f64]` instead of a scalar. The audio-clip loop reads the per-frame rate, derives the per-frame BPM for the stretch, seeks and loops with the new clip-timeline helper. Update the existing tests' call sites to pass a constant slice |
| `Engine/src/audio/types.rs` | `AudioPlayback::clip_source_frame(offset_ticks, recorded_bpm, ppq, clip_sr) -> f64` next to `calculate_stretch_factor` |
| `Engine/src/audio/devices/mod.rs` | `AudioDevice::set_transport(&mut self, _: &Transport) {}`; `pub fn apply_transport(devices: &mut [Box<dyn AudioDevice>], t: &Transport)`, which recurses through `as_container_mut()` |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs` | `transport` field, `set_transport`, write `BlockTransport` in `begin_block` before the `request_seq` store |
| `Engine/src/audio/ipc/protocol.rs` | `BlockTransport`, `TRANSPORT_FLAG_PLAYING`, `transport_offset` in `SharedMemoryLayout`, updated layout diagram |
| `Engine/src/audio/ipc/shared_memory.rs` | `transport()` accessor; layout alignment test covers the new offset |
| `Engine/src/plugin_host/audio_thread.rs` | `InstanceSlot.transport_event: TransportEvent`; `fn fill_transport_event(&BlockTransport, &mut TransportEvent)`; pass `Some(&slot.transport_event)` to `process()` |
| `Godot/data/TempoMap.gd` | `seconds_at_tick`, `tick_at_seconds`; doc comment |
| `Godot/data/Project.gd` | `tempo_map` setter + `_sync_tempo_map_to_engine()`; call on connect |
| `Godot/components/GridHelper.gd` | `tempo_map` property; map-aware `ticks_to_seconds` / `seconds_to_ticks` |
| `Godot/arranger/Arranger.gd` | `_on_project_activated()`: `grid_helper.tempo_map = project.tempo_map`; `_unbind_from_project()`: set to null |
| `Godot/editor/Editor.gd` | `_process()` uses `project.tempo_map.get_bpm_at_tick(_playhead_precise, project.tempo)`; `ticks_to_seconds()` uses `seconds_at_tick`; `_update_transport_ui()` shows the BPM at the playhead and sets `tempo_spinbox.editable = project.tempo_map.is_empty()`; `open_project()` connects `project.tempo_map.changed` to `_update_transport_ui` |
| `docs/subsystems/osc-protocol.md` | `/transport/tempo_map` |
| `docs/subsystems/engine-plugin-architecture.md` | `BlockTransport` region and the transport event |
| `docs/subsystems/engine-architecture.md` | Transport clock follows the tempo map; per-frame rates |
| `docs/adr/0007-engine-is-master-clock.md` | Amendment (see below) |

## ADR impact

**ADR-0007** says "All tick/sample conversions go through `ProjectSettings::{ticks_to_samples,
samples_to_ticks}`". This design breaks that deliberately. Under a tempo map, a constant-tempo
conversion is wrong. The clock now advances through `TempoMap`, and audio-clip source positions
go through `AudioPlayback::clip_source_frame` on the clip's recorded-BPM timeline. The ADR gets an
amendment note saying so. Its core decision, that the audio callback is the only clock and clip
positions advance frame by frame, is unchanged. ADR-0004 (sample-accurate MIDI) holds, because
tick events keep exact frame offsets.

## Migration and compatibility

- Nothing new is persisted. `.sonara` already stores `tempo_map`, and projects without it load
  empty, which gives the same behaviour as today.
- Engine–Godot version skew: an old engine logs an unknown address for `/transport/tempo_map`
  and plays at the static tempo. A new engine with an old Godot never receives a map and behaves
  as today.

## Test plan

- **Unit (engine):**
  - `cargo test tempo_map`:
    - `empty_map_uses_fallback`: 120 BPM / 48 kHz fills 0.04 ticks/sample, which is REQ-003.
    - `seconds_through_ramp`: `(0,120),(3840,60)` gives 4 ln 2 s at 3840 and +1 s at 4800
      (REQ-010, REQ-013).
    - `rates_are_continuous_across_buffers`: REQ-004.
    - `cursor_matches_binary_search`.
  - `cargo test processing`:
    - The existing tests, with the scalar replaced by a constant slice.
    - `ramp_ticks_are_contiguous`: REQ-005.
    - `constant_60_bpm_beat_takes_48000_frames` and `ramp_duration_matches_integral`: REQ-002.
    - `clip_seek_is_tempo_independent`: 60, 120 and 200 BPM all give source frame 24 000, which
      is REQ-007.
    - `clip_loop_bounds_on_clip_timeline`: REQ-008.
    - `clip_rate_follows_tempo`: REQ-006.
  - `cargo test transport`:
    - `transport_at_tick_1920`: REQ-012.
    - `tempo_inc_on_ramp`: about 3.125e-4, which is REQ-014.
    - `stopped_has_zero_inc`.
    - `devices_in_containers_receive_transport`: a recording test device inside a `ChainDevice`.
  - `cargo test fill_transport_event` (plugin_host): flags and fixed-point values, which is REQ-015.
  - `cargo test shared_memory`: the layout alignment test covers `transport_offset`.
  - `cargo test osc`, if the handler parsing is extracted into a testable fn: REQ-001.
  - Existing device tests pass unchanged: REQ-016.
- **Godot:**
  - `godot --headless --path Godot -s tests/test_tempo_map.gd -- --test`, extended with
    `seconds_at_tick` / `tick_at_seconds` round trips and the REQ-010 values.
  - `godot --headless --path Godot -s tests/test_playhead_interpolation.gd -- --test`, extended
    with the REQ-009 case: map `(0,60)` at static 120 advances 960 ticks in 1 s.
- **Live (engine + Godot running):**
  - Add points and watch the engine log for the point count.
  - A MIDI loop over a 120 → 60 ramp slows smoothly and the playhead tracks without snapping.
  - An audio clip stays on the grid through the ramp, and seeking into it mid-ramp lands in
    sync.
  - The time ruler labels are stretched through the ramp.
  - The tempo field is read-only and changes value during the ramp.
  - A tempo-synced CLAP delay or arpeggiator follows the static tempo and then the ramp.

## Risks

| Risk | Mitigation |
|---|---|
| Buffers larger than 8192 frames overrun `frame_tick_rates` capacity (allocation on the audio thread) | Same bound as `tick_events` today. Process in chunks of at most the capacity, or cap `frames` to the scratch length with a `debug_assert`, as `MAX_TICK_EVENTS` does |
| Per-frame Euler integration drifts from Godot's closed-form seconds | Error is well under 1 frame per beat at audio rates (tested). Godot snaps on errors over ¼ beat anyway |
| Existing seek-offset bug fix changes playback of clips whose `recorded_bpm` ≠ project tempo | Intended (it was out of sync). Called out in the changelog / TODO entry |
| Plugins misbehave on a transport jump at a Godot loop wrap | Same as a seek in any host; out of scope (no loop flags) |
| Dragging a tempo point floods OSC | One small packet per mouse move, the same order as automation drags; acceptable |

## Open questions

- (none)
