class_name NoteContainer extends Container

@export var note_height := 20.0:
	set(nh):
		if note_height != nh:
			note_height = nh
			# Some setting changed, ask for children re-sort.
			queue_sort()

# MIDI range - use Midi singleton constants
const MIDI_MIN: int = Midi.MIDI_MIN    # C-2 (MIDI 0)
const MIDI_MAX: int = Midi.MIDI_MAX    # G9 (MIDI 127)
const MIDI_RANGE: int = MIDI_MAX - MIDI_MIN + 1

# The clip instance that opened this editor (for context, not edited directly)
var clip_instance: ClipInstance = null

# Convenience to get the Clip of clip_instance
var clip: Clip:
	get:
		return clip_instance.clip if clip_instance else null
	set(clip):
		pass
		

# Preload VisualNote scene
var visual_note_scene = preload("res://clip_editor/VisualNote.tscn")

# Clipboard for copy/paste operations
var clipboard: NoteSelection

# Container for notes
var visual_notes: Array[VisualNote] = []  # Track all visual note instances
var selected_note: VisualNote = null  # Currently selected note (legacy single selection)
var selected_notes: Array[VisualNote] = []  # Multiple selected notes

# Interaction state
enum InteractionMode { NONE, DRAGGING, RESIZING, ERASING, PLACING_AND_DRAGGING, BOX_SELECTING }
var interaction_mode: InteractionMode = InteractionMode.NONE

# Signals
signal selection_changed(notes: Array[VisualNote])

# Drag/resize state
var dragging_note: VisualNote = null
var drag_start_ticks: int = 0
var drag_start_midi_note: int = 0
var drag_start_mouse_pos: Vector2 = Vector2.ZERO
var resizing_note: VisualNote = null
var resize_start_duration: int = 0
var resize_start_mouse_pos: Vector2 = Vector2.ZERO

# Erase mode state
var erasing_mode: bool = false
var last_erased_note: VisualNote = null

# Box selection state
var box_selection_start: Vector2 = Vector2.ZERO
var box_selection_current: Vector2 = Vector2.ZERO
var box_selection_rect: Rect2 = Rect2()
var is_box_selecting: bool = false
# Track the actual time range of the box selection (not just note bounding box)
var box_selection_start_tick: int = 0
var box_selection_end_tick: int = 0

# Grid helper for consistent grid/snap logic
var grid_helper: GridHelper = null:
	set(gh):
		# Disconnect from old grid helper if any
		if grid_helper and grid_helper.changed.is_connected(_on_grid_helper_changed):
			grid_helper.changed.disconnect(_on_grid_helper_changed)
		
		grid_helper = gh
		
		# Connect to new grid helper
		if grid_helper:
			grid_helper.changed.connect(_on_grid_helper_changed)

			# Initialize default note length from snap interval if not already set
			if default_note_length_ticks == 960:  # Only if still at default value
				default_note_length_ticks = get_snap_interval()
			

# Local cursor position (in ticks) - used for paste operations
# This is separate from the main project playhead
var cursor_position_ticks: int = 0

# Default note length for new notes (in ticks)
var default_note_length_ticks: int = 960  # Default to 1 beat (960 ticks at 960 PPQ)

# Horizontal scrolling configuration
@export var min_width_bars: int = 8  # Minimum width in bars (4 beats each at 4/4)
@export var extra_width_bars: int = 4  # Extra space to the right of rightmost note

func unbind():
	for node in get_children():
		node.queue_free()


func bind(ci : ClipInstance):
	if clip_instance != ci:
		if clip_instance:
			unbind()
		
		clip_instance = ci
		_load_clip_notes()
		queue_sort()
	
		# Set initial container width
		update_container_width()


# ============================================================================
# Visual Note Placement
# ============================================================================
func _notification(what):
	if what == NOTIFICATION_SORT_CHILDREN:
		_update_note_positions()

