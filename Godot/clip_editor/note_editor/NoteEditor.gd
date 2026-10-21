## Note editor with input handling and note interaction.
## Extends NoteContainer and uses NoteSelectionManager for selection operations.

class_name NoteEditor extends NoteContainer

## Emitted after `_gui_input` handled a key that changed the selection or note
## positions, so MidiEditor (which owns the range overlays) can refresh them.
signal key_input_handled

## A harmony hotkey asked for one of the option dialogs: &"harmonize", &"chords", &"bassline" or
## &"transfer". ClipEditor owns and opens the dialogs (spec 048).
signal harmony_dialog_requested(tool: StringName)

## Ctrl+Shift+A: select the notes of every editable track. MidiEditor owns that query.
signal select_all_tracks_requested

## The user touched a note (selected it alone, started dragging or resizing it): its values
## become the starting values of the next note drawn.
signal note_touched(note: MidiNoteData)

## Starting velocity and release of new notes. MidiEditor hands its shared instance down.
var next_values := NextNoteValues.new()

# Selection manager: box geometry and clipboard. The selected notes are in `selection_model`.
var selection_manager: NoteSelectionManager

## The selection this editor shows and edits. MidiEditor hands every editor its one model;
## a standalone editor keeps its own. Notes of the selection that this editor has no visual
## for (another track, or not bound) are simply not edited here.
var selection_model: NoteSelectionModel:
	get:
		return selection_manager.model

## The shared edit path (history, refresh, engine sync) over `selection_model`.
var edits: NoteEdits
## Drag, resize and velocity drag of the selection, on refs.
var gestures: NoteGestures

## Whether a note copied from a track may be pasted back onto it. MidiEditor sets this to its
## editable tracks; a standalone editor allows every track.
var paste_track_ok: Callable = func(_t: Track) -> bool: return true

## Notes whose visuals were last drawn as selected -> their clip.
var _lit: Dictionary = {}

# Interaction state
enum InteractionMode { NONE, DRAGGING, RESIZING, ERASING, PLACING_AND_DRAGGING, BOX_SELECTING, DUPLICATING, SCALING }
var interaction_mode: InteractionMode = InteractionMode.NONE


# Drag/resize state: NoteGestures keeps it (see `gestures`).
## The visual of the note being dragged, if this editor shows it.
var dragging_note: VisualNote:
	get:
		return gestures.grabbed_visual() if gestures.kind == NoteGestures.Kind.DRAG else null
## The visual of the note whose edge is being dragged, if this editor shows it.
var resizing_note: VisualNote:
	get:
		return gestures.grabbed_visual() if gestures.kind == NoteGestures.Kind.RESIZE else null

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

	# Provide the conversions between visuals and refs, and the coordinate conversion
	# callback. This lets the manager work in the correct coordinate space without tight coupling.
	selection_manager.get_note_song_position = get_note_song_position
	selection_manager.visual_of_ref = visual_of_ref
	selection_manager.ref_of_visual = ref_of_visual
	selection_manager.span_of_ref = span_of_ref
	_connect_selection_model(selection_manager.model)
	edits = NoteEdits.new(selection_manager.model)
	edits.editor = self
	gestures = NoteGestures.new(self)


## Use `model` as this editor's selection (MidiEditor shares one across its editors).
func use_selection_model(model: NoteSelectionModel) -> void:
	if model == null or model == selection_manager.model:
		return
	_disconnect_selection_model(selection_manager.model)
	selection_manager.model = model
	edits.model = model
	_lit.clear()
	_connect_selection_model(model)
	_sync_selected_look()


func _connect_selection_model(model: NoteSelectionModel) -> void:
	model.changed.connect(_on_selection_model_changed)
	model.set_changed.connect(_on_selection_model_set_changed)


func _disconnect_selection_model(model: NoteSelectionModel) -> void:
	model.changed.disconnect(_on_selection_model_changed)
	model.set_changed.disconnect(_on_selection_model_set_changed)


func _on_selection_model_changed() -> void:
	var model := selection_manager.model
	Hotkeys.set_condition("note_selection", not model.is_empty())
	Hotkeys.set_condition("note_range", model.has_range())
	if model.size() == 1:
		note_touched.emit(model.refs[0].data)
	queue_redraw()


func _on_selection_model_set_changed() -> void:
	_sync_selected_look()
	queue_redraw()


## Draw every visual of a selected note as selected (loop repeats and linked instances show
## the same note), and the visuals of notes that left the selection as not. O(selected).
func _sync_selected_look() -> void:
	var model := selection_manager.model
	for data in _lit.keys():
		if not model.has(data):
			_light(data, _lit[data], false)
			_lit.erase(data)
	for ref in model.refs:
		if not _lit.has(ref.data):
			_lit[ref.data] = ref.clip
			_light(ref.data, ref.clip, true)


func _light(data: MidiNoteData, source_clip: Clip, on: bool) -> void:
	for vn in _visuals_showing(data, source_clip):
		if is_instance_valid(vn) and vn.is_selected != on:
			vn.set_selected(on)


## Every visual of `data` here: its visual on each instance of `source_clip`, and their loop repeats.
func _visuals_showing(data: MidiNoteData, source_clip: Clip) -> Array[VisualNote]:
	if not multi_clip_mode:
		var only := visual_for(clip_instance, data)
		return [only] if only else ([] as Array[VisualNote])
	var out := _visuals_of(data, source_clip)
	for ci in _instances_of_clip(source_clip):
		out.append_array(_repeats_of(ci, data))
	return out


## Where `ref`'s note is in this editor's ticks (song ticks in track mode), whichever track it
## is on: {"start_tick", "end_tick"}.
func span_of_ref(ref: NoteRef) -> Dictionary:
	if multi_clip_mode:
		if ref.instance != null:
			return {"start_tick": ref.song_start(), "end_tick": ref.song_end()}
	else:
		var vn := visual_of_ref(ref)
		if vn != null:
			return get_note_song_position(vn)
	return {"start_tick": ref.data.start_tick, "end_tick": ref.data.start_tick + ref.data.duration_ticks}


## The ref that selects the note `vn` shows: its instance and loop pass.
func ref_of_visual(vn: VisualNote) -> NoteRef:
	if vn == null or vn.midi_note_data == null:
		return null
	return NoteRef.new(_instance_for_visual_note(vn), vn.midi_note_data, vn.repeat_pass)


## The visual that shows `ref` in this editor, or null (another track, a freed loop pass).
func visual_of_ref(ref: NoteRef) -> VisualNote:
	if ref.pass_index > 0 and multi_clip_mode:
		var nodes: Array = _repeats.get(_make_note_key(ref.instance, ref.data), [])
		var vn = nodes[ref.pass_index - 1] if ref.pass_index - 1 < nodes.size() else null
		return vn if vn != null and is_instance_valid(vn) else null
	return visual_for(ref.instance, ref.data)


# Override set_grid_helper to also update selection manager
func set_grid_helper(gh: GridHelper) -> void:
	super.set_grid_helper(gh)
	if selection_manager:
		selection_manager.grid_helper = gh


