# MidiNote.gd
# Represents a MIDI note with duration (higher-level than MidiEvent)
# Note that 60 = C3 ("middle C") 
class_name MidiNoteData extends RefCounted

# Unique identification (assigned by Project)
var id: int = -1  # Unique ID for this note (used by audio engine)

# Note properties
var note: int = 60  # MIDI note number (0-127)
var velocity: int = 100  # Note velocity (0-127)
var start_tick: int = 0  # Start position in ticks (relative to clip)
var duration_ticks: int = 480  # Note duration in ticks

# Serialize to JSON
func to_json() -> Dictionary:
	return {
		"id": id,
		"note": note,
		"velocity": velocity,
		"start_tick": start_tick,
		"duration_ticks": duration_ticks
	}

# Deserialize from JSON
static func from_json(data: Dictionary) -> MidiNoteData:
	var midi_note = MidiNoteData.new()
	midi_note.id = data.get("id", -1)
	midi_note.note = data.get("note", 60)
	midi_note.velocity = data.get("velocity", 100)
	midi_note.start_tick = data.get("start_tick", 0)
	midi_note.duration_ticks = data.get("duration_ticks", 480)
	return midi_note

# Get end tick
func get_end_tick() -> int:
	return start_tick + duration_ticks

# Convert to MIDI events (NOTE_ON and NOTE_OFF)
func to_midi_events() -> Array[MidiEvent]:
	var events: Array[MidiEvent] = []
	events.append(MidiEvent.create_note_on(start_tick, note, velocity))
	events.append(MidiEvent.create_note_off(get_end_tick(), note, 0))
	return events

# Create from note on/off events
static func from_events(note_on: MidiEvent, note_off: MidiEvent) -> MidiNoteData:
	var midi_note = MidiNoteData.new()
	midi_note.note = note_on.note
	midi_note.velocity = note_on.velocity
	midi_note.start_tick = note_on.tick
	midi_note.duration_ticks = note_off.tick - note_on.tick
	return midi_note
