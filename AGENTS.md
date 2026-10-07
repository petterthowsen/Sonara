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
godot --headless --path Godot -s path/to/script.gd -- --test  # script path relative to Godot/
Godot/tests/run_all.sh                           # run every test_*.gd script (3 in parallel) and report a summary
Godot/tests/run_all.sh clip_drag pan             # only scripts whose path contains one of these words
Godot/tests/run_all.sh -j1                       # serial (or -jN / TEST_JOBS=N); each script costs ~2.7 s of Godot startup
```

- Test scripts (`test_*.gd`, found in `Godot/tests/` and `Godot/ai/tests/`) extend `TestBase` (`Godot/tests/TestBase.gd`), which supplies `_assert()` and the pass/fail exit code. The `-- --test` after the script path is required: autoloads check `Utils.is_test_mode()` and skip side effects (real config I/O, asset scans, physical MIDI enumeration, OSC sockets) that don't work headless or in a shared dev environment.

## Architecture

### Engine threads (`Engine/src/`)
- **Main thread** (`main.rs`, `osc/server.rs`): runs the OSC server. It turns OSC messages into `AudioCommand`s (`audio/commands.rs`) and forwards `EngineStatus` back to Godot.
- **Command thread** (`audio/command_worker.rs`): applies commands to the `EngineState` it shares with the audio callback. It holds the state lock only briefly. Slow work (plugin scans, creating and dropping devices, plugin IPC) runs with the lock released.
- **Audio callback** (`audio/engine.rs`, `audio/processing.rs`, `audio/mixing.rs`): real-time. It takes the state lock with a bounded `try_lock` and outputs silence if the lock is still busy. It sends statuses and meters at about 20 Hz.
- **WindowManager thread** (`window_manager.rs`, winit): owns the host windows for plugin GUIs.
- **AudioFileService** (`audio/io/`): worker pool for decoding (symphonia), resampling (rubato) and waveform caches. The audio thread only ever receives finished PCM. Stale `req_id` completions must be ignored.
- Commands (main → command thread) and statuses (back to main) travel over crossbeam channels.

### Audio thread contract (critical)
Code on the audio callback must never allocate, block, do I/O, or wait on a lock. Use `try_lock()` and skip the work (output silence or pass-through) when the lock isn't available. Preallocate every buffer at init time (`audio/render_scratch.rs`). Log with `info!`/`warn!`/`error!`, never `println!`. Anything the command thread does while holding the state lock must also be fast.

### Callback and mixing
1. Lock the engine state.
2. Clear buffers.
3. Compute `(tick, frame_offset)` pairs so MIDI is sample-accurate. Devices must use `frame_offset` directly and never convert it back to ticks.
4. Render tracks and device chains.
5. `mix_and_output` runs four passes:
   - Device pre-pass. Route targets (buses, master) are skipped here.
   - Fader and pan.
   - Routing and sends in dependency order. Each channel finishes once, after every channel routing or sending into it. Route targets then run their devices (even with no input, so tails ring) and pan.
   - Master output. The callback computes meters afterward.

Pan is applied only in pass 2 and once per route target in pass 3, never while routing. The audio callback is the master clock.

### Channels and devices
- Channel types are `INSTRUMENT`, `AUDIO` and `BUS` (`Channel.ChannelType` in Godot). The master channel is identified by ID 1, not by a type.
- Channel IDs: 0 = none, 1 = master, 2–999 = user channels, 1000 and up = hardware outputs.
- Tracks (sequencing) are separate from channels (mixing) and point to one through `default_channel_id`.
- Each channel has an ordered chain of `Box<dyn AudioDevice>` (`audio/devices/mod.rs`). MIDI goes only to the first device.
- Built-in devices: `polysynth`, `sfizz_device` (SFZ sampler), `spectrum_analyzer`, plus the spec 012 effects `delay`, `eq`, `compressor`, `filter`, `chorus`, `phaser` and `reverb`, and the spec 017 `utility` (all registered in `factory.rs` `EFFECT_IDS` / `create_effect`, checked by `effect_conformance.rs`). Godot discovers them at runtime through `/builtin/request` → `/builtin/info` → `/builtin/complete`.
- Drum instruments (spec 013: `kick`, `snare`, `hat`, `clap`) come from `DRUM_IDS` / `create_drum` and are checked by `drum_conformance.rs`. They share `audio/devices/drums/` — a generic `DrumHost` over a mono `DrumVoice` impl, with sample-accurate triggers, a two-slot 3 ms retrigger crossfade, the shared global parameters (IDs 90–92) and a 100 ms instrument sleep — plus the drum blocks in `audio/dsp/` (one-shot/burst envelopes, `sweep_osc`, `noise`, `saturate`). Drum Machine pads carry choke targets (sibling pad ids in Godot, a `u128` note mask in the engine): a note-on chokes its target pads through `AudioDevice::choke` (ADR 0015, superseding 0012), which `DrumHost` implements as a 3 ms fade.
- Devices go to sleep after about 3 s of silence and no MIDI (`DeviceSleepState`) so their processing is skipped.
- Parameters cross the OSC and IPC boundary as normalized 0.0–1.0 values.

### CLAP plugins
- `audio/ipc/` holds `ProcessManager`, the shared-memory ring buffers and the command protocol.
- `audio/devices/clap_host/subprocess_adapter/` implements `AudioDevice` for plugins.
- `plugin_host/` is the code that runs inside the subprocess.
- Plugins load on a background thread behind an atomic `PluginLoad` state. While it is Loading, Failed or Crashed, the audio thread passes audio through. A crashed plugin can be reloaded with its last saved state.

### Godot UI (`Godot/`)
- Autoloads: `Sonara` (global editor reference and JSON config in `~/.config/sonara/`, accessed via `get_config`/`set_config`/`save_config`), `AudioEngineOSC` (OSC transport), `AudioConfig` (output device, sample rate and buffer size: engine device list, running config, applies the settings live), `AssetService` (browser asset providers) `MidiManager` (MIDI input and virtual keyboard, routed to armed channels) and `Hotkeys` (action registry with rebindable chords, plus the help-bar context and interaction states) and `UiTheme` (builds the theme from the `appearance/theme/*` settings and merges it into the project theme; `Sonara_Theme.tres` is generated).
- `editor/Editor.gd` is the entry point. It wires up the self-contained systems: `arranger/`, `mixer/`, `clip_editor/`, `browser/` and `devices/`.
- The `data/` models (`Project`, `Track`, `Channel`, `Clip`, `DeviceInstance`, …) sync themselves with the engine. The UI calls a setter such as `channel.set_volume()`. The model updates its state, sends OSC, and emits a signal, and the UI updates from that signal. To add a synced property, add the signal and setter and wire it into `sync_to_engine()`. UI code never sends OSC directly.
- `components/GridHelper.gd` handles tempo, zoom, scroll and snapping, and converts between ticks and pixels. Views share one instance.
- Device visuals extend `devices/DeviceView.gd`. Subscribe to device data streams in `_on_view_shown` and unsubscribe in `_on_view_hidden`.

The full OSC address reference is in `docs/subsystems/osc-protocol.md`. When you add an OSC message, update the handler in `osc/server.rs`, the command in `audio/commands.rs`, and the doc.

## Subsystem references

`docs/subsystems/` has detailed, subsystem-specific notes. Read the matching file before working in that area. They may lag behind the code, so check claims against the source.

| Area | Rule file |
|---|---|
| Engine threads, pipeline, mixing, time-stretching | `engine-architecture.md`, `engine-audio-thread.md` |
| CLAP subprocess hosting, IPC, plugin GUIs | `engine-plugin-architecture.md` |
| SFZ sampler (sfizz) | `engine-sfz-sampler.md` |
| Logs and debugging | `engine-debugging.md` |
| Godot structure, clip/MIDI editor, GridHelper | `godot-architecture.md` |
| OSC sync pattern, device data streams, clip loading | `godot-osc.md` |
| Device views and parameter types | `godot-device-views.md` |
| UI components: design principles, knobs, sliders, meters, tooltips | `godot-ui-components.md` |
| Asset browser and providers | `godot-asset-system.md` |
| Config system | `godot-config-system.md` |
| DAWproject import and export, transfer report | `dawproject.md` |
| Drag and drop | `godot-drag-and-drop.md` |

## Debugging

- Engine logs are written to `logs/` relative to the working directory, normally `Engine/logs/`. The files are `last_info.log`, `last_warn.log` (WARN and above) and `last_combined.log`. `/project/init` rotates them into `session_<timestamp>_*.log` files and keeps the 5 newest.
- WARN and ERROR messages are also forwarded to Godot over `/log`. Godot writes its own log to `Godot/logs/last.log`.
- When debugging, add plenty of logging and ask the user to reproduce the problem and report back.

## Domain docs and issues

- `CONTEXT.md` is the domain glossary and `docs/adr/` holds the decision records. Read the ADRs that touch the area you're working in. Use the glossary's terms in issues, proposals and test names. If your change contradicts an ADR, say so explicitly instead of silently overriding it.
- Issues live in GitHub Issues (petterthowsen/Sonara); use the `gh` CLI (`gh issue list/view/create/comment/edit/close`).
- Triage labels: `needs-triage`, `needs-info`, `ready-for-agent` (fully specified, ready for an AFK agent), `ready-for-human`, `wontfix`. Area labels: `engine`, `godot`, `device`, `builtins`, `arranger`, `editor`, `mixer`, `ai`, `export`.

## Project tracking

- `STATUS.md` is a scratchpad for the current complex investigation, with "Working" and "Not Working" sections.
- `TODO.md` is the checkbox backlog. Mark an item `[x?]` after implementing a fix, and `[x]` when verified.

## Library docs (Context7 IDs)

- clack (CLAP): `/prokopyl/clack`
- dasp: `/websites/rs_dasp_0_11_0_dasp`
- Signalsmith DSP: `/websites/rs_signalsmith-dsp_0_0_2_signalsmith_dsp`
- rubato: `/henquist/rubato`
- symphonia: `/pdeljanov/symphonia`