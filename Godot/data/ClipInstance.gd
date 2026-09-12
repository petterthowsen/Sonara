# ClipInstance.gd
# Represents a Clip placed on a Track at a specific position
# References a Clip (from Project's clip pool) but adds position and playback parameters
# Multiple ClipInstances can reference the same Clip

class_name ClipInstance extends RefCounted

# ============================================================================
# SIGNALS
# ============================================================================

signal position_changed(new_start_ticks: int)
signal duration_changed(new_duration_ticks: int)
signal loop_changed(enabled: bool)
signal instance_modified()  # Any change to instance properties

# ============================================================================
# PROPERTIES
# ============================================================================

# Unique identification (GUID-style)
var id: String = ""  # Instance ID

# Clip reference
var clip_id: String = ""  # References a Clip in Project's clip pool
var clip: Clip = null  # Cached reference (set by Track when added)

# Track reference - ClipInstances ALWAYS belong to a track
var track: Track = null  # Parent track (set by Track when added)

# Timeline position
var start_ticks: int = 0  # Position on timeline
var duration_ticks: int = 3840  # How long this instance plays (can differ from clip length)

# Clip content offset (where in the clip's content does this instance start reading from)
var clip_offset: int = 0  # Offset in ticks into the clip's content (allows trimming from left edge)

# Playback parameters
var loop_enabled: bool = false  # Whether to loop the clip content (default: disabled)
var loop_start_ticks: int = 0  # Where in the clip to start looping (offset into clip data)
var loop_length_ticks: int = 3840  # Length of loop region

# Instance-specific overrides (don't affect the source Clip)
var transpose: int = 0  # Semitones to transpose MIDI (for MIDI clips)
var gain_offset: float = 0.0  # dB adjustment for this instance
var muted: bool = false  # Mute this instance
var color_override: Color = Color.TRANSPARENT  # If not transparent, overrides clip color

# Processing
var fade_in_ticks: int = 0
var fade_out_ticks: int = 0

# ============================================================================
# LIFECYCLE
# ============================================================================

func _init(instance_id: String = "", ref_clip_id: String = ""):
	"""Initialize clip instance with unique ID and clip reference."""
	if instance_id.is_empty():
		id = _generate_uuid()
	else:
		id = instance_id

	clip_id = ref_clip_id


func _generate_uuid() -> String:
	"""Generate a simple UUID-like identifier."""
	var timestamp = Time.get_unix_time_from_system()
	var random_part = "%08x" % randi()
	return "inst_%d_%s" % [timestamp, random_part]


# ============================================================================
# POSITION AND PLAYBACK
# ============================================================================

func set_position(ticks: int) -> void:
	"""Set the start position on the timeline."""
	if start_ticks != ticks:
		start_ticks = ticks

		# Sync to audio engine if we have track reference
		if track and track._is_connected:
			AudioEngineOSC.send("/track/%d/instance/%s/set_position" % [track.id, id], [start_ticks, duration_ticks, clip_offset])

		position_changed.emit(start_ticks)
		instance_modified.emit()


func set_duration(ticks: int) -> void:
	"""Set the playback duration."""
	if duration_ticks != ticks:
		duration_ticks = max(1, ticks)  # Minimum 1 tick

		# Sync to audio engine if we have track reference
		if track and track._is_connected:
			AudioEngineOSC.send("/track/%d/instance/%s/set_position" % [track.id, id], [start_ticks, duration_ticks, clip_offset])

		duration_changed.emit(duration_ticks)
		instance_modified.emit()


func set_clip_offset(offset: int) -> void:
	"""Set the clip content offset (where to start reading from clip)."""
	if clip_offset != offset:
		clip_offset = max(0, offset)  # Minimum 0 ticks

		# Sync to audio engine if we have track reference
		if track and track._is_connected:
			AudioEngineOSC.send("/track/%d/instance/%s/set_position" % [track.id, id], [start_ticks, duration_ticks, clip_offset])

		instance_modified.emit()


func set_loop_enabled(enabled: bool) -> void:
	"""Enable/disable looping."""
	if loop_enabled != enabled:
		loop_enabled = enabled
		loop_changed.emit(loop_enabled)
		instance_modified.emit()


## Copy instance-specific playback overrides from `other` (not identity or position).
func copy_overrides_from(other: ClipInstance) -> void:
	if other == null:
		return
	clip_offset = other.clip_offset
	loop_enabled = other.loop_enabled
	loop_start_ticks = other.loop_start_ticks
	loop_length_ticks = other.loop_length_ticks
	transpose = other.transpose
	gain_offset = other.gain_offset
	muted = other.muted
	fade_in_ticks = other.fade_in_ticks
	fade_out_ticks = other.fade_out_ticks
	color_override = other.color_override


