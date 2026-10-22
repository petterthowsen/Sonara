## Drag, resize and velocity drag of the selected notes, on NoteRefs: every selected note moves,
## whichever track it is on. One per NoteEditor (and so per MidiEditor).
##
## A drag that starts on a note works in the note editor's coordinates (pixels of the shared
## grid and lane layout), so it does not matter whether the grabbed note is the focus track's or
## belongs to a track only the context layer draws. Per-note rules apply to each note through its
## own instance: the played-window clamp, folding into the loop, and the drop transfer to another
## clip of the same track (never to another track). The gesture changes `ref.data` directly; the
## undo step, the refresh and the engine sync go through NoteEdits.
class_name NoteGestures extends RefCounted

static var logger := Log.make("NoteGestures")

enum Kind { NONE, DRAG, RESIZE }
## What a drag changes. PENDING: Alt is held but the mouse has not moved far enough to tell
## length from velocity.
enum DragMode { POSITION, RESIZE, VELOCITY, PENDING }

var editor: NoteEditor
var kind: Kind = Kind.NONE
## The note the user grabbed. The pitch delta of a drag and the length delta of a resize are
## measured from it.
var grabbed: NoteRef = null
var last_drag_mode: DragMode = DragMode.POSITION
var drag_start_midi_note: int = 0
var drag_start_mouse_pos: Vector2 = Vector2.ZERO
## MidiNoteData -> {start_tick, note, velocity, clip_instance}, taken at the start of the drag
## and again on a mode switch.
var drag_start_positions: Dictionary = {}
var resize_start_duration: int = 0
var resize_start_mouse_pos: Vector2 = Vector2.ZERO
## MidiNoteData -> duration_ticks
var resize_start_durations: Dictionary = {}

## Clip -> its content length when the drag (or mode) started: the bound a note is clamped to.
## Taken once, since asking a clip scans all its notes.
var _content_lengths: Dictionary = {}
## Start of the grabbed note when the drag (or its current mode) began; see _grabbed_start_ticks.
var _anchor_start: int = 0

## The press that began the drag held Ctrl (to add a note to the selection): that Ctrl is not the
## length modifier until it is released once.
var _ctrl_from_press := false
## Whether a modifier key is held; a Callable(key) -> bool so a test can stand in for the keyboard.
var key_held: Callable = Input.is_key_pressed
## False for place-and-drag, whose note was recorded by the placement.
var _owns_edit := true


func _init(p_editor: NoteEditor) -> void:
	editor = p_editor


func is_active() -> bool:
	return kind != Kind.NONE


## The visual that shows the grabbed note in the note editor, or null (a note of another track).
func grabbed_visual() -> VisualNote:
	return editor.visual_of_ref(grabbed) if grabbed != null else null


# ============================================================================
# DRAG
# ============================================================================

## Start dragging the selection by `ref`. A note that is not selected becomes the selection.
## `pos` is in the note editor's coordinates. `open_edit` false keeps an edit that is already
## recorded elsewhere out of the undo history (place-and-drag).
func begin_drag(ref: NoteRef, pos: Vector2, open_edit := true, ctrl_held := false) -> void:
	if ref == null or ref.data == null:
		return
	if not editor.selection_model.has(ref.data):
		editor.selection_manager.select_ref(ref)
	editor.note_touched.emit(ref.data)

	kind = Kind.DRAG
	grabbed = ref
	drag_start_midi_note = ref.data.note
	drag_start_mouse_pos = pos
	last_drag_mode = DragMode.POSITION
	_ctrl_from_press = ctrl_held
	_owns_edit = open_edit
	Hotkeys.begin_state(self, "note_drag_alt" if editor._alt_auto_mode() else "note_drag")

	_snapshot()
	if open_edit:
		editor.edits.begin()


