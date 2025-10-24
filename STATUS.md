# Project Status

## Current Focus
- ✅ **COMPLETED & DEBUGGED:** Fully bidirectional plugin parameter synchronization working end-to-end!
- Plugins notify host of parameter changes → Engine forwards via OSC → Godot UI updates automatically.
- Fixed infinite feedback loop bug - parameter sync now stable and performant.

## Working
- Plugin subprocess launches, shares audio/MIDI buffers, and exposes CLAP parameters via IPC.
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

## Not Working / Blocked
- None currently - bidirectional parameter sync is fully functional!

## Next Steps
- Consider preset management (save/load plugin states)
- Plugin scanning and discovery system
- MIDI routing to plugins
- Multi-output plugin support