# MidiNote.gd
# Represents a MIDI note with duration (higher-level than MidiEvent)
# Note that 60 = C3 ("middle C") 
class_name MidiNoteData extends RefCounted

## Lowest velocity a note can have (MIDI 1 of 127). Velocity runs over (0, 1].
const MIN_VELOCITY := 1.0 / 127.0
const DEFAULT_VELOCITY := 100.0 / 127.0
const DEFAULT_RELEASE := 0.5
## Fields copied, snapshotted and compared as a note's values (everything but `id`).
const VALUE_FIELDS: Array[String] = ["note", "velocity", "release", "start_tick", "duration_ticks"]

# Unique identification (assigned by Project)
var id: int = -1  # Unique ID for this note (used by audio engine)

# Note properties
var note: int = 60  # MIDI note number (0-127)
## Normalized note-on velocity in [MIN_VELOCITY, 1]. Asserts on values >= 2, which are old 0-127 values.
var velocity: float = DEFAULT_VELOCITY:
	set(v):
		assert(v < 2.0, "MidiNoteData.velocity is normalized 0..1; convert 7-bit values with from_midi_velocity()")
		velocity = clampf(v, MIN_VELOCITY, 1.0)
## Normalized note-off (release) velocity in [0, 1].
var release: float = DEFAULT_RELEASE:
	set(v):
		release = clampf(v, 0.0, 1.0)
var start_tick: int = 0  # Start position in ticks (relative to clip)
var duration_ticks: int = 480  # Note duration in ticks


## 7-bit MIDI velocity (1-127) to normalized.
static func from_midi_velocity(v7: int) -> float:
	return clampf(float(v7) / 127.0, MIN_VELOCITY, 1.0)


## Normalized velocity to 7-bit MIDI (rounded, 1-127).
static func to_midi_velocity(v: float) -> int:
	return clampi(roundi(v * 127.0), 1, 127)


## Copy every value field (not the id) from another note.
func copy_values_from(other: MidiNoteData) -> void:
	for field in VALUE_FIELDS:
		set(field, other.get(field))


## A new note with the same values and no id.
func duplicate_note() -> MidiNoteData:
	var copy := MidiNoteData.new()
	copy.copy_values_from(self)
	return copy


## Snapshot of the value fields.
func values() -> Dictionary:
	var out := {}
	for field in VALUE_FIELDS:
		out[field] = get(field)
	return out


func apply_values(v: Dictionary) -> void:
	for field in VALUE_FIELDS:
		if v.has(field):
			set(field, v[field])


static func values_equal(a: Dictionary, b: Dictionary) -> bool:
	for field in VALUE_FIELDS:
		if a.get(field) != b.get(field):
			return false
	return true


# Serialize to JSON
func to_json() -> Dictionary:
	var out := {
		"id": id,
		"note": note,
		"start_tick": start_tick,
		"duration_ticks": duration_ticks,
		"vel": velocity,
	}
	if not is_equal_approx(release, DEFAULT_RELEASE):
		out["rel"] = release
	return out


# Deserialize from JSON. `vel`/`rel` are normalized; older files carry `velocity` as 0-127.
static func from_json(data: Dictionary) -> MidiNoteData:
	var midi_note = MidiNoteData.new()
	midi_note.id = data.get("id", -1)
	midi_note.note = data.get("note", 60)
	if data.has("vel"):
		midi_note.velocity = float(data["vel"])
	else:
		midi_note.velocity = from_midi_velocity(int(data.get("velocity", 100)))
	midi_note.release = float(data.get("rel", DEFAULT_RELEASE))
	midi_note.start_tick = data.get("start_tick", 0)
	midi_note.duration_ticks = data.get("duration_ticks", 480)
	return midi_note

# Get end tick
func get_end_tick() -> int:
	return start_tick + duration_ticks

# Convert to MIDI events (NOTE_ON and NOTE_OFF)
func to_midi_events() -> Array[MidiEvent]:
	var events: Array[MidiEvent] = []
	events.append(MidiEvent.create_note_on(start_tick, note, to_midi_velocity(velocity)))
	events.append(MidiEvent.create_note_off(get_end_tick(), note, to_midi_velocity(release)))
	return events

# Create from note on/off events
static func from_events(note_on: MidiEvent, note_off: MidiEvent) -> MidiNoteData:
	var midi_note = MidiNoteData.new()
	midi_note.note = note_on.note
	midi_note.velocity = from_midi_velocity(note_on.velocity)
	midi_note.start_tick = note_on.tick
	midi_note.duration_ticks = note_off.tick - note_on.tick
	return midi_note
