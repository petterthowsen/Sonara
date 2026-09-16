# Meter.gd
# Renders a mono or stereo meter with dB ticks and peak/RMS display
@tool
class_name Meter extends Control

# Target values (set from audio engine)
var _target_peak_left := 0.0
var _target_peak_right := 0.0
var _target_rms_left := 0.0
var _target_rms_right := 0.0

# Smoothed display values (lerped for visual smoothness)
@export var peak_left := 0.0: ## Smoothed left-channel peak level (linear, 0..1+)
	set(v):
		peak_left = v
		_wake()
@export var peak_right := 0.0: ## Smoothed right-channel peak level (linear, 0..1+)
	set(v):
		peak_right = v
		_wake()
@export var rms_left := 0.0: ## Smoothed left-channel RMS level (linear, 0..1+)
	set(v):
		rms_left = v
		_wake()
@export var rms_right := 0.0: ## Smoothed right-channel RMS level (linear, 0..1+)
	set(v):
		rms_right = v
		_wake()

# Ballistics (time-based, so frame-rate independent)
@export var peak_release_db_per_sec := 30.0 ## Peak value falls at this rate (dB/s) after a transient
@export var peak_hold_time := 1.5 ## Seconds the peak hold line sticks at its max
@export var peak_hold_release_db_per_sec := 15.0 ## Hold line fall rate (dB/s) once the hold time is over
@export var rms_attack_time := 0.05 ## RMS smoothing time constant when the level is rising (seconds)
@export var rms_release_time := 0.3 ## RMS smoothing time constant when the level is falling (seconds)

# Peak hold line state (dB), per side
var peak_hold_left_db := -INF
var peak_hold_right_db := -INF
var _hold_timer_left := 0.0
var _hold_timer_right := 0.0

# if enabled, draws a single bar (assumes peak_left/rms_left are the mono signal)
@export var mono := false: ## Draw a single bar using peak_left/rms_left instead of stereo left/right bars
	set(v):
		mono = v
		_wake()

# styling
@export var bars_spacing := 2: ## Pixel gap between the left and right bars (and between bars and fader)
	set(v):
		bars_spacing = v
		_wake()
@export var bar_bg_color := Color.DIM_GRAY: ## Background fill of each meter bar
	set(v):
		bar_bg_color = v
		_wake()
@export var bar_color_low := Color(0.21, 0.85, 0.62): ## Bar color when the level is in the normal range
	set(v):
		bar_color_low = v
		_wake()
@export var bar_color_high := Color(1.0, 0.75, 0.15): ## Bar color for the part of the bar between warn_db and 0 dB
	set(v):
		bar_color_high = v
		_wake()
@export var bar_color_clip := Color(1.0, 0.25, 0.25): ## Bar/peak-hold/LED color when the level clips (>= 0 dB)
	set(v):
		bar_color_clip = v
		_wake()
@export var warn_db := -6.0: ## Level where the bar color switches from low to high
	set(v):
		warn_db = v
		_wake()
@export_range(0.0, 1.0) var peak_bar_alpha := 0.45: ## Opacity of the peak bar drawn behind the solid RMS bar
	set(v):
		peak_bar_alpha = v
		_wake()
@export var tick_color := Color(0.75, 0.75, 0.75, 0.5): ## Color of the dB tick lines and labels
	set(v):
		tick_color = v
		_wake()
@export var tick_minor_color := Color(0.7, 0.7, 0.7, 0.25): ## Color of minor tick lines (unused unless show_minor_ticks is on)
	set(v):
		tick_minor_color = v
		_wake()
@export var zero_db_color := Color(1,1,1,0.75): ## Color of the 0 dB tick line and label
	set(v):
		zero_db_color = v
		_wake()
@export var tick_font_size := 12: ## Font size for tick labels
	set(v):
		tick_font_size = v
		_wake()
@export var show_minor_ticks := false: ## Whether to draw minor tick lines between the main labeled ticks
	set(v):
		show_minor_ticks = v
		_wake()

## Horizontal size (px) below which the tick/label column on the left is hidden to save space
@export var min_width_for_ticks := 28.0:
	set(v):
		min_width_for_ticks = v
		_wake()

