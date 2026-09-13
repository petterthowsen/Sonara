# ClipNotesStateCommand.gd
# Restores a clip's MIDI note list to a captured snapshot.
# Used for place/drag/erase gestures that may also cut overlapping notes.
class_name ClipNotesStateCommand extends Command

## Clip whose notes are restored.
var clip: Clip = null

## Snapshot of notes before the gesture (array of field dicts + note refs).
var before_state: Array = []

## Snapshot of notes after the gesture.
var after_state: Array = []


## Create a notes-state command. States are produced by capture_clip_notes().
func _init(
	p_name: String = "Edit Notes",
	p_clip: Clip = null,
	p_before: Array = [],
	p_after: Array = []
) -> void:
	name = p_name
	clip = p_clip
	before_state = p_before
	after_state = p_after


## Capture current midi_notes of a clip into a snapshot array.
static func capture_clip_notes(p_clip: Clip) -> Array:
	var snaps: Array = []
	if p_clip == null:
		return snaps
	for note in p_clip.midi_notes:
		snaps.append(_snapshot_note(note))
	return snaps


## Deep-copy fields of a MidiNoteData into a dictionary (keeps object ref).
static func _snapshot_note(note: MidiNoteData) -> Dictionary:
	return {
		"ref": note,
		"id": note.id,
		"note": note.note,
		"velocity": note.velocity,
		"start_tick": note.start_tick,
		"duration_ticks": note.duration_ticks,
	}


## Apply the after snapshot (redo / initial record already applied).
func do() -> void:
	_restore(after_state)


## Apply the before snapshot.
func undo() -> void:
	_restore(before_state)


## Make clip.midi_notes match the given snapshot via add/remove/update setters.
func _restore(state: Array) -> void:
	if clip == null:
		return

	var desired_by_id: Dictionary = {}
	for snap in state:
		desired_by_id[snap["id"]] = snap

	# Remove notes that should not exist
	var current: Array = clip.midi_notes.duplicate()
	for note in current:
		if not desired_by_id.has(note.id):
			clip.remove_midi_note(note)

	# Add or update desired notes
	for snap in state:
		var note: MidiNoteData = snap["ref"]
		# Ensure fields match snapshot (ref may have been mutated since capture)
		note.id = snap["id"]
		note.note = snap["note"]
		note.velocity = snap["velocity"]
		note.start_tick = snap["start_tick"]
		note.duration_ticks = snap["duration_ticks"]

		var existing: MidiNoteData = null
		for n in clip.midi_notes:
			if n.id == note.id:
				existing = n
				break

		if existing == null:
			clip.add_midi_note_data(note)
		else:
			if existing != note:
				# Same id, different object — copy fields onto the live object
				existing.note = note.note
				existing.velocity = note.velocity
				existing.start_tick = note.start_tick
				existing.duration_ticks = note.duration_ticks
				clip.update_midi_note(existing)
			else:
				clip.update_midi_note(note)