func unbind():
	# The pending duplicates are children and go with the rest; forget them too.
	_dup_origins.clear()
	_dup_context.clear()
	dup_anchor = null
	# Every note node goes away, so no gesture can carry on with one.
	_lit.clear()
	interaction_mode = InteractionMode.NONE
	gestures.abandon()
	placed_note_awaiting_drag = null
	last_erased_note = null
	erasing_mode = false
	super.unbind()


# ============================================================================
# UNDO HISTORY HELPERS
# ============================================================================

## The notes the edits act on: the whole selection, on any editable track.
func _edit_refs() -> Array[NoteRef]:
	var out: Array[NoteRef] = []
	out.assign(selection_model.refs)
	return out


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
	if gestures.is_active() and event.pressed and event.keycode == KEY_ESCAPE:
		# Esc mid-drag or mid-resize, on any track: every note goes back, no undo step.
		gestures.cancel()
		interaction_mode = InteractionMode.NONE
		accept_event()
		return
	if Hotkeys.pressed(event, "edit_select_all"):
		# Clip mode: every note in the clip. Track mode: every note on the active track
		# (the active editor is the one bound to it).
		selection_manager.select_all(get_all_visual_notes())
		accept_event()

	elif Hotkeys.pressed(event, "notes_select_all_tracks"):
		select_all_tracks_requested.emit()
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

	elif Hotkeys.pressed(event, "notes_invert_up"):
		invert_selection(true)
		accept_event()

	elif Hotkeys.pressed(event, "notes_invert_down"):
		invert_selection(false)
		accept_event()

	elif Hotkeys.pressed(event, "notes_select_voice_top"):
		select_voice(NoteVoices.TOP)
		accept_event()

	elif Hotkeys.pressed(event, "notes_select_voice_bottom"):
		select_voice(NoteVoices.BOTTOM)
		accept_event()

	elif Hotkeys.pressed(event, "notes_harmonize"):
		if can_harmonize():
			harmony_dialog_requested.emit(&"harmonize")
		accept_event()

	elif Hotkeys.pressed(event, "notes_insert_chords"):
		if can_insert_chords():
			harmony_dialog_requested.emit(&"chords")
		accept_event()

	elif Hotkeys.pressed(event, "notes_insert_bassline"):
		if can_insert_bassline():
			harmony_dialog_requested.emit(&"bassline")
		accept_event()

	elif Hotkeys.pressed(event, "notes_transfer"):
		if can_transfer():
			harmony_dialog_requested.emit(&"transfer")
		accept_event()

	elif Hotkeys.pressed(event, "notes_split_voices"):
		split_voices()
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

	# Snap to the nearest grid line (not the one before the cursor), in both views.
	if grid_helper:
		tick_position = grid_helper.snap_ticks(tick_position)

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

	edits.begin_clips([target_clip])
	# Cut overlapping notes
	var affected_notes = target_clip.cut_overlapping_notes_at_pitch(midi_note_num, tick_position, end_tick, target_clip.allocate_note_id)

	if not affected_notes.is_empty():
		logger.info("Cut/merged %d overlapping notes" % affected_notes.size())

	var note_id: int = target_clip.allocate_note_id()

	# Add note to clip
	var note_data = target_clip.add_midi_note(note_id, midi_note_num, next_values.velocity, tick_position, new_note_length, next_values.release)
	if note_data == null:
		push_error("[NoteEditor] Failed to add note after cutting overlaps")
		edits.discard()
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
	edits.commit("Place Note")
	# Placement can leave the selection range at the note's span, but only when the
	# user asked for it (default: off, so placing doesn't move the range).
	var with_range := _placement_sets_range()
	selection_manager.select_note(note_instance, with_range)
	if not with_range and saved_range != Vector2i.ZERO:
		selection_manager.box_selection_start_tick = saved_range.x
		selection_manager.box_selection_end_tick = saved_range.y
		selection_model.changed.emit()
	queue_redraw()

	# Wait for drag to start
	placed_note_awaiting_drag = note_instance
	placed_note_mouse_pos = get_global_mouse_position()

	return note_instance


# ============================================================================
# NOTE INTERACTION HANDLERS
# ============================================================================
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


## The VisualNote-facing entry points of the gestures (MidiEditor and tests hand over the visual
## the mouse is on); NoteGestures works on its ref.
func _on_drag_started(note: VisualNote, click_position: Vector2) -> void:
	gestures.begin_drag(ref_of_visual(note), click_position)


func _on_drag_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	if gestures.grabbed != null and gestures.grabbed.data == note.midi_note_data:
		gestures.update_drag(mouse_pos_local)


func _on_drag_ended(note: VisualNote) -> void:
	if gestures.grabbed != null and gestures.grabbed.data == note.midi_note_data:
		gestures.end_drag()


func _on_resize_started(note: VisualNote, click_position: Vector2) -> void:
	gestures.begin_resize(ref_of_visual(note), click_position)


func _on_resize_updated(note: VisualNote, mouse_pos_local: Vector2) -> void:
	if gestures.grabbed != null and gestures.grabbed.data == note.midi_note_data:
		gestures.update_resize(mouse_pos_local)


func _on_resize_ended(note: VisualNote) -> void:
	if gestures.grabbed != null and gestures.grabbed.data == note.midi_note_data:
		gestures.end_resize()


func _start_place_and_drag(note: VisualNote) -> void:
	"""Start dragging a newly placed note."""
	if not note or not note.midi_note_data:
		return
	interaction_mode = InteractionMode.PLACING_AND_DRAGGING
	note.set_selected(true)
	# The placement is already one undo step; the drag after it is not recorded on its own.
	gestures.begin_drag(ref_of_visual(note), get_local_mouse_position(), false)
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
		edits.begin_clips([note_clip])
		note_clip.remove_midi_note(note.midi_note_data)
		edits.commit("Erase Note")


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
	if selection_model.is_empty():
		logger.warn("No notes selected to cut")
		return

	selection_manager.copy_selection()
	_delete_selection()

	logger.info("Cut %d notes" % selection_manager.clipboard.notes.size())


## Ctrl+C: the selected notes over the selection range. With nothing selected and no range,
## the edited clips instead: their notes are selected and the range becomes their span, so
## the range can carry over to another track and the paste lands at the same position.
func copy_to_clipboard() -> void:
	if selection_model.is_empty() and not selection_manager.has_range():
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
	selection_manager.select_visuals(notes)
	selection_manager.box_selection_start_tick = start_tick
	selection_manager.box_selection_end_tick = end_tick
	selection_model.changed.emit()
	return true


## Where Ctrl+V lands: the range start when a range is set with no notes selected (a range
## carried over from another track, or a ruler range over empty space), else the cursor.
## With notes selected the range is theirs, and pasting onto them would only replace them.
func get_paste_tick() -> int:
	if not has_selection_here() and selection_manager.has_range():
		return selection_manager.box_selection_start_tick
	return cursor_position_ticks


