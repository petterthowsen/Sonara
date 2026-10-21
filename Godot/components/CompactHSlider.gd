@tool
## Text-first horizontal value control: one line of formatted value text over a thin value bar.
## The interaction model is `RotaryKnob`'s with the drag axis vertical: left-drag changes the value
## with vertical motion (Shift = fine drag), Ctrl/Cmd-click resets to `default_value`, and a
## double-click opens the `FloatingValueEditor` for typed entry. The bar draws like `HorSlider`:
## a unidirectional fill from the left, or a fill from the centre when the range spans
## negative and positive values. The modulation surface (assign drags, route bars, live markers)
## matches `HorSlider`, so `ModAssign.attach()` works unchanged.
class_name CompactSlider extends Control

signal value_changed(new_value: float)
## How the change behind the latest `value_changed` was made; read it inside the handler.
var last_edit_kind := ValueEditKind.Kind.DRAG
## Emitted on Ctrl/Cmd-click even when the value is already the default (see `value_changed`).
signal reset_requested
signal drag_started
signal drag_ended

## Height of the value bar in pixels; the rest of the control is the text line.
const BAR_HEIGHT := 3.0
const MOD_BAR := 3.0

## Emitted while `mod_assign_active` and the user drags (or double-clicks, which asks for 0).
## The value itself doesn't change. See `ModDisplay`.
signal mod_amount_changed(new_amount: float)

## Routes into this value: `{amount, color, source, bipolar}`. Only the first is drawn, on the
## bar's top edge; `ModAssign` passes just the focused modulator's route.
var mod_ranges: Array[Dictionary] = []:
	set(r):
		mod_ranges = r
		queue_redraw()
## True while the focused (hovered or assigning) modulator is bound to this control; the
## overlay in `mod_hint_color` then pulses.
var mod_hint_active := false:
	set(a):
		mod_hint_active = a
		ModDisplay.set_pulsing(self, a)
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
			_mod_dragging = false
		mod_assign_active = a
		queue_redraw()
		_refresh_mod_tooltip()

var mod_assign_color := Color.WHITE:
	set(c):
		mod_assign_color = c
		queue_redraw()

## Amount of the route being edited; the owner keeps it in sync, drags advance it.
var mod_assign_amount := 0.0

## Optional Callable(amount: float) -> String for the assign tooltip (e.g. "+1.2 oct").
var mod_amount_text_callback: Callable

## Live modulated positions (0..1) while playing, drawn as thin markers on the bar.
var mod_live_values := PackedFloat32Array():
	set(v):
		mod_live_values = v
		queue_redraw()

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

## Value restored by Ctrl/Cmd-click.
@export var default_value := 0.5

## When above 0, the value snaps to `min_value` + n × `step`; drags accumulate underneath, so
## slow movements still reach the next step. 0 is continuous.
@export var step := 0.0:
	set(s):
		step = maxf(s, 0.0)
		_set_value(_value, false)
		if is_inside_tree():
			queue_redraw()

## When true, drag and the bar map the value logarithmically between min and max (min must be
## above 0).
@export var logarithmic := false:
	set(v):
		logarithmic = v
		if is_inside_tree():
			queue_redraw()

@export_category("Appearance")

## Used when `value_text_callback` is empty. `unit` is appended when set.
@export var value_format := "%g"

@export var unit := ""

## Optional Callable(value: float) -> String. Overrides value_format/unit.
var value_text_callback: Callable

## Optional Callable(text: String) -> float: turns typed text into a value, or NAN when the
## text isn't one (default: the text as a number).
var edit_parse_callback: Callable

@export var text_font_size := 13:
	set(s):
		text_font_size = s
		if is_inside_tree():
			queue_redraw()

@export var show_value_tooltip := true

var _tc := ThemedColors.new(self, &"CompactSlider")
var bg_color: Color:
	get:
		return _tc.get_color(&"bg")
	set(c):
		_tc.set_color(&"bg", c)

var text_color: Color:
	get:
		return _tc.get_color(&"text")
	set(c):
		_tc.set_color(&"text", c)

var bar_bg_color: Color:
	get:
		return _tc.get_color(&"bar_bg")
	set(c):
		_tc.set_color(&"bar_bg", c)

var bar_fill_color: Color:
	get:
		return _tc.get_color(&"bar_fill")
	set(c):
		_tc.set_color(&"bar_fill", c)

var mod_live_color: Color:
	get:
		return _tc.get_color(&"mod_live")
	set(c):
		_tc.set_color(&"mod_live", c)

@export_category("Interaction")

## Vertical pixels of motion per 1.0 of normalized range at normal speed.
@export var drag_sensitivity := 0.005:
	set(s):
		drag_sensitivity = s