func _place_note_at_position(pos: Vector2, start_dragging: bool = true) -> VisualNote:
	"""Place a MIDI note at the given position and optionally start dragging it."""
	if not clip:
		print("No clip loaded in MIDI editor")
		return null
	
	print("placing note at ", pos.y)
	
	# Convert position to MIDI note and tick
	var midi_note_num = y_to_note(pos.y)
	var pixel_x = pos.x
	var tick_position = pixels_to_ticks(pixel_x)
	
	# Snap to grid
	var snap = get_snap_interval()
	if snap > 0:
		@warning_ignore("integer_division")
		tick_position = (tick_position / snap) * snap
	
	# Use stored default note length
	var default_length_ticks = default_note_length_ticks
	
	# Get unique note ID from project
	var note_id = -1
	if Sonara and Sonara.editor and Sonara.editor.project:
		note_id = Sonara.editor.project.next_note_id
		Sonara.editor.project.next_note_id += 1
		#TODO: incremening ID can be handled by Clip itself.

	# Add note data to clip (clip will emit signal, Track will sync to engine)
	var note_data = clip.add_midi_note(note_id, midi_note_num, 100, tick_position, default_length_ticks)
	print("[MidiEditor] Added note %d: MIDI=%d start=%d duration=%d (Track will sync)" % [note_data.id, midi_note_num, tick_position, default_length_ticks])

	# Create visual note instance
	var note_instance := visual_note_scene.instantiate()
	add_child(note_instance)

	# Bind to data
	note_instance.bind_to_note(note_data)

	# Position and size the visual note using the same method as updates
	_update_single_note_position(note_instance)
	
	print("Placed note: MIDI %d at tick %d (duration: %d)" % [midi_note_num, tick_position, default_length_ticks])
	
	# If requested, immediately start dragging the newly placed note
	if start_dragging:
		_start_place_and_drag(note_instance)
	else:
		# Only update width if not dragging (will update on drag end)
		update_container_width()
	
	return note_instance

func _update_note_positions() -> void:
	"""Update positions of all note instances based on current zoom and scroll."""
	# Don't update any notes while user is dragging or resizing
	# TODO: why?
	if dragging_note or resizing_note:
		return
	
	# Can't position notes without grid_helper
	if not grid_helper:
		return
	
	# Use visual_notes array instead of iterating children
	for note in get_children():
		if note is VisualNote and note.midi_note_data:
			_update_single_note_position(note)

func _update_single_note_position(note: VisualNote) -> void:
	"""Update the position and size of a single visual note."""
	if not note.midi_note_data:
		return
	
	var note_data = note.midi_note_data
	var note_x = ticks_to_pixels(note_data.start_tick)
	var note_y = note_to_y(note_data.note)
	var note_width = ticks_to_pixels(note_data.duration_ticks)
	
	note.position = Vector2(note_x, note_y)
	note.size = Vector2(note_width, note_height)

	# Update label visibility based on current note height
	note.update_label_visibility(note_height)

