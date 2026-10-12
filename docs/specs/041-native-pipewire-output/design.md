# Native PipeWire Output — Design

Implements [requirements.md](./requirements.md).

## Context

- `Engine/Cargo.toml` — `cpal = "0.15"`, no features, so the only host is ALSA.
- `Engine/src/audio/stream.rs` — the output stream. `StreamControl` runs the `audio-stream`
  thread that owns the `!Send` cpal `Stream` (`run_stream_thread`, `StreamMsg::{Resolve, Start,
  Stop}`). `resolve` finds a device by `device.name()` on `cpal::default_host()`;
  `select_stream_config` asks for `BufferSize::Fixed(period × ALSA_PERIODS)` because cpal 0.15
  makes the period a quarter of the buffer. `build_stream` holds the data callback: gap-based xrun
  detection, `LoadWindow`, `run_live_block` (lock state, sidechain feed, clear, `process_audio`,
  `mix_and_output`, preview, `update_peaks`, meter sends). `list_output_devices` and
  `fill_device_info` serve `/audio/devices/request`. `watchdog` restarts a stalled stream.
  `MAX_BLOCK_FRAMES` = 8192 is the preallocated block size; `MAX_PERIOD_FRAMES` is derived from it.
- `Engine/src/audio/pipewire.rs` — the `pipewire-monitor` thread (`spawn_monitor`,
  `run_monitor`): every 3 s it runs `pw-top -b`, `pw-dump` (`find_stream_node` by process id) and
  `pw-metadata` (`metadata_value`), adds the node's ERR delta to `CallbackCounters::xruns` and
  sends `AudioCommand::PipeWireGraph(GraphInfo)` on changes. `required_period` grows the period so
  the ALSA ring holds a quantum; `describe_mismatch` builds the Settings warning. It returns for
  good when `pw-top` isn't installed. `run_tool` runs a tool with a timeout.
- `Engine/src/audio/command_worker/audio_config.rs` — `set_audio_config`,
  `apply_audio_config` (stop → resolve → `set_device_rate` → start, over a candidate list with
  fallbacks), `report_audio_config` (`EngineStatus::AudioConfig(AudioConfigReport)`),
  `list_audio_devices` (background thread), `on_pipewire_graph` (reopens with
  `required_period`). State lives in `AudioSettings` in `command_worker/mod.rs`.
- `Engine/src/audio/commands/mod.rs` — `AudioCommand::SetAudioConfig { device, sample_rate,
  period_frames }`, `PipeWireGraph`; `commands/status.rs` — `AudioConfigReport`,
  `EngineStatus::AudioDeviceInfo(OutputDeviceInfo)`.
- `Engine/src/osc/routes/audio.rs` — `parse_audio_config` for `/audio/config/set`, with the test
  `audio_config_set_parses_device_rate_and_buffer`. `Engine/src/osc/encode.rs` —
  `/audio/device` and `audio_config_args`.
- `Engine/src/audio/engine.rs` — `AudioEngine::with_status_channel` builds `CallbackCounters`,
  `StreamControl`, the `CommandWorker` and the monitor. `Engine/src/main.rs` has no shutdown path:
  Ctrl+C ends the process with the default signal action.
- cpal 0.18.2 (`HostId::PipeWire`, feature `pipewire`, built on `pipewire` 0.10): `BufferSize::Fixed(n)`
  becomes the node property `node.latency = n/rate`; the data callback runs on cpal's own `pw_out`
  main-loop thread, which the `realtime-dbus` feature promotes through rtkit
  (`audio_thread_priority`), reporting `ErrorKind::RealtimeDenied` on failure. Underruns arrive as
  `ErrorKind::Xrun`. `Device::id()` is the node name (stable); `description().name()` is the
  readable name. The ALSA host now uses period = n, buffer = 2n. `OutputCallbackInfo::timestamp()`
  gives `callback` and predicted `playback` instants.
