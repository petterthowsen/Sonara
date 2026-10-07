# A horizontal slider control for two values along
# a filled bar is drawn between the a_value and the b_value.
# if a_value is further right than b_value, an alternative color is used.

# Use case: Dual Panning, I.E separate left/right panning.
@tool
class_name HDualSlider extends Control

signal a_value_changed(new_value: float)
signal b_value_changed(new_value: float)
signal values_changed(a_value : float, b_value : float)
signal drag_started
signal drag_ended
## A fill (both-handle) drag moved by `delta`, in value units, from where the drag began.
## Unclamped: a and b clamp individually, so a listener can keep the pair's real offset.
signal pair_dragged(delta: float)
## A single handle was dragged to `value`. `which` is DragMode.A_VALUE or DragMode.B_VALUE.
signal handle_dragged(which: int, value: float)

## PENDING: overlapped handles with Alt held; the first mouse motion picks the handle.
enum DragMode { NONE, A_VALUE, B_VALUE, BOTH, PENDING }
var _drag_mode := DragMode.NONE
var _fine_drag := FineDrag.new()
var _drag_start_a := 0.0
var _drag_start_b := 0.0
var _drag_start_x := 0.0

@export var min_value := -1.0:
	set(mv):
		min_value = mv
		if is_inside_tree():
			queue_redraw()

@export var max_value := 1.0:
	set(mv):
		max_value = mv
		if is_inside_tree():
			queue_redraw()

var _a_value : float = -0.5
@export var a_value : float:
	set(v):
		if _a_value != v:
			_a_value = clamp(v, min_value, max_value)
			a_value_changed.emit(a_value)
			values_changed.emit(a_value, b_value)
			if is_inside_tree():
				queue_redraw()
	get:
		return _a_value

var _b_value : float
@export var b_value := 0.5:
	set(v):
		if _b_value != v:
			_b_value = clamp(v, min_value, max_value)
			b_value_changed.emit(_b_value)
			values_changed.emit(a_value, b_value)
			if is_inside_tree():
				queue_redraw()
	get:
		return _b_value

func set_values_no_signal(a : float, b : float):
	_a_value = clampf(a, min_value, max_value)
	_b_value = clampf(b, min_value, max_value)
	if is_inside_tree():
		queue_redraw()

var _tc := ThemedColors.new(self, &"HDualSlider")
var bg_color: Color:
	get:
		return _tc.get_color(&"bg")
	set(c):
		_tc.set_color(&"bg", c)
var fill_color: Color:
	get:
		return _tc.get_color(&"fill")
	set(c):
		_tc.set_color(&"fill", c)
var alt_fill_color: Color:
	get:
		return _tc.get_color(&"alt_fill")
	set(c):
		_tc.set_color(&"alt_fill", c)

@export var handle_width := 4.0:
	set(hw):
		handle_width = hw
		if is_inside_tree():
			queue_redraw()

var handle_color: Color:
	get:
		return _tc.get_color(&"handle")
	set(c):
		_tc.set_color(&"handle", c)

func _ready():
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func _draw():
	var rect := get_rect()
	
	# draw background
	draw_rect(Rect2(Vector2(0, 0), rect.size), bg_color, true, -1.0, false)
	
	# Calculate positions
	var value_range: float = max_value - min_value
	var a_normalized: float = (a_value - min_value) / value_range
	var b_normalized: float = (b_value - min_value) / value_range
	
	var a_x: float = a_normalized * rect.size.x
	var b_x: float = b_normalized * rect.size.x
	
	# Draw filled bar between a and b
	var left_x: float = min(a_x, b_x)
	var right_x: float = max(a_x, b_x)
	var width: float = right_x - left_x
	
	# Use alt color if a_value > b_value (crossed)
	var color := alt_fill_color if a_value > b_value else fill_color
	draw_rect(Rect2(left_x, 0, width, rect.size.y), color, true, -1.0, false)
	
	# Draw handles for a_value and b_value (clamped to stay within bounds)
	var handle_half := handle_width / 2.0
	var a_handle_x: float = clamp(a_x - handle_half, 0, rect.size.x - handle_width)
	var b_handle_x: float = clamp(b_x - handle_half, 0, rect.size.x - handle_width)
	draw_rect(Rect2(a_handle_x, 0, handle_width, rect.size.y), handle_color, true, -1.0, false)
	draw_rect(Rect2(b_handle_x, 0, handle_width, rect.size.y), handle_color, true, -1.0, false)


