## The EQ's curve editor: log-frequency and dB grids, the analyser behind the curve, the combined
## curve and each band's own, draggable band nodes, and a piano strip along the bottom edge.
##
## Gestures on a node: drag = frequency and gain (Shift = fine), wheel = Q (Shift = fine),
## double-click = disable the band, right-click = Type / Slope / Stereo menu, Alt or middle button
## held = listen to the band. Double-click on empty space enables the first free band there.
##
## Modulation (a sidechain modulator making a dynamic EQ, say) is pushed in by the view through
## `set_live`: a modulated band is drawn with a translucent fill between its set curve and its live
## curve, and a ghost node where the modulation has moved it. The total curve then follows the
## live response, with the set total as a faint line behind it.
##
## The editor never talks to the engine: every edit goes through `device.set_parameter_real`
## (the DeviceInstance setter), and the curve redraws from `parameter_changed`. It references no
## autoloads, so tests can drive it headless.
class_name EqCurveEditor extends Control

## The view state (analyser mode, dB range, resolution, speed, tilt) changed; the owner persists
## it (and sends the analyser options to the engine).
signal view_state_changed
signal band_hovered(band: int)
## The band shown in the view's knob row changed (-1: none).
signal selection_changed(band: int)

const PIANO_HEIGHT := 18.0
const NODE_RADIUS := 7.0
const HIT_RADIUS := 11.0
const WHEEL_Q_STEP := 1.12
const WHEEL_Q_FINE_STEP := 1.03
## The analyser's own scale (dBFS), drawn behind the EQ curve over the whole plot height.
const ANALYSER_FLOOR_DB := -90.0
const ANALYSER_CEIL_DB := 0.0
## Analyser frames start with [flag, sample_rate, lo_hz, hi_hz] (eq.rs `SPECTRUM_HEADER_LEN`).
const SPECTRUM_HEADER_LEN := 4
## The drawn analyser moves linearly from where it is to each new frame over one frame interval,
## measured from the frames' arrival (smoothed, clamped to this range in seconds).
const ANALYSER_INTERVAL_MIN := 1.0 / 120.0
const ANALYSER_INTERVAL_MAX := 0.1
## The display tilt pivots here: this frequency reads the same at every tilt.
const TILT_PIVOT_HZ := 1000.0
## The analyser is drawn as a monotone cubic: up to SMOOTH_MAX_SUB sub-segments per engine
## segment, fewer when many points would pass SMOOTH_MAX_VERTICES in total.
const SMOOTH_MAX_SUB := 6
const SMOOTH_MAX_VERTICES := 1536

## Plot background: the theme's well colour, refreshed on theme change.
var _bg_color := UiColors.role(&"well")
const GRID_COLOR := Color(1, 1, 1, 0.06)
const GRID_MAJOR_COLOR := Color(1, 1, 1, 0.12)
const ZERO_COLOR := Color(1, 1, 1, 0.3)
const LABEL_COLOR := Color(1, 1, 1, 0.45)
const TOTAL_COLOR := Color(0.96, 0.96, 0.96, 0.95)
var _post_line := UiColors.role(&"accent_primary").lightened(0.2)
var _post_fill := Color(_post_line, 0.3)
const PRE_LINE := Color(1, 1, 1, 0.22)
## The set total while modulation moves the live one.
const SET_TOTAL_COLOR := Color(0.96, 0.96, 0.96, 0.3)
const LIVE_FILL_ALPHA := 0.3
const LIVE_LINE_ALPHA := 0.8
## A ghost node shows only once the live position is this far (px) from the set one.
const LIVE_NODE_MIN_DISTANCE := 2.0

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
## The band whose knobs the view shows: the last one clicked or enabled.
var selected_band := -1
## The piano strip along the bottom edge. The device lane is too short for it to be readable.
var show_piano := true:
	set(value):
		show_piano = value
		_curves_dirty = true
		queue_redraw()

## Draws a vertical line at the mouse with its frequency and note at the bottom (the window
## view turns it on).
var show_cursor_readout := false:
	set(value):
		show_cursor_readout = value
		queue_redraw()

