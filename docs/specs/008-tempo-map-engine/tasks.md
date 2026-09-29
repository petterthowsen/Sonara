# Tempo Map Playback and Device Transport — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

All engine commands run from `Engine/`; Godot commands from the repo root.

## Phase 1 — tempo map end to end

- [x] **T-001** [REQ-002, REQ-003, REQ-010, REQ-013] Engine `TempoMap` with closed-form seconds, BPM/slope lookup, `TempoCursor` and `fill_tick_rates`.
  - _Files_: `Engine/src/audio/tempo_map.rs` (new), `Engine/src/audio/mod.rs`
  - _Output_: module with `from_points`, `is_empty`, `bpm_at`, `slope_bpm_per_tick_at`, `seconds_at`, `TempoCursor`, `fill_tick_rates`
  - _Verify_: `cargo test tempo_map`. `empty_map_uses_fallback` (0.04 ticks/sample at 120/48 kHz), `seconds_through_ramp` (4 ln 2 s at 3840, +1 s at 4800), `rates_are_continuous_across_buffers`, `cursor_matches_binary_search` all pass
  - _Depends on_: —

- [x] **T-002** [REQ-001] `SetTempoMap` command, `EngineState.tempo_map`, worker swap (build off-lock, swap under lock, drop after), reset in `clear_project()`.
  - _Files_: `Engine/src/audio/commands.rs`, `Engine/src/audio/command_worker.rs`
  - _Output_: the engine holds a map equal to the last one received and logs `Tempo map set: N points`
  - _Verify_: `cargo build --release` passes. A unit test sends `SetTempoMap` with unsorted points through `CommandWorker` or the swap helper and gets them back sorted by tick
  - _Depends on_: T-001

- [x] **T-003** [REQ-001] OSC handler `/transport/tempo_map` (`i,f` pairs, empty = clear, warn on malformed trailing value).
  - _Files_: `Engine/src/osc/server.rs`
  - _Output_: the handler parses into `AudioCommand::SetTempoMap`. Parsing lives in a small pure fn so it can be tested
  - _Verify_: `cargo test tempo_map_args`: 2 pairs parse to 2 points, 0 args give an empty map, and an odd trailing int is dropped
  - _Depends on_: T-002

- [x] **T-004** [REQ-001] Godot sends the map: `Project.tempo_map` setter reconnects `changed` → `_sync_tempo_map_to_engine()`, which is called after the track sync on connect. Warn above 4000 points.
  - _Files_: `Godot/data/Project.gd`
  - _Output_: every add/move/delete/clear/undo/redo/load sends `/transport/tempo_map` while connected
  - _Verify_: `Godot/tests/run_all.sh` stays green. Live: add a point with the engine running and the engine log shows `Tempo map set: 1 points`. Undo shows `0 points`
  - _Depends on_: T-003

## Phase 2 — engine clock and clips follow the map

- [x] **T-005** [REQ-002, REQ-003, REQ-004, REQ-005] Per-frame tick rates: add `RenderScratch.frame_tick_rates` (capacity 8192). `process_audio` fills it via `fill_tick_rates`, `collect_tick_events` takes `&[f64]`, and the audio-clip loop advances from the same slice. Guard frames above capacity (design Risks).
  - _Files_: `Engine/src/audio/render_scratch.rs`, `Engine/src/audio/processing.rs`
  - _Output_: the playhead advances at the effective tempo per frame, and an empty map behaves exactly as before
  - _Verify_: `cargo test processing`. The existing tests pass with the scalar replaced by a constant slice. The new tests `constant_60_bpm_beat_takes_48000_frames`, `ramp_duration_matches_integral` (133 084 ±4 frames for ticks 0→3840) and `ramp_ticks_are_contiguous` pass
  - _Depends on_: T-002