## True when a selected note is one this editor shows. Notes selected on other tracks do not
## count: pasting here would not replace them.
func has_selection_here() -> bool:
	for ref in selection_model.refs:
		if visual_of_ref(ref) != null:
			return true
	return false


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
	# A copy from several tracks goes back to each note's own track (the focus track when that
	# one is gone or not editable); a copy from one track goes to the focus track.
	var per_track := multi_clip_mode and source.spans_tracks()
	var pasted_notes_list := source.get_notes_at_position(tick_position)
	for i in pasted_notes_list.size():
		var note_data := pasted_notes_list[i]
		var target_clip: Clip = clip
		var ci: ClipInstance = null
		var song_tick := note_data.start_tick
		if multi_clip_mode:
			var dest_track: Track = track
			if per_track:
				var wanted: Track = source.source_tracks[i] if i < source.source_tracks.size() else null
				if wanted != null and paste_track_ok.call(wanted):
					dest_track = wanted
			if dest_track == track:
				ci = get_or_create_clip_at_position(note_data.start_tick, span_end)
			else:
				ci = TrackClips.get_or_create(dest_track, note_data.start_tick,
					grid_helper.get_ticks_per_bar() if grid_helper else 3840, span_end)
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

	edits.begin_clips(target_clips)
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

	# Select newly pasted notes: on the focus track the visuals where they were pasted (a loop
	# repeat, or the instance the paste landed on); notes pasted onto another track by the
	# instance they went into.
	var pasted_notes: Array = []
	for target in pasted:
		var note_data: MidiNoteData = target[0]
		if multi_clip_mode and target[2] and target[2].track != track:
			pasted_notes.append(NoteRef.new(target[2], note_data, 0))
			continue
		var note_instance: VisualNote = visual_at_song_tick(target[2], note_data, target[3]) if target[2] else get_visual_note(note_data.id)
		if note_instance and note_instance not in pasted_notes:
			pasted_notes.append(note_instance)

	selection_manager.select_visuals(pasted_notes)

	# Set selection range
	if not selection_model.is_empty():
		selection_manager.box_selection_start_tick = tick_position
		selection_manager.box_selection_end_tick = span_end
		queue_redraw()

	selection_model.changed.emit()

	logger.info("Pasted %d notes at tick %d (range: %d-%d)" % [
		pasted.size(), tick_position, selection_manager.box_selection_start_tick, selection_manager.box_selection_end_tick
	])
	edits.commit("Paste Notes")


func _duplicate_selection() -> void:
	"""Duplicate selected notes immediately after the selection."""
	edits.begin()
	if selection_model.is_empty():
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
	edits.commit("Duplicate Notes")


func _delete_selection() -> void:
	"""Delete all selected notes."""
	var refs := _edit_refs()
	if refs.is_empty():
		logger.warn("No notes selected to delete")
		return
	edits.begin()

	# Each note once: removing it frees all its visuals and drops it from the selection.
	for ref in refs:
		if ref.clip:
			ref.clip.remove_midi_note(ref.data)

	selection_manager.select_visuals([])
	selection_model.changed.emit()

	update_container_width()

	logger.info("Deleted %d notes" % refs.size())
	edits.commit("Delete Notes")


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
	var refs := _edit_refs()
	if refs.is_empty():
		return
	edits.begin()

	# Move all selected notes. Linked clip instances and loop repeats show the same
	# MidiNoteData through several visuals, so step each note once.
	for ref in refs:
		ref.data.note = step.call(ref.data.note)
	edits.refresh(refs)

	# Process overlaps and sync
	edits.sync(refs)

	logger.info("Moved %d note(s) vertically" % refs.size())
	update_container_width()
	edits.commit("Transpose Notes")


func _move_selection_horizontal(delta_ticks: int) -> void:
	"""Move all selected notes left or right by ticks."""
	var refs := _edit_refs()
	if refs.is_empty():
		return
	edits.begin()

	# Move all selected notes (each shared MidiNoteData once; see _move_selection_vertical)
	for ref in refs:
		var note_data := ref.data
		var owner_ci := ref.instance if multi_clip_mode else null
		if owner_ci and owner_ci.in_loop_region(note_data.start_tick):
			# Stays in the loop, like a drag (the next pass shows it past the loop end).
			note_data.start_tick = owner_ci.fold_into_loop(note_data.start_tick + delta_ticks)
		else:
			note_data.start_tick = maxi(0, note_data.start_tick + delta_ticks)
	edits.refresh(refs)

	# Process overlaps and sync
	edits.sync(refs)

	logger.info("Moved %d note(s) %+d ticks" % [refs.size(), delta_ticks])

	# The selection range goes with the notes (it stops at tick 0).
	if selection_manager.has_range():
		var range_delta := maxi(delta_ticks, -selection_manager.box_selection_start_tick)
		selection_manager.box_selection_start_tick += range_delta
		selection_manager.box_selection_end_tick += range_delta
		selection_model.changed.emit()
	queue_redraw()
	update_container_width()
	edits.commit("Nudge Notes")


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
	selection_model.changed.emit()


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
##
## Spec 048: `edit` may return a Dictionary { Clip: Array[MidiNoteData] } of NEW notes (id -1,
## clip ticks) to add to those clips. They are added after the sync (same-pitch overlaps at their
## place are cut first), join the selection, and are part of the same undo step. `extra_clips`
## are clips that gain notes but own no selected note: they are snapshotted too, and the edit then
## also runs with nothing selected. Returns the number of notes added.
func _apply_selection_edit(history_name: String, edit: Callable, extra_clips: Array = []) -> int:
	var refs := _edit_refs()
	if refs.is_empty() and extra_clips.is_empty():
		return 0
	edits.begin(extra_clips)
	var notes: Array[MidiNoteData] = []
	for ref in refs:
		notes.append(ref.data)
	var result = edit.call(notes)
	edits.refresh(refs)
	edits.sync(refs)
	update_container_width()
	queue_redraw()
	var added := 0
	if result is Dictionary:
		added = _add_generated_notes(result)
	edits.commit(history_name)
	return added


## Add the generated notes of an edit (see _apply_selection_edit) to their clips and put them
## into the selection. Returns how many were added.
func _add_generated_notes(by_clip: Dictionary) -> int:
	var added := 0
	var new_refs: Array[NoteRef] = []
	for target_clip: Clip in by_clip.keys():
		if target_clip == null:
			continue
		for generated: MidiNoteData in by_clip[target_clip]:
			target_clip.cut_overlapping_notes_at_pitch(
				generated.note, generated.start_tick,
				generated.start_tick + generated.duration_ticks,
				target_clip.allocate_note_id)
			generated.id = target_clip.allocate_note_id()
			var live := target_clip.add_midi_note_data(generated)
			if live == null:
				continue
			added += 1
			var through := _instance_for_clip(target_clip)
			if through != null:
				new_refs.append(NoteRef.new(through, live, 0))
	if added > 0:
		var keep: Array[NoteRef] = []
		keep.append_array(selection_model.refs)
		keep.append_array(new_refs)
		selection_model.select(keep, true)
		selection_model.changed.emit()
		update_container_width()
		queue_redraw()
	return added


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
	for ref in selection_model.refs:
		var owner_ci := ref.instance
		if owner_ci and owner_ci.in_loop_region(ref.data.start_tick):
			owners[ref.data] = owner_ci
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
	for ref in selection_model.refs:
		clip_of[ref.data] = ref.clip
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


