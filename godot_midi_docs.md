# Godot MIDI Support Documentation

## Overview

Godot Engine provides MIDI input support through the `InputEventMIDI` class. MIDI events are received through the standard input system and can be handled in `_input()` or `_unhandled_input()` callbacks.

By default, Godot does not detect MIDI devices. You need to call OS.open_midi_inputs(), first. You can check which devices are detected with OS.get_connected_midi_inputs(), and close the connection with OS.close_midi_inputs().

## MIDI Message Constants

Godot defines MIDI message constants in the global scope:

```gdscript
MIDI_MESSAGE_NONE = 0
MIDI_MESSAGE_NOTE_OFF = 8
MIDI_MESSAGE_NOTE_ON = 9
MIDI_MESSAGE_AFTERTOUCH = 10
MIDI_MESSAGE_CONTROL_CHANGE = 11
MIDI_MESSAGE_PROGRAM_CHANGE = 12
MIDI_MESSAGE_CHANNEL_PRESSURE = 13
MIDI_MESSAGE_PITCH_BEND = 14
MIDI_MESSAGE_SYSTEM_EXCLUSIVE = 240
MIDI_MESSAGE_QUARTER_FRAME = 241
MIDI_MESSAGE_SONG_POSITION_POINTER = 242
MIDI_MESSAGE_SONG_SELECT = 243
MIDI_MESSAGE_TUNE_REQUEST = 246
MIDI_MESSAGE_TIMING_CLOCK = 248
MIDI_MESSAGE_START = 250
MIDI_MESSAGE_CONTINUE = 251
MIDI_MESSAGE_STOP = 252
MIDI_MESSAGE_ACTIVE_SENSING = 254
MIDI_MESSAGE_SYSTEM_RESET = 255
```

## InputEventMIDI Class

`InputEventMIDI` inherits from `InputEvent` and can be handled in input callbacks like `_input()` or `_unhandled_input()`.

### Properties

- **device** (int) - Device ID (inherited from InputEvent, may not reliably identify MIDI devices)
- **message** (int) - MIDI message type (use constants above)
- **channel** (int) - MIDI channel (0-15)
- **pitch** (int) - Note number (0-127)
- **velocity** (int) - Velocity (0-127, for note events)
- **controller_number** (int) - Controller number (0-127, for CC events)
- **controller_value** (int) - Controller value (0-127, for CC events)

## Basic MIDI Event Handling

### Simple Example

```gdscript
func _input(event: InputEvent):
    if event is InputEventMIDI:
        handle_midi_event(event)

func handle_midi_event(event: InputEventMIDI):
    var message = event.message
    var channel = event.channel
    var pitch = event.pitch
    var velocity = event.velocity
    
    # Check message type
    if message == MIDI_MESSAGE_NOTE_ON:
        print("Note ON: ", pitch, " Velocity: ", velocity, " Channel: ", channel)
    elif message == MIDI_MESSAGE_NOTE_OFF:
        print("Note OFF: ", pitch, " Channel: ", channel)
    elif message == MIDI_MESSAGE_CONTROL_CHANGE:
        print("CC: ", event.controller_number, " Value: ", event.controller_value)
    elif message == MIDI_MESSAGE_PITCH_BEND:
        print("Pitch Bend: ", event.pitch, " Channel: ", channel)
    elif message == MIDI_MESSAGE_PROGRAM_CHANGE:
        print("Program Change: ", event.pitch, " Channel: ", channel)
```

## Identifying MIDI Devices

### Using the `device` Property

`InputEventMIDI` inherits the `device` property from `InputEvent`:

```gdscript
func _input(event: InputEvent):
    if event is InputEventMIDI:
        var midi_event = event as InputEventMIDI
        var device_id = midi_event.device
        print("MIDI event from device ID: ", device_id)
```

**Note:** The `device` property may not reliably identify MIDI devices across all platforms. It often defaults to `0` for all MIDI events.

### Enumerating MIDI Devices

To properly identify MIDI devices, you should enumerate them using `OS` methods and create a mapping:

```gdscript
extends Node

var midi_devices: Dictionary = {}  # Maps device_id -> device_name

func _ready():
    # Open MIDI inputs
    OS.open_midi_inputs()
    
    # Get list of connected MIDI devices
    var device_names = OS.get_connected_midi_inputs()
    
    # Map device names to IDs
    for i in range(device_names.size()):
        var device_name = device_names[i]
        var device_id = i  # Use index as device ID
        midi_devices[device_id] = device_name
        print("MIDI device ", device_id, ": ", device_name)

func _input(event: InputEvent):
    if event is InputEventMIDI:
        var midi_event = event as InputEventMIDI
        var device_id = midi_event.device
        
        # Get device name from our mapping
        var device_name = midi_devices.get(device_id, "Unknown Device")
        print("MIDI event from: ", device_name, " (ID: ", device_id, ")")
        print("  Message: ", midi_event.message)
        print("  Channel: ", midi_event.channel)
        print("  Pitch: ", midi_event.pitch)
        print("  Velocity: ", midi_event.velocity)
```

