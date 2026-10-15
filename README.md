![Sonara](Godot/assets/sonara/logo_image.png)

Sonara is a Digital Audio Workstation developed on and for Linux. It's a Rust audio engine and a Godot 4 UI.

The goal of sonara is to provide a seamless, frictionless UI that makes it fun to compose, arrange and mix music, while allowing high user customizability.

![Sonara arranger with MIDI clips, an automation lane and a CLAP reverb in the device lane](screenshot_01.png)

## At a Glance

- UI Inspired by Bitwig
- Midi editor inspired by FL Studio
- Customizable and Themeable
- Built-in support for SFZ
- Support for instrument note mapping: SFZ Keyswitches, Drum Machine, Sampler(Multisampler mode), and Instrument Layer mapping.
- VST3 + Clap plugins

## Features

- **Arranger**: MIDI and audio clips, folder tracks, group tracks, song markers, tempo changes, key changes.
- **Clip editor**: Intuitive and powerful piano-roll inspired by FL Studio.
- **Mixer**: instrument, audio and bus channels with sends, pan modes, metering and routing to hardware outputs.
- **Automation**: volume, pan, send and device-parameter lanes with linear and step curves.
- **Built-in devices**: PolySynth, a Sampler with Multisampler mode, a powerful Drum Machine (combined with Sampler Multisample mode, drum libraries can easily be set up), and a host of Note effects and audio effects like EQ, Reverb, Compressor, Delay etc.
- **CLAP and VST3 plugins**: Hosted in their own process, or shared by vendor - depending on preference.
- **Asset browser**: audio files, MIDI files, SFZ instruments and devices/plugins.
- **Undo/redo** for editing.
- **AI assistant** (optional): chat that can read and edit the project, via OpenRouter.
- **Theme system** Simple, customizable theme system.

## Current limitations

- Live Recording is not implemented yet.
- There is no support for hardware midi controllers yet.
- Only supports wav audio files.
- Themeing only supports dark mode currently.
- Linux only.

## Install