# ============================================================================
# MUSICAL NOTE TOOLS (spec 048)
# ============================================================================

const HARMONIZE_INTERVALS_KEY := "clip_editor/harmonize_intervals"
const HARMONIZE_VELOCITY_KEY := "clip_editor/harmonize_velocity_offset"
const CHORDS_PROGRESSION_KEY := "clip_editor/chords_progression"
const CHORDS_LENGTH_KEY := "clip_editor/chords_length_ticks"
const CHORDS_COUNT_KEY := "clip_editor/chords_count"
const CHORDS_RANGE_KEY := "clip_editor/chords_range"
const CHORDS_VOICING_KEY := "clip_editor/chords_voicing"
const CHORDS_INVERSION_KEY := "clip_editor/chords_inversion"
const CHORDS_SEVENTH_KEY := "clip_editor/chords_seventh_default"
const BASSLINE_PATTERN_KEY := "clip_editor/bassline_pattern"
const BASSLINE_RANGE_KEY := "clip_editor/bassline_range"
const TRANSFER_TARGET_KEY := "clip_editor/transfer_last_target"

## True after the last insert_chords() run had to move notes by octaves to fit the range
## (the dialog shows a notice, REQ-034).
var last_chords_clamped := false
## The parse error of the last insert_chords() run ("" when there was none).
var last_chords_error := ""


## Remembered Harmonize intervals: signed scale-step counts (HarmonyGenerators.THIRD .. OCTAVE).
static func harmonize_steps() -> Array[int]:
	var out: Array[int] = []
	var raw: Variant = _config_value(HARMONIZE_INTERVALS_KEY, [HarmonyGenerators.THIRD])
	if raw is Array:
		for v in raw:
			out.append(int(v))
	if out.is_empty():
		out.append(HarmonyGenerators.THIRD)
	return out


## Remembered Harmonize velocity offset (normalized, -1..1).
static func harmonize_velocity_offset() -> float:
	return clampf(float(_config_value(HARMONIZE_VELOCITY_KEY, 0.0)), -1.0, 1.0)


static func _config_range(key: String, default: Vector2i) -> Vector2i:
	var raw: Variant = _config_value(key, [default.x, default.y])
	if raw is Array and raw.size() >= 2:
		var lo := clampi(int(raw[0]), 0, 127)
		var hi := clampi(int(raw[1]), 0, 127)
		return Vector2i(mini(lo, hi), maxi(lo, hi))
	return default


## Remembered Insert Chords options, in the form HarmonyGenerators.chords takes (plus
## `seventh_default`, which the dialog uses when it fills in a progression).
static func chords_options() -> Dictionary:
	var voicing := ChordTheory.Voicing.SPREAD if str(_config_value(CHORDS_VOICING_KEY, "close")) == "spread" \
			else ChordTheory.Voicing.CLOSE
	return {
		"progression": str(_config_value(CHORDS_PROGRESSION_KEY, "I V vi IV")),
		"length_ticks": maxi(1, int(_config_value(CHORDS_LENGTH_KEY, 3840))),
		"count": maxi(1, int(_config_value(CHORDS_COUNT_KEY, 4))),
		"range": _config_range(CHORDS_RANGE_KEY, Vector2i(48, 72)),
		"voicing": voicing,
		"inversion": "smooth" if str(_config_value(CHORDS_INVERSION_KEY, "root")) == "smooth" else "root",
		"seventh_default": bool(_config_value(CHORDS_SEVENTH_KEY, false)),
	}


static func bassline_pattern() -> HarmonyGenerators.Pattern:
	match str(_config_value(BASSLINE_PATTERN_KEY, "sustained")):
		"pulse":
			return HarmonyGenerators.Pattern.PULSE
		"root_fifth":
			return HarmonyGenerators.Pattern.ROOT_FIFTH
	return HarmonyGenerators.Pattern.SUSTAINED


static func bassline_range() -> Vector2i:
	return _config_range(BASSLINE_RANGE_KEY, Vector2i(36, 48))


## Remember `value` under `key` and save the config (the harmony dialogs call this on OK).
static func store_config(key: String, value: Variant) -> void:
	var sonara := _sonara_node()
	if sonara:
		sonara.set_config(key, value)
		sonara.save_config()


## The Sonara autoload by node lookup (see _config_value).
static func _sonara_node() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Sonara")


## The track whose notes this editor shows.
func source_track() -> Track:
	if multi_clip_mode:
		return track
	return clip_instance.track if clip_instance else null


func _project_of_editor() -> Project:
	var source := source_track()
	var project: Project = source.get_project_ref() if source else null
	if project == null:
		var sonara := _sonara_node()
		var editor: Object = sonara.get("editor") if sonara else null
		project = editor.get("project") if editor else null
	return project


## The first shown instance of `c`, whose position maps its clip ticks to the song.
func _instance_for_clip(c: Clip) -> ClipInstance:
	if not multi_clip_mode:
		return clip_instance if clip_instance and clip_instance.clip == c else null
	var list := _instances_of_clip(c)
	if not list.is_empty():
		return list[0]
	# A clip of another track: the instance the selection reaches it through.
	for ref in selection_model.refs:
		if ref.clip == c:
			return ref.instance
	return null


## The key in effect at clip tick `tick` of `c`: clip tick -> song tick -> Project key changes
## (REQ-003). Falls back to the editor's scale context when no project is reachable.
func _scale_at_clip_tick(c: Clip, tick: int) -> MusicalScale:
	var project := _project_of_editor()
	var ci := _instance_for_clip(c)
	if project and ci:
		return project.get_scale_at_tick(ci.clip_to_song_ticks(tick))
	return scale_context.scale


# --- Predicates for the toolbar (Phase 3) ---

## True when Insert Chords will fill a selection range (the Count option is then unused).
func chords_use_range() -> bool:
	return not layout.is_drum() and selection_manager.has_range()


func has_note_selection() -> bool:
	return not selection_model.is_empty()


## A key is set for the edited clip (the scale tools need one, REQ-002). Always false in Drum View.
func has_scale() -> bool:
	return not layout.is_drum() and not scale_context.scale.is_none()


func can_select_voices() -> bool:
	return not layout.is_drum() and not get_all_visual_notes().is_empty()


func can_invert() -> bool:
	return not layout.is_drum() and has_note_selection()


func can_harmonize() -> bool:
	return has_scale() and has_note_selection()


func can_insert_bassline() -> bool:
	return has_scale() and has_note_selection()


## Chords need a key and a clip to land in (in track mode the instance at the insert position).
func can_insert_chords() -> bool:
	return has_scale() and not _chords_target().is_empty()


## Transfer Notes needs a selection and a track to move them off.
func can_transfer() -> bool:
	return not layout.is_drum() and has_note_selection() and source_track() != null \
			and not selection_spans_tracks()


