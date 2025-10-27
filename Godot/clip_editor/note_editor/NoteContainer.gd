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


# The clip instance that opened this editor (for context, not edited directly)
var clip_instance: ClipInstance = null

# Convenience to get the Clip of clip_instance
var clip: Clip:
	get:
		return clip_instance.clip if clip_instance else null
	set(clip):
		pass

# Container for notes
var visual_notes_by_id: Dictionary = {}  # Map note ID -> VisualNote instance


func unbind():
	# Disconnect from clip signals if bound
	if clip:
		if clip.midi_note_added.is_connected(_on_clip_note_added):
			clip.midi_note_added.disconnect(_on_clip_note_added)
		if clip.midi_note_removed.is_connected(_on_clip_note_removed):
			clip.midi_note_removed.disconnect(_on_clip_note_removed)
		if clip.midi_note_changed.is_connected(_on_clip_note_changed):
			clip.midi_note_changed.disconnect(_on_clip_note_changed)
	
	# Disconnect from grid_helper if connected
	if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
		grid_helper.changed.disconnect(_on_grid_helper_changed)

	# Clear all visual notes
	for node in get_children():
		node.queue_free()

	visual_notes_by_id.clear()
	clip_instance = null


func bind(ci : ClipInstance):
	logger.info("bind called")
	logger.info("  - clip_instance: ", ci)
	logger.info("  - clip_id: ", ci.clip_id if ci else "null")

	if clip_instance != ci:
		if clip_instance:
			unbind()

		clip_instance = ci

		# Connect to clip signals for reactive updates
		if clip:
			clip.midi_note_added.connect(_on_clip_note_added)
			clip.midi_note_removed.connect(_on_clip_note_removed)
			clip.midi_note_changed.connect(_on_clip_note_changed)

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
	# Apply position offset for song-relative positioning in track-mode
	var note_x = ticks_to_pixels(note_data.start_tick + position_offset_ticks)
	var note_y = note_to_y(note_data.note)
	var note_width = ticks_to_pixels(note_data.duration_ticks)

	note.position = Vector2(note_x, note_y)
	note.size = Vector2(note_width, note_height)
	note.update_label_visibility(note_height)


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

	if not clip:
		logger.error("No clip to load!")
		return

	visual_notes_by_id.clear()

	# Load all notes from clip
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

		# Track in dictionary
		visual_notes_by_id[note_data.id] = note_instance

	# Update all note positions
	_update_note_positions()
	update_container_width()

	logger.info("Loaded %d notes from clip '%s'" % [clip.midi_notes.size(), clip.name])


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

	# Track in dictionary
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

	var note_instance = visual_notes_by_id[note_data.id]

	# Remove from dictionary and scene
	visual_notes_by_id.erase(note_data.id)
	note_instance.queue_free()
	update_container_width()

	logger.info("Reactively removed visual note %d" % note_data.id)


func _on_clip_note_changed(note_data: MidiNoteData) -> void:
	"""Handle when a note is modified in the clip (reactive)."""
	if note_data.id not in visual_notes_by_id:
		push_warning("[NoteContainer] Cannot update visual note %d - not found" % note_data.id)
		return

	var note_instance = visual_notes_by_id[note_data.id]
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
