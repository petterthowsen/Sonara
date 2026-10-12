# Native PipeWire Output — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Prerequisite: `libpipewire-0.3-dev libspa-0.2-dev libclang-dev libdbus-1-dev` installed
(`pkg-config --modversion libpipewire-0.3` succeeds).

## Phase 1 — cpal 0.18 and the driver, end to end

- [x?] **T-001** [REQ-006] Upgrade cpal to 0.18.2 (features `pipewire`, `realtime-dbus`) and port
  `stream.rs` to its API with ALSA still the only driver used: `SampleRate` as `u32`,
  `StreamConfig` by value, `description()`/`id()` instead of `name()`, `cpal::Error`, explicit
  `play()`. `Fixed(period)` instead of `period × ALSA_PERIODS`; `ALSA_PERIODS` = 2,
  `MAX_PERIOD_FRAMES` = 2048 explicit. Update `required_period` tests and replace
  `buffer_is_four_periods_within_the_device_range` with `alsa_buffer_is_the_period`.
  - _Files_: `Engine/Cargo.toml`, `Engine/src/audio/stream.rs`, `Engine/src/audio/pipewire.rs`
  - _Output_: engine builds and plays on ALSA through cpal 0.18
  - _Verify_: `cargo build --release` and `cargo test` pass; `./run_release.sh` log shows the
    stream started with the requested period; `./test_osc.sh` makes sound
  - _Depends on_: —

- [x?] **T-002** [REQ-001, REQ-002, REQ-005] Add `Driver { PipeWire, Alsa }` to `StreamRequest`,
  `StreamInfo` and `AudioCommand::SetAudioConfig`; `resolve` and `list_output_devices` use
  `cpal::host_from_id(driver.host_id())` and match by device id; `label` on `StreamInfo` and
  `OutputDeviceInfo`; the PipeWire default pseudo-device is not listed. Default driver PipeWire.
  - _Files_: `Engine/src/audio/stream.rs`, `Engine/src/audio/commands/mod.rs`,
    `Engine/src/audio/command_worker/mod.rs`, `Engine/src/audio/command_worker/audio_config.rs`,
    `Engine/src/audio/engine.rs`
  - _Output_: the engine opens a native PipeWire stream by default
  - _Verify_: `cargo test driver_parses`; live, `pw-top -b -n 2` shows the engine's node as a
    native stream (not `alsa_playback.engine`), and audio plays
  - _Depends on_: T-001

- [x?] **T-003** [REQ-002, REQ-005] OSC: optional 4th `s:driver` on `/audio/config/set`;
  `/audio/device` with `label` at index 1; `/audio/devices/request` lists the requested driver's
  devices.
  - _Files_: `Engine/src/osc/routes/audio.rs`, `Engine/src/osc/encode.rs`,
    `Engine/src/audio/command_worker/audio_config.rs`
  - _Output_: Godot can choose the driver and see readable device names
  - _Verify_: `cargo test audio_config_set` (with, without, unknown driver) and the new
    `/audio/device` encode test pass
  - _Depends on_: T-002

## Phase 2 — behaviour

- [x?] **T-004** [REQ-011] Render callbacks in chunks of at most `MAX_BLOCK_FRAMES` inside
  `run_live_block` (one lock, block clock published per chunk, meters once).
  - _Files_: `Engine/src/audio/stream.rs`
  - _Output_: any callback length renders correctly without allocation
  - _Verify_: `cargo test long_callbacks_render_in_chunks`
  - _Depends on_: T-001

- [x?] **T-005** [REQ-003, REQ-004] Candidate list per driver: request → default device on the
  same driver → ALSA default when PipeWire was requested (notice) → default config. Driver switch
  stops and reopens like a device change.
  - _Files_: `Engine/src/audio/command_worker/audio_config.rs`
  - _Output_: live driver switching and the PipeWire-unavailable fallback
  - _Verify_: live, `oscsend localhost 7000 /audio/config/set siis "" 48000 1024 alsa` then
    `… pipewire` during playback keeps the transport running and `/audio/config` reports each
    driver; starting with `PIPEWIRE_RUNTIME_DIR=/nonexistent` runs on ALSA with a notice
  - _Depends on_: T-003