## True when the selected notes sit on more than one track. Transfer Notes and Split Voices work
## from a single source track, so they are off then.
func selection_spans_tracks() -> bool:
	return selection_model.tracks().size() > 1


## Split Voices needs notes (selected, or any in the edited clips) and a target track.
func can_split_voices(selected_tracks: Array = []) -> bool:
	return not layout.is_drum() and not get_all_visual_notes().is_empty() and has_split_targets(selected_tracks) \
			and not selection_spans_tracks()


## True when `candidate` can receive transferred notes: an instrument track other than the source.
func is_transfer_target(candidate: Track) -> bool:
	return candidate != null and candidate != source_track() and candidate.type == Track.TrackType.INSTRUMENT


## Split targets: the selected instrument tracks in project track order. The source track is in
## the list (keeping its place) when it is selected. `selected_tracks` empty means the app's
## track selection (Editor.selected_tracks).
func split_target_tracks(selected_tracks: Array = []) -> Array[Track]:
	var picked: Array = selected_tracks
	if picked.is_empty():
		var sonara := _sonara_node()
		var editor: Object = sonara.get("editor") if sonara else null
		var from_app: Variant = editor.get("selected_tracks") if editor else null
		picked = from_app if from_app is Array else []
	var project := _project_of_editor()
	var out: Array[Track] = []
	if project:
		for t in project.tracks:
			if t in picked and t.type == Track.TrackType.INSTRUMENT:
				out.append(t)
	else:
		for t in picked:
			if t is Track and t.type == Track.TrackType.INSTRUMENT:
				out.append(t)
	return out


## REQ-042: at least one selected instrument track that is not the source track.
func has_split_targets(selected_tracks: Array = []) -> bool:
	var source := source_track()
	for t in split_target_tracks(selected_tracks):
		if t != source:
			return true
	return false


# --- Helpers ---

## Selected notes per clip: { Clip: Array[MidiNoteData] }, each shared note once.
func _selected_notes_by_clip() -> Dictionary:
	return _notes_by_clip(selection_model.refs)


func _notes_by_clip(refs: Array) -> Dictionary:
	var out := {}
	for ref: NoteRef in refs:
		var c := ref.clip
		if c == null:
			continue
		if not out.has(c):
			var typed: Array[MidiNoteData] = []
			out[c] = typed
		out[c].append(ref.data)
	return out


## The notes a voice tool works on: the selected notes, or every shown note of this editor
## (one ref each) when nothing is selected.
func _voice_pool() -> Array[NoteRef]:
	var pool: Array[NoteRef] = []
	pool.assign(selection_model.refs)
	if pool.is_empty():
		var seen := {}
		for vn in get_all_visual_notes():
			if not seen.has(vn.midi_note_data):
				seen[vn.midi_note_data] = true
				pool.append(ref_of_visual(vn))
	return pool


## { MidiNoteData: NoteRef } among `refs`.
static func _ref_per_note(refs: Array) -> Dictionary:
	var out := {}
	for ref: NoteRef in refs:
		out[ref.data] = ref
	return out


# --- Select Voices, Chord Inversion (REQ-020, REQ-021) ---

## Replace the selection with one voice of the chords: NoteVoices.TOP, NoteVoices.BOTTOM or N >= 1
## counted from the top. The candidates are the selected notes, or all notes of the edited
## clip(s) when nothing is selected. A selection change only: no undo step. Returns the number of
## notes selected.
func select_voice(which: int) -> int:
	if layout.is_drum():
		return 0
	var pool := _voice_pool()
	var ref_of := _ref_per_note(pool)
	var chosen: Array[NoteRef] = []
	var per_clip := _notes_by_clip(pool)
	for c in per_clip.keys():
		for nd in NoteVoices.select(per_clip[c], which):
			chosen.append(ref_of[nd])
	selection_manager.select_refs(chosen)
	selection_model.changed.emit()
	queue_redraw()
	return chosen.size()


## Invert every chord among the selected notes: up moves the lowest note up by octaves past the
## chord's highest, down mirrors that. One undo step; chords are found per clip.
func invert_selection(up: bool) -> void:
	if layout.is_drum():
		return
	var clip_of := {}
	for ref in selection_model.refs:
		clip_of[ref.data] = ref.clip
	_apply_selection_edit("Chord Inversion Up" if up else "Chord Inversion Down", func(notes: Array[MidiNoteData]):
		var per_clip := {}
		for note_data in notes:
			var c: Clip = clip_of.get(note_data)
			if not per_clip.has(c):
				var typed: Array[MidiNoteData] = []
				per_clip[c] = typed
			per_clip[c].append(note_data)
		for clip_notes: Array[MidiNoteData] in per_clip.values():
			NoteVoices.invert(clip_notes, up))


# --- Harmonize, Insert Chords, Insert Bassline (REQ-030..035) ---

## Add scale-step copies of the selected notes. `steps` are signed scale-step counts
## (HarmonyGenerators.THIRD .. OCTAVE; empty = the remembered ones), `velocity_offset` NAN = the
## remembered one. Needs a scale (has_scale). One undo step; the copies join the selection.
## Returns the number of notes added.
func harmonize_selection(steps: Array = [], velocity_offset: float = NAN) -> int:
	if not can_harmonize():
		return 0
	var use_steps: Array[int] = []
	for s in steps:
		use_steps.append(int(s))
	if use_steps.is_empty():
		use_steps = harmonize_steps()
	var use_offset := harmonize_velocity_offset() if is_nan(velocity_offset) else velocity_offset
	var groups := _selected_notes_by_clip()
	return _apply_selection_edit("Harmonize", func(_notes: Array[MidiNoteData]):
		var generated := {}
		for c: Clip in groups.keys():
			var picked: Array[MidiNoteData] = groups[c]
			var in_picked := {}
			for nd in picked:
				in_picked[nd] = true
			var others: Array[MidiNoteData] = []
			for nd in c.midi_notes:
				if not in_picked.has(nd):
					others.append(nd)
			var scale_at := func(tick: int) -> MusicalScale: return _scale_at_clip_tick(c, tick)
			var made := HarmonyGenerators.harmonize(picked, use_steps, scale_at, use_offset, others)
			if not made.is_empty():
				generated[c] = made
		return generated)


## Where Insert Chords writes: { "instance": ClipInstance, "start": clip tick, "end": clip tick
## or -1, "ranged": bool }, or {} when there is no clip to write into. With a selection range the
## chords fill it; otherwise they start at get_paste_tick(). In track mode the instance playing
## at the start is used (no clip is created) and a range is cut at its end.
func _chords_target() -> Dictionary:
	if layout.is_drum():
		return {}
	var ranged := selection_manager.has_range()
	var start_tick := selection_manager.box_selection_start_tick if ranged else get_paste_tick()
	var end_tick := selection_manager.box_selection_end_tick if ranged else -1
	var ci: ClipInstance = get_clip_at_position(start_tick) if multi_clip_mode else clip_instance
	if ci == null or ci.clip == null:
		return {}
	if multi_clip_mode:
		# Editor ticks are song ticks here; the generators work in clip ticks.
		if end_tick >= 0:
			end_tick = mini(end_tick, ci.get_end_ticks())
		var clip_start := ci.song_to_played_content_ticks(start_tick)
		if end_tick >= 0:
			end_tick = clip_start + (end_tick - start_tick)
		start_tick = clip_start
	if ranged and end_tick <= start_tick:
		return {}
	return {"instance": ci, "start": start_tick, "end": end_tick, "ranged": ranged}


