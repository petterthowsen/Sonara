# Clip.gd
# Pure data container for audio/MIDI content
# Has NO position - that's handled by ClipInstance
# Lives in Project's clip pool, can be referenced by multiple ClipInstances

class_name Clip extends RefCounted

enum ClipType { AUDIO, MIDI }

# ============================================================================
# SIGNALS
# ============================================================================

signal midi_note_added(note: MidiNoteData)
signal midi_note_removed(note: MidiNoteData)
signal midi_note_changed(note: MidiNoteData)
signal clip_modified()  # Any change to clip data

# ============================================================================
# PROPERTIES
# ============================================================================

# Unique identification (GUID-style)
var id: String = ""  # Generated via UUID or similar

# Basic properties
var name: String = "Clip"
var type: ClipType = ClipType.MIDI
var color: Color = Color.from_string("#4A90E2", Color.BLUE)

# Content length (in ticks) - the "natural" length of the clip data
# ClipInstances can play shorter/longer via loop_enabled and duration
var content_length_ticks: int = 3840  # Default: 4 beats at PPQ=960

# MIDI data (for MIDI clips)
var midi_notes: Array[MidiNoteData] = []
var midi_events: Array[MidiEvent] = []  # CC, program change, etc.

# Audio data (for audio clips)
var audio_file_path: String = ""
var audio_sample_rate: int = 48000
var audio_channels: int = 2
var audio_samples: PackedFloat32Array = PackedFloat32Array()  # Raw PCM samples (interleaved)
var recorded_bpm: float = 120.0  # BPM this audio clip was originally recorded at
var audio_waveform: MultiResWaveform = null  # Cached multi-resolution waveforms

# Metadata
var created_date: float = 0  # Unix timestamp
var modified_date: float = 0

# Engine sync tracking
var _synced_to_engine: bool = false  # Whether this clip has been created on the engine

# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(clip_id: String = ""):
	"""Initialize clip with unique ID."""
	if clip_id.is_empty():
		# Generate UUID-like ID
		id = _generate_uuid()
	else:
		id = clip_id

	created_date = Time.get_unix_time_from_system()
	modified_date = created_date


func _generate_uuid() -> String:
	"""Generate a simple UUID-like identifier."""
	var timestamp = Time.get_unix_time_from_system()
	var random_part = "%08x" % randi()
	return "clip_%d_%s" % [timestamp, random_part]


# ============================================================================
# MIDI NOTE MANAGEMENT
# ============================================================================

func add_midi_note(note_id: int, note: int, velocity: int, start_tick: int, duration: int) -> MidiNoteData:
	"""Add a MIDI note to the clip. note_id must be unique (assigned by Project)."""
	var end_tick = start_tick + duration
	
	# Check for overlapping notes at the same pitch
	for existing_note in midi_notes:
		if existing_note.note == note:
			var existing_end_tick = existing_note.start_tick + existing_note.duration_ticks
			# Check if there's any time overlap
			if start_tick < existing_end_tick and end_tick > existing_note.start_tick:
				push_warning("[Clip] Rejecting overlapping note: pitch=%d, start=%d, duration=%d (conflicts with note id=%d at start=%d)" % 
					[note, start_tick, duration, existing_note.id, existing_note.start_tick])
				return null
	
	var midi_note = MidiNoteData.new()
	midi_note.id = note_id
	midi_note.note = note
	midi_note.velocity = velocity
	midi_note.start_tick = start_tick
	midi_note.duration_ticks = duration
	midi_notes.append(midi_note)

	# Ensure clip exists on engine (create if needed)
	_ensure_synced_to_engine()

	# Sync note to audio engine
	var osc_path = "/clip/%s/add_note" % id
	AudioEngineOSC.send(osc_path, [note_id, note, start_tick, duration, velocity])

	modified_date = Time.get_unix_time_from_system()
	midi_note_added.emit(midi_note)
	clip_modified.emit()

	return midi_note


func add_midi_note_data(note_data: MidiNoteData) -> MidiNoteData:
	"""Add a MIDI note from a MidiNoteData object. Convenience wrapper for add_midi_note."""
	return add_midi_note(
		note_data.id,
		note_data.note,
		note_data.velocity,
		note_data.start_tick,
		note_data.duration_ticks
	)


func remove_midi_note(midi_note: MidiNoteData) -> bool:
	"""Remove a MIDI note from the clip."""
	var idx = midi_notes.find(midi_note)
	if idx >= 0:
		midi_notes.remove_at(idx)

		# Sync to audio engine if clip exists on engine
		if _synced_to_engine:
			var osc_path = "/clip/%s/remove_note" % id
			AudioEngineOSC.send(osc_path, [midi_note.id])

		modified_date = Time.get_unix_time_from_system()
		midi_note_removed.emit(midi_note)
		clip_modified.emit()
		return true
	return false


