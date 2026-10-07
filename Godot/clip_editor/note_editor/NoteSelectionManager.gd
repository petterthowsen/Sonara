## Manages note selection state only.
## Does NOT handle container operations, coordinate conversions, or clip mutations.
## Those responsibilities belong to NoteEditor.
class_name NoteSelectionManager extends RefCounted

static var logger := Log.make("NoteSelectionManager")


signal selection_changed(notes: Array[VisualNote])


# Selection state
var selected_note: VisualNote = null  # Currently selected note (legacy single selection)
var selected_notes: Array[VisualNote] = []  # Multiple selected notes


# Clipboard for copy/paste operations. One clipboard for every note editor (track mode
# builds one editor per track), so notes copied on one track paste onto another.
static var _shared_clipboard: NoteSelection = null
var clipboard: NoteSelection:
	get:
		return _shared_clipboard
	set(value):
		_shared_clipboard = value


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
	Hotkeys.begin_state(self, "box_select")
	_update_box_selection(pos)


func update_box_selection(pos: Vector2) -> void:
	"""Update box selection as mouse moves."""
	if not is_box_selecting:
		return

	box_selection_current = pos

	# Snap selection box boundaries to grid (X only), clamped so nothing selects before tick 0
	var snapped_start_x = maxf(0.0, _snap_x_to_grid(box_selection_start.x))
	var snapped_current_x = maxf(0.0, _snap_x_to_grid(pos.x))

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
	Hotkeys.end_state(self)

	# Update selection with provided notes
	_set_selected_notes(notes_in_box)

	# KEEP boundaries at grid-snapped positions - NEVER adjust based on notes
	# This allows selecting empty space and ensures boundaries follow grid, not notes
	# The box_selection_start_tick and box_selection_end_tick were already set by update_box_selection()

	if selected_notes.is_empty():
		logger.info("Box selection completed - no notes, boundaries at grid: %d-%d" % [
			box_selection_start_tick, box_selection_end_tick
		])
	else:
		logger.info("Box selection completed - %d notes, boundaries at grid: %d-%d" % [
			selected_notes.size(), box_selection_start_tick, box_selection_end_tick
		])

	selection_changed.emit(selected_notes)

	logger.info("Ended box selection - %d notes selected (range: %d-%d ticks)" % [
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
	# Clamp X so the selection never starts before tick 0.
	var snapped_start = Vector2(maxf(0.0, box_selection_start.x), box_selection_start.y)
	var snapped_current = Vector2(maxf(0.0, box_selection_current.x), box_selection_current.y)
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

	logger.info("Toggled note selection - %d notes selected (range: %d-%d)" % [
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


## Select every note in `notes` at once (Ctrl+A). The range covers them all.
func select_all(notes: Array[VisualNote]) -> void:
	_set_selected_notes(notes)
	_update_selection_range()
	selection_changed.emit(selected_notes)


func select_note(note: VisualNote, with_range: bool = true) -> void:
	"""Select a single note (clears previous selection).

	`with_range` also sets the selection range to the note's span; note placement
	passes the user's "placement sets range" setting here.
	"""
	# Clear all previous selections
	for n in selected_notes:
		if is_instance_valid(n):
			n.set_selected(false)

	# Select new note
	selected_note = note
	selected_notes = [note]
	note.set_selected(true)

	# Set selection range using coordinate conversion callback
	if with_range and note.midi_note_data:
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
	var selection := snapshot_selection()
	if selection == null:
		logger.info("No notes selected to copy")
		return
	clipboard = selection
	logger.info("Copied %d notes (duration: %d ticks)" % [clipboard.notes.size(), clipboard.duration_ticks])


## True when a time range is set (a box/ruler range, or the span of the selected notes).
func has_range() -> bool:
	return box_selection_end_tick > box_selection_start_tick


## Replace the selection with a bare time range and no notes, e.g. a range carried over
## from another track or clip. A range with end <= start clears it.
func set_range(start_tick: int, end_tick: int) -> void:
	clear_selection()
	if end_tick > start_tick:
		box_selection_start_tick = start_tick
		box_selection_end_tick = end_tick
	selection_changed.emit(selected_notes)


## The selected notes as a NoteSelection over the selection range, positioned in this
## editor's ticks (song ticks in track mode). Null when nothing is selected.
func snapshot_selection() -> NoteSelection:
	if selected_notes.is_empty():
		return null
	var start_tick := box_selection_start_tick
	var end_tick := box_selection_end_tick
	if end_tick <= start_tick:
		# No explicit range: use the notes' bounds in this editor's space.
		var first := true
		for n in selected_notes:
			if not is_instance_valid(n) or not n.midi_note_data:
				continue
			var pos: Dictionary = get_note_song_position.call(n)
			start_tick = pos["start_tick"] if first else mini(start_tick, pos["start_tick"])
			end_tick = pos["end_tick"] if first else maxi(end_tick, pos["end_tick"])
			first = false
		if first or end_tick <= start_tick:
			return null
	return NoteSelection.from_positioned_notes(selected_notes, start_tick, end_tick, get_note_song_position)


# Drawing removed - now handled by MidiEditor._draw()
# Selection state is read from MidiEditor for rendering