## Insert a chord progression: filling the selection range, or `opts.count` chords from the
## paste position. `opts` overrides the remembered options (see chords_options). Needs a scale.
## One undo step; the chords join the selection. Returns the number of notes added. A parse error
## adds nothing and is left in `last_chords_error`; `last_chords_clamped` reports octave folding.
func insert_chords(opts: Dictionary = {}) -> int:
	last_chords_clamped = false
	last_chords_error = ""
	if not has_scale():
		return 0
	var target := _chords_target()
	if target.is_empty():
		return 0
	var use := chords_options()
	use.merge(opts, true)
	var ci: ClipInstance = target.instance
	var target_clip: Clip = ci.clip
	var scale_at := func(tick: int) -> MusicalScale: return _scale_at_clip_tick(target_clip, tick)
	var result := HarmonyGenerators.chords(use, scale_at, target.start, target.end)
	last_chords_error = result.error
	last_chords_clamped = result.clamped
	if result.error != "" or result.notes.is_empty():
		return 0
	return _apply_selection_edit("Insert Chords", func(_notes: Array[MidiNoteData]):
		return {target_clip: result.notes}, [target_clip])


## Add a bass note pattern under every chord (2+ notes) of the selected notes. `pattern` is a
## HarmonyGenerators.Pattern (-1 = the remembered one), `bass_range` Vector2i(lo, hi) (default =
## the remembered one). Pulse and Root-Fifth step by the current grid value. Needs a scale. One
## undo step; the bass notes join the selection. Returns the number of notes added.
func insert_bassline(pattern: int = -1, bass_range: Vector2i = Vector2i(-1, -1)) -> int:
	if not can_insert_bassline():
		return 0
	var use_pattern: HarmonyGenerators.Pattern = bassline_pattern() if pattern < 0 \
			else pattern as HarmonyGenerators.Pattern
	var use_range := bassline_range() if bass_range.x < 0 else bass_range
	var grid_ticks := grid_helper.get_snap_interval() if grid_helper else 240
	var groups := _selected_notes_by_clip()
	return _apply_selection_edit("Insert Bassline", func(_notes: Array[MidiNoteData]):
		var generated := {}
		for c: Clip in groups.keys():
			var scale_at := func(tick: int) -> MusicalScale: return _scale_at_clip_tick(c, tick)
			var made := HarmonyGenerators.bassline(groups[c], use_pattern, use_range, grid_ticks, scale_at)
			if not made.is_empty():
				generated[c] = made
		return generated)


# --- Transfer Notes, Split Voices (REQ-040..043) ---

## Copies of `candidates`' notes with SONG-tick starts:
## { "moves": { Clip: [MidiNoteData originals] }, "notes": { original: song-tick copy } }.
func _song_copies(candidates: Array) -> Dictionary:
	var moves := {}
	var copies := {}
	for ref: NoteRef in candidates:
		var ci := ref.instance
		var c := ref.clip
		if ci == null or c == null or copies.has(ref.data):
			continue
		var copy := ref.data.duplicate_note()
		copy.start_tick = ci.clip_to_song_ticks(ref.data.start_tick)
		copies[ref.data] = copy
		if not moves.has(c):
			moves[c] = []
		moves[c].append(ref.data)
	return {"moves": moves, "notes": copies}


## The plan Transfer Notes would run for the selected notes (NoteTransfer.plan entries), so a
## dialog can preview it. Empty when nothing can be transferred.
func plan_transfer(target: Track) -> Array:
	var project := _project_of_editor()
	if project == null or not is_transfer_target(target) or layout.is_drum():
		return []
	var copies: Dictionary = _song_copies(selection_model.refs).notes
	return NoteTransfer.plan(project, target, copies.values())


## Clips of `target` that the transfer would write into and that other instances share
## (REQ-043: the notes show in every linked instance; the dialog warns about it).
func transfer_linked_clips(target: Track) -> Array:
	var project := _project_of_editor()
	if project == null:
		return []
	return NoteTransfer.linked_targets(project, plan_transfer(target))


## Move the selected notes to `target` (an instrument track other than the source) at the same
## song positions, into existing clips (extending them to whole bars) or new ones (NoteTransfer).
## One undo step. Returns the number of notes moved.
func transfer_selection(target: Track) -> int:
	if not can_transfer() or not is_transfer_target(target):
		return 0
	var copies := _song_copies(selection_model.refs)
	return _run_transfer("Transfer Notes", copies.moves, {target: copies.notes.values()})


## Spread the voices of the selected notes (or of all notes when nothing is selected) over the
## split targets: voice k (counted from the top, per clip) goes to the k-th target; voices without
## a target, or whose target is the source track, stay. One undo step. Returns the number of
## notes moved to other tracks.
func split_voices(selected_tracks: Array = []) -> int:
	if layout.is_drum() or not has_split_targets(selected_tracks) or selection_spans_tracks():
		return 0
	var targets := split_target_tracks(selected_tracks)
	var source := source_track()
	var pool := _voice_pool()
	var ref_of := _ref_per_note(pool)
	var per_clip := _notes_by_clip(pool)
	var leaving: Dictionary = {}  # Track -> Array[NoteRef]
	for c in per_clip.keys():
		var ranks := NoteVoices.ranks(per_clip[c])
		for nd: MidiNoteData in per_clip[c]:
			var voice: int = ranks[nd].x
			if voice > targets.size() or targets[voice - 1] == source:
				continue
			var dest: Track = targets[voice - 1]
			if not leaving.has(dest):
				var typed: Array[NoteRef] = []
				leaving[dest] = typed
			leaving[dest].append(ref_of[nd])
	if leaving.is_empty():
		return 0
	var moves := {}
	var per_target := {}
	for dest: Track in leaving.keys():
		var copies := _song_copies(leaving[dest])
		for c in copies.moves.keys():
			if not moves.has(c):
				moves[c] = []
			moves[c].append_array(copies.moves[c])
		per_target[dest] = copies.notes.values()
	return _run_transfer("Split Voices", moves, per_target)