- Godot: `Godot/data/AudioConfig.gd` (autoload; `KEYS`, `build_message`, `parse_device`,
  `parse_config`, `_on_setting_changed`), `Godot/settings/AudioSettingControl.gd` (`_entries`,
  `_device_label`, `_info_text`, `_warning_text`), `Godot/settings/Settings.gd` (registers
  `audio/output_device`, `audio/sample_rate`, `audio/buffer_size`), test
  `Godot/tests/test_audio_config.gd`.

## Approach

Upgrade cpal to 0.18.2 with the `pipewire` and `realtime-dbus` features and add a **driver** to
the stream request. The stream code stays one module: `resolve` picks a cpal host by driver
(`cpal::host_from_id`) instead of `cpal::default_host()`, matches devices by their stable id, and
asks for `BufferSize::Fixed(period)` directly. On PipeWire the engine is then an ordinary graph
node, rendering each cycle in that cycle (REQ-001); on ALSA the ring is two periods (REQ-006).
Because PipeWire, not the engine, now decides the block length, the callback renders long blocks
in `MAX_BLOCK_FRAMES` chunks (REQ-011).

Forcing follows Bitwig: a small `ForcedClock` on the command thread writes `clock.force-quantum`
and `clock.force-rate` with `pw-metadata` before the PipeWire stream starts, remembers what was
there before, and restores it on stop or shutdown only if the values are still the ones it wrote
(REQ-007–009). The graph monitor already reads those keys every 3 s; when they differ from what the
engine wrote, another application has forced them, and the engine plays along without fighting
back until the user changes a setting (REQ-010). Shutdown gets a termination handler (`ctrlc` with
its `termination` feature) that restores the values and exits.

Rejected: **using pipewire-rs directly** (our own `pw_stream`, metadata proxy and main loop). It
gives full control over node properties and runs the callback on PipeWire's own realtime data
thread, but it is several hundred lines of unsafe-adjacent loop code that cpal now maintains. The
stream code stays isolated in `stream.rs`, so this remains possible later. Also rejected: **keeping
the ALSA bridge and shrinking the ring** — cpal 0.18 already does that for ALSA, and it still
leaves one extra quantum, polls instead of being scheduled by the graph, and can't force anything.
**Writing the metadata through the `pipewire` crate** instead of `pw-metadata` was rejected for
now: it needs a main loop thread of our own, and the monitor already depends on the PipeWire tools.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `StreamRequest::driver`, `StreamInfo::{driver, label}` | command thread (`AudioSettings`) | stream thread by message; `StreamControl::active` snapshot | n/a (not on the callback) |
| `CallbackCounters::output_latency_us: AtomicU32` | written by the callback every block | read by the graph monitor | yes: one relaxed store; the timestamp subtraction is plain arithmetic |
| `CallbackCounters::callback_tid: AtomicI32` | written by the callback once per stream (0 → tid) | read by the graph monitor, which calls `sched_getscheduler(tid)` | yes: one `gettid` syscall on the first callback only, no allocation or blocking |
| `CallbackCounters::realtime_denied: AtomicBool` | set by the stream's error callback (cpal thread, not the data callback) | graph monitor | yes |
| `CallbackCounters::native_pipewire: AtomicBool` | stream thread, at start | graph monitor (skip pw-top ERR, which cpal reports itself) and the callback (skip gap detection) | yes: relaxed load |
| `ForcedClock` (`Arc<Mutex<ForcedClock>>`) | command thread | the termination handler thread (`restore` then `exit`) | n/a: never on the callback; runs `pw-metadata` with the state lock released |
| Chunked render in `run_live_block` | audio callback | — | yes: `chunks_mut` over the cpal buffer, no allocation; one state lock per callback as today |

## Data and protocol changes

**`/audio/config/set [s:device, i:rate, i:buffer, s:driver]`** (Godot → Rust). `driver` is
`"pipewire"` or `"alsa"`. Missing (older Godot) means `"pipewire"`; an unknown value is logged and
treated as `"pipewire"`. `device` is now the device **id** for that driver (`""` = system default).

