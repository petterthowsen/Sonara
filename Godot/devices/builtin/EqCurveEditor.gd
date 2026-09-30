## The EQ's curve editor: log-frequency and dB grids, the analyser behind the curve, the combined
## curve and each band's own, draggable band nodes, and a piano strip along the bottom edge.
##
## Gestures on a node: drag = frequency and gain (Shift = fine), wheel = Q (Shift = fine),
## double-click = disable the band, right-click = Type / Slope / Stereo menu, Alt or middle button
## held = listen to the band. Double-click on empty space enables the first free band there.
##
## The editor never talks to the engine: every edit goes through `device.set_parameter_real`
## (the DeviceInstance setter), and the curve redraws from `parameter_changed`. It references no
## autoloads, so tests can drive it headless.
class_name EqCurveEditor extends Control

## The view state (analyser mode, dB range) changed; the owner persists it.
signal view_state_changed
signal band_hovered(band: int)

const PIANO_HEIGHT := 12.0
const NODE_RADIUS := 7.0
const HIT_RADIUS := 11.0
const WHEEL_Q_STEP := 1.12
const WHEEL_Q_FINE_STEP := 1.03
## The analyser's own scale (dBFS), drawn behind the EQ curve over the whole plot height.
const ANALYSER_FLOOR_DB := -90.0
const ANALYSER_CEIL_DB := 0.0

const BG_COLOR := Color(0.067, 0.067, 0.067)
const GRID_COLOR := Color(1, 1, 1, 0.06)
const GRID_MAJOR_COLOR := Color(1, 1, 1, 0.12)
const ZERO_COLOR := Color(1, 1, 1, 0.3)
const LABEL_COLOR := Color(1, 1, 1, 0.45)
const TOTAL_COLOR := Color(0.96, 0.96, 0.96, 0.95)
const POST_FILL := Color(0.3, 0.55, 1.0, 0.3)
const POST_LINE := Color(0.45, 0.68, 1.0, 0.9)
const PRE_LINE := Color(1, 1, 1, 0.22)

## The DeviceInstance (typed loosely: this script must not depend on autoload-using classes).
var device: RefCounted = null:
	set = set_device
var state := EqViewState.new():
	set(value):
		state = value
		_curves_dirty = true
		queue_redraw()
var sample_rate := 48000.0:
	set(value):
		sample_rate = value
		_curves_dirty = true
		queue_redraw()

var freq_axis := FreqAxis.new()
var db_grid := DbGrid.new()
## One Dictionary per band (see EqResponse).
var bands: Array = []
var output_gain_db := 0.0
var hover_band := -1
var drag_band := -1
var listen_band := -1

var _fine := FineDrag.new()
var _curve_freqs := PackedFloat32Array()
var _curves: Array[PackedFloat32Array] = []
var _total := PackedFloat32Array()
var _curves_dirty := true
var _pre_bins := PackedFloat32Array()
var _post_bins := PackedFloat32Array()
var _bin_rate := 48000.0
var _menu: PopupMenu
var _type_menu: PopupMenu
var _slope_menu: PopupMenu
var _stereo_menu: PopupMenu
var _menu_band := -1
var _font: Font


func _init() -> void:
	custom_minimum_size = Vector2(320, 150)
	clip_contents = true
	_reset_bands()


func _ready() -> void:
	_font = ThemeDB.fallback_font
	_build_menus()


func _reset_bands() -> void:
	bands = []
	for i in EqResponse.BAND_COUNT:
		bands.append(EqResponse.default_band(i))


# ============================================================================
# DEVICE
# ============================================================================

func set_device(value: RefCounted) -> void:
	if device != null and device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.disconnect(_on_parameter_changed)
	device = value
	if device != null:
		device.parameter_changed.connect(_on_parameter_changed)
	refresh_all()


func refresh_all() -> void:
	for i in EqResponse.BAND_COUNT:
		_read_band(i)
	output_gain_db = _real(EqResponse.OUTPUT_GAIN, 0.0)
	var listen := int(_real(EqResponse.LISTEN_BAND, 0.0))
	listen_band = listen - 1
	_curves_dirty = true
	queue_redraw()


func _read_band(i: int) -> void:
	if device == null:
		bands[i] = EqResponse.default_band(i)
		return
	var base := i * EqResponse.BAND_STRIDE
	bands[i] = {
		"enabled": _real(base + EqResponse.P_ENABLED, 0.0) >= 0.5,
		"type": int(_real(base + EqResponse.P_TYPE, 0.0)),
		"freq": _real(base + EqResponse.P_FREQ, 1000.0),
		"gain": _real(base + EqResponse.P_GAIN, 0.0),
		"q": _real(base + EqResponse.P_Q, 0.71),
		"slope": int(_real(base + EqResponse.P_SLOPE, 1.0)),
		"stereo": int(_real(base + EqResponse.P_STEREO, 0.0)),
	}


