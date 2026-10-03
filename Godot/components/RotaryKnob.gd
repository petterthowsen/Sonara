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
## Unsnapped position (0–1) a drag has reached; only used while `step` > 0.
var _drag_normalized := 0.0
var _hovering := false
var _tooltip: ValueTooltip = null

@export_category("Value")

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

## When above 0, the value snaps to `min_value` + n × `step` (1.0 for whole numbers); drags
## accumulate underneath, so slow movements still reach the next step. 0 is continuous.
@export var step := 0.0:
	set(s):
		step = maxf(s, 0.0)
		_set_value(_value, false)
		if is_inside_tree():
			queue_redraw()

## When true, drag and the arc map the value logarithmically between min and max.
@export var logarithmic := false:
	set(v):
		logarithmic = v
		if is_inside_tree():
			queue_redraw()

@export_category("Appearance")

## Knob radius in pixels, arc included. At 0 the knob fills its rect; above 0 it also sets the
## minimum size to fit, and draws centered in any larger rect.
@export var radius := 24.0:
	set(r):
		radius = maxf(r, 0.0)
		if radius > 0.0:
			custom_minimum_size = Vector2.ONE * radius * 2.0
		if is_inside_tree():
			queue_redraw()

@export var knob_color := Color.DIM_GRAY:
	set(c):
		knob_color = c
		if is_inside_tree():
			queue_redraw()

@export var shadow_color := Color(0.30323273, 0.30323285, 0.30323282, 1):
	set(c):
		shadow_color = c
		if is_inside_tree():
			queue_redraw()


## Thickness of the shadow around the knob, in pixels.
@export_range(0.0, 10.0, 0.1) var shadow_width := 2.0:
	set(w):
		shadow_width = maxf(w, 0.0)
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

@export var knob_line_color := Color(0.6789437, 0.6789437, 0.6789437, 1):
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

@export var arc_width := 6.0:
	set(w):
		arc_width = w
		if is_inside_tree():
			queue_redraw()

## Extra pixel spacing between the knob and the value arc, beyond half the arc width.
@export var arc_offset := 0.0:
	set(o):
		arc_offset = o
		if is_inside_tree():
			queue_redraw()

@export var knob_line_width := 3.0:
	set(w):
		knob_line_width = w
		if is_inside_tree():
			queue_redraw()


## Length of the indicator line as a fraction of the knob radius; its outer end stays at 90%.
@export_range(0.0, 0.9, 0.01) var knob_line_length := 0.6:
	set(length):
		knob_line_length = clampf(length, 0.0, 0.9)
		if is_inside_tree():
			queue_redraw()


@export_group("Modulation")

## Width of the modulation range arc relative to the value arc (minimum 1.5 px). It draws on
## top of the value arc, centered on the same ring.
@export_range(0.0, 1.0, 0.05) var mod_range_width_scale := 1.0:
	set(w):
		mod_range_width_scale = maxf(w, 0.0)
		queue_redraw()

## Live marker radius relative to the value arc width (minimum 1.5 px).
@export_range(0.0, 4.0, 0.05) var mod_live_marker_radius_scale := 0.5:
	set(s):
		mod_live_marker_radius_scale = maxf(s, 0.0)
		queue_redraw()

## Color of live modulation markers while playing.
@export var mod_live_marker_color := ModDisplay.LIVE_MARKER_COLOR:
	set(c):
		mod_live_marker_color = c
		queue_redraw()

@export_subgroup("Preview")

## Draws a fake route from the settings below instead of `mod_ranges`, so the modulation look
## can be tuned in the inspector (and in the component gallery) without a modulator.
@export var preview_modulation := false:
	set(p):
		preview_modulation = p
		queue_redraw()

@export_range(-1.0, 1.0, 0.01) var preview_mod_amount := 0.25:
	set(a):
		preview_mod_amount = a
		queue_redraw()

@export var preview_mod_bipolar := false:
	set(b):
		preview_mod_bipolar = b
		queue_redraw()

@export var preview_mod_color := ModDisplay.SOURCE_COLORS[0]:
	set(c):
		preview_mod_color = c
		queue_redraw()

## Shows the focus fill and amount readout, as when the source modulator is hovered.
@export var preview_mod_focused := false:
	set(f):
		preview_mod_focused = f
		queue_redraw()

## Live marker position (0..1); below 0 hides it.
@export_range(-0.01, 1.0, 0.01) var preview_mod_live := -0.01:
	set(l):
		preview_mod_live = l
		queue_redraw()

@export_category("Tooltip")

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


@export_category("Interaction")

@export var drag_sensitivity := 0.005:
	set(s):
		drag_sensitivity = s