var _fine := FineDrag.new()
## The mouse x inside the editor, -1 while it is outside.
var _cursor_x := -1.0
var _curve_freqs := PackedFloat32Array()
var _curves: Array[PackedFloat32Array] = []
var _total := PackedFloat32Array()
var _curves_dirty := true
## Live values per band from the modulation stream (`set_live`): the fields a modulator moves
## right now ({freq, gain, q}, real units), {} for a band nothing modulates.
var live_bands: Array = []
## Live Output gain (dB), NAN while it isn't modulated.
var live_output_gain_db := NAN
## Per-band live curves (the set curve for an unmodulated band) and their total; the total is
## empty while nothing is modulated.
var _live_curves: Array[PackedFloat32Array] = []
var _live_total := PackedFloat32Array()
var _live_dirty := false
## Analyser points (dBFS), log-spaced from `_points_lo_hz` to `_points_hi_hz`.
var _pre_points := PackedFloat32Array()
var _post_points := PackedFloat32Array()
var _pre_target := PackedFloat32Array()
var _post_target := PackedFloat32Array()
## Where the current interpolation started, and how far along it is (0..1).
var _pre_from := PackedFloat32Array()
var _post_from := PackedFloat32Array()
var _pre_t := 1.0
var _post_t := 1.0
## Smoothed time between analyser frames (s), and when the last post frame arrived (µs).
var _frame_interval := 1.0 / 30.0
var _last_frame_usec := 0
var _points_lo_hz := 20.0
## Scratch buffers of `_draw_points`, reused every frame.
var _raw_points := PackedVector2Array()
var _smooth_points := PackedVector2Array()
var _fill_polygon := PackedVector2Array()
var _tangents := PackedFloat32Array()
var _points_hi_hz := 20000.0
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
	live_bands = []
	for i in EqResponse.BAND_COUNT:
		bands.append(EqResponse.default_band(i))
		live_bands.append({})


# ============================================================================
# DEVICE
# ============================================================================

func set_device(value: RefCounted) -> void:
	if device != null and device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.disconnect(_on_parameter_changed)
	device = value
	if device != null:
		device.parameter_changed.connect(_on_parameter_changed)
	clear_live()
	refresh_all()


func refresh_all() -> void:
	for i in EqResponse.BAND_COUNT:
		_read_band(i)
	output_gain_db = _real(EqResponse.OUTPUT_GAIN, 0.0)
	var listen := int(_real(EqResponse.LISTEN_BAND, 0.0))
	listen_band = listen - 1
	_keep_selection_valid()
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


## The selection follows the device: a band disabled elsewhere (undo, automation, the window view)
## gives it up, and the first enabled band is picked when nothing is selected.
func _keep_selection_valid() -> void:
	if selected_band >= 0 and not bands[selected_band]["enabled"]:
		select_band(_first_enabled_band())
	elif selected_band < 0:
		select_band(_first_enabled_band())


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
	_keep_selection_valid()
	_curves_dirty = true
	queue_redraw()


## Write one parameter of band `band` in real units (Hz, dB, enum index) through the device.
func set_band_param(band: int, offset: int, real_value: float) -> void:
	if device != null:
		ParameterActions.set_real(device, band * EqResponse.BAND_STRIDE + offset, real_value)


# ============================================================================
# ANALYSER
# ============================================================================

## A `"spectrum"` frame from the engine: [flag, sample_rate, lo_hz, hi_hz, points...] (flag 0 =
## pre, 1 = post), the points log-spaced from lo_hz to hi_hz.
func on_spectrum_frame(frame: PackedFloat32Array) -> void:
	if frame.size() < SPECTRUM_HEADER_LEN + 2 or frame[2] <= 0.0 or frame[3] <= frame[2]:
		return
	var points := frame.slice(SPECTRUM_HEADER_LEN)
	_points_lo_hz = frame[2]
	_points_hi_hz = frame[3]
	var post := frame[0] >= 0.5
	if post:
		_measure_frame_interval()
		_post_target = points
		_post_t = _start_lerp(_post_points, _post_from, points)
	else:
		_pre_target = points
		_pre_t = _start_lerp(_pre_points, _pre_from, points)
	set_process(is_visible_in_tree() and state.analyser != EqViewState.Analyser.OFF)
	if frame[1] > 0.0 and not is_equal_approx(frame[1], sample_rate):
		sample_rate = frame[1]
	queue_redraw()


