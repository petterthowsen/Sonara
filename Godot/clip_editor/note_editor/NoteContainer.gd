## Base container for rendering and positioning MIDI notes.
## Handles visual note lifecycle, coordinate conversion, and layout.
class_name NoteContainer extends Container

static var logger := Log.make("NoteContainer")

#=========================================================
# CONSTANTS
#=========================================================
# MIDI range - use Midi singleton constants
const MIDI_MIN: int = Midi.MIDI_MIN    # C-2 (MIDI 0)
const MIDI_MAX: int = Midi.MIDI_MAX    # G9 (MIDI 127)
const MIDI_RANGE: int = MIDI_MAX - MIDI_MIN + 1

# VisualNote scene
const visual_note_scene = preload("res://clip_editor/VisualNote.tscn")


#=========================================================
# PROPERTIES
# These must be set by the parent ClipEditor/MidiEditor
#=========================================================
@export var note_height := 20.0:
	set(nh):
		if note_height != nh:
			note_height = nh
			# Notify parent ScrollContainer that our size changed
			# and queue relayout
			update_minimum_size()
			queue_sort()

# Horizontal scrolling configuration
@export var min_width_bars: int = 8		# minimum width in bars
@export var extra_width_bars: int = 4		# extra width to the right of the rightmost note

# Grid helper which must be set by the parent ClipEditor/MidiEditor
var grid_helper: GridHelper = null:
	set = set_grid_helper


func set_grid_helper(gh: GridHelper) -> void:
	# Disconnect from old grid_helper if it exists
	if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
		grid_helper.changed.disconnect(_on_grid_helper_changed)
	
	grid_helper = gh
	
	# Connect to new grid_helper's changed signal
	if grid_helper:
		grid_helper.changed.connect(_on_grid_helper_changed)
	
	_update_note_positions()
	update_container_width()


func _on_grid_helper_changed() -> void:
	"""Called when grid_helper properties change (zoom, scroll, time signature, etc.)"""
	_update_note_positions()
	update_container_width()


# Should be set to track or clip color
var note_color = Color(0.3, 0.6, 0.9):
	set(nc):
		if note_color != nc:
			note_color = nc
			# Notify all visual notes to update their color
			for node in get_children():
				if node is VisualNote:
					node.set_color(note_color)


# Should be set by parent to support infinite scrolling
var horizonal_scroll_position: float = 0.0:
	set(value):
		horizonal_scroll_position = value
		update_container_width()


# Position offset for song-relative positioning in track-mode
# Set to clip_instance.start_ticks in track-mode, 0 in clip-mode
var position_offset_ticks: int = 0:
	set(value):
		if position_offset_ticks != value:
			position_offset_ticks = value
			_update_note_positions()
			update_container_width()


# SINGLE-CLIP MODE: The clip instance that opened this editor (for context, not edited directly)
var clip_instance: ClipInstance = null

# Convenience to get the Clip of clip_instance
var clip: Clip:
	get:
		return clip_instance.clip if clip_instance else null
	set(clip):
		pass

# MULTI-CLIP MODE: Multiple clip instances for track-mode
var clip_instances: Array[ClipInstance] = []
var track: Track = null  # Track that owns these clips
var multi_clip_mode: bool = false

# Container for notes
# SINGLE-CLIP MODE: note_id -> VisualNote
# MULTI-CLIP MODE: note_id -> {visual_note: VisualNote, clip_instance: ClipInstance}
var visual_notes_by_id: Dictionary = {}


