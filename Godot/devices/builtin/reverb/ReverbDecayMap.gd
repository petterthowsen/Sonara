@tool
## The Reverb's decay map (spec 050): time runs left to right on a square-root axis (x grows with
## sqrt(t / span), so the first ~100 ms get room), frequency (log, 20 Hz-20 kHz) runs bottom to
## top, and the tail is shaded by its level in dB as the current parameters predict it
## (`ReverbData`). It draws the Pre-Delay gap, the onset (each early reflection a broadband
## column whose brightness follows Early; Diffusion blurs the columns and lets the tail fill in
## sooner, a visual estimate), the -60 dB contour, the Low Cut / High Cut fades and, while Freeze is on, a tail that runs past
## the right edge. Six handles edit the parameters by dragging (contour, the two Decay EQ knees,
## the Pre-Delay edge, the two cuts).
##
## Without a bound device it draws `ReverbData.DEFAULTS`, so the control previews in the editor.
## It redraws only when a value, the span or the hover changes. Edits go through
## `ParameterActions` on the bound `DeviceInstance` (never straight to OSC), inside a gesture so
## one drag is one undo step per parameter.
class_name ReverbDecayMap extends Control

## The span (seconds shown) eased to a new value.
signal span_changed(span: float)

const ROWS := 64
const MARGIN_LEFT := 30.0
const MARGIN_BOTTOM := 14.0
const MARGIN_TOP := 4.0
const MARGIN_RIGHT := 4.0
const HANDLE_RADIUS := 5.0
const HIT_RADIUS := 9.0
const LINE_HIT := 5.0
const SPAN_EASE_S := 0.15
const AXIS_FREQS: Array[float] = [50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0]
## Time grid candidates (s); a line is skipped when its label would crowd the previous one.
const TIME_STEPS: Array[float] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 60.0]
const TIME_LABEL_GAP := 34.0
## Tail mesh columns: these many evenly in x, plus extra samples across the onset.
const TAIL_COLUMNS := 48
const ONSET_SAMPLES := 8

const GRID_COLOR := Color(1, 1, 1, 0.07)
const LABEL_COLOR := Color(1, 1, 1, 0.45)
const CONTOUR_COLOR := Color(1, 1, 1, 0.9)
const EARLY_COLOR := Color(1, 0.85, 0.4)
const CUT_COLOR := Color(1, 1, 1, 0.45)
const FROST_COLOR := Color(0.6, 0.85, 1.0, 0.95)

const H_CONTOUR := "contour"
const H_LOW_KNEE := "low_knee"
const H_HIGH_KNEE := "high_knee"
const H_PREDELAY := "pre_delay"
const H_LOW_CUT := "low_cut"
const H_HIGH_CUT := "high_cut"

## The device edits go to; null previews the defaults.
## (Untyped: `DeviceInstance` reaches autoloads, and this script must compile where they are not
## resolvable yet, like headless tests.)
var device = null
## Parameter id -> real value, what the map draws.
var values: Dictionary = ReverbData.DEFAULTS.duplicate()
## Seconds the horizontal axis shows now (eased toward `span_target`) and where it is heading.
var span := 3.0
var span_target := 3.0
## True while the user drags a handle: the span does not change until release.
var span_locked := false
## "≈ Tank FX" mark: devices in the decay loop change the tail in ways the map cannot model.
var approximate := false

var _span_ready := false
var _hover := ""
var _drag := ""
var _tooltip: ValueTooltip = null
var _fill_color := Color(0.3, 0.6, 1.0)
var _bg_color := Color(0.08, 0.08, 0.08)


func _init() -> void:
	custom_minimum_size = Vector2(300, 120)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(_on_mouse_exited)


func _ready() -> void:
	_apply_theme_colors()
	_tooltip = ValueTooltip.attach(self)
	_update_span_target()
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme_colors()
		queue_redraw()
	elif what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_EXIT_TREE:
		_end_drag()


func _apply_theme_colors() -> void:
	var theme := ThemeDB.get_project_theme()
	if theme == null:
		return
	if theme.has_color(&"accent_primary", &"Sonara"):
		_fill_color = UiColors.role(&"accent_primary")
	if theme.has_color(&"well", &"Sonara"):
		_bg_color = UiColors.role(&"well")


