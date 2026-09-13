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
