# Meter.gd
# Renders a mono or stereo meter with dB ticks and peak/RMS display
@tool
class_name Meter extends Control

# public inputs (peaks in linear 0..1+, RMS in linear)
@export var peak_left := 0.0:
	set(val):
		peak_left = val
@export var peak_right := 0.0:
	set(val):
		peak_right = val

# if enabled, draws a single bar (assumes peak_left/rms_left are the mono signal)
@export var mono := false

# styling
@export var bars_spacing := 2
@export var bar_bg_color := Color.DIM_GRAY
@export var bar_color_low := Color(0.21, 0.85, 0.62)     # greenish
@export var bar_color_high := Color(1.0, 0.75, 0.15)     # yellow/orange
@export var bar_color_clip := Color(1.0, 0.25, 0.25)     # red
@export var tick_color := Color(0.75, 0.75, 0.75, 0.5)
@export var tick_minor_color := Color(0.7, 0.7, 0.7, 0.25)
@export var zero_db_color := Color(1,1,1,0.75)
@export var tick_font_size := 12
@export var show_minor_ticks := false

# show an integrated fader control
@export var show_fader := false
@export var fader_color := Color("#624d99")
@export var fader_bg_color := Color.DIM_GRAY
@export var volume_db := -6.0
@export var fader_handle_color := Color.WHITE_SMOKE
@export var fader_handle_color_hover := Color.WHITE

# scale
@export var db_top := 6.0
@export var db_bottom := -60.0
@export var gamma_warp_min := 1.5
@export var gamma_warp_max := 3.0

var gamma_warp : float:
	get:
		var h_low = 100
		var h_high = 500
		var h_clamp = clamp(size.y, h_low, h_high)
		
		if gamma_warp_min and gamma_warp_max:
			return remap(h_clamp, h_low, h_high, gamma_warp_max, gamma_warp_min)
		else:
			return 1.0

signal volume_changed(volume : float)

var _is_dragging_fader := false
var mouse_hovered := false

var peak_combined: float:
	get: return (peak_left + peak_right) / 2.0

# for now treat RMS as same as peaks (feed your real RMS if you have it)
var rms_left: float:
	get: return peak_left

var rms_right: float:
	get: return peak_right

func set_peak_levels(left : float, right : float) -> void:
	peak_left = left
	peak_right = right
	rms_left = peak_left
	rms_right = peak_right


func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	
	peak_left = 0
	peak_right = 0
	rms_left = 0
	rms_right = 0


func _on_mouse_entered():
	mouse_hovered = true
	if show_fader:
		queue_redraw()

func _on_mouse_exited():
	mouse_hovered = false
	if show_fader:
		queue_redraw()


func _process(_delta: float) -> void:
	# you can add a "silence timeout" later to stop redrawing
	queue_redraw()

	# update cursor based on fader handle hover
	if show_fader:
		_update_cursor_for_fader()


func _gui_input(event: InputEvent) -> void:
	if not show_fader:
		return

	# only respond to mouse events on the fader
	if event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if _is_mouse_in_fader(mouse_event.position):
				if mouse_event.pressed:
					# start dragging
					_is_dragging_fader = true
					_handle_fader_drag(mouse_event.position)
					accept_event()
				else:
					# stop dragging
					_is_dragging_fader = false
					accept_event()

	elif event is InputEventMouseMotion:
		var mouse_event = event as InputEventMouseMotion
		if mouse_event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if _is_mouse_over_fader_handle(mouse_event.position) or _is_dragging_fader:
				# dragging the fader
				_handle_fader_drag(mouse_event.position)
				accept_event()
				queue_redraw()


func _is_mouse_in_fader(pos : Vector2) -> bool:
	var fader_width = bars_spacing
	var fader_offset = _get_fader_offset_x()
	return pos.x >= fader_offset and pos.x <= fader_offset + fader_width

func _get_fader_offset_x() -> float:
	if not show_fader:
		return false

	# calculate fader position (same as in _draw_fader)
	var fader_offset_x = 0.0

	# find fader x position (same calculation as _draw)
	var minimum_bars_width = 12 if mono else 25
	var show_ticks = size.x >= 28.0 + minimum_bars_width
	var ticks_width = 28.0 if show_ticks else 0.0
	var bars_width = max(0.0, size.x - ticks_width)
	var offset_x = ticks_width

	if mono:
		fader_offset_x = offset_x + bars_width + 2
	else:
		var bar_width = max(0.0, (bars_width - bars_spacing) * 0.5)
		fader_offset_x = offset_x + bar_width
	
	return fader_offset_x