func _load_clip_notes() -> void:
	selected_note = null
	
	# Load all notes from clip and assign IDs
	var project = Sonara.editor.project

	for note_data in clip.midi_notes:
		# Assign note ID if not already assigned
		# TODO: this should be handled elsewhere, not here.
		if note_data.id < 0:
			note_data.id = project.next_note_id
			project.next_note_id += 1

		# Note: Track will sync to audio engine via Clip signals, no need to call AudioEngineOSC here
		var note_instance = visual_note_scene.instantiate()
		add_child(note_instance)

		# Bind to data
		note_instance.bind_to_note(note_data)
	
	# Update all note positions
	_update_note_positions()
	
	# Update container width to accommodate all notes
	update_container_width()
	
	print("[MidiEditor] Loaded %d notes from clip '%s'" % [clip.midi_notes.size(), clip.name])


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
# INPUT
# ============================================================================
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mevent = event as InputEventMouseButton
		
		# Left mouse button - place note and drag, or box select with Ctrl
		if mevent.button_index == MOUSE_BUTTON_LEFT:
			if mevent.is_pressed():
				# Ctrl+Click starts box selection
				if mevent.ctrl_pressed:
					_start_box_selection(mevent.position)
					interaction_mode = InteractionMode.BOX_SELECTING
					accept_event()
				else:
					# Check if clicking on an existing note
					var clicked_note = _get_note_at_position(mevent.position)
					if clicked_note:
						# Start dragging or resizing existing note
						if clicked_note._is_over_resize_handle(clicked_note.get_local_mouse_position()):
							_on_resize_started(clicked_note)
							interaction_mode = InteractionMode.RESIZING
						else:
							_on_drag_started(clicked_note)
							interaction_mode = InteractionMode.DRAGGING
					else:
						# Place new note and start dragging
						_place_note_at_position(mevent.position, true)
					accept_event()
			else:
				# Release - end whatever interaction was happening
				if interaction_mode == InteractionMode.BOX_SELECTING:
					_end_box_selection()
					interaction_mode = InteractionMode.NONE
					accept_event()
				elif interaction_mode == InteractionMode.DRAGGING or interaction_mode == InteractionMode.PLACING_AND_DRAGGING:
					if dragging_note:
						_on_drag_ended(dragging_note)
					interaction_mode = InteractionMode.NONE
				elif interaction_mode == InteractionMode.RESIZING:
					if resizing_note:
						_on_resize_ended(resizing_note)
					interaction_mode = InteractionMode.NONE
				accept_event()
		
		# Right mouse button - erase mode
		elif mevent.button_index == MOUSE_BUTTON_RIGHT:
			if mevent.is_pressed():
				# Start erase mode
				interaction_mode = InteractionMode.ERASING
				erasing_mode = true
				last_erased_note = null
				
				# Immediately erase note under cursor if any
				var note_to_erase = _get_note_at_position(mevent.position)
				if note_to_erase:
					_erase_note(note_to_erase)
				accept_event()
			elif mevent.is_released():
				# End erase mode
				interaction_mode = InteractionMode.NONE
				erasing_mode = false
				last_erased_note = null
				accept_event()
	
	elif event is InputEventMouseMotion:
		var mevent = event as InputEventMouseMotion
		
		# Handle active interactions
		if interaction_mode == InteractionMode.BOX_SELECTING:
			_update_box_selection(mevent.position)
			accept_event()
		
		elif interaction_mode == InteractionMode.DRAGGING or interaction_mode == InteractionMode.PLACING_AND_DRAGGING:
			if dragging_note:
				_on_drag_updated(dragging_note, get_global_mouse_position())
				accept_event()
		
		elif interaction_mode == InteractionMode.RESIZING:
			if resizing_note:
				_on_resize_updated(resizing_note, get_global_mouse_position())
				accept_event()
		
		elif interaction_mode == InteractionMode.ERASING:
			# Continuously erase notes under cursor
			var note_to_erase = _get_note_at_position(mevent.position)
			if note_to_erase and note_to_erase != last_erased_note:
				_erase_note(note_to_erase)
			accept_event()
	
	elif event is InputEventKey:
		# Copy (Ctrl+C)
		if event.is_action_pressed("ui_copy"):
			print("copying selection at ", cursor_position_ticks)
			copy_selection()
			accept_event()
		
		# Cut (Ctrl+X)
		elif event.is_action_pressed("ui_cut"):
			print("cutting selection at ", cursor_position_ticks)
			cut_selection()
			accept_event()
		
		# Paste (Ctrl+V)
		elif event.is_action_pressed("ui_paste"):
			print("pasting selection at ", cursor_position_ticks)
			# Paste at playhead position or mouse position
			paste_at_position(cursor_position_ticks)
			accept_event()
		
		# Duplicate (Ctrl+D)
		elif event.is_action_pressed("ui_duplicate"):
			print("duplicating selection at ", cursor_position_ticks)
			duplicate_selection()
			accept_event()
		
		# Delete (Delete key or Backspace)
		elif event.is_action_pressed("ui_delete"):
			print("deleting selection at ", cursor_position_ticks)
			delete_selection()
			accept_event()

# ============================================================================
# HELPER METHODS
# ============================================================================
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


func _erase_note(note: VisualNote) -> void:
	"""Erase a note immediately."""
	if not note or not note.midi_note_data:
		return
	
	# Track this as the last erased note to avoid erasing it multiple times
	last_erased_note = note
	
	# Remove from clip (clip will emit signal, Track will sync to engine)
	if clip:
		clip.remove_midi_note(note.midi_note_data)
		print("[MidiEditor] Erased note %d (Track will sync)" % note.midi_note_data.id)
	
	# Remove from visual tracking
	visual_notes.erase(note)
	if selected_note == note:
		selected_note = null
	
	# Remove from scene
	note.queue_free()
	
	# Update container width in case we removed the rightmost note
	call_deferred("update_container_width")


