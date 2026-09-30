@tool 
class_name VolumeSlider extends Control

@onready var smart_line_edit: SmartLineEdit = $SmartLineEdit

signal value_changed(new_value: float)

var _dragging := false
var _value := 0.0  # Internal backing field
var _mouse_hovered := false
var _last_click_time := 0.0
var _double_click_threshold := 0.4  # 400ms
@export var fine_drag_scale := FineDrag.DEFAULT_SCALE
var _fine_drag := FineDrag.new()

## Emitted while `mod_assign_active` and the user drags (or double-clicks, which asks for 0).
## The value itself doesn't change. See `ModDisplay`.
signal mod_amount_changed(new_amount: float)

## Routes into this value: `{amount, color, source, bipolar}`.
var mod_ranges: Array[Dictionary] = []:
	set(r):
		mod_ranges = r
		queue_redraw()

## While true, dragging edits the modulation amount instead of the value.
var mod_assign_active := false:
	set(a):
		mod_assign_active = a
		_mod_dragging = false
		queue_redraw()

var mod_assign_color := Color.WHITE:
	set(c):
		mod_assign_color = c
		queue_redraw()

## Amount of the route being edited; the owner keeps it in sync, drags advance it.
var mod_assign_amount := 0.0

## Optional Callable(amount: float) -> String for the assign tooltip (e.g. "+1.2 oct").
var mod_amount_text_callback: Callable

## Live modulated positions (0..1) while playing, drawn as thin markers.
var mod_live_values := PackedFloat32Array():
	set(v):
		mod_live_values = v
		queue_redraw()

var _mod_dragging := false
var _mod_tooltip: ValueTooltip = null

const MOD_BAR := 3.0

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
	
	_draw_modulation()

	# Draw handle at value position (clamped to stay within bounds) - only if mouse is hovered
	if _mouse_hovered:
		var handle_half: float = handle_height / 2.0
		var handle_y: float = clamp(value_y - handle_half, 0, rect.size.y - handle_height)
		draw_rect(Rect2(0, handle_y, rect.size.x, handle_height), handle_color, true, -1.0, false)


## Value position as 0..1 up the track.
func _norm_value() -> float:
	return clampf((value - min_value) / (max_value - min_value), 0.0, 1.0) if max_value != min_value else 0.0


## Route bars down the right edge (one column per route), live markers, and an assign outline.
func _draw_modulation() -> void:
	var base := _norm_value()
	for i in mod_ranges.size():
		var route := mod_ranges[i]
		var band := ModDisplay.span(base, float(route["amount"]), bool(route.get("bipolar", false)))
		if band.y - band.x < 0.002:
			continue
		draw_rect(Rect2(size.x - (i + 1) * MOD_BAR, (1.0 - band.y) * size.y, MOD_BAR, (band.y - band.x) * size.y),
			route["color"], true)
	for live in mod_live_values:
		draw_rect(Rect2(0, (1.0 - clampf(live, 0.0, 1.0)) * size.y - 0.5, size.x, 1.5), ModDisplay.LIVE_MARKER_COLOR, true)
	if mod_assign_active:
		draw_rect(Rect2(Vector2.ZERO, size), Color(mod_assign_color, 0.9), false, 1.5)


## Assign mode input: drags edit the amount, double-click removes the route.
func _mod_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click:
				mod_assign_amount = 0.0
				mod_amount_changed.emit(0.0)
			else:
				_mod_dragging = true
			_refresh_mod_tooltip()
		else:
			_mod_dragging = false
			_refresh_mod_tooltip()
		accept_event()
	elif event is InputEventMouseMotion and _mod_dragging and size.y > 0.0:
		var scale := fine_drag_scale if event.shift_pressed else 1.0
		var amount := ModDisplay.step_amount(mod_assign_amount, -event.relative.y / size.y * scale)
		if not is_equal_approx(amount, mod_assign_amount):
			mod_assign_amount = amount
			mod_amount_changed.emit(amount)
			_refresh_mod_tooltip()
		accept_event()


func _refresh_mod_tooltip() -> void:
	if not is_inside_tree():
		return
	if not (mod_assign_active and (_mod_dragging or _mouse_hovered)):
		if _mod_tooltip:
			_mod_tooltip.visible = false
		return
	if _mod_tooltip == null:
		_mod_tooltip = ValueTooltip.attach(self)
	var text: String = str(mod_amount_text_callback.call(mod_assign_amount)) \
		if mod_amount_text_callback.is_valid() else ModDisplay.default_amount_text(mod_assign_amount)
	_mod_tooltip.set_text(text)
	_mod_tooltip.visible = true
	_mod_tooltip.place_right_of(Vector2(get_global_rect().end.x, get_global_rect().get_center().y))


func _gui_input(event: InputEvent):
	if mod_assign_active:
		_mod_gui_input(event)
		return
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
					_update_value_from_mouse(_fine_drag.begin(event.position))
				_last_click_time = current_time
			else:
				_dragging = false
	elif event is InputEventMouseMotion:
		if _dragging:
			_fine_drag.scale = fine_drag_scale
			_update_value_from_mouse(_fine_drag.update(event.position, event.shift_pressed, Rect2(Vector2.ZERO, size)))


func _update_value_from_mouse(mouse_pos: Vector2):
	var rect := get_rect()

	# Invert Y coordinate so bottom = 0, top = 1
	var normalized: float = clamp(1.0 - (mouse_pos.y / rect.size.y), 0.0, 1.0)

	# Map from [0, 1] to [min_value, max_value]
	value = remap(normalized, 0, 1, min_value, max_value)


func _on_mouse_entered():
	_mouse_hovered = true
	_refresh_mod_tooltip()
	queue_redraw()


func _on_mouse_exited():
	_mouse_hovered = false
	_refresh_mod_tooltip()
	queue_redraw()