func unbind():
	# Disconnect from clip signals (single-clip mode)
	if clip:
		if clip.midi_note_added.is_connected(_on_clip_note_added):
			clip.midi_note_added.disconnect(_on_clip_note_added)
		if clip.midi_note_removed.is_connected(_on_clip_note_removed):
			clip.midi_note_removed.disconnect(_on_clip_note_removed)
		if clip.midi_note_changed.is_connected(_on_clip_note_changed):
			clip.midi_note_changed.disconnect(_on_clip_note_changed)

	# Disconnect from all clips (multi-clip mode)
	for ci in clip_instances:
		if ci and ci.clip:
			var c = ci.clip
			if c.midi_note_added.is_connected(_on_clip_note_added):
				c.midi_note_added.disconnect(_on_clip_note_added)
			if c.midi_note_removed.is_connected(_on_clip_note_removed):
				c.midi_note_removed.disconnect(_on_clip_note_removed)
			if c.midi_note_changed.is_connected(_on_clip_note_changed):
				c.midi_note_changed.disconnect(_on_clip_note_changed)

	# Disconnect from grid_helper if connected
	if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
		grid_helper.changed.disconnect(_on_grid_helper_changed)

	# Clear all visual notes
	for node in get_children():
		node.queue_free()

	visual_notes_by_id.clear()
	clip_instance = null
	clip_instances.clear()
	track = null
	multi_clip_mode = false


func bind(ci : ClipInstance):
	"""Bind to single clip instance (clip-mode)."""
	logger.info("bind called (single-clip mode)")
	logger.info("  - clip_instance: ", ci)
	logger.info("  - clip_id: ", ci.clip_id if ci else "null")

	if clip_instance != ci:
		if clip_instance or multi_clip_mode:
			unbind()

		multi_clip_mode = false
		clip_instance = ci

		# Connect to clip signals for reactive updates
		if clip:
			clip.midi_note_added.connect(_on_clip_note_added)
			clip.midi_note_removed.connect(_on_clip_note_removed)
			clip.midi_note_changed.connect(_on_clip_note_changed)

		_load_clip_notes()
		queue_sort()
		update_container_width()


func bind_to_clips(instances: Array[ClipInstance], owner_track: Track):
	"""Bind to multiple clip instances (track-mode)."""
	logger.info("bind_to_clips called (multi-clip mode)")
	logger.info("  - %d clip instances on track: %s" % [instances.size(), owner_track.name if owner_track else "null"])

	# Unbind previous state
	if clip_instance or multi_clip_mode:
		unbind()

	multi_clip_mode = true
	clip_instances = instances
	track = owner_track

	# Connect to all clips' signals for reactive updates
	for ci in clip_instances:
		if ci and ci.clip:
			var c = ci.clip
			c.midi_note_added.connect(_on_clip_note_added)
			c.midi_note_removed.connect(_on_clip_note_removed)
			c.midi_note_changed.connect(_on_clip_note_changed)

	_load_clip_notes()
	queue_sort()
	update_container_width()


# ============================================================================
# Visual Note Placement
# ============================================================================
func _get_minimum_size() -> Vector2:
	# Total height for 128 MIDI notes (0-127)
	var total_height = 128 * note_height
	return Vector2(0, total_height)


func _notification(what):
	if what == NOTIFICATION_SORT_CHILDREN:
		_update_note_positions()


func _update_note_positions() -> void:
	"""Update positions of all note instances based on current zoom and scroll."""
	if not grid_helper:
		return

	for note in get_children():
		if note is VisualNote and note.midi_note_data:
			_update_single_note_position(note)


func _update_single_note_position(note: VisualNote) -> void:
	"""Update the position and size of a single visual note."""
	if not note.midi_note_data:
		return

	var note_data = note.midi_note_data

	# Calculate position offset based on mode
	var offset_ticks = 0
	if multi_clip_mode:
		# MULTI-CLIP MODE: Get clip instance for this note and use its start_ticks
		var entry = visual_notes_by_id.get(note_data.id)
		if entry and entry is Dictionary and entry.has("clip_instance"):
			var ci = entry["clip_instance"] as ClipInstance
			if ci:
				offset_ticks = ci.start_ticks
	else:
		# SINGLE-CLIP MODE: Use position_offset_ticks (usually 0 in clip-mode)
		offset_ticks = position_offset_ticks

	# Apply position offset for song-relative positioning
	var note_x = ticks_to_pixels(note_data.start_tick + offset_ticks)
	var note_y = note_to_y(note_data.note)
	var note_width = ticks_to_pixels(note_data.duration_ticks)

	note.position = Vector2(note_x, note_y)
	note.size = Vector2(note_width, note_height)
	note.update_label_visibility(note_height)


