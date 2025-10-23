# CLAP Plugin OSC Protocol

This document describes the OSC protocol for CLAP plugin management in Sonara.

## Overview

The plugin system uses bidirectional OSC communication:
- **Godot → Rust (port 7000)**: Commands to scan, instantiate, and control plugins
- **Rust → Godot (port 7001)**: Status updates and plugin metadata

All messages follow the resource-based path pattern established in the main OSC protocol.

---

## Plugin Discovery

### Scan for Plugins

**Godot → Rust:**
```
/plugin/scan
```

**Description:** Triggers a scan of standard CLAP plugin directories.

**Standard Paths (Linux):**
- `/usr/lib/clap`
- `/usr/local/lib/clap`
- `~/.clap`

**Rust → Godot (for each discovered plugin):**
```
/plugin/info [id, name, vendor, version, category, description]
  id:          string (unique plugin ID, e.g., "com.u-he.diva")
  name:        string (plugin name, e.g., "Diva")
  vendor:      string (manufacturer/author)
  version:     string (plugin version)
  category:    string ("instrument", "effect", or "utility")
  description: string (plugin description, may be empty)
```

**Rust → Godot (scan completion):**
```
/plugin/scan_complete [count]
  count: int (total number of plugins found)
```

**Notes:**
- Plugins are cached in the engine's `PluginScanner`
- `/plugin/info` messages are sent for each discovered plugin before `/plugin/scan_complete`
- Godot receives plugin metadata and can display them in the browser
- Scan happens on audio thread but doesn't block processing

---

## Plugin Instantiation

### Add Plugin to Channel (Unified with Built-In Devices)

**Godot → Rust:**
```
/channel/{channel_id}/add_device [plugin_id, position]
  plugin_id:  string (plugin ID from discovery)
  position:   int    (device chain position, -1 = append to end)
```

**Example:**
```
/channel/2/add_device ["michaelwillis.dragonfly.room", -1]
```

**Description:** Creates a new instance of the specified plugin and adds it to the channel's device chain. This uses the **same command** as built-in devices for consistency.

**Notes:**
- Plugin must have been discovered via `/plugin/scan` first
- Position 0 = first in chain, -1 = append to end
- Each call creates a new instance (supports multiple instances of same plugin)
- Works for both CLAP plugins and built-in devices (`sonara.builtin.oscillator`, `sonara.builtin.delay`)

---

## Plugin Parameters

### Query Plugin Parameters

**Godot → Rust:**
```
/plugin/get_parameters [channel_id, device_position]
  channel_id:      int (channel ID)
  device_position: int (index in device chain, 0-based)
```

**Rust → Godot (parameter count):**
```
/plugin/param/count [channel_id, device_position, count]
  channel_id:      int (channel ID)
  device_position: int (device position)
  count:           int (number of parameters)
```

**Rust → Godot (for each parameter):**
```
/plugin/param/info [channel_id, device_position, param_id, name, min, max, default]
  channel_id:      int    (channel ID)
  device_position: int    (device position)
  param_id:        int    (parameter ID, sequential 0-based)
  name:            string (parameter name, e.g., "Cutoff")
  min:             float  (minimum value)
  max:             float  (maximum value)
  default:         float  (default value)
```

### Set Plugin Parameter

**Godot → Rust:**
```
/channel/{channel_id}/device/{device_position}/param/{param_id} [value]
  value: float (normalized 0.0-1.0)
```

**Example:**
```
/channel/2/device/0/param/5 [0.75]
```

**Description:** Sets a plugin parameter value. Uses the existing device parameter path.

**Notes:**
- Parameters are always normalized to 0.0-1.0 range
- Plugin adapter handles conversion to native parameter range
- Real-time safe (no allocations in audio thread)

---

## Plugin State Management

### Save Plugin State

**Godot → Rust:**
```
/plugin/save_state [channel_id, device_position]
  channel_id:      int (channel ID)
  device_position: int (device position)
```

**Rust → Godot:**
```
/plugin/state/saved [channel_id, device_position, state_base64]
  channel_id:      int    (channel ID)
  device_position: int    (device position)
  state_base64:    string (base64-encoded binary state blob)
```

**Description:** Saves the complete plugin state (parameters, internal state, presets) as a base64-encoded blob.

**Notes:**
- Uses CLAP state extension (`save_state()`)
- State is opaque to Sonara (plugin-specific format)
- Store in project file for session recall

### Load Plugin State

**Godot → Rust:**
```
/plugin/load_state [channel_id, device_position, state_base64]
  channel_id:      int    (channel ID)
  device_position: int    (device position)
  state_base64:    string (base64-encoded state blob from save)
```

**Description:** Restores plugin state from a previously saved blob.