- [x] **T-006** [REQ-006, REQ-007, REQ-008] Audio clips on the clip timeline: add `AudioPlayback::clip_source_frame`. The seek offset and loop bounds use it, and the per-frame advance is `frame_bpm/recorded_bpm · clip_sr/device_sr`.
  - _Files_: `Engine/src/audio/types.rs`, `Engine/src/audio/processing.rs`
  - _Output_: clip seek, loop and rate no longer depend on the static project tempo
  - _Verify_: `cargo test processing`. `clip_seek_is_tempo_independent` (source frame 24 000 at 60/120/200 BPM), `clip_loop_bounds_on_clip_timeline` (wrap at 24 000 at 60 and 200 BPM) and `clip_rate_follows_tempo` pass
  - _Depends on_: T-005

## Phase 3 — transport to devices and plugins

- [x] **T-007** [REQ-012, REQ-013, REQ-014] `Transport` type and `Transport::at` (beats, seconds via the map, bar start/number from the static signature, `tempo_inc`).
  - _Files_: `Engine/src/audio/transport.rs` (new), `Engine/src/audio/mod.rs`
  - _Output_: a pure constructor for the per-block transport snapshot
  - _Verify_: `cargo test transport`. `transport_at_tick_1920` (2.0 beats, 1.0 s, bar 0), `transport_seconds_through_ramp` (5.0 beats, ≈3.773 s at 4800), `tempo_inc_on_ramp` (≈3.125e-4) and `stopped_has_zero_inc` pass
  - _Depends on_: T-001

- [x] **T-008** [REQ-012, REQ-016] `AudioDevice::set_transport` (default no-op) and `devices::apply_transport`, which recurses through containers. `process_audio` builds the transport at block start and applies it to every channel before the not-playing return.
  - _Files_: `Engine/src/audio/devices/mod.rs`, `Engine/src/audio/processing.rs`
  - _Output_: every device, including those nested in chain/layer/drum_machine, sees the block's transport, whether playing or stopped
  - _Verify_: `cargo test transport`. `devices_in_containers_receive_transport` (a recording device inside a `ChainDevice` sees tick 1920 values after one `process_audio`) passes. The full `cargo test` passes, which covers REQ-016
  - _Depends on_: T-005, T-007

- [x] **T-009** [REQ-015] Shared-memory transport: `BlockTransport` + `TRANSPORT_FLAG_PLAYING` in protocol, `transport_offset` in `SharedMemoryLayout`, `SharedMemory::transport()`, and the layout diagram.
  - _Files_: `Engine/src/audio/ipc/protocol.rs`, `Engine/src/audio/ipc/shared_memory.rs`
  - _Output_: each instance's mapping has a 64-byte-aligned transport region
  - _Verify_: `cargo test shared_memory`. The alignment test asserts `transport_offset % 64 == 0` and that `control_offset` comes after the transport region
  - _Depends on_: T-007

- [x] **T-010** [REQ-015] Engine side: `SubprocessClapAdapter` stores the transport in `set_transport` and writes `BlockTransport` in `begin_block` before the `request_seq` Release store.
  - _Files_: `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs`
  - _Output_: each published block carries its transport
  - _Verify_: `cargo test subprocess_adapter`. The new `begin_block_publishes_transport` (using `new_for_test`, like the existing tests) reads back the tempo and playing flag from shared memory
  - _Depends on_: T-008, T-009

- [x] **T-011** [REQ-015] Plugin host: `InstanceSlot.transport_event`, `fill_transport_event(&BlockTransport, &mut TransportEvent)` (flags; `BeatTime`/`SecondsTime::from_float`; loop/record/pre-roll cleared), and pass `Some(&slot.transport_event)` to `process()`.
  - _Files_: `Engine/src/plugin_host/audio_thread.rs`
  - _Output_: CLAP plugins receive a transport event every block
  - _Verify_: `cargo test fill_transport_event` checks the flags and the fixed-point beats and seconds for a playing 120 BPM block at tick 1920. `cargo build --release` builds both binaries
  - _Depends on_: T-009

## Phase 4 — Godot follows the map

- [x] **T-012** [REQ-010] `TempoMap.seconds_at_tick` / `tick_at_seconds` (closed form, same as the engine), and update the class doc comment.
  - _Files_: `Godot/data/TempoMap.gd`, `Godot/tests/test_tempo_map.gd`
  - _Output_: tick↔seconds through the map
  - _Verify_: `godot --headless --path Godot -s tests/test_tempo_map.gd -- --test` passes with the new cases: 3840 → ≈2.773 s, 4800 → ≈3.773 s, round trip within 1 tick, empty map uses the fallback
  - _Depends on_: —

