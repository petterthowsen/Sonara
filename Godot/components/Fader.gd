## Vertical value control, the sibling of `RotaryKnob`: a dark track, a fill in `fill_color`, a
## cap-style handle and an optional scale. It has no dB assumptions; a skewed taper comes from
## `logarithmic` or a `to_position` / `from_position` Callable pair (e.g. a `DeviceParameter`'s
## `value_to_normalized`).
##
## Gestures follow `godot-ui-components.md` §3: grabbing the handle never jumps, a click on the
## track jumps to the pointer, Shift is fine drag, double-click types a value, Ctrl/Cmd-click
## resets. The modulation contract matches `VolumeSlider` (bars down the right edge).
class_name Fader extends Control

signal value_changed(new_value: float)
## Emitted on every Ctrl/Cmd-click, even when the value is already the default.
signal reset_requested
## Emitted while `mod_assign_active` and the user drags (or double-clicks, which asks for 0).
signal mod_amount_changed(new_amount: float)

enum ScaleSide { NONE, LEFT, RIGHT }
enum TooltipSide { AUTO, LEFT, RIGHT }

const MOD_BAR := 3.0
const SCALE_WIDTH := 28.0
const HANDLE_GRAB_PAD := 4.0

## How the change behind the latest `value_changed` was made; read it inside the handler.
var last_edit_kind := ValueEditKind.Kind.DRAG

@export var min_value := 0.0:
	set(v):
		min_value = v
		_set_value(_value, false)
		queue_redraw()
@export var max_value := 1.0:
	set(v):
		max_value = v
		_set_value(_value, false)
		queue_redraw()
@export var value := 0.0:
	set(v):
		_set_value(v, true)
	get:
		return _value
@export var value_default := 0.0
## Maps the value logarithmically between min and max (min must be above 0).
@export var logarithmic := false:
	set(v):
		logarithmic = v
		queue_redraw()
## Optional skewed taper: Callable(value) -> 0..1 and Callable(0..1) -> value. Set both.
var to_position: Callable
var from_position: Callable

## The fill grows from this value, up or down; NAN grows it from the bottom.
@export var fill_origin := NAN:
	set(v):
		fill_origin = v
		queue_redraw()
@export var fill_color := UiColors.PRIMARY:
	set(c):
		fill_color = c
		queue_redraw()
@export var track_color := UiColors.TRACK_BG:
	set(c):
		track_color = c
		queue_redraw()
@export var handle_color := UiColors.HANDLE:
	set(c):
		handle_color = c
		queue_redraw()
@export var track_width := 16.0:
	set(w):
		track_width = w
		queue_redraw()
@export var handle_height := 8.0:
	set(h):
		handle_height = h
		queue_redraw()

## Array of `{value, label}` drawn beside the track (see `ScaleMarks`).
var scale_marks: Array[Dictionary] = []:
	set(m):
		scale_marks = m
		queue_redraw()
@export var scale_side := ScaleSide.NONE:
	set(s):
		scale_side = s
		queue_redraw()
@export var scale_font_size := 10

## A thin live bar inside the track, 0..1 up the track (NAN for none). The compressor's
## Threshold fader shows the detector level with it.
var overlay_level := NAN:
	set(v):
		overlay_level = v
		queue_redraw()
@export var overlay_color := Color(1, 1, 1, 0.55)
## A faint marker at this value (NAN for none), e.g. the Auto Gain makeup estimate.
var ghost_value := NAN:
	set(v):
		ghost_value = v
		queue_redraw()

@export var show_value_tooltip := true
@export var tooltip_side := TooltipSide.AUTO
@export var tooltip_gap := 10.0
@export var value_font_size := 12
## Used when `value_text_callback` is empty. `unit` is appended when set.
@export var value_format := "%.2f"
@export var unit := ""
## Optional Callable(value: float) -> String. Overrides value_format/unit.
var value_text_callback: Callable
@export var fine_drag_scale := FineDrag.DEFAULT_SCALE

## Routes into this value: `{amount, color, source, bipolar}`.
var mod_ranges: Array[Dictionary] = []:
	set(r):
		mod_ranges = r
		queue_redraw()
## While true, dragging edits the modulation amount instead of the value.
var mod_assign_active := false:
	set(a):
		mod_assign_active = a
		_dragging = false
		queue_redraw()
		_refresh_tooltip()
var mod_assign_color := Color.WHITE:
	set(c):
		mod_assign_color = c
		queue_redraw()