## Capture (or re-capture, on a mid-drag mode switch) the starting tick, pitch, velocity and
## duration and the owning instance of every selected note. The instance is kept so a drop
## transfer still works after a mode switch.
func _snapshot() -> void:
	drag_start_positions.clear()
	resize_start_durations.clear()
	_content_lengths.clear()
	for ref in editor.selection_model.refs:
		var data := ref.data
		var c := ref.clip
		if c != null and not _content_lengths.has(c):
			_content_lengths[c] = c.get_content_length()
		drag_start_positions[data] = {
			"start_tick": data.start_tick,
			"note": data.note,
			"velocity": data.velocity,
			"clip_instance": ref.instance,
		}
		resize_start_durations[data] = data.duration_ticks
	_anchor_start = _grabbed_start_ticks()


## Where the grabbed note starts, in the ticks the grid is laid out in: song ticks in track
## mode, clip-content ticks when the editor shows one clip.
func _grabbed_start_ticks() -> int:
	if grabbed == null or grabbed.data == null:
		return 0
	if editor.multi_clip_mode and grabbed.instance != null:
		return grabbed.song_start()
	return grabbed.data.start_tick


## While Alt (length or velocity) or Ctrl (length) is held, a drag changes more than position.
func update_drag(pos: Vector2) -> void:
	if kind != Kind.DRAG or grabbed == null:
		return
	var ctrl_pressed: bool = key_held.call(KEY_CTRL)
	if _ctrl_from_press:
		if ctrl_pressed:
			ctrl_pressed = false
		else:
			_ctrl_from_press = false
	var alt_pressed: bool = key_held.call(KEY_ALT)
	var drum_view := editor.layout.is_drum()

	# Drum View draws hits, not bars, so there is no length to drag out (REQ-022).
	# Length falls back to plain dragging (Ctrl) or to velocity only (Alt).
	var auto_alt := editor._alt_auto_mode()
	if drum_view or auto_alt:
		ctrl_pressed = false

	var current_mode: DragMode
	if alt_pressed and auto_alt and not drum_view:
		current_mode = alt_axis_mode(pos)
	elif alt_pressed:
		current_mode = DragMode.VELOCITY
	elif ctrl_pressed:
		current_mode = DragMode.RESIZE
	else:
		current_mode = DragMode.POSITION

	if current_mode != last_drag_mode:
		drag_start_mouse_pos = pos
		_snapshot()
		last_drag_mode = current_mode
		logger.info("Drag mode switched to: %s" % ["POSITION", "RESIZE", "VELOCITY", "PENDING"][current_mode])

	# Alt is down but undecided: nothing moves until the mouse commits to an axis.
	if current_mode == DragMode.PENDING:
		return

	var refs := editor.selection_model.refs
	var delta_ticks := editor.pixels_to_ticks(pos.x - drag_start_mouse_pos.x)
	# The grabbed note lands on the grid (even if it started off it, #170) and every other
	# note moves by the same delta, so notes keep their offsets from each other.
	var snapped_delta_ticks: int = editor._snap_unless_shift(_anchor_start + delta_ticks) - _anchor_start

	if current_mode == DragMode.VELOCITY:
		# Dragging up raises it, 2 px per 1/127 step.
		var velocity_delta := int(-(pos.y - drag_start_mouse_pos.y) / 2.0) / 127.0
		for ref in refs:
			var start_pos = drag_start_positions.get(ref.data)
			if not start_pos:
				continue
			var start_velocity: float = start_pos.get("velocity", MidiNoteData.DEFAULT_VELOCITY)
			ref.data.velocity = clampf(start_velocity + velocity_delta, MidiNoteData.MIN_VELOCITY, 1.0)
	elif current_mode == DragMode.RESIZE:
		# One snapped delta from the grabbed note, applied to every selected note.
		var anchor_start: int = resize_start_durations.get(grabbed.data, grabbed.data.duration_ticks)
		var snapped_delta: int = editor._snapped_duration(anchor_start + delta_ticks) - anchor_start
		for ref in refs:
			var start_duration = resize_start_durations.get(ref.data)
			if start_duration == null:
				continue
			ref.data.duration_ticks = maxi(1, start_duration + snapped_delta)
	else:
		_move_notes(refs, pos, snapped_delta_ticks)

	editor.edits.refresh(refs)

	if current_mode == DragMode.POSITION:
		_keep_dragged_out_visible(refs)


