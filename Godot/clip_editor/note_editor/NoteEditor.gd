## Note editor with input handling and note interaction.
## Extends NoteContainer and uses NoteSelectionManager for selection operations.

class_name NoteEditor extends NoteContainer

## Emitted after `_gui_input` handled a key that changed the selection or note
## positions, so MidiEditor (which owns the range overlays) can refresh them.
signal key_input_handled

## The user touched a note (selected it alone, started dragging or resizing it): its values
## become the starting values of the next note drawn.
signal note_touched(note: MidiNoteData)

## Starting velocity and release of new notes. MidiEditor hands its shared instance down.
var next_values := NextNoteValues.new()

# Selection manager
var selection_manager: NoteSelectionManager

# Interaction state
enum InteractionMode { NONE, DRAGGING, RESIZING, ERASING, PLACING_AND_DRAGGING, BOX_SELECTING, DUPLICATING, SCALING }
var interaction_mode: InteractionMode = InteractionMode.NONE


# Drag/resize state
var dragging_note: VisualNote = null:
	set(value):
		dragging_note = value
		if value:
			Hotkeys.begin_state(self, "note_drag_alt" if _alt_auto_mode() else "note_drag")
		else:
			Hotkeys.end_state(self)
var drag_start_midi_note: int = 0
var drag_start_mouse_pos: Vector2 = Vector2.ZERO
var drag_start_positions: Dictionary = {}  # note_id -> {start_tick, note, velocity, clip_instance}

var resizing_note: VisualNote = null
var resize_start_duration: int = 0
var resize_start_mouse_pos: Vector2 = Vector2.ZERO
var resize_start_durations: Dictionary = {}  # note_id -> duration_ticks

# Undo snapshots keyed by Clip (captured at gesture start)
var _history_clip_snapshots: Dictionary = {}  # Clip -> Array snapshot
var _history_selection_before: Dictionary = {}

## Undo or redo changed the selection (range or notes); overlays should redraw.
signal selection_range_restored


# Drag mode tracking
## PENDING: Alt is held but the mouse has not moved far enough to tell length from velocity.
enum DragMode { POSITION, RESIZE, VELOCITY, PENDING }
var last_drag_mode: DragMode = DragMode.POSITION

## Pixels the mouse must travel with Alt held before the drag becomes length or velocity.
const ALT_AXIS_THRESHOLD := 6.0


## True when one key (Alt) serves both length and velocity, told apart by drag direction.
func _alt_auto_mode() -> bool:
	return Settings.get_value("midi_editor/note_drag_modifiers") == Settings.MODS_ALT_AUTO


# Newly placed note state
var placed_note_awaiting_drag: VisualNote = null
var placed_note_mouse_pos: Vector2 = Vector2.ZERO
const DRAG_THRESHOLD: float = 3.0


# Erase mode state
var erasing_mode: bool = false
var last_erased_note: VisualNote = null

# Length (ticks) of the last note the user resized; new notes start with it. 0 = use the grid step.
var last_note_length: int = 0


# Local cursor position (for paste operations)
var cursor_position_ticks: int = 0

## The clip instances the user opened in the editor that this editor shows (track mode:
## the selected clips on this track; clip mode: unused, the bound instance is the one).
## Ctrl+C with nothing selected copies these whole.
var edited_clip_instances: Array[ClipInstance] = []


func _ready():
	# This is the control that holds keyboard focus for the note area
	# (MidiEditor delegates mouse input, ClipEditor focuses the note editor), so it has
	# to be focusable. Set here as well as in the scene so track-mode editors created
	# at runtime behave the same.
	focus_mode = Control.FOCUS_CLICK

	# Create selection manager (grid_helper will be set via override below)
	selection_manager = NoteSelectionManager.new(grid_helper)
	selection_manager.selection_changed.connect(func(notes):
		Hotkeys.set_condition("note_selection", not notes.is_empty())
		Hotkeys.set_condition("note_range", selection_manager.has_range()))

	# Provide coordinate conversion callback to selection manager
	# This allows it to work in the correct coordinate space without tight coupling
	selection_manager.get_note_song_position = get_note_song_position
	selection_manager.selection_changed.connect(_on_selection_touched)
	selection_manager.selection_changed.connect(func(_notes): queue_redraw())
	selection_manager.selection_set_changed.connect(queue_redraw)


func _on_selection_touched(notes: Array[VisualNote]) -> void:
	if notes.size() == 1 and notes[0].midi_note_data:
		note_touched.emit(notes[0].midi_note_data)


# Override set_grid_helper to also update selection manager
func set_grid_helper(gh: GridHelper) -> void:
	super.set_grid_helper(gh)
	if selection_manager:
		selection_manager.grid_helper = gh


func unbind():
	# The pending duplicates are children and go with the rest; forget them too.
	_dup_origins.clear()
	dup_anchor = null
	# Every note node goes away, so no gesture can carry on with one.
	interaction_mode = InteractionMode.NONE
	dragging_note = null
	resizing_note = null
	placed_note_awaiting_drag = null
	last_erased_note = null
	erasing_mode = false
	super.unbind()


# ============================================================================
# UNDO HISTORY HELPERS
# ============================================================================

## Begin capturing note-list snapshots for the given clips (call before mutating).
func _history_begin_clips(clips: Array) -> void:
	_history_clip_snapshots = ClipNotesStateCommand.capture_many(clips)
	_history_selection_before = capture_selection_state()


## The selection as { "range": Vector2i(start, end ticks), "notes": [[Clip, MidiNoteData], ...] },
## each selected note once.
func capture_selection_state() -> Dictionary:
	var notes: Array = []
	for vn in _selected_note_visuals():
		notes.append([_clip_for_visual_note(vn), vn.midi_note_data])
	return {
		"range": Vector2i(selection_manager.box_selection_start_tick, selection_manager.box_selection_end_tick),
		"notes": notes,
	}


static func _same_selection(a: Dictionary, b: Dictionary) -> bool:
	if a.get("range") != b.get("range") or a.notes.size() != b.notes.size():
		return false
	var data_in_a := {}
	for pair in a.notes:
		data_in_a[pair[1]] = true
	for pair in b.notes:
		if not data_in_a.has(pair[1]):
			return false
	return true


## Put a captured selection back (undo/redo). Notes that no longer exist are skipped.
func restore_selection_state(state: Dictionary) -> void:
	var visuals: Array[VisualNote] = []
	for pair in state.get("notes", []):
		var note_clip: Clip = pair[0]
		var data: MidiNoteData = pair[1]
		if multi_clip_mode:
			visuals.append_array(_visuals_of(data, note_clip))
		else:
			var vn := get_visual_note(data.id)
			if vn:
				visuals.append(vn)
	selection_manager.select_visuals(visuals)
	var range: Vector2i = state.get("range", Vector2i.ZERO)
	selection_manager.box_selection_start_tick = range.x
	selection_manager.box_selection_end_tick = range.y
	selection_manager.selection_changed.emit(selection_manager.selected_notes)
	selection_range_restored.emit()


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
	var before := _history_clip_snapshots
	_history_clip_snapshots = {}
	var first: Array[Command] = []
	var last: Array[Command] = []
	var selection_now := capture_selection_state()
	if not _same_selection(_history_selection_before, selection_now):
		first.append(SelectionStateCommand.new(action_name, self, _history_selection_before, selection_now, true))
		last.append(SelectionStateCommand.new(action_name, self, _history_selection_before, selection_now, false))
	ClipNotesStateCommand.commit_many(action_name, before, first, last)


# ============================================================================
# PUBLIC API FOR MIDIEDITOR INPUT DELEGATION
# ============================================================================
func get_note_at_position(pos: Vector2) -> VisualNote:
	"""Find which note is at the given position (public API for MidiEditor)."""
	return _get_note_at_position(pos)


## Hover cursor for the mouse at `pos` (local): resize over a note's right edge, a hand over
## the rest of a note. Notes ignore the mouse themselves, and this editor is the control
## under the pointer, so it carries the cursor. Only this editor's notes are checked.
func update_hover_cursor(pos: Vector2) -> void:
	if is_over_group_scale_handle(pos):
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
		return
	var note := get_note_at_position(pos)
	mouse_default_cursor_shape = note.cursor_shape_at(pos - note.position) if note else Control.CURSOR_ARROW


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


func _gui_input(event: InputEvent) -> void:
	"""Keyboard input for the note area.

	The focused control is the only one whose `_gui_input` runs, and ClipEditor
	focuses this node (see ClipEditor._on_visibility_changed), so keys land here
	rather than on MidiEditor's own `_gui_input`.
	"""
	if event is InputEventKey:
		handle_key_input(event)
		if get_viewport().is_input_handled():
			key_input_handled.emit()