## Plan every target, apply it and record ONE undo step that also restores the selection.
## `per_target`: { Track: Array of song-tick notes }. Returns the number of notes moved.
func _run_transfer(label: String, source_moves: Dictionary, per_target: Dictionary) -> int:
	var project := _project_of_editor()
	if project == null:
		return 0
	var plans: Array = []
	var count := 0
	for dest: Track in per_target.keys():
		var entries := NoteTransfer.plan(project, dest, per_target[dest])
		if entries.is_empty():
			continue
		plans.append({"track": dest, "entries": entries})
		count += per_target[dest].size()
	if plans.is_empty():
		return 0
	var selection_before := selection_model.capture()
	var cmds := NoteTransfer.apply(project, source_moves, plans, label, false)
	var selection_after := selection_model.capture()
	var all: Array[Command] = []
	var last: Array[Command] = []
	if not NoteSelectionModel.same_state(selection_before, selection_after):
		all.append(SelectionStateCommand.new(label, selection_model, selection_before, selection_after, true))
		last.append(SelectionStateCommand.new(label, selection_model, selection_before, selection_after, false))
	all.append_array(cmds)
	all.append_array(last)
	HistoryUtil.record_many(label, all)
	queue_redraw()
	update_container_width()
	return count


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
	# The selection model forgets the note itself (it listens to the clip).
	queue_redraw()

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
## The duplicate of the grabbed note and its track, whichever track that is (dup_anchor is null
## when the note is on another track), and its pitch at the start.
var dup_anchor_data: MidiNoteData = null
var dup_anchor_track: Track = null
var _dup_anchor_pitch := 0
## Pending duplicates of notes of other tracks: {data (editor ticks), track, start_tick, note}.
## The context layer draws them.
var _dup_context: Array[Dictionary] = []
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
	return start_duplicate_drag_ref(ref_of_visual(grabbed), mouse_pos_local)


## Same, grabbing the note a ref points at, which may be on any track. Notes of the focus track
## become pending VisualNotes; notes of other tracks become pending copies the context layer
## draws translucent.
func start_duplicate_drag_ref(grabbed: NoteRef, mouse_pos_local: Vector2) -> bool:
	if grabbed == null or grabbed.data == null:
		return false
	cancel_duplicate_drag()
	var sources: Array[NoteRef] = []
	if selection_model.has(grabbed.data):
		sources.assign(selection_model.refs)
	else:
		sources.append(grabbed)

	for src in sources:
		var nd: MidiNoteData = src.data
		var copy := MidiNoteData.new()
		copy.copy_values_from(nd)
		# Where this note shows in the editor's ticks: a loop repeat's pass, not the note's first.
		copy.start_tick = span_of_ref(src).start_tick
		var is_anchor := nd == grabbed.data
		var shown := visual_of_ref(src)
		if shown != null:
			var vn: VisualNote = visual_note_scene.instantiate()
			vn.is_pending = true
			add_child(vn)
			vn.bind_to_note(copy)
			vn.set_color(note_color)
			vn.set_selected(true)
			_update_single_note_position(vn)
			_dup_origins[vn] = {"start_tick": copy.start_tick, "note": copy.note}
			if is_anchor:
				dup_anchor = vn
		else:
			_dup_context.append({"data": copy, "track": src.track, "start_tick": copy.start_tick, "note": copy.note})
		if is_anchor:
			dup_anchor_data = copy
			dup_anchor_track = src.track
			_dup_anchor_pitch = copy.note

	if _dup_origins.is_empty() and _dup_context.is_empty():
		return false
	_dup_start_mouse_pos = mouse_pos_local
	interaction_mode = InteractionMode.DUPLICATING
	_sync_context_pending()
	return true


## Move every duplicate by the snapped mouse delta, keeping their relative layout.
func update_duplicate_drag(mouse_pos_local: Vector2) -> void:
	if (_dup_origins.is_empty() and _dup_context.is_empty()) or dup_anchor_data == null:
		return
	var delta_ticks := pixels_to_ticks(mouse_pos_local.x - _dup_start_mouse_pos.x)
	delta_ticks = _snap_unless_shift(delta_ticks)
	var delta_steps := layout.row_of_pitch(_dup_anchor_pitch) - layout.y_to_row(mouse_pos_local.y)
	for vn in get_pending_duplicates():
		var origin: Dictionary = _dup_origins[vn]
		vn.midi_note_data.start_tick = maxi(0, origin.start_tick + delta_ticks)
		vn.midi_note_data.note = step_note(origin.note, delta_steps)
		vn._update_visual()
		_update_single_note_position(vn)
	for entry in _dup_context:
		var moved: MidiNoteData = entry.data
		moved.start_tick = maxi(0, entry.start_tick + delta_ticks)
		moved.note = step_note(entry.note, delta_steps)
	_sync_context_pending()


func _sync_context_pending() -> void:
	var layer: Variant = edits.context_layer
	if layer != null and layer.has_method("set_pending_notes"):
		layer.set_pending_notes(_dup_context)


## Write the duplicates into their clips (one undo step) and select them. Dropping them
## back exactly where they started is treated as a cancel. A duplicate goes into its own
## track's clip.
func finish_duplicate_drag() -> void:
	var pending := get_pending_duplicates()
	var moved := false
	for vn in pending:
		var origin: Dictionary = _dup_origins[vn]
		if vn.midi_note_data.start_tick != origin.start_tick or vn.midi_note_data.note != origin.note:
			moved = true
			break
	for entry in _dup_context:
		if entry.data.start_tick != entry.start_tick or entry.data.note != entry.note:
			moved = true
			break
	if not moved:
		cancel_duplicate_drag()
		return

	# Resolve every target first: creating a clip in track mode is its own undo step,
	# and the note snapshots must be taken after it exists.
	var targets: Array = []  # [MidiNoteData copy, ClipInstance or null, Clip]
	var all_copies: Array = []  # [MidiNoteData, Track or null]
	for vn in pending:
		all_copies.append([vn.midi_note_data, track])
	for entry in _dup_context:
		all_copies.append([entry.data, entry.track])
	for pair in all_copies:
		var nd: MidiNoteData = pair[0]
		if multi_clip_mode:
			var dest_track: Track = pair[1] if pair[1] != null else track
			var ci: ClipInstance
			if dest_track == track:
				ci = get_or_create_clip_at_position(nd.start_tick)
			else:
				ci = TrackClips.get_or_create(dest_track, nd.start_tick, grid_helper.get_ticks_per_bar() if grid_helper else 3840)
			if ci and ci.clip:
				targets.append([nd, ci, ci.clip])
		elif clip:
			targets.append([nd, clip_instance, clip])

	var clips: Array = []
	for t in targets:
		if t[2] not in clips:
			clips.append(t[2])
	edits.begin_clips(clips)

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

	var new_selection: Array = []
	for entry in added:
		if multi_clip_mode and entry[1].track != track:
			new_selection.append(NoteRef.new(entry[1], entry[0], 0))
			continue
		var vn: VisualNote = visual_at_song_tick(entry[1], entry[0], entry[2]) if multi_clip_mode else visual_for(clip_instance, entry[0])
		if vn and vn not in new_selection:
			new_selection.append(vn)
	selection_manager.select_all(new_selection)
	edits.commit("Duplicate Notes")
	update_container_width()
	logger.info("Ctrl+drag duplicated %d note(s)" % added.size())


## Drop the pending duplicates without touching any clip.
func cancel_duplicate_drag() -> void:
	for vn in get_pending_duplicates():
		remove_child(vn)
		vn.queue_free()
	_dup_origins.clear()
	_dup_context.clear()
	_sync_context_pending()
	dup_anchor = null
	dup_anchor_data = null
	dup_anchor_track = null
	if interaction_mode == InteractionMode.DUPLICATING:
		interaction_mode = InteractionMode.NONE