## Amount of the route being edited; the owner keeps it in sync, drags advance it.
var mod_assign_amount := 0.0
## Optional Callable(amount: float) -> String for the assign tooltip.
var mod_amount_text_callback: Callable
## Live modulated positions (0..1) while playing, drawn as thin markers.
var mod_live_values := PackedFloat32Array():
	set(v):
		mod_live_values = v
		queue_redraw()

var _value := 0.0
var _dragging := false
var _hovering := false
var _fine_drag := FineDrag.new()
var _tooltip: ValueTooltip = null
var _cap_style := StyleBoxFlat.new()


func _init() -> void:
	custom_minimum_size = Vector2(24, 60)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_cap_style.set_corner_radius_all(2)


func _ready() -> void:
	if not mouse_entered.is_connected(_on_mouse_entered):
		mouse_entered.connect(_on_mouse_entered)
		mouse_exited.connect(_on_mouse_exited)


## Set the value without emitting `value_changed`.
func set_value_no_signal(v: float) -> void:
	_set_value(v, false)


## 0..1 position of `v` up the track, through the configured taper.
func value_to_position(v: float) -> float:
	if max_value <= min_value:
		return 0.0
	var n: float
	if to_position.is_valid():
		n = float(to_position.call(v))
	elif logarithmic and min_value > 0.0:
		n = 0.0 if v <= min_value else log(v / min_value) / log(max_value / min_value)
	else:
		n = (v - min_value) / (max_value - min_value)
	return clampf(n, 0.0, 1.0)


## Inverse of `value_to_position`.
func position_to_value(n: float) -> float:
	n = clampf(n, 0.0, 1.0)
	if from_position.is_valid():
		return clampf(float(from_position.call(n)), min_value, max_value)
	if logarithmic and min_value > 0.0:
		return min_value * pow(max_value / min_value, n)
	return min_value + n * (max_value - min_value)


func get_value_text() -> String:
	if mod_assign_active:
		if mod_amount_text_callback.is_valid():
			return str(mod_amount_text_callback.call(mod_assign_amount))
		return ModDisplay.default_amount_text(mod_assign_amount)
	if value_text_callback.is_valid():
		return str(value_text_callback.call(_value))
	var text := value_format % _value
	return text if unit.is_empty() else "%s %s" % [text, unit]


## The track in local coordinates. Its ends are padded by half a handle so the handle stays inside.
func track_rect() -> Rect2:
	var left := SCALE_WIDTH if scale_side == ScaleSide.LEFT else 0.0
	var right := SCALE_WIDTH if scale_side == ScaleSide.RIGHT else 0.0
	var area := maxf(size.x - left - right, 0.0)
	var w := minf(track_width, area)
	var pad := handle_height * 0.5
	return Rect2(left + (area - w) * 0.5, pad, w, maxf(size.y - pad * 2.0, 0.0))


## Local y of a 0..1 track position.
func position_y(n: float) -> float:
	var track := track_rect()
	return track.end.y - n * track.size.y


func _set_value(v: float, emit_change: bool) -> void:
	var clamped := clampf(v, min_value, max_value)
	if is_equal_approx(_value, clamped):
		return
	_value = clamped
	queue_redraw()
	_refresh_tooltip()
	if emit_change:
		value_changed.emit(_value)


func _draw() -> void:
	var track := track_rect()
	draw_rect(track, track_color)
	if scale_side != ScaleSide.NONE and not scale_marks.is_empty():
		var items := ScaleMarks.layout(scale_marks, value_to_position, track.end.y, -track.size.y)
		var left := scale_side == ScaleSide.LEFT
		ScaleMarks.draw_vertical(self, items, track.position.x if left else track.end.x, left, size.y, scale_font_size)

	var value_y := position_y(value_to_position(_value))
	var origin_y := track.end.y
	if not is_nan(fill_origin):
		origin_y = position_y(value_to_position(fill_origin))
	var top := minf(value_y, origin_y)
	draw_rect(Rect2(track.position.x, top, track.size.x, absf(origin_y - value_y)), fill_color)

	if not is_nan(overlay_level):
		var bar_w := maxf(track.size.x * 0.25, 2.0)
		var level_y := position_y(clampf(overlay_level, 0.0, 1.0))
		draw_rect(Rect2(track.position.x + (track.size.x - bar_w) * 0.5, level_y, bar_w, track.end.y - level_y), overlay_color)
	if not is_nan(ghost_value):
		var ghost_y := position_y(value_to_position(ghost_value))
		draw_line(Vector2(track.position.x - 2.0, ghost_y), Vector2(track.end.x + 2.0, ghost_y), Color(1, 1, 1, 0.4), 1.5)

	_draw_modulation(track)

	var cap := Rect2(track.position.x - 3.0, value_y - handle_height * 0.5, track.size.x + 6.0, handle_height)
	_cap_style.bg_color = handle_color
	draw_style_box(_cap_style, cap)
	draw_line(Vector2(cap.position.x + 2.0, value_y), Vector2(cap.end.x - 2.0, value_y), Color(0, 0, 0, 0.45), 1.0)


