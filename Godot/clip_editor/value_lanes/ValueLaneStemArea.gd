## The drawing and editing surface of one value lane: a stem per note, sitting at the note's
## start or end, as tall as the note's value. Draws everything in one _draw() and runs the
## gestures (paint, offset, scale, line, reset, exact value). The maths lives in
## ValueLaneEdits; the stems come from MidiEditor.value_stems(), so they sit exactly under
## the notes they belong to.
class_name ValueLaneStemArea extends Panel

## A gesture ended on `note` (it becomes the "last touched note" for new notes).
signal note_touched(note: MidiNoteData)
## Right click: the lane shows its menu at `global_pos`.
signal context_requested(global_pos: Vector2)

enum Gesture { NONE, PAINT, OFFSET, SCALE, LINE }

## Pixels either side of the pointer that count as "the same x" (a chord's stems).
const CHORD_TOLERANCE := 3.0
## Movement after a Ctrl press before it becomes a line instead of a click.
const LINE_THRESHOLD := 3.0
const STEM_WIDTH := 2.0
const HEAD_SIZE := 5.0
const HISTORY_NAME := "Edit %s"

var midi_editor: MidiEditor = null
var descriptor: NoteValueDescriptor = null:
	set(d):
		descriptor = d
		queue_redraw()

var _gesture := Gesture.NONE
var _press_pos := Vector2.ZERO
var _fine := FineDrag.new()
var _last_point := Vector2.ZERO
## Stems and note -> clip map frozen at the press, so a gesture doesn't rebuild them per motion.
var _stems: Array[Dictionary] = []
var _clip_by_note: Dictionary = {}  # MidiNoteData -> Clip
## Values at the press of every note an offset / scale gesture acts on (and of every touched
## note, for the "did it change" check on release).
var _originals: Dictionary = {}  # MidiNoteData -> float
## Everything touched by the gesture, for the refresh and the engine sync on release.
var _touched: Dictionary = {}  # MidiNoteData -> Clip
var _before: Dictionary = {}
var _line_end := Vector2.ZERO
var _moved := false
var _hovered: MidiNoteData = null
var _tooltip: ValueTooltip = null
var _last_audition_velocity := -1


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_tooltip = ValueTooltip.attach(self)


## Follow `editor`: redraw whenever the notes, the selection, the zoom or the scroll change.
func bind(editor: MidiEditor) -> void:
	midi_editor = editor
	if editor.grid_helper:
		_connect_once(editor.grid_helper.changed, queue_redraw)
	_connect_once(editor.h_scroll.get_h_scroll_bar().value_changed, _on_scrolled)
	_connect_once(editor.hovered_note_changed, _on_hover_changed)
	for ne in editor.note_editors:
		_connect_once(ne.notes_changed, queue_redraw)
		if ne.selection_manager:
			_connect_once(ne.selection_manager.selection_changed, _on_selection_changed)
	queue_redraw()


func _connect_once(sig: Signal, callable: Callable) -> void:
	if not sig.is_connected(callable):
		sig.connect(callable)


func _on_scrolled(_v: float) -> void:
	queue_redraw()


func _on_selection_changed(_notes: Array) -> void:
	queue_redraw()


func _on_hover_changed(_note: MidiNoteData) -> void:
	queue_redraw()


# ============================================================================
# GEOMETRY
# ============================================================================

## x of the note area's scroll content origin, in this control's coordinates.
func _origin_offset() -> float:
	return midi_editor.h_scroll.global_position.x - global_position.x


## Stem x in this control's coordinates.
func stem_x(stem: Dictionary) -> float:
	var x: float = stem["x_end"] if descriptor.anchor == NoteValueDescriptor.Anchor.END else stem["x_start"]
	return x + _origin_offset()


## y of the top of a stem with value `v`.
func stem_top(v: float) -> float:
	var span := descriptor.max_value - descriptor.min_value
	var t := 0.0 if span <= 0.0 else clampf((v - descriptor.min_value) / span, 0.0, 1.0)
	return size.y * (1.0 - t)


## The stems to act on: frozen during a gesture, fresh otherwise.
func _current_stems() -> Array[Dictionary]:
	return _stems if _gesture != Gesture.NONE else midi_editor.value_stems()