func _is_mouse_over_fader_handle(mouse_pos: Vector2) -> bool:
	if not show_fader:
		return false

	# calculate fader position (same as in _draw_fader)
	var vol_normalized = _db_to_norm(volume_db)
	var fader_offset_x = 0.0

	# find fader x position (same calculation as _draw)
	var minimum_bars_width = 12 if mono else 25
	var show_ticks = size.x >= 28.0 + minimum_bars_width
	var ticks_width = 28.0 if show_ticks else 0.0
	var bars_width = max(0.0, size.x - ticks_width)
	var offset_x = ticks_width

	if mono:
		fader_offset_x = offset_x + bars_width + 2
	else:
		var bar_width = max(0.0, (bars_width - bars_spacing) * 0.5)
		fader_offset_x = offset_x + bar_width

	var width = bars_spacing
	var handle_radius = width
	var fader_top = (1.0 - vol_normalized) * size.y
	var handle_pos = Vector2(fader_offset_x + (width / 2), fader_top)

	# check if mouse is within handle radius
	return handle_pos.distance_to(mouse_pos) <= handle_radius * 1.5


func _handle_fader_drag(mouse_pos: Vector2) -> void:
	# convert mouse y position to volume dB (with gamma warp inverse)
	var y_normalized = clamp(1.0 - (mouse_pos.y / size.y), 0.0, 1.0)  # 0 at top, 1 at bottom

	# apply inverse gamma warp
	var n_unwarp = y_normalized
	if gamma_warp != 1.0:
		n_unwarp = pow(y_normalized, 1.0 / gamma_warp)

	# convert normalized back to dB
	var new_volume_db = n_unwarp * (db_top - db_bottom) + db_bottom

	if new_volume_db != volume_db:
		volume_db = clamp(new_volume_db, db_bottom, db_top)
		volume_changed.emit(volume_db)


func _update_cursor_for_fader() -> void:
	var mouse_pos = get_local_mouse_position()
	if _is_mouse_in_fader(mouse_pos):
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	else:
		mouse_default_cursor_shape = Control.CURSOR_ARROW


func _db_to_y(db: float) -> float:
	# Godot y grows downward
	var n := _db_to_norm(db)
	return (1.0 - n) * size.y


func _lin_to_db(a: float) -> float:
	return Utils.lin_to_db(a, db_bottom)


func _db_to_norm(db: float) -> float:
	# 0 at bottom, 1 at top (linear in dB)
	var n := (db - db_bottom) / (db_top - db_bottom)
	n = clamp(n, 0.0, 1.0)
	
	# optional perceptual warp to give more space near 0 dB
	if gamma_warp != 1.0:
		n = pow(n, gamma_warp)
	return n

var minimum_ticks_width = 28.0
var minimum_bars_width : int:
	get:
		return 12 if mono else 25

func _should_show_ticks() -> bool:
	# Show ticks if we have enough horizontal space
	return size.x >= minimum_ticks_width + minimum_bars_width

var ticks_width : float:
	get:
		return minimum_ticks_width if _should_show_ticks() else 0.0

var bars_width : float:
	get:
		return max(0.0, size.x - ticks_width)


func _draw() -> void:
	var show_ticks = _should_show_ticks()
	
	if show_ticks:
		_draw_tick_marks(ticks_width)
	
	var offset_x = ticks_width

	var fader_offset = 0
	
	if mono:
		_draw_bar(rms_left, peak_left, offset_x, bars_width)
		fader_offset = offset_x + bars_width + 2
	else:
		var bar_width = max(0.0, (bars_width - bars_spacing) * 0.5)
		fader_offset = offset_x + bar_width
		var offset_left = offset_x
		var offset_right = offset_x + bar_width + bars_spacing
		_draw_bar(rms_left,  peak_left,  offset_left,  bar_width)
		_draw_bar(rms_right, peak_right, offset_right, bar_width)
	
	if show_fader:
		_draw_fader(fader_offset, bars_spacing)
	