func update_midi_note(midi_note: MidiNoteData) -> void:
	"""Notify that a MIDI note has been modified.
	
	Note: If the note is currently playing, the active voice won't change until
	playback is stopped and restarted. Updates only affect future Note On events.
	"""
	# Sync to audio engine if clip exists on engine
	if _synced_to_engine:
		var osc_path = "/clip/%s/update_note" % id
		AudioEngineOSC.send(osc_path, [midi_note.id, midi_note.note, midi_note.start_tick, midi_note.duration_ticks, midi_note.velocity])
		print("[Clip] Updated note %d in clip %s: pitch=%d start=%d dur=%d" % [midi_note.id, id, midi_note.note, midi_note.start_tick, midi_note.duration_ticks])
	else:
		push_warning("[Clip] Attempted to update note %d but clip %s not synced to engine!" % [midi_note.id, id])

	modified_date = Time.get_unix_time_from_system()
	midi_note_changed.emit(midi_note)
	clip_modified.emit()


func get_notes_at_tick(tick: int) -> Array[MidiNoteData]:
	"""Get all notes active at a specific tick."""
	var notes: Array[MidiNoteData] = []
	for note in midi_notes:
		if note.start_tick <= tick and note.get_end_tick() > tick:
			notes.append(note)
	return notes


func get_notes_in_range(start_tick: int, end_tick: int) -> Array[MidiNoteData]:
	"""Get all notes overlapping with a tick range."""
	var notes: Array[MidiNoteData] = []
	for note in midi_notes:
		if note.start_tick < end_tick and note.get_end_tick() > start_tick:
			notes.append(note)
	return notes


func cut_overlapping_notes_at_pitch(pitch: int, new_start_tick: int, new_end_tick: int, exclude_note_id: int = -1) -> Array[MidiNoteData]:
	"""
	Cut/trim existing notes at the given pitch that overlap with the new note range.
	Returns an array of notes that were modified or removed.
	
	Args:
		pitch: MIDI note number to check
		new_start_tick: Start tick of the new/moved note
		new_end_tick: End tick of the new/moved note
		exclude_note_id: Note ID to exclude from comparison (to avoid comparing a note against itself)
	
	Logic:
	- If existing note fully contains the new note -> split into two notes (before and after)
	- If existing note starts before new note -> trim its end
	- If existing note ends after new note -> trim its start
	- If existing note is fully contained -> remove it
	"""
	var affected_notes: Array[MidiNoteData] = []
	var notes_to_add: Array[MidiNoteData] = []  # New notes created from splits
	
	# Find all overlapping notes at the same pitch
	var i = 0
	while i < midi_notes.size():
		var existing_note = midi_notes[i]
		var existing_end_tick = existing_note.get_end_tick()
		
		# Skip the note we're comparing against itself
		if existing_note.id == exclude_note_id:
			i += 1
			continue
		
		# Only process notes at the same pitch
		if existing_note.note != pitch:
			i += 1
			continue
		
		# Check if there's any time overlap
		if new_start_tick >= existing_end_tick or new_end_tick <= existing_note.start_tick:
			i += 1
			continue
		
		# This note overlaps - handle it
		affected_notes.append(existing_note)
		
		# Case 1: Existing note fully contains the new note -> split into two
		if existing_note.start_tick < new_start_tick and existing_end_tick > new_end_tick:
			print("[Clip] Splitting note %d (start=%d, end=%d) around new note (start=%d, end=%d)" % 
				[existing_note.id, existing_note.start_tick, existing_end_tick, new_start_tick, new_end_tick])
			
			# Create the "after" portion (keep original ID for the first part)
			var after_note = MidiNoteData.new()
			if Sonara and Sonara.editor and Sonara.editor.project:
				after_note.id = Sonara.editor.project.next_note_id
				Sonara.editor.project.next_note_id += 1
			after_note.note = existing_note.note
			after_note.velocity = existing_note.velocity
			after_note.start_tick = new_end_tick
			after_note.duration_ticks = existing_end_tick - new_end_tick
			notes_to_add.append(after_note)
			
			# Trim the existing note to end at new note start
			existing_note.duration_ticks = new_start_tick - existing_note.start_tick
			update_midi_note(existing_note)
		
		# Case 2: Existing note starts before new note -> trim its end
		elif existing_note.start_tick < new_start_tick:
			print("[Clip] Trimming end of note %d (was end=%d, now end=%d)" % 
				[existing_note.id, existing_end_tick, new_start_tick])
			existing_note.duration_ticks = new_start_tick - existing_note.start_tick
			update_midi_note(existing_note)
		
		# Case 3: Existing note ends after new note -> trim its start
		elif existing_end_tick > new_end_tick:
			print("[Clip] Trimming start of note %d (was start=%d, now start=%d)" % 
				[existing_note.id, existing_note.start_tick, new_end_tick])
			existing_note.start_tick = new_end_tick
			existing_note.duration_ticks = existing_end_tick - new_end_tick
			update_midi_note(existing_note)
		
		# Case 4: Existing note is fully contained within new note -> remove it
		else:
			print("[Clip] Removing fully overlapped note %d" % existing_note.id)
			midi_notes.remove_at(i)
			if _synced_to_engine:
				var osc_path = "/clip/%s/remove_note" % id
				AudioEngineOSC.send(osc_path, [existing_note.id])
			midi_note_removed.emit(existing_note)
			continue  # Don't increment i, we removed an element
		
		i += 1
	
	# Add any new notes created from splits
	for new_note in notes_to_add:
		midi_notes.append(new_note)
		if _synced_to_engine:
			var osc_path = "/clip/%s/add_note" % id
			AudioEngineOSC.send(osc_path, [new_note.id, new_note.note, new_note.start_tick, new_note.duration_ticks, new_note.velocity])
		midi_note_added.emit(new_note)
	
	if not affected_notes.is_empty():
		modified_date = Time.get_unix_time_from_system()
		clip_modified.emit()
	
	return affected_notes


