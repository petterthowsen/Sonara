extends Node

## Central manager for MIDI device enumeration, routing, and engine communication.
## Maintains device registry, handles InputEventMIDI events, and routes them
## to armed channels via OSC.

var logger : Log = Log.make("MidiManager")


# ============================================================================
# SIGNALS
# ============================================================================

signal devices_changed()  # Emitted when device list changes
signal midi_event_received(device_id: int, event: InputEventMIDI)  # Raw MIDI event


# ============================================================================
# CONSTANTS
# ============================================================================

# Virtual keyboard device
const VIRTUAL_KEYBOARD_ID = -1

# Velocity steps for keyboard_velocity_up/down
const VELOCITY_STEP: int = 10


# ============================================================================
# DEVICE REGISTRY
# ============================================================================

# Device registry: device_id -> MidiDevice
var devices: Dictionary = {}

# Enabled device IDs (for quick filtering)
var enabled_devices: Array[int] = []


# ============================================================================
# VIRTUAL KEYBOARD STATE
# ============================================================================

var virtual_keyboard_enabled: bool = true
var keyboard_transpose: int = 0  # Semitone offset (default 0 = Q is C3)
var keyboard_velocity: int = 100  # Default velocity (0-127)
var active_keyboard_notes: Dictionary = {}  # action_name -> midi_note


# ============================================================================
# LIFECYCLE
# ============================================================================

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
	var enabled_list = Sonara.get_config("midi/enabled_devices", [VIRTUAL_KEYBOARD_ID])
	for device_id in enabled_list:
		if devices.has(device_id):
			devices[device_id].enabled = true
			enabled_devices.append(device_id)

	# Restore virtual keyboard settings
	virtual_keyboard_enabled = Sonara.get_config("midi/virtual_keyboard/enabled", true)
	keyboard_transpose = Sonara.get_config("midi/virtual_keyboard/transpose", 0)
	keyboard_velocity = Sonara.get_config("midi/virtual_keyboard/velocity", 100)

	# Connect to Settings autoload for runtime updates
	var settings = get_node_or_null("/root/Settings")
	if settings:
		settings.connect("setting_changed", _on_setting_changed)

	devices_changed.emit()
	logger.info("Initialized with %d devices (%d enabled)" % [devices.size(), enabled_devices.size()])


# ============================================================================
# DEVICE MANAGEMENT
# ============================================================================

func get_device(device_id: int) -> MidiDevice:
	## Returns MidiDevice for given ID, or null if not found.
	return devices.get(device_id)


func get_all_devices() -> Array[MidiDevice]:
	## Returns array of all registered devices (physical + virtual).
	var result: Array[MidiDevice] = []
	for device in devices.values():
		result.append(device)
	return result


func is_device_enabled(device_id: int) -> bool:
	## Check if device is currently enabled for input.
	return device_id in enabled_devices


func set_device_enabled(device_id: int, enabled: bool):
	## Enable or disable a MIDI device.
	## Updates config and emits devices_changed signal.

	if not devices.has(device_id):
		logger.warning("Device %d not found" % device_id)
		return

	var device = devices[device_id]
	var was_enabled = device.enabled
	device.enabled = enabled

	# Update enabled_devices array
	if enabled and not (device_id in enabled_devices):
		enabled_devices.append(device_id)
	elif not enabled and (device_id in enabled_devices):
		enabled_devices.erase(device_id)

	# Persist to config
	if was_enabled != enabled:
		Sonara.set_config("midi/enabled_devices", enabled_devices)
		Sonara.save_config()
		devices_changed.emit()
		logger.info("Device %d (%s) %s" % [device_id, device.device_name, "enabled" if enabled else "disabled"])