# ============================================================================
# STATE
# ============================================================================

## Bind the device that edits are written to (null unbinds).
func bind_device(p_device) -> void:
	device = p_device
	set_values(ReverbData.values_from_device(device))


## Replace the drawn values (a full dictionary, id -> real).
func set_values(new_values: Dictionary) -> void:
	values = ReverbData.DEFAULTS.duplicate()
	for id in new_values:
		values[id] = float(new_values[id])
	_update_span_target()
	queue_redraw()


func set_value(id: int, real: float) -> void:
	values[id] = real
	_update_span_target()
	queue_redraw()


func set_approximate(on: bool) -> void:
	if approximate != on:
		approximate = on
		queue_redraw()


func is_frozen() -> bool:
	return ReverbData.is_frozen(values)


## Where the -60 dB contour reaches at `freq` (s), infinite while frozen.
func contour_time(freq: float) -> float:
	return ReverbData.contour_time(freq, values)


func _update_span_target() -> void:
	if span_locked:
		return
	var target := ReverbData.span_target(values)
	if not _span_ready:
		_span_ready = true
		span = target
		span_target = target
		span_changed.emit(span)
		return
	if not is_equal_approx(target, span_target):
		span_target = target
		set_process(is_inside_tree())


func _process(delta: float) -> void:
	advance_span(delta)


## Ease the span toward its target (called each frame while they differ).
func advance_span(delta: float) -> void:
	if is_equal_approx(span, span_target):
		span = span_target
		set_process(false)
		return
	span += (span_target - span) * (1.0 - exp(-delta / SPAN_EASE_S))
	if absf(span - span_target) < span_target * 0.002:
		span = span_target
		set_process(false)
	span_changed.emit(span)
	queue_redraw()


## Jump to the target span now.
func snap_span() -> void:
	span = span_target
	set_process(false)
	span_changed.emit(span)
	queue_redraw()


# ============================================================================
# GEOMETRY
# ============================================================================

func plot_rect() -> Rect2:
	return Rect2(MARGIN_LEFT, MARGIN_TOP,
		maxf(size.x - MARGIN_LEFT - MARGIN_RIGHT, 1.0), maxf(size.y - MARGIN_TOP - MARGIN_BOTTOM, 1.0))


## Square-root time axis: x = sqrt(t / span) across the plot.
func x_of_t(t: float) -> float:
	var plot := plot_rect()
	return plot.position.x + sqrt(maxf(t, 0.0) / maxf(span, 1e-3)) * plot.size.x


func t_of_x(x: float) -> float:
	var plot := plot_rect()
	var frac := maxf((x - plot.position.x) / plot.size.x, 0.0)
	return frac * frac * span


func y_of_f(freq: float) -> float:
	var plot := plot_rect()
	var frac := log(clampf(freq, ReverbData.FREQ_MIN, ReverbData.FREQ_MAX) / ReverbData.FREQ_MIN) \
			/ log(ReverbData.FREQ_MAX / ReverbData.FREQ_MIN)
	return plot.end.y - frac * plot.size.y


func f_of_y(y: float) -> float:
	var plot := plot_rect()
	var frac := (plot.end.y - y) / plot.size.y
	return ReverbData.FREQ_MIN * pow(ReverbData.FREQ_MAX / ReverbData.FREQ_MIN, clampf(frac, 0.0, 1.0))


func _v(id: int) -> float:
	return float(values.get(id, ReverbData.DEFAULTS[id]))


func _pre() -> float:
	return _v(ReverbData.P_PREDELAY) * 0.001


## Local position of a handle, `Vector2.INF` for an unknown name.
func handle_position(handle: String) -> Vector2:
	var plot := plot_rect()
	match handle:
		H_CONTOUR:
			return Vector2(x_of_t(_pre() + ReverbData.band_t60_raw(1000.0, values)), y_of_f(1000.0))
		H_LOW_KNEE:
			return Vector2(x_of_t(_pre() + _v(ReverbData.P_DECAY) * _v(ReverbData.P_LOW_MULT)),
				y_of_f(_v(ReverbData.P_LOW_FREQ)))
		H_HIGH_KNEE:
			return Vector2(x_of_t(_pre() + _v(ReverbData.P_DECAY) * _v(ReverbData.P_HIGH_MULT)),
				y_of_f(_v(ReverbData.P_HIGH_FREQ)))
		H_PREDELAY:
			return Vector2(x_of_t(_pre()), plot.position.y + plot.size.y * 0.5)
		H_LOW_CUT:
			return Vector2(plot.position.x + plot.size.x * 0.4, y_of_f(_v(ReverbData.P_LOW_CUT)))
		H_HIGH_CUT:
			return Vector2(plot.position.x + plot.size.x * 0.4, y_of_f(_v(ReverbData.P_HIGH_CUT)))
	return Vector2.INF


