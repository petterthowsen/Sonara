## Manages note selection state only.
## Does NOT handle container operations, coordinate conversions, or clip mutations.
## Those responsibilities belong to NoteEditor.
class_name NoteSelectionManager extends RefCounted


signal selection_changed(notes: Array[VisualNote])


# Selection state
var selected_note: VisualNote = null  # Currently selected note (legacy single selection)
var selected_notes: Array[VisualNote] = []  # Multiple selected notes


# Clipboard for copy/paste operations
var clipboard: NoteSelection


# Box selection state
var box_selection_start: Vector2 = Vector2.ZERO
var box_selection_current: Vector2 = Vector2.ZERO
var box_selection_rect: Rect2 = Rect2()
var is_box_selecting: bool = false
var box_selection_start_tick: int = 0
var box_selection_end_tick: int = 0


# Reference to grid helper (for time snapping only)
var grid_helper: GridHelper


# Coordinate conversion callback
# This allows the container to provide the correct coordinate space (song-relative or clip-local)
# without NoteSelectionManager needing to know about modes, clips, or offsets
var get_note_song_position: Callable = func(note: VisualNote) -> Dictionary:
	# Default: use clip-local coordinates from note data
	if note and note.midi_note_data:
		return {
			"start_tick": note.midi_note_data.start_tick,
			"end_tick": note.midi_note_data.start_tick + note.midi_note_data.duration_ticks
		}
	return {"start_tick": 0, "end_tick": 0}


func _init(gh: GridHelper) -> void:
	grid_helper = gh


# ============================================================================
# BOX SELECTION
# ============================================================================
func start_box_selection(pos: Vector2) -> void:
	"""Start box selection at the given position."""
	clear_selection()
	box_selection_start = pos
	box_selection_current = pos
	is_box_selecting = true
	_update_box_selection(pos)


func update_box_selection(pos: Vector2) -> void:
	"""Update box selection as mouse moves."""
	if not is_box_selecting:
		return

	box_selection_current = pos

	# Snap selection box boundaries to grid (X only)
	var snapped_start_x = _snap_x_to_grid(box_selection_start.x)
	var snapped_current_x = _snap_x_to_grid(pos.x)

	# Create rect from snapped positions
	box_selection_rect = Rect2(
		Vector2(snapped_start_x, box_selection_start.y),
		Vector2.ZERO
	)
	box_selection_rect = box_selection_rect.expand(Vector2(snapped_current_x, pos.y))

	# Calculate the time range of the box selection
	var start_tick = grid_helper.pixels_to_ticks(box_selection_rect.position.x)
	var end_tick = grid_helper.pixels_to_ticks(box_selection_rect.position.x + box_selection_rect.size.x)
	box_selection_start_tick = min(start_tick, end_tick)
	box_selection_end_tick = max(start_tick, end_tick)


func end_box_selection(notes_in_box: Array[VisualNote]) -> void:
	"""End box selection with the list of notes that were selected."""
	if not is_box_selecting:
		return

	is_box_selecting = false

	# Update selection with provided notes
	_set_selected_notes(notes_in_box)

	# KEEP boundaries at grid-snapped positions - NEVER adjust based on notes
	# This allows selecting empty space and ensures boundaries follow grid, not notes
	# The box_selection_start_tick and box_selection_end_tick were already set by update_box_selection()

	if selected_notes.is_empty():
		print("[NoteSelectionManager] Box selection completed - no notes, boundaries at grid: %d-%d" % [
			box_selection_start_tick, box_selection_end_tick
		])
	else:
		print("[NoteSelectionManager] Box selection completed - %d notes, boundaries at grid: %d-%d" % [
			selected_notes.size(), box_selection_start_tick, box_selection_end_tick
		])

	selection_changed.emit(selected_notes)

	print("[NoteSelectionManager] Ended box selection - %d notes selected (range: %d-%d ticks)" % [
		selected_notes.size(), box_selection_start_tick, box_selection_end_tick
	])


func _snap_x_to_grid(x: float) -> float:
	"""Snap X position to time grid."""
	var ticks = grid_helper.pixels_to_ticks(x)
	ticks = grid_helper.snap_ticks(ticks)
	return grid_helper.ticks_to_pixels(ticks)


func _set_selected_notes(notes: Array[VisualNote]) -> void:
	"""Internal helper to update selected notes array."""
	# Clear previous selection visuals
	for note in selected_notes:
		if is_instance_valid(note):
			note.set_selected(false)
	selected_notes.clear()

	# Set new selection
	for note in notes:
		if is_instance_valid(note):
			selected_notes.append(note)
			note.set_selected(true)

	# Update legacy single selection reference
	if selected_notes.size() > 0:
		selected_note = selected_notes[0]
	else:
		selected_note = null