func refresh_devices():
	## Re-scan for physical MIDI devices.
	## Detects hotplug changes and updates registry.

	logger.info("Refreshing devices")

	var device_names = OS.get_connected_midi_inputs()
	var new_devices: Dictionary = {}

	# Create MidiDevice instances for each physical device
	for i in range(device_names.size()):
		var device_id = i
		var device_name = device_names[i]

		# Reuse existing device if already registered (preserves enabled state)
		if devices.has(device_id):
			new_devices[device_id] = devices[device_id]
			# Update name in case device changed
			new_devices[device_id].device_name = device_name
		else:
			# Create new device
			var new_device = MidiDevice.new(device_id, device_name, MidiDevice.DeviceType.PHYSICAL)
			new_devices[device_id] = new_device

	# Preserve virtual keyboard device
	if devices.has(VIRTUAL_KEYBOARD_ID):
		new_devices[VIRTUAL_KEYBOARD_ID] = devices[VIRTUAL_KEYBOARD_ID]

	# Update registry
	devices = new_devices

	# Clean up enabled_devices array (remove IDs that no longer exist)
	var valid_enabled: Array[int] = []
	for device_id in enabled_devices:
		if devices.has(device_id):
			valid_enabled.append(device_id)
	enabled_devices = valid_enabled

	devices_changed.emit()
	logger.info("Refreshed devices: %d found" % device_names.size())


# ============================================================================
# INPUT HANDLING
# ============================================================================

func _input(event: InputEvent):
	## Handle virtual keyboard input actions and physical MIDI events.
	## Use _input instead of _unhandled_input so keyboard events are processed
	## even when UI buttons are focused (e.g., record arm button).

	# Physical MIDI events
	if event is InputEventMIDI:
		handle_physical_midi_event(event)
		return

	if not virtual_keyboard_enabled:
		return

	# Typing in LineEdit/TextEdit should never trigger computer-keyboard MIDI.
	if _is_gui_text_editing():
		_release_active_keyboard_notes()
		return

	if event is InputEventKey and not event.is_echo():
		# Only process keyboard actions if they match our note actions
		# This prevents interfering with other keyboard shortcuts
		var is_keyboard_action = false
		for action in ["keyboard_c3", "keyboard_c#3", "keyboard_d3", "keyboard_d#3",
				"keyboard_e3", "keyboard_f3", "keyboard_f#3", "keyboard_g3",
				"keyboard_g#3", "keyboard_a3", "keyboard_a#3", "keyboard_b3",
				"keyboard_c4", "keyboard_c#4", "keyboard_d4", "keyboard_d#4",
				"keyboard_transpose_up", "keyboard_transpose_down",
				"keyboard_velocity_up", "keyboard_velocity_down"]:
			if event.is_action(action):
				is_keyboard_action = true
				break

		if is_keyboard_action:
			handle_virtual_keyboard_action(event)
			# Don't accept the event - let UI handle it if needed
			# But we've already processed it for MIDI


## True when a text input currently owns GUI focus (names, search, tempo, etc.).
func _is_gui_text_editing() -> bool:
	var viewport := get_viewport()
	if viewport == null:
		return false
	var focus := viewport.gui_get_focus_owner()
	if focus is LineEdit:
		return (focus as LineEdit).editable
	if focus is TextEdit:
		return (focus as TextEdit).editable
	return false


## Send note-off for any computer-keyboard notes that are still held.
func _release_active_keyboard_notes() -> void:
	if active_keyboard_notes.is_empty():
		return
	for note_name in active_keyboard_notes.keys():
		var note = active_keyboard_notes[note_name]
		emit_virtual_midi_note(note, 0, false)
	active_keyboard_notes.clear()


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


