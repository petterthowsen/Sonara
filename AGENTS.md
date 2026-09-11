# AGENTS.md

Sonara is a Linux-first DAW: a Rust real-time audio engine (`Engine/`) plus a Godot 4.7 UI (`Godot/`). They talk over OSC via UDP on localhost. Godot sends to port 7000 and the engine sends back to port 7001. CLAP plugins run out-of-process in a separate `plugin_host` binary.

Conventions: Middle C = C3 = MIDI note 60. Sequencing uses 960 PPQ.

## Commands

Engine (run from `Engine/`):

```bash
cargo build --release                         # default: debug builds are too slow for real-time audio
./run_release.sh                              # build all binaries + run engine (./run.sh = debug; ../run_engine.sh = same)
cargo test                                    # unit tests live in `mod tests` blocks inside source files
cargo test <name_substring> -- --nocapture    # run a single test
cargo fmt
```

- Two binaries: `engine` (default, `src/main.rs`) and `plugin_host` (`src/bin/plugin_host.rs`). `src/lib.rs` shares the modules between them. The engine spawns `plugin_host` from its own executable directory, so both must be built with the same profile. The run scripts handle this. A bare `cargo run` builds only `engine`, and CLAP plugins will then fail with a "plugin_host binary not found" error.
- Build prerequisites: CMake and `libsndfile1-dev` (needed by the `sfizz` git dependency).
- OSC smoke tests make sound. They are `./test_osc.sh`, `./test_plugin_osc.sh` and `./test_sfizz.sh` (which uses `test_kick.sfz`). Send ad-hoc messages with `oscsend localhost 7000 /transport/play` from `liblo-tools`.

Godot UI:

```bash
godot --path Godot                               # run the app; the engine must already be running
godot --headless --path Godot -s path/to/script.gd  # script path relative to Godot/
```

Godot does not launch the engine itself. Start the engine first.

## Architecture

### Engine threads (`Engine/src/`)
- **Main thread** (`main.rs`, `osc/server.rs`): runs the OSC server. It turns OSC messages into `AudioCommand`s (`audio/commands.rs`) and forwards `EngineStatus` back to Godot.
- **Audio callback** (`audio/processing.rs`, `audio/mixing.rs`): real-time. It receives commands with `try_recv` and sends statuses and meters at about 20 Hz.
- **WindowManager thread** (`window_manager.rs`, winit): owns the host windows for plugin GUIs.
- **AudioFileService** (`audio/io/`): worker pool for decoding (symphonia), resampling (rubato) and waveform caches. The audio thread only ever receives finished PCM. Stale `req_id` completions must be ignored.
- Main ↔ audio communication uses crossbeam channels.

### Audio thread contract (critical)
Code on the audio callback must never allocate, block, do I/O, or wait on a lock. Use `try_lock()` and skip the work (output silence or pass-through) when the lock isn't available. Preallocate every buffer at init time. Log with `info!`/`warn!`/`error!`, never `println!`.

### Callback and mixing
1. Drain commands.
2. Clear buffers.
3. Compute `(tick, frame_offset)` pairs so MIDI is sample-accurate. Devices must use `frame_offset` directly and never convert it back to ticks.
4. Render tracks and device chains.
5. `mix_and_output` runs five passes:
   - Device pre-pass. Buses are skipped here.
   - Fader and pan.
   - Sends.
   - Hierarchical routing, at most 10 iterations. Buses run their devices and reapply pan here.
   - Master output and meters.

Pan is applied only in pass 2 and once per bus in pass 4, never while routing. The audio callback is the master clock.

### Channels and devices
- Channel types are `INSTRUMENT`, `AUDIO` and `BUS` (`Channel.ChannelType` in Godot). The master channel is identified by ID 1, not by a type.
- Channel IDs: 0 = none, 1 = master, 2–999 = user channels, 1000 and up = hardware outputs.
- Tracks (sequencing) are separate from channels (mixing) and point to one through `default_channel_id`.
- Each channel has an ordered chain of `Box<dyn AudioDevice>` (`audio/devices/mod.rs`). MIDI goes only to the first device.
- Built-in devices: `polysynth`, `delay`, `sfizz_device` (SFZ sampler), `spectrum_analyzer`. Godot discovers them at runtime through `/builtin/request` → `/builtin/info` → `/builtin/complete`.
- Devices go to sleep after about 3 s of silence and no MIDI (`DeviceSleepState`) so their processing is skipped.
- Parameters cross the OSC and IPC boundary as normalized 0.0–1.0 values.