func _start_place_and_drag(note: VisualNote) -> void:
	"""Start dragging a newly placed note."""
	if not note or not note.midi_note_data:
		return
	
	interaction_mode = InteractionMode.PLACING_AND_DRAGGING
	dragging_note = note
	drag_start_ticks = note.midi_note_data.start_tick
	drag_start_midi_note = note.midi_note_data.note
	drag_start_mouse_pos = get_global_mouse_position()
	
	# Select the note
	if selected_note and selected_note != note:
		selected_note.set_selected(false)
	selected_note = note
	note.set_selected(true)
	
	print("[MidiEditor] Started place-and-drag for note %d" % note.midi_note_data.id)


# ============================================================================
# BOX SELECTION
# ============================================================================
func _start_box_selection(pos: Vector2) -> void:
	# Clear current selection
	_clear_selection()

	"""Start box selection at the given position."""
	box_selection_start = pos
	box_selection_current = pos
	is_box_selecting = true
	
	# Reset box selection tick range
	_update_box_selection(pos)
	
	# Force redraw to show selection box
	queue_redraw()


func _update_box_selection(pos: Vector2) -> void:
	"""Update box selection as mouse moves."""
	if not is_box_selecting:
		return
	
	box_selection_current = pos
	
	# Snap selection box boundaries to grid
	var snapped_start = _snap_position_to_grid(box_selection_start)
	var snapped_current = _snap_position_to_grid(box_selection_current)
	
	# Create rect from snapped positions (handle any drag direction)
	box_selection_rect = Rect2(snapped_start, Vector2.ZERO)
	box_selection_rect = box_selection_rect.expand(snapped_current)
	
	# Calculate the time range of the box selection
	var start_tick = pixels_to_ticks(box_selection_rect.position.x)
	var end_tick = pixels_to_ticks(box_selection_rect.position.x + box_selection_rect.size.x)
	box_selection_start_tick = min(start_tick, end_tick)
	box_selection_end_tick = max(start_tick, end_tick)
	
	# Update which notes are selected based on current box
	_update_selected_notes_from_box()
	
	# Redraw to show updated selection box
	queue_redraw()


func _end_box_selection() -> void:
	"""End box selection and finalize the selection."""
	if not is_box_selecting:
		return
	
	is_box_selecting = false
	
	# Final update of selection
	_update_selected_notes_from_box()
	
	# Emit selection changed signal
	selection_changed.emit(selected_notes)
	
	# Redraw to hide selection box
	queue_redraw()
	
	print("[NoteEditor] Ended box selection - %d notes selected" % selected_notes.size())


func _snap_position_to_grid(pos: Vector2) -> Vector2:
	"""Snap a position to the grid (time grid for X, note height for Y)."""
	var snapped_pos = pos
	
	# Snap Y to note height boundaries
	var note_num = y_to_note(pos.y)
	snapped_pos.y = note_to_y(note_num)
	
	# Snap X to time grid
	var ticks = pixels_to_ticks(pos.x)
	if grid_helper:
		ticks = grid_helper.snap_ticks(ticks)
	snapped_pos.x = ticks_to_pixels(ticks)
	
	return snapped_pos


func _update_selected_notes_from_box() -> void:
	"""Update the selected_notes array based on current box_selection_rect."""
	# Clear previous selection visuals
	for note in selected_notes:
		if is_instance_valid(note):
			note.set_selected(false)
	selected_notes.clear()
	
	# Find all notes that intersect with selection box
	for child in get_children():
		if child is VisualNote:
			var note_rect = Rect2(child.position, child.size)
			if box_selection_rect.intersects(note_rect):
				selected_notes.append(child)
				child.set_selected(true)
	
	# Update legacy single selection reference
	if selected_notes.size() > 0:
		selected_note = selected_notes[0]
	else:
		selected_note = null


