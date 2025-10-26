class_name NoteContainer extends Container

@export var note_height := 20.0:
	set(nh):
		if note_height != nh:
			note_height = nh
			# Notify parent ScrollContainer that our size changed
			update_minimum_size()
			# Some setting changed, ask for children re-sort.
			queue_sort()

@export var playhead_color = Color(1.0, 1.0, 1.0, 0.5)  # White with transparency
@export var playhead_width = 2.0

# MIDI range - use Midi singleton constants
const MIDI_MIN: int = Midi.MIDI_MIN    # C-2 (MIDI 0)
const MIDI_MAX: int = Midi.MIDI_MAX    # G9 (MIDI 127)
const MIDI_RANGE: int = MIDI_MAX - MIDI_MIN + 1


func _get_minimum_size() -> Vector2:
	# Total height for 128 MIDI notes (0-127)
	var total_height = 128 * note_height
	return Vector2(0, total_height)

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
var visual_notes_by_id: Dictionary = {}  # Map note ID -> VisualNote instance for fast lookups
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
# Track all selected notes' positions when starting multi-note drag
var drag_start_positions: Dictionary = {}  # note_id -> {start_tick: int, note: int}
var resizing_note: VisualNote = null
var resize_start_duration: int = 0
var resize_start_mouse_pos: Vector2 = Vector2.ZERO
# Track all selected notes' durations when starting multi-note resize
var resize_start_durations: Dictionary = {}  # note_id -> duration_ticks
# Track the last active drag mode to detect mode changes
enum DragMode { POSITION, RESIZE, VELOCITY }
var last_drag_mode: DragMode = DragMode.POSITION

# Newly placed note state (waiting for drag to start)
var placed_note_awaiting_drag: VisualNote = null
var placed_note_mouse_pos: Vector2 = Vector2.ZERO
const DRAG_THRESHOLD: float = 3.0  # Pixels to move before starting drag

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

# Playhead position (in clip-local ticks) - for visual playback indicator
var playhead_ticks: int = -1:
	set(value):
		if playhead_ticks != value:
			playhead_ticks = value
			queue_redraw()  # Redraw to update playhead position

# Default note length for new notes (in ticks)
var default_note_length_ticks: int = 960  # Default to 1 beat (960 ticks at 960 PPQ)

# Horizontal scrolling configuration
@export var min_width_bars: int = 8  # Minimum width in bars (4 beats each at 4/4)
@export var extra_width_bars: int = 4  # Extra space to the right of rightmost note

func unbind():
	# Disconnect from clip signals if bound
	if clip:
		if clip.midi_note_added.is_connected(_on_clip_note_added):
			clip.midi_note_added.disconnect(_on_clip_note_added)
		if clip.midi_note_removed.is_connected(_on_clip_note_removed):
			clip.midi_note_removed.disconnect(_on_clip_note_removed)
		if clip.midi_note_changed.is_connected(_on_clip_note_changed):
			clip.midi_note_changed.disconnect(_on_clip_note_changed)
	
	# Clear all visual notes
	for node in get_children():
		node.queue_free()
	
	visual_notes_by_id.clear()
	
	# Clear clip instance reference so that rebinding will reload notes
	clip_instance = null


func bind(ci : ClipInstance):
	print("[NoteEditor] bind called")
	print("  - clip_instance: ", ci)
	print("  - clip_id: ", ci.clip_id if ci else "null")
	print("  - clip property: ", str(ci.clip) if ci else "null")
	print("  - clip (computed): ", clip)
	
	if clip_instance != ci:
		if clip_instance:
			unbind()
		
		clip_instance = ci
		
		print("  - After assignment, clip property: ", str(ci.clip) if ci else "null")
		print("  - After assignment, clip (computed): ", clip)
		
		# Connect to clip signals for reactive updates
		if clip:
			clip.midi_note_added.connect(_on_clip_note_added)
			clip.midi_note_removed.connect(_on_clip_note_removed)
			clip.midi_note_changed.connect(_on_clip_note_changed)
		
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


