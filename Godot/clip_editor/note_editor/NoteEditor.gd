## Note editor with input handling and note interaction.
## Extends NoteContainer and uses NoteSelectionManager for selection operations.

class_name NoteEditor extends NoteContainer

# Selection manager
var selection_manager: NoteSelectionManager

# Interaction state
enum InteractionMode { NONE, DRAGGING, RESIZING, ERASING, PLACING_AND_DRAGGING, BOX_SELECTING }
var interaction_mode: InteractionMode = InteractionMode.NONE


# Drag/resize state
var dragging_note: VisualNote = null
var drag_start_ticks: int = 0
var drag_start_midi_note: int = 0
var drag_start_mouse_pos: Vector2 = Vector2.ZERO
var drag_start_positions: Dictionary = {}  # note_id -> {start_tick, note, velocity, clip_instance}

var resizing_note: VisualNote = null
var resize_start_duration: int = 0
var resize_start_mouse_pos: Vector2 = Vector2.ZERO
var resize_start_durations: Dictionary = {}  # note_id -> duration_ticks


# Drag mode tracking
enum DragMode { POSITION, RESIZE, VELOCITY }
var last_drag_mode: DragMode = DragMode.POSITION


# Newly placed note state
var placed_note_awaiting_drag: VisualNote = null
var placed_note_mouse_pos: Vector2 = Vector2.ZERO
const DRAG_THRESHOLD: float = 3.0


# Erase mode state
var erasing_mode: bool = false
var last_erased_note: VisualNote = null


# Local cursor position (for paste operations)
var cursor_position_ticks: int = 0


# Default note length for new notes
var default_note_length_ticks: int = 960:
	set(value):
		default_note_length_ticks = value


func _ready():
	# Create selection manager (grid_helper will be set via override below)
	selection_manager = NoteSelectionManager.new(grid_helper)
	selection_manager.selection_changed.connect(_on_selection_changed)
	
	# Provide coordinate conversion callback to selection manager
	# This allows it to work in the correct coordinate space without tight coupling
	selection_manager.get_note_song_position = get_note_song_position


func _on_selection_changed(notes: Array[VisualNote]) -> void:
	"""Handle selection changed from selection manager."""
	# Update default note length if single note selected
	if notes.size() == 1 and notes[0].midi_note_data:
		default_note_length_ticks = notes[0].midi_note_data.duration_ticks


# Override set_grid_helper to also update selection manager
func set_grid_helper(gh: GridHelper) -> void:
	super.set_grid_helper(gh)
	if selection_manager:
		selection_manager.grid_helper = gh


# Override bind to update default note length from grid helper
func bind(ci: ClipInstance):
	super.bind(ci)

	# Initialize default note length from snap interval if not already set
	if grid_helper and default_note_length_ticks == 960:
		default_note_length_ticks = grid_helper.get_snap_interval()


# Override bind_to_clips for multi-clip mode (track-mode)
func bind_to_clips(instances: Array[ClipInstance], owner_track: Track):
	super.bind_to_clips(instances, owner_track)

	# Initialize default note length from snap interval if not already set
	if grid_helper and default_note_length_ticks == 960:
		default_note_length_ticks = grid_helper.get_snap_interval()


# ============================================================================
# PUBLIC API FOR MIDIEDITOR INPUT DELEGATION
# ============================================================================
func get_note_at_position(pos: Vector2) -> VisualNote:
	"""Find which note is at the given position (public API for MidiEditor)."""
	return _get_note_at_position(pos)


func get_notes_in_box(box_rect: Rect2) -> Array[VisualNote]:
	"""Find all visual notes that intersect with the given box (public API for MidiEditor)."""
	return _get_notes_in_box(box_rect)


func place_note_at_position(pos: Vector2) -> VisualNote:
	"""Place a MIDI note at the given position (public API for MidiEditor)."""
	return _place_note_at_position(pos)