func _real(param_id: int, fallback: float) -> float:
	if device == null or device.get_parameter(param_id) == null:
		return fallback
	return device.get_parameter_real(param_id)


func _on_parameter_changed(param_id: int, _value: float) -> void:
	if param_id < EqResponse.BAND_COUNT * EqResponse.BAND_STRIDE:
		_read_band(param_id / EqResponse.BAND_STRIDE)
	elif param_id == EqResponse.OUTPUT_GAIN:
		output_gain_db = _real(EqResponse.OUTPUT_GAIN, 0.0)
	elif param_id == EqResponse.LISTEN_BAND:
		listen_band = int(_real(EqResponse.LISTEN_BAND, 0.0)) - 1
	_curves_dirty = true
	queue_redraw()


## Write one parameter of band `band` in real units (Hz, dB, enum index) through the device.
func set_band_param(band: int, offset: int, real_value: float) -> void:
	if device != null:
		device.set_parameter_real(band * EqResponse.BAND_STRIDE + offset, real_value)


# ============================================================================
# ANALYSER
# ============================================================================

## A `"spectrum"` frame from the engine: [flag, sample_rate, bins...] (flag 0 = pre, 1 = post).
func on_spectrum_frame(frame: PackedFloat32Array) -> void:
	if frame.size() < 4:
		return
	var bins := frame.slice(2)
	_bin_rate = frame[1]
	if frame[0] >= 0.5:
		_post_bins = bins
	else:
		_pre_bins = bins
	if frame[1] > 0.0 and not is_equal_approx(frame[1], sample_rate):
		sample_rate = frame[1]
	queue_redraw()


func clear_analyser() -> void:
	_pre_bins = PackedFloat32Array()
	_post_bins = PackedFloat32Array()
	queue_redraw()


func set_analyser_mode(mode: int) -> void:
	if state.analyser == mode:
		return
	state.analyser = mode
	if mode == EqViewState.Analyser.OFF:
		clear_analyser()
	view_state_changed.emit()
	queue_redraw()


func set_range_db(range_db: float) -> void:
	if is_equal_approx(state.range_db, range_db):
		return
	state.range_db = range_db
	_curves_dirty = true
	view_state_changed.emit()
	queue_redraw()


# ============================================================================
# GEOMETRY
# ============================================================================

func plot_rect() -> Rect2:
	return Rect2(0, 0, size.x, maxf(size.y - PIANO_HEIGHT, 1.0))


func piano_rect() -> Rect2:
	return Rect2(0, maxf(size.y - PIANO_HEIGHT, 0.0), size.x, PIANO_HEIGHT)


func _update_layout() -> void:
	var plot := plot_rect()
	freq_axis.rect = plot
	db_grid.rect = plot
	db_grid.set_symmetric(state.range_db)


## Where a band's node sits: its frequency, at its gain when the type has one, else on 0 dB.
func node_position(band: Dictionary) -> Vector2:
	_update_layout()
	var gain: float = band["gain"] if EqResponse.type_uses_gain(band["type"]) else 0.0
	return Vector2(freq_axis.hz_to_x(band["freq"]), db_grid.db_to_y(gain))


## The enabled band whose node is nearest to `pos` within the hit radius, or -1.
func band_at(pos: Vector2) -> int:
	var best := -1
	var best_distance := HIT_RADIUS
	for i in bands.size():
		if not bands[i]["enabled"]:
			continue
		var distance := node_position(bands[i]).distance_to(pos)
		if distance <= best_distance:
			best_distance = distance
			best = i
	return best


func first_free_band() -> int:
	for i in bands.size():
		if not bands[i]["enabled"]:
			return i
	return -1


# ============================================================================
# EDITING
# ============================================================================

## Enable the first free band at `pos` (Bell, except that bands 1 and 8 keep their default Low and
## High Cut type when the click is within the outer octave of the range). Returns the band or -1.
func enable_band_at(pos: Vector2) -> int:
	var band := first_free_band()
	if band < 0:
		return -1
	_update_layout()
	var freq := freq_axis.x_to_hz(pos.x)
	var type: int = bands[band]["type"]
	if EqResponse.type_is_cut(type) and freq > 40.0 and freq < 12000.0:
		type = EqResponse.Type.BELL
		set_band_param(band, EqResponse.P_TYPE, float(type))
	set_band_param(band, EqResponse.P_FREQ, freq)
	if EqResponse.type_uses_gain(type):
		set_band_param(band, EqResponse.P_GAIN, db_grid.y_to_db(pos.y))
	set_band_param(band, EqResponse.P_ENABLED, 1.0)
	return band