func _place_note_at_position(pos: Vector2) -> VisualNote:
	"""Place a MIDI note at the given position. Drag will start if mouse moves."""
	if not clip:
		print("No clip loaded in MIDI editor")
		return null
	
	print("placing note at ", pos.y)
	
	# Clear any existing selection before placing new note
	_clear_selection()
	
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
	var end_tick = tick_position + default_length_ticks
	
	# Cut/merge overlapping notes at this pitch before adding the new note
	# The clip will emit signals for removed/changed notes, handled reactively
	var affected_notes = clip.cut_overlapping_notes_at_pitch(midi_note_num, tick_position, end_tick)
	
	if not affected_notes.is_empty():
		print("[NoteEditor] Cut/merged %d overlapping notes (handled reactively)" % affected_notes.size())
	
	# Get unique note ID from project
	var note_id = -1
	if Sonara and Sonara.editor and Sonara.editor.project:
		note_id = Sonara.editor.project.next_note_id
		Sonara.editor.project.next_note_id += 1
		#TODO: incremening ID can be handled by Clip itself.

	# Add note data to clip (clip will emit signal, reactive handler creates visual note)
	# Now that we've cut overlapping notes, this should succeed
	var note_data = clip.add_midi_note(note_id, midi_note_num, 100, tick_position, default_length_ticks)
	if note_data == null:
		push_error("[NoteEditor] Failed to add note after cutting overlaps - this shouldn't happen!")
		return null
	
	print("[MidiEditor] Added note %d: MIDI=%d start=%d duration=%d (Track will sync)" % [note_data.id, midi_note_num, tick_position, default_length_ticks])

	# Visual note was created reactively by _on_clip_note_added signal handler
	# Just retrieve it from the dictionary
	var note_instance = visual_notes_by_id.get(note_data.id)
	if note_instance == null:
		push_error("[NoteEditor] Failed to find visual note after creation - reactive system failed!")
		return null
	
	print("Placed note: MIDI %d at tick %d (duration: %d)" % [midi_note_num, tick_position, default_length_ticks])
	
	# Select only the newly placed note
	selected_note = note_instance
	selected_notes = [note_instance]
	note_instance.set_selected(true)
	
	# Set selection range for the newly placed note (enables duplicate/copy operations)
	box_selection_start_tick = tick_position
	box_selection_end_tick = tick_position + default_length_ticks
	queue_redraw()  # Show selection markers
	
	# Set up state to wait for drag to start (only if mouse moves)
	placed_note_awaiting_drag = note_instance
	placed_note_mouse_pos = get_global_mouse_position()
	
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
	print("[NoteEditor] _load_clip_notes called")
	print("  - clip: ", clip)
	print("  - clip_instance: ", clip_instance)
	
	if not clip:
		print("[NoteEditor] ERROR: No clip to load!")
		return
	
	selected_note = null
	visual_notes_by_id.clear()
	
	# Load all notes from clip and assign IDs
	var project = Sonara.editor.project

	for note_data in clip.midi_notes:
		# Assign note ID if not already assigned
		# TODO: this should be handled elsewhere, not here.
		if note_data.id < 0:
			note_data.id = project.next_note_id
			project.next_note_id += 1

		# Create visual note instance
		var note_instance = visual_note_scene.instantiate()
		add_child(note_instance)
		note_instance.bind_to_note(note_data)
		
		# Set color from track
		_apply_track_color_to_note(note_instance)
		
		# Track in dictionary for fast lookups
		visual_notes_by_id[note_data.id] = note_instance
	
	# Update all note positions
	_update_note_positions()
	
	# Update container width to accommodate all notes
	update_container_width()
	
	print("[MidiEditor] Loaded %d notes from clip '%s'" % [clip.midi_notes.size(), clip.name])


# ============================================================================
# REACTIVE SIGNAL HANDLERS - Clip data changes
# ============================================================================

func _on_clip_note_added(note_data: MidiNoteData) -> void:
	"""Handle when a note is added to the clip (reactive)."""
	# Check if we already have a visual note for this ID (shouldn't happen, but be defensive)
	if note_data.id in visual_notes_by_id:
		push_warning("[NoteEditor] Note %d already has a visual representation" % note_data.id)
		return
	
	# Create visual note instance
	var note_instance = visual_note_scene.instantiate()
	add_child(note_instance)
	note_instance.bind_to_note(note_data)
	
	# Set color from track
	_apply_track_color_to_note(note_instance)
	
	# Track in dictionary
	visual_notes_by_id[note_data.id] = note_instance
	
	# Update position
	_update_single_note_position(note_instance)
	
	# Update container width if needed
	update_container_width()
	
	print("[NoteEditor] Reactively added visual note %d" % note_data.id)


func _on_clip_note_removed(note_data: MidiNoteData) -> void:
	"""Handle when a note is removed from the clip (reactive)."""
	if note_data.id not in visual_notes_by_id:
		push_warning("[NoteEditor] Cannot remove visual note %d - not found" % note_data.id)
		return
	
	var note_instance = visual_notes_by_id[note_data.id]
	
	# Remove from selection if selected
	if note_instance in selected_notes:
		selected_notes.erase(note_instance)
	if selected_note == note_instance:
		selected_note = null
	
	# Remove from dictionary and scene
	visual_notes_by_id.erase(note_data.id)
	note_instance.queue_free()
	
	# Update container width if needed
	update_container_width()
	
	print("[NoteEditor] Reactively removed visual note %d" % note_data.id)


func _on_clip_note_changed(note_data: MidiNoteData) -> void:
	"""Handle when a note is modified in the clip (reactive)."""
	if note_data.id not in visual_notes_by_id:
		push_warning("[NoteEditor] Cannot update visual note %d - not found" % note_data.id)
		return
	
	var note_instance = visual_notes_by_id[note_data.id]
	
	# Update position/size (note_instance is already bound to note_data, which has been modified)
	_update_single_note_position(note_instance)
	
	# Update container width if needed
	update_container_width()
	
	print("[NoteEditor] Reactively updated visual note %d" % note_data.id)


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