# show an integrated fader control
@export var show_fader := false: ## Whether to draw an interactive volume fader alongside the meter bars
	set(v):
		show_fader = v
		_wake()
@export var fader_color := Color("#624d99"): ## Fill color of the fader's filled (below-handle) portion
	set(v):
		fader_color = v
		_wake()
@export var fader_bg_color := Color.DIM_GRAY: ## Background fill behind the fader
	set(v):
		fader_bg_color = v
		_wake()
@export var volume_db := -6.0: ## Current fader value in dB; drives volume_changed when edited by the user
	set(v):
		volume_db = v
		queue_redraw()
@export var fader_handle_color := Color.WHITE_SMOKE: ## Fader handle color when not hovered
	set(v):
		fader_handle_color = v
		_wake()
@export var fader_handle_color_hover := Color.WHITE: ## Fader handle color while hovered
	set(v):
		fader_handle_color_hover = v
		_wake()

# scale
@export var db_top := 6.0: ## dB value at the top of the meter/fader range
	set(v):
		db_top = v
		_wake()
@export var db_bottom := -60.0: ## dB value at the bottom of the meter/fader range (also the "silent" floor)
	set(v):
		db_bottom = v
		_wake()
@export var gamma_warp_min := 1.5: ## Gamma warp applied at the tallest reference height (h_high), giving less perceptual expansion
	set(v):
		gamma_warp_min = v
		_wake()
@export var gamma_warp_max := 3.0: ## Gamma warp applied at the shortest reference height (h_low), giving more perceptual expansion near 0 dB
	set(v):
		gamma_warp_max = v
		_wake()

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
## Emitted when the highest peak since the last reset changes (-INF after a reset).
signal max_peak_changed(db: float)
## Emitted when the user clicks the meter bars to clear the clip lights and max peak.
signal peak_memory_reset_requested

## Highest peak (dB) since the last reset_peak_memory().
var max_peak_db := -INF
# Clip lights stay on until reset_peak_memory()
var _clip_left := false
var _clip_right := false

var _is_dragging_fader := false
var _last_fader_mouse_pos := Vector2.ZERO
@export var fader_fine_drag_scale := 0.15 ## Multiplier applied to mouse movement during shift-held fine fader drags
var mouse_hovered := false

var peak_combined: float:
	get: return (peak_left + peak_right) / 2.0


func set_peak_levels(left : float, right : float) -> void:
	_target_peak_left = left
	_target_peak_right = right
	if left >= 1.0 and not _clip_left:
		_clip_left = true
		queue_redraw()
	if right >= 1.0 and not _clip_right:
		_clip_right = true
		queue_redraw()
	var db := Utils.lin_to_db(maxf(left, right), -INF)
	if db > max_peak_db:
		max_peak_db = db
		max_peak_changed.emit(db)
	_wake()


## Clear the clip lights and the max peak.
func reset_peak_memory() -> void:
	_clip_left = false
	_clip_right = false
	max_peak_db = -INF
	max_peak_changed.emit(max_peak_db)
	queue_redraw()


func set_rms_levels(left : float, right : float) -> void:
	_target_rms_left = left
	_target_rms_right = right
	_wake()


