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
var drag_start_midi_note: int = 0
var drag_start_mouse_pos: Vector2 = Vector2.ZERO
var drag_start_positions: Dictionary = {}  # note_id -> {start_tick, note, velocity, clip_instance}

var resizing_note: VisualNote = null
var resize_start_duration: int = 0
var resize_start_mouse_pos: Vector2 = Vector2.ZERO
var resize_start_durations: Dictionary = {}  # note_id -> duration_ticks

# Undo snapshots keyed by Clip (captured at gesture start)
var _history_clip_snapshots: Dictionary = {}  # Clip -> Array snapshot


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
# UNDO HISTORY HELPERS
# ============================================================================

## Begin capturing note-list snapshots for the given clips (call before mutating).
func _history_begin_clips(clips: Array) -> void:
	_history_clip_snapshots.clear()
	for c in clips:
		if c is Clip and not _history_clip_snapshots.has(c):
			_history_clip_snapshots[c] = ClipNotesStateCommand.capture_clip_notes(c)


## Capture snapshots for every clip owning the selected notes.
func _history_begin_selection() -> void:
	var clips: Array = []
	for sel_note in selection_manager.selected_notes:
		if not sel_note or not sel_note.midi_note_data:
			continue
		var note_clip: Clip = _clip_for_visual_note(sel_note)
		if note_clip and note_clip not in clips:
			clips.append(note_clip)
	_history_begin_clips(clips)


## Record ClipNotesStateCommand(s) for all clips snapshotted since _history_begin_*.
func _history_commit(action_name: String) -> void:
	if _history_clip_snapshots.is_empty():
		return
	var cmds: Array[Command] = []
	for clip in _history_clip_snapshots.keys():
		var before: Array = _history_clip_snapshots[clip]
		var after: Array = ClipNotesStateCommand.capture_clip_notes(clip)
		if _history_snapshots_equal(before, after):
			continue
		cmds.append(ClipNotesStateCommand.new(action_name, clip, before, after))
	_history_clip_snapshots.clear()
	if cmds.is_empty():
		return
	HistoryUtil.record_many(action_name, cmds)


## Compare two note snapshots for equality (id + fields).
func _history_snapshots_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var by_id: Dictionary = {}
	for snap in b:
		by_id[snap["id"]] = snap
	for snap in a:
		if not by_id.has(snap["id"]):
			return false
		var other = by_id[snap["id"]]
		if snap["note"] != other["note"] or snap["velocity"] != other["velocity"]:
			return false
		if snap["start_tick"] != other["start_tick"] or snap["duration_ticks"] != other["duration_ticks"]:
			return false
	return true


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
	logger.debug("placing note at ", pos.y)

	# Clear selection before placing new note
	selection_manager.clear_selection()

	# Convert position to MIDI note and tick
	var midi_note_num = y_to_note(pos.y)
	if midi_note_num < 0:
		# Drum View with no rows: there is nowhere to put a note (REQ-023).
		return null
	var pixel_x = pos.x
	var tick_position = pixels_to_ticks(pixel_x)

	# Snap to grid
	if grid_helper:
		tick_position = grid_helper.floor_ticks(tick_position)

	# Drum View hits are one grid step long, not the remembered note length (REQ-019).
	var new_note_length := get_snap_interval() if layout.is_folded() else default_note_length_ticks

	var end_tick = tick_position + new_note_length

	# Determine which clip to add note to
	var target_clip: Clip
	if multi_clip_mode:
		# MULTI-CLIP MODE: Find clip at cursor position, or create one
		var target_clip_instance = get_or_create_clip_at_position(tick_position)
		if not target_clip_instance:
			logger.warn("No clip at position and creation not yet implemented (Phase 5)")
			return null
		target_clip = target_clip_instance.clip
		# In multi-clip mode, tick_position is song-relative, need to convert to clip-local
		tick_position = tick_position - target_clip_instance.start_ticks
		end_tick = tick_position + new_note_length
	else:
		# SINGLE-CLIP MODE: Use the bound clip
		if not clip:
			logger.warn("No clip loaded in MIDI editor")
			return null
		target_clip = clip

	_history_begin_clips([target_clip])
	# Cut overlapping notes
	var affected_notes = target_clip.cut_overlapping_notes_at_pitch(midi_note_num, tick_position, end_tick, _note_id_allocator())

	if not affected_notes.is_empty():
		logger.info("Cut/merged %d overlapping notes" % affected_notes.size())

	var note_id: int = _note_id_allocator().call()

	# Add note to clip
	var note_data = target_clip.add_midi_note(note_id, midi_note_num, 100, tick_position, new_note_length)
	if note_data == null:
		push_error("[NoteEditor] Failed to add note after cutting overlaps")
		_history_clip_snapshots.clear()
		return null

	logger.info("Added note %d: MIDI=%d start=%d duration=%d" % [note_data.id, midi_note_num, tick_position, new_note_length])

	# Get visual note created reactively
	var note_instance = get_visual_note(note_data.id)
	if note_instance == null:
		push_error("[NoteEditor] Failed to find visual note after creation")
		return null

	logger.info("Placed note: MIDI %d at tick %d (duration: %d)" % [midi_note_num, tick_position, new_note_length])

	# Select the newly placed note (uses coordinate conversion callback)
	_history_commit("Place Note")
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
	drag_start_midi_note = note.midi_note_data.note
	drag_start_mouse_pos = click_position
	last_drag_mode = DragMode.POSITION

	# Store starting positions for all selected notes
	_snapshot_selection()

	_history_begin_selection()


