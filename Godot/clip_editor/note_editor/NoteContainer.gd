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


# Horizontal scroll is derived from grid_helper.scroll_position


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
# TODO: rename to track_mode since that's what ClipEditor calls it ?
var clip_instances: Array[ClipInstance] = []
var track: Track = null  # Track that owns these clips
var multi_clip_mode: bool = false

# Container for notes
# SINGLE-CLIP MODE: note_id -> VisualNote
# MULTI-CLIP MODE: note_id -> {visual_note: VisualNote, clip_instance: ClipInstance}
var visual_notes_by_id: Dictionary = {}

func _make_note_key(ci: ClipInstance, nd: MidiNoteData) -> String:
	# Unique key per (clip_instance, note_id) to avoid collisions when multiple instances share the same Clip
	if ci:
		return "%s:%d" % [str(ci.id), nd.id]
	return "single:%d" % nd.id


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
	clip_instances = instances.duplicate()  # Duplicate to avoid modifying the track's array
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
		# MULTI-CLIP MODE: get clip instance directly from visual note metadata
		var ci: ClipInstance = note.get_meta("clip_instance") if note.has_meta("clip_instance") else null
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
	note.set_deferred("size", Vector2(note_width, note_height))
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
		var ci: ClipInstance = null
		if multi_clip_mode:
			ci = note.get_meta("clip_instance") if note.has_meta("clip_instance") else null
		else:
			ci = null
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
	var scroll_pos = grid_helper.scroll_position if grid_helper else 0.0
	var viewport_width = get_parent().size.x

	# Find rightmost content position (account for clip offsets in multi-clip mode)
	var rightmost_tick = 0
	if multi_clip_mode:
		# Use clip instance end ticks to cover entire clips on the track
		for ci in clip_instances:
			if ci:
				rightmost_tick = max(rightmost_tick, ci.get_end_ticks())
	else:
		# Single-clip mode: use note ends (plus optional position offset)
		for note in get_children():
			if note is VisualNote and note.midi_note_data:
				var note_end = note.midi_note_data.start_tick + note.midi_note_data.duration_ticks + position_offset_ticks
				rightmost_tick = max(rightmost_tick, note_end)
	var rightmost_pixels = ticks_to_pixels(rightmost_tick)

	# Calculate required width
	var extra_ticks = extra_width_bars * beats_per_bar * ppq
	var extra_pixels = ticks_to_pixels(extra_ticks)

	var width_from_scroll = scroll_pos + viewport_width + extra_pixels
	var width_from_content = rightmost_pixels + extra_pixels
	var required_width = max(min_width_pixels, width_from_scroll, width_from_content)

	logger.info("update_container_width: multi=%s rightmost_tick=%d min_px=%.1f scroll=%.1f viewport=%.1f content_px=%.1f required_px=%.1f" % [str(multi_clip_mode), rightmost_tick, min_width_pixels, scroll_pos, viewport_width, width_from_content, required_width])

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
		visual_notes_by_id[_make_note_key(null, note_data)] = note_instance

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

		# Debug per-clip summary
		var clip_note_count = ci.clip.midi_notes.size()
		logger.info("  - clip instance id=%s start=%d end=%d notes=%d" % [str(ci.id), ci.start_ticks, ci.get_end_ticks(), clip_note_count])

		for note_data in ci.clip.midi_notes:
			# Assign note ID if not already assigned
			if note_data.id < 0:
				note_data.id = project.next_note_id
				project.next_note_id += 1

			# Create visual note instance
			var note_instance = visual_note_scene.instantiate()
			add_child(note_instance)
			note_instance.bind_to_note(note_data)
			# Attach clip instance to the visual note for positioning and lookups
			note_instance.set_meta("clip_instance", ci)

			# Set color from track
			note_instance.set_color(note_color)

			# Track in dictionary (multi-clip mode: {visual_note, clip_instance})
			visual_notes_by_id[_make_note_key(ci, note_data)] = {
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
	if multi_clip_mode:
		# Create a visual note for EACH clip instance on this track (shared clip content)
		for ci in clip_instances:
			if not ci or not ci.clip:
				continue
			# Avoid duplicates
			var key = _make_note_key(ci, note_data)
			if visual_notes_by_id.has(key):
				continue
			var vn = visual_note_scene.instantiate()
			add_child(vn)
			vn.bind_to_note(note_data)
			vn.set_color(note_color)
			vn.set_meta("clip_instance", ci)
			visual_notes_by_id[key] = {
				"visual_note": vn,
				"clip_instance": ci
			}
			_update_single_note_position(vn)
	else:
		# Single-clip mode
		if note_data.id in visual_notes_by_id:
			push_warning("[NoteContainer] Note %d already has a visual representation" % note_data.id)
			return
		var vn_single = visual_note_scene.instantiate()
		add_child(vn_single)
		vn_single.bind_to_note(note_data)
		vn_single.set_color(note_color)
		visual_notes_by_id[note_data.id] = vn_single
		_update_single_note_position(vn_single)

	update_container_width()
	logger.info("Reactively added visual note %d" % note_data.id)


func _on_clip_note_removed(note_data: MidiNoteData) -> void:
	"""Handle when a note is removed from the clip (reactive)."""
	if multi_clip_mode:
		# Remove ALL instances of this note id across repeated clips
		var to_free: Array[VisualNote] = []
		for child in get_children():
			if child is VisualNote and child.midi_note_data and child.midi_note_data.id == note_data.id:
				# Erase dictionary entry
				if child.has_meta("clip_instance"):
					var ci: ClipInstance = child.get_meta("clip_instance")
					visual_notes_by_id.erase(_make_note_key(ci, note_data))
				to_free.append(child)
		for vn in to_free:
			vn.queue_free()
	else:
		if note_data.id not in visual_notes_by_id:
			push_warning("[NoteContainer] Cannot remove visual note %d - not found" % note_data.id)
			return
		var vn_single: VisualNote = visual_notes_by_id[note_data.id]
		visual_notes_by_id.erase(note_data.id)
		if vn_single:
			vn_single.queue_free()
	update_container_width()

	logger.info("Reactively removed visual note %d" % note_data.id)


func _on_clip_note_changed(note_data: MidiNoteData) -> void:
	"""Handle when a note is modified in the clip (reactive)."""
	if multi_clip_mode:
		# Update ALL instances for this shared note id
		for child in get_children():
			if child is VisualNote and child.midi_note_data and child.midi_note_data.id == note_data.id:
				child._update_visual()
				_update_single_note_position(child)
	else:
		if note_data.id not in visual_notes_by_id:
			push_warning("[NoteContainer] Cannot update visual note %d - not found" % note_data.id)
			return
		var vn_single: VisualNote = visual_notes_by_id[note_data.id]
		if vn_single:
			vn_single._update_visual()
			_update_single_note_position(vn_single)
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
	"""Get visual note by id. In multi-clip mode, scan children for matching note_id."""
	if not multi_clip_mode:
		return visual_notes_by_id.get(note_id, null)
	for child in get_children():
		if child is VisualNote and child.midi_note_data and child.midi_note_data.id == note_id:
			return child
	return null


func get_clip_instance_for_note(note_id: int) -> ClipInstance:
	"""Get the clip instance that owns this note (multi-clip mode)."""
	if not multi_clip_mode:
		return clip_instance
	for child in get_children():
		if child is VisualNote and child.midi_note_data and child.midi_note_data.id == note_id:
			return child.get_meta("clip_instance") if child.has_meta("clip_instance") else null
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

	# Find previous and next clips on the track
	var prev_clip_end: int = -1
	var next_clip_start: int = -1
	
	for instance in track.clip_instances:
		var clip_end = instance.start_ticks + instance.duration_ticks
		
		# Check for previous clip
		if clip_end <= clip_start_ticks:
			if prev_clip_end == -1 or clip_end > prev_clip_end:
				prev_clip_end = clip_end
		
		# Check for next clip
		if instance.start_ticks > clip_start_ticks:
			if next_clip_start == -1 or instance.start_ticks < next_clip_start:
				next_clip_start = instance.start_ticks
	
	# Adjust start position if it overlaps with previous clip
	if prev_clip_end != -1 and clip_start_ticks < prev_clip_end:
		# Snap to bar after previous clip ends
		@warning_ignore("integer_division")
		clip_start_ticks = ((prev_clip_end + ticks_per_bar - 1) / ticks_per_bar) * ticks_per_bar
		logger.info("  - Adjusted start to %d to avoid previous clip" % clip_start_ticks)

	# Calculate clip length
	var default_length = ticks_per_bar * 4  # Default: 4 bars
	var clip_length_ticks: int
	
	if next_clip_start != -1:
		# Constrain to end before the next clip
		var max_length = next_clip_start - clip_start_ticks
		
		# Ensure there's actually space for a clip
		if max_length <= 0:
			logger.error("Cannot create clip: no space between existing clips at tick %d" % tick)
			return null
		
		clip_length_ticks = min(default_length, max_length)
		logger.info("  - Constrained length to %d ticks (next clip at %d)" % [clip_length_ticks, next_clip_start])
	else:
		# No next clip, use default length
		clip_length_ticks = default_length

	# Create clip in project
	var project = Sonara.editor.project
	if not project:
		logger.error("Cannot create clip: no project available")
		return null

	var new_clip = project.create_clip("Clip %d" % project.clips.size(), Clip.ClipType.MIDI)
	new_clip.content_length_ticks = clip_length_ticks
	project.add_clip(new_clip)

	# Create clip instance on track
	var new_clip_instance = track.create_clip_instance(new_clip, clip_start_ticks, clip_length_ticks)

	logger.info("Created clip '%s' (instance: %s) at tick %d (length: %d)" % [new_clip.name, new_clip_instance.id, clip_start_ticks, clip_length_ticks])

	# Add the new clip instance to our tracking and connect signals
	# (no need to rebind everything, just add the new one)
	clip_instances.append(new_clip_instance)
	
	# Connect to new clip's signals for reactive updates
	if new_clip and not new_clip.midi_note_added.is_connected(_on_clip_note_added):
		new_clip.midi_note_added.connect(_on_clip_note_added)
		new_clip.midi_note_removed.connect(_on_clip_note_removed)
		new_clip.midi_note_changed.connect(_on_clip_note_changed)
	
	# Refresh container width to account for new clip
	update_container_width()

	return clip_instance
