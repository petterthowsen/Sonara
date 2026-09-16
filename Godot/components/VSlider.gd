@tool 
class_name VolumeSlider extends Control

@onready var smart_line_edit: SmartLineEdit = $SmartLineEdit

signal value_changed(new_value: float)

var _dragging := false
var _value := 0.0  # Internal backing field
var _mouse_hovered := false
var _last_click_time := 0.0
var _double_click_threshold := 0.4  # 400ms
var _last_drag_mouse_pos := Vector2.ZERO
@export var fine_drag_scale := 0.15

@export var min_value := -60.0:
	set(mv):
		min_value = mv
		if is_inside_tree():
			queue_redraw()

@export var max_value := 6.0:
	set(mv):
		max_value = mv
		if is_inside_tree():
			queue_redraw()

@export var value := 0.0:
	set(v):
		if _value != v:
			_value = v
			value_changed.emit(_value)
			if is_inside_tree():
				smart_line_edit.set_value(_value)
				queue_redraw()
	get:
		return _value

@export var bg_color := Color.BLACK:
	set(c):
		bg_color = c
		if is_inside_tree():
			queue_redraw()

@export var fill_color := Color.DARK_ORANGE:
	set(c):
		fill_color = c
		if is_inside_tree():
			queue_redraw()

@export var handle_height := 4.0:
	set(hh):
		handle_height = hh
		if is_inside_tree():
			queue_redraw()

@export var handle_color := Color.WHITE:
	set(hc):
		handle_color = hc
		if is_inside_tree():
			queue_redraw()


func set_value_no_signal(v: float) -> void:
	"""Set value without emitting value_changed signal."""
	if _value != v:
		_value = v
		smart_line_edit.set_value(value)
		if is_inside_tree():
			queue_redraw()

func _ready():
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	
	smart_line_edit.value_changed.connect(_on_smart_value_changed)
	smart_line_edit.set_value(value)
	queue_redraw()

func _on_smart_value_changed(val):
	value = val

func _draw():
	var rect := get_rect()
	
	# draw background (use Rect2 starting at 0,0)
	draw_rect(Rect2(0, 0, rect.size.x, rect.size.y), bg_color, true, -1.0, false)
	
	var value_normalized: float = (value - min_value) / (max_value - min_value)
	
	# draw filled bar
	var value_y: float
	# fill from bottom to top
	var w: float = rect.size.x
	var h: float = value_normalized * rect.size.y
	draw_rect(Rect2(0, rect.size.y - h, w, h), fill_color, true, -1.0, false)
	value_y = rect.size.y - h
	
	# Draw handle at value position (clamped to stay within bounds) - only if mouse is hovered
	if _mouse_hovered:
		var handle_half: float = handle_height / 2.0
		var handle_y: float = clamp(value_y - handle_half, 0, rect.size.y - handle_height)
		draw_rect(Rect2(0, handle_y, rect.size.x, handle_height), handle_color, true, -1.0, false)


func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var current_time = Time.get_ticks_msec() / 1000.0
				if current_time - _last_click_time < _double_click_threshold:
					# Double-click detected
					smart_line_edit.start_editing()
					_dragging = false
				else:
					# Single click - start dragging
					_dragging = true
					_last_drag_mouse_pos = event.position
					_update_value_from_mouse(event.position)
				_last_click_time = current_time
			else:
				_dragging = false
	elif event is InputEventMouseMotion:
		if _dragging:
			if event.shift_pressed:
				_update_value_from_mouse_relative(event.position)
			else:
				_update_value_from_mouse(event.position)
			_last_drag_mouse_pos = event.position


func _update_value_from_mouse(mouse_pos: Vector2):
	var rect := get_rect()

	# Invert Y coordinate so bottom = 0, top = 1
	var normalized: float = clamp(1.0 - (mouse_pos.y / rect.size.y), 0.0, 1.0)

	# Map from [0, 1] to [min_value, max_value]
	value = remap(normalized, 0, 1, min_value, max_value)


## Fine adjustment: scale the mouse movement instead of jumping to its position.
func _update_value_from_mouse_relative(mouse_pos: Vector2):
	var rect := get_rect()

	var delta_normalized: float = -(mouse_pos.y - _last_drag_mouse_pos.y) / rect.size.y * fine_drag_scale
	var current_normalized: float = (value - min_value) / (max_value - min_value)
	var normalized: float = clamp(current_normalized + delta_normalized, 0.0, 1.0)

	value = remap(normalized, 0, 1, min_value, max_value)


func _on_mouse_entered():
	_mouse_hovered = true
	queue_redraw()


func _on_mouse_exited():
	_mouse_hovered = false
	queue_redraw()