func erase_note(note: VisualNote) -> void:
	"""Erase a note immediately (public API for MidiEditor)."""
	_erase_note(note)


func start_place_and_drag(note: VisualNote) -> void:
	"""Start dragging a newly placed note (public API for MidiEditor)."""
	_start_place_and_drag(note)


func handle_key_input(event: InputEventKey) -> void:
	"""Handle keyboard input."""
	if event.is_action_pressed("ui_copy"):
		selection_manager.copy_selection()
		accept_event()

	elif event.is_action_pressed("ui_cut"):
		_cut_selection()
		accept_event()

	elif event.is_action_pressed("ui_paste"):
		_paste_at_position(cursor_position_ticks)
		accept_event()

	elif event.is_action_pressed("ui_duplicate"):
		_duplicate_selection()
		accept_event()

	elif event.is_action_pressed("ui_delete"):
		_delete_selection()
		accept_event()

	elif event.is_action_pressed("ui_up"):
		var semitones = 12 if event.ctrl_pressed else 1
		_move_selection_vertical(semitones)
		accept_event()

	elif event.is_action_pressed("ui_down"):
		var semitones = 12 if event.ctrl_pressed else 1
		_move_selection_vertical(-semitones)
		accept_event()

	elif event.is_action_pressed("ui_left"):
		_move_selection_horizontal(-get_snap_interval())
		accept_event()

	elif event.is_action_pressed("ui_right"):
		_move_selection_horizontal(get_snap_interval())
		accept_event()


# ============================================================================
# NOTE PLACEMENT
# ============================================================================
func _place_note_at_position(pos: Vector2) -> VisualNote:
	"""Place a MIDI note at the given position."""
	print("placing note at ", pos.y)

	# Clear selection before placing new note
	selection_manager.clear_selection()

	# Convert position to MIDI note and tick
	var midi_note_num = y_to_note(pos.y)
	var pixel_x = pos.x
	var tick_position = pixels_to_ticks(pixel_x)

	# Snap to grid
	var snap = get_snap_interval()
	if snap > 0:
		@warning_ignore("integer_division")
		tick_position = (tick_position / snap) * snap

	var end_tick = tick_position + default_note_length_ticks

	# Determine which clip to add note to
	var target_clip: Clip
	if multi_clip_mode:
		# MULTI-CLIP MODE: Find clip at cursor position, or create one
		var target_clip_instance = get_or_create_clip_at_position(tick_position)
		if not target_clip_instance:
			print("[NoteEditor] No clip at position and creation not yet implemented (Phase 5)")
			return null
		target_clip = target_clip_instance.clip
		# In multi-clip mode, tick_position is song-relative, need to convert to clip-local
		tick_position = tick_position - target_clip_instance.start_ticks
		end_tick = tick_position + default_note_length_ticks
	else:
		# SINGLE-CLIP MODE: Use the bound clip
		if not clip:
			print("No clip loaded in MIDI editor")
			return null
		target_clip = clip

	# Cut overlapping notes
	var affected_notes = target_clip.cut_overlapping_notes_at_pitch(midi_note_num, tick_position, end_tick)

	if not affected_notes.is_empty():
		print("[NoteEditor] Cut/merged %d overlapping notes" % affected_notes.size())

	# Get unique note ID
	var note_id = -1
	if Sonara and Sonara.editor and Sonara.editor.project:
		note_id = Sonara.editor.project.next_note_id
		Sonara.editor.project.next_note_id += 1

	# Add note to clip
	var note_data = target_clip.add_midi_note(note_id, midi_note_num, 100, tick_position, default_note_length_ticks)
	if note_data == null:
		push_error("[NoteEditor] Failed to add note after cutting overlaps")
		return null

	print("[NoteEditor] Added note %d: MIDI=%d start=%d duration=%d" % [note_data.id, midi_note_num, tick_position, default_note_length_ticks])

	# Get visual note created reactively
	var note_instance = get_visual_note(note_data.id)
	if note_instance == null:
		push_error("[NoteEditor] Failed to find visual note after creation")
		return null

	print("Placed note: MIDI %d at tick %d (duration: %d)" % [midi_note_num, tick_position, default_note_length_ticks])

	# Select the newly placed note (uses coordinate conversion callback)
	selection_manager.select_note(note_instance)
	queue_redraw()

	# Wait for drag to start
	placed_note_awaiting_drag = note_instance
	placed_note_mouse_pos = get_global_mouse_position()

	return note_instance