func _clear_selection() -> void:
	"""Clear all selected notes."""
	for note in selected_notes:
		if is_instance_valid(note):
			note.set_selected(false)
	selected_notes.clear()
	selected_note = null


func _draw() -> void:
	"""Draw the selection box when box selecting."""
	if is_box_selecting and box_selection_rect.size.length() > 0:
		# Draw semi-transparent white fill
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.1))
		
		# Draw white border
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.5), false, 2.0)


# ============================================================================
# CLIPBOARD OPERATIONS
# ============================================================================
func copy_selection() -> void:
	"""Copy selected notes to clipboard."""
	if selected_notes.is_empty():
		print("[NoteEditor] No notes selected to copy")
		return
	
	# Create selection with actual box selection time range if available
	if box_selection_start_tick > 0 or box_selection_end_tick > 0:
		# Use the actual box selection time range (preserves empty space)
		clipboard = NoteSelection.from_visual_notes_with_range(
			selected_notes, 
			box_selection_start_tick, 
			box_selection_end_tick
		)
	else:
		# Fallback to note bounding box (for single-click selections)
		clipboard = NoteSelection.from_visual_notes(selected_notes)
	
	print("[NoteEditor] Copied %d notes (duration: %d ticks)" % [clipboard.notes.size(), clipboard.duration_ticks])


func cut_selection() -> void:
	"""Cut selected notes (copy + delete)."""
	if selected_notes.is_empty():
		print("[NoteEditor] No notes selected to cut")
		return
	
	# Copy to clipboard
	copy_selection()
	
	# Delete selected notes
	delete_selection()
	
	print("[NoteEditor] Cut %d notes" % clipboard.notes.size())


func paste_at_position(tick_position: int) -> void:
	"""Paste clipboard contents at the specified tick position."""
	if not clipboard or clipboard.is_empty():
		print("[NoteEditor] Clipboard is empty")
		return
	
	if not clip:
		print("[NoteEditor] No clip loaded")
		return
	
	# Snap to grid
	var snap = get_snap_interval()
	if snap > 0:
		@warning_ignore("integer_division")
		tick_position = (tick_position / snap) * snap
	
	# Get notes positioned at the paste location
	var notes_to_paste = clipboard.get_notes_at_position(tick_position)
	
	# Clear current selection
	_clear_selection()
	
	# Add notes to clip and create visual representations
	var project = Sonara.editor.project
	for note_data in notes_to_paste:
		# Assign unique ID
		note_data.id = project.next_note_id
		project.next_note_id += 1
		
		# Add to clip (clip will emit signal, Track will sync to engine)
		clip.add_midi_note_data(note_data)
		
		# Create visual note
		var note_instance = visual_note_scene.instantiate()
		add_child(note_instance)
		note_instance.bind_to_note(note_data)
		
		# Add to new selection
		selected_notes.append(note_instance)
		note_instance.set_selected(true)
	
	# Update positions and container width
	_update_note_positions()
	update_container_width()
	
	# Update single selection reference
	if selected_notes.size() > 0:
		selected_note = selected_notes[0]
	
	# Emit selection changed
	selection_changed.emit(selected_notes)
	
	print("[NoteEditor] Pasted %d notes at tick %d" % [notes_to_paste.size(), tick_position])


func duplicate_selection() -> void:
	"""Duplicate selected notes and place them immediately after the selection."""
	if selected_notes.is_empty():
		print("[NoteEditor] No notes selected to duplicate")
		return
	
	# Create selection from current notes with actual box selection time range
	# This preserves the spacing/duration of the original selection
	var selection: NoteSelection
	if box_selection_start_tick > 0 or box_selection_end_tick > 0:
		# Use the actual box selection time range (preserves empty space)
		selection = NoteSelection.from_visual_notes_with_range(
			selected_notes, 
			box_selection_start_tick, 
			box_selection_end_tick
		)
	else:
		# Fallback to note bounding box (for single-click selections)
		selection = NoteSelection.from_visual_notes(selected_notes)
	
	# Place duplicate right after the original selection ends
	var duplicate_position = selection.end_tick
	
	# Store in clipboard temporarily
	var old_clipboard = clipboard
	clipboard = selection
	
	# Paste at new position
	paste_at_position(duplicate_position)
	
	# Restore old clipboard
	clipboard = old_clipboard
	
	print("[NoteEditor] Duplicated %d notes (selection duration: %d ticks)" % [selection.notes.size(), selection.duration_ticks])


