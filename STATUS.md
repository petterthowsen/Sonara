# Project Status

## Current Focus
- Completed major refactoring: extracted generic IPC infrastructure and split subprocess_adapter.
- Plugin subprocess system fully functional with clean architecture.

## Working
- Plugin subprocess launches, shares audio/MIDI buffers, and exposes CLAP parameters via IPC.
- `SetParameter` calls denormalize and flush immediately; Godot UI updates reflect new values.
- Generic IPC infrastructure (`audio/ipc/`) now reusable for VST3, LV2, or other plugin formats.
- subprocess_adapter split into focused modules (lifecycle, parameter, gui) for better maintainability.

## Recent Refactoring
**Extracted generic IPC layer:**
- Moved `process_manager`, `shared_memory`, `platform_shm`, `protocol` → `Engine/src/audio/ipc/`
- These components are now plugin-format agnostic and reusable

**Split subprocess_adapter (632 → 409 lines + 3 submodules):**
- `subprocess_adapter/lifecycle.rs` - Async plugin loading and initialization
- `subprocess_adapter/parameter.rs` - Parameter queries and caching
- `subprocess_adapter/gui.rs` - GUI window management
- `subprocess_adapter/mod.rs` - Core AudioDevice implementation

## Recently Touched Files
- `Engine/src/audio/ipc/*` (new directory)
- `Engine/src/audio/devices/clap_host/subprocess_adapter/*`
- `Engine/src/bin/plugin_host.rs`
- `Engine/src/audio/commands.rs`