# ============================================================================
# NOTE INTERACTION HANDLERS
# ============================================================================
func _on_drag_started(note: VisualNote, click_position: Vector2) -> void:
	"""Handle note drag start."""
	if not note.midi_note_data:
		return

	# If note not selected, select it
	if note not in selection_manager.selected_notes:
		selection_manager.select_note(note)

	dragging_note = note
	drag_start_ticks = note.midi_note_data.start_tick
	drag_start_midi_note = note.midi_note_data.note
	drag_start_mouse_pos = click_position
	last_drag_mode = DragMode.POSITION

	# Store starting positions for all selected notes
	drag_start_positions.clear()
	resize_start_durations.clear()
	for sel_note in selection_manager.selected_notes:
		if sel_note.midi_note_data:
			var source_clip_instance = get_clip_instance_for_note(sel_note.midi_note_data.id)
			drag_start_positions[sel_note.midi_note_data.id] = {
				"start_tick": sel_note.midi_note_data.start_tick,
				"note": sel_note.midi_note_data.note,
				"velocity": sel_note.midi_note_data.velocity,
				"clip_instance": source_clip_instance
			}
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks


func _on_drag_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	"""Handle note drag update (supports shift-to-resize and alt-for-velocity)."""
	if dragging_note != note or not note.midi_note_data:
		return

	var shift_pressed = Input.is_key_pressed(KEY_SHIFT)
	var alt_pressed = Input.is_key_pressed(KEY_ALT)

	# Determine current mode
	var current_mode: DragMode
	if alt_pressed:
		current_mode = DragMode.VELOCITY
	elif shift_pressed:
		current_mode = DragMode.RESIZE
	else:
		current_mode = DragMode.POSITION

	# Check if mode changed
	if current_mode != last_drag_mode:
		drag_start_mouse_pos = mouse_pos_local

		# Update stored starting positions
		for sel_note in selection_manager.selected_notes:
			if not sel_note.midi_note_data:
				continue
			drag_start_positions[sel_note.midi_note_data.id] = {
				"start_tick": sel_note.midi_note_data.start_tick,
				"note": sel_note.midi_note_data.note,
				"velocity": sel_note.midi_note_data.velocity
			}
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks

		last_drag_mode = current_mode
		print("[NoteEditor] Drag mode switched to: %s" % ["POSITION", "RESIZE", "VELOCITY"][current_mode])

	var delta_x = mouse_pos_local.x - drag_start_mouse_pos.x
	var delta_y = mouse_pos_local.y - drag_start_mouse_pos.y
	var delta_ticks = pixels_to_ticks(delta_x)

	if alt_pressed:
		# Alt mode: Control velocity
		var velocity_delta = int(-delta_y / 2.0)

		for sel_note in selection_manager.selected_notes:
			if not sel_note.midi_note_data:
				continue

			var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
			if not start_pos:
				continue

			var start_velocity = start_pos.get("velocity", 100)
			var new_velocity = clamp(start_velocity + velocity_delta, 1, 127)

			sel_note.midi_note_data.velocity = new_velocity
			sel_note._update_visual()

	elif shift_pressed:
		# Shift mode: Control note length
		for sel_note in selection_manager.selected_notes:
			if not sel_note.midi_note_data:
				continue

			var start_duration = resize_start_durations.get(sel_note.midi_note_data.id)
			if start_duration == null:
				continue

			var new_duration = max(get_snap_interval(), start_duration + delta_ticks)

			# Apply snapping
			if grid_helper:
				var snap_interval = grid_helper.get_snap_interval()
				new_duration = max(snap_interval, new_duration)
				@warning_ignore("integer_division")
				new_duration = int(new_duration / snap_interval) * snap_interval

			sel_note.midi_note_data.duration_ticks = new_duration
			var note_width = ticks_to_pixels(new_duration)
			sel_note.size.x = note_width

			default_note_length_ticks = new_duration
	else:
		# Normal mode: Control position
		var current_midi_note = y_to_note(mouse_pos_local.y)
		var delta_midi_note = current_midi_note - drag_start_midi_note

		for sel_note in selection_manager.selected_notes:
			if not sel_note.midi_note_data:
				continue

			var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
			if not start_pos:
				continue

			var new_ticks = max(0, start_pos.start_tick + delta_ticks)
			var new_midi_note = clamp(start_pos.note + delta_midi_note, 0, 127)

			# Apply snapping
			if grid_helper:
				new_ticks = grid_helper.snap_ticks(new_ticks)

			sel_note.midi_note_data.start_tick = new_ticks
			sel_note.midi_note_data.note = new_midi_note

			# Calculate visual position (accounting for clip offset in multi-clip mode)
			var visual_offset_ticks = 0
			if multi_clip_mode:
				var clip_instance = get_clip_instance_for_note(sel_note.midi_note_data.id)
				if clip_instance:
					visual_offset_ticks = clip_instance.start_ticks

			var note_x = ticks_to_pixels(new_ticks + visual_offset_ticks)
			var note_y = note_to_y(new_midi_note)
			sel_note.position = Vector2(note_x, note_y)
			sel_note._update_visual()