var _value := 0.5
var _dragging := false
## Unsnapped position (0–1) a drag has reached; only used while `step` > 0.
var _drag_normalized := 0.0
var _hovered := false
var _fine_drag := FineDrag.new()
var _tooltip: ValueTooltip = null
var _mod_dragging := false
var _mod_tooltip: ValueTooltip = null


func _ready() -> void:
	if not Engine.is_editor_hint():
		HotkeyActions.declare_context(self, "control_knob")
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))


## Set the value without emitting `value_changed`.
func set_value_no_signal(v: float) -> void:
	_set_value(v, false)


## Format the current value for the text line.
func get_value_text() -> String:
	if value_text_callback.is_valid():
		return str(value_text_callback.call(_value))
	# GDScript's % operator doesn't support "%g"; format it by hand: whole values drop the
	# fractional part, everything else keeps `str()`'s shortest form.
	var text := _format_g(_value) if value_format == "%g" else value_format % _value
	if TimeFormat.is_time_unit(unit.strip_edges()):
		return TimeFormat.format(_value, unit.strip_edges())
	return text if unit.is_empty() else "%s %s" % [text, unit]


func _set_value(v: float, emit_change: bool) -> void:
	var clamped := _snap(clampf(v, min_value, max_value))
	if is_equal_approx(_value, clamped):
		return
	_value = clamped
	if emit_change:
		value_changed.emit(_value)
	if is_inside_tree():
		queue_redraw()


## C-style %g: whole values drop the fractional part, others keep the shortest form.
func _format_g(v: float) -> String:
	if is_equal_approx(v, roundf(v)) and absf(v) < 1e15:
		return str(int(round(v)))
	return str(v)


## `v` rounded to the nearest step from `min_value`, or unchanged when continuous.
func _snap(v: float) -> float:
	if step <= 0.0:
		return v
	return clampf(min_value + roundf((v - min_value) / step) * step, min_value, max_value)


func _set_hovered(hovered: bool) -> void:
	_hovered = hovered
	_refresh_mod_tooltip()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_tc.refresh()
		queue_redraw()
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_hovered = false


## Intrinsic height: one text line over the bar. Hosts that don't give the control a height
## otherwise get a zero-size (and thus dead) control.
func _get_minimum_size() -> Vector2:
	var font := get_theme_font(&"font", &"Label")
	if font == null:
		font = ThemeDB.fallback_font
	return Vector2(0.0, font.get_height(text_font_size) + BAR_HEIGHT + 2.0)


func _draw() -> void:
	# Background behind the whole component, the same well colour HorSlider/VSlider use.
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true, -1.0, true)
	# Value text line.
	var font := get_theme_font(&"font", &"Label")
	if font == null:
		font = ThemeDB.fallback_font
	draw_string(font, Vector2(0, size.y - BAR_HEIGHT - 1.0), get_value_text(),
		HORIZONTAL_ALIGNMENT_CENTER, size.x, text_font_size, text_color)

	# Thin value bar, filled like HorSlider: from the left, or from the centre when the range
	# spans negative and positive values.
	var bar_y := size.y - BAR_HEIGHT
	var bar_w := size.x
	draw_rect(Rect2(0, bar_y, bar_w, BAR_HEIGHT), bar_bg_color, true, -1.0, true)
	if _bidirectional():
		var center_x := bar_w * 0.5
		var fill_w := (_value_to_norm(_value) - 0.5) * bar_w  # negative fills left of centre
		draw_rect(Rect2(minf(center_x, center_x + fill_w), bar_y, absf(fill_w), BAR_HEIGHT),
			bar_fill_color, true, -1.0, true)
	else:
		draw_rect(Rect2(0, bar_y, _norm_value() * bar_w, BAR_HEIGHT), bar_fill_color, true, -1.0, true)

	_draw_modulation()


func _draw_modulation() -> void:
	var bar_y := size.y - BAR_HEIGHT
	var base := _norm_value()
	for i in mod_ranges.size():
		var route := mod_ranges[i]
		var band := ModDisplay.span(base, float(route["amount"]), bool(route.get("bipolar", false)))
		if band.y - band.x < 0.002:
			continue
		draw_rect(Rect2(band.x * size.x, bar_y - MOD_BAR * (i + 1),
			(band.y - band.x) * size.x, MOD_BAR), route["color"], true)
	for live in mod_live_values:
		draw_rect(Rect2(clampf(live, 0.0, 1.0) * size.x - 0.5, bar_y, 1.5, BAR_HEIGHT),
			mod_live_color, true)
	if mod_hint_active:
		ModDisplay.draw_fill(self, Rect2(Vector2.ZERO, size), mod_hint_color, ModDisplay.pulse_alpha())
	elif mod_assign_active:
		ModDisplay.draw_fill(self, Rect2(Vector2.ZERO, size), mod_assign_color)