func _draw_fader(offset_x : float, width : float):
	# background
	draw_rect(Rect2(offset_x, 0, width, size.y), fader_bg_color, true)

	# fader bar (using gamma warp like the meter bars)
	var vol_normalized = _db_to_norm(volume_db)

	var fader_top = (1.0 - vol_normalized) * size.y
	var fader_height = vol_normalized * size.y

	draw_rect(Rect2(offset_x, fader_top, width, fader_height), fader_color, true, -1.0, true)

	# draw white circular handle
	var handle_radius = width
	var handle_c = fader_handle_color_hover if mouse_hovered else fader_handle_color
	draw_circle(Vector2(offset_x + (width / 2), fader_top), handle_radius, handle_c, true, -1.0, true)

	# draw volume value label when hovering or dragging
	if mouse_hovered or _is_dragging_fader:
		var font := get_theme_default_font()
		var fs := 16
		var value_text = "%0.1f" % volume_db
		var text_size = font.get_string_size(value_text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)

		# position above handle if handle is in lower half, otherwise below
		var label_y = fader_top - text_size.y - 6 if fader_top > size.y * 0.5 else fader_top + handle_radius + 16
		var label_x = offset_x + (width / 2) - (text_size.x / 2)

		draw_string(
			font,
			Vector2(label_x, label_y),
			value_text,
			HORIZONTAL_ALIGNMENT_CENTER,
			-1.0,
			fs,
			Color.WHITE
		)


func _get_ticks():
	if size.y >= 360:
		return [0, -6, -12, -18, -24, -30, -36, -42, -48, -54]
	if size.y >= 320:
		return [0, -6, -12, -18, -24, -30, -36, -42, -48]
	elif size.y >= 280:
		return [0, -6, -12, -18, -24, -30, -36, -42]
	elif size.y >= 200:
		return [0, -6, -12, -18, -24, -30, -40]
	elif size.y > 120:
		return [0, -6, -12, -18, -24, -36]
	else:
		return [0, -6, -12, -18, -32]


func _draw_tick_marks(ticks_width := 28.0) -> void:
	var font := get_theme_default_font()
	var fs := tick_font_size

	# exactly the ticks you asked for
	var ticks = _get_ticks()
	
	for db in ticks:
		# skip anything outside your current visible range
		if db > db_top or db < db_bottom:
			continue

		var y = floor(_db_to_y(db)) + 0.5  # crisp 1px

		# 0 dB a bit brighter/thicker
		var col := zero_db_color if db == 0 else tick_color
		var thick :=  2.0 if db == 0 else 1.0

		# label (side-by-side with tick)
		var label_text = str(abs(db))
		var label_x = 2.0
		draw_string(
			font,
			Vector2(label_x, y + 4),  # centered vertically on tick line
			label_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			fs,
			col
		)

		# short tick line after the label
		var label_width = font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var tick_start_x = label_x + label_width + 2
		var tick_end_x = ticks_width
		draw_line(Vector2(tick_start_x, y), Vector2(tick_end_x, y), col, thick)

# -------------------------
# bar drawing
# -------------------------
func _draw_bar(rms_lin: float, peak_lin: float, offset_x: float, width: float) -> void:
	# background
	draw_rect(Rect2(offset_x, 0, width, size.y), bar_bg_color, true)

	# nothing to show
	if rms_lin <= 0.0 and peak_lin <= 0.0:
		return

	# convert to dB with floor
	var rms_db := _lin_to_db(rms_lin)
	var peak_db := _lin_to_db(peak_lin)

	# choose color by dB
	var fill_color := bar_color_low
	if peak_db >= 0.0:
		fill_color = bar_color_clip
	elif rms_db > -3.0:
		fill_color = bar_color_high

	# fill from bottom up according to RMS
	var y_top := _db_to_y(rms_db)
	var h := size.y - y_top
	if h > 0.0:
		draw_rect(Rect2(offset_x, y_top, width, h), fill_color, true)

	# draw a thin peak line
	var y_peak = _db_to_y(peak_db)
	var y_line = floor(y_peak) + 0.5
	draw_line(Vector2(offset_x, y_line), Vector2(offset_x + width, y_line), Color(1,1,1,0.8), 1.0)

	# optional: clip LED on the very top few pixels (visual candy)
	if peak_db >= 0.0:
		draw_rect(Rect2(offset_x, 0, width, 3), bar_color_clip, true)