@export var fine_drag_scale := 0.15

## Emitted while `mod_assign_active` and the user drags (or double-clicks, which asks for 0).
## The value itself doesn't change. See `ModDisplay`.
signal mod_amount_changed(new_amount: float)

## Routes into this value: `{amount, color, source, bipolar}`. Only the first is drawn, over the
## value arc; `ModAssign` passes just the focused modulator's route.
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
	var clamped := _snap(clampf(v, min_value, max_value))
	if is_equal_approx(_value, clamped):
		return
	_value = clamped
	if is_inside_tree():
		queue_redraw()
	_refresh_tooltip()
	if emit_change:
		value_changed.emit(_value)


## `v` rounded to the nearest step from `min_value`, or unchanged when continuous.
func _snap(v: float) -> float:
	if step <= 0.0:
		return v
	return clampf(min_value + roundf((v - min_value) / step) * step, min_value, max_value)


func _draw() -> void:
	var center := size / 2.0
	var fit: float = minf(size.x, size.y) / 2.0
	var outer: float = minf(radius, fit) if radius > 0.0 else fit
	var arc_radius: float = outer - arc_width / 2.0
	var knob_radius: float = arc_radius - arc_width - arc_offset
	var min_rotation_rad: float = deg_to_rad(min_rotation_deg - 90.0)
	var max_rotation_rad: float = deg_to_rad(max_rotation_deg - 90.0)
	draw_arc(center, arc_radius, min_rotation_rad, max_rotation_rad, 32, value_arc_bg, arc_width, true)
	var value_angle: float = lerpf(min_rotation_rad, max_rotation_rad, _value_to_normalized(_value))
	draw_arc(center, arc_radius, min_rotation_rad, value_angle, 32, value_arc_color, arc_width, true)
	draw_circle(center, knob_radius + shadow_width, shadow_color, true, -1.0, true)
	draw_circle(center, knob_radius, knob_color, true, -1.0, true)
	var line_start: Vector2 = center + Vector2.from_angle(value_angle) * (knob_radius * (0.9 - knob_line_length))
	var line_end: Vector2 = center + Vector2.from_angle(value_angle) * (knob_radius * 0.9)
	draw_line(line_start, line_end, knob_line_color, knob_line_width, true)
	_draw_modulation(center, arc_radius, knob_radius, min_rotation_rad, max_rotation_rad)


## Draw the focused route's range over the value arc, live-value markers on the ring, and the
## focus fill and amount readout on the knob body.
func _draw_modulation(center: Vector2, arc_radius: float, knob_radius: float, min_rad: float, max_rad: float) -> void:
	var route := {}
	var live_values := mod_live_values
	var hint_text := mod_hint_text
	var hint_color := mod_hint_color
	if preview_modulation:
		route = {"amount": preview_mod_amount, "color": preview_mod_color, "bipolar": preview_mod_bipolar}
		live_values = PackedFloat32Array([preview_mod_live]) if preview_mod_live >= 0.0 else PackedFloat32Array()
		hint_text = ModDisplay.default_amount_text(preview_mod_amount) if preview_mod_focused else ""
		hint_color = preview_mod_color
	elif not mod_ranges.is_empty():
		route = mod_ranges[0]
	if not route.is_empty():
		var band := ModDisplay.span(_value_to_normalized(_value), float(route["amount"]), bool(route.get("bipolar", false)))
		if band.y - band.x >= 0.002:
			draw_arc(center, arc_radius, lerpf(min_rad, max_rad, band.x), lerpf(min_rad, max_rad, band.y),
				24, route["color"], maxf(arc_width * mod_range_width_scale, 1.5), true)
	for live in live_values:
		var angle := lerpf(min_rad, max_rad, clampf(live, 0.0, 1.0))
		draw_circle(center + Vector2.from_angle(angle) * arc_radius,
			maxf(arc_width * mod_live_marker_radius_scale, 1.5), mod_live_marker_color, true, -1.0, true)
	if mod_assign_active:
		ModDisplay.draw_fill_circle(self, center, knob_radius, mod_assign_color)
	elif not hint_text.is_empty():
		ModDisplay.draw_fill_circle(self, center, knob_radius, hint_color)
	ModDisplay.draw_hint_text(self, Rect2(center - Vector2.ONE * knob_radius, Vector2.ONE * knob_radius * 2.0), hint_text)


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
					_drag_normalized = _value_to_normalized(_value)
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
			if step > 0.0:
				_drag_normalized = clampf(_drag_normalized - motion.relative.y * drag_sensitivity * drag_scale, 0.0, 1.0)
				value = _normalized_to_value(_drag_normalized)
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
