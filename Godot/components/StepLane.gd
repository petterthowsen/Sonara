@tool
## One row of step cells for a step sequencer: a bar lane (`BARS`, e.g. Pitch, Velocity, Chance) or
## an On/Off row (`TOGGLES`). It knows nothing about devices: the owner pushes values through the
## `*_no_signal` setters and listens to `value_edited`. Every lane of a view uses the same column
## geometry (`column_rect` / `step_at_x`), so a column lines up across lanes.
##
## Gestures (BARS): drag paints every crossed step (gaps between mouse events are filled by
## `fill_between`), Shift + press grabs one step for a fine-drag adjustment (`FineDrag`),
## Ctrl/Cmd + press or drag resets crossed steps to `default_value`, double-click types an exact
## value. TOGGLES: a press flips the step and a drag sets every crossed step to the new state.
class_name StepLane extends Control

enum Mode { TOGGLES, BARS }

## A real change of one step. `step` is zero-based.
signal value_edited(step: int, value: float)
signal edit_started
signal edit_ended

## Horizontal space between groups of `group_size` columns.
const GROUP_GAP := 4.0
## Narrowest a column may get, so steps stay easy to hit and their numbers fit.
const MIN_COLUMN_WIDTH := 24.0

@export var mode := Mode.BARS:
	set(m):
		mode = m
		queue_redraw()
@export var step_count := 16:
	set(n):
		step_count = maxi(n, 1)
		_values.resize(step_count)
		_flash.resize(step_count)
		update_minimum_size()
		queue_redraw()
@export var group_size := 4:
	set(n):
		group_size = maxi(n, 1)
		queue_redraw()
@export var min_value := -24.0:
	set(v):
		min_value = v
		queue_redraw()
@export var max_value := 24.0:
	set(v):
		max_value = v
		queue_redraw()
## The base the bars grow from (0 for Pitch, the minimum for percent lanes).
@export var origin := 0.0:
	set(v):
		origin = v
		queue_redraw()
@export var default_value := 0.0
@export var value_step := 1.0
## Guide lines (Pitch: +-12). The line at `origin` is always drawn when it is inside the range.
@export var guide_values := PackedFloat32Array():
	set(g):
		guide_values = g
		queue_redraw()
@export var unit := ""
## Optional Callable(value: float) -> String for the readout and the editor's initial text.
var value_text_callback: Callable
@export var show_value_tooltip := true
## Optional colour per whole value (BARS, spec 053): a bar is drawn in `level_colors[int(value)]`
## instead of `bar_color`. Values past the array keep the normal colour.
var level_colors := PackedColorArray():
	set(c):
		level_colors = c
		queue_redraw()

## Bit k set = step k is Off (BARS draws those bars dimmed).
var off_mask := 0:
	set(m):
		if m != off_mask:
			off_mask = m
			queue_redraw()
## Steps at or beyond `length` dim more strongly but stay editable.
var length := 16:
	set(n):
		if n != length:
			length = n
			queue_redraw()
## The highlighted column, -1 for none.
var playhead := -1:
	set(p):
		if p != playhead:
			playhead = p
			queue_redraw()

var _values := PackedFloat32Array()
var _flash := PackedFloat32Array()

var _tc := ThemedColors.new(self, &"StepLane")
var bg_color: Color:
	get: return _tc.get_color(&"bg")
	set(c): _tc.set_color(&"bg", c)
var grid_color: Color:
	get: return _tc.get_color(&"grid")
	set(c): _tc.set_color(&"grid", c)
var bar_color: Color:
	get: return _tc.get_color(&"bar")
	set(c): _tc.set_color(&"bar", c)
var bar_off_color: Color:
	get: return _tc.get_color(&"bar_off")
	set(c): _tc.set_color(&"bar_off", c)
var toggle_on_color: Color:
	get: return _tc.get_color(&"toggle_on")
	set(c): _tc.set_color(&"toggle_on", c)
var toggle_off_color: Color:
	get: return _tc.get_color(&"toggle_off")
	set(c): _tc.set_color(&"toggle_off", c)
var playhead_color: Color:
	get: return _tc.get_color(&"playhead")
	set(c): _tc.set_color(&"playhead", c)
var fired_color: Color:
	get: return _tc.get_color(&"fired")
	set(c): _tc.set_color(&"fired", c)
var beyond_color: Color:
	get: return _tc.get_color(&"beyond")
	set(c): _tc.set_color(&"beyond", c)