func _process(delta: float) -> void:
	var step := delta / _frame_interval
	_pre_t = _lerp_points(_pre_points, _pre_from, _pre_target, _pre_t, step)
	_post_t = _lerp_points(_post_points, _post_from, _post_target, _post_t, step)
	queue_redraw()
	if _is_analyser_settled():
		set_process(false)


## True when both displayed spectra have reached their targets.
func _is_analyser_settled() -> bool:
	return _pre_t >= 1.0 and _post_t >= 1.0


## Smooth the time between post frames (pre and post arrive together) into `_frame_interval`.
func _measure_frame_interval() -> void:
	var now := Time.get_ticks_usec()
	if _last_frame_usec > 0:
		var dt := clampf((now - _last_frame_usec) / 1000000.0, ANALYSER_INTERVAL_MIN, ANALYSER_INTERVAL_MAX)
		_frame_interval = lerpf(_frame_interval, dt, 0.2)
	_last_frame_usec = now


## Start interpolating `shown` from where it is now to `target`, copying it into `from` in place.
## The first frame and a resolution change snap. Returns the new progress (0, or 1 when snapped).
func _start_lerp(shown: PackedFloat32Array, from: PackedFloat32Array, target: PackedFloat32Array) -> float:
	if shown.size() != target.size():
		shown.resize(target.size())
		for i in target.size():
			shown[i] = target[i]
		return 1.0
	from.resize(shown.size())
	for i in shown.size():
		from[i] = shown[i]
	return 0.0


## Advance progress `t` by `step` and set `shown` in place to the linear blend of `from` and
## `target`. Returns the new progress.
func _lerp_points(shown: PackedFloat32Array, from: PackedFloat32Array, target: PackedFloat32Array, t: float, step: float) -> float:
	if t >= 1.0:
		return t
	t = minf(t + step, 1.0)
	var n := mini(shown.size(), mini(from.size(), target.size()))
	for i in n:
		shown[i] = lerpf(from[i], target[i], t)
	return t


# ============================================================================
# MODULATION
# ============================================================================

## Show the live (modulated) values: one Dictionary per band holding the fields a modulator moves
## ({freq, gain, q}, real units; {} when none), and the live Output gain (NAN when unmodulated).
## Redraws only when something changed.
func set_live(values: Array, output_gain_db := NAN) -> void:
	var same_output := is_nan(output_gain_db) == is_nan(live_output_gain_db) \
			and (is_nan(output_gain_db) or output_gain_db == live_output_gain_db)
	if same_output and values == live_bands:
		return
	live_bands = []
	for i in EqResponse.BAND_COUNT:
		live_bands.append((values[i] as Dictionary).duplicate() if i < values.size() else {})
	live_output_gain_db = output_gain_db
	_live_dirty = true
	queue_redraw()


func clear_live() -> void:
	var none: Array = []
	none.resize(EqResponse.BAND_COUNT)
	none.fill({})
	set_live(none)


## True while a modulator moves any band or the Output gain.
func has_live() -> bool:
	if not is_nan(live_output_gain_db):
		return true
	for live: Dictionary in live_bands:
		if not live.is_empty():
			return true
	return false


## Band `band` with its live values in place of the set ones.
func live_band(band: int) -> Dictionary:
	var merged: Dictionary = bands[band].duplicate()
	if band < live_bands.size():
		merged.merge(live_bands[band], true)
	return merged


func clear_analyser() -> void:
	_pre_points = PackedFloat32Array()
	_post_points = PackedFloat32Array()
	_pre_target = PackedFloat32Array()
	_post_target = PackedFloat32Array()
	_pre_t = 1.0
	_post_t = 1.0
	_last_frame_usec = 0
	set_process(false)
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


func set_resolution(resolution: int) -> void:
	if state.resolution == resolution:
		return
	state.resolution = resolution
	view_state_changed.emit()


func set_speed(speed: int) -> void:
	if state.speed == speed:
		return
	state.speed = speed
	view_state_changed.emit()


## Show or hide the piano strip (the window view's toggle); persisted in the view state.
func set_piano_visible(visible_strip: bool) -> void:
	if state.piano == visible_strip:
		return
	state.piano = visible_strip
	show_piano = visible_strip
	view_state_changed.emit()


