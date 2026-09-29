@tool
## Horizontal slider with optional snapping and Ctrl/Cmd-click reset to default.
class_name HorSlider extends Control

signal value_changed(new_value: float)
## How the change behind the latest `value_changed` was made; read it inside the handler.
var last_edit_kind := ValueEditKind.Kind.DRAG
## Emitted on Ctrl/Cmd-click even when the value is already the default (see `value_changed`).
signal reset_requested
signal drag_started
signal drag_ended

var _dragging := false
var _fine_drag := FineDrag.new()

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


## Draw the handle only while hovered or dragged; the fill alone shows the value otherwise.
@export var handle_on_hover_only := true:
	set(h):
		handle_on_hover_only = h
		if is_inside_tree():
			queue_redraw()

var _hovered := false


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))


## True when the handle is drawn: always, or only while hovered or dragged.
func is_handle_visible() -> bool:
	return not handle_on_hover_only or _hovered or _dragging


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	if handle_on_hover_only:
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_hovered = false


func _draw() -> void:
	var rect := get_rect()
	
	# draw background
	draw_rect(Rect2(0, 0, size.x, size.y), bg_color, true, -1.0, true)
	
	# draw filled bar
	var value_x: float
	if bidirectional:
		# fill from center to either edge
		var h = rect.size.y
		var w = (value / max_value if max_value != 0.0 else 0.0) * rect.size.x / 2
		draw_rect(Rect2(rect.size.x / 2, 0, w, h), fill_color, true, -1.0, true)
		value_x = rect.size.x / 2 + w
	else:
		# fill from left to right
		var h = rect.size.y
		var span := max_value - min_value
		var w = (clampf((value - min_value) / span, 0.0, 1.0) if span != 0.0 else 0.0) * rect.size.x
		draw_rect(Rect2(0, 0, w, h), fill_color, true, -1.0, true)
		value_x = w
	
	if bidirectional:
		# faint center tick, so a centered value still reads while the handle is hidden
		var cx := roundf(rect.size.x / 2.0)
		draw_rect(Rect2(cx - 0.5, 0, 1, rect.size.y), Color(handle_color, handle_color.a * 0.3), true)

	if not is_handle_visible():
		return

	# Draw handle at value position (clamped to stay within bounds)
	var handle_half := handle_width / 2.0
	var handle_x: float = clamp(value_x - handle_half, 0, rect.size.x - handle_width)
	draw_rect(Rect2(handle_x, 0, handle_width, rect.size.y), handle_color, true, -1.0, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.is_command_or_control_pressed():
					last_edit_kind = ValueEditKind.Kind.RESET
					value = default_value
					last_edit_kind = ValueEditKind.Kind.DRAG
					reset_requested.emit()
					_dragging = false
					accept_event()
					return
				_dragging = true
				drag_started.emit()
				_update_value_from_mouse(_fine_drag.begin(event.position))
			else:
				if _dragging:
					_dragging = false
					drag_ended.emit()
					queue_redraw()
	elif event is InputEventMouseMotion:
		if _dragging:
			_update_value_from_mouse(_fine_drag.update(event.position, event.shift_pressed, Rect2(Vector2.ZERO, size)))


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
