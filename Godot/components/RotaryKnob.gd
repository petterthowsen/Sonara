## Rotary knob with an arc value indicator and a hover/edit value tooltip.
@tool
class_name RotaryKnob extends Control

signal value_changed(new_value: float)

var _value := 0.5
var _dragging := false
var _hovering := false
var _tooltip: PanelContainer = null
var _tooltip_label: Label = null

@export var min_value := 0.0:
	set(mv):
		min_value = mv
		_set_value(_value, false)
		if is_inside_tree():
			queue_redraw()

@export var max_value := 1.0:
	set(mv):
		max_value = mv
		_set_value(_value, false)
		if is_inside_tree():
			queue_redraw()

@export var value := 0.5:
	set(v):
		_set_value(v, true)
	get:
		return _value

@export var value_default := 0.5

## When true, drag and the arc map the value logarithmically between min and max.
@export var logarithmic := false:
	set(v):
		logarithmic = v
		if is_inside_tree():
			queue_redraw()

@export var show_value_tooltip := true

## Used when `value_text_callback` is empty. `unit` is appended when set.
@export var value_format := "%.2f"

@export var unit := ""

## Optional Callable(value: float) -> String. Overrides value_format/unit.
var value_text_callback: Callable

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

@export var fine_drag_scale := 0.15


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if not mouse_entered.is_connected(_on_mouse_entered):
		mouse_entered.connect(_on_mouse_entered)
	if not mouse_exited.is_connected(_on_mouse_exited):
		mouse_exited.connect(_on_mouse_exited)


## Set the value without emitting `value_changed`.
func set_value_no_signal(v: float) -> void:
	_set_value(v, false)


## Format the current value for the tooltip.
func get_value_text() -> String:
	if value_text_callback.is_valid():
		return str(value_text_callback.call(_value))
	var text := value_format % _value
	return text if unit.is_empty() else "%s %s" % [text, unit]


func _set_value(v: float, emit_change: bool) -> void:
	var clamped := clampf(v, min_value, max_value)
	if is_equal_approx(_value, clamped):
		return
	_value = clamped
	if is_inside_tree():
		queue_redraw()
	_refresh_tooltip()
	if emit_change:
		value_changed.emit(_value)


func _draw() -> void:
	var center := size / 2.0
	var radius: float = minf(size.x, size.y) / 2.0
	var arc_radius: float = radius - arc_width / 2.0
	var knob_radius: float = arc_radius - arc_width - arc_offset
	var min_rotation_rad: float = deg_to_rad(min_rotation_deg - 90.0)
	var max_rotation_rad: float = deg_to_rad(max_rotation_deg - 90.0)
	draw_arc(center, arc_radius, min_rotation_rad, max_rotation_rad, 32, value_arc_bg, arc_width, false)
	var value_angle: float = lerpf(min_rotation_rad, max_rotation_rad, _value_to_normalized(_value))
	draw_arc(center, arc_radius, min_rotation_rad, value_angle, 32, value_arc_color, arc_width, false)
	draw_circle(center, knob_radius + 1.0, shadow_color)
	draw_circle(center, knob_radius, knob_color)
	var line_start: Vector2 = center + Vector2.from_angle(value_angle) * (knob_radius * 0.3)
	var line_end: Vector2 = center + Vector2.from_angle(value_angle) * (knob_radius * 0.9)
	draw_line(line_start, line_end, knob_line_color, knob_line_width, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click or mb.ctrl_pressed:
					value = value_default
				else:
					_dragging = true
					_refresh_tooltip()
			else:
				_dragging = false
				_refresh_tooltip()
	elif event is InputEventMouseMotion:
		if _dragging:
			var motion := event as InputEventMouseMotion
			var drag_scale: float = fine_drag_scale if motion.shift_pressed else 1.0
			var new_n: float = _value_to_normalized(_value) + (-motion.relative.y) * drag_sensitivity * drag_scale
			value = _normalized_to_value(new_n)


func _on_mouse_entered() -> void:
	_hovering = true
	_refresh_tooltip()


func _on_mouse_exited() -> void:
	_hovering = false
	_refresh_tooltip()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_EXIT_TREE:
		if not is_visible_in_tree() and _tooltip:
			_tooltip.visible = false
			set_process(false)


func _process(_delta: float) -> void:
	if _tooltip and _tooltip.visible:
		_position_tooltip()
	else:
		set_process(false)


## Map a real value onto 0–1, using log scaling when enabled.
func _value_to_normalized(v: float) -> float:
	if max_value <= min_value:
		return 0.0
	if logarithmic and min_value > 0.0:
		if v <= min_value:
			return 0.0
		return clampf(log(v / min_value) / log(max_value / min_value), 0.0, 1.0)
	return clampf((v - min_value) / (max_value - min_value), 0.0, 1.0)


## Inverse of `_value_to_normalized`.
func _normalized_to_value(normalized: float) -> float:
	var n := clampf(normalized, 0.0, 1.0)
	if logarithmic and min_value > 0.0:
		return min_value * pow(max_value / min_value, n)
	return min_value + n * (max_value - min_value)


## Show, hide, or update the value tooltip for hover and live dragging.
func _refresh_tooltip() -> void:
	if not show_value_tooltip or not is_inside_tree():
		if _tooltip:
			_tooltip.visible = false
		set_process(false)
		return
	var should_show := _hovering or _dragging
	if not should_show:
		if _tooltip:
			_tooltip.visible = false
		set_process(false)
		return
	_ensure_tooltip()
	_tooltip_label.text = get_value_text()
	_tooltip.visible = true
	_tooltip.reset_size()
	_position_tooltip()
	set_process(true)


## Create the floating value label once, as an unsaved internal child.
func _ensure_tooltip() -> void:
	if _tooltip != null:
		return
	_tooltip = PanelContainer.new()
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.top_level = true
	_tooltip.z_index = 128
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.94)
	style.border_color = Color(1, 1, 1, 0.12)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	_tooltip.add_theme_stylebox_override("panel", style)
	_tooltip_label = Label.new()
	_tooltip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tooltip_label.add_theme_font_size_override("font_size", 12)
	_tooltip.add_child(_tooltip_label)
	add_child(_tooltip, false, Node.INTERNAL_MODE_BACK)
	_tooltip.visible = false


## Center the tooltip just above the knob in viewport space.
func _position_tooltip() -> void:
	if _tooltip == null or not _tooltip.visible:
		return
	var tip_size := _tooltip.get_combined_minimum_size()
	_tooltip.size = tip_size
	var top_center := global_position + Vector2(size.x * 0.5, 0.0)
	var pos := top_center - Vector2(tip_size.x * 0.5, tip_size.y + 4.0)
	if pos.y < 0.0:
		pos.y = global_position.y + size.y + 4.0
	var view_size := get_viewport_rect().size
	pos.x = clampf(pos.x, 0.0, maxf(view_size.x - tip_size.x, 0.0))
	_tooltip.global_position = pos