func _unhandled_input(event: InputEvent) -> void:
	"""
	Global input handler - used to catch events that might be consumed by child nodes.
	Specifically handles right mouse button release to ensure erase mode always exits properly.
	"""
	if not visible or not is_visible_in_tree():
		return
	
	if event is InputEventMouseButton:
		var mevent = event as InputEventMouseButton
		
		# Always catch right mouse button release to exit erase mode
		if mevent.button_index == MOUSE_BUTTON_RIGHT and mevent.is_released():
			if erasing_mode or interaction_mode == InteractionMode.ERASING:
				print("[NoteEditor] Right mouse released - exiting erase mode (global handler)")
				interaction_mode = InteractionMode.NONE
				erasing_mode = false
				last_erased_note = null


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mevent = event as InputEventMouseButton
		
		# Left mouse button - place note and drag, or box select with Ctrl
		if mevent.button_index == MOUSE_BUTTON_LEFT:
			if mevent.is_pressed():
				# Check if clicking on an existing note
				var clicked_note = _get_note_at_position(mevent.position)
				if clicked_note:
					# Clicking on a note
					if mevent.ctrl_pressed:
						# Ctrl+Click on note: toggle selection
						_toggle_note_selection(clicked_note)
						accept_event()
					elif clicked_note._is_over_resize_handle(clicked_note.get_local_mouse_position()):
						# Start resizing existing note
						_on_resize_started(clicked_note, mevent.position)
						interaction_mode = InteractionMode.RESIZING
						accept_event()
					else:
						# Start dragging existing note
						_on_drag_started(clicked_note, mevent.position)
						interaction_mode = InteractionMode.DRAGGING
						accept_event()
				else:
					# Clicking on empty space
					if mevent.ctrl_pressed:
						# Ctrl+Click on empty space: start box selection
						_start_box_selection(mevent.position)
						interaction_mode = InteractionMode.BOX_SELECTING
						accept_event()
					else:
						# Place new note (drag will start if mouse moves)
						_place_note_at_position(mevent.position)
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
					accept_event()
				elif interaction_mode == InteractionMode.RESIZING:
					if resizing_note:
						_on_resize_ended(resizing_note)
					interaction_mode = InteractionMode.NONE
					accept_event()
				elif placed_note_awaiting_drag:
					# Mouse released without dragging - just finalize the placement
					print("[NoteEditor] Note placed without drag")
					update_container_width()
					placed_note_awaiting_drag = null
					accept_event()
				else:
					accept_event()
		
		# Right mouse button - erase mode
		elif mevent.button_index == MOUSE_BUTTON_RIGHT:
			if mevent.is_pressed():
				# Always start erase mode on right-click
				interaction_mode = InteractionMode.ERASING
				erasing_mode = true
				last_erased_note = null
				
				# Check if clicking on a note
				var note_under_cursor = _get_note_at_position(mevent.position)
				if note_under_cursor:
					# Erase the note immediately
					_erase_note(note_under_cursor)
					accept_event()
				else:
					# Right-click on empty space - also deselect all notes
					_clear_selection()
					print("[NoteEditor] Right-click on empty space - cleared selection, erase mode active")
					# Don't accept event - let it propagate for proper cursor handling
			elif mevent.is_released():
				# End erase mode
				interaction_mode = InteractionMode.NONE
				erasing_mode = false
				last_erased_note = null
				# Don't accept release event - let mouse events propagate normally
	
	elif event is InputEventMouseMotion:
		var mevent = event as InputEventMouseMotion
		
		# Check if we have a newly placed note waiting for drag to start
		if placed_note_awaiting_drag and placed_note_awaiting_drag.midi_note_data:
			var current_mouse_pos = get_global_mouse_position()
			var distance = current_mouse_pos.distance_to(placed_note_mouse_pos)
			
			if distance >= DRAG_THRESHOLD:
				# Mouse moved far enough - start dragging
				print("[NoteEditor] Starting drag after placement (moved %.1f pixels)" % distance)
				_start_place_and_drag(placed_note_awaiting_drag)
				placed_note_awaiting_drag = null
				accept_event()
				return
		
		# Handle active interactions
		if interaction_mode == InteractionMode.BOX_SELECTING:
			_update_box_selection(mevent.position)
			accept_event()
		
		elif interaction_mode == InteractionMode.DRAGGING or interaction_mode == InteractionMode.PLACING_AND_DRAGGING:
			if dragging_note:
				_on_drag_updated(dragging_note, mevent.position)
				accept_event()
		
		elif interaction_mode == InteractionMode.RESIZING:
			if resizing_note:
				_on_resize_updated(resizing_note, mevent.position)
				accept_event()
		
		elif interaction_mode == InteractionMode.ERASING:
			# Continuously erase notes under cursor
			var note_to_erase = _get_note_at_position(mevent.position)
			if note_to_erase and note_to_erase != last_erased_note:
				_erase_note(note_to_erase)
				accept_event()
			# Don't accept event if not erasing - let it propagate to VisualNotes for cursor updates
	
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
		
		# Arrow keys - move selected notes
		elif event.is_action_pressed("ui_up"):
			var semitones = 12 if event.ctrl_pressed else 1
			move_selection_vertical(semitones)
			accept_event()
		
		elif event.is_action_pressed("ui_down"):
			var semitones = 12 if event.ctrl_pressed else 1
			move_selection_vertical(-semitones)
			accept_event()
		
		elif event.is_action_pressed("ui_left"):
			move_selection_horizontal(-get_snap_interval())
			accept_event()
		
		elif event.is_action_pressed("ui_right"):
			move_selection_horizontal(get_snap_interval())
			accept_event()