func handle_key_input(event: InputEventKey) -> void:
	"""Handle keyboard input."""
	if interaction_mode == InteractionMode.SCALING and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_group_scale()
		accept_event()
		return
	if Hotkeys.pressed(event, "edit_select_all"):
		# Clip mode: every note in the clip. Track mode: every note on the active track
		# (the active editor is the one bound to it).
		selection_manager.select_all(get_all_visual_notes())
		accept_event()

	elif Hotkeys.pressed(event, "edit_copy"):
		copy_to_clipboard()
		accept_event()

	elif Hotkeys.pressed(event, "edit_cut"):
		_cut_selection()
		accept_event()

	elif Hotkeys.pressed(event, "edit_paste"):
		paste_clipboard()
		accept_event()

	elif Hotkeys.pressed(event, "edit_duplicate"):
		_duplicate_selection()
		accept_event()

	elif Hotkeys.pressed(event, "edit_delete"):
		_delete_selection()
		accept_event()

	elif Hotkeys.pressed(event, "notes_octave_up"):
		_move_selection_vertical(func(p: int) -> int: return step_note(p, 12))
		accept_event()

	elif Hotkeys.pressed(event, "notes_octave_down"):
		_move_selection_vertical(func(p: int) -> int: return step_note(p, -12))
		accept_event()

	elif Hotkeys.pressed(event, "notes_transpose_up"):
		_transpose_selection(1)
		accept_event()

	elif Hotkeys.pressed(event, "notes_transpose_down"):
		_transpose_selection(-1)
		accept_event()

	elif Hotkeys.pressed(event, "notes_conform_to_scale"):
		conform_selection_to_scale()
		accept_event()

	elif Hotkeys.pressed(event, "notes_nudge_left"):
		_move_selection_horizontal(-get_snap_interval())
		accept_event()

	elif Hotkeys.pressed(event, "notes_nudge_right"):
		_move_selection_horizontal(get_snap_interval())
		accept_event()

	elif Hotkeys.pressed(event, "notes_range_end_right"):
		_resize_selection_range(0, get_snap_interval())
		accept_event()

	elif Hotkeys.pressed(event, "notes_range_end_left"):
		_resize_selection_range(0, -get_snap_interval())
		accept_event()

	elif Hotkeys.pressed(event, "notes_range_start_left"):
		_resize_selection_range(-get_snap_interval(), 0)
		accept_event()

	elif Hotkeys.pressed(event, "notes_range_start_right"):
		_resize_selection_range(get_snap_interval(), 0)
		accept_event()

	elif Hotkeys.pressed(event, "notes_move_by_selection_left"):
		_move_selection_by_its_length(-1)
		accept_event()

	elif Hotkeys.pressed(event, "notes_move_by_selection_right"):
		_move_selection_by_its_length(1)
		accept_event()

	elif Hotkeys.pressed(event, "notes_velocity_up"):
		_adjust_selection_velocity(KEY_VELOCITY_STEP)
		accept_event()

	elif Hotkeys.pressed(event, "notes_velocity_down"):
		_adjust_selection_velocity(-KEY_VELOCITY_STEP)
		accept_event()

	elif Hotkeys.pressed(event, "notes_length_grow"):
		_adjust_selection_length(get_snap_interval())
		accept_event()

	elif Hotkeys.pressed(event, "notes_length_shrink"):
		_adjust_selection_length(-get_snap_interval())
		accept_event()

	elif Hotkeys.pressed(event, "notes_flip_vertical"):
		flip_selection_vertical()
		accept_event()

	elif Hotkeys.pressed(event, "notes_flip_horizontal"):
		flip_selection_horizontal()
		accept_event()

	elif Hotkeys.pressed(event, "notes_quantize"):
		quantize_selection()
		accept_event()

	elif Hotkeys.pressed(event, "notes_strum"):
		strum_selection()
		accept_event()


# ============================================================================
# NOTE PLACEMENT
# ============================================================================
## Whether left-click note placement should also set the selection range to the
## new note's span (default off). Node lookup, not the bare autoload name, so
## headless test scripts that load() this file still compile.
func _placement_sets_range() -> bool:
	var settings := get_node_or_null("/root/Settings")
	return settings != null and settings.get_value("midi_editor/note_placement_sets_range")


func _place_note_at_position(pos: Vector2) -> VisualNote:
	"""Place a MIDI note at the given position."""
	logger.debug("placing note at ", pos.y)

	# With the "placement sets range" setting off, an existing time range survives
	# placement: remember it, since clear_selection resets the range ticks.
	var keep_range := not _placement_sets_range()
	var saved_range := Vector2i(selection_manager.box_selection_start_tick,
		selection_manager.box_selection_end_tick) if keep_range and selection_manager.has_range() else Vector2i.ZERO

	# Clear selection before placing new note
	selection_manager.clear_selection()

	# Convert position to MIDI note and tick
	var midi_note_num = y_to_note(pos.y)
	if midi_note_num < 0:
		# Drum View with no rows: there is nowhere to put a note (REQ-023).
		return null
	# Scale snap (REQ-014, REQ-019): the half of the row under the cursor breaks ties.
	if scale_context.snap_active() and not scale_context.is_keyswitch(midi_note_num):
		var upper_half := fposmod(pos.y, layout.row_height) < layout.row_height * 0.5
		midi_note_num = scale_context.snap_pitch(midi_note_num, upper_half)
	var pixel_x = pos.x
	var tick_position = pixels_to_ticks(pixel_x)

	# Snap to grid
	if grid_helper:
		tick_position = grid_helper.floor_ticks(tick_position)

	# A new note is one grid step long (REQ-019), in both views: the current snap
	# interval is the finest visible grid line, so zooming in lets you write 16ths.
	# In Drum View a hit is always one step: a length remembered from a piano-roll
	# resize would cut every following hit on the row when the overlap is cleared.
	var new_note_length := get_snap_interval()
	if not layout.is_drum() and last_note_length > 0:
		new_note_length = last_note_length

	var end_tick = tick_position + new_note_length

	# Determine which clip to add note to
	var target_clip: Clip
	var target_clip_instance: ClipInstance = null
	var song_tick: int = tick_position
	if multi_clip_mode:
		# MULTI-CLIP MODE: Find clip at cursor position, or create one
		target_clip_instance = get_or_create_clip_at_position(tick_position)
		if not target_clip_instance:
			logger.warn("No clip at position and creation not yet implemented (Phase 5)")
			return null
		target_clip = target_clip_instance.clip
		# Song ticks to clip content; a click in a loop repeat lands in the loop region.
		tick_position = target_clip_instance.song_to_played_content_ticks(tick_position)
		end_tick = tick_position + new_note_length
	else:
		# SINGLE-CLIP MODE: Use the bound clip
		if not clip:
			logger.warn("No clip loaded in MIDI editor")
			return null
		target_clip = clip

	# Clamp to the free space before the next note on this pitch instead of cutting it.
	var next_start := target_clip.next_note_start_at_pitch(midi_note_num, tick_position)
	if next_start >= 0 and next_start < end_tick:
		new_note_length = next_start - tick_position
		end_tick = next_start

	_history_begin_clips([target_clip])
	# Cut overlapping notes
	var affected_notes = target_clip.cut_overlapping_notes_at_pitch(midi_note_num, tick_position, end_tick, target_clip.allocate_note_id)

	if not affected_notes.is_empty():
		logger.info("Cut/merged %d overlapping notes" % affected_notes.size())

	var note_id: int = target_clip.allocate_note_id()

	# Add note to clip
	var note_data = target_clip.add_midi_note(note_id, midi_note_num, next_values.velocity, tick_position, new_note_length, next_values.release)
	if note_data == null:
		push_error("[NoteEditor] Failed to add note after cutting overlaps")
		_history_clip_snapshots.clear()
		return null

	logger.info("Added note %d: MIDI=%d start=%d duration=%d" % [note_data.id, midi_note_num, tick_position, new_note_length])

	# Get visual note created reactively: the one under the mouse (a loop repeat, or the
	# note on the clicked instance when the clip is used more than once).
	var note_instance: VisualNote = null
	if target_clip_instance:
		note_instance = visual_at_song_tick(target_clip_instance, note_data, song_tick)
	else:
		note_instance = get_visual_note(note_data.id)
	if note_instance == null:
		push_error("[NoteEditor] Failed to find visual note after creation")
		return null

	logger.info("Placed note: MIDI %d at tick %d (duration: %d)" % [midi_note_num, tick_position, new_note_length])

	# Select the newly placed note (uses coordinate conversion callback)
	_history_commit("Place Note")
	# Placement can leave the selection range at the note's span, but only when the
	# user asked for it (default: off, so placing doesn't move the range).
	var with_range := _placement_sets_range()
	selection_manager.select_note(note_instance, with_range)
	if not with_range and saved_range != Vector2i.ZERO:
		selection_manager.box_selection_start_tick = saved_range.x
		selection_manager.box_selection_end_tick = saved_range.y
		selection_manager.selection_changed.emit(selection_manager.selected_notes)
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
	note_touched.emit(note.midi_note_data)

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
			# Prefer the visual note's attached clip instance to avoid id collisions in multi-clip mode
			var source_clip_instance: ClipInstance = sel_note.clip_instance
			if not source_clip_instance:
				source_clip_instance = get_clip_instance_for_note(sel_note.midi_note_data.id)
			drag_start_positions[sel_note.midi_note_data.id] = {
				"start_tick": sel_note.midi_note_data.start_tick,
				"note": sel_note.midi_note_data.note,
				"velocity": sel_note.midi_note_data.velocity,
				"clip_instance": source_clip_instance
			}
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks


func _on_drag_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	"""Handle note drag update (ctrl-to-resize, alt-for-velocity, shift-to-bypass-snapping)."""
	if dragging_note != note or not note.midi_note_data:
		return

	var ctrl_pressed = Input.is_key_pressed(KEY_CTRL)
	var alt_pressed = Input.is_key_pressed(KEY_ALT)
	var drum_view := layout.is_drum()

	# Drum View draws hits, not bars, so there is no length to drag out (REQ-022).
	# Length falls back to plain dragging (Ctrl) or to velocity only (Alt).
	var auto_alt := _alt_auto_mode()
	if drum_view or auto_alt:
		ctrl_pressed = false

	# Determine current mode
	var current_mode: DragMode
	if alt_pressed and auto_alt and not drum_view:
		current_mode = _alt_axis_mode(mouse_pos_local)
	elif alt_pressed:
		current_mode = DragMode.VELOCITY
	elif ctrl_pressed:
		current_mode = DragMode.RESIZE
	else:
		current_mode = DragMode.POSITION

	# Check if mode changed
	if current_mode != last_drag_mode:
		drag_start_mouse_pos = mouse_pos_local

		# Update stored starting positions
		_snapshot_selection()

		last_drag_mode = current_mode
		logger.info("Drag mode switched to: %s" % ["POSITION", "RESIZE", "VELOCITY", "PENDING"][current_mode])

	# Alt is down but undecided: nothing moves until the mouse commits to an axis.
	if current_mode == DragMode.PENDING:
		return

	var delta_x = mouse_pos_local.x - drag_start_mouse_pos.x
	var delta_ticks = pixels_to_ticks(delta_x)
	# Snap the drag delta, not each note, so notes keep their offsets from each other.
	var snapped_delta_ticks: int = _snap_unless_shift(delta_ticks)

	# Each note once, however many of its visuals (loop repeats, linked instances) are selected.
	var edited := _selected_note_visuals()

	if current_mode == DragMode.VELOCITY:
		# Alt mode: Control velocity. Dragging up raises it, 2 px per 1/127 step.
		var velocity_delta := int(-(mouse_pos_local.y - drag_start_mouse_pos.y) / 2.0) / 127.0

		for sel_note in edited:
			var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
			if not start_pos:
				continue

			var start_velocity: float = start_pos.get("velocity", MidiNoteData.DEFAULT_VELOCITY)
			var new_velocity := clampf(start_velocity + velocity_delta, MidiNoteData.MIN_VELOCITY, 1.0)

			sel_note.midi_note_data.velocity = new_velocity

	elif current_mode == DragMode.RESIZE:
		# Length mode (Ctrl, or Alt dragged sideways): Control note length
		for sel_note in edited:
			var start_duration = resize_start_durations.get(sel_note.midi_note_data.id)
			if start_duration == null:
				continue

			var new_duration := _snapped_duration(start_duration + delta_ticks)
			sel_note.midi_note_data.duration_ticks = new_duration
	else:
		# Normal mode: Control position
		# Row-wise in Drum View, semitone-wise in the piano roll (REQ-020). The two
		# agree exactly in chromatic mode.
		var delta_steps := layout.row_of_pitch(drag_start_midi_note) - layout.y_to_row(mouse_pos_local.y)
		# Scale snap (REQ-015, 016, 018): the cursor picks an in-scale target and every note
		# moves the same number of scale steps. Shift keeps the plain row walk.
		var scale_steps := 0
		var scale_drag: bool = scale_context.snap_active() and not Input.is_key_pressed(KEY_SHIFT)
		if scale_drag:
			var upper_half := fposmod(mouse_pos_local.y, layout.row_height) < layout.row_height * 0.5
			var target := scale_context.snap_pitch(layout.y_to_pitch(mouse_pos_local.y), upper_half)
			scale_steps = scale_context.steps_between(drag_start_midi_note, target)

		for sel_note in edited:
			var start_pos = drag_start_positions.get(sel_note.midi_note_data.id)
			if not start_pos:
				continue

			var new_ticks: int = maxi(0, start_pos.start_tick + snapped_delta_ticks)
			var new_midi_note := step_note(start_pos.note, delta_steps)
			if scale_drag and not scale_context.is_keyswitch(start_pos.note):
				new_midi_note = scale_context.step(start_pos.note, scale_steps)

			# Clamp within clip content in track-mode to avoid crossing instance boundaries
			if multi_clip_mode:
				var owner_ci_clamp := _instance_for_visual_note(sel_note)
				if owner_ci_clamp and owner_ci_clamp.in_loop_region(start_pos.start_tick):
					# A note in the loop stays in it: dragged past the loop end it comes in
					# again at the loop start, which is where the next pass shows it.
					new_ticks = owner_ci_clamp.fold_into_loop(start_pos.start_tick + snapped_delta_ticks)
				elif owner_ci_clamp and owner_ci_clamp.clip:
					# The bound is the instance's played window, not the content
					# length: content length is the rightmost note end, so using it
					# would pin the last note in place and make dragging right a no-op.
					# Content that reaches past the window (a trimmed instance) still
					# gets that larger bound, so no note is ever clamped backwards.
					var clip_len: int = max(owner_ci_clamp.clip_offset + owner_ci_clamp.duration_ticks, owner_ci_clamp.clip.get_content_length())
					if clip_len > 0:
						new_ticks = clampi(new_ticks, 0, maxi(0, clip_len - sel_note.midi_note_data.duration_ticks))

			sel_note.midi_note_data.start_tick = new_ticks
			sel_note.midi_note_data.note = new_midi_note

	_refresh_notes(edited)

	if current_mode == DragMode.POSITION:
		# A note dragged out of its (unlooped) instance stays in view under the mouse until
		# the drop moves it into the clip it lands on.
		for sel_note in selection_manager.selected_notes:
			if not is_instance_valid(sel_note) or not sel_note.midi_note_data or sel_note.repeat_pass > 0:
				continue
			var owner_ci := _instance_for_visual_note(sel_note)
			if multi_clip_mode and owner_ci and not owner_ci.loop_enabled and not sel_note.visible:
				var rect := NotePlacement.note_rect(sel_note.midi_note_data, owner_ci.content_origin_ticks(), layout, grid_helper)
				if rect.has_area():
					sel_note.visible = true
					sel_note.position = rect.position
					sel_note.size = rect.size


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
			if sel_note.midi_note_data.velocity != start_pos.get("velocity", MidiNoteData.DEFAULT_VELOCITY):
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

	var drag_start_duration = resize_start_durations.get(note.midi_note_data.id)
	if drag_start_duration != null and note.midi_note_data.duration_ticks != drag_start_duration:
		last_note_length = note.midi_note_data.duration_ticks

	# MULTI-CLIP MODE: Check if notes need to be transferred between clips
	if multi_clip_mode:
		_handle_cross_clip_transfers()

	# Process all selected notes (cut overlaps and update)
	var total_affected = 0
	# A cross-clip transfer above frees the old visual and replaces it with a new one
	# carrying a new id, and drops it from the selection, so this list is current.
	for sel_note in _selected_note_visuals():
		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		# Get the clip this visual note belongs to (prefer its clip_instance)
		var note_clip: Clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			note_clip.allocate_note_id,
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
	if layout.is_drum():
		return

	if note not in selection_manager.selected_notes:
		selection_manager.select_note(note)
	note_touched.emit(note.midi_note_data)

	resizing_note = note
	resize_start_duration = note.midi_note_data.duration_ticks
	resize_start_mouse_pos = click_position

	# Store starting durations for all selected notes
	resize_start_durations.clear()
	for sel_note in selection_manager.selected_notes:
		if sel_note.midi_note_data:
			resize_start_durations[sel_note.midi_note_data.id] = sel_note.midi_note_data.duration_ticks

	_history_begin_selection()