enum Gesture { NONE, PAINT, RESET, FINE, TOGGLE }
## The gesture in progress. The setter owns the help-bar state and `edit_started` / `edit_ended`,
## so every exit path stays consistent.
var _gesture := Gesture.NONE:
	set(g):
		var was_active := _gesture != Gesture.NONE
		_gesture = g
		var active := g != Gesture.NONE
		if active == was_active:
			return
		var hotkeys := _hotkeys()
		if active:
			if hotkeys:
				hotkeys.begin_state(self, "step_lane_draw")
			edit_started.emit()
		else:
			if hotkeys:
				hotkeys.end_state(self)
			edit_ended.emit()
			_refresh_tooltip()
var _last_step := -1
var _last_value := 0.0
var _toggle_state := 0.0
var _fine := FineDrag.new()
var _fine_step := -1
var _hover_step := -1
var _tooltip: ValueTooltip = null
var _edit_step := -1


func _init() -> void:
	_values.resize(step_count)
	_flash.resize(step_count)
	length = step_count


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if not Engine.is_editor_hint():
		HotkeyActions.declare_context(self, "step_lane")
	mouse_exited.connect(_on_mouse_exited)


func _exit_tree() -> void:
	if _gesture != Gesture.NONE:
		_gesture = Gesture.NONE


func _get_minimum_size() -> Vector2:
	return Vector2(min_width_for(step_count, group_size), 24.0)


## Minimum width of a row of `count` columns, including the group gaps.
static func min_width_for(count: int, group: int) -> float:
	var gaps := maxi(ceili(float(count) / maxi(group, 1)) - 1, 0)
	return count * MIN_COLUMN_WIDTH + gaps * GROUP_GAP


# --- Data (never emits) ---------------------------------------------------------------------

func set_values_no_signal(v: PackedFloat32Array) -> void:
	for k in step_count:
		_values[k] = v[k] if k < v.size() else 0.0
	queue_redraw()


func set_value_no_signal(k: int, v: float) -> void:
	if k < 0 or k >= step_count or is_equal_approx(_values[k], v):
		return
	_values[k] = v
	queue_redraw()


func get_value_at(k: int) -> float:
	return _values[k] if k >= 0 and k < step_count else 0.0


func get_values() -> PackedFloat32Array:
	return _values.duplicate()


## True when step `k` is Off.
func is_step_off(k: int) -> bool:
	return (off_mask >> k) & 1 == 1


## True when step `k` is at or beyond the sequence length.
func is_beyond_length(k: int) -> bool:
	return k >= length


## Flash level 0..1 drawn as the `fired` overlay on column `k`.
func set_flash(k: int, level: float) -> void:
	if k < 0 or k >= step_count:
		return
	level = clampf(level, 0.0, 1.0)
	if not is_equal_approx(_flash[k], level):
		_flash[k] = level
		queue_redraw()


func clear_flashes() -> void:
	for k in step_count:
		_flash[k] = 0.0
	playhead = -1
	queue_redraw()


# --- Geometry and pure maths ----------------------------------------------------------------

func _column_width() -> float:
	var gaps := maxi(ceili(float(step_count) / group_size) - 1, 0)
	return maxf((size.x - gaps * GROUP_GAP) / step_count, 1.0)


## Full-height rectangle of column `k`, in local coordinates.
func column_rect(k: int) -> Rect2:
	var w := _column_width()
	var x := k * w + (k / group_size) * GROUP_GAP
	return Rect2(x, 0.0, w, size.y)


## The column under local `x`. A point in a group gap or outside the lane gives the nearest one.
func step_at_x(x: float) -> int:
	for k in step_count:
		var r := column_rect(k)
		var gap_after := GROUP_GAP if (k + 1) % group_size == 0 and k < step_count - 1 else 0.0
		if x < r.end.x + gap_after * 0.5:
			return k
	return step_count - 1


## The value at height `y` of a lane `height` tall: `max_v` at the top, `min_v` at the bottom,
## snapped to `step` (counted from `min_v`) and clamped.
static func value_at_y(y: float, height: float, min_v: float, max_v: float, step: float = 1.0) -> float:
	return snap_value(raw_value_at_y(y, height, min_v, max_v), min_v, max_v, step)


## `value_at_y` without snapping.
static func raw_value_at_y(y: float, height: float, min_v: float, max_v: float) -> float:
	if height <= 0.0:
		return min_v
	return lerpf(max_v, min_v, clampf(y / height, 0.0, 1.0))


static func snap_value(v: float, min_v: float, max_v: float, step: float) -> float:
	if step > 0.0:
		v = min_v + roundf((v - min_v) / step) * step
	return clampf(v, min_v, max_v)