# caller should snap the position to the grid
func _update_box_selection(pos: Vector2) -> void:
	"""Internal helper to update box selection (called by start_box_selection)."""
	box_selection_current = pos
	var snapped_start = box_selection_start
	var snapped_current = box_selection_current
	box_selection_rect = Rect2(snapped_start, Vector2.ZERO)
	box_selection_rect = box_selection_rect.expand(snapped_current)

	var start_tick = grid_helper.pixels_to_ticks(box_selection_rect.position.x)
	var end_tick = grid_helper.pixels_to_ticks(box_selection_rect.position.x + box_selection_rect.size.x)
	box_selection_start_tick = min(start_tick, end_tick)
	box_selection_end_tick = max(start_tick, end_tick)


# ============================================================================
# SELECTION MANIPULATION
# ============================================================================
func toggle_note_selection(note: VisualNote) -> void:
	"""Toggle a note's selection state (for Ctrl+Click)."""
	if not note or not note.midi_note_data:
		return

	if note in selected_notes:
		# Remove from selection
		selected_notes.erase(note)
		note.set_selected(false)

		if selected_note == note:
			selected_note = selected_notes[0] if not selected_notes.is_empty() else null
	else:
		# Add to selection
		selected_notes.append(note)
		note.set_selected(true)

		if selected_notes.size() == 1:
			selected_note = note

	# Update selection range
	_update_selection_range()
	selection_changed.emit(selected_notes)
	#container.queue_redraw()

	print("[NoteSelectionManager] Toggled note selection - %d notes selected (range: %d-%d)" % [
		selected_notes.size(), box_selection_start_tick, box_selection_end_tick
	])


func clear_selection() -> void:
	"""Clear all selected notes."""
	for note in selected_notes:
		if is_instance_valid(note):
			note.set_selected(false)
	selected_notes.clear()
	selected_note = null

	box_selection_start_tick = 0
	box_selection_end_tick = 0
	#container.queue_redraw()


func select_note(note: VisualNote) -> void:
	"""Select a single note (clears previous selection)."""
	# Clear all previous selections
	for n in selected_notes:
		if is_instance_valid(n):
			n.set_selected(false)

	# Select new note
	selected_note = note
	selected_notes = [note]
	note.set_selected(true)

	# Set selection range using coordinate conversion callback
	if note.midi_note_data:
		var pos = get_note_song_position.call(note)
		box_selection_start_tick = pos["start_tick"]
		box_selection_end_tick = pos["end_tick"]

	selection_changed.emit(selected_notes)
	#container.queue_redraw()


func _update_selection_range() -> void:
	"""Update box selection range to encompass all selected notes."""
	if selected_notes.is_empty():
		box_selection_start_tick = 0
		box_selection_end_tick = 0
		return

	var first_note = true
	for sel_note in selected_notes:
		if not sel_note.midi_note_data:
			continue
		
		# Use coordinate conversion callback to get song-relative position
		var pos = get_note_song_position.call(sel_note)
		var note_start = pos["start_tick"]
		var note_end = pos["end_tick"]

		if first_note:
			box_selection_start_tick = note_start
			box_selection_end_tick = note_end
			first_note = false
		else:
			box_selection_start_tick = min(box_selection_start_tick, note_start)
			box_selection_end_tick = max(box_selection_end_tick, note_end)


# ============================================================================
# CLIPBOARD OPERATIONS
# ============================================================================
func copy_selection() -> void:
	"""Copy selected notes to clipboard."""
	if selected_notes.is_empty():
		print("[NoteSelectionManager] No notes selected to copy")
		return

	var selection_length = box_selection_end_tick - box_selection_start_tick
	if selection_length <= 0:
		print("[NoteSelectionManager] Cannot copy - invalid selection range")
		return

	if box_selection_start_tick > 0 or box_selection_end_tick > 0:
		clipboard = NoteSelection.from_visual_notes_with_range(
			selected_notes,
			box_selection_start_tick,
			box_selection_end_tick
		)
	else:
		clipboard = NoteSelection.from_visual_notes(selected_notes)

	print("[NoteSelectionManager] Copied %d notes (duration: %d ticks)" % [clipboard.notes.size(), clipboard.duration_ticks])


# Drawing removed - now handled by MidiEditor._draw()
# Selection state is read from MidiEditor for rendering