## Position mode: every note moves by the same snapped tick delta and the same number of rows
## (Drum View) or scale steps. The pitch delta is measured from the grabbed note. Drum View rows
## are the shared layout's, so a note can land on a row its own track has no pad for.
func _move_notes(refs: Array, pos: Vector2, snapped_delta_ticks: int) -> void:
	var layout := editor.layout
	var scale_context := editor.scale_context
	# Row-wise in Drum View, semitone-wise in the piano roll (REQ-020). The two agree exactly in
	# chromatic mode.
	var delta_steps := layout.row_of_pitch(drag_start_midi_note) - layout.y_to_row(pos.y)
	# Scale snap (REQ-015, 016, 018): the cursor picks an in-scale target and every note moves
	# the same number of scale steps. Shift keeps the plain row walk.
	var scale_steps := 0
	var scale_drag: bool = scale_context.snap_active() and not Input.is_key_pressed(KEY_SHIFT)
	if scale_drag:
		var upper_half := fposmod(pos.y, layout.row_height) < layout.row_height * 0.5
		var target := scale_context.snap_pitch(layout.y_to_pitch(pos.y), upper_half)
		scale_steps = scale_context.steps_between(drag_start_midi_note, target)

	for ref: NoteRef in refs:
		var data := ref.data
		var start_pos = drag_start_positions.get(data)
		if not start_pos:
			continue
		var new_ticks: int = maxi(0, start_pos.start_tick + snapped_delta_ticks)
		var new_midi_note := editor.step_note(start_pos.note, delta_steps)
		if scale_drag and not scale_context.is_keyswitch(start_pos.note):
			new_midi_note = scale_context.step(start_pos.note, scale_steps)

		# Clamp within clip content in track mode to avoid crossing instance boundaries
		var owner_ci := ref.instance if editor.multi_clip_mode else null
		if owner_ci:
			if owner_ci.in_loop_region(start_pos.start_tick):
				# A note in the loop stays in it: dragged past the loop end it comes in again at
				# the loop start, which is where the next pass shows it.
				new_ticks = owner_ci.fold_into_loop(start_pos.start_tick + snapped_delta_ticks)
			elif owner_ci.clip:
				# The bound is the instance's played window, not the content length: content
				# length is the rightmost note end, so using it would pin the last note in place
				# and make dragging right a no-op. Content that reaches past the window (a
				# trimmed instance) still gets that larger bound, so no note is clamped backwards.
				var clip_len: int = max(owner_ci.clip_offset + owner_ci.duration_ticks, _content_lengths.get(owner_ci.clip, 0))
				if clip_len > 0:
					new_ticks = clampi(new_ticks, 0, maxi(0, clip_len - data.duration_ticks))
		data.start_tick = new_ticks
		data.note = new_midi_note


## A note dragged out of its (unlooped) instance stays in view under the mouse until the drop
## moves it into the clip it lands on. Only the note editor's own visuals need this: the context
## layer draws selected notes from the refs.
func _keep_dragged_out_visible(refs: Array) -> void:
	if not editor.multi_clip_mode:
		return
	for ref: NoteRef in refs:
		if ref.pass_index > 0 or ref.instance == null or ref.instance.loop_enabled:
			continue
		var vn := editor.visual_of_ref(ref)
		if vn == null or vn.visible:
			continue
		var rect := NotePlacement.note_rect(ref.data, ref.instance.content_origin_ticks(), editor.layout, editor.grid_helper)
		if rect.has_area():
			vn.visible = true
			vn.position = rect.position
			vn.size = rect.size


## Alt auto mode: while the mouse is within ALT_AXIS_THRESHOLD of where Alt engaged the drag is
## PENDING, then the dominant axis picks length (sideways) or velocity (up, down) and stays
## picked until Alt is released.
func alt_axis_mode(pos: Vector2) -> DragMode:
	if last_drag_mode == DragMode.RESIZE or last_drag_mode == DragMode.VELOCITY:
		return last_drag_mode
	if last_drag_mode != DragMode.PENDING:
		return DragMode.PENDING
	var moved := pos - drag_start_mouse_pos
	if moved.length() < NoteEditor.ALT_AXIS_THRESHOLD:
		return DragMode.PENDING
	return DragMode.RESIZE if absf(moved.x) >= absf(moved.y) else DragMode.VELOCITY