func get_note_song_position(note: VisualNote) -> Dictionary:
	"""Get the song-relative position for a note (accounts for clip offset in track-mode).
	
	Returns a dictionary with 'start_tick' and 'end_tick' keys.
	This is used by NoteSelectionManager to work in the correct coordinate space.
	"""
	if not note or not note.midi_note_data:
		return {"start_tick": 0, "end_tick": 0}
	
	var note_data = note.midi_note_data
	var offset_ticks = 0
	
	if multi_clip_mode:
		# MULTI-CLIP MODE: Get clip instance for this note and use its start_ticks
		var entry = visual_notes_by_id.get(note_data.id)
		if entry and entry is Dictionary and entry.has("clip_instance"):
			var ci = entry["clip_instance"] as ClipInstance
			if ci:
				offset_ticks = ci.start_ticks
	else:
		# SINGLE-CLIP MODE: Use position_offset_ticks (0 in clip-mode, set in track-mode)
		offset_ticks = position_offset_ticks
	
	return {
		"start_tick": note_data.start_tick + offset_ticks,
		"end_tick": note_data.start_tick + note_data.duration_ticks + offset_ticks
	}


# TODO: move this to NoteEditor
func update_container_width() -> void:
	"""Update the container's minimum width for infinite scrolling."""
	var h_scroll = get_parent()
	if not h_scroll is ScrollContainer:
		return

	# Calculate minimum visible width
	var ppq = grid_helper.ppq if grid_helper else 960
	var beats_per_bar = grid_helper.time_numerator if grid_helper else 4
	var min_width_ticks = min_width_bars * beats_per_bar * ppq
	var min_width_pixels = ticks_to_pixels(min_width_ticks)

	# Get current scroll position and viewport width
	var scroll_pos = horizonal_scroll_position
	var viewport_width = get_parent().size.x

	# Find rightmost note position
	var rightmost_tick = 0
	for note in get_children():
		if note is VisualNote and note.midi_note_data:
			var note_end = note.midi_note_data.start_tick + note.midi_note_data.duration_ticks
			rightmost_tick = max(rightmost_tick, note_end)
	var rightmost_pixels = ticks_to_pixels(rightmost_tick)

	# Calculate required width
	var extra_ticks = extra_width_bars * beats_per_bar * ppq
	var extra_pixels = ticks_to_pixels(extra_ticks)

	var width_from_scroll = scroll_pos + viewport_width + extra_pixels
	var width_from_content = rightmost_pixels + extra_pixels
	var required_width = max(min_width_pixels, width_from_scroll, width_from_content)

	custom_minimum_size.x = required_width


func _load_clip_notes() -> void:
	logger.info("_load_clip_notes called")

	visual_notes_by_id.clear()

	if multi_clip_mode:
		# MULTI-CLIP MODE: Load notes from all clip instances
		_load_notes_from_multiple_clips()
	else:
		# SINGLE-CLIP MODE: Load notes from single clip
		_load_notes_from_single_clip()

	# Update all note positions
	_update_note_positions()
	update_container_width()


func _load_notes_from_single_clip() -> void:
	"""Load notes from single clip instance (clip-mode)."""
	if not clip:
		logger.error("No clip to load!")
		return

	var project = Sonara.editor.project

	for note_data in clip.midi_notes:
		# Assign note ID if not already assigned
		if note_data.id < 0:
			note_data.id = project.next_note_id
			project.next_note_id += 1

		# Create visual note instance
		var note_instance = visual_note_scene.instantiate()
		add_child(note_instance)
		note_instance.bind_to_note(note_data)

		# Set color from track
		note_instance.set_color(note_color)

		# Track in dictionary (single-clip mode: just the VisualNote)
		visual_notes_by_id[note_data.id] = note_instance

	logger.info("Loaded %d notes from clip '%s'" % [clip.midi_notes.size(), clip.name])


