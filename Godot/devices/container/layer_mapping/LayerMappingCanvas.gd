## Middle column of the Layer mapping window (docs/specs/006-layer-note-mapping, REQ-010): one
## line per mapped input → output note, drawn between the input piano (left edge) and the output
## piano (right edge). The selected slot's lines are bright; other zoned slots' lines are faded.
## Full-map slots draw nothing here (the window says "all notes" instead). Draw-only: input
## handling lives in LayerMappingWindow.
class_name LayerMappingCanvas extends Control

const LINE_WIDTH := 2.0
const FADED_ALPHA := 0.18
const SELECTED_INPUT_COLOR := Color(1.0, 1.0, 1.0, 0.12)

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

## While dragging a connection: the input note it started from and the pointer y (local), or -1.
var drag_from_input := -1
var drag_to_y := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size.x = 120


func _on_layout_changed() -> void:
	update_minimum_size()
	queue_redraw()


func _get_minimum_size() -> Vector2:
	return Vector2(custom_minimum_size.x, layout.total_height() if layout else 0.0)


func set_drag(from_input: int, to_y: float) -> void:
	drag_from_input = from_input
	drag_to_y = to_y
	queue_redraw()


func _draw() -> void:
	if layout == null:
		return
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
	if drag_from_input >= 0:
		var start := Vector2(0, layout.pitch_to_y_center(drag_from_input))
		_draw_link(start, Vector2(size.x, drag_to_y), Color(1, 1, 1, 0.8))


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