# ============================================================================
# KEYBOARD NOTE MOVEMENT
# ============================================================================
func move_selection_vertical(semitones: int) -> void:
	"""Move all selected notes up or down by the specified number of semitones."""
	if selected_notes.is_empty():
		return
	
	# Move all selected notes
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		var note_data = sel_note.midi_note_data
		var new_pitch = clamp(note_data.note + semitones, 0, 127)
		note_data.note = new_pitch
		
		# Update visual position
		var note_y = note_to_y(new_pitch)
		sel_note.position.y = note_y
		sel_note._update_visual()
	
	# Process all notes for overlaps and sync
	var total_affected = 0
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks
		
		# Check for overlaps at new pitch
		var affected_notes = clip.cut_overlapping_notes_at_pitch(
			note_data.note, 
			note_data.start_tick, 
			end_tick,
			note_data.id
		)
		
		total_affected += affected_notes.size()
		
		# Sync to engine
		if clip:
			clip.update_midi_note(note_data)
	
	if total_affected > 0:
		print("[NoteEditor] Keyboard move vertical - cut/merged %d overlapping notes" % total_affected)
	
	print("[NoteEditor] Moved %d note(s) %+d semitones" % [selected_notes.size(), semitones])
	
	# Update selection range (no change in time, only pitch)
	# Selection range stays the same since we didn't move horizontally
	
	update_container_width()


func move_selection_horizontal(delta_ticks: int) -> void:
	"""Move all selected notes left or right by the specified number of ticks."""
	if selected_notes.is_empty():
		return
	
	# Move all selected notes
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		var note_data = sel_note.midi_note_data
		var new_start = max(0, note_data.start_tick + delta_ticks)
		note_data.start_tick = new_start
		
		# Update visual position
		var note_x = ticks_to_pixels(new_start)
		sel_note.position.x = note_x
	
	# Process all notes for overlaps and sync
	var total_affected = 0
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks
		
		# Check for overlaps at new position
		var affected_notes = clip.cut_overlapping_notes_at_pitch(
			note_data.note, 
			note_data.start_tick, 
			end_tick,
			note_data.id
		)
		
		total_affected += affected_notes.size()
		
		# Sync to engine
		if clip:
			clip.update_midi_note(note_data)
	
	if total_affected > 0:
		print("[NoteEditor] Keyboard move horizontal - cut/merged %d overlapping notes" % total_affected)
	
	print("[NoteEditor] Moved %d note(s) %+d ticks" % [selected_notes.size(), delta_ticks])
	
	# Update selection range to reflect new positions
	if not selected_notes.is_empty():
		var first_note = true
		for sel_note in selected_notes:
			if not sel_note.midi_note_data:
				continue
			var note_data = sel_note.midi_note_data
			var note_start = note_data.start_tick
			var note_end = note_data.start_tick + note_data.duration_ticks
			
			if first_note:
				box_selection_start_tick = note_start
				box_selection_end_tick = note_end
				first_note = false
			else:
				box_selection_start_tick = min(box_selection_start_tick, note_start)
				box_selection_end_tick = max(box_selection_end_tick, note_end)
		
		queue_redraw()  # Update selection markers
	
	update_container_width()


# ============================================================================
# HELPER METHODS
# ============================================================================
func _apply_track_color_to_note(note_instance: VisualNote) -> void:
	"""Apply the track color to a visual note instance."""
	if clip_instance and clip_instance.track:
		note_instance.set_color(clip_instance.track.color)
	else:
		# Fallback to default color if no track available
		note_instance.set_color(Color(0.3, 0.6, 0.9))


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
	
	# Remove from clip (clip will emit signal, reactive handler will remove visual note)
	if clip:
		clip.remove_midi_note(note.midi_note_data)
		print("[MidiEditor] Erased note %d (Track will sync, visual removal handled reactively)" % note.midi_note_data.id)
	
	# Note: visual note removal, selection cleanup, scene cleanup, and container width update
	# are all handled by the reactive _on_clip_note_removed signal handler


