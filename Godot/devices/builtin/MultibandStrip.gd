## Crossover strip of the Multiband FX view: a log frequency axis (20 Hz–20 kHz) with each active
## band's region filled in its slot color and one draggable handle per crossover (the `Low Edge` of
## every active band except the lowest). Dragging writes that band's `Low Edge`, clamped between the
## neighbouring active crossovers (spec 016 D6); the engine enforces the same order on its own.
class_name MultibandStrip extends Control

const HANDLE_GRAB := 7.0
const AXIS_HEIGHT := 14.0
const TICKS := [20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0]

var mb: DeviceInstance = null

var _drag_band := 0
var _drag_old := 0.0
var _hover_band := 0


func _init() -> void:
	custom_minimum_size = Vector2(240, 72)
	mouse_filter = Control.MOUSE_FILTER_STOP


func bind(p_mb: DeviceInstance) -> void:
	mb = p_mb
	queue_redraw()


func _x_of(hz: float) -> float:
	return Multiband.freq_to_norm(hz) * size.x


func _hz_at(x: float) -> float:
	return Multiband.norm_to_freq(x / maxf(size.x, 1.0))


## Crossover handles as {band: position, hz: edge} for every active band but the lowest.
func _crossovers() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if mb == null:
		return out
	var active := Multiband.active_positions(mb)
	for i in range(1, active.size()):
		out.append({"band": active[i], "hz": Multiband.edge_hz(mb, active[i])})
	return out


## Allowed range of band `position`'s edge between its active neighbours (D6).
func edge_limits(position: int) -> Vector2:
	var active := Multiband.active_positions(mb)
	var i := active.find(position)
	var lo := Multiband.FREQ_MIN
	var hi := Multiband.FREQ_MAX
	if i > 1:
		lo = Multiband.edge_hz(mb, active[i - 1]) * Multiband.MIN_RATIO
	if i >= 0 and i + 1 < active.size():
		hi = Multiband.edge_hz(mb, active[i + 1]) / Multiband.MIN_RATIO
	return Vector2(lo, maxf(lo, hi))


func _draw() -> void:
	if mb == null:
		return
	var h := size.y - AXIS_HEIGHT
	var font := get_theme_default_font()
	var font_size := 10
	draw_rect(Rect2(0, 0, size.x, h), Color(0.09, 0.09, 0.09))
	var active := Multiband.active_positions(mb)
	var names := Multiband.auto_names(mb)
	for i in active.size():
		var p := active[i]
		var x0 := 0.0 if i == 0 else _x_of(Multiband.edge_hz(mb, p))
		var x1 := size.x if i + 1 >= active.size() else _x_of(Multiband.edge_hz(mb, active[i + 1]))
		var color := _band_color(p)
		draw_rect(Rect2(x0, 0, x1 - x0, h), Color(color, 0.28))
		draw_rect(Rect2(x0, 0, x1 - x0, 3), color)
		var label := mb.children[p - 1].get_display_name() if p <= mb.children.size() else names[p - 1]
		if x1 - x0 > 30.0:
			draw_string(font, Vector2(x0 + 5, 17), label, HORIZONTAL_ALIGNMENT_LEFT, x1 - x0 - 8, font_size, Color(1, 1, 1, 0.85))
	for hz in TICKS:
		var x := _x_of(hz)
		draw_line(Vector2(x, h), Vector2(x, h + 3), Color(0.5, 0.5, 0.5))
		var text := "%dk" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_string(font, Vector2(clampf(x - w * 0.5, 0.0, size.x - w), h + AXIS_HEIGHT - 2), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.6, 0.6, 0.6))
	for cross in _crossovers():
		var x := _x_of(cross["hz"])
		var live: bool = int(cross["band"]) == _drag_band or int(cross["band"]) == _hover_band
		draw_line(Vector2(x, 0), Vector2(x, h), Color.WHITE if live else Color(1, 1, 1, 0.7), 2.0 if live else 1.5)
		draw_rect(Rect2(x - 4, h * 0.5 - 8, 8, 16), Color.WHITE if live else Color(0.85, 0.85, 0.85))
		var label := _format_hz(cross["hz"])
		var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_string(font, Vector2(clampf(x - w * 0.5, 0.0, size.x - w), h - 5), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


func _band_color(position: int) -> Color:
	if position <= mb.children.size():
		return mb.slot_color(mb.slot_key_for(mb.children[position - 1]))
	return Multiband.band_color(position)


static func _format_hz(hz: float) -> String:
	return "%.2f kHz" % (hz / 1000.0) if hz >= 1000.0 else "%d Hz" % int(round(hz))


func _handle_at(x: float) -> int:
	var best := 0
	var best_dist := HANDLE_GRAB
	for cross in _crossovers():
		var d := absf(_x_of(cross["hz"]) - x)
		if d <= best_dist:
			best_dist = d
			best = int(cross["band"])
	return best


func _gui_input(event: InputEvent) -> void:
	if mb == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_band = _handle_at(event.position.x)
			if _drag_band > 0:
				_drag_old = mb.get_parameter_normalized(Multiband.param_id(_drag_band, Multiband.OFFSET_EDGE))
				if event.double_click:
					_reset_edge(_drag_band)
					_drag_band = 0
		elif _drag_band > 0:
			_finish_drag()
		queue_redraw()
	elif event is InputEventMouseMotion:
		if _drag_band > 0:
			var limits := edge_limits(_drag_band)
			var hz := clampf(_hz_at(event.position.x), limits.x, limits.y)
			mb.set_parameter_normalized(Multiband.param_id(_drag_band, Multiband.OFFSET_EDGE), Multiband.freq_to_norm(hz))
		else:
			var hover := _handle_at(event.position.x)
			if hover != _hover_band:
				_hover_band = hover
		mouse_default_cursor_shape = Control.CURSOR_HSIZE if (_drag_band > 0 or _hover_band > 0) else Control.CURSOR_ARROW
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover_band = 0
		queue_redraw()
	elif what == NOTIFICATION_RESIZED:
		queue_redraw()


## Record the finished drag as one undo step.
func _finish_drag() -> void:
	var id := Multiband.param_id(_drag_band, Multiband.OFFSET_EDGE)
	var now := mb.get_parameter_normalized(id)
	if absf(now - _drag_old) > 0.0001:
		var target := mb
		var cmd := PropertyCommand.new("Move Crossover", null, "", _drag_old, now)
		HistoryUtil.record(cmd.set_callable(func(v): target.set_parameter_normalized(id, v)))
	_drag_band = 0


## Double-click: back to the parameter default, if it still fits between the neighbours.
func _reset_edge(position: int) -> void:
	var param := mb.get_parameter(Multiband.param_id(position, Multiband.OFFSET_EDGE))
	if param == null:
		return
	var limits := edge_limits(position)
	var hz := clampf(float(param.default_value), limits.x, limits.y)
	var id := param.id
	var old := mb.get_parameter_normalized(id)
	mb.set_parameter_normalized(id, Multiband.freq_to_norm(hz))
	var now := mb.get_parameter_normalized(id)
	if absf(now - old) > 0.0001:
		var target := mb
		var cmd := PropertyCommand.new("Reset Crossover", null, "", old, now)
		HistoryUtil.record(cmd.set_callable(func(v): target.set_parameter_normalized(id, v)))