## Note length rounded to the nearest grid step, never shorter than one grid step.
## Alt auto mode: while the mouse is within ALT_AXIS_THRESHOLD of where Alt engaged the drag
## is PENDING, then the dominant axis picks length (sideways) or velocity (up, down) and
## stays picked until Alt is released.
func _alt_axis_mode(mouse_pos_local: Vector2) -> DragMode:
	if last_drag_mode == DragMode.RESIZE or last_drag_mode == DragMode.VELOCITY:
		return last_drag_mode
	if last_drag_mode != DragMode.PENDING:
		return DragMode.PENDING
	var moved := mouse_pos_local - drag_start_mouse_pos
	if moved.length() < ALT_AXIS_THRESHOLD:
		return DragMode.PENDING
	return DragMode.RESIZE if absf(moved.x) >= absf(moved.y) else DragMode.VELOCITY


## While Shift is held the snap is bypassed and the minimum is a single tick.
func _snapped_duration(ticks: int) -> int:
	if Input.is_key_pressed(KEY_SHIFT):
		return maxi(1, ticks)
	var snap_interval := get_snap_interval()
	if grid_helper:
		ticks = grid_helper.snap_ticks(ticks)
	return maxi(snap_interval, ticks)


## Grid-snapped `ticks`, or `ticks` untouched while Shift is held (free placement).
func _snap_unless_shift(ticks: int) -> int:
	if grid_helper and not Input.is_key_pressed(KEY_SHIFT):
		return grid_helper.snap_ticks(ticks)
	return ticks


func _on_resize_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	"""Handle note resize update."""
	if resizing_note != note or not note.midi_note_data:
		return

	var delta = mouse_pos_local - resize_start_mouse_pos
	var delta_ticks = pixels_to_ticks(delta.x)

	var new_duration := _snapped_duration(resize_start_duration + delta_ticks)

	var same_length := Input.is_key_pressed(KEY_ALT if _alt_auto_mode() else KEY_CTRL)

	# Update all selected notes (each once; see _selected_note_visuals)
	var edited := _selected_note_visuals()
	for sel_note in edited:
		var note_new_duration: int

		if same_length:
			# Length key (Alt or Ctrl, see the note drag modifiers setting): all notes get the same duration
			note_new_duration = new_duration
		else:
			# Default: Apply same delta to each note
			var note_start_duration = resize_start_durations.get(sel_note.midi_note_data.id, sel_note.midi_note_data.duration_ticks)
			note_new_duration = _snapped_duration(note_start_duration + delta_ticks)

		sel_note.midi_note_data.duration_ticks = note_new_duration
	_refresh_notes(edited)


func _on_resize_ended(note: VisualNote) -> void:
	"""Handle note resize end."""
	if resizing_note != note or not note.midi_note_data:
		return

	last_note_length = note.midi_note_data.duration_ticks

	# Process all selected notes
	var total_affected = 0
	for sel_note in _selected_note_visuals():
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
			note_clip.allocate_note_id,
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
		if child is VisualNote and child.visible and not child.is_pending:
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


## Ctrl+C: the selected notes over the selection range. With nothing selected and no range,
## the edited clips instead: their notes are selected and the range becomes their span, so
## the range can carry over to another track and the paste lands at the same position.
func copy_to_clipboard() -> void:
	if selection_manager.selected_notes.is_empty() and not selection_manager.has_range():
		select_edited_clips()
	selection_manager.copy_selection()


## Select every shown note of the edited clips and set the range to their span. Clip mode
## uses the bound instance's played window (clip-content ticks); track mode the song span
## of `edited_clip_instances` that this editor shows. Returns false when there is no clip.
func select_edited_clips() -> bool:
	var start_tick := 0
	var end_tick := 0
	var notes: Array[VisualNote] = []
	if multi_clip_mode:
		var instances: Array[ClipInstance] = []
		for ci in edited_clip_instances:
			if is_instance_valid(ci) and clip_instances.has(ci):
				instances.append(ci)
		if instances.is_empty():
			return false
		start_tick = instances[0].start_ticks
		end_tick = instances[0].get_end_ticks()
		for ci in instances:
			start_tick = mini(start_tick, ci.start_ticks)
			end_tick = maxi(end_tick, ci.get_end_ticks())
		for vn in get_all_visual_notes():
			if vn.clip_instance and instances.has(vn.clip_instance):
				notes.append(vn)
	else:
		if not clip_instance:
			return false
		start_tick = clip_instance.clip_offset
		end_tick = clip_instance.clip_offset + clip_instance.duration_ticks
		if clip_instance.loop_enabled:
			start_tick = clip_instance.loop_start_ticks
			end_tick = start_tick + clip_instance.loop_length_ticks
		for vn in get_all_visual_notes():
			var nd: MidiNoteData = vn.midi_note_data
			if nd.start_tick >= start_tick and nd.start_tick < end_tick:
				notes.append(vn)
	selection_manager._set_selected_notes(notes)
	selection_manager.box_selection_start_tick = start_tick
	selection_manager.box_selection_end_tick = end_tick
	selection_manager.selection_changed.emit(selection_manager.selected_notes)
	return true


## Where Ctrl+V lands: the range start when a range is set with no notes selected (a range
## carried over from another track, or a ruler range over empty space), else the cursor.
## With notes selected the range is theirs, and pasting onto them would only replace them.
func get_paste_tick() -> int:
	if selection_manager.selected_notes.is_empty() and selection_manager.has_range():
		return selection_manager.box_selection_start_tick
	return cursor_position_ticks


## Ctrl+V: paste the shared note clipboard at get_paste_tick().
func paste_clipboard() -> void:
	_paste_at_position(get_paste_tick())


func _paste_at_position(tick_position: int) -> void:
	"""Paste clipboard contents at the specified tick position (this editor's ticks)."""
	var source: NoteSelection = selection_manager.clipboard
	if not source or source.is_empty():
		logger.warn("Clipboard is empty")
		return
	if not multi_clip_mode and not clip:
		logger.warn("No clip loaded")
		return

	# Snap to grid
	if grid_helper:
		tick_position = grid_helper.floor_ticks(tick_position)
	var span_end := tick_position + source.duration_ticks

	# Pick each note's clip. Track mode: the clip playing at the note's song position, or a
	# new clip covering the pasted span when there is none, so a range copied across several
	# clips lands in the matching clips of the target track (notes stay visible).
	var targets: Array = []  # [MidiNoteData in clip-content ticks, Clip, ClipInstance, song tick]
	var target_clips: Array = []
	for note_data in source.get_notes_at_position(tick_position):
		var target_clip: Clip = clip
		var ci: ClipInstance = null
		var song_tick := note_data.start_tick
		if multi_clip_mode:
			ci = get_or_create_clip_at_position(note_data.start_tick, span_end)
			if not ci:
				logger.warn("Cannot paste note at tick %d - no clip there" % note_data.start_tick)
				continue
			# A note pasted into a loop repeat lands in the loop region.
			note_data.start_tick = ci.song_to_played_content_ticks(note_data.start_tick)
			target_clip = ci.clip
		targets.append([note_data, target_clip, ci, song_tick])
		if not target_clips.has(target_clip):
			target_clips.append(target_clip)
	if targets.is_empty():
		logger.warn("Cannot paste - no clip at position")
		return

	_history_begin_clips(target_clips)
	# Cut overlapping notes
	var total_affected = 0
	for target in targets:
		var note_data: MidiNoteData = target[0]
		var target_clip: Clip = target[1]
		var end_tick = note_data.start_tick + note_data.duration_ticks
		var affected = target_clip.cut_overlapping_notes_at_pitch(note_data.note, note_data.start_tick, end_tick, target_clip.allocate_note_id)
		total_affected += affected.size()

	if total_affected > 0:
		logger.info("Paste cut/merged %d overlapping notes" % total_affected)

	selection_manager.clear_selection()

	# Add notes to clips
	var pasted: Array = []  # the targets that were added
	for target in targets:
		var note_data: MidiNoteData = target[0]
		var target_clip: Clip = target[1]
		note_data.id = target_clip.allocate_note_id()
		var added = target_clip.add_midi_note_data(note_data)
		if added == null:
			push_warning("[NoteEditor] Failed to paste note at pitch=%d, start=%d" % [note_data.note, note_data.start_tick])
			continue
		pasted.append(target)

	# Select newly pasted notes: the visuals where they were pasted (a loop repeat, or the
	# instance the paste landed on)
	var pasted_notes: Array[VisualNote] = []
	for target in pasted:
		var note_data: MidiNoteData = target[0]
		var note_instance: VisualNote = visual_at_song_tick(target[2], note_data, target[3]) if target[2] else get_visual_note(note_data.id)
		if note_instance and note_instance not in pasted_notes:
			pasted_notes.append(note_instance)

	selection_manager._set_selected_notes(pasted_notes)

	# Set selection range
	if not selection_manager.selected_notes.is_empty():
		selection_manager.box_selection_start_tick = tick_position
		selection_manager.box_selection_end_tick = span_end
		queue_redraw()

	selection_manager.selection_changed.emit(selection_manager.selected_notes)

	logger.info("Pasted %d notes at tick %d (range: %d-%d)" % [
		pasted.size(), tick_position, selection_manager.box_selection_start_tick, selection_manager.box_selection_end_tick
	])
	_history_commit("Paste Notes")