func _on_drag_ended(note: VisualNote) -> void:
	"""Handle note drag end."""
	if dragging_note != note or not note.midi_note_data:
		return

	# Check if any note changed
	var any_changes = false
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue
		var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
		var start_duration = resize_start_durations.get(sel_note.midi_note_data.id)

		if start_pos:
			if sel_note.midi_note_data.start_tick != start_pos.start_tick or sel_note.midi_note_data.note != start_pos.note:
				any_changes = true
				break
			if sel_note.midi_note_data.velocity != start_pos.get("velocity", 100):
				any_changes = true
				break
		if start_duration != null and sel_note.midi_note_data.duration_ticks != start_duration:
			any_changes = true
			break

	if not any_changes:
		print("[NoteEditor] Drag ended with no changes")
		dragging_note = null
		drag_start_positions.clear()
		resize_start_durations.clear()
		update_container_width()
		return

	# MULTI-CLIP MODE: Check if notes need to be transferred between clips
	if multi_clip_mode:
		_handle_cross_clip_transfers()

	# Process all selected notes (cut overlaps and update)
	var total_affected = 0
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		# Get the clip this note belongs to
		var note_clip = _get_clip_for_note(sel_note.midi_note_data.id)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		print("[NoteEditor] Multi-drag ended - cut/merged %d overlapping notes" % total_affected)

	print("[NoteEditor] Updated %d note(s) position/duration" % selection_manager.selected_notes.size())

	# Don't update selection range - keep grid-snapped box selection boundaries
	# This preserves the user's original box selection for duplicate/paste operations
	queue_redraw()
	update_container_width()

	dragging_note = null
	drag_start_positions.clear()
	resize_start_durations.clear()


func _on_resize_started(note: VisualNote, click_position: Vector2) -> void:
	"""Handle note resize start."""
	if not note.midi_note_data:
		return

	if note not in selection_manager.selected_notes:
		selection_manager.select_note(note)

	resizing_note = note
	resize_start_duration = note.midi_note_data.duration_ticks
	resize_start_mouse_pos = click_position

	# Store starting durations for all selected notes
	resize_start_durations.clear()
	for sel_note in selection_manager.selected_notes:
		if sel_note.midi_note_data:
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks


func _on_resize_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	"""Handle note resize update."""
	if resizing_note != note or not note.midi_note_data:
		return

	var delta = mouse_pos_local - resize_start_mouse_pos
	var delta_ticks = pixels_to_ticks(delta.x)

	var new_duration = max(get_snap_interval(), resize_start_duration + delta_ticks)

	# Apply snapping
	if grid_helper:
		var snap_interval = grid_helper.get_snap_interval()
		new_duration = max(snap_interval, new_duration)
		@warning_ignore("integer_division")
		new_duration = int(new_duration / snap_interval) * snap_interval

	var shift_pressed = Input.is_key_pressed(KEY_SHIFT)

	# Update all selected notes
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_new_duration: int

		if shift_pressed:
			# Shift: Set all notes to same duration
			note_new_duration = new_duration
		else:
			# Default: Apply same delta to each note
			var note_start_duration = resize_start_durations.get(sel_note.midi_note_data.id, sel_note.midi_note_data.duration_ticks)
			note_new_duration = max(get_snap_interval(), note_start_duration + delta_ticks)

			if grid_helper:
				var snap_interval = grid_helper.get_snap_interval()
				note_new_duration = max(snap_interval, note_new_duration)
				@warning_ignore("integer_division")
				note_new_duration = int(note_new_duration / snap_interval) * snap_interval

		sel_note.midi_note_data.duration_ticks = note_new_duration
		var note_width = ticks_to_pixels(note_new_duration)
		sel_note.size.x = note_width


func _on_resize_ended(note: VisualNote) -> void:
	"""Handle note resize end."""
	if resizing_note != note or not note.midi_note_data:
		return

	# Store new note length as default
	default_note_length_ticks = note.midi_note_data.duration_ticks
	print("[NoteEditor] Updated default note length to %d ticks" % default_note_length_ticks)

	# Process all selected notes
	var total_affected = 0
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		# Get the clip this note belongs to
		var note_clip = _get_clip_for_note(sel_note.midi_note_data.id)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		print("[NoteEditor] Multi-resize ended - cut/merged %d overlapping notes" % total_affected)

	print("[NoteEditor] Updated %d note(s) duration" % selection_manager.selected_notes.size())

	# Don't update selection range - keep grid-snapped box selection boundaries
	queue_redraw()
	update_container_width()

	resizing_note = null
	resize_start_durations.clear()


func _start_place_and_drag(note: VisualNote) -> void:
	"""Start dragging a newly placed note."""
	if not note or not note.midi_note_data:
		return

	interaction_mode = InteractionMode.PLACING_AND_DRAGGING
	dragging_note = note
	drag_start_ticks = note.midi_note_data.start_tick
	drag_start_midi_note = note.midi_note_data.note
	drag_start_mouse_pos = get_local_mouse_position()
	last_drag_mode = DragMode.POSITION

	# Select the note
	if selection_manager.selected_note and selection_manager.selected_note != note:
		selection_manager.selected_note.set_selected(false)
	selection_manager.selected_note = note
	note.set_selected(true)

	# Store starting positions
	drag_start_positions.clear()
	resize_start_durations.clear()
	for sel_note in selection_manager.selected_notes:
		if sel_note.midi_note_data:
			drag_start_positions[sel_note.midi_note_data.id] = {
				"start_tick": sel_note.midi_note_data.start_tick,
				"note": sel_note.midi_note_data.note,
				"velocity": sel_note.midi_note_data.velocity
			}
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks

	print("[NoteEditor] Started place-and-drag for note %d" % note.midi_note_data.id)


func _erase_note(note: VisualNote) -> void:
	"""Erase a note immediately."""
	if not note or not note.midi_note_data:
		return

	last_erased_note = note

	var note_clip = _get_clip_for_note(note.midi_note_data.id)
	if note_clip:
		note_clip.remove_midi_note(note.midi_note_data)
		print("[NoteEditor] Erased note %d" % note.midi_note_data.id)


