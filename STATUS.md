# Project Status

## Current Focus
- ✅ **COMPLETED:** Fixed critical IO Safety violation bug in plugin shutdown!
- ✅ **COMPLETED & DEBUGGED:** Fully bidirectional plugin parameter synchronization working end-to-end!
- Plugins notify host of parameter changes → Engine forwards via OSC → Godot UI updates automatically.
- Plugin subprocess shutdown now safe and clean - no more crashes on project clear.

## Working
- Plugin subprocess launches, shares audio/MIDI buffers, and exposes CLAP parameters via IPC.
- **Plugin subprocess shutdown is now safe and stable** - no IO safety violations or crashes.
- **Full bidirectional parameter sync:**
  - **Godot → Plugin:** UI changes sent via OSC → Engine → Subprocess → Plugin (working)
  - **Plugin → Godot:** GUI changes → Output events → Subprocess → Engine → OSC → Godot UI (✅ NOW WORKING!)
- Plugin GUI parameter changes automatically update Godot UI in real-time.
- Generic IPC infrastructure (`audio/ipc/`) reusable for VST3, LV2, or other plugin formats.
- subprocess_adapter split into focused modules (lifecycle, parameter, gui) for better maintainability.

## Recent Work: Plugin → Host Parameter Sync (Completed!)

**The Challenge:**
- Subprocess was detecting parameter changes and sending responses, but main engine never read them
- IPC was only checked when expecting a command response (request/response pattern)
- Plugin GUI changes are **unsolicited messages** that arrive asynchronously

**The Solution:**
1. **Subprocess side** (`plugin_host.rs`):
   - Added periodic `params.flush()` in main event loop to collect output events from plugin GUI
   - Events processed and sent as `ParameterValueChanged` responses via stdout
   - Works whether audio is playing or not

2. **Engine side** (`mixing.rs`, `subprocess_adapter/mod.rs`, `process_manager.rs`):
   - Added `poll_parameter_changes()` to subprocess adapter (non-blocking)
   - Added `try_recv_response()` for non-blocking IPC reads (100μs timeout)
   - Called in audio callback alongside existing in-process plugin polling
   - Sends `PluginParameterValueChanged` status → OSC

3. **Godot side** (`DeviceInstance.gd`, `AudioEngineOSC.gd`, `CompactParameterControl.gd`):
   - **Wildcard listener** support: matches `/channel/{ch}/device/{dev}/param/*/value` patterns
   - Single listener per device captures all parameter changes dynamically
   - **Server as single source of truth** prevents infinite loops:
     - `set_parameter_normalized()`: Sends to engine, does NOT emit signal
     - `_on_parameter_value_received()`: Receives OSC (including echoes), emits signal
     - `CompactParameterControl`: Guards against redundant slider updates
   - All UI updates triggered by OSC responses, ensuring consistent state

**Files modified:**
- `Engine/src/audio/mixing.rs` - Poll subprocess adapters for parameter changes
- `Engine/src/audio/devices/clap_host/subprocess_adapter/mod.rs` - Added `poll_parameter_changes()`
- `Engine/src/audio/ipc/process_manager.rs` - Added `try_recv_response()` for non-blocking reads
- `Engine/src/bin/plugin_host.rs` - Periodic `params.flush()` to collect GUI events, extensive debug logging
- `Engine/src/audio/commands.rs` - Added `is_param_change()` helper method
- `Engine/src/osc/server.rs` - Enhanced logging for parameter change OSC messages
- `Godot/data/DeviceInstance.gd` - Server as source of truth, wildcard listener
- `Godot/AudioEngineOSC.gd` - Wildcard pattern matching support
- `Godot/components/device/compact/CompactParameterControl.gd` - Redundant update guard
- `Godot/device_lane/DevicePanel.gd` - Removed redundant channel listener
- `Godot/data/Channel.gd` - Removed manual parameter listener registration

**Result:** Moving sliders in plugin GUI now instantly updates Godot UI! 🎉

## Bug Fix: Infinite Feedback Loop (Fixed!)

**The Problem:**
- Plugin GUI parameter changes created infinite loops
- Values would continuously bounce between Engine and Godot
- System became unresponsive when moving plugin GUI controls