## Drop: transfer notes that landed in another clip of their track, cut overlaps, sync and record
## one undo step. Returns true when anything changed.
func end_drag() -> bool:
	if kind != Kind.DRAG or grabbed == null:
		return false
	var refs := editor.selection_model.refs
	var changed := false
	for ref in refs:
		var data := ref.data
		var start_pos = drag_start_positions.get(data)
		var start_duration = resize_start_durations.get(data)
		if start_pos:
			if data.start_tick != start_pos.start_tick or data.note != start_pos.note \
					or data.velocity != start_pos.get("velocity", MidiNoteData.DEFAULT_VELOCITY):
				changed = true
				break
		if start_duration != null and data.duration_ticks != start_duration:
			changed = true
			break
	if not changed:
		logger.info("Drag ended with no changes")
		_reset()
		editor.edits.discard()
		editor.update_container_width()
		return false

	var anchor_start = resize_start_durations.get(grabbed.data)
	if anchor_start != null and grabbed.data.duration_ticks != anchor_start:
		editor.last_note_length = grabbed.data.duration_ticks

	if editor.multi_clip_mode:
		_transfer_between_clips()

	# Cut overlaps and update. A transfer above drops its note from the selection, so this is
	# the current set.
	editor.edits.sync()
	logger.info("Updated %d note(s)" % editor.selection_model.size())
	editor.edits.commit("Move Notes")

	# Don't update the selection range: it keeps the grid-snapped box boundaries the user made.
	editor.queue_redraw()
	editor.update_container_width()
	_reset()
	return true


## Notes dragged into a clip of the same track other than their own move into it (creating a
## clip on empty space). Notes of a clip used by several instances stay in the clip, and notes in
## a loop stay in their instance. A note never leaves its track.
func _transfer_between_clips() -> void:
	# Iterate a copy: removing a note drops it from the selection.
	for ref: NoteRef in editor.selection_model.refs.duplicate():
		var source := ref.instance
		var track := ref.track
		var data := ref.data
		if source == null or source.clip == null or track == null:
			continue
		if source.loop_enabled and source.in_loop_region(data.start_tick):
			continue
		if not drag_start_positions.has(data):
			continue
		var song_position := source.clip_to_song_ticks(data.start_tick)
		var dest := TrackClips.clip_at(track, song_position)
		# A destination that plays the same clip: edits are clip-local and shared across
		# instances, so the note keeps its clip-local position.
		if dest and dest.clip == source.clip:
			continue
		if not dest:
			var ticks_per_bar: int = editor.grid_helper.get_ticks_per_bar() if editor.grid_helper else 3840
			dest = TrackClips.get_or_create(track, song_position, ticks_per_bar)
			if dest and track == editor.track and dest not in editor.clip_instances:
				editor.clip_instances.append(dest)
		if dest and dest != source:
			_transfer_note(data, source, dest, song_position)


func _transfer_note(note_data: MidiNoteData, source: ClipInstance, dest: ClipInstance, song_position: int) -> void:
	logger.info("Transferring note %d from clip '%s' to '%s'" % [note_data.id, source.clip.name if source.clip else "?", dest.clip.name if dest.clip else "?"])
	editor.edits.include_clip(dest.clip)
	var dest_local_position := dest.song_to_clip_ticks(song_position)

	var new_note := MidiNoteData.new()
	new_note.id = dest.clip.allocate_note_id()
	new_note.copy_values_from(note_data)
	new_note.start_tick = dest_local_position
	new_note.duration_ticks = note_data.duration_ticks

	# Clear the landing spot first. Without this the add below is rejected as an overlap and
	# the note would be dropped entirely.
	dest.clip.cut_overlapping_notes_at_pitch(
		new_note.note, new_note.start_tick, new_note.start_tick + new_note.duration_ticks,
		dest.clip.allocate_note_id)

	# Remove from the source clip (the selection model forgets the note)
	if not source.clip.remove_midi_note(note_data):
		logger.warn("Transfer aborted: note %d is not in clip '%s'" % [note_data.id, source.clip.name])
		return

	if dest.clip.add_midi_note_data(new_note) == null:
		# Put it back rather than losing it.
		logger.warn("Transfer of note %d into '%s' was rejected; restoring it in '%s'" % [note_data.id, dest.clip.name, source.clip.name])
		source.clip.add_midi_note_data(note_data)
		return
	logger.info("Note transferred: old_id=%d, new_id=%d, new_local_pos=%d" % [note_data.id, new_note.id, dest_local_position])