func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_drag(event.position, event.alt_pressed)
			elif _drag_mode != DragMode.NONE:
				_drag_mode = DragMode.NONE
				drag_ended.emit()
	elif event is InputEventMouseMotion:
		if _drag_mode == DragMode.PENDING:
			if is_zero_approx(event.relative.x):
				return
			# Toward the left picks the left-most handle, toward the right the right-most.
			var a_is_left := a_value <= b_value
			_drag_mode = DragMode.A_VALUE if (event.relative.x < 0.0) == a_is_left else DragMode.B_VALUE
		if _drag_mode != DragMode.NONE:
			_update_from_mouse(_fine_drag.update(event.position, event.shift_pressed, _drag_bounds()))


## A press within this many pixels of a handle grabs it.
func grab_radius() -> float:
	return handle_width * 2.0


func _value_to_x(value: float) -> float:
	return (value - min_value) / (max_value - min_value) * size.x


## Both-handle drags are unclamped so the pair's offset survives a handle hitting an edge.
func _drag_bounds() -> Rect2:
	if _drag_mode == DragMode.BOTH:
		return Rect2()
	return Rect2(Vector2.ZERO, size)


## What a press at local `pos` grabs: a handle within the grab radius, both handles when it
## lands on the fill or on overlapped handles (PENDING with `alt`), and the nearest handle
## anywhere else. Hover readouts use it too, so they name what a press would move.
func pick_at(pos: Vector2, alt := false) -> DragMode:
	var a_x := _value_to_x(a_value)
	var b_x := _value_to_x(b_value)
	var dist_a := absf(pos.x - a_x)
	var dist_b := absf(pos.x - b_x)
	var near_a := dist_a <= grab_radius()
	var near_b := dist_b <= grab_radius()
	var on_fill := pos.x > minf(a_x, b_x) and pos.x < maxf(a_x, b_x)

	if near_a and near_b:
		return DragMode.PENDING if alt else DragMode.BOTH
	if near_a:
		return DragMode.A_VALUE
	if near_b:
		return DragMode.B_VALUE
	if on_fill:
		return DragMode.BOTH
	return DragMode.A_VALUE if dist_a < dist_b else DragMode.B_VALUE


## The active drag, or NONE between drags.
func get_drag_mode() -> DragMode:
	return _drag_mode


func _begin_drag(pos: Vector2, alt: bool) -> void:
	_drag_mode = pick_at(pos, alt)

	_drag_start_a = a_value
	_drag_start_b = b_value
	_drag_start_x = pos.x
	drag_started.emit()
	var point := _fine_drag.begin(pos)
	# A handle jumps to the press; a pair drag or a pending pick moves nothing yet.
	if _drag_mode == DragMode.A_VALUE or _drag_mode == DragMode.B_VALUE:
		_update_from_mouse(point)


func _update_from_mouse(point: Vector2) -> void:
	var value_range := max_value - min_value
	if _drag_mode == DragMode.BOTH:
		var delta := (point.x - _drag_start_x) / size.x * value_range
		_set_both(_drag_start_a + delta, _drag_start_b + delta)
		pair_dragged.emit(delta)
		return
	var new_value := min_value + clampf(point.x / size.x, 0.0, 1.0) * value_range
	if _drag_mode == DragMode.A_VALUE:
		a_value = new_value
	elif _drag_mode == DragMode.B_VALUE:
		b_value = new_value
	else:
		return
	handle_dragged.emit(_drag_mode, new_value)


## Move both handles as one change: a single values_changed, so listeners see no half step.
func _set_both(a: float, b: float) -> void:
	a = clampf(a, min_value, max_value)
	b = clampf(b, min_value, max_value)
	var a_changed := a != _a_value
	var b_changed := b != _b_value
	if not a_changed and not b_changed:
		return
	_a_value = a
	_b_value = b
	if a_changed:
		a_value_changed.emit(a)
	if b_changed:
		b_value_changed.emit(b)
	values_changed.emit(a, b)
	if is_inside_tree():
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_tc.refresh()
		queue_redraw()