# ============================================================================
# DRAWING
# ============================================================================

func _draw() -> void:
	if midi_editor == null or descriptor == null:
		return
	for stem in _current_stems():
		var x := stem_x(stem)
		if x < -HEAD_SIZE or x > size.x + HEAD_SIZE:
			continue
		var nd: MidiNoteData = stem["note_data"]
		var top := stem_top(descriptor.get_value(nd))
		var color: Color = Utils.display_color(stem["color"])
		var width := STEM_WIDTH
		if stem["ghost"]:
			color.a = 0.35
		if stem["selected"]:
			color = color.lightened(0.35)
			width += 1.0
		if nd == midi_editor.hovered_note_data:
			color = Color.WHITE
		draw_line(Vector2(x, size.y), Vector2(x, top), color, width)
		draw_rect(Rect2(x - HEAD_SIZE * 0.5, top - HEAD_SIZE * 0.5, HEAD_SIZE, HEAD_SIZE), color)
	if _gesture == Gesture.LINE and _moved:
		draw_line(_press_pos, _line_end, Color(1, 1, 1, 0.8), 1.5)


# ============================================================================
# TARGETS
# ============================================================================

## The notes a gesture at x acts on: the selection when one exists, otherwise the stems at x
## (a chord).
func targets_at(x: float) -> Array[MidiNoteData]:
	var selected := midi_editor.selected_note_data()
	if not selected.is_empty():
		return selected
	return _chord_at(x, x)


## Notes of the stems whose x lies within the tolerance of [x0, x1].
func _chord_at(x0: float, x1: float) -> Array[MidiNoteData]:
	var lo := minf(x0, x1) - CHORD_TOLERANCE
	var hi := maxf(x0, x1) + CHORD_TOLERANCE
	var out: Array[MidiNoteData] = []
	for stem in _current_stems():
		var x := stem_x(stem)
		if x >= lo and x <= hi and stem["note_data"] not in out:
			out.append(stem["note_data"])
	return out


## Note of the stem nearest x (within tolerance), or null.
func _note_near(x: float) -> MidiNoteData:
	var best: MidiNoteData = null
	var best_d := CHORD_TOLERANCE + 0.001
	for stem in midi_editor.value_stems():
		var d := absf(stem_x(stem) - x)
		if d < best_d:
			best_d = d
			best = stem["note_data"]
	return best


# ============================================================================
# INPUT
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if midi_editor == null or descriptor == null:
		return
	if event is InputEventMouseButton:
		_on_button(event)
	elif event is InputEventMouseMotion:
		_on_motion(event)


func _on_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		context_requested.emit(event.global_position)
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		if event.double_click and not event.ctrl_pressed and not event.alt_pressed:
			_cancel_gesture()
			_open_exact_editor(event.position)
		else:
			_begin(event)
		accept_event()
	elif _gesture != Gesture.NONE:
		_finish()
		accept_event()


func _begin(event: InputEventMouseButton) -> void:
	_press_pos = event.position
	_moved = false
	_touched.clear()
	_originals.clear()
	_last_audition_velocity = -1
	_fine.begin(event.position)
	_last_point = event.position
	_stems = midi_editor.value_stems()
	_clip_by_note.clear()
	for stem in _stems:
		_clip_by_note[stem["note_data"]] = stem["clip"]
	_before = ClipNotesStateCommand.capture_many(_unique_clips())
	if event.alt_pressed:
		_gesture = Gesture.SCALE if event.ctrl_pressed else Gesture.OFFSET
		for nd in targets_at(event.position.x):
			_originals[nd] = descriptor.get_value(nd)
	elif event.ctrl_pressed:
		_gesture = Gesture.LINE
		_line_end = event.position
	else:
		_gesture = Gesture.PAINT
		_paint(event.position, event.position)
	_update_tooltip(event.position)
	_refresh()