func disable_band(band: int) -> void:
	if listen_band == band:
		end_listen()
	set_band_param(band, EqResponse.P_ENABLED, 0.0)


## Move band `band`'s node to the plot point `point`: frequency, and gain where the type has one.
func drag_band_to(band: int, point: Vector2) -> void:
	_update_layout()
	set_band_param(band, EqResponse.P_FREQ, clampf(freq_axis.x_to_hz(point.x), EqResponse.MIN_FREQ, EqResponse.MAX_FREQ))
	if EqResponse.type_uses_gain(bands[band]["type"]):
		set_band_param(band, EqResponse.P_GAIN, clampf(db_grid.y_to_db(point.y), -EqResponse.MAX_GAIN, EqResponse.MAX_GAIN))


## Scale band `band`'s Q by one wheel notch (`direction` +1 narrows, -1 widens).
func step_q(band: int, direction: int, fine: bool) -> void:
	var step := WHEEL_Q_FINE_STEP if fine else WHEEL_Q_STEP
	var q: float = bands[band]["q"] * pow(step, direction)
	set_band_param(band, EqResponse.P_Q, clampf(q, EqResponse.MIN_Q, EqResponse.MAX_Q))


func begin_listen(band: int) -> void:
	listen_band = band
	if device != null:
		device.set_parameter_real(EqResponse.LISTEN_BAND, float(band + 1))


func end_listen() -> void:
	if listen_band < 0:
		return
	listen_band = -1
	if device != null:
		device.set_parameter_real(EqResponse.LISTEN_BAND, 0.0)


## Stop any drag or listen in progress (the view is hiding).
func end_interaction() -> void:
	drag_band = -1
	end_listen()


# ============================================================================
# INPUT
# ============================================================================

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)


func _on_mouse_button(mb: InputEventMouseButton) -> void:
	var band := band_at(mb.position)
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					drag_band = -1
					if band >= 0:
						disable_band(band)
					else:
						enable_band_at(mb.position)
					accept_event()
				elif band >= 0:
					drag_band = band
					_fine.begin_at(node_position(bands[band]), mb.position)
					if mb.alt_pressed:
						begin_listen(band)
					accept_event()
				queue_redraw()
			else:
				drag_band = -1
				if listen_band >= 0:
					end_listen()
				queue_redraw()
		MOUSE_BUTTON_MIDDLE:
			if mb.pressed and band >= 0:
				begin_listen(band)
				accept_event()
			elif not mb.pressed:
				end_listen()
		MOUSE_BUTTON_RIGHT:
			if mb.pressed and band >= 0:
				_open_menu(band, mb.global_position)
				accept_event()
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed and band >= 0:
				step_q(band, 1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1, mb.shift_pressed)
				accept_event()


func _on_mouse_motion(motion: InputEventMouseMotion) -> void:
	if drag_band >= 0:
		var point := _fine.update(motion.position, motion.shift_pressed, plot_rect())
		drag_band_to(drag_band, point)
		queue_redraw()
		return
	var band := band_at(motion.position)
	if band != hover_band:
		hover_band = band
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if band >= 0 else Control.CURSOR_ARROW
		band_hovered.emit(band)
		queue_redraw()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_curves_dirty = true
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			if drag_band < 0 and hover_band >= 0:
				hover_band = -1
				band_hovered.emit(-1)
				queue_redraw()
		NOTIFICATION_VISIBILITY_CHANGED:
			if not is_visible_in_tree():
				end_interaction()


# ============================================================================
# CONTEXT MENU
# ============================================================================

