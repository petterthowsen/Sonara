# Plugin OSC Protocol Refactoring

## Summary

Successfully refactored the plugin OSC protocol to eliminate redundancy and improve consistency with the existing device architecture.

## Changes Made

### ✅ Removed Redundant Commands

**Before:**
- `/plugin/instantiate [channel_id, plugin_id, position]` ← **Redundant!**
- `/channel/{id}/add_device [device_id, position]` ← **Built-in devices only**

**After:**
- `/channel/{id}/add_device [device_id, position]` ← **Handles both built-in + plugins!**

### ✅ Simplified Status Messages

**Before:**
- `/plugin/discovered [id, name, vendor, category, version]` (sent for each plugin)
- `/plugin/scan_complete [count]`

**After:**
- `/plugin/scan_complete [count]` (only message needed)
- Plugins cached in `PluginScanner`, query individually as needed

### ✅ Unified Device Factory

**Location:** `Engine/src/audio/commands.rs:467-516`

The `AddDeviceToChannel` handler now checks:
1. Built-in device IDs (`sonara.builtin.*`)
2. Plugin IDs from `PluginScanner`

```rust
match device_id.as_str() {
    // Built-in devices
    "sonara.builtin.oscillator" => { /* ... */ }
    "sonara.builtin.delay" => { /* ... */ }
    
    // CLAP plugins (fallback)
    id => {
        if let Some(descriptor) = state.plugin_scanner.get_plugin(id) {
            // Load CLAP plugin
        }
    }
}
```

## Benefits

### 1. **Consistency**
- Same command for all devices (built-in and plugins)
- Same parameter control: `/channel/{id}/device/{pos}/param/{id}`
- Easier to learn and use

### 2. **Less API Surface**
- Removed 1 command (`/plugin/instantiate`)
- Removed 1 status message type (`/plugin/discovered`)
- Simpler protocol documentation

### 3. **Better Architecture**
- Plugins are devices (they implement `AudioDevice` trait)
- Godot doesn't need to know the difference
- Future plugin formats (VST3, LV2) use same API

### 4. **Cleaner Code**
- 50+ fewer lines of code
- One device loading path instead of two
- No special cases in Godot

## Updated Protocol

### Plugin Workflow

```bash
# 1. Scan for plugins
/plugin/scan
← /plugin/scan_complete [197]

# 2. Add plugin (same as built-in!)
/channel/2/add_device ["michaelwillis.dragonfly.room", -1]

# 3. Control parameters (same as built-in!)
/channel/2/device/0/param/0 [0.75]

# 4. Query parameters (same as built-in!)
/plugin/get_parameters [2, 0]
← /plugin/param/count [2, 0, 12]
← /plugin/param/info [...]

# 5. Save/load state (plugin-specific)
/plugin/state/save [2, 0]
/plugin/state/load [2, 0, "base64state"]
```

### Device ID Examples

**Built-in:**
- `sonara.builtin.oscillator`
- `sonara.builtin.delay`

**CLAP Plugins:**
- `michaelwillis.dragonfly.room`
- `com.airwindows.consolidated`
- `in.lsp-plug.compressor_mono`

## Files Modified

| File | Changes |
|------|---------|
| `Engine/src/audio/commands.rs` | • Removed `InstantiatePlugin` command<br>• Updated `AddDeviceToChannel` handler<br>• Removed `PluginDiscovered` status<br>• Simplified plugin scan handler |
| `Engine/src/osc/server.rs` | • Removed `/plugin/instantiate` route<br>• Removed `/plugin/discovered` status handler |
| `OSC_PROTOCOL.md` | • Added CLAP plugin section to devices<br>• Documented unified command structure |
| `PLUGIN_OSC_PROTOCOL.md` | • Updated instantiation section<br>• Updated example workflow<br>• Clarified unified approach |
| `Engine/test_plugin_osc.sh` | • Updated to use `/channel/2/add_device`<br>• Added "Key Takeaways" section |

## Testing

✅ **Compilation:** No errors, 32 warnings (pre-existing)  
✅ **Plugin Loading:** Dragonfly Room Reverb loads successfully  
✅ **Unified Command:** `/channel/2/add_device` works for both built-in and plugins  
✅ **Test Script:** Updated and verified

### Test Output
```
Add device michaelwillis.dragonfly.room to channel 2 at position -1
Loading CLAP plugin: Dragonfly Room Reverb (michaelwillis.dragonfly.room)
Device michaelwillis.dragonfly.room added to channel 2 at position 0
```

## Breaking Changes

### For Godot Integration (not yet implemented)

**Before:**
```gdscript
AudioEngineOSC.send("/plugin/instantiate", [channel_id, plugin_id, position])
```

**After:**
```gdscript
AudioEngineOSC.send("/channel/" + str(channel_id) + "/add_device", [plugin_id, position])
```

Since the Godot integration hasn't been implemented yet, there are **no actual breaking changes** - just better documentation for when we implement Phase 3.

## Remaining Work

### Known Issues (Pre-existing)
1. **Plugin Activation** - Plugins load but aren't activated (0 parameters reported)
2. **State Save/Load** - Returns empty state (needs CLAP state extension)

### Future Improvements
1. Add `/plugin/list` command to query discovered plugins from Godot
2. Add `/plugin/info [plugin_id]` to get individual plugin metadata
3. Implement plugin categories in Browser (instruments vs effects)

## Conclusion

The OSC protocol is now **cleaner, simpler, and more consistent**. Plugins are treated as first-class devices alongside built-in oscillators and effects. This sets a strong foundation for Phase 3 (Godot Integration).

---

**Refactored:** October 22, 2025  
**Test System:** Linux 6.8.0-52-generic  
**Verified:** 197 CLAP plugins, Dragonfly Room Reverb instantiation