**Notes:**
- Must be called on same plugin type that generated the state
- No validation of state format (plugin's responsibility)
- Real-time safe (state loaded on main thread, then activated)

---

## Device Management

Plugins use the existing device management protocol:

### Remove Plugin from Channel

**Godot → Rust:**
```
/channel/{channel_id}/remove_device [position]
  position: int (device position to remove)
```

### Clear All Devices from Channel

**Godot → Rust:**
```
/channel/{channel_id}/clear_devices
```

---

## Example Workflow

### 1. Project Initialization
```
/project/init [120.0, 4, 4, 960, 48000]
/channel/1/create ["Master"]
/channel/2/create ["Synth"]
```

### 2. Scan for Plugins
```
→ /plugin/scan
← /plugin/info ["michaelwillis.dragonfly.room", "Dragonfly Room", "Michael Willis", "1.0.0", "effect", "Reverb effect"]
← /plugin/info ["surge-synth-team.surge-xt", "Surge XT", "Surge Synth Team", "1.3.0", "instrument", "Hybrid synthesizer"]
... (195 more /plugin/info messages)
← /plugin/scan_complete [197]
```

### 3. Load Plugin (same command as built-in devices!)
```
→ /channel/2/add_device ["michaelwillis.dragonfly.room", -1]
```

### 4. Query Parameters
```
→ /plugin/get_parameters [2, 0]
← /plugin/param/count [2, 0, 12]
← /plugin/param/info [2, 0, 0, "Dry Level", 0.0, 1.0, 1.0]
← /plugin/param/info [2, 0, 1, "Early Level", 0.0, 1.0, 0.5]
... (10 more parameters)
```

### 5. Control Plugin (same as built-in devices!)
```
→ /channel/2/device/0/param/0 [0.75]  # Set parameter to 75%
```

### 6. Save Session
```
→ /plugin/state/save [2, 0]
← /plugin/state/saved [2, 0, "QklOQVJZU1RBVEUuLi4="]
(Store in project JSON)
```

### 7. Restore Session
```
→ /channel/2/add_device ["michaelwillis.dragonfly.room", -1]
→ /plugin/state/load [2, 0, "QklOQVJZU1RBVEUuLi4="]
```

---

## Plugin Categories

Plugins are categorized based on CLAP feature tags:

| Category     | CLAP Features                                           |
|--------------|---------------------------------------------------------|
| `instrument` | `instrument`, `synthesizer`, `sampler`, `drum-machine` |
| `effect`     | `audio-effect`, `reverb`, `delay`, `compressor`, etc.  |
| `utility`    | `analyzer`, `utility`                                  |

---

## Error Handling

Plugin operations log errors but don't send explicit error messages via OSC. Check engine logs for diagnostics:

**Common errors:**
- Plugin not found in scanner → Check plugin ID spelling
- Failed to load bundle → Check file permissions and library dependencies
- Instantiation failed → Plugin may require specific sample rate or configuration
- Invalid device position → Check device chain size

---

## Thread Safety

All plugin operations follow Sonara's lock-free design:

1. **OSC Message Reception:** Main thread (non-blocking)
2. **Command Queueing:** Crossbeam channel (lock-free)
3. **Command Processing:** Audio thread (via `try_recv()`)
4. **Plugin Processing:** Audio thread (real-time safe)

**Important:**
- Plugin instantiation happens on audio thread (blocks one buffer cycle)
- Parameter changes are real-time safe
- State save/load may block briefly (acceptable for user-triggered actions)

---

## Future Extensions

### Phase 3 (Planned)
- Plugin GUI support (`/plugin/gui/open`, `/plugin/gui/close`)
- Latency compensation queries
- Preset management (beyond raw state blobs)
- Multi-output plugin routing

### Phase 4 (Planned)
- VST3 plugin support (same OSC protocol)
- LV2 plugin support
- Out-of-process plugin hosting (sandboxing)

---

## Testing

See `Engine/test_plugin_osc.sh` for a test script that demonstrates the full workflow.

**Prerequisites:**
```bash
sudo apt-get install liblo-tools  # For oscsend/oscdump
```

**Run Test:**
```bash
# Terminal 1: Start engine
cd Engine && ./run.sh

# Terminal 2: Monitor responses
oscdump 7001

# Terminal 3: Send commands
./test_plugin_osc.sh
```

---

## Compatibility

**Supported Plugin Formats:**
- ✅ CLAP (v1.x)
- ⏳ VST3 (planned)
- ⏳ LV2 (planned)

**Platform Support:**
- ✅ Linux (tested)
- ⏳ macOS (untested, should work)
- ⏳ Windows (not supported yet, requires path changes)

---

## References

- [CLAP Specification](https://github.com/free-audio/clap)
- [clack-host Documentation](https://github.com/prokopyl/clack)
- [Sonara OSC Protocol](OSC_PROTOCOL.md)
- [Plugin Implementation Plan](plan.md)

