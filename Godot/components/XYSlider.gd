# A XY "Pad" slider control for two values along an X/Y axis as a rectangle.
# A single handle is drawn at the X,Y position of the values.

@tool
class_name XYSlider extends Control

@export_group("Display")
@export var handle_radius := 6.0:
	set(hr):
		handle_radius = hr
		if is_inside_tree():
			queue_redraw()

@export var handle_color := Color.WHITE:
	set(hc):
		handle_color = hc
		if is_inside_tree():
			queue_redraw()

@export var bg_color := Color.BLACK:
	set(bc):
		bg_color = bc
		if is_inside_tree():
			queue_redraw()

@export var show_axis_lines := true:
	set(s):
		show_axis_lines = s
		if is_inside_tree():
			queue_redraw()

@export var axis_line_color := Color.WHITE:
	set(ac):
		axis_line_color = ac
		if is_inside_tree():
			queue_redraw()

@export var axis_line_width := 1.0:
	set(aw):
		axis_line_width = aw
		if is_inside_tree():
			queue_redraw()

@export var show_value_labels := true:
	set(s):
		show_value_labels = s
		if is_inside_tree():
			queue_redraw()

@export var value_label_color := Color.WHITE:
	set(vc):
		value_label_color = vc
		if is_inside_tree():
			queue_redraw()

@export var value_label_font_size := 12:
	set(vls):
		value_label_font_size = vls
		if is_inside_tree():
			queue_redraw()

@export_group("Values")
@export var x_min := 0.0:
	set(xm):
		x_min = xm
		if is_inside_tree():
			queue_redraw()

@export var x_max := 1.0:
	set(xm):
		x_max = xm
		if is_inside_tree():
			queue_redraw()

@export var y_min := 0.0:
	set(ym):
		y_min = ym
		if is_inside_tree():
			queue_redraw()

@export var y_max := 1.0:
	set(ym):
		y_max = ym
		if is_inside_tree():
			queue_redraw()

var handle_diameter:
	get:
		return handle_radius * 2.0
	set(hd):
		handle_radius = hd / 2.0
		if is_inside_tree():
			queue_redraw()

@export var value_x: float:
	set(vx):
		vx = clamp(vx, x_min, x_max)
		if _x != vx:
			_x = vx
			x_changed.emit(_x)
			values_changed.emit(_x, _y)
			if is_inside_tree():
				queue_redraw()
	get:
		return _x

@export var value_y: float:
	set(vy):
		vy = clamp(vy, y_min, y_max)
		if _y != vy:
			_y = vy
			y_changed.emit(_y)
			values_changed.emit(_x, _y)
			if is_inside_tree():
				queue_redraw()
	get:
		return _y

var _x := 0.0
var _y := 0.0

var _dragging := false

signal x_changed(new_x: float)
signal y_changed(new_y: float)
signal values_changed(x: float, y: float)


func set_values(new_x: float, new_y: float):
	new_x = clamp(new_x, x_min, x_max)
	new_y = clamp(new_y, y_min, y_max)

	if _x != new_x or _y != new_y:
		if _x != new_x:
			_x = new_x
			x_changed.emit(new_x)
		if _y != new_y:
			_y = new_y
			y_changed.emit(new_y)
		
		values_changed.emit(new_x, new_y)
		if is_inside_tree():
			queue_redraw()


func set_values_no_signal(new_x: float, new_y: float):
	_x = clamp(new_x, x_min, x_max)
	_y = clamp(new_y, y_min, y_max)
	if is_inside_tree():
		queue_redraw()


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_CLICK
	mouse_exited.connect(_on_mouse_exited)


func _get_minimum_size() -> Vector2:
	var s = min(handle_diameter * 2, 32)
	return Vector2(s, s)

func _on_mouse_exited() -> void:
	_dragging = false
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and not _dragging:
				_dragging = true
				_update_value_from_mouse(event.position)
			elif event.is_released():
				_dragging = false
	elif event is InputEventMouseMotion:
		if _dragging:
			_update_value_from_mouse(event.position)


func _update_value_from_mouse(mouse_pos: Vector2):
	var x = remap(mouse_pos.x, 0, size.x, x_min, x_max)
	var y = remap(mouse_pos.y, size.y, 0, y_min, y_max) 
	set_values(x, y)


func get_handle_rect() -> Rect2:
	var x = remap(_x, x_min, x_max, handle_radius, size.x - handle_radius)
	var y = remap(_y, y_min, y_max, size.y - handle_radius, handle_radius)

	return Rect2(
		x - handle_radius,
		y - handle_radius,
		handle_diameter,
		handle_diameter
	)


func _draw():
	var x = remap(_x, x_min, x_max, handle_radius, size.x - handle_radius)
	var y = remap(_y, y_min, y_max, size.y - handle_radius, handle_radius)

	# draw background
	draw_rect(Rect2(0, 0, size.x, size.y), bg_color, true, -1.0, false)

	# draw axis lines
	if show_axis_lines:
		draw_line(Vector2(0, size.y / 2), Vector2(size.x, size.y / 2), axis_line_color, axis_line_width, true)
		draw_line(Vector2(size.x/2, 0), Vector2(size.x / 2, size.y), axis_line_color, axis_line_width, true)

	# draw handle
	draw_circle(Vector2(x, y), handle_radius, handle_color)

	# draw value labels
	#if show_value_labels:
	#	draw_string(get_theme_default_font(), Vector2(x - 10, y - 10), str(_x), HORIZONTAL_ALIGNMENT_LEFT, -1.0, value_label_font_size, value_label_color)
	#	draw_string(get_theme_default_font(), Vector2(x - 10, y + 10), str(_y), HORIZONTAL_ALIGNMENT_LEFT, -1.0, value_label_font_size, value_label_color)
