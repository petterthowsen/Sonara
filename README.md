# Sonara

Linux-first DAW: Godot 4 for the UI, Rust for the audio engine, OSC between them.

## Prerequisites

- Linux (Ubuntu/Debian/Arch/Fedora)
- Rust 1.70+ ([rustup](https://rustup.rs/))
- CMake: `sudo apt install cmake`
- libsndfile headers (sfizz sampler): `sudo apt install libsndfile1-dev`
- PipeWire or ALSA
- Godot 4.5+

Optional: `liblo-tools` (`oscsend`) for OSC debugging.

## Run

```bash
# Audio engine (release; debug is too slow for realtime)
./run_engine.sh

# UI: open Godot/ in the Godot editor, or:
godot --path Godot
```

The engine initializes PipeWire/JACK/ALSA, starts OSC (listens on UDP 7000, talks back on 7001), and waits for Godot.

## Layout

```
Engine/     Rust audio engine, plugin host, OSC server
Godot/      Godot 4 UI
docs/       Research, design notes, open checklists
.cursor/rules/   Docs for implemented systems (agent-facing, keep current)
TODO.md     Backlog
STATUS.md   Notes on in-flight hard problems
```

## Dependencies
Third-party libraries the project relies on. Pin versions live in `Engine/Cargo.toml` and each addon’s `plugin.cfg`.
### Engine (Rust)
| Library | Role |
|--------|------|
| [cpal](https://github.com/RustAudio/cpal) | Audio I/O (PipeWire / JACK / ALSA) |
| [symphonia](https://github.com/pdeljanov/symphonia) | Decode import formats (AAC, MP3, OGG, FLAC, WAV, …) |
| [rubato](https://github.com/henquist/rubato) | Offline resampling during decode |
| [realfft](https://github.com/ejmahler/realfft) | Spectrum analyzer FFT |
| [sfizz](https://github.com/petterthowsen/rust-sfizz) (git) | Built-in SFZ sampler |
| [clack](https://github.com/prokopyl/clack) (`clack-host`, `clack-extensions`, git) | CLAP plugin hosting |
| [rosc](https://github.com/klingtnet/rosc) | OSC to/from Godot |
| [winit](https://github.com/rust-windowing/winit) + [raw-window-handle](https://github.com/rust-windowing/raw-window-handle) | Out-of-process CLAP plugin windows (Linux: `x11`) |
| [libloading](https://github.com/nagisa/rust_libloading) | Dynamic CLAP library load |
| [nix](https://github.com/nix-rust/nix) / `libc` | Shared-memory IPC for plugin subprocess |
Also declared in `Cargo.toml` but not referenced in engine source today: `fundsp`, `dasp`, `rustwav` (legacy / unused—safe cleanup candidates).
Supporting crates (logging, serde, crossbeam, bincode for waveform cache, etc.) are standard plumbing; see `Engine/Cargo.toml` for the full list.
### Godot UI
Vendored editor/runtime addons under `Godot/addons/`:
| Addon | Version | Role |
|-------|---------|------|
| **GodOSC** (`godOSC`) | 0.1 | OSC client/server in GDScript (engine comms) |
| **Godot AI** (`godot_ai`) | 4.0.4 | MCP server and editor AI tooling |
No other third-party Godot addons are checked into this repo; the rest of the UI is project code under `Godot/`.


## Development

```bash
cd Engine
cargo build --release --bins   # engine + plugin_host (needed for CLAP)
cargo test
```

Logs: `Engine/logs/engine.log`.

If the engine fails to start, install ALSA headers (`libasound2-dev` / `alsa-lib`) and a C toolchain.

## Conventions

- Middle C = C3 = MIDI 60
- 960 PPQ
- OSC is resource-based (`/channel/{id}/volume`, …). Catalog: `.cursor/rules/osc-protocol.mdc`