**`/audio/devices/request`** (Godot → Rust), unchanged arguments: the engine lists the devices of
the **requested** driver. Godot requests the list again after a driver change.

**`/audio/device [s:id, s:label, i:is_default, i:min_buffer, i:max_buffer, i:channels, i:rates…]`**
(Rust → Godot). New `label` at index 1 (the readable name); `id` is what `/audio/config/set`
takes. The default pseudo-device of the PipeWire host isn't listed (Godot's "System default"
stands for it). Index shift is breaking; Godot changes in the same release.

**`/audio/config`** (Rust → Godot) appends:

| # | Type | Meaning |
|---|---|---|
| 13 | s | `driver`: the running driver (`"pipewire"`/`"alsa"`, `""` without a stream) |
| 14 | s | `requested_driver` |
| 15 | s | `device_label`: readable name of the running device |
| 16 | f | `output_latency_ms`: driver-reported time from render to hardware; 0 until measured |
| 17 | s | `realtime`: `"granted"`, `"denied"` or `"unknown"` (not yet known) |

`latency_ms` (#3) keeps meaning one buffer. `mismatch` (#11) gains the "forced by another
application" text (REQ-010).

**Internal commands:** `AudioCommand::SetAudioConfig` gains `driver: Driver`; new
`AudioCommand::OutputHealth { latency_us: u32, realtime: RealtimeState }` from the graph monitor
(command thread only), handled by `report_audio_config` when it changes.

**Persisted:** `audio/driver` in `Settings.gd`, `Type.STRING`, default `"pipewire"`, sub
"Output", scene `res://settings/AudioSettingControl.tscn`, registered before `audio/output_device`.
Changing it sets `audio/output_device` to `""` (REQ-003).

## File-by-file change list

| File | Change |
|---|---|
| `Engine/Cargo.toml` | `cpal = { version = "0.18.2", features = ["pipewire", "realtime-dbus"] }`; add `ctrlc = { version = "3", features = ["termination"] }`. |
| `Engine/src/audio/stream.rs` | Port to the cpal 0.18 API (`SampleRate` is `u32`, `StreamConfig` by value, `description()`/`id()` instead of `name()`, unified `cpal::Error`, streams returned paused). Add `pub enum Driver { PipeWire, Alsa }` (`as_str`, `parse`, `host_id`), `driver` on `StreamRequest`/`StreamInfo`, `label` on `StreamInfo`/`OutputDeviceInfo`. `resolve` and `list_output_devices` take the host from the driver and match by `device.id()?.id()`. `select_stream_config`/`fixed_buffer_frames` ask for `Fixed(period)`; `ALSA_PERIODS` = 2 (only used by `required_period`), `MAX_PERIOD_FRAMES` = 2048 as an explicit constant. `run_live_block` renders `data` in chunks of at most `MAX_BLOCK_FRAMES` (block clock published per chunk). Data callback: store `playback − callback` in `output_latency_us`, store the tid once, skip gap-based xruns when `native_pipewire`. Error callback: `Xrun` → `xruns`, `RealtimeDenied` → `realtime_denied`, others → WARN. `CallbackCounters` gains the four fields above. |
| `Engine/src/audio/pipewire.rs` | Monitor no longer returns when the tools are missing (it still reports output health). Each poll: read latency and realtime state (`realtime_state(policy, denied)`, pure) and send `AudioCommand::OutputHealth` on change; add pw-top ERR to xruns only when not `native_pipewire`. New `ForcedClock` with `apply(quantum, rate)`, `restore()`, `is_ours(&GraphInfo)` over a `MetadataIo` trait (real impl uses `run_tool("pw-metadata", …)` to read and write; a fake in tests). `describe_mismatch` gains a `forced_by_other: bool` input and its text. |
| `Engine/src/audio/command_worker/mod.rs` | `AudioSettings` gains `forced: Arc<Mutex<ForcedClock>>`, `latency_us`, `realtime`. `CommandWorker::new` takes the `ForcedClock` handle. Dispatch `SetAudioConfig { driver, .. }` and `OutputHealth`. |
| `Engine/src/audio/command_worker/audio_config.rs` | Candidates: request → default device on the same driver → ALSA default when the request was PipeWire (notice "PipeWire isn't running…") → `StreamRequest::default()`. PipeWire: `ForcedClock::apply(period, rate)` after resolve, before start; no `required_period`. Stopping a PipeWire stream for an ALSA one calls `restore`. `on_pipewire_graph` only reopens on ALSA; on PipeWire it reports, marking `forced_by_other` when `!is_ours`. A later `set_audio_config` re-applies the force (REQ-008, REQ-010). `report_audio_config` fills the new report fields. `list_audio_devices` passes the requested driver. |
| `Engine/src/audio/commands/mod.rs` | `SetAudioConfig.driver`; `OutputHealth { latency_us, realtime }`; classify it command-thread only next to `PipeWireGraph`. |
| `Engine/src/audio/commands/status.rs` | `AudioConfigReport` gains `output_latency_us: u32`, `realtime: RealtimeState`, `forced_by_other: bool`. |
| `Engine/src/audio/engine.rs` | Build the `ForcedClock`, pass it to `CommandWorker::new` and the monitor; `AudioEngine::forced_clock()` accessor; log "Using audio host" per driver at start instead of `default_host()`. |
| `Engine/src/main.rs` | Install a `ctrlc` handler: `forced_clock.lock().restore()`, log, `std::process::exit(0)`. |
| `Engine/src/osc/routes/audio.rs` | Optional 4th `s:driver` argument; tests for with, without and unknown driver. |
| `Engine/src/osc/encode.rs` | `/audio/device` with `label` at index 1; `audio_config_args` appends #13–17. |
| `Godot/settings/Settings.gd` | Register `audio/driver`. |
| `Godot/data/AudioConfig.gd` | `DRIVER_KEY` in `KEYS`; `build_message` appends the driver; `parse_device` reads `id`/`label` (the dictionary keeps `name` = id and adds `label`); `parse_config` reads #13–17; on a driver change set `DEVICE_KEY` to `""` and request devices after applying. Header comment lists the new arguments. |
| `Godot/settings/AudioSettingControl.gd` | `_entries` for `DRIVER_KEY` (PipeWire, ALSA); device entries and the "System default (…)" label use `label`; Driver row info "Running: PipeWire · realtime scheduling granted/denied"; Buffer row info adds "Output latency: N ms". |
| `Godot/tests/test_audio_config.gd` | Cover the new message, both parsers and the device reset on driver change. |
| `docs/subsystems/osc-protocol.md` | Audio Device Settings section: the changes above; drop the "four buffers" paragraph. |
| `docs/subsystems/engine-architecture.md` | Thread model line for the monitor; "Output device, sample rate and buffer size" section rewritten for drivers, forcing and chunked callbacks; `PipeWireGraph`/`OutputHealth` rows in the command classification. |
| `docs/subsystems/engine-debugging.md` | Xrun sources per driver; the forced-quantum note now mentions that the engine itself forces while it runs and restores on exit. |
| `CONTEXT.md` | Glossary: **Driver**, **Forced quantum**. |

## Migration and compatibility

- Projects: nothing changes.
- `config.json`: `audio/driver` is new and defaults to PipeWire. A saved `audio/output_device` was
  an ALSA name; on PipeWire it isn't found, so the default sink plays and the notice says so
  (REQ-005). Choosing a device once fixes it. Most configs hold `""`.
- Version skew: an older Godot sends three arguments and gets PipeWire. An older Godot reading the
  new `/audio/device` would misparse it; both ship together.
- Build: `libpipewire-0.3-dev`, `libspa-0.2-dev`, `libclang-dev` (and `libdbus-1-dev`) are now
  required (README and AGENTS.md already list them).

## Test plan

- **Unit (Rust):**
  - `cargo test long_callbacks_render_in_chunks` (`stream.rs`) — a 16384-frame callback with
    `MAX_BLOCK_FRAMES` 8192 renders a running channel through both chunks with no gap at frame
    8192, and the transport advances 16384 frames.
  - `cargo test alsa_buffer_is_the_period` (`stream.rs`, replaces
    `buffer_is_four_periods_within_the_device_range`) — `Fixed(period)` within the device range.
  - `cargo test driver_parses` (`stream.rs`) — `"pipewire"`, `"alsa"`, unknown → `None`.
  - `cargo test forced_clock` (`pipewire.rs`, fake `MetadataIo`) — first `apply` saves previous
    values; `restore` writes them back when still ours; leaves a foreign value alone; `is_ours`
    false after a foreign write; re-`apply` after a foreign write forces again.
  - `cargo test realtime_state` (`pipewire.rs`) — FIFO/RR → granted, denied flag → denied, else unknown.
  - `buffer_grows_only_when_the_quantum_outgrows_it` and `mismatch_text_names_the_forcing_command`
    updated for two ALSA periods and the forced-by-other text.
  - `cargo test audio_config_set` (`osc/routes/audio.rs`) — with, without and unknown driver.
  - an `encode.rs` test for `/audio/device` and the `/audio/config` tail.
- **Godot:** `godot --headless --path Godot -s tests/test_audio_config.gd -- --test` — message,
  parsers, device reset on driver change.
- **Live** (the user's engine may hold port 7000, and Bitwig may be forcing: ask before changing
  PipeWire settings):
  - PipeWire, buffer 1024 → `pw-metadata -n settings 0` shows 1024/48000; `pw-top` shows the
    engine node under the sink at quantum 1024; Settings shows output latency ≤ ~43 ms + hardware.
  - Buffer 256 → quantum follows within a second; no xruns in the Engine panel for 60 s.
  - Quit the engine with Ctrl+C → the previous forced values are back.
  - Start Bitwig after Sonara → Sonara follows Bitwig's quantum, Settings shows the warning; quit
    Sonara → Bitwig's values stay.
  - `chrt -p` on the `pw_out` thread → `SCHED_FIFO`/`SCHED_RR`; startup log says granted.
  - Driver ALSA → plays; log shows a 2-period buffer.
  - Quantum forced to 8192 with `SONARA_FEATURES=rt-debug` → no allocation reports.
  - By ear: a MIDI keyboard note against Bitwig at the same buffer size.

## Risks

| Risk | Mitigation |
|---|---|
| cpal's PipeWire host is new (0.18.0, June 2026) and may misbehave (stalls, device changes) | The ALSA driver stays selectable; the watchdog restart still applies; live checks above. |
| `clock.force-rate` outside `clock.allowed-rates` doesn't switch the hardware (here allowed is `[48000]`), so the graph resamples | The rate list on PipeWire comes from the allowed rates cpal reports, so Settings only offers those; the existing rate mismatch warning covers the rest. |
| The engine is killed (SIGKILL, crash) and leaves the quantum forced | Out of scope by decision; the next engine start forces again and restores on a clean exit; `engine-debugging.md` documents the `pw-metadata … 0` command. |
| `pw-metadata` isn't installed | `ForcedClock::apply` fails softly: the stream still runs at the graph's quantum and the notice says forcing isn't possible. |
| Xruns counted twice (cpal `Xrun` and pw-top ERR) or falsely (callback gaps equal to a quantum) | `native_pipewire` switches off both other sources on the PipeWire driver. |
| rtkit refuses (limits, `RLIMIT_RTTIME`) | Reported as denied in log and Settings (REQ-013); audio still plays. |
| Plugin deadlines with chunked callbacks | `block_clock.publish` per chunk, so each chunk gets its own deadline as today. |
| Last writer wins between Sonara and Bitwig when both force | Accepted with "always force"; REQ-010 makes Sonara follow later changes instead of fighting. |

## Open questions

None.