func set_tilt_db(tilt_db: float) -> void:
	if is_equal_approx(state.tilt_db, tilt_db):
		return
	state.tilt_db = tilt_db
	view_state_changed.emit()
	queue_redraw()


# ============================================================================
# GEOMETRY
# ============================================================================

func plot_rect() -> Rect2:
	return Rect2(0, 0, size.x, maxf(size.y - _piano_height(), 1.0))


func piano_rect() -> Rect2:
	return Rect2(0, maxf(size.y - _piano_height(), 0.0), size.x, _piano_height())


func _piano_height() -> float:
	return PIANO_HEIGHT if show_piano else 0.0


## Show band `band`'s knobs (-1: none).
func select_band(band: int) -> void:
	if band == selected_band:
		return
	selected_band = band
	selection_changed.emit(band)
	queue_redraw()


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


func _first_enabled_band() -> int:
	for i in bands.size():
		if bands[i]["enabled"]:
			return i
	return -1


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
	select_band(band)
	return band


func disable_band(band: int) -> void:
	if listen_band == band:
		end_listen()
	set_band_param(band, EqResponse.P_ENABLED, 0.0)
	if selected_band == band:
		select_band(_first_enabled_band())


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
					select_band(band)
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
	if show_cursor_readout:
		_cursor_x = motion.position.x
		queue_redraw()
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
	if what == NOTIFICATION_THEME_CHANGED:
		_bg_color = UiColors.role(&"well")
		_post_line = UiColors.role(&"accent_primary").lightened(0.2)
		_post_fill = Color(_post_line, 0.3)
		queue_redraw()
	match what:
		NOTIFICATION_RESIZED:
			_curves_dirty = true
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			if _cursor_x >= 0.0:
				_cursor_x = -1.0
				queue_redraw()
			if drag_band < 0 and hover_band >= 0:
				hover_band = -1
				band_hovered.emit(-1)
				queue_redraw()
		NOTIFICATION_VISIBILITY_CHANGED:
			if not is_visible_in_tree():
				end_interaction()
				set_process(false)
			elif not _is_analyser_settled():
				set_process(true)


# ============================================================================
# CONTEXT MENU
# ============================================================================

func _build_menus() -> void:
	if _menu != null:
		return
	_menu = PopupMenu.new()
	_menu.theme_type_variation = &"ContextMenuList"
	_type_menu = PopupMenu.new()
	_type_menu.theme_type_variation = &"ContextMenuList"
	_slope_menu = PopupMenu.new()
	_slope_menu.theme_type_variation = &"ContextMenuList"
	_stereo_menu = PopupMenu.new()
	_stereo_menu.theme_type_variation = &"ContextMenuList"
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
	ContextMenuPopup.popup_at_point(_menu, global_pos)


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
	_update_live_curves()


## Recompute only the modulated bands' curves (the live values arrive about 20 times a second).
func _update_live_curves() -> void:
	_live_dirty = false
	_live_curves = []
	_live_total = PackedFloat32Array()
	if not has_live():
		return
	for i in bands.size():
		if i < live_bands.size() and not live_bands[i].is_empty() and bands[i]["enabled"]:
			_live_curves.append(EqResponse.band_curves([live_band(i)], _curve_freqs, sample_rate)[0])
		else:
			_live_curves.append(_curves[i] if i < _curves.size() else PackedFloat32Array())
	var out_db := output_gain_db if is_nan(live_output_gain_db) else live_output_gain_db
	_live_total = EqResponse.total_curve(_live_curves, _curve_freqs.size(), out_db)


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
	elif _live_dirty:
		_update_live_curves()
	var plot := plot_rect()
	draw_rect(plot, _bg_color)
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
		if _is_live(i):
			_draw_live_band(points, _curve_points(_live_curves[i]), color)
		draw_polyline(points, Color(color, 0.85 if i == hot else 0.55), 1.5, true)
	if _live_total.size() > 1:
		if _total.size() > 1:
			draw_polyline(_curve_points(_total), SET_TOTAL_COLOR, 1.5, true)
		draw_polyline(_curve_points(_live_total), TOTAL_COLOR, 2.0, true)
	elif _total.size() > 1:
		draw_polyline(_curve_points(_total), TOTAL_COLOR, 2.0, true)
	for i in bands.size():
		if bands[i]["enabled"] and _is_live(i):
			_draw_live_node(i)
	for i in bands.size():
		if bands[i]["enabled"]:
			_draw_node(i, i == hot)
	if hot >= 0 and bands[hot]["enabled"]:
		_draw_readout(hot, font)
	if show_cursor_readout and _cursor_x >= 0.0:
		_draw_cursor_readout(font)
	if show_piano:
		freq_axis.draw_piano_strip(self, piano_rect(), font, 9)


