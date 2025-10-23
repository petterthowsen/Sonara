# Godot Device System

This document describes the Godot-side implementation of the audio device system, including built-in device registration and parameter management.

## Overview

The device system consists of three main classes:

1. **Device** - Metadata about a device type (instrument or effect)
2. **DeviceParameter** - Metadata about a device parameter (knob, slider, etc.)
3. **DeviceInstance** - An instance of a device on a channel with current parameter state

## Architecture

### Device Discovery Flow

```
DeviceAssetProvider
├── Registers built-in devices (Oscillator, Delay)
└── Provides access to Device metadata

AssetService
├── Manages all asset providers
├── Queries available devices
└── Returns device lists by category
```

### Device Usage Flow

```
1. Query available devices via AssetService
2. Create DeviceInstance for a channel
3. Set parameters on DeviceInstance
4. Sync parameters to audio engine via OSC
```

## Classes

### Device

Represents the metadata/definition of a device type.

**Device Types:**
```gdscript
enum DeviceType { BuiltIn, LV2, CLAP }
```

**Device Categories:**
```gdscript
enum DeviceCategory { Instrument, Effect, Utility }
```

**Key Properties:**
```gdscript
var device_id: String                      # Unique ID (e.g., "sonara.builtin.oscillator")
var name: String                           # Display name
var device_type: DeviceType                # BuiltIn, LV2, or CLAP
var category: DeviceCategory               # Instrument, Effect, or Utility
var parameters: Array[DeviceParameter]    # List of parameters
var accepts_midi: bool                     # True for instruments
var description: String                    # Documentation
```

**Factory Methods:**
```gdscript
# Create built-in devices
static func create_builtin_oscillator() -> Device
static func create_builtin_delay() -> Device
```

**Example:**
```gdscript
var osc = Device.create_builtin_oscillator()
print(osc.name)  # "Oscillator"
print(osc.device_id)  # "sonara.builtin.oscillator"
print(osc.category)  # Device.DeviceCategory.Instrument
```

---

### DeviceParameter

Metadata about a device parameter (with value scaling).

**Key Properties:**
```gdscript
var id: int                      # Parameter ID (0-255)
var name: String                 # Display name (e.g., "Delay Time")
var unit: String                 # Unit string (e.g., "ms", "dB", "Hz")
var min_value: float             # Minimum real value
var max_value: float             # Maximum real value
var default_value: float         # Default real value
var is_logarithmic: bool         # True for logarithmic scaling
var description: String          # Documentation
var is_automation_safe: bool     # For parameter automation
```

**Conversion Methods:**
```gdscript
# Convert between normalized (0.0-1.0) and real values
func value_to_normalized(value: float) -> float
func normalized_to_value(normalized: float) -> float

# Display formatting
func format_value(value: float) -> String
func get_label() -> String       # "Name (unit)"
```

**Example:**
```gdscript
var param = device.get_parameter(0)  # Get delay time parameter
var normalized = param.value_to_normalized(500.0)  # 500ms → normalized
var real_value = param.normalized_to_value(0.5)    # 0.5 → real value
print(param.format_value(500.0))  # "500.00 ms"
```

---

### DeviceInstance

An instance of a device on a channel with parameter state.

**Key Properties:**
```gdscript
var id: String                   # Unique instance ID (UUID)
var device: Device               # Device metadata
var channel_id: int              # Which channel it's on
var position: int                # Position in device chain (0 = first)
var parameter_values: Dictionary # Normalized parameter values (0.0-1.0)
```

**Signals:**
```gdscript
signal parameter_changed(param_id: int, value: float)
```

**Parameter Access:**
```gdscript
# Normalized values (0.0-1.0)
func set_parameter_normalized(param_id: int, value: float)
func get_parameter_normalized(param_id: int) -> float

# Real values (device-specific range)
func set_parameter_real(param_id: int, value: float)
func get_parameter_real(param_id: int) -> float

# Get all parameters as dictionary
func get_all_parameters_normalized() -> Dictionary[int, float]
```

**Engine Sync:**
```gdscript
# Send all current parameters to audio engine
func sync_to_engine() -> void
```

**Example:**
```gdscript
# Create device instance on channel 2
var device = AssetService.get_device("sonara.builtin.delay")
var instance = DeviceInstance.new(device, 2, 0)

# Set parameter (real value)
instance.set_parameter_real(0, 500.0)  # Set delay time to 500ms

# Sync to engine
instance.sync_to_engine()  # Sends OSC: /channel/2/device/0/param/0 {normalized}
```

---

## Integration with AssetService

### Query Devices