func _snapshot_selection() -> void:
	"""Capture (or re-capture, on a mid-drag mode switch) the starting tick/note/
	velocity/duration and owning clip instance for every selected note. Must
	include clip_instance so cross-clip note transfer keeps working after a
	Shift/Alt mode switch mid-drag."""
	drag_start_positions.clear()
	resize_start_durations.clear()
	for sel_note in selection_manager.selected_notes:
		if sel_note.midi_note_data:
			var source_clip_instance: ClipInstance = null
			# Prefer the visual note's attached clip instance to avoid id collisions in multi-clip mode
			if sel_note.has_meta("clip_instance"):
				source_clip_instance = sel_note.get_meta("clip_instance")
			else:
				source_clip_instance = get_clip_instance_for_note(sel_note.midi_note_data.id)
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

	# Drum View draws hits, not bars, so there is no length to drag out (REQ-022).
	# Shift falls back to plain dragging rather than silently changing durations.
	if layout.is_folded():
		shift_pressed = false

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
		_snapshot_selection()

		last_drag_mode = current_mode
		logger.info("Drag mode switched to: %s" % ["POSITION", "RESIZE", "VELOCITY"][current_mode])

	var delta_x = mouse_pos_local.x - drag_start_mouse_pos.x
	var delta_y = mouse_pos_local.y - drag_start_mouse_pos.y
	var delta_ticks = pixels_to_ticks(delta_x)
	# Snap the drag delta, not each note, so notes keep their offsets from each other.
	var snapped_delta_ticks: int = grid_helper.snap_ticks(delta_ticks) if grid_helper else delta_ticks

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

			var new_duration := _snapped_duration(start_duration + delta_ticks)

			sel_note.midi_note_data.duration_ticks = new_duration
			var note_width = ticks_to_pixels(new_duration)
			sel_note.size.x = note_width

			default_note_length_ticks = new_duration
	else:
		# Normal mode: Control position
		# Row-wise in Drum View, semitone-wise in the piano roll (REQ-020). The two
		# agree exactly in chromatic mode.
		var delta_steps := layout.row_of_pitch(drag_start_midi_note) - layout.y_to_row(mouse_pos_local.y)

		for sel_note in selection_manager.selected_notes:
			if not sel_note.midi_note_data:
				continue

			var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
			if not start_pos:
				continue

			var new_ticks = max(0, start_pos.start_tick + snapped_delta_ticks)
			var new_midi_note := step_note(start_pos.note, delta_steps)

			# Clamp within clip content in track-mode to avoid crossing instance boundaries
			if multi_clip_mode:
				var owner_ci_clamp: ClipInstance = null
				if sel_note.has_meta("clip_instance"):
					owner_ci_clamp = sel_note.get_meta("clip_instance")
				else:
					owner_ci_clamp = get_clip_instance_for_note(sel_note.midi_note_data.id)
				if owner_ci_clamp and owner_ci_clamp.clip:
					# The bound is the instance's played window, not the content
					# length: content length is the rightmost note end, so using it
					# would pin the last note in place and make dragging right a no-op.
					# Content that reaches past the window (a trimmed instance) still
					# gets that larger bound, so no note is ever clamped backwards.
					var clip_len: int = max(owner_ci_clamp.duration_ticks, owner_ci_clamp.clip.get_content_length())
					if clip_len > 0:
						new_ticks = clamp(new_ticks, 0, max(0, clip_len - sel_note.midi_note_data.duration_ticks))

			sel_note.midi_note_data.start_tick = new_ticks
			sel_note.midi_note_data.note = new_midi_note

			# Calculate visual position (accounting for clip offset in multi-clip mode)
			var visual_offset_ticks = 0
			if multi_clip_mode:
				var owner_ci_vis: ClipInstance = null
				if sel_note.has_meta("clip_instance"):
					owner_ci_vis = sel_note.get_meta("clip_instance")
				else:
					owner_ci_vis = get_clip_instance_for_note(sel_note.midi_note_data.id)
				if owner_ci_vis:
					visual_offset_ticks = owner_ci_vis.start_ticks
					logger.debug("Drag render note ", sel_note.midi_note_data.id,
						" ci=", owner_ci_vis.id, " ci_start=", owner_ci_vis.start_ticks,
						" clip_local=", new_ticks)

			var note_x = ticks_to_pixels(new_ticks + visual_offset_ticks)
			sel_note.position = Vector2(note_x, note_visual_y(new_midi_note))
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
		logger.info("Drag ended with no changes")
		dragging_note = null
		drag_start_positions.clear()
		resize_start_durations.clear()
		_history_clip_snapshots.clear()
		update_container_width()
		return

	# MULTI-CLIP MODE: Check if notes need to be transferred between clips
	if multi_clip_mode:
		_handle_cross_clip_transfers()

	# Process all selected notes (cut overlaps and update)
	var total_affected = 0
	for sel_note in selection_manager.selected_notes.duplicate():
		# A cross-clip transfer above frees the old visual and replaces it with a new
		# one carrying a new id; the stale entry must not be updated.
		if not is_instance_valid(sel_note) or not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		# Get the clip this visual note belongs to (prefer meta clip_instance)
		var note_clip: Clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			_note_id_allocator(),
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		logger.info("Multi-drag ended - cut/merged %d overlapping notes" % total_affected)

	logger.info("Updated %d note(s) position/duration" % selection_manager.selected_notes.size())

	_history_commit("Move Notes")

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

	# Drum View draws hits, not bars: there is no length to drag (REQ-022).
	if layout.is_folded():
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

	_history_begin_selection()


