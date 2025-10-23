class_name NoteSelection extends RefCounted

## Represents a selection of MIDI notes within a time range
## Used for copy/paste, cut, duplicate operations
## Stores notes with positions relative to start_tick for easy repositioning

# Time range of the selection (in ticks)
var start_tick: int = 0
var end_tick: int = 0

# Duration of the selection in ticks
var duration_ticks: int:
	get:
		return end_tick - start_tick

# Notes in the selection (stored with relative positions)
var notes: Array[MidiNoteData] = []


func _init(p_start_tick: int = 0, p_end_tick: int = 0, p_notes: Array[MidiNoteData] = []):
	start_tick = p_start_tick
	end_tick = p_end_tick
	notes = p_notes


## Create a NoteSelection from an array of VisualNote instances
static func from_visual_notes(visual_notes: Array[VisualNote]) -> NoteSelection:
	if visual_notes.is_empty():
		return NoteSelection.new()
	
	# Find the bounding box of all selected notes
	var min_tick: int = 999999999
	var max_tick: int = 0
	
	for visual_note in visual_notes:
		if not visual_note.midi_note_data:
			continue
		var note_data = visual_note.midi_note_data
		min_tick = min(min_tick, note_data.start_tick)
		max_tick = max(max_tick, note_data.start_tick + note_data.duration_ticks)
	
	# Create relative copies of all notes
	var relative_notes: Array[MidiNoteData] = []
	for visual_note in visual_notes:
		if not visual_note.midi_note_data:
			continue
		var note_data = visual_note.midi_note_data
		
		# Create a copy with position relative to start_tick
		var relative_note = MidiNoteData.new()
		relative_note.id = -1  # Will be assigned when pasted
		relative_note.note = note_data.note
		relative_note.velocity = note_data.velocity
		relative_note.start_tick = note_data.start_tick - min_tick  # Relative position
		relative_note.duration_ticks = note_data.duration_ticks
		
		relative_notes.append(relative_note)
	
	return NoteSelection.new(min_tick, max_tick, relative_notes)


## Create a NoteSelection from an array of VisualNote instances with explicit time range
## This preserves the actual selection box time range, not just the note bounding box
static func from_visual_notes_with_range(visual_notes: Array[VisualNote], p_start_tick: int, p_end_tick: int) -> NoteSelection:
	if visual_notes.is_empty():
		return NoteSelection.new(p_start_tick, p_end_tick, [])
	
	# Create relative copies of all notes (relative to the selection start, not note bounding box)
	var relative_notes: Array[MidiNoteData] = []
	for visual_note in visual_notes:
		if not is_instance_valid(visual_note) or not visual_note.midi_note_data:
			continue
		var note_data = visual_note.midi_note_data
		
		# Create a copy with position relative to selection start_tick
		var relative_note = MidiNoteData.new()
		relative_note.id = -1  # Will be assigned when pasted
		relative_note.note = note_data.note
		relative_note.velocity = note_data.velocity
		relative_note.start_tick = note_data.start_tick - p_start_tick  # Relative to selection start
		relative_note.duration_ticks = note_data.duration_ticks
		
		relative_notes.append(relative_note)
	
	return NoteSelection.new(p_start_tick, p_end_tick, relative_notes)


## Create a NoteSelection from an array of MidiNoteData instances
static func from_midi_notes(midi_notes: Array[MidiNoteData]) -> NoteSelection:
	if midi_notes.is_empty():
		return NoteSelection.new()
	
	# Find the bounding box of all selected notes
	var min_tick: int = 999999999
	var max_tick: int = 0
	
	for note_data in midi_notes:
		min_tick = min(min_tick, note_data.start_tick)
		max_tick = max(max_tick, note_data.start_tick + note_data.duration_ticks)
	
	# Create relative copies of all notes
	var relative_notes: Array[MidiNoteData] = []
	for note_data in midi_notes:
		# Create a copy with position relative to start_tick
		var relative_note = MidiNoteData.new()
		relative_note.id = -1  # Will be assigned when pasted
		relative_note.note = note_data.note
		relative_note.velocity = note_data.velocity
		relative_note.start_tick = note_data.start_tick - min_tick  # Relative position
		relative_note.duration_ticks = note_data.duration_ticks
		
		relative_notes.append(relative_note)
	
	return NoteSelection.new(min_tick, max_tick, relative_notes)


## Get notes positioned at a new start_tick
## Returns an array of MidiNoteData instances ready to be added to a clip
func get_notes_at_position(new_start_tick: int) -> Array[MidiNoteData]:
	var positioned_notes: Array[MidiNoteData] = []
	
	for note in notes:
		var new_note = MidiNoteData.new()
		new_note.id = -1  # Will be assigned by caller
		new_note.note = note.note
		new_note.velocity = note.velocity
		new_note.start_tick = new_start_tick + note.start_tick  # Add new offset
		new_note.duration_ticks = note.duration_ticks
		
		positioned_notes.append(new_note)
	
	return positioned_notes


## Check if selection is empty
func is_empty() -> bool:
	return notes.is_empty()


## Get a duplicate of this selection (deep copy)
func duplicate() -> NoteSelection:
	var dup_notes: Array[MidiNoteData] = []
	for note in notes:
		var dup_note = MidiNoteData.new()
		dup_note.id = note.id
		dup_note.note = note.note
		dup_note.velocity = note.velocity
		dup_note.start_tick = note.start_tick
		dup_note.duration_ticks = note.duration_ticks
		dup_notes.append(dup_note)
	
	return NoteSelection.new(start_tick, end_tick, dup_notes)


## Debug string representation
func get_description() -> String:
	return "NoteSelection(start=%d, end=%d, duration=%d, notes=%d)" % [
		start_tick, end_tick, duration_ticks, notes.size()
	]