func handle_virtual_keyboard_action(event: InputEventKey):
	## Process virtual keyboard input actions.

	# Transpose controls
	if event.is_action_pressed("keyboard_transpose_up"):
		keyboard_transpose = clampi(keyboard_transpose + 12, -24, 24)
		Sonara.set_config("midi/virtual_keyboard/transpose", keyboard_transpose)
		logger.info("Keyboard transpose: %d" % keyboard_transpose)
		return
	elif event.is_action_pressed("keyboard_transpose_down"):
		keyboard_transpose = clampi(keyboard_transpose - 12, -24, 24)
		Sonara.set_config("midi/virtual_keyboard/transpose", keyboard_transpose)
		logger.info("Keyboard transpose: %d" % keyboard_transpose)
		return

	# Velocity controls
	elif event.is_action_pressed("keyboard_velocity_up"):
		keyboard_velocity = clampi(keyboard_velocity + VELOCITY_STEP, 1, 127)
		Sonara.set_config("midi/virtual_keyboard/velocity", keyboard_velocity)
		logger.info("Keyboard velocity: %d" % keyboard_velocity)
		return
	elif event.is_action_pressed("keyboard_velocity_down"):
		keyboard_velocity = clampi(keyboard_velocity - VELOCITY_STEP, 1, 127)
		Sonara.set_config("midi/virtual_keyboard/velocity", keyboard_velocity)
		logger.info("Keyboard velocity: %d" % keyboard_velocity)
		return

	# Note actions (keyboard_c3, keyboard_d#4, etc.)
	var note = ""
	if event.is_action("keyboard_c3"):
		note = "C3"
	elif event.is_action("keyboard_c#3"):
		note = "C#3"
	elif event.is_action("keyboard_d3"):
		note = "D3"
	elif event.is_action("keyboard_d#3"):
		note = "D#3"
	elif event.is_action("keyboard_e3"):
		note = "E3"
	elif event.is_action("keyboard_f3"):
		note = "F3"
	elif event.is_action("keyboard_f#3"):
		note = "F#3"
	elif event.is_action("keyboard_g3"):
		note = "G3"
	elif event.is_action("keyboard_g#3"):
		note = "G#3"
	elif event.is_action("keyboard_a3"):
		note = "A3"
	elif event.is_action("keyboard_a#3"):
		note = "A#3"
	elif event.is_action("keyboard_b3"):
		note = "B3"
	elif event.is_action("keyboard_c4"):
		note = "C4"
	elif event.is_action("keyboard_c#4"):
		note = "C#4"
	elif event.is_action("keyboard_d4"):
		note = "D4"
	elif event.is_action("keyboard_d#4"):
		note = "D#4"

	if note != "":
		handle_virtual_note(note, event.pressed)
		return


func handle_virtual_note(note_name: String, pressed: bool):
	## Handle virtual keyboard note press/release.
	
	# Convert note name to MIDI number using Midi utility
	var base_note = Midi.note_name_to_midi(note_name.to_upper())
	if base_note < 0:
		push_warning("[MidiManager] Invalid note name: %s" % note_name)
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


# ============================================================================
# MIDI ROUTING
# ============================================================================

func route_midi_event(device_id: int, event: InputEventMIDI):
	## Route MIDI event to armed channels matching device routing.
	# Get all armed channels
	var project = Sonara.editor.project
	if not project:
		return

	for channel in project.channels:
		if not channel.record_armed:
			continue

		# Check device routing
		var accepts_device = false
		if channel.midi_input_device == -2:  # All devices
			accepts_device = true
		elif channel.midi_input_device == device_id:  # Specific device
			accepts_device = true

		if accepts_device:
			send_midi_to_channel(channel.id, event)


func route_virtual_midi_event(event: Dictionary):
	## Route virtual MIDI event to armed channels.
	# Get all armed channels
	var project = Sonara.editor.project
	if not project:
		return

	for channel in project.channels:
		if not channel.record_armed:
			continue

		# Check device routing
		var accepts_device = false
		if channel.midi_input_device == -2:  # All devices
			accepts_device = true
		elif channel.midi_input_device == VIRTUAL_KEYBOARD_ID:  # Virtual keyboard
			accepts_device = true

		if accepts_device:
			send_midi_to_channel(channel.id, event)