- [x] **T-013** [REQ-010] `GridHelper.tempo_map` (setter relays `changed`), map-aware `ticks_to_seconds`/`seconds_to_ticks`, set and cleared in `Arranger._on_project_activated` / `_unbind_from_project`.
  - _Files_: `Godot/components/GridHelper.gd`, `Godot/arranger/Arranger.gd`
  - _Output_: the time ruler labels real time and redraws on map edits
  - _Verify_: `Godot/tests/run_all.sh` stays green. Live: the time ruler labels stretch through a ramp and update while a point is dragged
  - _Depends on_: T-012

- [x] **T-014** [REQ-009, REQ-011] Editor: `_process()` free-runs at `tempo_map.get_bpm_at_tick(_playhead_precise, project.tempo)`, `ticks_to_seconds()` uses `seconds_at_tick`, and `_update_transport_ui()` shows the BPM at the playhead and sets `tempo_spinbox.editable`. `open_project()` connects `tempo_map.changed` → `_update_transport_ui`.
  - _Files_: `Godot/editor/Editor.gd`, `Godot/tests/test_playhead_interpolation.gd`
  - _Output_: the playhead and transport display follow the map
  - _Verify_: `godot --headless --path Godot -s tests/test_playhead_interpolation.gd -- --test` passes with the new case: map `(0,60)` and static 120 advance 960 ticks in 1 s
  - _Depends on_: T-012

## Phase 5 — docs

- [x] **T-015** [REQ-001] Document `/transport/tempo_map` in the OSC reference.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: address, `i:tick, f:bpm …` args, empty = clear, direction Godot → engine
  - _Verify_: the message appears in the Transport table
  - _Depends on_: T-003

- [x] **T-016** [REQ-015] Document the `BlockTransport` region and the transport event.
  - _Files_: `docs/subsystems/engine-plugin-architecture.md`
  - _Output_: layout, ordering (the `request_seq` Release/Acquire pair) and field mapping to `clap_event_transport`
  - _Verify_: the section exists and matches `protocol.rs`
  - _Depends on_: T-011

- [x] **T-017** [REQ-002, REQ-006] Engine architecture notes, and the ADR-0007 amendment (conversions go through `TempoMap` and `AudioPlayback::clip_source_frame`, not the constant-tempo `ProjectSettings` helpers).
  - _Files_: `docs/subsystems/engine-architecture.md`, `docs/adr/0007-engine-is-master-clock.md`
  - _Output_: the docs describe per-frame tick rates and the transport snapshot, and the ADR has a dated amendment
  - _Verify_: both files mention the tempo map, and the ADR no longer claims all conversions use `ProjectSettings`
  - _Depends on_: T-006, T-008

## Phase 6 — gates and live verification

- [x] **T-018** [REQ-all] Gates: `cargo fmt`, `cargo test`, `cargo build --release`, `Godot/tests/run_all.sh`.
  - _Files_: —
  - _Output_: all green, with any already-failing tests listed by name
  - _Verify_: command output
  - _Depends on_: T-001 … T-017

- [x] **T-019** [REQ-all] Live check with the engine and Godot running (user-run; the engine may already hold port 7000).
  - _Files_: `TODO.md`, `STATUS.md`
  - _Output_: the `TODO.md` entry is marked `[x]` once verified, and `STATUS.md` notes what was and wasn't checked
  - _Verify_:
    1. Add a 120 → 60 ramp over 4 bars with a MIDI loop playing. The tempo slows smoothly, and the playhead tracks without snapping.
    2. An audio clip (recorded at the project tempo) stays on the grid through the ramp. Seeking into it mid-ramp lands in sync.
    3. The time ruler labels stretch through the ramp.
    4. The tempo field is read-only, shows the changing BPM, and is editable again after Clear Tempo Automation.
    5. A tempo-synced CLAP delay or arpeggiator follows the static tempo, then the ramp.
    6. Save, reload and play: same result.
  - _Depends on_: T-018
