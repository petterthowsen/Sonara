## Middle column of the Layer mapping window (docs/specs/006-layer-note-mapping, REQ-010): one
## line per mapped input → output note, drawn between the input piano (left edge) and the output
## piano (right edge). The selected slot's lines are bright; other zoned slots' lines are faded.
## Full-map slots draw nothing here (the window says "all notes" instead). Pressing a row starts a
## connect drag from that input (full-height rows, so black keys are as easy to grab as white ones);
## the drag itself is tracked by LayerMappingWindow.
class_name LayerMappingCanvas extends Control

## Left button pressed on the row of input `note`.
signal row_pressed(note: int)

const LINE_WIDTH := 2.0
const FADED_ALPHA := 0.18
const SELECTED_INPUT_COLOR := Color(1.0, 0.75, 0.2, 0.14)
const HOVER_ROW_COLOR := Color(1.0, 1.0, 1.0, 0.06)
const DRAG_COLOR := Color(1.0, 0.75, 0.2, 0.9)

## Shared with both pianos, so rows line up.
var layout: LaneLayout = null:
	set(l):
		if layout and layout.changed.is_connected(_on_layout_changed):
			layout.changed.disconnect(_on_layout_changed)
		layout = l
		if layout:
			layout.changed.connect(_on_layout_changed)
		_on_layout_changed()

## One {map: PackedByteArray, color: Color, selected: bool} per slot, in slot order.
var slots: Array[Dictionary] = []:
	set(s):
		slots = s
		queue_redraw()

## Input notes selected in the window, highlighted as a band across the canvas.
var selected_inputs: PackedInt32Array = PackedInt32Array():
	set(s):
		selected_inputs = s
		queue_redraw()

## While dragging a connection: the dragged inputs, their target outputs (index-aligned; empty
## while the pointer isn't over a target) and the pointer y (local).
var drag_inputs := PackedInt32Array()
var drag_targets := PackedInt32Array()
var drag_to_y := 0.0

var _hover_row := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	tooltip_text = "Drag from a row to connect that input (or the selection) to a Layer key"
	custom_minimum_size.x = 120


func _gui_input(event: InputEvent) -> void:
	if layout == null:
		return
	if event is InputEventMouseMotion:
		_set_hover_row(layout.y_to_pitch(event.position.y))
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var note := layout.y_to_pitch(event.position.y)
		if note >= 0 and note <= 127:
			row_pressed.emit(note)
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_set_hover_row(-1)


func _set_hover_row(note: int) -> void:
	if note != _hover_row:
		_hover_row = note
		queue_redraw()


func _on_layout_changed() -> void:
	update_minimum_size()
	queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(custom_minimum_size.x, layout.total_height() if layout else 0.0)


func set_drag(inputs: PackedInt32Array, targets: PackedInt32Array, to_y: float) -> void:
	drag_inputs = inputs
	drag_targets = targets
	drag_to_y = to_y
	queue_redraw()


func _draw() -> void:
	if layout == null:
		return
	if _hover_row >= 0 and drag_inputs.is_empty():
		draw_rect(Rect2(0, layout.pitch_to_y(_hover_row), size.x, layout.row_height), HOVER_ROW_COLOR)
	for input in selected_inputs:
		draw_rect(Rect2(0, layout.pitch_to_y(input), size.x, layout.row_height), SELECTED_INPUT_COLOR)
	# Faded slots first so the selected slot's lines sit on top.
	for pass_selected in [false, true]:
		for slot in slots:
			if slot.selected != pass_selected:
				continue
			var map: PackedByteArray = slot.map
			if LayerNoteMap.is_full(map):
				continue
			var color: Color = slot.color
			if not pass_selected:
				color.a = FADED_ALPHA
			for input in LayerNoteMap.inputs(map):
				var a := Vector2(0, layout.pitch_to_y_center(input))
				var b := Vector2(size.x, layout.pitch_to_y_center(map[input]))
				_draw_link(a, b, color)
	for i in drag_inputs.size():
		var start := Vector2(0, layout.pitch_to_y_center(drag_inputs[i]))
		if i < drag_targets.size():
			var end := Vector2(size.x, layout.pitch_to_y_center(drag_targets[i]))
			_draw_link(start, end, DRAG_COLOR)
			draw_circle(end - Vector2(3, 0), 3.0, DRAG_COLOR)
		else:
			_draw_link(start, Vector2(size.x, drag_to_y), Color(DRAG_COLOR, 0.5))


## A soft S-curve from `a` to `b`, so parallel mappings stay readable.
func _draw_link(a: Vector2, b: Vector2, color: Color) -> void:
	if is_equal_approx(a.y, b.y):
		draw_line(a, b, color, LINE_WIDTH, true)
		return
	var points := PackedVector2Array()
	var steps := 12
	for i in steps + 1:
		var t := float(i) / steps
		var eased := t * t * (3.0 - 2.0 * t)
		points.append(Vector2(lerpf(a.x, b.x, t), lerpf(a.y, b.y, eased)))
	draw_polyline(points, color, LINE_WIDTH, true)