## One selected visual per selected note: the one it was selected through. A note shown by
## several visuals (loop repeats, instances of a linked clip) shares one MidiNoteData, so edits
## apply to it once.
func _selected_note_visuals() -> Array[VisualNote]:
	return selection_manager.selected_visuals()


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
	# If the selection reaches the note through this visual, move it to another visual of the
	# note, or drop the note when there is none.
	var sel := selection_model.ref_of(vn.midi_note_data) if vn.midi_note_data else null
	if sel != null and sel.instance == _instance_for_visual_note(vn) and sel.pass_index == vn.repeat_pass:
		var other: VisualNote = null
		for cand in _visuals_showing(vn.midi_note_data, sel.clip):
			if cand != vn and is_instance_valid(cand):
				other = cand
				break
		if other != null:
			sel.instance = _instance_for_visual_note(other)
			sel.pass_index = other.repeat_pass
		else:
			selection_model.remove_data(vn.midi_note_data, true)
	queue_redraw()
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

## The notes being scaled (refs of any track), and copies of them in editor ticks: scaling runs
## on the copies, in song ticks about the earliest start, and each result is converted back to
## its clip's ticks through the note's own instance.
var _scale_refs: Array[NoteRef] = []
var _scale_proxies: Array[MidiNoteData] = []
var _scale_origins := PackedInt32Array()
var _scale_starts := PackedInt32Array()
var _scale_durations := PackedInt32Array()
var _scale_anchor := 0
var _scale_end := 0
var _scale_mouse_x := 0.0
var _scale_range := Vector2i.ZERO
var _scale_had_range := false
var _scale_loop_owners: Dictionary = {}


## Where the clip tick 0 of `ref`'s note is in editor ticks: the instance's content origin in
## track mode (song ticks), 0 in clip mode.
func _editor_origin(ref: NoteRef) -> int:
	return ref.instance.content_origin_ticks() if multi_clip_mode and ref.instance != null else 0


## The handle just past the end of the selection, in this editor's space; an empty Rect2 when
## there is none. Needs two or more selected notes, on any tracks, outside Drum View (hits have
## no length). Among the notes that end last it sits on the one nearest the middle of their
## pitch range.
func group_scale_handle_rect() -> Rect2:
	if layout.is_drum() or grid_helper == null or selection_model.size() < 2:
		return Rect2()
	var right := -1
	for ref in selection_model.refs:
		right = maxi(right, _editor_origin(ref) + ref.data.start_tick + ref.data.duration_ticks)
	var lo := 127
	var hi := 0
	var last_ending: Array[NoteRef] = []
	for ref in selection_model.refs:
		if _editor_origin(ref) + ref.data.start_tick + ref.data.duration_ticks == right:
			last_ending.append(ref)
			lo = mini(lo, ref.data.note)
			hi = maxi(hi, ref.data.note)
	var pick: NoteRef = last_ending[0]
	for ref in last_ending:
		if absf(ref.data.note - (lo + hi) * 0.5) < absf(pick.data.note - (lo + hi) * 0.5):
			pick = ref
	var h := maxf(SCALE_HANDLE_SIZE.y, 0.0)
	var row_y := layout.pitch_to_y(pick.data.note)
	return Rect2(grid_helper.ticks_to_pixels(right) + SCALE_HANDLE_GAP, row_y + layout.row_height * 0.5 - h * 0.5, SCALE_HANDLE_SIZE.x, h)


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
	_scale_refs.assign(selection_model.refs)
	_scale_proxies.clear()
	_scale_origins = PackedInt32Array()
	_scale_starts = PackedInt32Array()
	_scale_durations = PackedInt32Array()
	for ref in _scale_refs:
		var origin := _editor_origin(ref)
		var proxy := ref.data.duplicate_note()
		proxy.start_tick = origin + ref.data.start_tick
		_scale_proxies.append(proxy)
		_scale_origins.append(origin)
		_scale_starts.append(proxy.start_tick)
		_scale_durations.append(ref.data.duration_ticks)
	var span := NoteTransforms.tick_bounds(_scale_proxies)
	_scale_anchor = span.x
	_scale_end = span.y
	_scale_mouse_x = mouse_x
	_scale_loop_owners = _loop_owners()
	_scale_had_range = selection_manager.has_range()
	_scale_range = Vector2i(selection_manager.box_selection_start_tick, selection_manager.box_selection_end_tick)
	edits.begin()
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
	NoteTransforms.scale(_scale_proxies, _scale_anchor, float(new_end - _scale_anchor) / float(span),
			_scale_starts, _scale_durations)
	_write_scaled_back()
	edits.refresh()
	queue_redraw()


## The scaled copies back into the notes, in each note's clip ticks.
func _write_scaled_back() -> void:
	for i in _scale_refs.size():
		var data := _scale_refs[i].data
		data.start_tick = maxi(0, _scale_proxies[i].start_tick - _scale_origins[i])
		data.duration_ticks = _scale_proxies[i].duration_ticks


## Same, from the mouse at editor position `pos`, snapped to the grid (Shift: free).
func update_group_scale_from_mouse(pos: Vector2) -> void:
	update_group_scale(_snap_unless_shift(_scale_end + pixels_to_ticks(pos.x - _scale_mouse_x)))


## Commit the preview as one undo step ("Scale Notes").
func end_group_scale() -> void:
	if interaction_mode != InteractionMode.SCALING:
		return
	interaction_mode = InteractionMode.NONE
	var scaled: Array[MidiNoteData] = []
	for ref in _scale_refs:
		scaled.append(ref.data)
	_fold_into_loops(scaled, _scale_loop_owners)
	edits.refresh()
	if _scale_had_range:
		var new_end := NoteTransforms.tick_bounds(_scale_proxies).y
		var factor := float(new_end - _scale_anchor) / float(_scale_end - _scale_anchor)
		selection_manager.box_selection_start_tick = _scaled_tick(_scale_range.x, factor)
		selection_manager.box_selection_end_tick = _scaled_tick(_scale_range.y, factor)
		selection_model.changed.emit()
	edits.sync()
	update_container_width()
	queue_redraw()
	edits.commit("Scale Notes")
	_scale_clear()


func _scaled_tick(tick: int, factor: float) -> int:
	return maxi(0, _scale_anchor + roundi((tick - _scale_anchor) * factor))


## Abort the gesture: notes go back to the snapshot and no undo step is recorded.
func cancel_group_scale() -> void:
	if interaction_mode != InteractionMode.SCALING:
		return
	interaction_mode = InteractionMode.NONE
	NoteTransforms.scale(_scale_proxies, _scale_anchor, 1.0, _scale_starts, _scale_durations)
	_write_scaled_back()
	edits.refresh()
	edits.discard()
	_scale_clear()
	queue_redraw()


func _scale_clear() -> void:
	_scale_refs.clear()
	_scale_proxies.clear()
	_scale_loop_owners.clear()
	queue_redraw()
