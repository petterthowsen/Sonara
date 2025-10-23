# Overview

Sonara is a new Linux-first DAW built with Rust and Godot 4.5

## 🎯 Project Vision

Create a lightweight, real-time audio workstation that combines:
- **Godot Engine** for a beautiful, responsive UI
- **Rust** for high-performance audio processing
- **OSC** for low-latency communication

### Prerequisites

**System Requirements:**
- Linux (Ubuntu/Debian/Arch/Fedora)
- Rust 1.70+ (install via [rustup](https://rustup.rs/))
- PipeWire or ALSA audio system

**Optional:**
- `liblo-tools` for OSC testing: `sudo apt install liblo-tools`

### Running the Audio Engine

```bash
# Quick start
./run_engine.sh

# Or manually
cd Engine
cargo run --release
```

The engine will:
1. Initialize the audio backend (PipeWire/JACK/ALSA)
2. Start the OSC server and client
3. Wait for OSC commands

### Testing the Engine

```bash
cd Engine
./test_osc.sh
```

This will play a sequence of tones to verify the engine is working.

**Manual OSC Commands:**
```bash
# Start playback
oscsend localhost 7000 /sine/start

# Set frequency to 440 Hz (A4 note)
oscsend localhost 7000 /sine/frequency f 440.0

# Set amplitude to 50%
oscsend localhost 7000 /sine/amplitude f 0.5

# Stop playback
oscsend localhost 7000 /sine/stop
```

## 📁 Project Structure

```
daw/
├── Engine/                    # Rust audio engine
│   ├── src/
│   │   ├── audio/            # Audio processing modules
│   │   │   ├── engine.rs     # Audio engine core
│   │   ├── osc/              # OSC communication
│   │   │   └── server.rs     # OSC server
│   │   └── main.rs           # Entry point
│   ├── Cargo.toml            # Rust dependencies
│   ├── README.md             # Engine documentation
├── Godot/                    # Godot UI (Phase 2)
│   └── ...                   # Godot project files
└── README.md                 # This file
```

## 🎹 OSC Protocol

The audio engine listens for OSC messages on **UDP port 7000**.

## 🔧 Development

### Building

```bash
cd Engine

# Debug build
cargo build

# Release build (optimized)
cargo build --release
```

### Running Tests

```bash
cd Engine

# Run Rust tests
cargo test

# Test OSC interface
./test_osc.sh
```

### Code Structure

The engine uses a **lock-free architecture** for real-time safety:

- **Main Thread**: Handles OSC server and initialization
- **Audio Thread**: Runs the audio callback (real-time priority)
- **Communication**: Lock-free crossbeam channels

This ensures the audio thread never blocks, preventing glitches and dropouts.

### Troubleshooting

**Check engine logs:*
- The engine (./Engine/logs/engine.log) outputs detailed logs showing which audio backend it's using.

2. **Install system dependencies:**
   ```bash
   # Ubuntu/Debian
   sudo apt install libasound2-dev build-essential
   
   # Arch
   sudo pacman -S alsa-lib base-devel
   ```

## 🤝 Contributing

This is currently a personal project, but contributions and suggestions are welcome!

### Development Setup

1. **Clone the repository**
2. **Install Rust:** https://rustup.rs/
3. **Install system dependencies** (see Troubleshooting)
4. **Build and run:** `./run_engine.sh`

### Code Style

- **Rust**: Follow standard Rust conventions (`cargo fmt`)
- **Documentation**: Add docstrings to public APIs
- **Testing**: Add tests for new features


## 🙏 Acknowledgments

- **CPAL** - Cross-platform audio library
- **rosc** - OSC protocol implementation
- **Godot Engine** - UI framework
- **PipeWire** - Modern Linux audio server

**Last Updated**: 2025-10-21