## True when the range spans negative and positive values (centre fill).
func _bidirectional() -> bool:
	return min_value < 0.0 and max_value > 0.0


## 0..1 position of `v` across the bar, honouring log mapping and the centre point of a
## bidirectional range.
func _value_to_norm(v: float) -> float:
	return _value_to_normalized(v)


## Current value position as 0..1 across the bar.
func _norm_value() -> float:
	return clampf(_value_to_normalized(_value), 0.0, 1.0)


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


func _gui_input(event: InputEvent) -> void:
	if mod_assign_active:
		_mod_gui_input(event)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					_start_editing()
				elif mb.is_command_or_control_pressed():
					last_edit_kind = ValueEditKind.Kind.RESET
					value = default_value
					last_edit_kind = ValueEditKind.Kind.DRAG
					reset_requested.emit()
					_dragging = false
				else:
					_dragging = true
					_drag_normalized = _value_to_normalized(_value)
					drag_started.emit()
					_refresh_tooltip()
			else:
				if _dragging:
					_dragging = false
					drag_ended.emit()
				_refresh_tooltip()
			accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			var motion := event as InputEventMouseMotion
			var drag_scale := _fine_drag.scale if motion.shift_pressed else 1.0
			if step > 0.0:
				_drag_normalized = clampf(
					_drag_normalized - motion.relative.y * drag_sensitivity * drag_scale, 0.0, 1.0)
				value = _normalized_to_value(_drag_normalized)
				return
			var new_n: float = _value_to_normalized(_value) \
				+ (-motion.relative.y) * drag_sensitivity * drag_scale
			value = _normalized_to_value(new_n)
			_refresh_tooltip()


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
		var scale := _fine_drag.scale if event.shift_pressed else 1.0
		var amount := ModDisplay.step_amount(mod_assign_amount,
			-event.relative.y * drag_sensitivity * scale)
		if not is_equal_approx(amount, mod_assign_amount):
			mod_assign_amount = amount
			mod_amount_changed.emit(amount)
			_refresh_mod_tooltip()
		accept_event()


func _refresh_mod_tooltip() -> void:
	if not is_inside_tree():
		return
	if not (mod_assign_active and (_mod_dragging or _hovered)):
		if _mod_tooltip:
			_mod_tooltip.visible = false
		return
	if _mod_tooltip == null:
		_mod_tooltip = ValueTooltip.attach(self)
	var text: String = str(mod_amount_text_callback.call(mod_assign_amount)) \
		if mod_amount_text_callback.is_valid() else ModDisplay.default_amount_text(mod_assign_amount)
	_mod_tooltip.set_text(text)
	_mod_tooltip.visible = true
	_mod_tooltip.place_above(get_global_rect())


## Open a floating LineEdit above the control to type a new value directly.
func _start_editing() -> void:
	_dragging = false
	var editor := FloatingValueEditor.new()
	add_child(editor)
	editor.committed.connect(_on_edit_committed)
	var editor_size := Vector2(56.0, 22.0)
	editor.open(get_value_text(), FloatingValueEditor.position_above(self, editor_size), editor_size)


func _on_edit_committed(text: String) -> void:
	var trimmed := text.strip_edges()
	var parsed := NAN
	if edit_parse_callback.is_valid():
		parsed = float(edit_parse_callback.call(trimmed))
	elif trimmed.is_valid_float():
		parsed = float(trimmed)
	if not is_nan(parsed):
		last_edit_kind = ValueEditKind.Kind.TYPED
		value = parsed
		last_edit_kind = ValueEditKind.Kind.DRAG


func _process(_delta: float) -> void:
	if _tooltip and _tooltip.visible:
		_position_tooltip()
	else:
		set_process(false)


## Show, hide, or update the value tooltip for live dragging.
func _refresh_tooltip() -> void:
	if not show_value_tooltip or not is_inside_tree():
		if _tooltip:
			_tooltip.visible = false
		set_process(false)
		return
	if not _dragging:
		if _tooltip:
			_tooltip.visible = false
		set_process(false)
		return
	if _tooltip == null:
		_tooltip = ValueTooltip.attach(self)
	_tooltip.set_text(get_value_text())
	_tooltip.visible = true
	_position_tooltip()
	set_process(true)


func _position_tooltip() -> void:
	if _tooltip == null or not _tooltip.visible:
		return
	_tooltip.place_above(get_global_rect())