### CLAP plugins
- `audio/ipc/` holds `ProcessManager`, the shared-memory ring buffers and the command protocol.
- `audio/devices/clap_host/subprocess_adapter/` implements `AudioDevice` for plugins.
- `plugin_host/` is the code that runs inside the subprocess.
- Plugins load on a background thread behind a `LoadingState`. While it is Loading or Failed, the audio thread passes audio through.

### Godot UI (`Godot/`)
- Autoloads: `Sonara` (global editor reference and JSON config in `~/.config/sonara/`, accessed via `get_config`/`set_config`/`save_config`), `AudioEngineOSC` (OSC transport), `AssetService` (browser asset providers) and `MidiManager` (MIDI input and virtual keyboard, routed to armed channels).
- `editor/Editor.gd` is the entry point. It wires up the self-contained systems: `arranger/`, `mixer/`, `clip_editor/`, `browser/` and `devices/`.
- The `data/` models (`Project`, `Track`, `Channel`, `Clip`, `DeviceInstance`, …) sync themselves with the engine. The UI calls a setter such as `channel.set_volume()`. The model updates its state, sends OSC, and emits a signal, and the UI updates from that signal. To add a synced property, add the signal and setter and wire it into `sync_to_engine()`. UI code never sends OSC directly.
- `components/GridHelper.gd` handles tempo, zoom, scroll and snapping, and converts between ticks and pixels. Views share one instance.
- Device visuals extend `devices/DeviceView.gd`. Subscribe to device data streams in `_on_view_shown` and unsubscribe in `_on_view_hidden`.

The full OSC address reference is in `OSC_PROTOCOL.md` (engine) and `PLUGIN_OSC_PROTOCOL.md`. When you add an OSC message, update the handler in `osc/server.rs`, the command in `audio/commands.rs`, and the doc.

## Subsystem references

`.cursor/rules/` has detailed, subsystem-specific notes. Read the matching file before working in that area. They may lag behind the code, so check claims against the source.

| Area | Rule file |
|---|---|
| Engine threads, pipeline, mixing, time-stretching | `engine-architecture.mdc`, `engine-audio-thread.mdc` |
| CLAP subprocess hosting, IPC, plugin GUIs | `engine-plugin-architecture.mdc` |
| SFZ sampler (sfizz) | `engine-sfz-sampler.mdc` |
| Logs and debugging | `engine-debugging.mdc` |
| Godot structure, clip/MIDI editor, GridHelper | `godot-architecture.mdc` |
| OSC sync pattern, device data streams, clip loading | `godot-osc.mdc` |
| Device views and parameter types | `godot-device-views.mdc` |
| Asset browser and providers | `godot-asset-system.mdc` |
| Config system | `godot-config-system.mdc` |
| Drag and drop | `godot-drag-and-drop.mdc` |

## Debugging

- Engine logs are written to `logs/` relative to the working directory, normally `Engine/logs/`. The files are `last_info.log`, `last_warn.log` (WARN and above) and `last_combined.log`. `/project/init` rotates them into `session_<timestamp>_*.log` files and keeps the 5 newest.
- WARN and ERROR messages are also forwarded to Godot over `/log`. Godot writes its own log to `Godot/logs/last.log`.
- When debugging, add plenty of logging and ask the user to reproduce the problem and report back.

## Code style

- Keep files under 600 lines, with a hard limit of 1000. Refactor when a file grows past that.
- Prefer object-oriented designs where behavior lives in structs and classes. Keep solutions simple and fail fast. If the code organization is confusing, stop and ask the user before reorganizing it.
- **Rust:** run `cargo fmt`. Put `///` doc comments on functions, methods and types.
- **GDScript:**
  - Leave two blank lines between functions.
  - Put a short `##` comment above every class and every function.
  - Expose behavior worth tweaking as configurable properties.
  - Write ternaries as `a if cond else b`.
- **Godot resources:** never hand-edit `.tscn`, `.tres` or `.uid` files. Use the godot-ai MCP tools (scene, node and resource tools) instead. Node paths are relative to the scene being edited.

## Project tracking

- `STATUS.md` is a scratchpad for the current complex investigation, with "Working" and "Not Working" sections.
- `TODO.md` is the checkbox backlog. Mark an item `[x]` only after the behavior is verified.
- Keep both files short.

## Library docs (Context7 IDs)

- clack (CLAP): `/prokopyl/clack`
- dasp: `/websites/rs_dasp_0_11_0_dasp`
- Signalsmith DSP: `/websites/rs_signalsmith-dsp_0_0_2_signalsmith_dsp`
- rubato: `/henquist/rubato`
- symphonia: `/pdeljanov/symphonia`
- Godot: `/websites/llm-docs_ams3_cdn_digitaloceanspaces_godot_4_2_2`. This covers 4.2 while the project runs 4.7, so check newer APIs against it.