## Note length floored to the grid, never shorter than one grid step.
func _snapped_duration(ticks: int) -> int:
	var snap_interval := get_snap_interval()
	if grid_helper:
		ticks = grid_helper.floor_ticks(ticks)
	return maxi(snap_interval, ticks)


func _on_resize_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	"""Handle note resize update."""
	if resizing_note != note or not note.midi_note_data:
		return

	var delta = mouse_pos_local - resize_start_mouse_pos
	var delta_ticks = pixels_to_ticks(delta.x)

	var new_duration := _snapped_duration(resize_start_duration + delta_ticks)

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
			note_new_duration = _snapped_duration(note_start_duration + delta_ticks)

		sel_note.midi_note_data.duration_ticks = note_new_duration
		var note_width = ticks_to_pixels(note_new_duration)
		sel_note.size.x = note_width


func _on_resize_ended(note: VisualNote) -> void:
	"""Handle note resize end."""
	if resizing_note != note or not note.midi_note_data:
		return

	# Store new note length as default
	default_note_length_ticks = note.midi_note_data.duration_ticks
	logger.info("Updated default note length to %d ticks" % default_note_length_ticks)

	# Process all selected notes
	var total_affected = 0
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		# Get the clip this note belongs to
		var note_clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			_note_id_allocator(),
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		logger.info("Multi-resize ended - cut/merged %d overlapping notes" % total_affected)

	logger.info("Updated %d note(s) duration" % selection_manager.selected_notes.size())

	# Don't update selection range - keep grid-snapped box selection boundaries
	queue_redraw()
	update_container_width()

	_history_commit("Resize Notes")
	resizing_note = null
	resize_start_durations.clear()