```gdscript
# Get all available devices
var all_devices = AssetService.get_device_assets()

# Get specific categories
var instruments = AssetService.get_instruments()
var effects = AssetService.get_effects()

# Get specific device
var delay = AssetService.get_device("sonara.builtin.delay")
```

### Example: Create Device Chain UI

```gdscript
# Get all effects for a dropdown menu
var effects = AssetService.get_effects()
for device in effects:
	print("%s - %s" % [device.name, device.description])
	# Add to dropdown...
```

---

## Built-In Devices

### Oscillator

**ID:** `sonara.builtin.oscillator`
**Category:** Instrument
**MIDI Input:** Yes

**Parameters:**

| ID | Name | Unit | Min | Max | Default | Description |
|---|---|---|---|---|---|---|
| 0 | Waveform | - | 0.0 | 1.0 | 0.0 | Sine (0.0), Square (0.25), Sawtooth (0.5), Triangle (0.75) |
| 1 | Amplitude | - | 0.0 | 1.0 | 0.3 | Output amplitude / volume |

**Example:**
```gdscript
var osc_device = AssetService.get_device("sonara.builtin.oscillator")
var instance = DeviceInstance.new(osc_device, channel_id, 0)

# Set to square wave
instance.set_parameter_normalized(0, 0.25)

# Set amplitude to 50%
instance.set_parameter_normalized(1, 0.5)

instance.sync_to_engine()
```

---

### Delay

**ID:** `sonara.builtin.delay`
**Category:** Effect
**MIDI Input:** No

**Parameters:**

| ID | Name | Unit | Min | Max | Default | Scaling |
|---|---|---|---|---|---|---|
| 0 | Delay Time | ms | 1.0 | 5000.0 | 250.0 | Logarithmic |
| 1 | Wet Amount | - | 0.0 | 1.0 | 0.5 | Linear |

**Example:**
```gdscript
var delay_device = AssetService.get_device("sonara.builtin.delay")
var instance = DeviceInstance.new(delay_device, channel_id, 1)

# Set delay to 500ms
instance.set_parameter_real(0, 500.0)

# Set to 70% wet
instance.set_parameter_normalized(1, 0.7)

instance.sync_to_engine()
```

---

## Channel Device Chain Management

### Add Device to Channel

```gdscript
# Request audio engine to add device at position -1 (append)
var device_id = "sonara.builtin.delay"
var position = -1
AudioEngineOSC.send("/channel/2/add_device", [device_id, position])
```

### Set Device Parameter

```gdscript
# Send parameter change to audio engine
var channel_id = 2
var device_pos = 0
var param_id = 0
var normalized_value = 0.5
AudioEngineOSC.send("/channel/%d/device/%d/param/%d" % [channel_id, device_pos, param_id], [normalized_value])
```

### Remove Device

```gdscript
# Remove device at position from channel
AudioEngineOSC.send("/channel/2/remove_device", [0])
```

---

## Workflow Example

### Step 1: Get Available Devices

```gdscript
# In a mixer UI or device browser
var instruments = AssetService.get_instruments()
var effects = AssetService.get_effects()

# Create dropdown/menu for user selection
```

### Step 2: Add Device to Channel

```gdscript
# User selects "Oscillator" from dropdown
var device = AssetService.get_device("sonara.builtin.oscillator")
var instance = DeviceInstance.new(device, channel_id, 0)

# Send to audio engine
AudioEngineOSC.send("/channel/%d/add_device" % channel_id, [device.device_id, -1])
```

### Step 3: Configure Device Parameters

```gdscript
# User adjusts slider for waveform
var normalized_value = slider.value  # 0.0-1.0
instance.set_parameter_normalized(0, normalized_value)

# Send OSC to engine
AudioEngineOSC.send("/channel/%d/device/%d/param/0" % [channel_id, position], [normalized_value])
```

### Step 4: Add Effects

```gdscript
# User adds delay effect
var delay_device = AssetService.get_device("sonara.builtin.delay")
AudioEngineOSC.send("/channel/%d/add_device" % channel_id, ["sonara.builtin.delay", -1])

# Configure delay parameters
AudioEngineOSC.send("/channel/%d/device/1/param/0" % channel_id, [0.1])  # 250ms
AudioEngineOSC.send("/channel/%d/device/1/param/1" % channel_id, [0.7])  # 70% wet
```

---

## Future: Plugin Support (Phase 4)

When LV2/CLAP plugins are added:

1. **DeviceAssetProvider** will scan plugin directories
2. **Device objects** will be created for each plugin with metadata
3. **DeviceInstance** works the same way (no UI changes needed)
4. **DeviceParameter** handles plugin ports automatically
5. **OSC Protocol** extends to support plugin IDs: `"lv2:plugin.so"`, `"clap:path/to/plugin.clap"`

No changes to existing code needed!