## Every column from `k0` to `k1` inclusive (in travel order) with the value linearly
## interpolated from `v0` to `v1`: `{column: value}`. When `k0 == k1` it is just `{k1: v1}`.
static func fill_between(k0: int, v0: float, k1: int, v1: float) -> Dictionary:
	var out := {}
	if k0 == k1:
		out[k1] = v1
		return out
	var dir := 1 if k1 > k0 else -1
	var n := absi(k1 - k0)
	for i in n + 1:
		out[k0 + dir * i] = lerpf(v0, v1, float(i) / n)
	return out


## Parses typed text: a number with an optional trailing `%` or `st`. NAN when it isn't one.
static func parse_entry(text: String) -> float:
	var t := text.strip_edges().to_lower()
	if t.ends_with("%"):
		t = t.trim_suffix("%")
	elif t.ends_with("st"):
		t = t.trim_suffix("st")
	t = t.strip_edges()
	return float(t) if t.is_valid_float() else NAN


func _value_to_y(v: float) -> float:
	if max_value <= min_value:
		return size.y
	return size.y * (1.0 - clampf((v - min_value) / (max_value - min_value), 0.0, 1.0))


func get_value_text(v: float) -> String:
	if value_text_callback.is_valid():
		return str(value_text_callback.call(v))
	var text := str(int(roundf(v))) if is_equal_approx(v, roundf(v)) else str(v)
	if TimeFormat.is_time_unit(unit.strip_edges()):
		return TimeFormat.format(v, unit.strip_edges())
	return text if unit.is_empty() else "%s %s" % [text, unit]


# --- Drawing --------------------------------------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_tc.refresh()
		queue_redraw()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_hover_step = -1
		_refresh_tooltip()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)
	if mode == Mode.BARS:
		_draw_bars()
	else:
		_draw_toggles()
	var play_c := playhead_color
	var fired_c := fired_color
	var beyond_c := beyond_color
	for k in step_count:
		var r := column_rect(k)
		if is_beyond_length(k):
			draw_rect(r, beyond_c, true)
		if k == playhead:
			draw_rect(r, play_c, true)
		if _flash[k] > 0.0:
			draw_rect(r, Color(fired_c, fired_c.a * _flash[k]), true)
	# Group separators sit in the gaps between groups.
	var grid_c := grid_color
	for k in range(group_size, step_count, group_size):
		var gx := column_rect(k).position.x - GROUP_GAP * 0.5
		draw_line(Vector2(gx, 0.0), Vector2(gx, size.y), grid_c, 1.0)


func _draw_bars() -> void:
	var grid_c := grid_color
	var line_c := Color(grid_c, grid_c.a * 0.6)
	for g in guide_values:
		if g > min_value and g < max_value:
			var gy := roundf(_value_to_y(g)) + 0.5
			draw_line(Vector2(0.0, gy), Vector2(size.x, gy), line_c, 1.0)
	if origin > min_value and origin < max_value:
		var zy := roundf(_value_to_y(origin)) + 0.5
		draw_line(Vector2(0.0, zy), Vector2(size.x, zy), grid_c, 1.0)
	var oy := _value_to_y(origin)
	var on_c := bar_color
	var off_c := bar_off_color
	for k in step_count:
		var r := column_rect(k)
		var vy := _value_to_y(_values[k])
		var top := minf(vy, oy)
		var h := maxf(absf(vy - oy), 1.0)
		if is_equal_approx(vy, oy) and oy >= size.y:
			top = size.y - 1.0
		draw_rect(Rect2(r.position.x + 1.0, top, maxf(r.size.x - 2.0, 1.0), h),
			off_c if is_step_off(k) else _bar_color_for(k), true)


## Colour of step `k`'s bar: its entry of `level_colors`, else the lane's `bar` colour.
func _bar_color_for(k: int) -> Color:
	var level := int(_values[k])
	if level >= 0 and level < level_colors.size():
		return level_colors[level]
	return bar_color


func _draw_toggles() -> void:
	var on_c := toggle_on_color
	var off_c := toggle_off_color
	for k in step_count:
		var r := column_rect(k).grow(-1.0)
		draw_rect(r, on_c if _values[k] > 0.5 else off_c, true)


# --- Input ----------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_on_press(mb)
		else:
			_gesture = Gesture.NONE
		accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _gesture == Gesture.NONE:
			_hover_step = step_at_x(motion.position.x)
			_refresh_tooltip()
		else:
			_on_drag(motion)
			accept_event()