- [x?] **T-006** [REQ-007, REQ-008, REQ-009] `ForcedClock` over a `MetadataIo` trait (real impl via
  `pw-metadata`): `apply` saves previous values on first use and writes quantum and rate;
  `restore` writes them back only while still ours. Command worker applies it before starting a
  PipeWire stream and on every config change, and restores when switching to ALSA.
  - _Files_: `Engine/src/audio/pipewire.rs`, `Engine/src/audio/command_worker/mod.rs`,
    `Engine/src/audio/command_worker/audio_config.rs`, `Engine/src/audio/engine.rs`
  - _Output_: the engine forces its buffer size and rate while it runs on PipeWire
  - _Verify_: `cargo test forced_clock`; live (with the user's permission), buffer 512 →
    `pw-metadata -n settings 0` shows `clock.force-quantum 512` and `clock.force-rate 48000`;
    buffer 256 → updates within a second
  - _Depends on_: T-005

- [x?] **T-007** [REQ-009] Termination handler: `ctrlc` (feature `termination`) restores the
  `ForcedClock` and exits.
  - _Files_: `Engine/Cargo.toml`, `Engine/src/main.rs`, `Engine/src/audio/engine.rs`
  - _Output_: Ctrl+C / SIGTERM leave PipeWire's settings as they were
  - _Verify_: live, note `clock.force-quantum` before start, run the engine, Ctrl+C → the value
    is back; `kill -TERM` likewise
  - _Depends on_: T-006

- [x?] **T-008** [REQ-010] Foreign forcing: `on_pipewire_graph` on the PipeWire driver never
  reopens; when the graph's forced values aren't ours it marks `forced_by_other`, and
  `describe_mismatch` says another application forces the quantum/rate. The next
  `set_audio_config` forces again.
  - _Files_: `Engine/src/audio/pipewire.rs`, `Engine/src/audio/command_worker/audio_config.rs`,
    `Engine/src/audio/commands/status.rs`
  - _Output_: the engine follows another app's quantum and Settings explains it
  - _Verify_: `cargo test mismatch_text`; live, `pw-metadata -n settings 0 clock.force-quantum
    2048` with Sonara at 512 → 2048-frame blocks, no xruns, `/audio/config` mismatch names it
  - _Depends on_: T-006

- [x?] **T-009** [REQ-012, REQ-013, REQ-014] Output health: callback stores `playback − callback`
  and its tid once; the error callback maps `Xrun` and `RealtimeDenied`; gap detection and pw-top
  ERR are skipped on the PipeWire driver; the monitor keeps running without the PipeWire tools,
  derives `RealtimeState` and sends `AudioCommand::OutputHealth` on change; `/audio/config`
  appends #13–17.
  - _Files_: `Engine/src/audio/stream.rs`, `Engine/src/audio/pipewire.rs`,
    `Engine/src/audio/commands/mod.rs`, `Engine/src/audio/commands/status.rs`,
    `Engine/src/audio/command_worker/mod.rs`, `Engine/src/audio/command_worker/audio_config.rs`,
    `Engine/src/osc/encode.rs`
  - _Output_: measured latency, realtime state and correct xrun counts reach Godot
  - _Verify_: `cargo test realtime_state` and the `/audio/config` encode test; live, startup log
    says realtime granted, `chrt -p` on the `pw_out` thread shows `SCHED_FIFO`/`SCHED_RR`, and
    `oscdump`-style check of `/audio/config` shows a non-zero output latency
  - _Depends on_: T-004, T-008

## Phase 3 — Godot

- [x?] **T-010** [REQ-002, REQ-003, REQ-005, REQ-012, REQ-013] Register `audio/driver`;
  `AudioConfig` sends the driver, parses the new `/audio/device` and `/audio/config` fields,
  resets the device and re-requests devices on a driver change; `AudioSettingControl` shows the
  Driver row, device labels, output latency and realtime state.
  - _Files_: `Godot/settings/Settings.gd`, `Godot/data/AudioConfig.gd`,
    `Godot/settings/AudioSettingControl.gd`, `Godot/tests/test_audio_config.gd`
  - _Output_: Settings › Audio › Output has Driver, readable devices and the new info lines
  - _Verify_: `godot --headless --path Godot -s tests/test_audio_config.gd -- --test` passes;
    `Godot/tests/run_all.sh` has no new failures
  - _Depends on_: T-003, T-009

## Phase 4 — docs

- [x?] **T-011** [REQ-all] Update `osc-protocol.md` (audio section), `engine-architecture.md`
  (monitor line, output section, command classification), `engine-debugging.md` (xrun sources,
  forcing) and `CONTEXT.md` (Driver, Forced quantum).
  - _Files_: `docs/subsystems/osc-protocol.md`, `docs/subsystems/engine-architecture.md`,
    `docs/subsystems/engine-debugging.md`, `CONTEXT.md`
  - _Output_: docs match the code
  - _Verify_: every message and field changed in T-003/T-009 appears in `osc-protocol.md`; no
    mention of four ALSA periods or "never writes PipeWire's settings" remains
    (`grep -rn "ALSA_PERIODS\` (4)\|never writes PipeWire" docs/` is empty)
  - _Depends on_: T-010

## Phase 5 — live verification

- [ ] **T-012** [REQ-all] Live check with the engine and Godot running (ask first: the user's
  engine may hold port 7000 and PipeWire settings are system-wide), then comment on #1.
  - _Files_: —
  - _Output_: results recorded on GitHub issue #1; spec tasks marked `[x]`
  - _Verify_: the design's live list: PipeWire at 1024 shows output latency ≤ ~43 ms + hardware;
    256 for 60 s with no xruns; Ctrl+C restores; Bitwig started later is followed and its values
    survive Sonara quitting; ALSA driver plays with a 2-period buffer; `rt-debug` with quantum 8192
    reports no allocations; a MIDI keyboard note feels as prompt as Bitwig
  - _Depends on_: T-011

## Phase 6 — follow-up: lower-latency computer-keyboard input (planning only)

- [ ] **T-013** [follow-up, not part of this spec's requirements] Plan a way for computer-keyboard
  notes to reach the engine sooner than Godot's once-per-frame input handling (0–17 ms at 60 fps,
  measured after T-012), without modifying the Godot engine. Write the findings as a new spec or
  issue, not code.
  - _Files_: a new `docs/specs/<NNN>-…/requirements.md` or a GitHub issue
  - _Output_: measured key-to-sound latency per stage, and a chosen approach with its limits.
    Candidates to evaluate:
    - Godot project settings only: a higher frame rate (`application/run/max_fps`, V-Sync off)
      while the computer keyboard plays notes, and what it costs in CPU/GPU.
    - A GDExtension thread that reads key events itself (XInput2 raw events on the Sonara window
      under X11; Wayland has no equivalent for unfocused reads, so check what a focused client
      can do) and sends OSC without waiting for the frame.
    - Reading the keyboard in the engine via evdev (`/dev/input`, needs the `input` group; it sees
      every keyboard regardless of focus, so it must only play while Sonara's window is focused).
    - Whether the engine's fixed one-buffer live-MIDI delay
      (`Engine/src/audio/processing/live_midi.rs`) should become optional at large buffers.
  - _Verify_: the plan names the measured numbers and the chosen approach; the user approves it
  - _Depends on_: T-012