func get_content_length() -> int:
	"""Calculate actual content length based on MIDI notes or audio."""
	if type == ClipType.MIDI and not midi_notes.is_empty():
		var max_end = 0
		for note in midi_notes:
			max_end = max(max_end, note.get_end_tick())
		return max_end

	return content_length_ticks


# ============================================================================
# AUDIO PROCESSING
# ============================================================================

func precompute_waveforms() -> void:
	"""
	Generate waveform peak data at multiple resolutions.
	Call this after loading audio samples to cache waveforms for efficient rendering.
	"""
	if type != ClipType.AUDIO or audio_samples.is_empty():
		return

	if audio_waveform == null:
		audio_waveform = MultiResWaveform.new()

	audio_waveform.precompute_from_audio(audio_samples, audio_sample_rate, audio_channels)
	modified_date = Time.get_unix_time_from_system()
	clip_modified.emit()


# ============================================================================
# CONVENIENCE
# ============================================================================
func find_highest_note() -> int:
	var highest = 60
	for note in midi_notes:
		if note.note > highest:
			highest = note.note
	return highest


func find_lowest_note() -> int:
	var lowest = 60
	for note in midi_notes:
		if note.note < lowest:
			lowest = note.note
	return lowest


func find_average_note() -> int:
	var total_notes = 0
	var total_midi_sum = 0
	for note in midi_notes:
		total_midi_sum += note.note
		total_notes += 1
	@warning_ignore("integer_division")
	return total_midi_sum / total_notes


# ============================================================================
# SERIALIZATION
# ============================================================================

func to_json() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"type": ClipType.keys()[type],
		"color": color.to_html(),
		"content_length_ticks": content_length_ticks,
		"midi_notes": _serialize_midi_notes(),
		"midi_events": _serialize_midi_events(),
		"audio_file_path": audio_file_path,
		"audio_sample_rate": audio_sample_rate,
		"audio_channels": audio_channels,
		"recorded_bpm": recorded_bpm,
		"created_date": created_date,
		"modified_date": modified_date
	}


static func from_json(data: Dictionary) -> Clip:
	var clip_id = data.get("id", "")
	var clip = Clip.new(clip_id)

	clip.name = data.get("name", "Clip")

	# Parse clip type
	var type_str = data.get("type", "MIDI")
	clip.type = ClipType.get(type_str) if ClipType.has(type_str) else ClipType.MIDI

	clip.color = Color.from_string(data.get("color", "#4A90E2"), Color.BLUE)
	clip.content_length_ticks = data.get("content_length_ticks", 3840)
	clip._deserialize_midi_notes(data.get("midi_notes", []))
	clip._deserialize_midi_events(data.get("midi_events", []))
	clip.audio_file_path = data.get("audio_file_path", "")
	clip.audio_sample_rate = data.get("audio_sample_rate", 48000)
	clip.audio_channels = data.get("audio_channels", 2)
	clip.recorded_bpm = data.get("recorded_bpm", 120.0)
	clip.created_date = data.get("created_date", 0)
	clip.modified_date = data.get("modified_date", 0)

	return clip


func _serialize_midi_notes() -> Array:
	var serialized = []
	for note in midi_notes:
		serialized.append(note.to_json())
	return serialized


func _serialize_midi_events() -> Array:
	var serialized = []
	for event in midi_events:
		serialized.append(event.to_json())
	return serialized


func _deserialize_midi_notes(data: Array) -> void:
	midi_notes.clear()
	for note_data in data:
		if note_data is Dictionary:
			midi_notes.append(MidiNoteData.from_json(note_data))


func _deserialize_midi_events(data: Array) -> void:
	midi_events.clear()
	for event_data in data:
		if event_data is Dictionary:
			midi_events.append(MidiEvent.from_json(event_data))


# ============================================================================
# ENGINE SYNC
# ============================================================================

## Ensure this clip has been created on the audio engine
func _ensure_synced_to_engine() -> void:
	"""Create clip on engine if it doesn't exist yet."""
	if _synced_to_engine:
		return  # Already synced, don't send create again

	var clip_type_str = "midi" if type == Clip.ClipType.MIDI else "audio"
	AudioEngineOSC.send("/clip/create", [id, clip_type_str, name])
	_synced_to_engine = true
	print("[Clip] Created clip %s on engine" % id)
