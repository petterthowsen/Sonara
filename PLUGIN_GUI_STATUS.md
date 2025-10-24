# CLAP Plugin GUI Status

## Current Status: Partial Implementation ⚠️

### ✅ What Works
- **Plugin loading and initialization** - CLAP plugins load successfully
- **Audio processing** - Plugins process audio correctly
- **Parameter control** - All parameters accessible and controllable from Godot UI
- **State save/load** - Plugin state serialization works
- **Host extensions** - Proper support for Log, GUI, Timer, Params, State, Audio Ports, Note Ports
- **GUI creation** - Plugin windows are created in X11
- **Threading architecture** - Proper separation of main thread (GUI/params) and audio thread

### ❌ What Doesn't Work
- **GUI visibility** - Windows are created but remain invisible
- **GUI interaction** - No mouse/keyboard input (window not displayed)

## Root Cause

CLAP floating windows (X11 on Linux) require **continuous event loop processing** on the main thread:

```rust
// What clack-host example does:
loop {
    for message in receiver {
        instance.call_on_main_thread_callback(); // Keep processing!
    }
}
```

**Sonara's architecture conflict**:
- Main thread must handle OSC messages (can't block in plugin event loop)
- `PluginInstance` is not `Send` (can't move to worker thread)  
- Audio thread has real-time constraints (can't process GUI callbacks)

## Evidence

X11 window is created but invisible:
```bash
$ xwininfo -root -tree | grep Dragonfly
0x8400004 (has no name): ("Dragonfly-Dragonfly Hall Reverb" ...) 1016x381+500+367
```

Logs confirm successful creation:
```
✅ Plugin GUI opened for: Dragonfly Hall Reverb
⚠️  GUI may become unresponsive without continuous callback processing
```

## Solution: Separate Process Per Plugin

This is the industry-standard approach used by all major DAWs:

### Architecture
```
┌─────────────────┐         ┌──────────────────┐
│  Sonara Engine  │◄───────►│  Plugin Process  │
│  (Main Process) │   IPC   │  (per plugin)    │
└─────────────────┘         └──────────────────┘
                                     │
                                     ▼
                            ┌────────────────┐
                            │  Plugin GUI    │
                            │  (X11 Window)  │
                            └────────────────┘
```

### Benefits
1. **Crash isolation** - Plugin crash doesn't kill entire DAW
2. **Event loop isolation** - Each plugin can block in its own event loop
3. **Resource management** - Can kill/restart individual plugins
4. **Sandboxing** - Security isolation between plugins and engine

### Implementation Plan

**Phase 1: IPC Foundation**
- Design message protocol (audio samples, MIDI, parameters, commands)
- Choose IPC mechanism (Unix sockets, shared memory, both)
- Implement serialization/deserialization

**Phase 2: Process Management**
- Fork/spawn plugin host processes
- Lifecycle management (start, stop, restart, watchdog)
- Handle process crashes gracefully

**Phase 3: Audio Routing**
- Shared memory ring buffers for audio
- Low-latency audio transfer
- Handle buffer underruns

**Phase 4: GUI Integration**
- Each plugin process owns its GUI thread
- Window parenting/embedding (optional)
- Focus management

**Phase 5: State Management**
- Serialize plugin state across process boundaries
- Handle plugin process restart without audio glitches

## Workarounds (Interim)

### Option A: Embedded GUI (Future)
Use CLAP embedded GUI mode where Godot provides the parent window:
- Godot creates window
- Plugin renders into it
- Godot handles event loop

### Option B: External GUI Bridge
Use a helper process per plugin:
```
Engine -> GUI Bridge Process -> Plugin GUI
```
The bridge process handles the event loop.

### Option C: Accept Limitation
Document that floating window GUIs don't work yet.
Use parameter controls in Godot UI instead.

## Current Recommendation

**Option C** for now, then implement **Separate Process Per Plugin** properly.

This avoids half-measures and delivers the right architecture:
- Crash protection
- Proper GUI support
- Industry-standard approach
- Better resource management

## Files Modified

### Implemented
- `Engine/Cargo.toml` - Added CLAP extensions (gui, log, timer, params, state, audio-ports, note-ports)
- `Engine/src/audio/devices/clap_host/adapter.rs` - GUI methods (open_gui, close_gui, has_gui)
- `Engine/src/audio/devices/clap_host/host_impl.rs` - Host extension implementations
- `Engine/src/audio/commands.rs` - OpenPluginGui/ClosePluginGui commands
- `Engine/src/osc/server.rs` - GUI control OSC endpoints
- `OSC_PROTOCOL.md` - Documented GUI control protocol
- `Godot/data/Device.gd` - has_gui() method
- `Godot/data/DeviceInstance.gd` - open_gui(), close_gui() methods
- `Godot/components/device/compact/CompactDevicePanel.gd` - Double-click to open GUI

### Next Steps
- Design IPC protocol
- Implement plugin host subprocess
- Test with single plugin
- Add crash recovery
- Update documentation