### OS Methods for MIDI

- **`OS.open_midi_inputs()`** - Opens all available MIDI inputs
- **`OS.get_connected_midi_inputs()`** - Returns an array of connected MIDI device names

## Complete MIDI Handler Example

```gdscript
extends Node

var midi_devices: Dictionary = {}
var device_name_cache: Dictionary = {}  # Cache device names for performance

func _ready():
    setup_midi_devices()

func setup_midi_devices():
    """Initialize MIDI device enumeration."""
    OS.open_midi_inputs()
    var device_names = OS.get_connected_midi_inputs()
    
    print("[MIDI] Found ", device_names.size(), " MIDI input devices:")
    for i in range(device_names.size()):
        var device_name = device_names[i]
        var device_id = i
        midi_devices[device_id] = device_name
        device_name_cache[device_id] = device_name
        print("  [", device_id, "] ", device_name)

func _input(event: InputEvent):
    if event is InputEventMIDI:
        handle_midi_event(event)

func handle_midi_event(event: InputEventMIDI):
    """Handle incoming MIDI events with device identification."""
    var device_id = event.device
    var device_name = device_name_cache.get(device_id, "Unknown Device")
    
    var message = event.message
    var channel = event.channel
    
    match message:
        MIDI_MESSAGE_NOTE_ON:
            if event.velocity > 0:
                print("[MIDI] Note ON from ", device_name, ": Note ", event.pitch, 
                      " Velocity ", event.velocity, " Channel ", channel)
            else:
                # Velocity 0 means note off
                print("[MIDI] Note OFF from ", device_name, ": Note ", event.pitch, 
                      " Channel ", channel)
        
        MIDI_MESSAGE_NOTE_OFF:
            print("[MIDI] Note OFF from ", device_name, ": Note ", event.pitch, 
                  " Channel ", channel)
        
        MIDI_MESSAGE_CONTROL_CHANGE:
            print("[MIDI] CC from ", device_name, ": CC ", event.controller_number, 
                  " Value ", event.controller_value, " Channel ", channel)
        
        MIDI_MESSAGE_PROGRAM_CHANGE:
            print("[MIDI] Program Change from ", device_name, ": Program ", event.pitch, 
                  " Channel ", channel)
        
        MIDI_MESSAGE_PITCH_BEND:
            print("[MIDI] Pitch Bend from ", device_name, ": Value ", event.pitch, 
                  " Channel ", channel)
        
        MIDI_MESSAGE_CHANNEL_PRESSURE:
            print("[MIDI] Channel Pressure from ", device_name, ": Value ", event.pitch, 
                  " Channel ", channel)
        
        MIDI_MESSAGE_AFTERTOUCH:
            print("[MIDI] Aftertouch from ", device_name, ": Value ", event.pitch, 
                  " Channel ", channel)
        
        MIDI_MESSAGE_TIMING_CLOCK:
            # Don't spam for timing clock messages
            pass
        
        _:
            print("[MIDI] Unknown message ", message, " from ", device_name, 
                  " Channel ", channel)

func get_device_name(device_id: int) -> String:
    """Get human-readable name for a MIDI device ID."""
    return device_name_cache.get(device_id, "Unknown Device")
```

## Limitations and Considerations

1. **Device ID Reliability**: The `device` property on `InputEventMIDI` may not reliably distinguish between MIDI devices on all platforms. It often defaults to `0` for all events.

2. **Platform Differences**: MIDI support may vary across platforms:
   - **Linux**: Uses ALSA MIDI
   - **Windows**: Uses Windows MIDI API
   - **macOS**: Uses CoreMIDI

3. **Device Enumeration**: Always call `OS.open_midi_inputs()` before calling `OS.get_connected_midi_inputs()` to ensure devices are properly enumerated.

4. **Real-time Performance**: MIDI event handling should be kept lightweight to avoid audio dropouts or performance issues.

## Integration with Sonara

In the Sonara DAW project:
- MIDI events are currently routed through OSC to the Rust audio engine
- The project has MIDI utilities (`Midi.gd`) for note conversions
- MIDI events are not currently handled directly in Godot for audio generation
- Consider using `InputEventMIDI` if you want to add direct MIDI input handling in the Godot UI

## References

- [Godot InputEventMIDI Documentation](https://docs.godotengine.org/en/stable/classes/class_inputeventmidi.html)
- [Godot OS Class Documentation](https://docs.godotengine.org/en/stable/classes/class_os.html)
- [MIDI Message Types](https://www.midi.org/specifications-old/item/table-1-summary-of-midi-message)