# ============================================================================
# HELPER METHODS FOR SELECTION MANAGER
# ============================================================================
func _snap_position_to_grid(pos: Vector2) -> Vector2:
	"""Snap a position to the grid (both X and Y)."""
	var snapped_pos = pos

	# Snap Y to note height boundaries
	var note_num = y_to_note(pos.y)
	snapped_pos.y = note_to_y(note_num)

	# Snap X to time grid
	var ticks = grid_helper.pixels_to_ticks(pos.x)
	ticks = grid_helper.snap_ticks(ticks)
	snapped_pos.x = grid_helper.ticks_to_pixels(ticks)

	return snapped_pos


func _get_notes_in_box(box_rect: Rect2) -> Array[VisualNote]:
	"""Find all visual notes that intersect with the given box."""
	var notes: Array[VisualNote] = []
	for child in get_children():
		if child is VisualNote:
			var note_rect = Rect2(child.position, child.size)
			if box_rect.intersects(note_rect):
				notes.append(child)
	return notes


# ============================================================================
# CLIPBOARD OPERATIONS (orchestrates between selection manager and container)
# ============================================================================
func _cut_selection() -> void:
	"""Cut selected notes (copy + delete)."""
	if selection_manager.selected_notes.is_empty():
		print("[NoteEditor] No notes selected to cut")
		return

	selection_manager.copy_selection()
	_delete_selection()

	print("[NoteEditor] Cut %d notes" % selection_manager.clipboard.notes.size())


func _paste_at_position(tick_position: int) -> void:
	"""Paste clipboard contents at the specified tick position."""
	if not selection_manager.clipboard or selection_manager.clipboard.is_empty():
		print("[NoteEditor] Clipboard is empty")
		return

	# Determine target clip
	var target_clip: Clip
	var clip_local_position: int = tick_position

	if multi_clip_mode:
		# MULTI-CLIP MODE: Find or create clip at cursor position
		var target_clip_instance = get_or_create_clip_at_position(tick_position)
		if not target_clip_instance:
			print("[NoteEditor] Cannot paste - no clip at position")
			return
		target_clip = target_clip_instance.clip
		# Convert to clip-local position
		clip_local_position = tick_position - target_clip_instance.start_ticks
	else:
		# SINGLE-CLIP MODE: Use bound clip
		if not clip:
			print("[NoteEditor] No clip loaded")
			return
		target_clip = clip
		clip_local_position = tick_position

	# Snap to grid
	var snap = get_snap_interval()
	if snap > 0:
		@warning_ignore("integer_division")
		clip_local_position = (clip_local_position / snap) * snap

	# Get notes positioned at paste location
	var notes_to_paste = selection_manager.clipboard.get_notes_at_position(clip_local_position)

	# Cut overlapping notes
	var total_affected = 0
	for note_data in notes_to_paste:
		var end_tick = note_data.start_tick + note_data.duration_ticks
		var affected = target_clip.cut_overlapping_notes_at_pitch(note_data.note, note_data.start_tick, end_tick)
		total_affected += affected.size()

	if total_affected > 0:
		print("[NoteEditor] Paste cut/merged %d overlapping notes" % total_affected)

	selection_manager.clear_selection()

	# Add notes to clip
	var project = Sonara.editor.project
	var pasted_note_ids: Array[int] = []

	for note_data in notes_to_paste:
		note_data.id = project.next_note_id
		project.next_note_id += 1

		var added = target_clip.add_midi_note_data(note_data)
		if added == null:
			push_warning("[NoteEditor] Failed to paste note at pitch=%d, start=%d" % [note_data.note, note_data.start_tick])
			continue

		pasted_note_ids.append(note_data.id)

	# Select newly pasted notes
	var pasted_notes: Array[VisualNote] = []
	for note_id in pasted_note_ids:
		var note_instance = get_visual_note(note_id)
		if note_instance:
			pasted_notes.append(note_instance)

	selection_manager._set_selected_notes(pasted_notes)
	if selection_manager.selected_notes.size() > 0:
		selection_manager.selected_note = selection_manager.selected_notes[0]

	# Set selection range
	if not selection_manager.selected_notes.is_empty():
		selection_manager.box_selection_start_tick = tick_position
		selection_manager.box_selection_end_tick = tick_position + selection_manager.clipboard.duration_ticks
		queue_redraw()

	selection_manager.selection_changed.emit(selection_manager.selected_notes)

	print("[NoteEditor] Pasted %d notes at tick %d (range: %d-%d)" % [
		pasted_note_ids.size(), tick_position, selection_manager.box_selection_start_tick, selection_manager.box_selection_end_tick
	])