func _on_motion(event: InputEventMouseMotion) -> void:
	if _gesture == Gesture.NONE:
		_update_hover(event.position)
		return
	var point := _fine.update(event.position, event.shift_pressed)
	if not _moved and event.position.distance_to(_press_pos) > LINE_THRESHOLD:
		_moved = true
	match _gesture:
		Gesture.PAINT:
			# x follows the real pointer (which stems it crosses), y is the fine-adjusted value.
			var p := Vector2(event.position.x, point.y)
			_paint(_last_point, p)
			_last_point = p
		Gesture.OFFSET:
			_apply_offset(point.y - _press_pos.y)
		Gesture.SCALE:
			_apply_scale(point.y - _press_pos.y)
		Gesture.LINE:
			_line_end = Vector2(event.position.x, point.y)
	_update_tooltip(event.position)
	_refresh()
	accept_event()


func _finish() -> void:
	var gesture := _gesture
	if gesture == Gesture.LINE:
		if _moved:
			_apply_line()
		else:
			for nd in targets_at(_press_pos.x):
				_write_value(nd, descriptor.default_value)
	_gesture = Gesture.NONE
	_tooltip.visible = false
	_stop_audition()
	_commit()


func _cancel_gesture() -> void:
	_gesture = Gesture.NONE
	_tooltip.visible = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _gesture == Gesture.NONE and midi_editor != null:
		if _hovered != null:
			_hovered = null
			midi_editor.set_hovered_note(null)


func _update_hover(pos: Vector2) -> void:
	var nd := _note_near(pos.x)
	if nd != _hovered:
		_hovered = nd
		midi_editor.set_hovered_note(nd)


# ============================================================================
# GESTURE MATHS (applied to the data; the engine hears about it on release)
# ============================================================================

func _unique_clips() -> Array:
	var clips: Array = []
	for c in _clip_by_note.values():
		if c != null and c not in clips:
			clips.append(c)
	return clips


func _paint(from: Vector2, to: Vector2) -> void:
	var selected := midi_editor.selected_note_data()
	if not selected.is_empty():
		var v := ValueLaneEdits.value_at_y(to.y, size.y, descriptor)
		for nd in selected:
			_write_value(nd, v)
		return
	# Every stem the pointer passed between the last and this position gets the value on the
	# line between the two points, so a fast drag doesn't skip stems.
	var p0 := Vector2(from.x, ValueLaneEdits.value_at_y(from.y, size.y, descriptor))
	var p1 := Vector2(to.x, ValueLaneEdits.value_at_y(to.y, size.y, descriptor))
	var lo := minf(from.x, to.x) - CHORD_TOLERANCE
	var hi := maxf(from.x, to.x) + CHORD_TOLERANCE
	for stem in _stems:
		var x := stem_x(stem)
		if x >= lo and x <= hi:
			_write_value(stem["note_data"], ValueLaneEdits.line_value(p0, p1, x, descriptor))


func _apply_offset(dy: float) -> void:
	var delta := -dy / maxf(size.y, 1.0) * (descriptor.max_value - descriptor.min_value)
	var res := ValueLaneEdits.offset(_originals.values(), delta, descriptor)
	var i := 0
	for nd in _originals.keys():
		_write_value(nd, res[i])
		i += 1


## Scale toward 0: dragging down shrinks, up grows.
func _apply_scale(dy: float) -> void:
	var factor := (size.y - dy) / maxf(size.y, 1.0)
	var res := ValueLaneEdits.scale(_originals.values(), factor, descriptor)
	var i := 0
	for nd in _originals.keys():
		_write_value(nd, res[i])
		i += 1


## Ctrl-drag release: every stem inside the dragged x span (the selection only, when there
## is one) gets the value on the line.
func _apply_line() -> void:
	var p0 := Vector2(_press_pos.x, ValueLaneEdits.value_at_y(_press_pos.y, size.y, descriptor))
	var p1 := Vector2(_line_end.x, ValueLaneEdits.value_at_y(_line_end.y, size.y, descriptor))
	var selected := midi_editor.selected_note_data()
	var lo := minf(p0.x, p1.x)
	var hi := maxf(p0.x, p1.x)
	for stem in _stems:
		var nd: MidiNoteData = stem["note_data"]
		if not selected.is_empty() and nd not in selected:
			continue
		var x := stem_x(stem)
		if x >= lo and x <= hi:
			_write_value(nd, ValueLaneEdits.line_value(p0, p1, x, descriptor))