Download `sonara-<version>-linux-x86_64.tar.gz` from
[GitHub Releases](https://github.com/petterthowsen/Sonara/releases) or
[itch.io](https://thowsenmedia.itch.io/sonara). It runs on Debian 12, Ubuntu 24.04, Fedora 37,
Arch or newer (x86_64, glibc 2.36+) with PipeWire, JACK or ALSA.

```bash
sha256sum -c sonara-*.tar.gz.sha256   # optional
tar xzf sonara-*-linux-x86_64.tar.gz
cd sonara-*-linux-x86_64
./Sonara.x86_64                       # run it in place, or:
./install.sh                          # install for your user: app menu, .sonara files, `sonara` command
```

`install.sh` needs no root and installs into `~/.local`. Run it again from a newer archive to
upgrade. `~/.local/share/sonara/uninstall.sh` removes it.

Where Sonara keeps your files:

| What | Where |
|---|---|
| Projects, presets, note maps | `~/Documents/Sonara/{projects,presets,note_maps}` |
| Settings | `~/.config/sonara/` |
| Caches (safe to delete) | `~/.cache/sonara/` |
| Logs (Help > Open Logs Folder) | `~/.local/state/sonara/logs/` |

Uninstalling leaves all of these in place.

## Prerequisites

- Linux (Ubuntu/Debian/Arch/Fedora) with PipeWire, JACK or ALSA
- Rust 1.82+ ([rustup](https://rustup.rs/))
- A C/C++ toolchain, CMake and pkg-config (sfizz builds C++)
- ALSA and libsndfile headers: `sudo apt install libasound2-dev libsndfile1-dev`
  (Arch: `alsa-lib libsndfile`)
- PipeWire, D-Bus and libclang headers for the native PipeWire driver and realtime scheduling
  through rtkit: `sudo apt install libpipewire-0.3-dev libspa-0.2-dev libdbus-1-dev libclang-dev`
  (Arch: `pipewire dbus clang`)
- X11 headers for plugin GUI windows: `sudo apt install libx11-dev libxext-dev` (Arch: `libx11 libxext`)
- Godot 4.7

Optional: `liblo-tools` (`oscsend`) for OSC debugging, and `libxml2-utils` (`xmllint`) to
check DAWproject exports against the schema in tests (Arch: `libxml2`).

## Run from source

```bash
cd Engine && cargo build --release --bins && cd ..   # engine + plugin_host

# UI: open Godot/ in the Godot editor, or:
godot --path Godot
```

The UI starts `Engine/target/release/engine` itself when no engine is running, and stops it when
you quit. To run the engine on its own (to watch its output, or debug it), start
`./run_engine.sh` first; the UI then attaches to it and leaves it running. The engine opens the
audio device and listens for OSC on UDP 7000 (replies on 7001). Choose the output device, sample
rate and buffer size in the UI's settings.

## Layout

```
Engine/            Rust audio engine, plugin host, OSC server
Godot/             Godot 4 UI
docs/subsystems/   Docs for implemented systems (keep current)
docs/adr/          Architecture decision records
docs/specs/        Feature specs (requirements, design, tasks)
docs/              Plans, research, design notes
AGENTS.md          Guide for AI coding agents (commands, architecture, conventions)
CONTEXT.md         Domain glossary
TODO.md            Backlog
STATUS.md          Notes on in-flight hard problems
```

## Development

```bash
cd Engine
cargo build --release --bins   # engine + plugin_host (both needed for CLAP)
cargo test
cargo fmt

Godot/tests/run_all.sh         # Godot tests (headless, parallel; optional name filters, -jN), from the repo root
```

`Engine/test_osc.sh`, `test_plugin_osc.sh` and `test_sfizz.sh` are OSC smoke tests against a
running engine. They make sound.

Logs: `~/.local/state/sonara/logs/engine/last_{info,warn,combined}.log` (rotated per session) and `~/.local/state/sonara/logs/ui/last.log`. In the app: Help > Open Logs Folder.

### Releasing

See [docs/releasing.md](docs/releasing.md): bump `VERSION`, tag `v<version>`, push. CI builds the
archive and publishes the GitHub Release (and the itch.io build). Build the archive locally with
`scripts/package_linux.sh`.

See `AGENTS.md` for the architecture overview and `docs/subsystems/` for details.

## Conventions

- Middle C = C3 = MIDI 60
- 960 PPQ
- OSC is resource-based (`/channel/{id}/volume`, …). Catalog: `docs/subsystems/osc-protocol.md`

## Dependencies

Third-party libraries the project relies on. Versions are pinned in `Engine/Cargo.toml` and each
addon's `plugin.cfg`.

### Engine (Rust)

| Library | Role |
|--------|------|
| [cpal](https://github.com/RustAudio/cpal) | Audio output (PipeWire / ALSA) |
| [symphonia](https://github.com/pdeljanov/symphonia) | Decode import formats (AAC, MP3, OGG, FLAC, WAV, …) |
| [rubato](https://github.com/henquist/rubato) | Offline resampling during decode |
| [realfft](https://github.com/ejmahler/realfft) | Spectrum analyzer FFT |
| [sfizz](https://github.com/petterthowsen/rust-sfizz) (git) | Built-in SFZ sampler |
| [clack](https://github.com/prokopyl/clack) (`clack-host`, `clack-extensions`, git) | CLAP plugin hosting |
| [rosc](https://github.com/klingtnet/rosc) | OSC to/from Godot |
| [winit](https://github.com/rust-windowing/winit) + [raw-window-handle](https://github.com/rust-windowing/raw-window-handle) | Plugin GUI host windows (Linux: `x11`) |
| [libloading](https://github.com/nagisa/rust_libloading) | Dynamic CLAP library load |
| [nix](https://github.com/nix-rust/nix) / `libc` | Plugin IPC: Unix socket, shared memory, futex |
| [bincode](https://github.com/bincode-org/bincode) | Plugin IPC wire format and waveform cache |

Supporting crates (logging, serde, crossbeam, etc.) are standard plumbing; see `Engine/Cargo.toml`
for the full list.

### Godot UI

Vendored addons under `Godot/addons/`:

| Addon | Version | License | Role |
|-------|---------|---------|------|
| **GodOSC** (`godOSC`) | 0.1 | CC0 | OSC client/server in GDScript (engine comms) |
| **Godot AI** (`godot_ai`) | 4.0.4 | MIT | MCP server and editor AI tooling |

## License

Sonara is licensed under the [GNU General Public License v3.0 or later](LICENSE).
Third-party notices for everything it bundles or links are in
[THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

Copyright © 2026 the Sonara contributors