func delete_selection() -> void:
	"""Delete all selected notes."""
	if selected_notes.is_empty():
		print("[NoteEditor] No notes selected to delete")
		return
	
	var count = selected_notes.size()
	
	# Remove notes in reverse to avoid index issues
	for i in range(selected_notes.size() - 1, -1, -1):
		var note = selected_notes[i]
		if is_instance_valid(note) and note.midi_note_data:
			# Remove from clip (clip will emit signal, Track will sync to engine)
			clip.remove_midi_note(note.midi_note_data)
			note.queue_free()
	
	# Clear selection arrays
	selected_notes.clear()
	selected_note = null
	
	# Emit selection changed
	selection_changed.emit(selected_notes)
	
	# Update container width
	call_deferred("update_container_width")
	
	print("[NoteEditor] Deleted %d notes" % count)


# ============================================================================
# GRID HELPER MANAGEMENT
# ============================================================================
func get_snap_interval() -> int:
	"""Get the current snap interval in ticks."""
	return grid_helper.get_snap_interval()


func _on_grid_helper_changed() -> void:
	"""Handle changes to grid helper (e.g. horizontal zoom, tempo, time signature)."""
	# Update all note positions and sizes to reflect new pixel-to-tick conversion
	_update_note_positions()
	
	# Update container width to reflect new zoom level
	update_container_width()


func update_container_width() -> void:
	"""Update the container's minimum width for infinite scrolling."""
	if not grid_helper:
		return
	
	# Get the horizontal scroll container (parent of this NoteEditor)
	var h_scroll = get_parent()
	if not h_scroll is ScrollContainer:
		return
	
	# Calculate minimum visible width based on viewport
	var ppq = grid_helper.ppq if grid_helper else 960
	var beats_per_bar = grid_helper.time_numerator if grid_helper else 4
	var min_width_ticks = min_width_bars * beats_per_bar * ppq
	var min_width_pixels = ticks_to_pixels(min_width_ticks)
	
	# Get current scroll position and viewport width
	var scroll_pos = h_scroll.scroll_horizontal
	var viewport_width = h_scroll.size.x
	
	# Find rightmost note position (start + duration)
	var rightmost_tick = 0
	for note in get_children():
		if note is VisualNote and note.midi_note_data:
			var note_end = note.midi_note_data.start_tick + note.midi_note_data.duration_ticks
			rightmost_tick = max(rightmost_tick, note_end)
	var rightmost_pixels = ticks_to_pixels(rightmost_tick)
	
	# Calculate required width for infinite scrolling:
	# - At minimum, show min_width_bars
	# - Always extend beyond current scroll position + viewport + extra space
	# - Always extend beyond rightmost note + extra space
	var extra_ticks = extra_width_bars * beats_per_bar * ppq
	var extra_pixels = ticks_to_pixels(extra_ticks)
	
	var width_from_scroll = scroll_pos + viewport_width + extra_pixels
	var width_from_content = rightmost_pixels + extra_pixels
	var required_width = max(min_width_pixels, width_from_scroll, width_from_content)
	
	# Set minimum width (allow infinite growth)
	custom_minimum_size.x = required_width


# ============================================================================
# NOTE INTERACTION HANDLERS
# ============================================================================
func _on_note_selected(note: VisualNote) -> void:
	"""Handle note selection (single note without modifiers)."""
	# Clear all previous selections
	_clear_selection()
	
	# Clear box selection tick range (this is a single note selection)
	box_selection_start_tick = 0
	box_selection_end_tick = 0
	
	# Select new note
	selected_note = note
	selected_notes = [note]
	note.set_selected(true)

	# set default note length to the note's duration
	default_note_length_ticks = note.midi_note_data.duration_ticks
	
	# Emit selection changed
	selection_changed.emit(selected_notes)