func _start_place_and_drag(note: VisualNote) -> void:
	"""Start dragging a newly placed note."""
	if not note or not note.midi_note_data:
		return

	interaction_mode = InteractionMode.PLACING_AND_DRAGGING
	dragging_note = note
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

	logger.info("Started place-and-drag for note %d" % note.midi_note_data.id)


func _erase_note(note: VisualNote) -> void:
	"""Erase a note immediately."""
	if not note or not note.midi_note_data:
		return

	last_erased_note = note

	# Use the clicked visual note's own clip, not an id lookup: in track mode the
	# same note id can be visible on several instances and the lookup returns the
	# first match, which may belong to another clip.
	var note_clip = _clip_for_visual_note(note)
	if note_clip:
		_history_begin_clips([note_clip])
		note_clip.remove_midi_note(note.midi_note_data)
		_history_commit("Erase Note")


# ============================================================================
# HELPER METHODS FOR SELECTION MANAGER
# ============================================================================
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
		logger.warn("No notes selected to cut")
		return

	selection_manager.copy_selection()
	_delete_selection()

	logger.info("Cut %d notes" % selection_manager.clipboard.notes.size())


func _paste_at_position(tick_position: int) -> void:
	"""Paste clipboard contents at the specified tick position."""
	if not selection_manager.clipboard or selection_manager.clipboard.is_empty():
		logger.warn("Clipboard is empty")
		return

	# Determine target clip
	var target_clip: Clip
	var clip_local_position: int = tick_position

	if multi_clip_mode:
		# MULTI-CLIP MODE: Find or create clip at cursor position
		var target_clip_instance = get_or_create_clip_at_position(tick_position)
		if not target_clip_instance:
			logger.warn("Cannot paste - no clip at position")
			return
		target_clip = target_clip_instance.clip
		# Convert to clip-local position
		clip_local_position = tick_position - target_clip_instance.start_ticks
	else:
		# SINGLE-CLIP MODE: Use bound clip
		if not clip:
			logger.warn("No clip loaded")
			return
		target_clip = clip
		clip_local_position = tick_position

	# Snap to grid
	if grid_helper:
		clip_local_position = grid_helper.floor_ticks(clip_local_position)

	# Get notes positioned at paste location
	var notes_to_paste = selection_manager.clipboard.get_notes_at_position(clip_local_position)

	_history_begin_clips([target_clip])
	# Cut overlapping notes
	var total_affected = 0
	for note_data in notes_to_paste:
		var end_tick = note_data.start_tick + note_data.duration_ticks
		var affected = target_clip.cut_overlapping_notes_at_pitch(note_data.note, note_data.start_tick, end_tick, _note_id_allocator())
		total_affected += affected.size()

	if total_affected > 0:
		logger.info("Paste cut/merged %d overlapping notes" % total_affected)

	selection_manager.clear_selection()

	# Add notes to clip
	var allocate_note_id := _note_id_allocator()
	var pasted_note_ids: Array[int] = []

	for note_data in notes_to_paste:
		note_data.id = allocate_note_id.call()

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

	logger.info("Pasted %d notes at tick %d (range: %d-%d)" % [
		pasted_note_ids.size(), tick_position, selection_manager.box_selection_start_tick, selection_manager.box_selection_end_tick
	])
	_history_commit("Paste Notes")


func _duplicate_selection() -> void:
	"""Duplicate selected notes immediately after the selection."""
	_history_begin_selection()
	if selection_manager.selected_notes.is_empty():
		logger.warn("No notes selected to duplicate")
		return

	var selection_length = selection_manager.box_selection_end_tick - selection_manager.box_selection_start_tick
	if selection_length <= 0:
		logger.warn("Cannot duplicate - invalid selection range")
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

	logger.info("Duplicated %d notes (duration: %d ticks)" % [selection.notes.size(), selection.duration_ticks])
	_history_commit("Duplicate Notes")