func _load_notes_from_multiple_clips() -> void:
	"""Load notes from multiple clip instances (track-mode)."""
	if clip_instances.is_empty():
		logger.warn("No clip instances to load!")
		return

	var project = Sonara.editor.project
	var total_notes = 0

	for ci in clip_instances:
		if not ci or not ci.clip:
			continue

		for note_data in ci.clip.midi_notes:
			# Assign note ID if not already assigned
			if note_data.id < 0:
				note_data.id = project.next_note_id
				project.next_note_id += 1

			# Create visual note instance
			var note_instance = visual_note_scene.instantiate()
			add_child(note_instance)
			note_instance.bind_to_note(note_data)

			# Set color from track
			note_instance.set_color(note_color)

			# Track in dictionary (multi-clip mode: {visual_note, clip_instance})
			visual_notes_by_id[note_data.id] = {
				"visual_note": note_instance,
				"clip_instance": ci
			}

			total_notes += 1

	logger.info("Loaded %d notes from %d clip instances on track '%s'" % [total_notes, clip_instances.size(), track.name if track else "null"])


# ============================================================================
# REACTIVE SIGNAL HANDLERS - Clip data changes
# ============================================================================
func _on_clip_note_added(note_data: MidiNoteData) -> void:
	"""Handle when a note is added to the clip (reactive)."""
	if note_data.id in visual_notes_by_id:
		push_warning("[NoteContainer] Note %d already has a visual representation" % note_data.id)
		return

	# Create visual note instance
	var note_instance = visual_note_scene.instantiate()
	add_child(note_instance)
	note_instance.bind_to_note(note_data)

	# Set color from track
	note_instance.set_color(note_color)

	# Track in dictionary (with clip reference in multi-clip mode)
	if multi_clip_mode:
		# Find which clip this note belongs to
		var owner_clip_instance = _find_clip_instance_for_note(note_data)
		if owner_clip_instance:
			visual_notes_by_id[note_data.id] = {
				"visual_note": note_instance,
				"clip_instance": owner_clip_instance
			}
		else:
			push_warning("[NoteContainer] Could not find clip instance for note %d" % note_data.id)
	else:
		visual_notes_by_id[note_data.id] = note_instance

	# Update position
	_update_single_note_position(note_instance)
	update_container_width()

	logger.info("Reactively added visual note %d" % note_data.id)


func _on_clip_note_removed(note_data: MidiNoteData) -> void:
	"""Handle when a note is removed from the clip (reactive)."""
	if note_data.id not in visual_notes_by_id:
		push_warning("[NoteContainer] Cannot remove visual note %d - not found" % note_data.id)
		return

	# Get visual note (handling both single-clip and multi-clip mode)
	var note_instance: VisualNote
	if multi_clip_mode:
		var entry = visual_notes_by_id[note_data.id]
		if entry is Dictionary and entry.has("visual_note"):
			note_instance = entry["visual_note"]
	else:
		note_instance = visual_notes_by_id[note_data.id]

	# Remove from dictionary and scene
	visual_notes_by_id.erase(note_data.id)
	if note_instance:
		note_instance.queue_free()
	update_container_width()

	logger.info("Reactively removed visual note %d" % note_data.id)


func _on_clip_note_changed(note_data: MidiNoteData) -> void:
	"""Handle when a note is modified in the clip (reactive)."""
	if note_data.id not in visual_notes_by_id:
		push_warning("[NoteContainer] Cannot update visual note %d - not found" % note_data.id)
		return

	# Get visual note (handling both single-clip and multi-clip mode)
	var note_instance: VisualNote
	if multi_clip_mode:
		var entry = visual_notes_by_id[note_data.id]
		if entry is Dictionary and entry.has("visual_note"):
			note_instance = entry["visual_note"]
	else:
		note_instance = visual_notes_by_id[note_data.id]

	if note_instance:
		_update_single_note_position(note_instance)
		update_container_width()

	logger.info("Reactively updated visual note %d" % note_data.id)


# ============================================================================
# COORDINATE CONVERSION
# ============================================================================
func y_to_note(y: float) -> int:
	"""Convert Y pixel position to MIDI note number."""
	var note = Midi.MIDI_MAX - int(y / note_height)
	return clamp(note, MIDI_MIN, MIDI_MAX)


func note_to_y(note : int) -> float:
	return (127.0 - note) * note_height


func ticks_to_pixels(ticks: int) -> float:
	"""Convert ticks to horizontal pixels using GridHelper."""
	return grid_helper.ticks_to_pixels(ticks)