**Root Cause Analysis:**
1. **Channel signal handler was re-sending to engine:**
   - `Channel._on_device_parameter_changed()` was listening to `DeviceInstance.parameter_changed`
   - It sent ALL parameter changes back to engine via OSC (line 441)
   - This included echoes FROM the engine, creating the loop:
     - Plugin GUI → Engine → DeviceInstance → Channel → **sends back to Engine** → repeat

2. **Secondary issue - slider range updates:**
   - `CompactParameterControl._update_ui()` was setting `min_value`/`max_value` on every update
   - Scene had wrong initial values (100.0 instead of 1.0)
   - Repeatedly triggering property setters caused unnecessary overhead

**The Fix:**
1. **Removed OSC send from Channel callback:**
   - `Channel._on_device_parameter_changed()` now ONLY relays signal for UI notifications
   - DeviceInstance is the single source of truth - it handles sending via `set_parameter_normalized()`
   - Channel just passes the signal along, doesn't communicate with engine

2. **Optimized slider initialization:**
   - Set `min_value`/`max_value` once in `_ready()` instead of every update
   - Fixed scene file to have correct initial values (0.0-1.0 range)
   - Added `queue_redraw()` to `HSlider.set_value_no_signal()` for proper visual updates

**Files modified:**
- `Godot/data/Channel.gd` - Removed OSC send from parameter callback (THE KEY FIX)
- `Godot/components/device/compact/CompactParameterControl.gd` - Slider range set once in _ready()
- `Godot/components/device/compact/CompactParameterControl.tscn` - Correct initial slider values
- `Godot/components/HSlider.gd` - Added queue_redraw() to set_value_no_signal()

**Result:** Parameter sync now works smoothly with no feedback loops! Plugin GUI and Godot UI stay perfectly in sync.

## Recent Work: Plugin Shutdown IO Safety Violation (Fixed!)

**The Problem:**
- Engine was crashing with `fatal runtime error: IO Safety violation: owned file descriptor already closed` during plugin shutdown
- Happened when clearing projects or shutting down plugins
- Made plugin system unstable and caused data loss risk

**Root Cause Analysis:**
1. **Critical bug - unsafe `std::mem::zeroed::<Child>()`:**
   - `process_manager.rs` was using `std::mem::zeroed()` to move `Child` struct during shutdown
   - This created invalid `Child` with zeroed file descriptors (FD 0 or other invalid values)
   - When the zeroed `Child` dropped, Rust tried to close these invalid FDs
   - Triggered: "IO Safety violation: owned file descriptor already closed"

2. **Secondary issue - Unix socket FD leak:**
   - Subprocess received shared memory FD via Unix socket (FD 3)
   - FD 3 was never explicitly closed after receiving the shared memory FD
   - Left dangling FD that could cause issues on subprocess exit

**The Fix:**
1. **Changed `PluginProcess.child` to `Option<Child>`:**
   - Removed unsafe `std::mem::zeroed()` usage entirely
   - Used `Option::take()` for safe ownership transfer during shutdown
   - Updated `Drop` impl to safely check and kill running processes

2. **Close Unix socket FD after use:**
   - Added explicit `libc::close(unix_socket_fd)` after receiving shared memory FD
   - Prevents FD leaks and ensures clean subprocess exit

**Files modified:**
- `Engine/src/audio/ipc/process_manager.rs`:
  - Changed `child: Child` to `child: Option<Child>` in `PluginProcess` struct
  - Rewrote `shutdown()` to use `Option::take()` instead of `std::mem::zeroed()`
  - Updated `is_alive()` to handle `Option<Child>`
  - Improved `Drop` impl with proper exit status checking and zombie reaping
- `Engine/src/bin/plugin_host.rs`:
  - Added explicit close of Unix socket FD 3 after receiving shared memory FD
  - Handles close in both success and error paths

**Result:** Plugin shutdown is now rock-solid - no crashes, no IO safety violations! 🎉

## Not Working / Blocked
- None currently - plugin system is stable and functional!

## Next Steps
- Consider preset management (save/load plugin states)
- Plugin scanning and discovery system
- MIDI routing to plugins
- Multi-output plugin support