func _duplicate_selection() -> void:
	"""Duplicate selected notes immediately after the selection."""
	_history_begin_selection()
	if selection_manager.selected_notes.is_empty():
		logger.warn("No notes selected to duplicate")
		return

	var selection := selection_manager.snapshot_selection()
	if selection == null:
		logger.warn("Cannot duplicate - invalid selection range")
		return

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

	# Each note once: removing it frees all its visuals and drops them from the selection.
	var doomed := _selected_note_visuals()
	var count = doomed.size()
	for note in doomed:
		var note_clip = _clip_for_visual_note(note)
		if note_clip:
			note_clip.remove_midi_note(note.midi_note_data)

	selection_manager.selected_notes.clear()
	selection_manager.selected_note = null
	selection_manager.selection_changed.emit(selection_manager.selected_notes)

	update_container_width()

	logger.info("Deleted %d notes" % count)
	_history_commit("Delete Notes")


## Arrow-key transpose: one scale step when scale snap is active (keyswitch notes move one
## row/semitone), else one row as before.
func _transpose_selection(direction: int) -> void:
	if scale_context.snap_active():
		_move_selection_vertical(func(p: int) -> int:
			if scale_context.is_keyswitch(p):
				return step_note(p, direction)
			return scale_context.step(p, direction))
	else:
		_move_selection_vertical(func(p: int) -> int: return step_note(p, direction))


## Move all selected notes; `step` maps each note's pitch to its new pitch.
func _move_selection_vertical(step: Callable) -> void:
	_history_begin_selection()
	if selection_manager.selected_notes.is_empty():
		return

	# Move all selected notes. Linked clip instances and loop repeats show the same
	# MidiNoteData through several visuals, so step each note once.
	var edited := _selected_note_visuals()
	for sel_note in edited:
		sel_note.midi_note_data.note = step.call(sel_note.midi_note_data.note)
	_refresh_notes(edited)

	# Process overlaps and sync
	var total_affected = 0
	for sel_note in edited:
		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		var note_clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			note_clip.allocate_note_id,
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		logger.info("Keyboard move vertical - cut/merged %d overlapping notes" % total_affected)

	logger.info("Moved %d note(s) vertically" % selection_manager.selected_notes.size())
	update_container_width()
	_history_commit("Transpose Notes")


func _move_selection_horizontal(delta_ticks: int) -> void:
	"""Move all selected notes left or right by ticks."""
	_history_begin_selection()
	if selection_manager.selected_notes.is_empty():
		return

	# Move all selected notes (each shared MidiNoteData once; see _move_selection_vertical)
	var edited := _selected_note_visuals()
	for sel_note in edited:
		var note_data := sel_note.midi_note_data
		var owner_ci := _instance_for_visual_note(sel_note) if multi_clip_mode else null
		if owner_ci and owner_ci.in_loop_region(note_data.start_tick):
			# Stays in the loop, like a drag (the next pass shows it past the loop end).
			note_data.start_tick = owner_ci.fold_into_loop(note_data.start_tick + delta_ticks)
		else:
			note_data.start_tick = maxi(0, note_data.start_tick + delta_ticks)
	_refresh_notes(edited)

	# Process overlaps and sync
	var total_affected = 0
	for sel_note in edited:
		var note_data = sel_note.midi_note_data
		var end_tick = note_data.start_tick + note_data.duration_ticks

		var note_clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue

		var affected_notes = note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			end_tick,
			note_clip.allocate_note_id,
			note_data.id
		)

		total_affected += affected_notes.size()
		note_clip.update_midi_note(note_data)

	if total_affected > 0:
		logger.info("Keyboard move horizontal - cut/merged %d overlapping notes" % total_affected)

	logger.info("Moved %d note(s) %+d ticks" % [selection_manager.selected_notes.size(), delta_ticks])

	# The selection range goes with the notes (it stops at tick 0).
	if selection_manager.has_range():
		var range_delta := maxi(delta_ticks, -selection_manager.box_selection_start_tick)
		selection_manager.box_selection_start_tick += range_delta
		selection_manager.box_selection_end_tick += range_delta
		selection_manager.selection_changed.emit(selection_manager.selected_notes)
	queue_redraw()
	update_container_width()
	_history_commit("Nudge Notes")


## MIDI velocity steps per press of the velocity hotkeys (held keys repeat).
const KEY_VELOCITY_STEP := 4.0 / 127.0


## Move the selection range's start by `start_delta` and its end by `end_delta` (negative =
## earlier). The start stays at 0 or later and the range keeps at least one tick. The notes
## themselves stay as they are.
func _resize_selection_range(start_delta: int, end_delta: int) -> void:
	if not selection_manager.has_range():
		return
	var start := maxi(0, selection_manager.box_selection_start_tick + start_delta)
	var end := selection_manager.box_selection_end_tick + end_delta
	if end <= start:
		return
	selection_manager.box_selection_start_tick = start
	selection_manager.box_selection_end_tick = end
	selection_manager.selection_changed.emit(selection_manager.selected_notes)


## Move the selected notes and the range by the range's length (the span of the selected
## notes when there is no range). `direction` is -1 or 1.
func _move_selection_by_its_length(direction: int) -> void:
	var span_start := selection_manager.box_selection_start_tick
	var span_end := selection_manager.box_selection_end_tick
	if span_end <= span_start:
		var snapshot := selection_manager.snapshot_selection()
		if snapshot == null:
			return
		span_start = snapshot.start_tick
		span_end = snapshot.end_tick
	var delta := (span_end - span_start) * direction
	# The group moves as one: stop at tick 0 instead of squashing notes against it.
	delta = maxi(delta, -span_start)
	if delta == 0:
		return
	_move_selection_horizontal(delta)


## Run `mutate(note_data)` on every selected note once, then sync and commit one undo step.
func _edit_selection_data(history_name: String, mutate: Callable) -> void:
	_apply_selection_edit(history_name, func(notes: Array[MidiNoteData]):
		for note_data in notes:
			mutate.call(note_data))


## Shared path of the selection tools (quantize, mirror, strum, ...). Runs `edit(notes)` once on
## the selected notes (an Array[MidiNoteData], each shared note once), then refreshes the
## visuals, cuts same-pitch overlaps, syncs the engine and records one undo/redo step
## (ClipNotesStateCommand plus the selection) under `history_name`.
func _apply_selection_edit(history_name: String, edit: Callable) -> void:
	if selection_manager.selected_notes.is_empty():
		return
	_history_begin_selection()
	var edited := _selected_note_visuals()
	var notes: Array[MidiNoteData] = []
	for sel_note in edited:
		notes.append(sel_note.midi_note_data)
	edit.call(notes)
	_refresh_notes(edited)
	_sync_edited_notes(edited)
	_history_commit(history_name)


## After an edit: cut same-pitch overlaps, sync the engine and fix the content width.
func _sync_edited_notes(edited: Array[VisualNote]) -> void:
	for sel_note in edited:
		var note_data := sel_note.midi_note_data
		var note_clip: Clip = _clip_for_visual_note(sel_note)
		if not note_clip:
			continue
		note_clip.cut_overlapping_notes_at_pitch(
			note_data.note,
			note_data.start_tick,
			note_data.start_tick + note_data.duration_ticks,
			note_clip.allocate_note_id,
			note_data.id
		)
		note_clip.update_midi_note(note_data)

	queue_redraw()
	update_container_width()