func _wake() -> void:
	if not is_processing() and is_visible_in_tree():
		set_process(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		set_process(is_visible_in_tree())


func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	
	peak_left = 0.0
	peak_right = 0.0
	rms_left = 0.0
	rms_right = 0.0
	_target_peak_left = 0.0
	_target_peak_right = 0.0
	_target_rms_left = 0.0
	_target_rms_right = 0.0


func _on_mouse_entered():
	mouse_hovered = true
	if show_fader:
		queue_redraw()

func _on_mouse_exited():
	mouse_hovered = false
	if show_fader:
		queue_redraw()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		# no ballistics/animation in the editor, just redraw once to reflect export changes
		set_process(false)
		queue_redraw()
		return
	if not is_visible_in_tree():
		set_process(false)
		return

	# Peaks: instant attack, constant dB/s release
	peak_left = _release_peak(peak_left, _target_peak_left, delta)
	peak_right = _release_peak(peak_right, _target_peak_right, delta)

	# Peak hold lines: stick for peak_hold_time, then fall
	var hold_l := _update_hold(peak_hold_left_db, _hold_timer_left, _lin_to_db(peak_left), delta)
	peak_hold_left_db = hold_l.x
	_hold_timer_left = hold_l.y
	var hold_r := _update_hold(peak_hold_right_db, _hold_timer_right, _lin_to_db(peak_right), delta)
	peak_hold_right_db = hold_r.x
	_hold_timer_right = hold_r.y

	# RMS: exponential smoothing with separate attack/release
	rms_left = _smooth_rms(rms_left, _target_rms_left, delta)
	rms_right = _smooth_rms(rms_right, _target_rms_right, delta)

	queue_redraw()

	# Stop redrawing once everything has settled; new levels wake us up again
	if _is_settled():
		set_process(false)


func _release_peak(current: float, target: float, delta: float) -> float:
	if target >= current:
		return target
	var db := _lin_to_db(current) - peak_release_db_per_sec * delta
	if db <= db_bottom:
		return target
	return max(target, db_to_linear(db))


## Returns Vector2(hold_db, hold_timer).
func _update_hold(hold_db: float, timer: float, peak_db: float, delta: float) -> Vector2:
	if peak_db >= hold_db:
		return Vector2(peak_db, peak_hold_time)
	if timer > 0.0:
		return Vector2(hold_db, timer - delta)
	return Vector2(max(peak_db, hold_db - peak_hold_release_db_per_sec * delta), 0.0)


func _smooth_rms(current: float, target: float, delta: float) -> float:
	var tau := rms_attack_time if target > current else rms_release_time
	var value: float = lerp(current, target, 1.0 - exp(-delta / max(tau, 0.001)))
	# snap once visually indistinguishable so the meter can settle
	if absf(value - target) < 0.0001:
		return target
	return value


func _is_settled() -> bool:
	return peak_left == _target_peak_left and peak_right == _target_peak_right \
		and rms_left == _target_rms_left and rms_right == _target_rms_right \
		and _hold_timer_left <= 0.0 and _hold_timer_right <= 0.0 \
		and peak_hold_left_db <= _lin_to_db(peak_left) \
		and peak_hold_right_db <= _lin_to_db(peak_right)


func _gui_input(event: InputEvent) -> void:
	# clicking the bars (not the fader) clears the clip lights and max peak
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and not (show_fader and _is_mouse_in_fader(event.position)):
		peak_memory_reset_requested.emit()
		reset_peak_memory()
		accept_event()
		return

	if not show_fader:
		return

	# only respond to mouse events on the fader
	if event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if _is_mouse_in_fader(mouse_event.position):
				if mouse_event.pressed:
					if mouse_event.double_click:
						_start_value_edit()
					else:
						# start dragging
						_is_dragging_fader = true
						_last_fader_mouse_pos = mouse_event.position
						_handle_fader_drag(mouse_event.position)
					accept_event()
				else:
					# stop dragging
					_is_dragging_fader = false
					accept_event()

	elif event is InputEventMouseMotion:
		var mouse_event = event as InputEventMouseMotion
		_update_cursor_for_fader()
		if mouse_event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if _is_mouse_over_fader_handle(mouse_event.position) or _is_dragging_fader:
				# dragging the fader
				_handle_fader_drag(mouse_event.position, mouse_event.shift_pressed)
				accept_event()
				queue_redraw()


## Open a floating LineEdit above the fader to type a new volume directly.
func _start_value_edit() -> void:
	_is_dragging_fader = false
	var editor := FloatingValueEditor.new()
	add_child(editor)
	editor.committed.connect(_on_edit_committed)
	var editor_size := Vector2(56.0, 22.0)
	editor.open("%.1f" % volume_db, FloatingValueEditor.position_above(self, editor_size), editor_size)


func _on_edit_committed(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_valid_float():
		volume_db = clamp(float(trimmed), db_bottom, db_top)
		volume_changed.emit(volume_db)


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
	var show_ticks = size.x >= min_width_for_ticks + minimum_bars_width
	var ticks_width = min_width_for_ticks if show_ticks else 0.0
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


func _handle_fader_drag(mouse_pos: Vector2, fine: bool = false) -> void:
	# 0 at top, 1 at bottom of the fader's screen-space (post-warp) range
	var y_normalized: float
	if fine:
		# Fine adjustment: scale the mouse movement instead of jumping to its position.
		var last_y_normalized: float = clamp(1.0 - (_last_fader_mouse_pos.y / size.y), 0.0, 1.0)
		var new_y_normalized: float = clamp(1.0 - (mouse_pos.y / size.y), 0.0, 1.0)
		var delta: float = (new_y_normalized - last_y_normalized) * fader_fine_drag_scale
		y_normalized = clamp(_db_to_norm(volume_db) + delta, 0.0, 1.0)
	else:
		y_normalized = clamp(1.0 - (mouse_pos.y / size.y), 0.0, 1.0)

	# apply inverse gamma warp
	var n_unwarp = y_normalized
	if gamma_warp != 1.0:
		n_unwarp = pow(y_normalized, 1.0 / gamma_warp)

	# convert normalized back to dB
	var new_volume_db = n_unwarp * (db_top - db_bottom) + db_bottom

	if new_volume_db != volume_db:
		volume_db = clamp(new_volume_db, db_bottom, db_top)
		volume_changed.emit(volume_db)

	_last_fader_mouse_pos = mouse_pos


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

var minimum_bars_width : int:
	get:
		return 12 if mono else 25

func _should_show_ticks() -> bool:
	# Show ticks if we have enough horizontal space
	return size.x >= min_width_for_ticks + minimum_bars_width

var ticks_width : float:
	get:
		return min_width_for_ticks if _should_show_ticks() else 0.0

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
		_draw_bar(rms_left, peak_left, peak_hold_left_db, _clip_left or _clip_right, offset_x, bars_width)
		fader_offset = offset_x + bars_width + 2
	else:
		var bar_width = max(0.0, (bars_width - bars_spacing) * 0.5)
		fader_offset = offset_x + bar_width
		var offset_left = offset_x
		var offset_right = offset_x + bar_width + bars_spacing
		_draw_bar(rms_left,  peak_left,  peak_hold_left_db,  _clip_left,  offset_left,  bar_width)
		_draw_bar(rms_right, peak_right, peak_hold_right_db, _clip_right, offset_right, bar_width)
	
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
		var label_y = fader_top - text_size.y - 6 if fader_top > size.y * 0.5 else fader_top + handle_radius + 28
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
func _draw_bar(rms_lin: float, peak_lin: float, hold_db: float, clipped: bool, offset_x: float, width: float) -> void:
	# background
	draw_rect(Rect2(offset_x, 0, width, size.y), bar_bg_color, true)

	# peak bar (dim) behind the solid RMS bar, both colored by level
	if peak_lin > 0.0:
		_draw_level(_lin_to_db(peak_lin), offset_x, width, peak_bar_alpha)
	if rms_lin > 0.0:
		_draw_level(_lin_to_db(rms_lin), offset_x, width, 1.0)

	# peak hold line (sticks, then falls slowly)
	if hold_db > db_bottom:
		var y_line = floor(_db_to_y(hold_db)) + 0.5
		var line_color := bar_color_clip if hold_db >= 0.0 else Color(1, 1, 1, 0.8)
		draw_line(Vector2(offset_x, y_line), Vector2(offset_x + width, y_line), line_color, 1.0)

	# clip light, latched until reset_peak_memory()
	if clipped:
		draw_rect(Rect2(offset_x, 0, width, 4), bar_color_clip, true)


## Fill from the bottom up to `db`: low color below warn_db, high color up to 0 dB, clip color above.
func _draw_level(db: float, offset_x: float, width: float, alpha: float) -> void:
	if db <= db_bottom:
		return
	var y_top := _db_to_y(db)
	var y_warn := maxf(_db_to_y(warn_db), y_top)
	var y_zero := maxf(_db_to_y(0.0), y_top)
	var low := Color(bar_color_low, bar_color_low.a * alpha)
	var high := Color(bar_color_high, bar_color_high.a * alpha)
	var clip := Color(bar_color_clip, bar_color_clip.a * alpha)
	draw_rect(Rect2(offset_x, y_warn, width, size.y - y_warn), low, true)
	if y_warn > y_zero:
		draw_rect(Rect2(offset_x, y_zero, width, y_warn - y_zero), high, true)
	if y_zero > y_top:
		draw_rect(Rect2(offset_x, y_top, width, y_zero - y_top), clip, true)