func _start_place_and_drag(note: VisualNote) -> void:
	"""Start dragging a newly placed note."""
	if not note or not note.midi_note_data:
		return
	
	interaction_mode = InteractionMode.PLACING_AND_DRAGGING
	dragging_note = note
	drag_start_ticks = note.midi_note_data.start_tick
	drag_start_midi_note = note.midi_note_data.note
	drag_start_mouse_pos = get_local_mouse_position()
	last_drag_mode = DragMode.POSITION  # Reset mode at start of drag
	
	# Select the note
	if selected_note and selected_note != note:
		selected_note.set_selected(false)
	selected_note = note
	note.set_selected(true)
	
	# Store starting positions, durations, and velocities for selected notes
	drag_start_positions.clear()
	resize_start_durations.clear()
	for sel_note in selected_notes:
		if sel_note.midi_note_data:
			drag_start_positions[sel_note.midi_note_data.id] = {
				"start_tick": sel_note.midi_note_data.start_tick,
				"note": sel_note.midi_note_data.note,
				"velocity": sel_note.midi_note_data.velocity
			}
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks
	
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
	
	# If no notes were selected, invalidate the selection (zero-length with no notes)
	if selected_notes.is_empty():
		box_selection_start_tick = 0
		box_selection_end_tick = 0
		queue_redraw()
		print("[NoteEditor] Box selection cleared - no notes in range")
		return
	
	# Expand box selection time range to include all selected notes
	# This ensures copy/paste/duplicate operations preserve the full note range
	for visual_note in selected_notes:
		if not visual_note.midi_note_data:
			continue
		var note_data = visual_note.midi_note_data
		var note_start = note_data.start_tick
		var note_end = note_data.start_tick + note_data.duration_ticks
		
		# Expand selection range to include this note
		box_selection_start_tick = min(box_selection_start_tick, note_start)
		box_selection_end_tick = max(box_selection_end_tick, note_end)
	
	# Emit selection changed signal
	selection_changed.emit(selected_notes)
	
	# Redraw to hide selection box
	queue_redraw()
	
	print("[NoteEditor] Ended box selection - %d notes selected (range: %d-%d ticks)" % [
		selected_notes.size(), box_selection_start_tick, box_selection_end_tick
	])


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


func _toggle_note_selection(note: VisualNote) -> void:
	"""Toggle a note's selection state (for Ctrl+Click)."""
	if not note or not note.midi_note_data:
		return
	
	if note in selected_notes:
		# Note is already selected - remove it
		selected_notes.erase(note)
		note.set_selected(false)
		
		# Update single selection reference
		if selected_note == note:
			selected_note = selected_notes[0] if not selected_notes.is_empty() else null
	else:
		# Note is not selected - add it
		selected_notes.append(note)
		note.set_selected(true)
		
		# Update single selection reference
		if selected_notes.size() == 1:
			selected_note = note
	
	# Update selection range to encompass all selected notes
	if not selected_notes.is_empty():
		var first_note = true
		for sel_note in selected_notes:
			if not sel_note.midi_note_data:
				continue
			var note_data = sel_note.midi_note_data
			var note_start = note_data.start_tick
			var note_end = note_data.start_tick + note_data.duration_ticks
			
			if first_note:
				box_selection_start_tick = note_start
				box_selection_end_tick = note_end
				first_note = false
			else:
				box_selection_start_tick = min(box_selection_start_tick, note_start)
				box_selection_end_tick = max(box_selection_end_tick, note_end)
	else:
		# No notes selected - clear range
		box_selection_start_tick = 0
		box_selection_end_tick = 0
	
	# Emit selection changed
	selection_changed.emit(selected_notes)
	
	# Redraw to update selection markers
	queue_redraw()
	
	print("[NoteEditor] Toggled note selection - %d notes selected (range: %d-%d)" % [
		selected_notes.size(), box_selection_start_tick, box_selection_end_tick
	])


func _clear_selection() -> void:
	"""Clear all selected notes."""
	for note in selected_notes:
		if is_instance_valid(note):
			note.set_selected(false)
	selected_notes.clear()
	selected_note = null
	
	# Clear selection range
	box_selection_start_tick = 0
	box_selection_end_tick = 0
	
	# Redraw to hide selection markers
	queue_redraw()


func _draw() -> void:
	"""Draw the selection box when box selecting, selection range markers, and playhead."""
	var height = size.y
	
	# Draw box selection while actively selecting
	if is_box_selecting and box_selection_rect.size.length() > 0:
		# Draw semi-transparent white fill
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.1))
		
		# Draw white border
		draw_rect(box_selection_rect, Color(1.0, 1.0, 1.0, 0.5), false, 2.0)
	
	# Draw selection range markers when a valid selection exists (non-zero length)
	var selection_length = box_selection_end_tick - box_selection_start_tick
	if not selected_notes.is_empty() and selection_length > 0:
		var start_x = ticks_to_pixels(box_selection_start_tick)
		var end_x = ticks_to_pixels(box_selection_end_tick)
		
		# Draw vertical lines at selection boundaries
		var line_color = Color(0.4, 0.8, 1.0, 0.6)  # Light blue with transparency
		var line_width = 2.0
		
		# Start marker
		draw_line(Vector2(start_x, 0), Vector2(start_x, height), line_color, line_width)
		
		# End marker
		draw_line(Vector2(end_x, 0), Vector2(end_x, height), line_color, line_width)
	
	# Draw playhead line (clip-local position)
	if playhead_ticks >= 0:
		var playhead_x = ticks_to_pixels(playhead_ticks)
		draw_line(Vector2(playhead_x, 0), Vector2(playhead_x, height), playhead_color, playhead_width)