func _on_press(mb: InputEventMouseButton) -> void:
	var k := step_at_x(mb.position.x)
	_hover_step = k
	if mode == Mode.TOGGLES:
		_toggle_state = 0.0 if _values[k] > 0.5 else 1.0
		_gesture = Gesture.TOGGLE
		_last_step = k
		_apply(k, _toggle_state)
		return
	if mb.double_click:
		_start_editing(k)
		return
	_last_step = k
	if mb.is_command_or_control_pressed():
		_gesture = Gesture.RESET
		_last_value = default_value
		_apply(k, default_value)
	elif mb.shift_pressed:
		_gesture = Gesture.FINE
		_fine_step = k
		_fine.begin_at(Vector2(0.0, _value_to_y(_values[k])), mb.position)
	else:
		_gesture = Gesture.PAINT
		_last_value = value_at_y(mb.position.y, size.y, min_value, max_value, value_step)
		_apply(k, _last_value)
	_refresh_tooltip()


func _on_drag(motion: InputEventMouseMotion) -> void:
	var k := step_at_x(motion.position.x)
	match _gesture:
		Gesture.FINE:
			# Only y matters; the bounds clamp it to the lane (x is held in a 1 px strip).
			var p := _fine.update(motion.position, motion.shift_pressed, Rect2(0.0, 0.0, 1.0, size.y))
			_apply(_fine_step, snap_value(
				raw_value_at_y(p.y, size.y, min_value, max_value),
				min_value, max_value, value_step))
			_hover_step = _fine_step
		Gesture.TOGGLE:
			for c in fill_between(_last_step, _toggle_state, k, _toggle_state):
				_apply(c, _toggle_state)
			_last_step = k
			_hover_step = k
		_:
			var v := default_value if _gesture == Gesture.RESET else \
				value_at_y(motion.position.y, size.y, min_value, max_value, value_step)
			var path := fill_between(_last_step, _last_value, k, v)
			for c in path:
				if c == _last_step and k != _last_step:
					continue
				_apply(c, snap_value(path[c], min_value, max_value, value_step))
			_last_step = k
			_last_value = v
			_hover_step = k
	_refresh_tooltip()


## Sets step `k`, emitting `value_edited` only when the value really changes.
func _apply(k: int, v: float) -> void:
	v = snap_value(v, min_value, max_value, value_step)
	if k < 0 or k >= step_count or is_equal_approx(_values[k], v):
		return
	_values[k] = v
	value_edited.emit(k, v)
	queue_redraw()


# --- Readout and typed entry ----------------------------------------------------------------

func _on_mouse_exited() -> void:
	if _gesture == Gesture.NONE:
		_hover_step = -1
		_refresh_tooltip()


func _refresh_tooltip() -> void:
	if not is_inside_tree():
		return
	var show := show_value_tooltip and mode == Mode.BARS and _hover_step >= 0 \
		and (_gesture != Gesture.NONE or is_visible_in_tree())
	if not show:
		if _tooltip:
			_tooltip.visible = false
		return
	if _tooltip == null:
		_tooltip = ValueTooltip.attach(self)
	_tooltip.set_text("Step %d  %s" % [_hover_step + 1, get_value_text(_values[_hover_step])])
	_tooltip.visible = true
	var col := column_rect(_hover_step)
	_tooltip.place_above(Rect2(global_position + Vector2(col.position.x, 0.0), Vector2(col.size.x, 0.0)))


func _start_editing(k: int) -> void:
	_edit_step = k
	var editor := FloatingValueEditor.new()
	add_child(editor)
	editor.committed.connect(commit_text)
	var editor_size := Vector2(64.0, 22.0)
	var col := column_rect(k)
	var pos := global_position + Vector2(col.get_center().x - editor_size.x * 0.5, -editor_size.y - 4.0)
	pos.x = clampf(pos.x, 0.0, maxf(get_viewport_rect().size.x - editor_size.x, 0.0))
	if pos.y < 0.0:
		pos.y = global_position.y + size.y + 4.0
	editor.open(get_value_text(_values[k]), pos, editor_size)


## Applies typed text to the step being edited: a number with an optional `%` or `st`, rounded
## and clamped. Text that isn't a number is ignored.
func commit_text(text: String) -> void:
	var parsed := parse_entry(text)
	if is_nan(parsed) or _edit_step < 0:
		return
	_apply(_edit_step, parsed)


func _hotkeys() -> Node:
	var tree := get_tree()
	return tree.root.get_node_or_null("Hotkeys") if tree else null
