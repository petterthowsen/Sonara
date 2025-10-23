# A rotary knob UI control
# Draws:
# - Semicircular (arc) progressbar showing current value
# - Knob offset inside tha progressbar
@tool
class_name RotaryKnob extends Control

signal value_changed(new_value: float)

var _dragging := false
var _drag_start_y := 0.0
var _drag_start_value := 0.0

@export var min_value := 0.0:
	set(mv):
		min_value = mv
		if is_inside_tree():
			queue_redraw()

@export var max_value := 1.0:
	set(mv):
		max_value = mv
		if is_inside_tree():
			queue_redraw()

@export var value := 0.5:
	set(v):
		if value != v:
			value = clamp(v, min_value, max_value)
			value_changed.emit(value)
			if is_inside_tree():
				queue_redraw()

@export var value_default := 0.5

@export var knob_color := Color.DIM_GRAY:
	set(c):
		knob_color = c
		if is_inside_tree():
			queue_redraw()

@export var shadow_color := Color.BLACK:
	set(c):
		shadow_color = c
		if is_inside_tree():
			queue_redraw()

# Rotation angles in degrees
# 0° is up, -90° is left, 90° is right
# Default: -120° to 120° (240° total range, like Bitwig)
@export var min_rotation_deg := -120.0:
	set(r):
		min_rotation_deg = r
		if is_inside_tree():
			queue_redraw()

@export var max_rotation_deg := 120.0:
	set(r):
		max_rotation_deg = r
		if is_inside_tree():
			queue_redraw()

# a small line drawn on the edge of the knob circle to signify its orientation,
# hence its value
@export var knob_line_color := Color.LIGHT_GRAY:
	set(c):
		knob_line_color = c
		if is_inside_tree():
			queue_redraw()

@export var value_arc_bg := Color.GRAY:
	set(c):
		value_arc_bg = c
		if is_inside_tree():
			queue_redraw()

@export var value_arc_color := Color.ORANGE:
	set(c):
		value_arc_color = c
		if is_inside_tree():
			queue_redraw()

@export var arc_width := 3.0:
	set(w):
		arc_width = w
		if is_inside_tree():
			queue_redraw()

@export var arc_offset := 2.0:
	set(o):
		arc_offset = o
		if is_inside_tree():
			queue_redraw()

@export var knob_line_width := 2.0:
	set(w):
		knob_line_width = w
		if is_inside_tree():
			queue_redraw()

@export var drag_sensitivity := 0.005:
	set(s):
		drag_sensitivity = s


func _ready():
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _draw():
	var rect := get_rect()
	var center := rect.size / 2.0
	var radius: float = min(rect.size.x, rect.size.y) / 2.0
	
	# Arc radius (slightly larger than knob)
	var arc_radius: float = radius - arc_width / 2.0
	var knob_radius: float = arc_radius - arc_width - arc_offset
	
	# Convert degrees to radians and adjust for 0° being up (subtract 90°)
	var min_rotation_rad: float = deg_to_rad(min_rotation_deg - 90.0)
	var max_rotation_rad: float = deg_to_rad(max_rotation_deg - 90.0)
	
	# Draw background arc
	draw_arc(center, arc_radius, min_rotation_rad, max_rotation_rad, 32, value_arc_bg, arc_width, false)
	
	# Draw value arc
	var value_normalized: float = (value - min_value) / (max_value - min_value)
	var value_angle: float = lerp(min_rotation_rad, max_rotation_rad, value_normalized)
	draw_arc(center, arc_radius, min_rotation_rad, value_angle, 32, value_arc_color, arc_width, false)
	
	# Draw shadow (offset slightly)
	var shadow_offset := Vector2(0, 0)
	draw_circle(center + shadow_offset, knob_radius + 1, shadow_color)
	
	# Draw knob
	draw_circle(center, knob_radius, knob_color)
	
	# Draw indicator line
	var line_start: Vector2 = center + Vector2.from_angle(value_angle) * (knob_radius * 0.3)
	var line_end: Vector2 = center + Vector2.from_angle(value_angle) * (knob_radius * 0.9)
	draw_line(line_start, line_end, knob_line_color, knob_line_width, true)


func set_value_no_signal(v: float):
	if value != v:
		value = clamp(v, min_value, max_value)
		if is_inside_tree():
			queue_redraw()


func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				# Double-click or Ctrl+click to reset to default
				if event.double_click or event.ctrl_pressed:
					value = value_default
				else:
					_dragging = true
					_drag_start_y = event.position.y
					_drag_start_value = value
			else:
				_dragging = false
	elif event is InputEventMouseMotion:
		if _dragging:
			# Vertical drag to change value
			var delta_y: float = _drag_start_y - event.position.y
			var value_range: float = max_value - min_value
			var delta_value: float = delta_y * drag_sensitivity * value_range
			value = _drag_start_value + delta_value