# ============================================================================
# RESIZE
# ============================================================================

## Start resizing the selection by `ref`'s right edge. False in Drum View (hits have no length,
## REQ-022).
func begin_resize(ref: NoteRef, pos: Vector2) -> bool:
	if ref == null or ref.data == null or editor.layout.is_drum():
		return false
	if not editor.selection_model.has(ref.data):
		editor.selection_manager.select_ref(ref)
	editor.note_touched.emit(ref.data)

	kind = Kind.RESIZE
	grabbed = ref
	resize_start_duration = ref.data.duration_ticks
	resize_start_mouse_pos = pos
	_owns_edit = true
	resize_start_durations.clear()
	for sel in editor.selection_model.refs:
		resize_start_durations[sel.data] = sel.data.duration_ticks
	editor.edits.begin()
	return true


func update_resize(pos: Vector2) -> void:
	if kind != Kind.RESIZE or grabbed == null:
		return
	var delta_ticks := editor.pixels_to_ticks(pos.x - resize_start_mouse_pos.x)
	var new_duration: int = editor._snapped_duration(resize_start_duration + delta_ticks)
	var same_length: bool = key_held.call(KEY_ALT if editor._alt_auto_mode() else KEY_CTRL)
	# Same delta for every note, snapped once from the grabbed note
	var snapped_delta := new_duration - resize_start_duration
	var refs := editor.selection_model.refs
	for ref in refs:
		if same_length:
			# Length key (Alt or Ctrl, see the note drag modifiers setting): all notes get the same duration
			ref.data.duration_ticks = new_duration
		else:
			var start_duration: int = resize_start_durations.get(ref.data, ref.data.duration_ticks)
			ref.data.duration_ticks = maxi(1, start_duration + snapped_delta)
	editor.edits.refresh(refs)


func end_resize() -> void:
	if kind != Kind.RESIZE or grabbed == null:
		return
	editor.last_note_length = grabbed.data.duration_ticks
	editor.edits.sync()
	logger.info("Updated %d note(s) duration" % editor.selection_model.size())
	editor.queue_redraw()
	editor.update_container_width()
	editor.edits.commit("Resize Notes")
	_reset()


# ============================================================================
# CANCEL
# ============================================================================

## Esc: put every note back as it was at the start and record nothing.
func cancel() -> void:
	if kind == Kind.NONE:
		return
	if editor.edits.is_open():
		editor.edits.cancel()
	else:
		# Place-and-drag: the placement is recorded, only the drag is undone.
		for ref in editor.selection_model.refs:
			var start_pos = drag_start_positions.get(ref.data)
			if start_pos:
				ref.data.start_tick = start_pos.start_tick
				ref.data.note = start_pos.note
				ref.data.velocity = start_pos.velocity
			var start_duration = resize_start_durations.get(ref.data)
			if start_duration != null:
				ref.data.duration_ticks = start_duration
		editor.edits.refresh()
	_reset()
	editor.queue_redraw()
	editor.update_container_width()


## The notes the gesture works on are going away (unbind): forget it without touching clips.
func abandon() -> void:
	_reset()
	editor.edits.discard()


func _reset() -> void:
	if kind == Kind.DRAG:
		Hotkeys.end_state(self)
	kind = Kind.NONE
	grabbed = null
	_ctrl_from_press = false
	drag_start_positions.clear()
	resize_start_durations.clear()
	_content_lengths.clear()