## The text under the cursor line: "440 Hz  A3 +0¢".
func cursor_readout_text() -> String:
	var hz := freq_axis.x_to_hz(_cursor_x)
	return "%s  %s" % [FreqAxis.format_hz_long(hz), FreqAxis.format_note_cents(hz)]


## A vertical line at the mouse, and its frequency and note in a box on the line's foot, above
## the grid labels.
func _draw_cursor_readout(font: Font) -> void:
	var plot := plot_rect()
	var x := clampf(_cursor_x, plot.position.x, plot.end.x)
	draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), Color(1, 1, 1, 0.35), 1.0)
	var text := cursor_readout_text()
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
	var box := Rect2(x - text_size.x / 2.0 - 4.0, plot.end.y - text_size.y - 20.0, text_size.x + 8.0, text_size.y + 4.0)
	box.position.x = clampf(box.position.x, 2.0, maxf(size.x - box.size.x - 2.0, 2.0))
	draw_rect(box, Color(0.08, 0.08, 0.1, 0.9))
	draw_string(font, box.position + Vector2(4.0, text_size.y - 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.92, 0.92, 0.95))


## Faint vertical fill between a band's curve and the 0 dB line.
func _draw_band_fill(points: PackedVector2Array, color: Color) -> void:
	var zero_y := db_grid.db_to_y(0.0)
	var lines := PackedVector2Array()
	for i in range(0, points.size(), 1):
		lines.append(Vector2(points[i].x, zero_y))
		lines.append(points[i])
	draw_multiline(lines, Color(color, 0.14), 2.0)


## True when band `band` has a live curve of its own to draw.
func _is_live(band: int) -> bool:
	return band < live_bands.size() and not live_bands[band].is_empty() \
			and band < _live_curves.size() and not _live_curves[band].is_empty()


## The modulation of one band: a translucent fill between its set and live curves, and the live
## curve itself.
func _draw_live_band(set_points: PackedVector2Array, live_points: PackedVector2Array, color: Color) -> void:
	var lines := PackedVector2Array()
	for i in mini(set_points.size(), live_points.size()):
		lines.append(set_points[i])
		lines.append(live_points[i])
	draw_multiline(lines, Color(color, LIVE_FILL_ALPHA), 2.0)
	draw_polyline(live_points, Color(color, LIVE_LINE_ALPHA), 1.0, true)


## A ghost node where the modulation has moved band `band`, tied to its set node.
func _draw_live_node(band: int) -> void:
	var set_pos := node_position(bands[band])
	var live_pos := node_position(live_band(band))
	if set_pos.distance_to(live_pos) < LIVE_NODE_MIN_DISTANCE:
		return
	var color := band_color(band)
	draw_line(set_pos, live_pos, Color(color, 0.45), 1.0, true)
	draw_circle(live_pos, NODE_RADIUS - 1.5, Color(color, 0.35))
	draw_arc(live_pos, NODE_RADIUS - 1.5, 0.0, TAU, 20, Color(color, 0.9), 1.0, true)


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
	elif band == selected_band:
		draw_arc(pos, NODE_RADIUS + 3.0, 0.0, TAU, 24, Color(1, 1, 1, 0.55), 1.0, true)
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
			_draw_points(_pre_points, PRE_LINE, Color(0, 0, 0, 0))
			_draw_points(_post_points, _post_line, _post_fill)
		EqViewState.Analyser.PRE:
			_draw_points(_pre_points, _post_line, _post_fill)