## Send a note-on or note-off straight to `channel_id`, skipping record-arm routing.
func send_note_to_channel(channel_id: int, note: int, velocity: int, is_note_on: bool) -> void:
	send_midi_to_channel(channel_id, {
		"message": MIDI_MESSAGE_NOTE_ON if is_note_on else MIDI_MESSAGE_NOTE_OFF,
		"channel": 0,
		"pitch": note,
		"velocity": velocity if is_note_on else 0,
	})


func send_midi_to_channel(channel_id: int, event):
	## Send MIDI event to engine via OSC.
	## Accepts both InputEventMIDI (physical devices) and Dictionary (virtual keyboard).
	# Get microsecond timestamp
	var timestamp_us = int(Time.get_ticks_usec())

	# Extract message, channel, pitch, velocity from either InputEventMIDI or Dictionary
	var message: int
	var midi_channel: int
	var pitch: int
	var velocity: int

	if event is InputEventMIDI:
		message = event.message
		midi_channel = event.channel
		pitch = event.pitch
		velocity = event.velocity
	elif event is Dictionary:
		message = event.message
		midi_channel = event.channel
		pitch = event.pitch
		velocity = event.velocity
	else:
		push_warning("[MidiManager] Invalid event type")
		return

	# Route to appropriate OSC message based on type
	match message:
		MIDI_MESSAGE_NOTE_ON, MIDI_MESSAGE_NOTE_OFF:
			AudioEngineOSC.send(
				"/channel/%d/midi_event" % channel_id,
				[channel_id, message, midi_channel, pitch, velocity, timestamp_us]
			)

		MIDI_MESSAGE_CONTROL_CHANGE:
			# For InputEventMIDI, we need controller_number and controller_value
			if event is InputEventMIDI:
				AudioEngineOSC.send(
					"/channel/%d/midi_cc" % channel_id,
					[channel_id, midi_channel, event.controller_number, event.controller_value, timestamp_us]
				)
			else:
				# For dictionary-based CC events (if we add them later)
				AudioEngineOSC.send(
					"/channel/%d/midi_cc" % channel_id,
					[channel_id, midi_channel, pitch, velocity, timestamp_us]
				)

		# Add more message types as needed
		_:
			push_warning("[MidiManager] Unhandled MIDI message type: %d" % message)


# ============================================================================
# VIRTUAL KEYBOARD MANAGEMENT
# ============================================================================

func set_virtual_keyboard_enabled(enabled: bool):
	## Enable or disable virtual keyboard input.
	if virtual_keyboard_enabled != enabled:
		virtual_keyboard_enabled = enabled

		# Release all active notes when disabling
		if not enabled:
			_release_active_keyboard_notes()

		# Persist to config
		Sonara.set_config("midi/virtual_keyboard/enabled", enabled)
		Sonara.save_config()
		devices_changed.emit()
		print("[MidiManager] Virtual keyboard %s" % ("enabled" if enabled else "disabled"))


# ---------------------------------------------------------------------------
# Settings synchronization (called when SettingsDialog changes a value)
# ---------------------------------------------------------------------------

func _on_setting_changed(key: String, value) -> void:
	"""React to live setting changes from the Settings dialog."""
	match key:
		"midi/virtual_keyboard/enabled":
			_apply_virtual_keyboard_enabled(value)
		"midi/virtual_keyboard/transpose":
			keyboard_transpose = clampi(int(value), -24, 24)
			logger.info("Keyboard transpose updated: %d" % keyboard_transpose)
		"midi/virtual_keyboard/velocity":
			keyboard_velocity = clampi(int(value), 1, 127)
			logger.info("Keyboard velocity updated: %d" % keyboard_velocity)


func _apply_virtual_keyboard_enabled(enabled: bool) -> void:
	"""Update virtual keyboard state without persisting (Settings dialog handles save)."""
	if virtual_keyboard_enabled != enabled:
		virtual_keyboard_enabled = enabled
		if not enabled:
			_release_active_keyboard_notes()
		devices_changed.emit()
		print("[MidiManager] Virtual keyboard %s" % ("enabled" if enabled else "disabled"))