## Route bars down the right edge of the track, live markers, and an outline while assigning.
func _draw_modulation(track: Rect2) -> void:
	var base := value_to_position(_value)
	for i in mod_ranges.size():
		var route := mod_ranges[i]
		var band := ModDisplay.span(base, float(route["amount"]), bool(route.get("bipolar", false)))
		if band.y - band.x < 0.002:
			continue
		draw_rect(Rect2(track.end.x - (i + 1) * MOD_BAR, position_y(band.y), MOD_BAR, (band.y - band.x) * track.size.y),
			route["color"], true)
	for live in mod_live_values:
		draw_rect(Rect2(track.position.x, position_y(clampf(live, 0.0, 1.0)) - 0.5, track.size.x, 1.5),
			ModDisplay.LIVE_MARKER_COLOR, true)
	if mod_assign_active:
		draw_rect(track, Color(mod_assign_color, 0.9), false, 1.5)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if not mb.pressed:
			_dragging = false
			_refresh_tooltip()
			return
		if mod_assign_active:
			if mb.double_click:
				mod_assign_amount = 0.0
				mod_amount_changed.emit(0.0)
			else:
				_dragging = true
			_refresh_tooltip()
		elif mb.double_click:
			_start_editing()
		elif mb.is_command_or_control_pressed():
			last_edit_kind = ValueEditKind.Kind.RESET
			value = value_default
			last_edit_kind = ValueEditKind.Kind.DRAG
			reset_requested.emit()
		else:
			_begin_drag(mb.position)
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		var track := track_rect()
		if track.size.y <= 0.0:
			return
		if mod_assign_active:
			var scale := fine_drag_scale if motion.shift_pressed else 1.0
			var amount := ModDisplay.step_amount(mod_assign_amount, -motion.relative.y / track.size.y * scale)
			if not is_equal_approx(amount, mod_assign_amount):
				mod_assign_amount = amount
				mod_amount_changed.emit(amount)
				_refresh_tooltip()
			return
		_fine_drag.scale = fine_drag_scale
		var point := _fine_drag.update(motion.position, motion.shift_pressed, Rect2(track.position, track.size))
		value = position_to_value((track.end.y - point.y) / track.size.y)


## A press on the handle grabs it where it is; a press elsewhere on the track jumps to the pointer.
func _begin_drag(mouse: Vector2) -> void:
	_dragging = true
	var track := track_rect()
	var handle_y := position_y(value_to_position(_value))
	var grab := Rect2(track.position.x - HANDLE_GRAB_PAD, handle_y - handle_height * 0.5 - HANDLE_GRAB_PAD,
		track.size.x + HANDLE_GRAB_PAD * 2.0, handle_height + HANDLE_GRAB_PAD * 2.0)
	if grab.has_point(mouse):
		_fine_drag.begin_at(Vector2(mouse.x, handle_y), mouse)
	else:
		var point := _fine_drag.begin(mouse)
		if track.size.y > 0.0:
			value = position_to_value((track.end.y - point.y) / track.size.y)
	_refresh_tooltip()


## Open a floating LineEdit above the fader to type a new value directly.
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
	if (what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_EXIT_TREE) \
			and not is_visible_in_tree() and _tooltip:
		_tooltip.visible = false


## Show, hide or update the tooltip on hover and while dragging, on the side away from the scale.
func _refresh_tooltip() -> void:
	if not is_inside_tree():
		return
	if not show_value_tooltip or not (_hovering or _dragging):
		if _tooltip:
			_tooltip.visible = false
		return
	if _tooltip == null:
		_tooltip = ValueTooltip.attach(self)
	_tooltip.gap = tooltip_gap
	_tooltip.set_font_size(value_font_size)
	_tooltip.set_text(get_value_text())
	_tooltip.visible = true
	var rect := get_global_rect()
	var y := global_position.y + position_y(value_to_position(_value))
	var on_left := tooltip_side == TooltipSide.LEFT \
		or (tooltip_side == TooltipSide.AUTO and scale_side == ScaleSide.RIGHT)
	if on_left:
		_tooltip.place_right_of(Vector2(rect.position.x - tooltip_gap * 2.0 - _tooltip.get_combined_minimum_size().x, y))
	else:
		_tooltip.place_right_of(Vector2(rect.end.x, y))