func _duplicate_selection() -> void:
	"""Duplicate selected notes immediately after the selection."""
	if selection_manager.selected_notes.is_empty():
		print("[NoteEditor] No notes selected to duplicate")
		return

	var selection_length = selection_manager.box_selection_end_tick - selection_manager.box_selection_start_tick
	if selection_length <= 0:
		print("[NoteEditor] Cannot duplicate - invalid selection range")
		return

	var selection: NoteSelection
	if selection_manager.box_selection_start_tick > 0 or selection_manager.box_selection_end_tick > 0:
		selection = NoteSelection.from_visual_notes_with_range(
			selection_manager.selected_notes,
			selection_manager.box_selection_start_tick,
			selection_manager.box_selection_end_tick
		)
	else:
		selection = NoteSelection.from_visual_notes(selection_manager.selected_notes)

	var duplicate_position = selection.end_tick

	# Store clipboard temporarily
	var old_clipboard = selection_manager.clipboard
	selection_manager.clipboard = selection
	_paste_at_position(duplicate_position)
	selection_manager.clipboard = old_clipboard

	print("[NoteEditor] Duplicated %d notes (duration: %d ticks)" % [selection.notes.size(), selection.duration_ticks])


func _delete_selection() -> void:
	"""Delete all selected notes."""
	if selection_manager.selected_notes.is_empty():
		print("[NoteEditor] No notes selected to delete")
		return

	var count = selection_manager.selected_notes.size()

	# Remove notes in reverse
	for i in range(selection_manager.selected_notes.size() - 1, -1, -1):
		var note = selection_manager.selected_notes[i]
		if is_instance_valid(note) and note.midi_note_data:
			var note_clip = _get_clip_for_note(note.midi_note_data.id)
			if note_clip:
				note_clip.remove_midi_note(note.midi_note_data)
			note.queue_free()

	selection_manager.selected_notes.clear()
	selection_manager.selected_note = null
	selection_manager.selection_changed.emit(selection_manager.selected_notes)

	update_container_width()

	print("[NoteEditor] Deleted %d notes" % count)


# ============================================================================
# KEYBOARD NOTE MOVEMENT (orchestrates between selection manager and container)
# ============================================================================
func _move_selection_vertical(semitones: int) -> void:
	"""Move all selected notes up or down by semitones."""
	if selection_manager.selected_notes.is_empty():
		return

	# Move all selected notes
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var new_pitch = clamp(note_data.note + semitones, 0, 127)
		note_data.note = new_pitch

		var note_y = note_to_y(new_pitch)
		sel_note.position.y = note_y
		sel_note._update_visual()

	# Process overlaps and sync
	var total_affected = 0
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		var note_clip = _get_clip_for_note(sel_note.midi_note_data.id)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		print("[NoteEditor] Keyboard move vertical - cut/merged %d overlapping notes" % total_affected)

	print("[NoteEditor] Moved %d note(s) %+d semitones" % [selection_manager.selected_notes.size(), semitones])
	update_container_width()