# ============================================================================
# CLIPBOARD OPERATIONS
# ============================================================================
func copy_selection() -> void:
	"""Copy selected notes to clipboard."""
	if selected_notes.is_empty():
		print("[NoteEditor] No notes selected to copy")
		return
	
	# Validate selection range
	var selection_length = box_selection_end_tick - box_selection_start_tick
	if selection_length <= 0:
		print("[NoteEditor] Cannot copy - invalid selection range (zero length)")
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
	
	# Cut overlapping notes for each note we're about to paste
	# Reactive signal handlers will remove/update affected visual notes automatically
	var total_affected = 0
	for note_data in notes_to_paste:
		var end_tick = note_data.start_tick + note_data.duration_ticks
		var affected = clip.cut_overlapping_notes_at_pitch(note_data.note, note_data.start_tick, end_tick)
		total_affected += affected.size()
	
	if total_affected > 0:
		print("[NoteEditor] Paste cut/merged %d overlapping notes (handled reactively)" % total_affected)
	
	# Clear current selection
	_clear_selection()
	
	# Add notes to clip and track their IDs for selection
	# Reactive signal handlers will create visual notes automatically
	var project = Sonara.editor.project
	var pasted_note_ids: Array[int] = []
	
	for note_data in notes_to_paste:
		# Assign unique ID
		note_data.id = project.next_note_id
		project.next_note_id += 1
		
		# Add to clip (clip will emit signal, reactive handler creates visual note)
		var added = clip.add_midi_note_data(note_data)
		if added == null:
			push_warning("[NoteEditor] Failed to paste note at pitch=%d, start=%d" % [note_data.note, note_data.start_tick])
			continue
		
		pasted_note_ids.append(note_data.id)
	
	# Select the newly pasted notes (created reactively by signal handlers)
	for note_id in pasted_note_ids:
		var note_instance = visual_notes_by_id.get(note_id)
		if note_instance:
			selected_notes.append(note_instance)
			note_instance.set_selected(true)
	
	# Update single selection reference
	if selected_notes.size() > 0:
		selected_note = selected_notes[0]
	
	# Set selection range for the pasted notes (enables chained duplicate operations)
	if not selected_notes.is_empty():
		# Calculate the range from the pasted position and clipboard duration
		box_selection_start_tick = tick_position
		box_selection_end_tick = tick_position + clipboard.duration_ticks
		queue_redraw()  # Show selection markers
	
	# Emit selection changed
	selection_changed.emit(selected_notes)
	
	print("[NoteEditor] Pasted %d notes at tick %d (range: %d-%d)" % [
		pasted_note_ids.size(), tick_position, box_selection_start_tick, box_selection_end_tick
	])


func duplicate_selection() -> void:
	"""Duplicate selected notes and place them immediately after the selection."""
	if selected_notes.is_empty():
		print("[NoteEditor] No notes selected to duplicate")
		return
	
	# Validate selection range
	var selection_length = box_selection_end_tick - box_selection_start_tick
	if selection_length <= 0:
		print("[NoteEditor] Cannot duplicate - invalid selection range (zero length)")
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
	for n in selected_notes:
		if is_instance_valid(n):
			n.set_selected(false)
	
	# Select new note
	selected_note = note
	selected_notes = [note]
	note.set_selected(true)
	
	# Set selection range to the note's bounds
	if note.midi_note_data:
		box_selection_start_tick = note.midi_note_data.start_tick
		box_selection_end_tick = note.midi_note_data.start_tick + note.midi_note_data.duration_ticks
	
	# set default note length to the note's duration
	default_note_length_ticks = note.midi_note_data.duration_ticks
	
	# Emit selection changed
	selection_changed.emit(selected_notes)
	
	# Redraw to show selection markers
	queue_redraw()


func _on_drag_started(note: VisualNote, click_position: Vector2) -> void:
	"""Handle note drag start (supports multi-note drag)."""
	if not note.midi_note_data:
		return
	
	# If the note isn't already selected, select only it
	if note not in selected_notes:
		_on_note_selected(note)
	
	dragging_note = note
	drag_start_ticks = note.midi_note_data.start_tick
	drag_start_midi_note = note.midi_note_data.note
	drag_start_mouse_pos = click_position
	last_drag_mode = DragMode.POSITION  # Reset mode at start of drag
	
	# Store starting positions, durations, and velocities for all selected notes
	drag_start_positions.clear()
	resize_start_durations.clear()
	for sel_note in selected_notes:
		if sel_note.midi_note_data:
			drag_start_positions[sel_note.midi_note_data.id] = {
				"start_tick": sel_note.midi_note_data.start_tick,
				"note": sel_note.midi_note_data.note,
				"velocity": sel_note.midi_note_data.velocity
			}
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks

func _on_drag_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	"""Handle note drag update (supports multi-note drag, shift-to-resize, and alt-for-velocity)."""
	if dragging_note != note or not note.midi_note_data:
		return

	# Check modifier keys to determine current drag mode
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
	
	# Check if mode changed - if so, reset reference point
	if current_mode != last_drag_mode:
		drag_start_mouse_pos = mouse_pos_local
		
		# Update stored starting positions/durations/velocities to current state
		for sel_note in selected_notes:
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
	
	# Calculate deltas
	var delta_x = mouse_pos_local.x - drag_start_mouse_pos.x
	var delta_y = mouse_pos_local.y - drag_start_mouse_pos.y
	var delta_ticks = pixels_to_ticks(delta_x)
	
	if alt_pressed:
		# Alt mode: Control velocity with Y-axis movement
		# Map Y movement to velocity change (negative Y = higher velocity)
		var velocity_delta = int(-delta_y / 2.0)  # Scale factor for sensitivity
		
		for sel_note in selected_notes:
			if not sel_note.midi_note_data:
				continue
			
			var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
			if not start_pos:
				continue
			
			# Calculate new velocity
			var start_velocity = start_pos.get("velocity", 100)
			var new_velocity = clamp(start_velocity + velocity_delta, 1, 127)
			
			# Update data layer immediately (visual feedback only, no audio sync yet)
			sel_note.midi_note_data.velocity = new_velocity
			
			# Update visual to reflect new velocity
			sel_note._update_visual()
	
	elif shift_pressed:
		# Shift mode: Control note length instead of position
		for sel_note in selected_notes:
			if not sel_note.midi_note_data:
				continue
			
			var start_duration = resize_start_durations.get(sel_note.midi_note_data.id)
			if start_duration == null:
				continue
			
			# Calculate new duration from horizontal mouse movement
			var new_duration = max(get_snap_interval(), start_duration + delta_ticks)
			
			# Apply snapping for visual feedback
			if grid_helper:
				var snap_interval = grid_helper.get_snap_interval()
				new_duration = max(snap_interval, new_duration)
				@warning_ignore("integer_division")
				new_duration = int(new_duration / snap_interval) * snap_interval
			
			# Update data layer immediately (visual feedback only, no audio sync yet)
			sel_note.midi_note_data.duration_ticks = new_duration
			
			# Update visual width directly
			var note_width = ticks_to_pixels(new_duration)
			sel_note.size.x = note_width
	else:
		# Normal mode: Control position
		# Calculate Y delta (in MIDI note numbers)
		var current_midi_note = y_to_note(mouse_pos_local.y)
		var delta_midi_note = current_midi_note - drag_start_midi_note

		# Update all selected notes
		for sel_note in selected_notes:
			if not sel_note.midi_note_data:
				continue
			
			var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
			if not start_pos:
				continue
			
			# Calculate new position for this note
			var new_ticks = max(0, start_pos.start_tick + delta_ticks)
			var new_midi_note = clamp(start_pos.note + delta_midi_note, 0, 127)
			
			# Apply snapping for visual feedback
			if grid_helper:
				new_ticks = grid_helper.snap_ticks(new_ticks)
			
			# Update data layer immediately (visual feedback only, no audio sync yet)
			sel_note.midi_note_data.start_tick = new_ticks
			sel_note.midi_note_data.note = new_midi_note
			
			# Update visual position directly
			var note_x = ticks_to_pixels(new_ticks)
			var note_y = note_to_y(new_midi_note)
			sel_note.position = Vector2(note_x, note_y)
			
			# Update the note's label to show the new pitch
			sel_note._update_visual()

func _on_drag_ended(note: VisualNote) -> void:
	"""Handle note drag end (supports multi-note drag)."""
	if dragging_note != note or not note.midi_note_data:
		return
	
	# Check if any note actually changed (position, duration, or velocity)
	var any_changes = false
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
		var start_duration = resize_start_durations.get(sel_note.midi_note_data.id)
		
		# Check for position change, duration change, or velocity change
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
		# No notes changed - no need to update or check overlaps
		print("[NoteEditor] Drag ended with no changes - skipping update")
		dragging_note = null
		drag_start_positions.clear()
		resize_start_durations.clear()
		update_container_width()
		return
	
	# Process all selected notes
	var total_affected = 0
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks
		
		# Check if this note now overlaps with any other notes at the same pitch
		# Cut/merge those notes if needed (exclude this note from comparison)
		# Reactive signal handlers will update/remove affected visual notes automatically
		var affected_notes = clip.cut_overlapping_notes_at_pitch(
			note_data.note, 
			note_data.start_tick, 
			end_tick,
			note_data.id  # Exclude this note from comparison
		)
		
		total_affected += affected_notes.size()
		
		# Update this note in the clip (will emit signal and reactive handler will update visual)
		if clip:
			clip.update_midi_note(note_data)
	
	if total_affected > 0:
		print("[NoteEditor] Multi-drag ended - cut/merged %d overlapping notes (handled reactively)" % total_affected)
	
	print("[MidiEditor] Updated %d note(s) position/duration (Track will sync)" % selected_notes.size())
	
	# Update selection range to reflect new note positions
	if not selected_notes.is_empty():
		# Find the actual bounding box of all selected notes
		var first_note = true
		for sel_note in selected_notes:
			if not sel_note.midi_note_data:
				continue
			var note_data = sel_note.midi_note_data
			var note_start = note_data.start_tick
			var note_end = note_data.start_tick + note_data.duration_ticks
			
			if first_note:
				box_selection_start_tick = note_start
				box_selection_end_tick = note_end
				first_note = false
			else:
				box_selection_start_tick = min(box_selection_start_tick, note_start)
				box_selection_end_tick = max(box_selection_end_tick, note_end)
		
		# Redraw to update selection markers
		queue_redraw()
		print("[NoteEditor] Updated selection range after drag: %d-%d ticks" % [box_selection_start_tick, box_selection_end_tick])

	# Update container width in case notes were moved to the right
	update_container_width()

	# Clear dragging state
	dragging_note = null
	drag_start_positions.clear()
	resize_start_durations.clear()