func _build_menus() -> void:
	if _menu != null:
		return
	_menu = PopupMenu.new()
	_type_menu = PopupMenu.new()
	_slope_menu = PopupMenu.new()
	_stereo_menu = PopupMenu.new()
	for sub in [_type_menu, _slope_menu, _stereo_menu]:
		_menu.add_child(sub)
	for i in EqResponse.TYPE_NAMES.size():
		_type_menu.add_radio_check_item(EqResponse.TYPE_NAMES[i], i)
	for i in EqResponse.SLOPE_NAMES.size():
		_slope_menu.add_radio_check_item(EqResponse.SLOPE_NAMES[i], i)
	for i in EqResponse.STEREO_NAMES.size():
		_stereo_menu.add_radio_check_item(EqResponse.STEREO_NAMES[i], i)
	_type_menu.id_pressed.connect(func(id: int) -> void: set_band_param(_menu_band, EqResponse.P_TYPE, float(id)))
	_slope_menu.id_pressed.connect(func(id: int) -> void: set_band_param(_menu_band, EqResponse.P_SLOPE, float(id)))
	_stereo_menu.id_pressed.connect(func(id: int) -> void: set_band_param(_menu_band, EqResponse.P_STEREO, float(id)))
	_menu.id_pressed.connect(func(id: int) -> void:
		if id == 100:
			disable_band(_menu_band))
	add_child(_menu)


func _open_menu(band: int, global_pos: Vector2) -> void:
	_build_menus()
	_menu_band = band
	var b: Dictionary = bands[band]
	_menu.clear()
	_menu.add_item("Band %d" % (band + 1), 101)
	_menu.set_item_disabled(0, true)
	_menu.add_separator()
	for i in _type_menu.item_count:
		_type_menu.set_item_checked(i, i == b["type"])
	for i in _slope_menu.item_count:
		_slope_menu.set_item_checked(i, i == b["slope"])
	for i in _stereo_menu.item_count:
		_stereo_menu.set_item_checked(i, i == b["stereo"])
	_menu.add_submenu_node_item("Type", _type_menu)
	if EqResponse.type_is_cut(b["type"]):
		_menu.add_submenu_node_item("Slope", _slope_menu)
	_menu.add_submenu_node_item("Stereo", _stereo_menu)
	_menu.add_separator()
	_menu.add_item("Disable", 100)
	_menu.popup(Rect2i(Vector2i(global_pos), Vector2i.ZERO))


# ============================================================================
# DRAWING
# ============================================================================

static func band_color(band: int) -> Color:
	return Color.from_hsv(fposmod(0.02 + float(band) / float(EqResponse.BAND_COUNT), 1.0), 0.62, 0.98)


func _update_curves() -> void:
	var plot := plot_rect()
	var count := maxi(int(plot.size.x / 2.0), 32)
	_curve_freqs = EqResponse.log_frequencies(count)
	_curves = EqResponse.band_curves(bands, _curve_freqs, sample_rate)
	_total = EqResponse.total_curve(_curves, count, output_gain_db)
	_curves_dirty = false


func _curve_points(curve: PackedFloat32Array) -> PackedVector2Array:
	var plot := plot_rect()
	var points := PackedVector2Array()
	var n := curve.size()
	points.resize(n)
	for i in n:
		points[i] = Vector2(plot.position.x + plot.size.x * float(i) / float(n - 1), db_grid.db_to_y(curve[i]))
	return points


func _draw() -> void:
	_update_layout()
	if _curves_dirty:
		_update_curves()
	var plot := plot_rect()
	draw_rect(plot, BG_COLOR)
	var font := _font if _font != null else ThemeDB.fallback_font
	freq_axis.draw_grid(self, font, 10, GRID_COLOR, GRID_MAJOR_COLOR, LABEL_COLOR)
	db_grid.draw_grid(self, font, 10, GRID_MAJOR_COLOR, ZERO_COLOR, LABEL_COLOR)
	_draw_analyser()
	var hot := drag_band if drag_band >= 0 else hover_band
	for i in bands.size():
		if not bands[i]["enabled"] or i >= _curves.size() or _curves[i].is_empty():
			continue
		var points := _curve_points(_curves[i])
		var color := band_color(i)
		if i == hot:
			_draw_band_fill(points, color)
		draw_polyline(points, Color(color, 0.85 if i == hot else 0.55), 1.5, true)
	if _total.size() > 1:
		draw_polyline(_curve_points(_total), TOTAL_COLOR, 2.0, true)
	for i in bands.size():
		if bands[i]["enabled"]:
			_draw_node(i, i == hot)
	if hot >= 0 and bands[hot]["enabled"]:
		_draw_readout(hot, font)
	freq_axis.draw_piano_strip(self, piano_rect(), font, 8)


## Faint vertical fill between a band's curve and the 0 dB line.
func _draw_band_fill(points: PackedVector2Array, color: Color) -> void:
	var zero_y := db_grid.db_to_y(0.0)
	var lines := PackedVector2Array()
	for i in range(0, points.size(), 1):
		lines.append(Vector2(points[i].x, zero_y))
		lines.append(points[i])
	draw_multiline(lines, Color(color, 0.14), 2.0)


