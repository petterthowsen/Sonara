@tool
## Horizontal slider with optional snapping and Ctrl/Cmd-click reset to default.
class_name HorSlider extends Control

signal value_changed(new_value: float)
signal drag_started
signal drag_ended

var _dragging := false

@export var min_value := 0.0:
	set(mv):
		min_value = mv
		if is_inside_tree():
			queue_redraw()

@export var max_value := 0.0:
	set(mv):
		max_value = mv
		if is_inside_tree():
			queue_redraw()

var _value := 0.0

@export var value := 0.0:
	set(v):
		var snapped := _apply_step_and_clamp(v)
		if _value != snapped:
			_value = snapped
			value_changed.emit(value)
			if is_inside_tree():
				queue_redraw()
	get:
		return _value

## Value restored by Ctrl/Cmd-click.
@export var default_value := 0.0:
	set(dv):
		default_value = dv
		if is_inside_tree():
			queue_redraw()

## Quantize increments; `0` keeps the slider continuous.
@export var step := 0.0:
	set(s):
		step = maxf(s, 0.0)
		var snapped := _apply_step_and_clamp(_value)
		if _value != snapped:
			_value = snapped
			if is_inside_tree():
				queue_redraw()

## Set the value without emitting `value_changed`.
func set_value_no_signal(val: float) -> void:
	_value = _apply_step_and_clamp(val)
	if is_inside_tree():
		queue_redraw()

# When bidirectional, the middle value is centered visually
@export var bidirectional := true:
	set(b):
		bidirectional = b
		if is_inside_tree():
			queue_redraw()

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


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _draw() -> void:
	var rect := get_rect()
	
	# draw background
	draw_rect(Rect2(0, 0, size.x, size.y), bg_color, true, -1.0, true)
	
	var value_normalized = value / max_value
	
	# draw filled bar
	var value_x: float
	if bidirectional:
		# fill from center to either edge
		var h = rect.size.y
		var w = value_normalized * rect.size.x / 2
		draw_rect(Rect2(rect.size.x / 2, 0, w, h), fill_color, true, -1.0, true)
		value_x = rect.size.x / 2 + w
	else:
		# fill from left to right
		var h = rect.size.y
		var w = value_normalized * rect.size.x
		draw_rect(Rect2(0, 0, w, h), fill_color, true, -1.0, true)
		value_x = w
	
	# Draw handle at value position (clamped to stay within bounds)
	var handle_half := handle_width / 2.0
	var handle_x: float = clamp(value_x - handle_half, 0, rect.size.x - handle_width)
	draw_rect(Rect2(handle_x, 0, handle_width, rect.size.y), handle_color, true, -1.0, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.is_command_or_control_pressed():
					value = default_value
					_dragging = false
					accept_event()
					return
				_dragging = true
				drag_started.emit()
				_update_value_from_mouse(event.position)
			else:
				if _dragging:
					_dragging = false
					drag_ended.emit()
	elif event is InputEventMouseMotion:
		if _dragging:
			_update_value_from_mouse(event.position)


## Map a mouse x position onto the slider range.
func _update_value_from_mouse(mouse_pos: Vector2) -> void:
	var rect := get_rect()
	var normalized: float = clamp(mouse_pos.x / rect.size.x, 0.0, 1.0)
	
	if bidirectional:
		# Map from [0, 1] to [-max_value, max_value]
		# Center is at 0.5
		value = (normalized - 0.5) * 2.0 * max_value
	else:
		# Map from [0, 1] to [min_value, max_value]
		value = min_value + normalized * (max_value - min_value)


## Snap to `step` (when set) and clamp to the active range.
func _apply_step_and_clamp(v: float) -> float:
	var lo := -max_value if bidirectional else min_value
	var hi := max_value
	var snapped := v
	if step > 0.0:
		snapped = round(v / step) * step
	return clampf(snapped, lo, hi)
