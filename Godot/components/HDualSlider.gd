# A horizontal slider control for two values along
# a filled bar is drawn between the a_value and the b_value.
# if a_value is further right than b_value, an alternative color is used.

# Use case: Dual Panning, I.E separate left/right panning.
@tool
class_name HDualSlider extends Control

signal a_value_changed(new_value: float)
signal b_value_changed(new_value: float)
signal values_changed(a_value : float, b_value : float)

enum DragMode { NONE, A_VALUE, B_VALUE }
var _drag_mode := DragMode.NONE

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
	_a_value = a
	_b_value = b

@export var bg_color := Color.BLACK
@export var fill_color := Color.DARK_ORANGE
@export var alt_fill_color := Color.DARK_RED  # Used when a_value > b_value

@export var handle_width := 4.0:
	set(hw):
		handle_width = hw
		if is_inside_tree():
			queue_redraw()

@export var handle_color := Color.WHITE:
	set(hc):
		handle_color = hc
		if is_inside_tree():
			queue_redraw()

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
				# Determine which handle is closer to the click
				var rect := get_rect()
				var value_range: float = max_value - min_value
				var a_normalized: float = (a_value - min_value) / value_range
				var b_normalized: float = (b_value - min_value) / value_range
				var a_x: float = a_normalized * rect.size.x
				var b_x: float = b_normalized * rect.size.x
				
				var dist_to_a: float = abs(event.position.x - a_x)
				var dist_to_b: float = abs(event.position.x - b_x)
				
				if dist_to_a < dist_to_b:
					_drag_mode = DragMode.A_VALUE
				else:
					_drag_mode = DragMode.B_VALUE
				
				_update_value_from_mouse(event.position)
			else:
				_drag_mode = DragMode.NONE
	elif event is InputEventMouseMotion:
		if _drag_mode != DragMode.NONE:
			_update_value_from_mouse(event.position)


func _update_value_from_mouse(mouse_pos: Vector2):
	var rect := get_rect()
	var normalized: float = clamp(mouse_pos.x / rect.size.x, 0.0, 1.0)
	var new_value := min_value + normalized * (max_value - min_value)
	
	if _drag_mode == DragMode.A_VALUE:
		a_value = new_value
	elif _drag_mode == DragMode.B_VALUE:
		b_value = new_value
