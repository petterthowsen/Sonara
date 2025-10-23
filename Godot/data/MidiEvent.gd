# MidiEvent.gd
# Represents a single MIDI event (note on/off, CC, etc.)
class_name MidiEvent extends RefCounted

enum EventType {
	NOTE_ON,
	NOTE_OFF,
	CONTROL_CHANGE,
	PROGRAM_CHANGE,
	PITCH_BEND,
	AFTERTOUCH
}

# Common properties
var type: EventType = EventType.NOTE_ON
var tick: int = 0  # Position in ticks relative to clip start

# Note events (NOTE_ON, NOTE_OFF)
var note: int = 60  # MIDI note number (0-127)
var velocity: int = 100  # Velocity (0-127)

# Control Change
var cc_number: int = 0  # Controller number (0-127)
var cc_value: int = 0   # Controller value (0-127)

# Program Change
var program: int = 0  # Program number (0-127)

# Pitch Bend
var pitch_bend: int = 8192  # Pitch bend value (0-16383, center = 8192)

# Aftertouch
var aftertouch: int = 0  # Aftertouch pressure (0-127)

# Serialize to JSON
func to_json() -> Dictionary:
	var data = {
		"type": EventType.keys()[type],
		"tick": tick
	}
	
	match type:
		EventType.NOTE_ON, EventType.NOTE_OFF:
			data["note"] = note
			data["velocity"] = velocity
		EventType.CONTROL_CHANGE:
			data["cc_number"] = cc_number
			data["cc_value"] = cc_value
		EventType.PROGRAM_CHANGE:
			data["program"] = program
		EventType.PITCH_BEND:
			data["pitch_bend"] = pitch_bend
		EventType.AFTERTOUCH:
			data["aftertouch"] = aftertouch
	
	return data

# Deserialize from JSON
static func from_json(data: Dictionary) -> MidiEvent:
	var event = MidiEvent.new()
	
	# Parse event type
	var type_str = data.get("type", "NOTE_ON")
	event.type = EventType.get(type_str) if EventType.has(type_str) else EventType.NOTE_ON
	
	event.tick = data.get("tick", 0)
	
	# Parse type-specific data
	match event.type:
		EventType.NOTE_ON, EventType.NOTE_OFF:
			event.note = data.get("note", 60)
			event.velocity = data.get("velocity", 100)
		EventType.CONTROL_CHANGE:
			event.cc_number = data.get("cc_number", 0)
			event.cc_value = data.get("cc_value", 0)
		EventType.PROGRAM_CHANGE:
			event.program = data.get("program", 0)
		EventType.PITCH_BEND:
			event.pitch_bend = data.get("pitch_bend", 8192)
		EventType.AFTERTOUCH:
			event.aftertouch = data.get("aftertouch", 0)
	
	return event

# Create a NOTE_ON event
static func create_note_on(tick_pos: int, note_num: int, vel: int = 100) -> MidiEvent:
	var event = MidiEvent.new()
	event.type = EventType.NOTE_ON
	event.tick = tick_pos
	event.note = note_num
	event.velocity = vel
	return event

# Create a NOTE_OFF event
static func create_note_off(tick_pos: int, note_num: int, vel: int = 0) -> MidiEvent:
	var event = MidiEvent.new()
	event.type = EventType.NOTE_OFF
	event.tick = tick_pos
	event.note = note_num
	event.velocity = vel
	return event

# Create a Control Change event
static func create_cc(tick_pos: int, cc_num: int, value: int) -> MidiEvent:
	var event = MidiEvent.new()
	event.type = EventType.CONTROL_CHANGE
	event.tick = tick_pos
	event.cc_number = cc_num
	event.cc_value = value
	return event