func _handle_enabled(handle: String) -> bool:
	return not (is_frozen() and handle == H_CONTOUR)


## The handle under `pos` (priority: knees, contour, cut lines, Pre-Delay edge), or "".
func hit_test(pos: Vector2) -> String:
	var plot := plot_rect()
	if not plot.grow(HIT_RADIUS).has_point(pos):
		return ""
	for handle: String in [H_LOW_KNEE, H_HIGH_KNEE, H_CONTOUR]:
		if _handle_enabled(handle) and handle_position(handle).distance_to(pos) <= HIT_RADIUS:
			return handle
	for handle: String in [H_LOW_CUT, H_HIGH_CUT]:
		if absf(handle_position(handle).y - pos.y) <= LINE_HIT:
			return handle
	if absf(handle_position(H_PREDELAY).x - pos.x) <= LINE_HIT:
		return H_PREDELAY
	return ""


# ============================================================================
# DRAWING
# ============================================================================

## Shade for a level: transparent at the floor, the accent at 0 dB.
func _shade(db: float) -> Color:
	var a := clampf((db + 60.0) / 60.0, 0.0, 1.0)
	return Color(_fill_color.r, _fill_color.g, _fill_color.b, a * 0.95)


func _draw() -> void:
	var plot := plot_rect()
	draw_rect(plot, _bg_color)
	_draw_grid(plot)
	_draw_tail(plot)
	_draw_early(plot)
	_draw_pre_gap(plot)
	_draw_cuts(plot)
	_draw_contour(plot)
	_draw_handles(plot)
	_draw_marks(plot)
	draw_rect(plot, Color(1, 1, 1, 0.12), false, 1.0)


func _draw_grid(plot: Rect2) -> void:
	var font := get_theme_default_font()
	for freq in AXIS_FREQS:
		var y := y_of_f(freq)
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID_COLOR)
		if freq in [100.0, 1000.0, 10000.0]:
			var text := "%dk" % int(freq / 1000.0) if freq >= 1000.0 else "%d" % int(freq)
			draw_string(font, Vector2(2.0, y + 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, MARGIN_LEFT - 4.0, 10, LABEL_COLOR)
	draw_string(font, Vector2(plot.position.x + 2.0, size.y - 2.0), "0", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, LABEL_COLOR)
	var last_x := plot.position.x
	for t in TIME_STEPS:
		if t > span + 1e-6:
			break
		var x := x_of_t(t)
		if x - last_x < TIME_LABEL_GAP:
			continue
		last_x = x
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), GRID_COLOR)
		draw_string(font, Vector2(x + 2.0, size.y - 2.0), time_label(t), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, LABEL_COLOR)


## Grid label for `t` seconds: milliseconds under 1 s.
static func time_label(t: float) -> String:
	if t < 1.0:
		return "%d ms" % roundi(t * 1000.0)
	return "%s s" % str(snappedf(t, 0.01))


## One triangle mesh: a vertex per frequency row edge and time column, shaded by the predicted
## level and faded in over the onset (`ReverbData.tail_onset`). The columns are even in x plus
## extra samples across the onset, so the square-root axis and the fade-in both stay smooth.
func _draw_tail(plot: Rect2) -> void:
	var pre := _pre()
	var x0 := x_of_t(pre)
	if x0 >= plot.end.x:
		return
	var times := tail_sample_times(plot)
	var ratio := ReverbData.FREQ_MAX / ReverbData.FREQ_MIN
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	for i in ROWS + 1:
		var f := ReverbData.FREQ_MIN * pow(ratio, float(i) / ROWS)
		var y := y_of_f(f)
		for t in times:
			points.append(Vector2(x_of_t(t), y))
			var c := _shade(ReverbData.level_db(t, f, values))
			c.a *= ReverbData.tail_onset(t, values)
			colors.append(c)
	var cols := times.size()
	var indices := PackedInt32Array()
	for i in ROWS:
		for j in cols - 1:
			var a := i * cols + j
			var b := a + cols
			indices.append_array([a, a + 1, b + 1, a, b + 1, b])
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), indices, points, colors)