## A spectrum as a line (and optional fill) over the plot. The engine already smoothed it into
## log-spaced points, so this places them, adding the display tilt (dB per octave around
## TILT_PIVOT_HZ), and draws a monotone cubic through them (`smooth_monotone`, display only).
func _draw_points(values: PackedFloat32Array, line_color: Color, fill_color: Color) -> void:
	var count := values.size()
	if count < 2:
		return
	var plot := plot_rect()
	var octaves := log(_points_hi_hz / _points_lo_hz) / log(2.0)
	var pivot_octaves := log(TILT_PIVOT_HZ / _points_lo_hz) / log(2.0)
	_raw_points.resize(count)
	for i in count:
		var t := float(i) / float(count - 1)
		var hz := _points_lo_hz * pow(2.0, octaves * t)
		var db := values[i] + state.tilt_db * (octaves * t - pivot_octaves)
		var y := clampf((db - ANALYSER_FLOOR_DB) / (ANALYSER_CEIL_DB - ANALYSER_FLOOR_DB), 0.0, 1.0)
		_raw_points[i] = Vector2(freq_axis.hz_to_x(hz), plot.end.y - plot.size.y * y)
	var sub := clampi(SMOOTH_MAX_VERTICES / (count - 1), 1, SMOOTH_MAX_SUB)
	smooth_monotone(_raw_points, sub, _smooth_points, _tangents)
	var total := _smooth_points.size()
	if fill_color.a > 0.0:
		_fill_polygon.resize(total + 2)
		for i in total:
			_fill_polygon[i] = _smooth_points[i]
		_fill_polygon[total] = Vector2(_smooth_points[total - 1].x, plot.end.y)
		_fill_polygon[total + 1] = Vector2(_smooth_points[0].x, plot.end.y)
		draw_colored_polygon(_fill_polygon, fill_color)
	draw_polyline(_smooth_points, line_color, 1.0, true)


## Monotone cubic (Fritsch-Carlson / PCHIP) through `src` (x strictly increasing), with `sub`
## segments between neighbouring points, written into `out` (resized, so reused buffers don't
## allocate once grown). The source points are kept exactly, and between two of them the curve
## stays within their y range, so a peak never overshoots and the line never dips below the
## floor. `tangents` is scratch.
static func smooth_monotone(src: PackedVector2Array, sub: int, out: PackedVector2Array, tangents: PackedFloat32Array) -> void:
	var n := src.size()
	if n < 2 or sub < 2:
		out.resize(n)
		for i in n:
			out[i] = src[i]
		return
	tangents.resize(n)
	for k in range(1, n - 1):
		var h0 := src[k].x - src[k - 1].x
		var h1 := src[k + 1].x - src[k].x
		if h0 <= 0.0 or h1 <= 0.0:
			tangents[k] = 0.0
			continue
		var d0 := (src[k].y - src[k - 1].y) / h0
		var d1 := (src[k + 1].y - src[k].y) / h1
		if d0 * d1 <= 0.0:
			tangents[k] = 0.0
		else:
			var w0 := 2.0 * h1 + h0
			var w1 := h1 + 2.0 * h0
			tangents[k] = (w0 + w1) / (w0 / d0 + w1 / d1)
	tangents[0] = _secant(src, 0)
	tangents[n - 1] = _secant(src, n - 2)
	out.resize((n - 1) * sub + 1)
	for k in n - 1:
		var p0 := src[k]
		var p1 := src[k + 1]
		var h := p1.x - p0.x
		out[k * sub] = p0
		for j in range(1, sub):
			var t := float(j) / float(sub)
			var t2 := t * t
			var t3 := t2 * t
			var y := (2.0 * t3 - 3.0 * t2 + 1.0) * p0.y + (t3 - 2.0 * t2 + t) * h * tangents[k] \
				+ (-2.0 * t3 + 3.0 * t2) * p1.y + (t3 - t2) * h * tangents[k + 1]
			out[k * sub + j] = Vector2(p0.x + h * t, clampf(y, minf(p0.y, p1.y), maxf(p0.y, p1.y)))
	out[(n - 1) * sub] = src[n - 1]


static func _secant(src: PackedVector2Array, k: int) -> float:
	var h := src[k + 1].x - src[k].x
	return (src[k + 1].y - src[k].y) / h if h > 0.0 else 0.0