func _on_resize_started(note: VisualNote, click_position: Vector2) -> void:
	"""Handle note resize start (supports multi-note resize)."""
	if not note.midi_note_data:
		return
	
	# If the note isn't already selected, select only it
	if note not in selected_notes:
		_on_note_selected(note)
	
	resizing_note = note
	resize_start_duration = note.midi_note_data.duration_ticks
	resize_start_mouse_pos = click_position
	
	# Store starting durations for all selected notes (for multi-note resize)
	resize_start_durations.clear()
	for sel_note in selected_notes:
		if sel_note.midi_note_data:
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks

func _on_resize_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	"""Handle note resize update (supports multi-note resize)."""
	if resizing_note != note or not note.midi_note_data:
		return

	# Calculate delta in local coordinates
	var delta = mouse_pos_local - resize_start_mouse_pos
	var delta_ticks = pixels_to_ticks(delta.x)

	# Calculate new duration for the main note
	var new_duration = max(get_snap_interval(), resize_start_duration + delta_ticks)

	# Apply snapping for visual feedback
	if grid_helper:
		var snap_interval = grid_helper.get_snap_interval()
		new_duration = max(snap_interval, new_duration)
		new_duration = int(new_duration / snap_interval) * snap_interval

	# Check if shift is pressed for absolute resize mode
	var shift_pressed = Input.is_key_pressed(KEY_SHIFT)
	
	# Update all selected notes
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		var note_new_duration: int
		
		if shift_pressed:
			# Shift mode: Set all notes to the same duration as the resized note
			note_new_duration = new_duration
		else:
			# Default mode: Apply the same delta to each note (relative resize)
			var note_start_duration = resize_start_durations.get(sel_note.midi_note_data.id, sel_note.midi_note_data.duration_ticks)
			note_new_duration = max(get_snap_interval(), note_start_duration + delta_ticks)
			
			# Apply snapping
			if grid_helper:
				var snap_interval = grid_helper.get_snap_interval()
				note_new_duration = max(snap_interval, note_new_duration)
				@warning_ignore("integer_division")
				note_new_duration = int(note_new_duration / snap_interval) * snap_interval
		
		# Update data layer immediately (visual feedback only, no audio sync yet)
		sel_note.midi_note_data.duration_ticks = note_new_duration
		
		# Update visual width directly
		var note_width = ticks_to_pixels(note_new_duration)
		sel_note.size.x = note_width

func _on_resize_ended(note: VisualNote) -> void:
	"""Handle note resize end (supports multi-note resize)."""
	if resizing_note != note or not note.midi_note_data:
		return

	# Store the new note length as default for future notes
	default_note_length_ticks = note.midi_note_data.duration_ticks
	print("[MidiEditor] Updated default note length to %d ticks" % default_note_length_ticks)
	
	# Process all selected notes
	var total_affected = 0
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks
		
		# Check if this note now overlaps with any other notes at the same pitch
		# Cut/merge those notes if needed (exclude this note from comparison)
		# Reactive signal handlers will update/remove affected visual notes automatically
		var affected_notes = clip.cut_overlapping_notes_at_pitch(
			note_data.note, 
			note_data.start_tick, 
			end_tick,
			note_data.id  # Exclude this note from comparison
		)
		
		total_affected += affected_notes.size()
		
		# Update this note in the clip (will emit signal and reactive handler will update visual)
		if clip:
			clip.update_midi_note(note_data)
	
	if total_affected > 0:
		print("[NoteEditor] Multi-resize ended - cut/merged %d overlapping notes (handled reactively)" % total_affected)
	
	print("[MidiEditor] Updated %d note(s) duration (Track will sync)" % selected_notes.size())
	
	# Update selection range to reflect new note durations
	if not selected_notes.is_empty():
		# Find the actual bounding box of all selected notes
		var first_note = true
		for sel_note in selected_notes:
			if not sel_note.midi_note_data:
				continue
			var note_data = sel_note.midi_note_data
			var note_start = note_data.start_tick
			var note_end = note_data.start_tick + note_data.duration_ticks
			
			if first_note:
				box_selection_start_tick = note_start
				box_selection_end_tick = note_end
				first_note = false
			else:
				box_selection_start_tick = min(box_selection_start_tick, note_start)
				box_selection_end_tick = max(box_selection_end_tick, note_end)
		
		# Redraw to update selection markers
		queue_redraw()
		print("[NoteEditor] Updated selection range after resize: %d-%d ticks" % [box_selection_start_tick, box_selection_end_tick])

	# Update container width in case notes were extended to the right
	update_container_width()

	# Clear resizing state
	resizing_note = null
	resize_start_durations.clear()