## The times (s, ascending) the tail mesh samples: Pre-Delay, the onset, then even steps in x to
## the right edge.
func tail_sample_times(plot: Rect2) -> PackedFloat32Array:
	var pre := _pre()
	var build := ReverbData.tail_build_s(values)
	var times := PackedFloat32Array()
	for k in ONSET_SAMPLES + 1:
		times.append(pre + build * float(k) / ONSET_SAMPLES)
	var x0 := x_of_t(pre + build)
	for k in range(1, TAIL_COLUMNS + 1):
		var t := t_of_x(x0 + (plot.end.x - x0) * float(k) / TAIL_COLUMNS)
		if t > times[times.size() - 1]:
			times.append(t)
	return times


## The early reflections (both channels in one row) as broadband columns, brightness from the
## tap level. Diffusion widens each column into a soft smear (fainter as it spreads) that runs
## into the tail; at 0 % they are hairlines, discrete echoes.
func _draw_early(plot: Rect2) -> void:
	var blur := ReverbData.early_blur_s(values)
	for tick in ReverbData.early_ticks(values):
		var t := float(tick["t"])
		var x := x_of_t(t)
		if x > plot.end.x:
			continue
		var level := clampf((float(tick["db"]) + 40.0) / 40.0, 0.0, 1.0)
		if level <= 0.0:
			continue
		var left := maxf(x - x_of_t(maxf(t - blur, 0.0)), 0.5)
		var right := maxf(x_of_t(t + blur) - x, 0.5)
		var peak := level * 0.85 * clampf(1.5 / (left + right), 0.2, 1.0)
		var c := Color(EARLY_COLOR, peak)
		var clear := Color(EARLY_COLOR, 0.0)
		var top := plot.position.y
		var bottom := plot.end.y
		draw_polygon(PackedVector2Array([Vector2(x - left, top), Vector2(x, top), Vector2(x, bottom), Vector2(x - left, bottom)]),
			PackedColorArray([clear, c, c, clear]))
		draw_polygon(PackedVector2Array([Vector2(x, top), Vector2(x + right, top), Vector2(x + right, bottom), Vector2(x, bottom)]),
			PackedColorArray([c, clear, clear, c]))


func _draw_pre_gap(plot: Rect2) -> void:
	var x := x_of_t(_pre())
	if x > plot.position.x:
		draw_rect(Rect2(plot.position.x, plot.position.y, minf(x, plot.end.x) - plot.position.x, plot.size.y), Color(0, 0, 0, 0.25))
	var active := _hover == H_PREDELAY or _drag == H_PREDELAY
	draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), Color(1, 1, 1, 0.8 if active else 0.3), 1.5 if active else 1.0)


func _draw_cuts(plot: Rect2) -> void:
	var low_y := y_of_f(_v(ReverbData.P_LOW_CUT))
	var high_y := y_of_f(_v(ReverbData.P_HIGH_CUT))
	var veil := Color(_bg_color.r, _bg_color.g, _bg_color.b, 0.55)
	draw_rect(Rect2(plot.position.x, low_y, plot.size.x, plot.end.y - low_y), veil)
	draw_rect(Rect2(plot.position.x, plot.position.y, plot.size.x, high_y - plot.position.y), veil)
	for pair in [[H_LOW_CUT, low_y], [H_HIGH_CUT, high_y]]:
		var active: bool = _hover == pair[0] or _drag == pair[0]
		draw_line(Vector2(plot.position.x, pair[1]), Vector2(plot.end.x, pair[1]),
			Color(1, 1, 1, 0.8 if active else CUT_COLOR.a), 1.5 if active else 1.0)