const QUANTIZE_STRENGTH_KEY := "clip_editor/quantize_strength"
const QUANTIZE_MODE_KEY := "clip_editor/quantize_mode"


## Node lookup, not the bare autoload name, so headless scripts that load() this file compile.
static func _config_value(key: String, default: Variant) -> Variant:
	var sonara: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Sonara")
	return sonara.get_config(key, default) if sonara else default


## Remembered quantize strength (0..1); 1 is a hard snap.
static func quantize_strength() -> float:
	return clampf(float(_config_value(QUANTIZE_STRENGTH_KEY, 1.0)), 0.0, 1.0)


static func quantize_mode() -> NoteTransforms.QuantizeMode:
	return int(_config_value(QUANTIZE_MODE_KEY, NoteTransforms.QuantizeMode.START)) as NoteTransforms.QuantizeMode


## Quantize the selected notes to the grid with the remembered strength and mode (one undo step).
## Starts of notes inside a loop region stay in the loop. Drum View hits have no length, so the
## end is left alone there.
func quantize_selection(strength: float = -1.0, mode: int = -1) -> void:
	if grid_helper == null:
		return
	var use_strength := quantize_strength() if strength < 0.0 else strength
	var use_mode := quantize_mode() if mode < 0 else mode as NoteTransforms.QuantizeMode
	if layout.is_drum():
		use_mode = NoteTransforms.QuantizeMode.START
	var loop_owner := _loop_owners()
	_apply_selection_edit("Quantize Notes", func(notes: Array[MidiNoteData]):
		NoteTransforms.quantize(notes, grid_helper.snap_ticks, use_strength, use_mode)
		_fold_into_loops(notes, loop_owner))


## Selected notes that start inside a loop region, mapped to their instance. Taken before an
## edit moves them, because the edit may move a start out of the loop.
func _loop_owners() -> Dictionary:
	var owners := {}
	for vn in _selected_note_visuals():
		var owner_ci := _instance_for_visual_note(vn) if multi_clip_mode else clip_instance
		if owner_ci and owner_ci.in_loop_region(vn.midi_note_data.start_tick):
			owners[vn.midi_note_data] = owner_ci
	return owners


func _fold_into_loops(notes: Array[MidiNoteData], owners: Dictionary) -> void:
	for note_data in notes:
		if owners.has(note_data):
			note_data.start_tick = owners[note_data].fold_into_loop(note_data.start_tick)


## Invert the selected notes' pitches around the middle of their pitch range (one undo step).
## Does nothing in Drum View, where rows are pads and not a pitch scale.
func flip_selection_vertical() -> void:
	if layout.is_drum():
		return
	_apply_selection_edit("Flip Notes Vertically", func(notes: Array[MidiNoteData]):
		var bounds := NoteTransforms.pitch_bounds(notes)
		NoteTransforms.mirror_pitch(notes, bounds.x, bounds.y))


## Snap the selected notes to the project scale (one undo step). Does nothing without a scale
## or in Drum View. Keyswitch notes stay put.
func conform_selection_to_scale() -> void:
	if not scale_context.highlight_active():
		return
	_apply_selection_edit("Conform to Scale", func(notes: Array[MidiNoteData]):
		NoteTransforms.conform_to_scale(notes, scale_context.pitch_classes(), scale_context.keyswitches))


## Reverse the selected notes in time (one undo step). The axis is the selection range when
## there is one, else the span of the selected notes.
func flip_selection_horizontal() -> void:
	var range_start := selection_manager.box_selection_start_tick
	var range_end := selection_manager.box_selection_end_tick
	var loop_owner := _loop_owners()
	_apply_selection_edit("Flip Notes Horizontally", func(notes: Array[MidiNoteData]):
		if not selection_manager.has_range():
			var span := NoteTransforms.tick_bounds(notes)
			range_start = span.x
			range_end = span.y
		NoteTransforms.mirror_time(notes, range_start, range_end, not layout.is_drum())
		_fold_into_loops(notes, loop_owner))


const STRUM_SPREAD_KEY := "clip_editor/strum_spread_ticks"
const STRUM_DIRECTION_KEY := "clip_editor/strum_direction"
const STRUM_RAMP_KEY := "clip_editor/strum_velocity_ramp"


## Remembered strum spread between neighbouring chord notes, in ticks (960 PPQ).
static func strum_spread() -> int:
	return maxi(0, int(_config_value(STRUM_SPREAD_KEY, 30)))


static func strum_direction() -> NoteTransforms.StrumDirection:
	return int(_config_value(STRUM_DIRECTION_KEY, NoteTransforms.StrumDirection.UP)) as NoteTransforms.StrumDirection


## Remembered velocity ramp across a strum (-1..1).
static func strum_velocity_ramp() -> float:
	return clampf(float(_config_value(STRUM_RAMP_KEY, 0.0)), -1.0, 1.0)


## Strum the chords among the selected notes with the remembered spread, direction and velocity
## ramp (one undo step). Note ends stay where they are. Does nothing in Drum View, where hits
## have no length and rows are pads.
func strum_selection() -> void:
	if layout.is_drum():
		return
	# Note ticks are clip ticks, so chords are only found inside one clip: notes of different
	# clips that happen to share a clip tick are not a chord.
	var clip_of := {}
	for vn in _selected_note_visuals():
		clip_of[vn.midi_note_data] = _clip_for_visual_note(vn)
	var spread := strum_spread()
	var direction := strum_direction()
	var ramp := strum_velocity_ramp()
	_apply_selection_edit("Strum Notes", func(notes: Array[MidiNoteData]):
		var per_clip := {}
		for note_data in notes:
			var clip: Clip = clip_of.get(note_data)
			if not per_clip.has(clip):
				var typed: Array[MidiNoteData] = []
				per_clip[clip] = typed
			per_clip[clip].append(note_data)
		for clip_notes: Array[MidiNoteData] in per_clip.values():
			NoteTransforms.strum(clip_notes, spread, direction, ramp))


func _adjust_selection_velocity(delta: float) -> void:
	_edit_selection_data("Change Velocity", func(note_data: MidiNoteData):
		note_data.velocity = clampf(note_data.velocity + delta, MidiNoteData.MIN_VELOCITY, 1.0))


## Drum View hits have no length (REQ-022), so this does nothing there.
func _adjust_selection_length(delta_ticks: int) -> void:
	if layout.is_drum():
		return
	var floor_ticks := get_snap_interval()
	_edit_selection_data("Resize Notes", func(note_data: MidiNoteData):
		note_data.duration_ticks = maxi(floor_ticks, note_data.duration_ticks + delta_ticks)
		last_note_length = note_data.duration_ticks)


func _on_clip_note_removed(note_data: MidiNoteData, source_clip: Clip) -> void:
	"""Handle when a note is removed from the clip."""
	# Drop every visual of the note from the selection (track mode: one per instance)
	var gone: Array[VisualNote] = []
	if multi_clip_mode:
		gone = _visuals_of(note_data, source_clip)
	else:
		var note_instance := get_visual_note(note_data.id)
		if note_instance:
			gone.append(note_instance)
	for vn in gone:
		selection_manager.selected_notes.erase(vn)
		queue_redraw()
		if selection_manager.selected_note == vn:
			selection_manager.selected_note = null

	# Call parent implementation
	super._on_clip_note_removed(note_data, source_clip)


# ============================================================================
# CTRL+DRAG DUPLICATE
# ============================================================================
# Duplicates are "pending" visual notes that belong to no clip yet: their note data is
# a copy whose start_tick is in this editor's ticks (clip-content in clip mode, song in
# track mode). With no clip_instance, _update_single_note_position places them at
# exactly that tick in both modes, so zoom and scroll keep working mid-drag. They are
# only written to clips when the drag ends.

## Pending duplicate -> {start_tick, note} in editor ticks, captured at drag start.
var _dup_origins: Dictionary = {}
## The duplicate of the note that was grabbed, which steers the pitch delta.
var dup_anchor: VisualNote = null
var _dup_start_mouse_pos: Vector2 = Vector2.ZERO


## The duplicates being dragged, in creation order.
func get_pending_duplicates() -> Array[VisualNote]:
	var out: Array[VisualNote] = []
	for vn in _dup_origins:
		if is_instance_valid(vn):
			out.append(vn)
	return out


