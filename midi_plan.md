# MIDI System Implementation Plan

## Overview
Implement comprehensive MIDI input handling for Sonara, allowing hardware MIDI devices and virtual keyboard input to record and control instrument channels. The system will route MIDI events through OSC to the Rust audio engine for sample-accurate recording and playback.

## Architecture Summary
- **MidiManager** (Godot autoload singleton): Central coordinator for device enumeration, routing, and OSC communication
- **MidiDevice** abstraction: Represents physical devices and virtual keyboard with enable/disable state
- **Channel MIDI routing**: Each channel can accept MIDI from specific device(s) based on record arm state
- **Virtual keyboard**: Fake device ID for computer keyboard MIDI input
- **Engine integration**: OSC messages deliver MIDI events with sample-accurate timing

## Device ID Scheme
- `-3`: No MIDI input (channel ignores all MIDI)
- `-2`: All devices (channel accepts MIDI from any enabled device)
- `-1`: Virtual keyboard (computer keyboard)
- `0-999`: Physical MIDI devices (matches Godot's device enumeration order)

---

## Phase 1: Godot - MidiManager Foundation

### 1.1 Create MidiManager Singleton
**File**: `Godot/Midi/MidiManager.gd`

**Responsibilities**:
- Enumerate and track MIDI devices
- Maintain device enable/disable state
- Handle incoming InputEventMIDI events
- Provide device lookup/query API
- Persist device enabled/disabled to config

**Implementation**:
```gdscript
extends Node

## Central manager for MIDI device enumeration, routing, and engine communication.
## Maintains device registry, handles InputEventMIDI events, and routes them
## to armed channels via OSC.

signal devices_changed()  # Emitted when device list changes
signal midi_event_received(device_id: int, event: InputEventMIDI)  # Raw MIDI event

# Device registry: device_id -> MidiDevice
var devices: Dictionary = {}

# Enabled device IDs (for quick filtering)
var enabled_devices: Array[int] = []

# Virtual keyboard device
const VIRTUAL_KEYBOARD_ID = -1

func _ready():
	## Scan for MIDI devices and restore enabled state from config.
	initialize()

func initialize():
	## Initialize MIDI system, enumerate devices, restore config.
	# Enumerate physical MIDI devices
	OS.open_midi_inputs()
	refresh_devices()

	# Create virtual keyboard device
	var virt_device = MidiDevice.new(VIRTUAL_KEYBOARD_ID, "Virtual Keyboard", MidiDevice.DeviceType.VIRTUAL_KEYBOARD)
	devices[VIRTUAL_KEYBOARD_ID] = virt_device

	# Restore enabled devices from config
	var enabled_list = Sonara.get_config("midi/enabled_devices", [-1])
	for device_id in enabled_list:
		if devices.has(device_id):
			devices[device_id].enabled = true
			enabled_devices.append(device_id)

	# Restore virtual keyboard settings
	virtual_keyboard_enabled = Sonara.get_config("midi/virtual_keyboard/enabled", true)
	keyboard_transpose = Sonara.get_config("midi/virtual_keyboard/transpose", 0)
	keyboard_velocity = Sonara.get_config("midi/virtual_keyboard/velocity", 100)

	devices_changed.emit()

func get_device(device_id: int) -> MidiDevice:
	## Returns MidiDevice for given ID, or null if not found.
	return devices.get(device_id)

func get_all_devices() -> Array[MidiDevice]:
	## Returns array of all registered devices (physical + virtual).
	pass

func is_device_enabled(device_id: int) -> bool:
	## Check if device is currently enabled for input.
	pass

func set_device_enabled(device_id: int, enabled: bool):
	## Enable or disable a MIDI device.
	## Updates config and emits devices_changed signal.
	pass

func refresh_devices():
	## Re-scan for physical MIDI devices.
	## Detects hotplug changes and updates registry.
	pass
```

### 1.2 Create MidiDevice Class
**File**: `Godot/midi/MidiDevice.gd`

**Responsibilities**:
- Represent a single MIDI input device (physical or virtual)
- Track device metadata (name, ID, type)
- Track enabled state

**Implementation**:
```gdscript
class_name MidiDevice
extends RefCounted

## Represents a MIDI input device (physical or virtual keyboard).

enum DeviceType {
	PHYSICAL,      # Hardware MIDI controller/keyboard
	VIRTUAL_KEYBOARD  # Computer keyboard emulation
}

var device_id: int
var device_name: String
var device_type: DeviceType
var enabled: bool = false

func _init(id: int, name: String, type: DeviceType):
	device_id = id
	device_name = name
	device_type = type

func is_virtual_keyboard() -> bool:
	return device_type == DeviceType.VIRTUAL_KEYBOARD
```

### 1.3 Device Enumeration & Hotplug
**Update**: `MidiManager.gd`

**Tasks**:
- Call `OS.open_midi_inputs()` on initialization
- Enumerate devices with `OS.get_connected_midi_inputs()`
- Create MidiDevice instances for each physical device (ID = index, starting at 0)
- Add virtual keyboard device (ID = -1)
- Implement `refresh_devices()` for hotplug detection
- Restore enabled state from `Sonara.get_config("midi/enabled_devices", [])`

**Config Schema**:
```json
{
  "midi": {
    "enabled_devices": [-1, 0],  // Device IDs (-1 = virtual keyboard, 0+ = physical devices)
    "virtual_keyboard": {
      "enabled": true,
      "transpose": 0,
      "velocity": 100
    }
  }
}
```

---

## Phase 2: Godot - MIDI Event Handling

### 2.1 InputEventMIDI Capture
**Update**: `MidiManager.gd`

**Tasks**:
- Implement `_input(event)` to capture `InputEventMIDI`
- Filter events by enabled devices
- Emit `midi_event_received(device_id, event)` signal
- Handle velocity=0 note-on as note-off
- Log device_id mismatches (Godot's device property may not be reliable)

**Implementation Notes**:
- According to docs, `event.device` may default to 0 for all events
- May need to add device detection heuristics or user manual mapping if Godot's device ID is unreliable
- Consider timestamp handling (events arrive with OS timestamps)

### 2.2 Virtual Keyboard Implementation
**Update**: `MidiManager.gd` (no separate class needed)

**Responsibilities**:
- Handle input actions for virtual keyboard notes (`keyboard_c3`, `keyboard_c#3`, ..., `keyboard_d#4`)
- Handle transpose up/down actions (`keyboard_transpose_up/down`)
- Handle velocity up/down actions (`keyboard_velocity_up/down`)
- Emit virtual MIDI events with device ID = -1
- Track active notes to send note-offs on release
- Provide enable/disable toggle for virtual keyboard

**Input Actions** (defined in project settings):
```
keyboard_c3, keyboard_c#3, keyboard_d3, keyboard_d#3, keyboard_e3, keyboard_f3,
keyboard_f#3, keyboard_g3, keyboard_g#3, keyboard_a3, keyboard_a#3, keyboard_b3,
keyboard_c4, keyboard_c#4, keyboard_d4, keyboard_d#4
keyboard_transpose_up
keyboard_transpose_down
keyboard_velocity_up
keyboard_velocity_down
```

**Implementation** (add to MidiManager.gd):
```gdscript
# Virtual keyboard state
var virtual_keyboard_enabled: bool = true
var keyboard_transpose: int = 0  # Semitone offset (default 0 = Q is C3)
var keyboard_velocity: int = 100  # Default velocity (0-127)
var active_keyboard_notes: Dictionary = {}  # action_name -> midi_note

# Velocity steps for keyboard_velocity_up/down
const VELOCITY_STEP: int = 10

func _unhandled_input(event: InputEvent):
	## Handle virtual keyboard input actions and physical MIDI events.

	# Physical MIDI events
	if event is InputEventMIDI:
		handle_physical_midi_event(event)
		return

	# Virtual keyboard (only if enabled)
	if not virtual_keyboard_enabled:
		return

	if event is InputEventAction:
		handle_virtual_keyboard_action(event)

func handle_virtual_keyboard_action(event: InputEventAction):
	## Process virtual keyboard input actions.
	var action = event.as_text().split(" ")[0]  # Extract action name

	# Transpose controls
	if action == "keyboard_transpose_up" and event.pressed:
		keyboard_transpose = clampi(keyboard_transpose + 12, -24, 24)
		print("[MidiManager] Keyboard transpose: ", keyboard_transpose)
		return
	elif action == "keyboard_transpose_down" and event.pressed:
		keyboard_transpose = clampi(keyboard_transpose - 12, -24, 24)
		print("[MidiManager] Keyboard transpose: ", keyboard_transpose)
		return

	# Velocity controls
	elif action == "keyboard_velocity_up" and event.pressed:
		keyboard_velocity = clampi(keyboard_velocity + VELOCITY_STEP, 1, 127)
		print("[MidiManager] Keyboard velocity: ", keyboard_velocity)
		return
	elif action == "keyboard_velocity_down" and event.pressed:
		keyboard_velocity = clampi(keyboard_velocity - VELOCITY_STEP, 1, 127)
		print("[MidiManager] Keyboard velocity: ", keyboard_velocity)
		return

	# Note actions (keyboard_c3, keyboard_d#4, etc.)
	if action.begins_with("keyboard_"):
		var note_name = action.substr(9)  # Remove "keyboard_" prefix
		handle_virtual_note(note_name, event.pressed)

func handle_virtual_note(note_name: String, pressed: bool):
	## Handle virtual keyboard note press/release.

	# Convert note name to MIDI number using Midi utility
	var base_note = Midi.note_name_to_midi(note_name.to_upper())
	if base_note < 0:
		push_warning("[MidiManager] Invalid note name: ", note_name)
		return

	# Apply transpose
	var midi_note = clampi(base_note + keyboard_transpose, 0, 127)

	if pressed:
		# Note on
		if not active_keyboard_notes.has(note_name):
			active_keyboard_notes[note_name] = midi_note
			emit_virtual_midi_note(midi_note, keyboard_velocity, true)
	else:
		# Note off
		if active_keyboard_notes.has(note_name):
			var note = active_keyboard_notes[note_name]
			active_keyboard_notes.erase(note_name)
			emit_virtual_midi_note(note, 0, false)

func emit_virtual_midi_note(note: int, velocity: int, is_note_on: bool):
	## Emit virtual MIDI event with device ID = -1.
	var message_type = MIDI_MESSAGE_NOTE_ON if is_note_on else MIDI_MESSAGE_NOTE_OFF

	# Create internal MIDI event structure
	var midi_event = {
		"device_id": VIRTUAL_KEYBOARD_ID,
		"message": message_type,
		"channel": 0,
		"pitch": note,
		"velocity": velocity
	}

	# Route to armed channels (same as physical MIDI)
	route_virtual_midi_event(midi_event)

func route_virtual_midi_event(event: Dictionary):
	## Route virtual MIDI event to armed channels.
	# Same logic as route_midi_event but uses internal event structure
	# Implementation in Phase 3
	pass

func set_virtual_keyboard_enabled(enabled: bool):
	## Enable or disable virtual keyboard input.
	if virtual_keyboard_enabled != enabled:
		virtual_keyboard_enabled = enabled

		# Release all active notes when disabling
		if not enabled:
			for note_name in active_keyboard_notes.keys():
				var note = active_keyboard_notes[note_name]
				emit_virtual_midi_note(note, 0, false)
			active_keyboard_notes.clear()

		# Persist to config
		Sonara.set_config("midi/virtual_keyboard/enabled", enabled)
		Sonara.save_config()
		devices_changed.emit()
```

**Update handle_physical_midi_event**:
```gdscript
func handle_physical_midi_event(event: InputEventMIDI):
	## Handle incoming physical MIDI device events.
	var device_id = event.device

	# Check if device is enabled
	if device_id not in enabled_devices:
		return

	# Emit signal for monitoring
	midi_event_received.emit(device_id, event)

	# Route to armed channels
	route_midi_event(device_id, event)
```

---

## Phase 3: Godot - Channel MIDI Routing

### 3.1 Extend Channel Data Model
**Update**: `Godot/data/Channel.gd`

**New Properties**:
```gdscript
## MIDI input configuration
var midi_input_device: int = -3  # -3=none, -2=all, -1=virtual keyboard, 0+=physical device
var record_armed: bool = false

signal midi_input_device_changed(device_id: int)
signal record_armed_changed(armed: bool)

func set_midi_input_device(device_id: int):
	## Assign MIDI input device to this channel.
	## -3 = no MIDI, -2 = all devices, -1 = virtual keyboard, 0+ = specific device ID.
	if midi_input_device != device_id:
		midi_input_device = device_id
		midi_input_device_changed.emit(device_id)
		sync_to_engine()

func set_record_armed(armed: bool):
	## Arm/disarm channel for MIDI recording.
	if record_armed != armed:
		record_armed = armed
		record_armed_changed.emit(armed)
		# Recording state affects MIDI routing

func sync_to_engine():
	## Send MIDI routing config to engine via OSC.
	if not is_valid():
		return

	AudioEngineOSC.send_message("/channel/%d/midi_input_device" % channel_id, [midi_input_device])
	AudioEngineOSC.send_message("/channel/%d/record_armed" % channel_id, [record_armed])
```

### 3.2 MIDI Routing Logic in MidiManager
**Update**: `MidiManager.gd`

**Tasks**:
- Add method `route_midi_event(device_id: int, event: InputEventMIDI)`
- Query all channels for `midi_input_device` and `record_armed`
- Determine which channels should receive this event:
  - Channel must be record-armed
  - Channel's `midi_input_device` must match:
    - `-2` = accepts all devices
    - `device_id` = accepts specific device
    - `-3` = no MIDI (skip)
- Send OSC message per target channel (Phase 4)

**Implementation**:
```gdscript
func route_midi_event(device_id: int, event: InputEventMIDI):
	## Route MIDI event to armed channels matching device routing.

	# Get all armed channels
	var project = Sonara.editor.project
	if not project:
		return

	for channel in project.channels.values():
		if not channel.record_armed:
			continue

		# Check device routing
		var accepts_device = false
		if channel.midi_input_device == -2:  # All devices
			accepts_device = true
		elif channel.midi_input_device == device_id:  # Specific device
			accepts_device = true

		if accepts_device:
			send_midi_to_channel(channel.channel_id, event)

func send_midi_to_channel(channel_id: int, event: InputEventMIDI):
	## Send MIDI event to engine for given channel.
	# Implemented in Phase 4
	pass
```

---

## Phase 4: Godot - OSC MIDI Transmission

### 4.1 Define OSC MIDI Protocol
**Messages** (Godot → Engine):

```
/channel/{id}/midi_input_device ii channel_id device_id
/channel/{id}/record_armed ib channel_id armed

/channel/{id}/midi_event iiiiii channel_id message midi_channel pitch velocity timestamp_us
  - message: MIDI message type constant (8=note_off, 9=note_on, etc.)
  - midi_channel: MIDI channel 0-15
  - pitch: MIDI note/data1
  - velocity: velocity/data2
  - timestamp_us: microsecond timestamp (for sample-accurate scheduling)
```

**Alternative (if we want CC support)**:
```
/channel/{id}/midi_cc iiiii channel_id midi_channel cc_number cc_value timestamp_us
```

### 4.2 Implement OSC Transmission
**Update**: `MidiManager.gd`

```gdscript
func send_midi_to_channel(channel_id: int, event: InputEventMIDI):
	## Send MIDI event to engine via OSC.

	# Get microsecond timestamp (Godot uses msec, convert to usec)
	var timestamp_us = int(Time.get_ticks_usec())

	# Route to appropriate OSC message based on type
	match event.message:
		MIDI_MESSAGE_NOTE_ON, MIDI_MESSAGE_NOTE_OFF:
			AudioEngineOSC.send_message(
				"/channel/%d/midi_event" % channel_id,
				[channel_id, event.message, event.channel, event.pitch, event.velocity, timestamp_us]
			)

		MIDI_MESSAGE_CONTROL_CHANGE:
			AudioEngineOSC.send_message(
				"/channel/%d/midi_cc" % channel_id,
				[channel_id, event.channel, event.controller_number, event.controller_value, timestamp_us]
			)

		# Add more message types as needed
		_:
			push_warning("[MidiManager] Unhandled MIDI message type: ", event.message)
```

---

## Phase 5: Godot - UI Integration

### 5.1 MIDI Device Settings Panel
**File**: `Godot/editor/settings/MidiDevicePanel.gd`

**Features**:
- List all detected MIDI devices
- Enable/disable checkboxes per device
- "Refresh Devices" button for hotplug
- Virtual keyboard enable toggle
- Display device connection status

**Layout**:
```
MIDI Devices
┌─────────────────────────────────────┐
│ ☑ Virtual Keyboard (Computer Keys)  │
│ ☑ Arturia KeyLab 49                 │
│ ☐ MIDI Fighter Twister              │
│ ☐ Disconnected Device               │
│                                      │
│ [Refresh Devices]                   │
└─────────────────────────────────────┘
```

### 5.2 Channel MIDI Routing UI
**Update**: Channel strip or mixer channel

**Controls**:
- Record arm button (toggle)
- MIDI input device dropdown:
  - "No MIDI Input" (-3)
  - "All Devices" (-2)
  - "Virtual Keyboard" (-1)
  - Individual device names (0+)

**Visual Feedback**:
- MIDI activity indicator (blinks on note events)
- Record arm LED (red when armed)

### 5.3 Global MIDI Monitor (Optional)
**File**: `Godot/editor/debug/MidiMonitor.gd`

**Features**:
- Real-time MIDI event log
- Filter by device/channel
- Show message type, note, velocity, timestamps
- Useful for debugging MIDI routing

---

## Phase 6: Engine - MIDI Data Structures

### 6.1 Define MIDI Event Types
**File**: `Engine/src/audio/midi_types.rs`

**Structures**:
```rust
/// MIDI message type constants (match Godot)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MidiMessageType {
    NoteOff = 8,
    NoteOn = 9,
    Aftertouch = 10,
    ControlChange = 11,
    ProgramChange = 12,
    ChannelPressure = 13,
    PitchBend = 14,
}

/// Sample-accurate MIDI event with tick timing
#[derive(Debug, Clone)]
pub struct MidiEvent {
    pub message_type: MidiMessageType,
    pub midi_channel: u8,  // 0-15
    pub note: u8,          // 0-127 (or data1)
    pub velocity: u8,      // 0-127 (or data2)
    pub tick: u64,         // Scheduled tick (converted from timestamp)
    pub frame_offset: usize, // Sample offset within current buffer
}

impl MidiEvent {
    pub fn note_on(midi_channel: u8, note: u8, velocity: u8, tick: u64) -> Self {
        Self {
            message_type: MidiMessageType::NoteOn,
            midi_channel,
            note,
            velocity,
            tick,
            frame_offset: 0,
        }
    }

    pub fn note_off(midi_channel: u8, note: u8, tick: u64) -> Self {
        Self {
            message_type: MidiMessageType::NoteOff,
            midi_channel,
            note,
            velocity: 0,
            tick,
            frame_offset: 0,
        }
    }
}
```

### 6.2 Channel MIDI State
**Update**: `Engine/src/audio/types.rs` (Channel struct)

**Fields**:
```rust
pub struct Channel {
    // ... existing fields ...

    /// MIDI input device routing (-3=none, -2=all, -1=virtual keyboard, 0+=device_id)
    pub midi_input_device: i32,

    /// Record arm state
    pub record_armed: bool,

    /// Incoming MIDI event queue (non-audio thread writes, audio thread reads)
    pub midi_queue: Arc<SegQueue<MidiEvent>>,
}
```

---

## Phase 7: Engine - OSC MIDI Reception

### 7.1 OSC Handler Registration
**Update**: `Engine/src/osc/server.rs`

**Handlers**:
```rust
fn register_handlers(&mut self) {
    // ... existing handlers ...

    // MIDI routing config
    self.add_handler(
        "/channel/{id}/midi_input_device",
        handle_channel_midi_input_device,
    );
    self.add_handler(
        "/channel/{id}/record_armed",
        handle_channel_record_armed,
    );

    // MIDI events
    self.add_handler(
        "/channel/{id}/midi_event",
        handle_channel_midi_event,
    );
    self.add_handler(
        "/channel/{id}/midi_cc",
        handle_channel_midi_cc,
    );
}
```

### 7.2 MIDI Event Handler Implementation
**File**: `Engine/src/osc/handlers/midi.rs`

```rust
use rosc::OscType;
use crate::audio::{MidiEvent, MidiMessageType};

/// Handle /channel/{id}/midi_event iiiiii
pub fn handle_channel_midi_event(
    engine: &mut EngineState,
    args: Vec<OscType>,
) -> Result<(), String> {
    // Parse: channel_id, message, midi_channel, pitch, velocity, timestamp_us
    let channel_id = extract_int(&args, 0)?;
    let message = extract_int(&args, 1)?;
    let midi_channel = extract_int(&args, 2)? as u8;
    let pitch = extract_int(&args, 3)? as u8;
    let velocity = extract_int(&args, 4)? as u8;
    let timestamp_us = extract_long(&args, 5)?;

    // Convert timestamp to tick (based on current transport state)
    let tick = engine.timestamp_to_tick(timestamp_us);

    // Create MIDI event
    let message_type = match message {
        8 => MidiMessageType::NoteOff,
        9 => MidiMessageType::NoteOn,
        // ... handle others
        _ => return Err(format!("Unknown MIDI message type: {}", message)),
    };

    let event = MidiEvent {
        message_type,
        midi_channel,
        note: pitch,
        velocity,
        tick,
        frame_offset: 0, // Will be computed in audio callback
    };

    // Push to channel's MIDI queue
    if let Some(channel) = engine.channels.get(&channel_id) {
        channel.midi_queue.push(event);
        Ok(())
    } else {
        Err(format!("Channel {} not found", channel_id))
    }
}

/// Handle /channel/{id}/midi_input_device ii
pub fn handle_channel_midi_input_device(
    engine: &mut EngineState,
    args: Vec<OscType>,
) -> Result<(), String> {
    let channel_id = extract_int(&args, 0)?;
    let device_id = extract_int(&args, 1)?;

    if let Some(channel) = engine.channels.get_mut(&channel_id) {
        channel.midi_input_device = device_id;
        info!("Channel {} MIDI input device set to {}", channel_id, device_id);
        Ok(())
    } else {
        Err(format!("Channel {} not found", channel_id))
    }
}

/// Handle /channel/{id}/record_armed ib
pub fn handle_channel_record_armed(
    engine: &mut EngineState,
    args: Vec<OscType>,
) -> Result<(), String> {
    let channel_id = extract_int(&args, 0)?;
    let armed = extract_bool(&args, 1)?;

    if let Some(channel) = engine.channels.get_mut(&channel_id) {
        channel.record_armed = armed;
        info!("Channel {} record armed: {}", channel_id, armed);
        Ok(())
    } else {
        Err(format!("Channel {} not found", channel_id))
    }
}
```

---

## Phase 8: Engine - Audio Thread MIDI Processing

### 8.1 Sample-Accurate MIDI Scheduling
**Update**: `Engine/src/audio/processing.rs`

**Integration into `process_audio`**:
```rust
pub fn process_audio(
    engine: &mut EngineState,
    output: &mut [f32],
    frame_count: usize,
    sample_rate: f32,
) {
    // 1. Drain pending commands
    drain_commands(engine);

    // 2. Clear channel buffers
    clear_buffers(engine);

    // 3. Advance transport and calculate timing
    let start_tick = engine.transport.tick;
    let ticks_per_sample = calculate_ticks_per_sample(engine.bpm, sample_rate);

    // 4. Drain MIDI queues and schedule events
    schedule_midi_events(engine, start_tick, ticks_per_sample, frame_count);

    // 5. Process devices and render audio
    // ... existing rendering logic ...
}

fn schedule_midi_events(
    engine: &mut EngineState,
    start_tick: u64,
    ticks_per_sample: f64,
    frame_count: usize,
) {
    let end_tick = start_tick + (frame_count as f64 * ticks_per_sample) as u64;

    for channel in engine.channels.values_mut() {
        // Drain MIDI queue and calculate frame offsets
        while let Some(mut event) = channel.midi_queue.pop() {
            // Skip events that are too late (already passed)
            if event.tick < start_tick {
                warn!("Dropping late MIDI event: tick {} < {}", event.tick, start_tick);
                continue;
            }

            // Calculate sample offset within this buffer
            let tick_offset = event.tick.saturating_sub(start_tick);
            let frame_offset = ((tick_offset as f64) / ticks_per_sample) as usize;

            if frame_offset >= frame_count {
                // Event is for future buffer, push back to queue
                channel.midi_queue.push(event);
                break;
            }

            event.frame_offset = frame_offset;

            // Add to scheduled events for this channel's devices
            channel.scheduled_midi_events.push(event);
        }

        // Sort by frame offset for sample-accurate processing
        channel.scheduled_midi_events.sort_by_key(|e| e.frame_offset);
    }
}
```

### 8.2 Device MIDI Consumption
**Update device processing** (e.g., CLAP subprocess adapter)

**Pattern**:
```rust
// In device's render method
pub fn render_block(
    &mut self,
    output: &mut [f32],
    frame_count: usize,
    midi_events: &[MidiEvent],
) {
    // Convert MidiEvent to CLAP events
    let clap_events = self.convert_midi_to_clap(midi_events);

    // Send to subprocess via shared memory
    self.send_events_to_subprocess(&clap_events);

    // Process audio block
    // ... existing rendering ...
}
```

---

## Phase 9: Testing & Refinement

### 9.1 Unit Tests (Godot)
- Test MidiDevice enumeration and state management
- Test virtual keyboard key mapping and octave shifting
- Test MIDI routing logic (device filtering, record arm)
- Mock OSC transmission and verify message format

### 9.2 Unit Tests (Engine)
- Test MIDI event parsing from OSC
- Test timestamp-to-tick conversion
- Test sample-accurate scheduling algorithm
- Test MIDI queue management (push/pop, ordering)

### 9.3 Integration Tests
- End-to-end: Virtual keyboard → Godot → OSC → Engine → MIDI queue
- Hardware device detection and routing
- Multi-channel MIDI routing (same event to multiple channels)
- Record arm toggling during playback

### 9.4 Manual Testing Checklist
- [ ] Enumerate physical MIDI devices on Linux (ALSA)
- [ ] Enable/disable devices and verify config persistence
- [ ] Virtual keyboard plays notes on armed channel
- [ ] Physical MIDI controller plays notes on armed channel
- [ ] MIDI events route to correct channels based on device_id
- [ ] All devices (-1) mode works correctly
- [ ] No MIDI (-2) mode blocks all input
- [ ] Sample-accurate timing (notes align with playhead)
- [ ] Hotplug: Connect/disconnect device and refresh
- [ ] Octave shifting on virtual keyboard
- [ ] MIDI monitor shows all events in real-time

---

## Future Enhancements (Post-MVP)

### MIDI Recording to Clips
- Capture MIDI events into Clip note data during transport playback
- Quantize recording based on grid settings
- Overdub and replace modes

### MIDI Learn for Parameters
- Assign CC messages to device parameters
- Visual feedback during learn mode

### MIDI Clock Sync
- Send/receive MIDI clock for external sync
- Handle START/STOP/CONTINUE messages

### MIDI Thru
- Pass-through MIDI events to output devices
- Monitor mode for playing while recording

### Virtual Device Enhancements
- Configurable key mapping
- Velocity sensitivity (key press duration)
- Sustain pedal simulation

### MPE Support
- Per-note pitch bend and pressure
- Multi-channel note allocation

---

## Dependencies & Prerequisites

### Godot Side
- Existing: `Sonara.gd` autoload, `AudioEngineOSC`, `Channel` data model
- New: `MidiManager.gd` (autoload), `MidiDevice.gd`

### Engine Side
- Existing: OSC server, `EngineState`, `Channel` struct, sample-accurate scheduling
- New: `midi_types.rs`, MIDI OSC handlers, MIDI queue processing
- Dependencies: None (uses existing crossbeam queues)

### System Requirements
- Linux: ALSA MIDI support
- Godot 4.5+ with `OS.open_midi_inputs()` support

---

## Timeline Estimate

| Phase | Description | Effort |
|-------|-------------|--------|
| 1 | MidiManager & MidiDevice foundation | 2-3 hours |
| 2 | MIDI event handling & virtual keyboard | 3-4 hours |
| 3 | Channel routing logic | 1-2 hours |
| 4 | OSC MIDI transmission | 1-2 hours |
| 5 | UI integration | 3-4 hours |
| 6 | Engine MIDI data structures | 1 hour |
| 7 | Engine OSC reception | 2-3 hours |
| 8 | Engine audio thread processing | 3-4 hours |
| 9 | Testing & debugging | 4-6 hours |
| **Total** | **Full MIDI system** | **20-29 hours** |

---

## Success Criteria

- ✅ Physical MIDI devices enumerate and can be enabled/disabled
- ✅ Virtual keyboard generates MIDI notes from computer keyboard
- ✅ MIDI events route to armed channels based on device assignment
- ✅ Engine receives MIDI events via OSC with sample-accurate timing
- ✅ Audio thread processes MIDI events without blocking or allocation
- ✅ UI provides clear MIDI routing controls and visual feedback
- ✅ Config persists device enabled state across sessions
- ✅ System handles hotplug device changes gracefully