func _move_selection_horizontal(delta_ticks: int) -> void:
	"""Move all selected notes left or right by ticks."""
	if selection_manager.selected_notes.is_empty():
		return

	# Move all selected notes
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var new_start = max(0, note_data.start_tick + delta_ticks)
		note_data.start_tick = new_start

		var note_x = ticks_to_pixels(new_start)
		sel_note.position.x = note_x

	# Process overlaps and sync
	var total_affected = 0
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		var note_clip = _get_clip_for_note(sel_note.midi_note_data.id)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		print("[NoteEditor] Keyboard move horizontal - cut/merged %d overlapping notes" % total_affected)

	print("[NoteEditor] Moved %d note(s) %+d ticks" % [selection_manager.selected_notes.size(), delta_ticks])

	# Don't update selection range - keep grid-snapped box selection boundaries
	queue_redraw()
	update_container_width()


# Override _on_clip_note_removed to handle selection cleanup
func _on_clip_note_removed(note_data: MidiNoteData) -> void:
	"""Handle when a note is removed from the clip."""
	# Remove from selection if selected
	var note_instance = get_visual_note(note_data.id)
	if note_instance:
		if note_instance in selection_manager.selected_notes:
			selection_manager.selected_notes.erase(note_instance)
		if selection_manager.selected_note == note_instance:
			selection_manager.selected_note = null

	# Call parent implementation
	super._on_clip_note_removed(note_data)


# ============================================================================
# CROSS-CLIP NOTE MOVEMENT (MULTI-CLIP MODE)
# ============================================================================
func _handle_cross_clip_transfers() -> void:
	"""Transfer notes between clips if they moved to different clip regions."""
	if not multi_clip_mode:
		return

	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var note_id = note_data.id

		# Get source and destination clips
		var start_pos = drag_start_positions.get(note_id)
		if not start_pos:
			continue

		var source_clip_instance = start_pos.get("clip_instance") as ClipInstance
		if not source_clip_instance:
			continue

		# Calculate song-relative position (note position + clip offset)
		var current_clip_instance = get_clip_instance_for_note(note_id)
		if not current_clip_instance:
			continue

		var song_position = note_data.start_tick + current_clip_instance.start_ticks

		# Find which clip should contain this note at its new position
		var dest_clip_instance = get_clip_at_position(song_position)

		# If no clip at position, try to create one
		if not dest_clip_instance:
			dest_clip_instance = get_or_create_clip_at_position(song_position)

		# Transfer note if it moved to a different clip
		if dest_clip_instance and dest_clip_instance != source_clip_instance:
			_transfer_note_between_clips(note_data, source_clip_instance, dest_clip_instance, song_position)


func _transfer_note_between_clips(note_data: MidiNoteData, source: ClipInstance, dest: ClipInstance, song_position: int) -> void:
	"""Transfer a note from source clip to destination clip."""
	print("[NoteEditor] Transferring note %d from clip '%s' to '%s'" % [note_data.id, source.clip.name if source.clip else "?", dest.clip.name if dest.clip else "?"])

	# Calculate clip-local position for destination clip
	var dest_local_position = song_position - dest.start_ticks

	# Create a copy of the note data for the destination clip
	var new_note = MidiNoteData.new()
	var project = Sonara.editor.project
	new_note.id = project.next_note_id
	project.next_note_id += 1
	new_note.note = note_data.note
	new_note.velocity = note_data.velocity
	new_note.start_tick = dest_local_position
	new_note.duration_ticks = note_data.duration_ticks

	# Remove from source clip (this will trigger reactive removal)
	source.clip.remove_midi_note(note_data)

	# Add to destination clip (this will trigger reactive addition)
	dest.clip.add_midi_note_data(new_note)

	print("[NoteEditor] Note transferred: old_id=%d, new_id=%d, new_local_pos=%d" % [note_data.id, new_note.id, dest_local_position])


func _get_clip_for_note(note_id: int) -> Clip:
	"""Get the clip that owns this note (works in both single and multi-clip modes)."""
	if not multi_clip_mode:
		return clip

	var clip_instance = get_clip_instance_for_note(note_id)
	if clip_instance:
		return clip_instance.clip
	return null
