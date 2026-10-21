## Box-select geometry and the note clipboard of one NoteEditor.
## The selected notes themselves live in the MidiEditor's NoteSelectionModel (`model`): this
## class turns visuals into refs and back through the editor's callbacks, so the editor's
## edit code can keep working on VisualNotes.
## Does NOT handle container operations, coordinate conversions, or clip mutations.
## Those responsibilities belong to NoteEditor.
class_name NoteSelectionManager extends RefCounted

static var logger := Log.make("NoteSelectionManager")


## The selection (notes and range). One per MidiEditor, assigned by NoteEditor.
var model: NoteSelectionModel

## NoteRef -> the VisualNote showing it (null when it has none), set by NoteEditor.
var visual_of_ref: Callable = func(_ref: NoteRef) -> VisualNote: return null
## VisualNote -> the NoteRef that selects its note, set by NoteEditor.
var ref_of_visual: Callable = func(_vn: VisualNote) -> NoteRef: return null


## The selected time range in editor ticks, kept in the model. Also the live range of a box
## while it is dragged.
var box_selection_start_tick: int:
	get:
		return model.range.x
	set(value):
		model.range = Vector2i(value, model.range.y)
var box_selection_end_tick: int:
	get:
		return model.range.y
	set(value):
		model.range = Vector2i(model.range.x, value)


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


func _init(gh: GridHelper, p_model: NoteSelectionModel = null) -> void:
	grid_helper = gh
	model = p_model if p_model else NoteSelectionModel.new()


## The visuals of the selected notes (one per note, the one it was selected through), in
## selection order. O(selected).
func selected_visuals() -> Array[VisualNote]:
	var out: Array[VisualNote] = []
	for ref in model.refs:
		var vn: VisualNote = visual_of_ref.call(ref)
		if vn != null and is_instance_valid(vn):
			out.append(vn)
	return out


func _refs_of(notes: Array[VisualNote]) -> Array[NoteRef]:
	var out: Array[NoteRef] = []
	for note in notes:
		if is_instance_valid(note) and note.midi_note_data:
			var ref: NoteRef = ref_of_visual.call(note)
			if ref != null:
				out.append(ref)
	return out


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
	select_visuals(notes_in_box)

	# The boundaries start at the grid-snapped box (so empty space can be selected). Notes the
	# box only partly covers are selected whole, so the range grows to take in their full span.
	# It never shrinks: a box wider than its notes keeps its grid edges.
	_grow_range_to_selected_notes()

	if model.is_empty():
		logger.info("Box selection completed - no notes, boundaries at grid: %d-%d" % [
			box_selection_start_tick, box_selection_end_tick
		])
	else:
		logger.info("Box selection completed - %d notes, boundaries at grid: %d-%d" % [
			model.size(), box_selection_start_tick, box_selection_end_tick
		])

	model.changed.emit()

	logger.info("Ended box selection - %d notes selected (range: %d-%d ticks)" % [
		model.size(), box_selection_start_tick, box_selection_end_tick
	])


func _grow_range_to_selected_notes() -> void:
	for note in selected_visuals():
		var pos: Dictionary = get_note_song_position.call(note)
		box_selection_start_tick = mini(box_selection_start_tick, pos["start_tick"])
		box_selection_end_tick = maxi(box_selection_end_tick, pos["end_tick"])


func _snap_x_to_grid(x: float) -> float:
	"""Snap X position to time grid."""
	var ticks = grid_helper.pixels_to_ticks(x)
	ticks = grid_helper.snap_ticks(ticks)
	return grid_helper.ticks_to_pixels(ticks)


## Make exactly `notes` the selection (no range change; only `set_changed`). A note shown by
## several visuals counts once, through the first.
func select_visuals(notes: Array[VisualNote]) -> void:
	model.select(_refs_of(notes), true)


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
	var ref: NoteRef = ref_of_visual.call(note)
	if ref == null:
		return
	model.toggle(ref, true)

	# Update selection range
	_update_selection_range()
	model.changed.emit()

	logger.info("Toggled note selection - %d notes selected (range: %d-%d)" % [
		model.size(), box_selection_start_tick, box_selection_end_tick
	])


func clear_selection() -> void:
	"""Clear all selected notes."""
	model.clear(true)


## Select every note in `notes` at once (Ctrl+A). The range covers them all.
func select_all(notes: Array[VisualNote]) -> void:
	select_visuals(notes)
	_update_selection_range()
	model.changed.emit()


func select_note(note: VisualNote, with_range: bool = true) -> void:
	"""Select a single note (clears previous selection).

	`with_range` also sets the selection range to the note's span; note placement
	passes the user's "placement sets range" setting here.
	"""
	select_visuals([note] as Array[VisualNote])

	# Set selection range using coordinate conversion callback
	if with_range and note.midi_note_data:
		var pos = get_note_song_position.call(note)
		box_selection_start_tick = pos["start_tick"]
		box_selection_end_tick = pos["end_tick"]

	model.changed.emit()


func _update_selection_range() -> void:
	"""Update box selection range to encompass all selected notes."""
	if model.is_empty():
		box_selection_start_tick = 0
		box_selection_end_tick = 0
		return

	var first_note = true
	for sel_note in selected_visuals():
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
	return model.has_range()


## Replace the selection with a bare time range and no notes, e.g. a range carried over
## from another track or clip. A range with end <= start clears it.
func set_range(start_tick: int, end_tick: int) -> void:
	clear_selection()
	model.set_range(start_tick, end_tick)


## The selected notes as a NoteSelection over the selection range, positioned in this
## editor's ticks (song ticks in track mode). Null when nothing is selected.
func snapshot_selection() -> NoteSelection:
	if model.is_empty():
		return null
	var visuals := selected_visuals()
	var start_tick := box_selection_start_tick
	var end_tick := box_selection_end_tick
	if end_tick <= start_tick:
		# No explicit range: use the notes' bounds in this editor's space.
		var first := true
		for n in visuals:
			var pos: Dictionary = get_note_song_position.call(n)
			start_tick = pos["start_tick"] if first else mini(start_tick, pos["start_tick"])
			end_tick = pos["end_tick"] if first else maxi(end_tick, pos["end_tick"])
			first = false
		if first or end_tick <= start_tick:
			return null
	return NoteSelection.from_positioned_notes(visuals, start_tick, end_tick, get_note_song_position)


# Drawing removed - now handled by MidiEditor._draw()
# Selection state is read from MidiEditor for rendering