## Write a value to a note and remember it for the refresh and the sync.
func _write_value(nd: MidiNoteData, v: float) -> void:
	if not _touched.has(nd):
		_touched[nd] = _clip_by_note.get(nd)
		if not _originals.has(nd):
			_originals[nd] = descriptor.get_value(nd)
	descriptor.set_value(nd, v)
	_audition(nd)


## Redraw the stems and the brightness of the notes' own visuals.
func _refresh() -> void:
	for editor in midi_editor.note_editors:
		for child in editor.get_children():
			if child is VisualNote and child.midi_note_data in _touched:
				child.bind_to_note(child.midi_note_data)
	queue_redraw()


## One undo step, one engine update per changed note.
func _commit() -> void:
	_refresh()
	var last: MidiNoteData = null
	for nd in _touched.keys():
		last = nd
		if is_equal_approx(descriptor.get_value(nd), _originals.get(nd, descriptor.get_value(nd))):
			continue
		var clip: Clip = _touched[nd]
		if clip != null:
			clip.update_midi_note(nd)
	ClipNotesStateCommand.commit_many(HISTORY_NAME % descriptor.display_name, _before)
	_before = {}
	_stems = []
	_clip_by_note.clear()
	_touched.clear()
	_originals.clear()
	if last != null:
		note_touched.emit(last)


# ============================================================================
# AUDITION AND READOUT
# ============================================================================

## A single-note velocity drag plays the note again whenever its 7-bit velocity changes.
func _audition(nd: MidiNoteData) -> void:
	if descriptor.key != "vel" or not midi_editor.audition_enabled or _touched.size() != 1:
		return
	var v7 := MidiNoteData.to_midi_velocity(nd.velocity)
	if v7 == _last_audition_velocity:
		return
	_last_audition_velocity = v7
	midi_editor._start_preview_note(nd.note, nd.velocity)


func _stop_audition() -> void:
	if _last_audition_velocity >= 0:
		midi_editor._stop_preview_note()
	_last_audition_velocity = -1


func _update_tooltip(pos: Vector2) -> void:
	var mode := NoteValueDescriptors.display_mode()
	var v: float
	if _gesture == Gesture.LINE:
		v = ValueLaneEdits.value_at_y(_line_end.y, size.y, descriptor)
	elif not _touched.is_empty():
		v = descriptor.get_value(_touched.keys()[0])
	else:
		v = ValueLaneEdits.value_at_y(pos.y, size.y, descriptor)
	_tooltip.set_text(descriptor.format(v, mode))
	_tooltip.visible = true
	_tooltip.place_right_of(get_global_transform() * pos)


# ============================================================================
# EXACT VALUE (double click)
# ============================================================================

func _open_exact_editor(pos: Vector2) -> void:
	var targets := targets_at(pos.x)
	if targets.is_empty():
		return
	var box := Vector2(72, 24)
	var editor := FloatingValueEditor.new()
	add_child(editor)
	editor.committed.connect(_on_exact_committed.bind(targets))
	editor.open(descriptor.format(descriptor.get_value(targets[0]), NoteValueDescriptors.display_mode()),
		get_global_transform() * pos - Vector2(box.x * 0.5, box.y + 8.0), box)


func _on_exact_committed(text: String, targets: Array[MidiNoteData]) -> void:
	apply_exact_value(targets, descriptor.parse(text, NoteValueDescriptors.display_mode()))


## Set `targets` to `v` as one undo step. Does nothing for NAN (text that didn't parse).
func apply_exact_value(targets: Array[MidiNoteData], v: float) -> void:
	if is_nan(v):
		return
	apply_values(targets, NoteValueTransforms.set_all(targets, v, descriptor))


## Give each note in `notes` the matching value of `values` as one undo step and one engine
## update per changed note (the lane's transforms and the exact-value editor use this).
func apply_values(notes: Array[MidiNoteData], values: Array) -> void:
	_stems = midi_editor.value_stems()
	_clip_by_note.clear()
	for stem in _stems:
		_clip_by_note[stem["note_data"]] = stem["clip"]
	_before = ClipNotesStateCommand.capture_many(_unique_clips())
	_touched.clear()
	_originals.clear()
	for i in notes.size():
		_write_value(notes[i], values[i])
	_commit()
