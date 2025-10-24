# Device Active/Enabled State Sync Implementation

## Summary

Implemented bidirectional OSC synchronization for device `active` and `enabled` states between Godot UI and Rust audio engine. The **engine is now the source of truth** for device states.

## What Changed

### 1. **Rust Audio Engine** (`Engine/src/`)

#### Built-in Devices (`oscillator.rs`, `delay.rs`)
- ✅ Added `is_active` and `is_enabled` fields to struct
- ✅ Implemented `is_active()`, `activate()`, `deactivate()` trait methods
- ✅ Implemented `is_enabled()`, `set_enabled()` trait methods
- ✅ Added state checks in `process_block()`:
  - **Inactive**: Pass-through for effects, silence for instruments (device not loaded)
  - **Disabled**: Pass-through for effects, silence for instruments (bypass)

#### Commands (`commands.rs`)
- ✅ Added `DeviceActiveChanged` and `DeviceEnabledChanged` to `EngineStatus` enum
- ✅ Modified `SetDeviceActive` handler to send status updates after successful state change
- ✅ Modified `SetDeviceEnabled` handler to send status updates after successful state change

#### OSC Server (`osc/server.rs`)
- ✅ Added OSC message handlers for:
  - `/channel/{id}/device/{position}/active` → sends `i:0_or_1`
  - `/channel/{id}/device/{position}/enabled` → sends `i:0_or_1`

### 2. **Godot Front-End** (`Godot/data/`)

#### DeviceInstance (`DeviceInstance.gd`)
- ✅ Added `connect_to_engine()` to set up OSC listeners for its own state
- ✅ Added `disconnect_from_engine()` to clean up OSC listeners
- ✅ Added `_on_active_received()` callback handler
- ✅ Added `_on_enabled_received()` callback handler
- ✅ Updates own state without sending back to engine (avoids loops)
- ✅ Already had `set_enabled()` and `set_active()` with OSC send
- ✅ Signals properly emitted when state changes from engine

#### Channel (`Channel.gd`)
- ✅ Calls `device_inst.connect_to_engine()` when devices are added
- ✅ Calls `device_inst.disconnect_from_engine()` when devices are removed
- ✅ Connects all existing devices on `Channel.connect_to_engine()`
- ✅ Clean separation: Channel manages device chain, DeviceInstance manages own state

### 3. **Documentation** (`OSC_PROTOCOL.md`)
- ✅ Updated device state management section
- ✅ Added "Device State Updates (Rust -> Godot)" section

## Architecture

### Clean OOP Design

Each `DeviceInstance` is responsible for:
- Listening to its own OSC messages: `/channel/{channel_id}/device/{position}/active|enabled`
- Updating its own state when messages arrive from engine
- Emitting its own signals for UI updates
- Sending state change requests to engine via `set_enabled()` / `set_active()`

The `Channel` manages the device chain lifecycle:
- Calls `device_inst.connect_to_engine()` when devices are added
- Calls `device_inst.disconnect_from_engine()` when devices are removed

### Message Flow

**UI → Engine (User clicks enable/disable button)**:
1. `DeviceLightButton._gui_input()` → calls `device_instance.set_enabled()`
2. `DeviceInstance.set_enabled()` → sends `/channel/{id}/device/{pos}/enable [0|1]`
3. Rust OSC server receives → creates `AudioCommand::SetDeviceEnabled`
4. Audio thread processes command → calls `device.set_enabled()`
5. Command handler sends `EngineStatus::DeviceEnabledChanged`
6. OSC server sends back `/channel/{id}/device/{pos}/enabled [0|1]`
7. **DeviceInstance receives via `_on_enabled_received()`** → updates `enabled` + emits signal
8. UI updates to reflect confirmed state

**Why Bidirectional?**
- Engine can fail to activate/deactivate (e.g., CLAP plugin activation error)
- Ensures UI always shows actual audio state, not just requested state
- Supports future features like automation or scripting changing device states

### OSC Message Queuing

**Question: Are OSC messages queued if spammed via UI?**

**Answer: YES! ✅**

- **Godot → Engine**: Uses **crossbeam unbounded channel** (`command_tx`)
- **Engine → Godot**: Uses **crossbeam unbounded channel** (`status_tx`)
- **Spamming 100 enable/disable clicks is safe** - all messages queue and process in order
- Audio thread uses `try_recv()` (non-blocking) so UI never blocks audio processing

## Testing

Test with:
```bash
# Terminal 1: Run audio engine
cd Engine && cargo run

# Terminal 2: Run Godot UI
cd Godot && godot

# In Godot:
1. Create an instrument track (already done on startup)
2. Add a device (e.g., Oscillator) to the channel
3. Click the DeviceLightButton to toggle enable/bypass
4. Ctrl+Click to toggle active/inactive
5. Check Engine logs for state changes
6. Check UI updates reflect engine state
```

## Benefits

1. **Reliable State Sync**: UI always shows actual audio engine state
2. **Error Handling**: Failed activations don't leave UI in incorrect state
3. **Performance**: Queued messages prevent UI spam from blocking audio
4. **Future-Proof**: Supports automation, scripting, and engine-driven state changes
5. **Clean Architecture**: Engine is source of truth, UI is view layer

## Fixed Issues

- ✅ CLAP plugins now correctly pass audio through when inactive (was outputting silence)
- ✅ Order of checks corrected: inactive check before enabled check for proper behavior

## Next Steps

1. Test with CLAP plugins to verify disable behavior
2. Improve listener tracking for proper cleanup
3. Consider adding state query messages for initial sync on reconnect
4. Add similar bidirectional sync for parameter changes?