func _draw_node(band: int, hot: bool) -> void:
	var pos := node_position(bands[band])
	var color := band_color(band)
	var listening := band == listen_band
	if listening:
		draw_circle(pos, NODE_RADIUS + 5.0, Color(1, 0.9, 0.3, 0.3))
	draw_circle(pos, NODE_RADIUS + 1.5, Color(0, 0, 0, 0.6))
	draw_circle(pos, NODE_RADIUS, Color(color, 1.0 if hot else 0.9))
	if hot:
		draw_arc(pos, NODE_RADIUS + 1.0, 0.0, TAU, 24, Color.WHITE, 1.5, true)
	var font := _font if _font != null else ThemeDB.fallback_font
	var text := str(band + 1)
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10)
	draw_string(font, pos + Vector2(-text_size.x / 2.0, 3.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.05, 0.05, 0.08))


## The value tooltip next to a hovered or dragged node.
func _draw_readout(band: int, font: Font) -> void:
	var b: Dictionary = bands[band]
	var text := "%d  %s  %s Hz" % [band + 1, EqResponse.TYPE_NAMES[b["type"]], FreqAxis.format_hz(b["freq"])]
	if EqResponse.type_uses_gain(b["type"]):
		text += "  %+.1f dB" % b["gain"]
	text += "  Q %.2f" % b["q"]
	if EqResponse.type_is_cut(b["type"]):
		text += "  " + EqResponse.SLOPE_NAMES[b["slope"]]
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
	var pos := node_position(b)
	var box := Rect2(pos + Vector2(-text_size.x / 2.0 - 5.0, -NODE_RADIUS - text_size.y - 12.0), text_size + Vector2(10.0, 4.0))
	if box.position.y < 2.0:
		box.position.y = pos.y + NODE_RADIUS + 8.0
	box.position.x = clampf(box.position.x, 2.0, maxf(size.x - box.size.x - 2.0, 2.0))
	draw_rect(box, Color(0.08, 0.08, 0.1, 0.94))
	draw_rect(box, Color(1, 1, 1, 0.12), false, 1.0)
	draw_string(font, box.position + Vector2(5.0, text_size.y - 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.92, 0.92, 0.95))


func _draw_analyser() -> void:
	match state.analyser:
		EqViewState.Analyser.POST:
			_draw_bins(_pre_bins, PRE_LINE, Color(0, 0, 0, 0))
			_draw_bins(_post_bins, POST_LINE, POST_FILL)
		EqViewState.Analyser.PRE:
			_draw_bins(_pre_bins, POST_LINE, POST_FILL)


## A spectrum as a line (and optional fill) over the plot. Bins are mapped onto the log axis:
## columns between bins interpolate, columns covering several bins take their maximum.
func _draw_bins(bins: PackedFloat32Array, line_color: Color, fill_color: Color) -> void:
	if bins.size() < 4:
		return
	var plot := plot_rect()
	var bin_hz := _bin_rate / (2.0 * float(bins.size() - 1))
	var points := PackedVector2Array()
	var x := plot.position.x
	while x <= plot.end.x + 0.5:
		var lo_hz := freq_axis.x_to_hz(x - 1.0)
		var hi_hz := freq_axis.x_to_hz(x + 1.0)
		var i0 := int(floor(lo_hz / bin_hz))
		var i1 := int(ceil(hi_hz / bin_hz))
		var db: float
		if i1 - i0 <= 1:
			var position := freq_axis.x_to_hz(x) / bin_hz
			var a := clampi(int(floor(position)), 0, bins.size() - 1)
			var b := mini(a + 1, bins.size() - 1)
			db = lerpf(bins[a], bins[b], position - floorf(position))
		else:
			db = ANALYSER_FLOOR_DB
			for i in range(maxi(i0, 0), mini(i1, bins.size() - 1) + 1):
				db = maxf(db, bins[i])
		var t := clampf((db - ANALYSER_FLOOR_DB) / (ANALYSER_CEIL_DB - ANALYSER_FLOOR_DB), 0.0, 1.0)
		points.append(Vector2(x, plot.end.y - plot.size.y * t))
		x += 2.0
	if fill_color.a > 0.0 and points.size() > 2:
		var polygon := points.duplicate()
		polygon.append(Vector2(points[points.size() - 1].x, plot.end.y))
		polygon.append(Vector2(points[0].x, plot.end.y))
		draw_colored_polygon(polygon, fill_color)
	draw_polyline(points, line_color, 1.0, true)