## Start duplicating: the selection when the grabbed note is part of it, otherwise just
## the grabbed note. Returns false when there was nothing to copy.
func start_duplicate_drag(grabbed: VisualNote, mouse_pos_local: Vector2) -> bool:
	if not grabbed or not grabbed.midi_note_data:
		return false
	cancel_duplicate_drag()
	var sources: Array[VisualNote] = []
	if grabbed in selection_manager.selected_notes:
		sources.assign(selection_manager.selected_notes)
	else:
		sources.append(grabbed)

	for src in sources:
		if not is_instance_valid(src) or not src.midi_note_data:
			continue
		var nd: MidiNoteData = src.midi_note_data
		var copy := MidiNoteData.new()
		copy.copy_values_from(nd)
		# Where this visual shows it: a loop repeat's pass, not the note's first one.
		copy.start_tick = get_note_song_position(src).start_tick
		var vn: VisualNote = visual_note_scene.instantiate()
		vn.is_pending = true
		add_child(vn)
		vn.bind_to_note(copy)
		vn.set_color(note_color)
		vn.set_selected(true)
		_update_single_note_position(vn)
		_dup_origins[vn] = {"start_tick": copy.start_tick, "note": copy.note}
		if src == grabbed:
			dup_anchor = vn

	if _dup_origins.is_empty():
		return false
	_dup_start_mouse_pos = mouse_pos_local
	interaction_mode = InteractionMode.DUPLICATING
	return true


## Move every duplicate by the snapped mouse delta, keeping their relative layout.
func update_duplicate_drag(mouse_pos_local: Vector2) -> void:
	if _dup_origins.is_empty() or not dup_anchor:
		return
	var delta_ticks := pixels_to_ticks(mouse_pos_local.x - _dup_start_mouse_pos.x)
	delta_ticks = _snap_unless_shift(delta_ticks)
	var anchor_pitch: int = _dup_origins[dup_anchor].note
	var delta_steps := layout.row_of_pitch(anchor_pitch) - layout.y_to_row(mouse_pos_local.y)
	for vn in get_pending_duplicates():
		var origin: Dictionary = _dup_origins[vn]
		vn.midi_note_data.start_tick = maxi(0, origin.start_tick + delta_ticks)
		vn.midi_note_data.note = step_note(origin.note, delta_steps)
		vn._update_visual()
		_update_single_note_position(vn)


## Write the duplicates into their clips (one undo step) and select them. Dropping them
## back exactly where they started is treated as a cancel.
func finish_duplicate_drag() -> void:
	var pending := get_pending_duplicates()
	var moved := false
	for vn in pending:
		var origin: Dictionary = _dup_origins[vn]
		if vn.midi_note_data.start_tick != origin.start_tick or vn.midi_note_data.note != origin.note:
			moved = true
			break
	if not moved:
		cancel_duplicate_drag()
		return

	# Resolve every target first: creating a clip in track mode is its own undo step,
	# and the note snapshots must be taken after it exists.
	var targets: Array = []  # [MidiNoteData copy, ClipInstance or null, Clip]
	for vn in pending:
		var nd: MidiNoteData = vn.midi_note_data
		if multi_clip_mode:
			var ci := get_or_create_clip_at_position(nd.start_tick)
			if ci and ci.clip:
				targets.append([nd, ci, ci.clip])
		elif clip:
			targets.append([nd, clip_instance, clip])

	var clips: Array = []
	for t in targets:
		if t[2] not in clips:
			clips.append(t[2])
	_history_begin_clips(clips)

	var added: Array = []  # [MidiNoteData, ClipInstance]
	for t in targets:
		var nd: MidiNoteData = t[0]
		var ci: ClipInstance = t[1]
		var target_clip: Clip = t[2]
		# Dropped on a loop repeat, the copy lands in the loop region.
		var local := ci.song_to_played_content_ticks(nd.start_tick) if multi_clip_mode else nd.start_tick
		local = maxi(0, local)
		target_clip.cut_overlapping_notes_at_pitch(nd.note, local, local + nd.duration_ticks, target_clip.allocate_note_id)
		var new_note := target_clip.add_midi_note(target_clip.allocate_note_id(), nd.note, nd.velocity, local, nd.duration_ticks, nd.release)
		if new_note:
			added.append([new_note, ci, nd.start_tick])

	cancel_duplicate_drag()

	var new_visuals: Array[VisualNote] = []
	for entry in added:
		var vn: VisualNote = visual_at_song_tick(entry[1], entry[0], entry[2]) if multi_clip_mode else visual_for(clip_instance, entry[0])
		if vn and vn not in new_visuals:
			new_visuals.append(vn)
	selection_manager.select_all(new_visuals)
	_history_commit("Duplicate Notes")
	update_container_width()
	logger.info("Ctrl+drag duplicated %d note(s)" % added.size())


## Drop the pending duplicates without touching any clip.
func cancel_duplicate_drag() -> void:
	for vn in get_pending_duplicates():
		remove_child(vn)
		vn.queue_free()
	_dup_origins.clear()
	dup_anchor = null
	if interaction_mode == InteractionMode.DUPLICATING:
		interaction_mode = InteractionMode.NONE