func _draw_contour(_plot: Rect2) -> void:
	if is_frozen():
		return
	var points := PackedVector2Array()
	var ratio := ReverbData.FREQ_MAX / ReverbData.FREQ_MIN
	for i in ROWS + 1:
		var f := ReverbData.FREQ_MIN * pow(ratio, float(i) / ROWS)
		points.append(Vector2(minf(x_of_t(_pre() + ReverbData.band_t60(f, values)), plot_rect().end.x), y_of_f(f)))
	if approximate:
		# Dashed: pairs of segments, a gap every third.
		for i in range(0, points.size() - 1, 3):
			draw_line(points[i], points[mini(i + 1, points.size() - 1)], CONTOUR_COLOR, 1.5)
	else:
		draw_polyline(points, CONTOUR_COLOR, 1.5)


func _draw_handles(plot: Rect2) -> void:
	for handle: String in [H_CONTOUR, H_LOW_KNEE, H_HIGH_KNEE]:
		var pos := handle_position(handle)
		if not plot.grow(HANDLE_RADIUS).has_point(pos):
			continue
		var enabled := _handle_enabled(handle)
		var active: bool = enabled and (_hover == handle or _drag == handle)
		var color := Color(1, 1, 1, 1.0 if active else (0.8 if enabled else 0.25))
		if handle == H_CONTOUR:
			draw_circle(pos, HANDLE_RADIUS, Color(0, 0, 0, 0.6))
			draw_arc(pos, HANDLE_RADIUS, 0.0, TAU, 20, color, 1.5 if not active else 2.5)
		else:
			var r := HANDLE_RADIUS
			var diamond := PackedVector2Array([pos + Vector2(0, -r), pos + Vector2(r, 0), pos + Vector2(0, r), pos + Vector2(-r, 0)])
			draw_colored_polygon(diamond, Color(0, 0, 0, 0.6))
			draw_polyline(diamond + PackedVector2Array([diamond[0]]), color, 1.5 if not active else 2.5)


func _draw_marks(plot: Rect2) -> void:
	var font := get_theme_default_font()
	if is_frozen():
		draw_string(font, Vector2(plot.position.x, plot.position.y + 14.0), "❄ FROZEN", HORIZONTAL_ALIGNMENT_RIGHT, plot.size.x - 6.0, 12, FROST_COLOR)
	if approximate:
		draw_string(font, Vector2(plot.position.x + 6.0, plot.position.y + 14.0), "≈ Tank FX", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, LABEL_COLOR)


# ============================================================================
# INTERACTION
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			var handle := hit_test(mb.position)
			if handle.is_empty():
				return
			accept_event()
			if mb.double_click:
				_reset_handle(handle)
				return
			_begin_drag(handle)
			_drag_to(mb.position)
		else:
			if not _drag.is_empty():
				accept_event()
				_end_drag()
				_update_hover(mb.position)
		return
	var mm := event as InputEventMouseMotion
	if mm != null:
		if _drag.is_empty():
			_update_hover(mm.position)
		else:
			accept_event()
			_drag_to(mm.position)


func _on_mouse_exited() -> void:
	if _drag.is_empty():
		_set_hover("")


func _update_hover(pos: Vector2) -> void:
	_set_hover(hit_test(pos))


func _set_hover(handle: String) -> void:
	if handle == _hover:
		return
	_hover = handle
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not handle.is_empty() else Control.CURSOR_ARROW
	_refresh_tooltip()
	queue_redraw()


func _begin_drag(handle: String) -> void:
	_drag = handle
	span_locked = true
	ParameterActions.begin_gesture()
	_refresh_tooltip()
	queue_redraw()


func _end_drag() -> void:
	if _drag.is_empty():
		return
	_drag = ""
	ParameterActions.end_gesture()
	span_locked = false
	_update_span_target()
	_refresh_tooltip()
	queue_redraw()


func is_dragging() -> bool:
	return not _drag.is_empty()


## The ids a handle edits.
func handle_params(handle: String) -> Array[int]:
	match handle:
		H_CONTOUR:
			return [ReverbData.P_DECAY]
		H_LOW_KNEE:
			return [ReverbData.P_LOW_MULT, ReverbData.P_LOW_FREQ]
		H_HIGH_KNEE:
			return [ReverbData.P_HIGH_MULT, ReverbData.P_HIGH_FREQ]
		H_PREDELAY:
			return [ReverbData.P_PREDELAY]
		H_LOW_CUT:
			return [ReverbData.P_LOW_CUT]
		H_HIGH_CUT:
			return [ReverbData.P_HIGH_CUT]
	return []


