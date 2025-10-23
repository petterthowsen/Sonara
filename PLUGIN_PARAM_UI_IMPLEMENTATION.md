# Plugin Parameter UI Implementation

## Overview
Implemented automatic parameter UI generation for CLAP plugins, matching the behavior of built-in devices.

## Problem
- Built-in devices had hardcoded parameters in their factory methods
- CLAP plugins discovered via OSC had empty `parameters` array
- No UI controls generated for plugin parameters
- OSC protocol used inefficient argument-based routing

## Solution

### 1. Fixed OSC Protocol (Path-Based Routing)

**Before (Inconsistent):**
```
/plugin/param/count [channel_id, device_pos, count]
/plugin/param/info [channel_id, device_pos, param_id, name, min, max, default]
```
→ All channels listen to same address, filter by channel_id

**After (Consistent with `/channel/{id}/peak` pattern):**
```
/channel/{channel_id}/device/{device_pos}/param/count [count]
/channel/{channel_id}/device/{device_pos}/param/info [param_id, name, min, max, default]
```
→ Each channel listens to own addresses only

### 2. Automatic Parameter Query on Device Add

**Flow:**
1. User drags plugin from browser to channel
2. `Channel.add_device()` sends `/channel/{id}/add_device` to engine
3. For plugin devices, `_query_plugin_parameters()` is called
4. Sets up OSC listeners for `/channel/{id}/device/{pos}/param/*`
5. Sends `/plugin/get_parameters [channel_id, device_pos]` to engine
6. Engine responds with parameter count and info for each parameter
7. Channel populates `Device.parameters` array dynamically
8. DevicePanel listens to `device_parameters_updated` signal
9. UI refreshes and generates controls automatically

### 3. Dynamic Parameter Loading

**Key Components:**

**Channel.gd:**
- `_pending_param_queries: Dictionary` - Tracks expected parameter counts
- `_query_plugin_parameters(device_pos)` - Sends query and sets up listeners
- `_listen_device_params(device_pos)` - Creates device-specific OSC listeners
- `_on_device_param_count_received()` - Stores expected count
- `_on_device_param_info_received()` - Creates DeviceParameter, adds to Device
- `device_parameters_updated` signal - Emitted when all params loaded

**DevicePanel.gd:**
- Connects to channel's `device_parameters_updated` signal
- `_on_device_parameters_updated()` - Refreshes UI when params load
- Works seamlessly with existing `_create_parameter_controls()`

## Files Modified

1. **Engine/src/osc/server.rs**
   - Changed parameter messages to path-based routing
   
2. **Godot/data/Channel.gd**
   - Added parameter query tracking dictionary
   - Implemented query logic and OSC handlers
   - Added signal for parameter updates
   
3. **Godot/device_lane/DevicePanel.gd**
   - Added signal handler to refresh UI
   - Fixed linter warnings
   
4. **PLUGIN_OSC_PROTOCOL.md**
   - Updated documentation to reflect path-based routing

## Testing

To test:
1. Start audio engine: `cd Engine && ./run.sh`
2. Start Godot project
3. Drag CLAP plugin (e.g., Dragonfly Hall Reverb) onto mixer channel
4. Device panel should show parameter controls automatically
5. Verify parameters are controllable and sync to engine

## Benefits

✅ **Consistency** - Plugins work exactly like built-in devices
✅ **Efficiency** - No unnecessary OSC callbacks or filtering
✅ **Cleaner Protocol** - Path-based routing throughout
✅ **Better UX** - Parameters appear automatically, no manual setup needed
✅ **Extensible** - Easy to add automation lanes later

## Next Steps (Phase 4 Continued)

1. **Plugin State Save/Load** - Store parameter values + plugin state in project files
2. **Parameter Automation** - Connect plugin params to automation lanes
3. **Plugin GUI** (optional) - Floating native GUI windows