func _delete_selection() -> void:
	"""Delete all selected notes."""
	_history_begin_selection()
	if selection_manager.selected_notes.is_empty():
		logger.warn("No notes selected to delete")
		return

	var count = selection_manager.selected_notes.size()

	# Remove notes in reverse
	for i in range(selection_manager.selected_notes.size() - 1, -1, -1):
		var note = selection_manager.selected_notes[i]
		if is_instance_valid(note) and note.midi_note_data:
			var note_clip = _clip_for_visual_note(note)
			if note_clip:
				note_clip.remove_midi_note(note.midi_note_data)
			note.queue_free()

	selection_manager.selected_notes.clear()
	selection_manager.selected_note = null
	selection_manager.selection_changed.emit(selection_manager.selected_notes)

	update_container_width()

	logger.info("Deleted %d notes" % count)
	_history_commit("Delete Notes")


func _move_selection_vertical(semitones: int) -> void:
	"""Move all selected notes up or down by semitones."""
	_history_begin_selection()
	if selection_manager.selected_notes.is_empty():
		return

	# Move all selected notes
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var new_pitch := step_note(note_data.note, semitones)
		note_data.note = new_pitch

		sel_note.position.y = note_visual_y(new_pitch)
		sel_note._update_visual()

	# Process overlaps and sync
	var total_affected = 0
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		var note_clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			_note_id_allocator(),
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		logger.info("Keyboard move vertical - cut/merged %d overlapping notes" % total_affected)

	logger.info("Moved %d note(s) %+d semitones" % [selection_manager.selected_notes.size(), semitones])
	update_container_width()
	_history_commit("Transpose Notes")


func _move_selection_horizontal(delta_ticks: int) -> void:
	"""Move all selected notes left or right by ticks."""
	_history_begin_selection()
	if selection_manager.selected_notes.is_empty():
		return

	# Move all selected notes
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var new_start = max(0, note_data.start_tick + delta_ticks)
		note_data.start_tick = new_start

		# Use the shared positioning logic so track-mode's per-clip offset
		# (ci.start_ticks) is applied instead of a bare tick->pixel conversion.
		_update_single_note_position(sel_note)

	# Process overlaps and sync
	var total_affected = 0
	for sel_note in selection_manager.selected_notes:
		if not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		var note_clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			_note_id_allocator(),
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		logger.info("Keyboard move horizontal - cut/merged %d overlapping notes" % total_affected)

	logger.info("Moved %d note(s) %+d ticks" % [selection_manager.selected_notes.size(), delta_ticks])

	# Don't update selection range - keep grid-snapped box selection boundaries
	queue_redraw()
	update_container_width()
	_history_commit("Nudge Notes")


func _on_clip_note_removed(note_data: MidiNoteData, source_clip: Clip) -> void:
	"""Handle when a note is removed from the clip."""
	# Remove from selection if selected
	var note_instance = get_visual_note(note_data.id)
	if note_instance:
		if note_instance in selection_manager.selected_notes:
			selection_manager.selected_notes.erase(note_instance)
		if selection_manager.selected_note == note_instance:
			selection_manager.selected_note = null

	# Call parent implementation
	super._on_clip_note_removed(note_data, source_clip)