func pixels_to_ticks(pixels: float) -> int:
	"""Convert horizontal pixels to ticks using GridHelper."""
	return grid_helper.pixels_to_ticks(pixels)


# ============================================================================
# HELPER METHODS
# ============================================================================
func get_snap_interval() -> int:
	"""Get the current snap interval from the grid helper."""
	if grid_helper:
		return grid_helper.get_snap_interval()
	return 960  # Default to quarter note


func _get_note_at_position(pos: Vector2) -> VisualNote:
	"""Find which note is at the given position (if any)."""
	# Iterate through children in reverse (top-most first)
	var children = get_children()
	for i in range(children.size() - 1, -1, -1):
		var child = children[i]
		if child is VisualNote:
			var rect = Rect2(child.position, child.size)
			if rect.has_point(pos):
				return child
	return null


func get_visual_note(note_id: int) -> VisualNote:
	"""Get visual note from dictionary (works in both single and multi-clip modes)."""
	if not visual_notes_by_id.has(note_id):
		return null

	var entry = visual_notes_by_id[note_id]
	if multi_clip_mode:
		# Multi-clip mode: entry is {visual_note, clip_instance}
		if entry is Dictionary and entry.has("visual_note"):
			return entry["visual_note"]
		return null
	else:
		# Single-clip mode: entry is VisualNote directly
		return entry


func get_clip_instance_for_note(note_id: int) -> ClipInstance:
	"""Get the clip instance that owns this note (multi-clip mode)."""
	if not multi_clip_mode:
		return clip_instance

	if not visual_notes_by_id.has(note_id):
		return null

	var entry = visual_notes_by_id[note_id]
	if entry is Dictionary and entry.has("clip_instance"):
		return entry["clip_instance"]
	return null


func _find_clip_instance_for_note(note_data: MidiNoteData) -> ClipInstance:
	"""Find which clip instance contains the given note (multi-clip mode)."""
	for ci in clip_instances:
		if ci and ci.clip:
			for note in ci.clip.midi_notes:
				if note.id == note_data.id:
					return ci
	return null


func get_clip_at_position(tick: int) -> ClipInstance:
	"""Get the clip instance at the given tick position (multi-clip mode)."""
	if not multi_clip_mode:
		return clip_instance

	for ci in clip_instances:
		if ci and tick >= ci.start_ticks and tick < ci.get_end_ticks():
			return ci
	return null


func get_or_create_clip_at_position(tick: int) -> ClipInstance:
	"""Get clip at position, or create a new one if empty space (multi-clip mode)."""
	# First try to find existing clip
	var existing = get_clip_at_position(tick)
	if existing:
		return existing

	# No clip at position - create a new one
	if not multi_clip_mode or not track:
		logger.error("Cannot create clip: not in multi-clip mode or no track set")
		return null

	logger.info("Creating new clip at tick %d on track '%s'" % [tick, track.name])

	# Calculate clip boundaries (snap to bars for clean organization)
	var ppq = grid_helper.ppq if grid_helper else 960
	var beats_per_bar = grid_helper.time_numerator if grid_helper else 4
	var ticks_per_bar = beats_per_bar * ppq

	# Snap start position to bar boundary
	@warning_ignore("integer_division")
	var clip_start_ticks = int(tick / ticks_per_bar) * ticks_per_bar

	# Default clip length: 4 bars
	var clip_length_ticks = ticks_per_bar * 4

	# Create clip in project
	var project = Sonara.editor.project
	if not project:
		logger.error("Cannot create clip: no project available")
		return null

	var clip = project.create_clip("Clip %d" % project.clips.size(), Clip.ClipType.MIDI)
	clip.content_length_ticks = clip_length_ticks
	project.add_clip(clip)

	# Create clip instance on track
	var clip_instance = track.create_clip_instance(clip, clip_start_ticks, clip_length_ticks)

	logger.info("Created clip '%s' (instance: %s) at tick %d (length: %d)" % [clip.name, clip_instance.id, clip_start_ticks, clip_length_ticks])

	# Rebind to refresh the container with the new clip
	# Store current clips and add the new one
	var updated_clips = clip_instances.duplicate()
	updated_clips.append(clip_instance)
	bind_to_clips(updated_clips, track)

	return clip_instance