func _clamp_param(id: int, real: float) -> float:
	var limits: Vector2 = ReverbData.RANGES[id]
	return clampf(real, limits.x, limits.y)


func _write(id: int, real: float) -> void:
	real = _clamp_param(id, real)
	if device != null:
		ParameterActions.set_real(device, id, real)
		real = device.get_parameter_real(id)
	values[id] = real
	queue_redraw()


func _drag_to(pos: Vector2) -> void:
	var t := t_of_x(pos.x)
	var pre := _pre()
	var frozen := is_frozen()
	match _drag:
		H_CONTOUR:
			if not frozen:
				# One proportional step from the current tail; the next motion refines it.
				var current := ReverbData.band_t60_raw(1000.0, values)
				_write(ReverbData.P_DECAY, _v(ReverbData.P_DECAY) * maxf(t - pre, 0.001) / maxf(current, 1e-4))
		H_LOW_KNEE:
			if not frozen:
				_write(ReverbData.P_LOW_MULT, (t - pre) / _v(ReverbData.P_DECAY))
			_write(ReverbData.P_LOW_FREQ, f_of_y(pos.y))
		H_HIGH_KNEE:
			if not frozen:
				_write(ReverbData.P_HIGH_MULT, (t - pre) / _v(ReverbData.P_DECAY))
			_write(ReverbData.P_HIGH_FREQ, f_of_y(pos.y))
		H_PREDELAY:
			_write(ReverbData.P_PREDELAY, t * 1000.0)
		H_LOW_CUT:
			_write(ReverbData.P_LOW_CUT, f_of_y(pos.y))
		H_HIGH_CUT:
			_write(ReverbData.P_HIGH_CUT, f_of_y(pos.y))
	_refresh_tooltip()


func _reset_handle(handle: String) -> void:
	for id in handle_params(handle):
		if device != null:
			ParameterActions.reset(device, id)
			values[id] = device.get_parameter_real(id)
		else:
			values[id] = ReverbData.DEFAULTS[id]
	_update_span_target()
	queue_redraw()


# ============================================================================
# TOOLTIP
# ============================================================================

## The text a handle's tooltip shows (the same formats as the knobs).
func handle_text(handle: String) -> String:
	match handle:
		H_CONTOUR:
			return "Decay %s" % ReverbData.format_value(ReverbData.P_DECAY, _v(ReverbData.P_DECAY))
		H_LOW_KNEE:
			return "Low %s @ %s" % [ReverbData.format_value(ReverbData.P_LOW_MULT, _v(ReverbData.P_LOW_MULT)),
				ReverbData.format_value(ReverbData.P_LOW_FREQ, _v(ReverbData.P_LOW_FREQ))]
		H_HIGH_KNEE:
			return "High %s @ %s" % [ReverbData.format_value(ReverbData.P_HIGH_MULT, _v(ReverbData.P_HIGH_MULT)),
				ReverbData.format_value(ReverbData.P_HIGH_FREQ, _v(ReverbData.P_HIGH_FREQ))]
		H_PREDELAY:
			return "Pre-Delay %s" % ReverbData.format_value(ReverbData.P_PREDELAY, _v(ReverbData.P_PREDELAY))
		H_LOW_CUT:
			return "Low Cut %s" % ReverbData.format_value(ReverbData.P_LOW_CUT, _v(ReverbData.P_LOW_CUT))
		H_HIGH_CUT:
			return "High Cut %s" % ReverbData.format_value(ReverbData.P_HIGH_CUT, _v(ReverbData.P_HIGH_CUT))
	return ""


func tooltip_visible() -> bool:
	return _tooltip != null and _tooltip.visible


func _refresh_tooltip() -> void:
	if _tooltip == null:
		return
	var handle := _drag if not _drag.is_empty() else _hover
	if handle.is_empty():
		_tooltip.hide()
		return
	_tooltip.set_text(handle_text(handle))
	_tooltip.show()
	if is_inside_tree():
		var pos := handle_position(handle)
		_tooltip.place_above(Rect2(get_global_transform() * pos - Vector2(4, 4), Vector2(8, 8)))