func _on_drag_started(note: VisualNote) -> void:
	"""Handle note drag start."""
	if not note.midi_note_data:
		return
	
	# Select the note
	_on_note_selected(note)
	
	dragging_note = note
	drag_start_ticks = note.midi_note_data.start_tick
	drag_start_midi_note = note.midi_note_data.note
	drag_start_mouse_pos = get_global_mouse_position()

func _on_drag_updated(note: VisualNote, mouse_pos_global: Vector2) -> void:
	"""Handle note drag update."""
	if dragging_note != note or not note.midi_note_data:
		return

	# Convert global positions to MidiEditor-local positions
	var mouse_local = make_canvas_position_local(mouse_pos_global)
	var start_local = make_canvas_position_local(drag_start_mouse_pos)

	# Calculate delta in MidiEditor-local pixels
	var delta = mouse_local - start_local

	# Convert to ticks and MIDI notes
	var delta_ticks = pixels_to_ticks(delta.x)
	var delta_notes = -int(delta.y / note_height)  # Negative because Y is inverted

	# Calculate new position
	var new_ticks = max(0, drag_start_ticks + delta_ticks)
	var new_midi_note = clamp(drag_start_midi_note + delta_notes, 0, 127)

	# Apply snapping for visual feedback
	if grid_helper:
		new_ticks = grid_helper.snap_ticks(new_ticks)

	# Update data layer immediately (visual feedback only, no audio sync yet)
	note.midi_note_data.start_tick = new_ticks
	note.midi_note_data.note = new_midi_note

	# Update visual position directly
	var note_x = ticks_to_pixels(new_ticks)
	var note_y = note_to_y(new_midi_note)
	note.position = Vector2(note_x, note_y)

func _on_drag_ended(note: VisualNote) -> void:
	"""Handle note drag end."""
	if dragging_note != note or not note.midi_note_data:
		return

	# Notify clip that note changed (clip will emit signal, Track will sync to engine)
	if clip:
		clip.update_midi_note(note.midi_note_data)
		print("[MidiEditor] Updated note %d position (Track will sync)" % note.midi_note_data.id)

	# Update container width in case note was moved to the right
	update_container_width()

	# Clear dragging state
	dragging_note = null

func _on_resize_started(note: VisualNote) -> void:
	"""Handle note resize start."""
	if not note.midi_note_data:
		return
	
	# Select the note
	_on_note_selected(note)
	
	resizing_note = note
	resize_start_duration = note.midi_note_data.duration_ticks
	resize_start_mouse_pos = get_global_mouse_position()

func _on_resize_updated(note: VisualNote, mouse_pos_global: Vector2) -> void:
	"""Handle note resize update."""
	if resizing_note != note or not note.midi_note_data:
		return

	# Convert global positions to MidiEditor-local positions
	var mouse_local = make_canvas_position_local(mouse_pos_global)
	var start_local = make_canvas_position_local(resize_start_mouse_pos)

	# Calculate delta in MidiEditor-local pixels
	var delta = mouse_local - start_local
	var delta_ticks = pixels_to_ticks(delta.x)

	# Calculate new duration
	var new_duration = max(get_snap_interval(), resize_start_duration + delta_ticks)

	# Apply snapping for visual feedback
	if grid_helper:
		var snap_interval = grid_helper.get_snap_interval()
		new_duration = max(snap_interval, new_duration)
		new_duration = int(new_duration / snap_interval) * snap_interval

	# Update data layer immediately (visual feedback only, no audio sync yet)
	note.midi_note_data.duration_ticks = new_duration

	# Update visual width directly
	var note_width = ticks_to_pixels(new_duration)
	note.size.x = note_width

func _on_resize_ended(note: VisualNote) -> void:
	"""Handle note resize end."""
	if resizing_note != note or not note.midi_note_data:
		return

	# Store the new note length as default for future notes
	default_note_length_ticks = note.midi_note_data.duration_ticks
	print("[MidiEditor] Updated default note length to %d ticks" % default_note_length_ticks)

	# Notify clip that note changed (clip will emit signal, Track will sync to engine)
	if clip:
		clip.update_midi_note(note.midi_note_data)
		print("[MidiEditor] Updated note %d duration (Track will sync)" % note.midi_note_data.id)

	# Update container width in case note was extended to the right
	update_container_width()

	# Clear resizing state
	resizing_note = null
