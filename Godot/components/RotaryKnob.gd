## Rotary knob with an arc value indicator and a hover/edit value tooltip.
@tool
class_name RotaryKnob extends Control

signal value_changed(new_value: float)
## How the change behind the latest `value_changed` was made; read it inside the handler.
var last_edit_kind := ValueEditKind.Kind.DRAG
## Emitted on Ctrl/Cmd-click even when the value is already the default (see `value_changed`).
signal reset_requested

var _value := 0.5
var _dragging := false
var _hovering := false
var _tooltip: ValueTooltip = null

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

## Knob radius in pixels, arc included. At 0 the knob fills its rect; above 0 it also sets the
## minimum size to fit, and draws centered in any larger rect.
@export var radius := 0.0:
	set(r):
		radius = maxf(r, 0.0)
		if radius > 0.0:
			custom_minimum_size = Vector2.ONE * radius * 2.0
		if is_inside_tree():
			queue_redraw()

@export var show_value_tooltip := true

## Font size of the value tooltip text.
@export var value_font_size := 12

enum TooltipSide { ABOVE, BELOW }

## Where the value tooltip sits. Put it on the side away from the knob's caption.
@export var tooltip_side := TooltipSide.ABOVE

## Gap in pixels between the knob and the value tooltip.
@export var tooltip_gap := 10.0

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

## Emitted while `mod_assign_active` and the user drags (or double-clicks, which asks for 0).
## The value itself doesn't change. See `ModDisplay`.
signal mod_amount_changed(new_amount: float)

## Routes into this value: `{amount, color, source, bipolar}`, drawn as arcs inside the ring.
var mod_ranges: Array[Dictionary] = []:
	set(r):
		mod_ranges = r
		queue_redraw()
## Amount readout ("+35 %") and color of the focused modulator's binding to this control, shown
## while a modulator is hovered or being assigned; empty when this control isn't bound to it.
var mod_hint_text := "":
	set(t):
		mod_hint_text = t
		queue_redraw()

var mod_hint_color := Color.WHITE:
	set(c):
		mod_hint_color = c
		queue_redraw()


## While true, dragging edits the modulation amount instead of the value.
var mod_assign_active := false:
	set(a):
		# Re-assigning the same value (a refresh mid-drag) must not cancel the drag.
		if a != mod_assign_active:
			_dragging = false
		mod_assign_active = a
		queue_redraw()
		_refresh_tooltip()

var mod_assign_color := Color.WHITE:
	set(c):
		mod_assign_color = c
		queue_redraw()

## Amount of the route being edited; the owner keeps it in sync, drags advance it.
var mod_assign_amount := 0.0

## Optional Callable(amount: float) -> String for the assign tooltip (e.g. "+1.2 oct").
var mod_amount_text_callback: Callable

## Live modulated positions (0..1) while playing, drawn as dots on the ring.
var mod_live_values := PackedFloat32Array():
	set(v):
		mod_live_values = v
		queue_redraw()


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
	if mod_assign_active:
		if mod_amount_text_callback.is_valid():
			return str(mod_amount_text_callback.call(mod_assign_amount))
		return ModDisplay.default_amount_text(mod_assign_amount)
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
	var fit: float = minf(size.x, size.y) / 2.0
	var outer: float = minf(radius, fit) if radius > 0.0 else fit
	var arc_radius: float = outer - arc_width / 2.0
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
	_draw_modulation(center, arc_radius, knob_radius, min_rotation_rad, max_rotation_rad)


## Route arcs just inside the value ring, the live markers on it, and live markers.
func _draw_modulation(center: Vector2, arc_radius: float, knob_radius: float, min_rad: float, max_rad: float) -> void:
	var base := _value_to_normalized(_value)
	var thin := maxf(arc_width * 0.6, 1.5)
	var ring := arc_radius - arc_width * 0.5 - thin * 0.5 - 1.0
	for i in mod_ranges.size():
		var route := mod_ranges[i]
		var band := ModDisplay.span(base, float(route["amount"]), bool(route.get("bipolar", false)))
		if band.y - band.x < 0.002:
			continue
		var r := ring - i * (thin + 0.5)
		if r <= thin:
			break
		draw_arc(center, r, lerpf(min_rad, max_rad, band.x), lerpf(min_rad, max_rad, band.y),
			24, route["color"], thin, true)
	for live in mod_live_values:
		var angle := lerpf(min_rad, max_rad, clampf(live, 0.0, 1.0))
		draw_circle(center + Vector2.from_angle(angle) * arc_radius, maxf(arc_width * 0.5, 1.5),
			ModDisplay.LIVE_MARKER_COLOR)
	if mod_assign_active:
		ModDisplay.draw_fill_circle(self, center, knob_radius, mod_assign_color)
	elif not mod_hint_text.is_empty():
		ModDisplay.draw_fill_circle(self, center, knob_radius, mod_hint_color)
	ModDisplay.draw_hint_text(self, Rect2(center - Vector2.ONE * knob_radius, Vector2.ONE * knob_radius * 2.0), mod_hint_text)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and mod_assign_active:
				if mb.double_click:
					mod_assign_amount = 0.0
					mod_amount_changed.emit(0.0)
				else:
					_dragging = true
				_refresh_tooltip()
			elif mb.pressed:
				if mb.double_click:
					_start_editing()
				elif mb.ctrl_pressed:
					last_edit_kind = ValueEditKind.Kind.RESET
					value = value_default
					last_edit_kind = ValueEditKind.Kind.DRAG
					reset_requested.emit()
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
			if mod_assign_active:
				var amount := ModDisplay.step_amount(mod_assign_amount, -motion.relative.y * drag_sensitivity * drag_scale)
				if not is_equal_approx(amount, mod_assign_amount):
					mod_assign_amount = amount
					mod_amount_changed.emit(amount)
					_refresh_tooltip()
				return
			var new_n: float = _value_to_normalized(_value) + (-motion.relative.y) * drag_sensitivity * drag_scale
			value = _normalized_to_value(new_n)


## Open a floating LineEdit above the knob to type a new value directly.
func _start_editing() -> void:
	_dragging = false
	var editor := FloatingValueEditor.new()
	add_child(editor)
	editor.committed.connect(_on_edit_committed)
	var editor_size := Vector2(56.0, 22.0)
	editor.open(value_format % _value, FloatingValueEditor.position_above(self, editor_size), editor_size)


func _on_edit_committed(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_valid_float():
		last_edit_kind = ValueEditKind.Kind.TYPED
		value = float(trimmed)
		last_edit_kind = ValueEditKind.Kind.DRAG


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
	if _tooltip == null:
		_tooltip = ValueTooltip.attach(self)
	_tooltip.gap = tooltip_gap
	_tooltip.set_font_size(value_font_size)
	_tooltip.set_text(get_value_text())
	_tooltip.visible = true
	_position_tooltip()
	set_process(true)


## Keep the tooltip above or below the knob in viewport space.
func _position_tooltip() -> void:
	if _tooltip == null or not _tooltip.visible:
		return
	if tooltip_side == TooltipSide.BELOW:
		_tooltip.place_below(get_global_rect())
	else:
		_tooltip.place_above(get_global_rect())