# ============================================================================
# CROSS-CLIP NOTE MOVEMENT (MULTI-CLIP MODE)
# ============================================================================
func _handle_cross_clip_transfers() -> void:
	"""Transfer notes between clips if they moved to different clip regions."""
	if not multi_clip_mode:
		return

	# Iterate a copy: removing a note fires midi_note_removed, which erases entries
	# from selected_notes and would make this loop skip elements. Each note once.
	for sel_note in _selected_note_visuals():
		if not is_instance_valid(sel_note) or not sel_note.midi_note_data:
			continue
		# A note in a loop stays in its instance: the drag folded it into the loop region.
		var owner_ci := _instance_for_visual_note(sel_note)
		if owner_ci and owner_ci.loop_enabled and owner_ci.in_loop_region(sel_note.midi_note_data.start_tick):
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
		var source_clip_instance: ClipInstance = sel_note.clip_instance
		if not source_clip_instance:
			source_clip_instance = start_pos.get("clip_instance") as ClipInstance
		if not source_clip_instance or not source_clip_instance.clip:
			continue

		# Calculate song-relative position (note position + clip offset)
		var current_clip_instance = get_clip_instance_for_note(note_id)
		if not current_clip_instance:
			continue

		var song_position = current_clip_instance.clip_to_song_ticks(note_data.start_tick)

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
	var dest_local_position = dest.song_to_clip_ticks(song_position)

	# Create a copy of the note data for the destination clip
	var new_note = MidiNoteData.new()
	new_note.id = dest.clip.allocate_note_id()
	new_note.copy_values_from(note_data)
	new_note.start_tick = dest_local_position
	new_note.duration_ticks = note_data.duration_ticks

	# Clear the landing spot first. Without this the add below is rejected as an
	# overlap and the note would be dropped entirely.
	dest.clip.cut_overlapping_notes_at_pitch(
		new_note.note,
		new_note.start_tick,
		new_note.start_tick + new_note.duration_ticks,
		dest.clip.allocate_note_id
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


## One selected visual per selected note. A note selected through several visuals (loop
## repeats, instances of a linked clip) shares one MidiNoteData, so edits apply to it once.
func _selected_note_visuals() -> Array[VisualNote]:
	var seen := {}
	var out: Array[VisualNote] = []
	for vn in selection_manager.selected_notes:
		if is_instance_valid(vn) and vn.midi_note_data and not seen.has(vn.midi_note_data):
			seen[vn.midi_note_data] = true
			out.append(vn)
	return out


## Show the current data of the notes behind `visuals` on all their visuals (mid-gesture).
func _refresh_notes(visuals: Array[VisualNote]) -> void:
	for vn in visuals:
		if is_instance_valid(vn) and vn.midi_note_data:
			refresh_note(vn.midi_note_data, _clip_for_visual_note(vn))


## The instance a visual shows its note through (track mode), or the bound one (clip mode).
func _instance_for_visual_note(vn: VisualNote) -> ClipInstance:
	if not multi_clip_mode:
		return clip_instance
	var ci: ClipInstance = vn.clip_instance
	if ci == null and vn.midi_note_data:
		ci = get_clip_instance_for_note(vn.midi_note_data.id)
	return ci


## A visual is freed (its note or loop pass went away): nothing may keep using it.
func _forget_visual(vn: VisualNote) -> void:
	selection_manager.selected_notes.erase(vn)
	queue_redraw()
	if selection_manager.selected_note == vn:
		selection_manager.selected_note = selection_manager.selected_notes[0] if not selection_manager.selected_notes.is_empty() else null
	var fallback: VisualNote = null
	if vn.clip_instance and vn.midi_note_data:
		fallback = visual_for(vn.clip_instance, vn.midi_note_data)
	if dragging_note == vn:
		dragging_note = fallback
	if resizing_note == vn:
		resizing_note = fallback
	if placed_note_awaiting_drag == vn:
		placed_note_awaiting_drag = null
	if last_erased_note == vn:
		last_erased_note = null


## The clip a given visual note belongs to. Prefers the clip_instance stamped on the
## note itself, which is unambiguous even when several instances show the same id.
func _clip_for_visual_note(note: VisualNote) -> Clip:
	if not note or not note.midi_note_data:
		return null
	if not multi_clip_mode:
		return clip
	var ci: ClipInstance = note.clip_instance
	if ci and ci.clip:
		return ci.clip
	return _get_clip_for_note(note.midi_note_data.id)


func _get_clip_for_note(note_id: int) -> Clip:
	"""Get the clip that owns this note (works in both single and multi-clip modes)."""
	if not multi_clip_mode:
		return clip

	var clip_instance = get_clip_instance_for_note(note_id)
	if clip_instance:
		return clip_instance.clip
	return null


# ============================================================================
# GROUP LENGTH-SCALE HANDLE
# ============================================================================

const SCALE_HANDLE_SIZE := Vector2(18.0, 22.0)
## Space between the end of the last note and the handle.
const SCALE_HANDLE_GAP := 5.0
const SCALE_HANDLE_ICON := preload("res://assets/icons/move-horizontal.svg")
const SCALE_HANDLE_ICON_SIZE := 14.0

var _scale_notes: Array[MidiNoteData] = []
var _scale_visuals: Array[VisualNote] = []
var _scale_starts := PackedInt32Array()
var _scale_durations := PackedInt32Array()
var _scale_anchor := 0
var _scale_end := 0
var _scale_mouse_x := 0.0
var _scale_range := Vector2i.ZERO
var _scale_had_range := false
var _scale_loop_owners: Dictionary = {}


## The handle just past the end of the selection, in this editor's space; an empty Rect2 when
## there is none. Needs two or more selected notes of one clip, outside Drum View (hits have
## no length). Among the notes that end last it sits on the one nearest the middle of their
## pitch range.
func group_scale_handle_rect() -> Rect2:
	if layout.is_drum():
		return Rect2()
	var visuals := _selected_note_visuals()
	if visuals.size() < 2:
		return Rect2()
	var the_clip: Clip = _clip_for_visual_note(visuals[0])
	var right := -INF
	for vn in visuals:
		if _clip_for_visual_note(vn) != the_clip:
			return Rect2()
		right = maxf(right, vn.position.x + vn.size.x)
	var last_ending: Array[VisualNote] = []
	var lo := 127
	var hi := 0
	for vn in visuals:
		if vn.position.x + vn.size.x >= right - 0.5:
			last_ending.append(vn)
			lo = mini(lo, vn.midi_note_data.note)
			hi = maxi(hi, vn.midi_note_data.note)
	var pick: VisualNote = last_ending[0]
	for vn in last_ending:
		if absf(vn.midi_note_data.note - (lo + hi) * 0.5) < absf(pick.midi_note_data.note - (lo + hi) * 0.5):
			pick = vn
	var h := maxf(SCALE_HANDLE_SIZE.y, 0.0)
	return Rect2(right + SCALE_HANDLE_GAP, pick.position.y + pick.size.y * 0.5 - h * 0.5, SCALE_HANDLE_SIZE.x, h)


func is_over_group_scale_handle(pos: Vector2) -> bool:
	var r := group_scale_handle_rect()
	return r.size != Vector2.ZERO and r.grow(2.0).has_point(pos)


func _draw() -> void:
	var r := group_scale_handle_rect()
	if r.size == Vector2.ZERO:
		return
	var active := interaction_mode == InteractionMode.SCALING
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.12, 0.12, 0.14, 0.95) if not active else Color(0.3, 0.55, 0.85, 0.95)
	box.border_color = Color(1, 1, 1, 0.55)
	box.set_border_width_all(1)
	box.set_corner_radius_all(5)
	draw_style_box(box, r)
	var icon := Rect2(r.get_center() - Vector2.ONE * SCALE_HANDLE_ICON_SIZE * 0.5, Vector2.ONE * SCALE_HANDLE_ICON_SIZE)
	draw_texture_rect(SCALE_HANDLE_ICON, icon, false, Color(1, 1, 1, 0.95))


func _on_grid_scale_changed() -> void:
	super()
	queue_redraw()


func _on_layout_changed() -> void:
	super()
	queue_redraw()


## Start scaling the selected notes from the handle (grabbed at editor x `mouse_x`).
## Returns false when there is no handle.
func begin_group_scale(mouse_x: float = 0.0) -> bool:
	if group_scale_handle_rect().size == Vector2.ZERO:
		return false
	_scale_visuals = _selected_note_visuals()
	_scale_notes.clear()
	_scale_starts = PackedInt32Array()
	_scale_durations = PackedInt32Array()
	for vn in _scale_visuals:
		_scale_notes.append(vn.midi_note_data)
		_scale_starts.append(vn.midi_note_data.start_tick)
		_scale_durations.append(vn.midi_note_data.duration_ticks)
	var span := NoteTransforms.tick_bounds(_scale_notes)
	_scale_anchor = span.x
	_scale_end = span.y
	_scale_mouse_x = mouse_x
	_scale_loop_owners = _loop_owners()
	_scale_had_range = selection_manager.has_range() and not multi_clip_mode
	_scale_range = Vector2i(selection_manager.box_selection_start_tick, selection_manager.box_selection_end_tick)
	_history_begin_selection()
	interaction_mode = InteractionMode.SCALING
	queue_redraw()
	return true


## Preview with the group's end at `new_end` ticks. Always scales from the snapshot taken at
## the start, so many updates never accumulate rounding. The end stays past the anchor and no
## note shrinks below one tick.
func update_group_scale(new_end: int) -> void:
	if interaction_mode != InteractionMode.SCALING:
		return
	var span := _scale_end - _scale_anchor
	var min_factor := NoteTransforms.min_scale_factor(_scale_durations)
	new_end = maxi(new_end, _scale_anchor + ceili(span * min_factor))
	NoteTransforms.scale(_scale_notes, _scale_anchor, float(new_end - _scale_anchor) / float(span),
			_scale_starts, _scale_durations)
	_refresh_notes(_scale_visuals)
	queue_redraw()


## Same, from the mouse at editor position `pos`, snapped to the grid (Shift: free).
func update_group_scale_from_mouse(pos: Vector2) -> void:
	update_group_scale(_snap_unless_shift(_scale_end + pixels_to_ticks(pos.x - _scale_mouse_x)))


## Commit the preview as one undo step ("Scale Notes").
func end_group_scale() -> void:
	if interaction_mode != InteractionMode.SCALING:
		return
	interaction_mode = InteractionMode.NONE
	_fold_into_loops(_scale_notes, _scale_loop_owners)
	_refresh_notes(_scale_visuals)
	if _scale_had_range:
		var new_end := NoteTransforms.tick_bounds(_scale_notes).y
		var factor := float(new_end - _scale_anchor) / float(_scale_end - _scale_anchor)
		selection_manager.box_selection_start_tick = _scaled_tick(_scale_range.x, factor)
		selection_manager.box_selection_end_tick = _scaled_tick(_scale_range.y, factor)
		selection_manager.selection_changed.emit(selection_manager.selected_notes)
	_sync_edited_notes(_scale_visuals)
	_history_commit("Scale Notes")
	_scale_clear()


func _scaled_tick(tick: int, factor: float) -> int:
	return maxi(0, _scale_anchor + roundi((tick - _scale_anchor) * factor))


## Abort the gesture: notes go back to the snapshot and no undo step is recorded.
func cancel_group_scale() -> void:
	if interaction_mode != InteractionMode.SCALING:
		return
	interaction_mode = InteractionMode.NONE
	NoteTransforms.scale(_scale_notes, _scale_anchor, 1.0, _scale_starts, _scale_durations)
	_refresh_notes(_scale_visuals)
	_history_clip_snapshots.clear()
	_scale_clear()
	queue_redraw()


func _scale_clear() -> void:
	_scale_notes.clear()
	_scale_visuals.clear()
	_scale_loop_owners.clear()
	queue_redraw()