func get_end_ticks() -> int:
	"""Get the end position on the timeline."""
	return start_ticks + duration_ticks


func get_effective_color() -> Color:
	"""Get the color to display (override or clip's color)."""
	if color_override.a > 0.0:
		return color_override
	if clip:
		return clip.color
	return Color.WHITE


# ============================================================================
# MIDI NOTE RESOLUTION
# ============================================================================

func get_midi_notes_for_playback(project_start_tick: int, project_end_tick: int) -> Array[Dictionary]:
	"""
	Get MIDI notes from the referenced clip, adjusted for this instance's position and settings.
	Returns array of dictionaries with absolute timeline positions and transposition applied.
	Applies clip_offset to only play a portion of the clip.
	"""
	if not clip or clip.type != Clip.ClipType.MIDI:
		return []

	var notes: Array[Dictionary] = []

	# Calculate which part of the instance is being played
	var instance_start = start_ticks
	var instance_end = get_end_ticks()

	# Clip to requested range
	var play_start = max(project_start_tick, instance_start)
	var play_end = min(project_end_tick, instance_end)

	if play_start >= play_end:
		return []  # Instance not in requested range

	# Convert to local instance time (relative to instance start)
	var local_start = play_start - instance_start
	var local_end = play_end - instance_start

	# Get notes from clip, applying clip_offset and loop logic
	for midi_note in clip.midi_notes:
		# Apply clip_offset: only consider notes that are at or after the offset
		var note_start = midi_note.start_tick - clip_offset
		var note_end = midi_note.get_end_tick() - clip_offset
		
		# Skip notes that are before the clip_offset
		if note_end <= 0:
			continue

		# Handle looping
		if loop_enabled:
			# Calculate which loop iteration(s) this note appears in
			var loop_len = loop_length_ticks if loop_length_ticks > 0 else clip.content_length_ticks
			var iterations = ceili(float(duration_ticks) / float(loop_len))

			for i in range(iterations):
				var offset = i * loop_len
				var instance_note_start = note_start + offset
				var instance_note_end = note_end + offset

				# Check if this iteration's note is in range
				if instance_note_start < local_end and instance_note_end > local_start:
					# Add note with absolute timeline position
					notes.append({
						"note": midi_note.note + transpose,
						"velocity": midi_note.velocity,
						"start_ticks": instance_start + instance_note_start,
						"duration_ticks": midi_note.duration_ticks,
						"engine_note_id": midi_note.engine_note_id
					})
		else:
			# No looping - just check if note is in range
			if note_start < local_end and note_end > local_start:
				notes.append({
					"note": midi_note.note + transpose,
					"velocity": midi_note.velocity,
					"start_ticks": instance_start + note_start,
					"duration_ticks": midi_note.duration_ticks,
					"engine_note_id": midi_note.engine_note_id
				})

	return notes


# ============================================================================
# SERIALIZATION
# ============================================================================

func to_json() -> Dictionary:
	return {
		"id": id,
		"clip_id": clip_id,
		"start_ticks": start_ticks,
		"duration_ticks": duration_ticks,
		"clip_offset": clip_offset,
		"loop_enabled": loop_enabled,
		"loop_start_ticks": loop_start_ticks,
		"loop_length_ticks": loop_length_ticks,
		"transpose": transpose,
		"gain_offset": gain_offset,
		"muted": muted,
		"color_override": color_override.to_html() if color_override.a > 0.0 else "",
		"fade_in_ticks": fade_in_ticks,
		"fade_out_ticks": fade_out_ticks
	}


static func from_json(data: Dictionary) -> ClipInstance:
	var instance_id = data.get("id", "")
	var ref_clip_id = data.get("clip_id", "")
	var instance = ClipInstance.new(instance_id, ref_clip_id)

	instance.start_ticks = data.get("start_ticks", 0)
	instance.duration_ticks = data.get("duration_ticks", 3840)
	instance.clip_offset = data.get("clip_offset", 0)
	instance.loop_enabled = data.get("loop_enabled", false)
	instance.loop_start_ticks = data.get("loop_start_ticks", 0)
	instance.loop_length_ticks = data.get("loop_length_ticks", 3840)
	instance.transpose = data.get("transpose", 0)
	instance.gain_offset = data.get("gain_offset", 0.0)
	instance.muted = data.get("muted", false)

	var color_str = data.get("color_override", "")
	if not color_str.is_empty():
		instance.color_override = Color.from_string(color_str, Color.TRANSPARENT)

	instance.fade_in_ticks = data.get("fade_in_ticks", 0)
	instance.fade_out_ticks = data.get("fade_out_ticks", 0)

	return instance