# ============================================================================
# CROSS-CLIP NOTE MOVEMENT (MULTI-CLIP MODE)
# ============================================================================
func _handle_cross_clip_transfers() -> void:
	"""Transfer notes between clips if they moved to different clip regions."""
	if not multi_clip_mode:
		return

	# Iterate a copy: removing a note fires midi_note_removed, which erases entries
	# from selected_notes and would make this loop skip elements.
	for sel_note in selection_manager.selected_notes.duplicate():
		if not is_instance_valid(sel_note) or not sel_note.midi_note_data:
			continue

		var note_data = sel_note.midi_note_data
		var note_id = note_data.id

		# Get source and destination clips
		var start_pos = drag_start_positions.get(note_id)
		if not start_pos:
			continue

		# Resolve the source from the note's current owner rather than the snapshot
		# taken at drag start: an earlier transfer may already have moved it, and a
		# stale source makes the removal below silently do nothing.
		var source_clip_instance: ClipInstance = null
		if sel_note.has_meta("clip_instance"):
			source_clip_instance = sel_note.get_meta("clip_instance")
		if not source_clip_instance:
			source_clip_instance = start_pos.get("clip_instance") as ClipInstance
		if not source_clip_instance or not source_clip_instance.clip:
			continue

		# Calculate song-relative position (note position + clip offset)
		var current_clip_instance = get_clip_instance_for_note(note_id)
		if not current_clip_instance:
			continue

		var song_position = note_data.start_tick + current_clip_instance.start_ticks

		# Find which clip should contain this note at its new position
		var dest_clip_instance = get_clip_at_position(song_position)

		# If destination is within an instance of the SAME underlying clip, do not transfer;
		# edits are clip-local and shared across instances. Just keep the updated clip-local position.
		if dest_clip_instance and dest_clip_instance.clip and source_clip_instance and source_clip_instance.clip and dest_clip_instance.clip == source_clip_instance.clip:
			continue

		# If no clip at position, try to create one
		if not dest_clip_instance:
			dest_clip_instance = get_or_create_clip_at_position(song_position)

		# Transfer note if it moved to a different clip
		if dest_clip_instance and dest_clip_instance != source_clip_instance:
			_transfer_note_between_clips(note_data, source_clip_instance, dest_clip_instance, song_position)


func _transfer_note_between_clips(note_data: MidiNoteData, source: ClipInstance, dest: ClipInstance, song_position: int) -> void:
	"""Transfer a note from source clip to destination clip."""
	logger.info("Transferring note %d from clip '%s' to '%s'" % [note_data.id, source.clip.name if source.clip else "?", dest.clip.name if dest.clip else "?"])

	# Calculate clip-local position for destination clip
	var dest_local_position = song_position - dest.start_ticks

	# Create a copy of the note data for the destination clip
	var new_note = MidiNoteData.new()
	new_note.id = _note_id_allocator().call()
	new_note.note = note_data.note
	new_note.velocity = note_data.velocity
	new_note.start_tick = dest_local_position
	new_note.duration_ticks = note_data.duration_ticks

	# Clear the landing spot first. Without this the add below is rejected as an
	# overlap and the note would be dropped entirely.
	dest.clip.cut_overlapping_notes_at_pitch(
		new_note.note,
		new_note.start_tick,
		new_note.start_tick + new_note.duration_ticks,
		_note_id_allocator()
	)

	# Remove from source clip (this will trigger reactive removal)
	if not source.clip.remove_midi_note(note_data):
		logger.warn("Transfer aborted: note %d is not in clip '%s'" % [note_data.id, source.clip.name])
		return

	# Add to destination clip (this will trigger reactive addition)
	if dest.clip.add_midi_note_data(new_note) == null:
		# Put it back rather than losing it.
		logger.warn("Transfer of note %d into '%s' was rejected; restoring it in '%s'" % [note_data.id, dest.clip.name, source.clip.name])
		source.clip.add_midi_note_data(note_data)
		return

	logger.info("Note transferred: old_id=%d, new_id=%d, new_local_pos=%d" % [note_data.id, new_note.id, dest_local_position])


## The clip a given visual note belongs to. Prefers the clip_instance stamped on the
## note itself, which is unambiguous even when several instances show the same id.
func _clip_for_visual_note(note: VisualNote) -> Clip:
	if not note or not note.midi_note_data:
		return null
	if not multi_clip_mode:
		return clip
	if note.has_meta("clip_instance"):
		var ci: ClipInstance = note.get_meta("clip_instance")
		if ci and ci.clip:
			return ci.clip
	return _get_clip_for_note(note.midi_note_data.id)


## Note ID source for new and split notes: the open project's counter.
func _get_clip_for_note(note_id: int) -> Clip:
	"""Get the clip that owns this note (works in both single and multi-clip modes)."""
	if not multi_clip_mode:
		return clip

	var clip_instance = get_clip_instance_for_note(note_id)
	if clip_instance:
		return clip_instance.clip
	return null
