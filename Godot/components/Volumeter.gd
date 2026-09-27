# Vertical volume control and Meter in one.
@tool
class_name Volumeter extends Control

@export var min_width := 8:
	set(mw):
		min_width = mw
		custom_minimum_size.x = min_width

# Colors default to the mixer strip's Meter so the two read as one system.
@export var bg_color := Color(0.0627451, 0.0627451, 0.0627451, 1)
@export var handle_color := Color(0.9607843, 0.9607843, 0.9607843, 1)
@export var bar_color_low := Color(0.728, 0.8, 0.08, 1) ## Level color below warn_db
@export var bar_color_high := Color(0.8, 0.416, 0.08, 1) ## Level color between warn_db and 0 dB
@export var bar_color_clip := Color(0.8, 0.08, 0.08, 1) ## Level color above 0 dB, and the clip line
@export var warn_db := -6.0 ## Level where the bar color switches from low to high

@export_range(0.0, 1.0) var peak_bar_alpha := 0.45 ## Opacity of the peak bar drawn behind the solid RMS bar

## Seconds the red clip line stays at the top after the level reaches 0 dB.
@export var clip_hold_time := 10.0

# Scale, matching the mixer fader range
@export var db_top := 6.0
@export var db_bottom := -60.0

# Ballistics, matching Meter (time-based, so frame-rate independent)
@export var peak_release_db_per_sec := 30.0 ## Peak value falls at this rate (dB/s) after a transient
@export var rms_attack_time := 0.05 ## RMS smoothing time constant when the level is rising (seconds)
@export var rms_release_time := 0.3 ## RMS smoothing time constant when the level is falling (seconds)

## Incoming peak level (linear). Setting it animates the displayed bar.
@export var peak := 0.0:
	set(p):
		peak = p
		if p >= 1.0:
			_start_clip_hold()
		set_process(true)

## Incoming RMS level (linear). Setting it animates the displayed bar.
var rms := 0.0:
	set(r):
		rms = r
		set_process(true)

# Smoothed display values (linear)
var _display_peak := 0.0
var _display_rms := 0.0

# Volume in dB, clamped to db_bottom..db_top
@export var volume_db := -6.0:
	set(v):
		volume_db = clampf(v, db_bottom, db_top)
		queue_redraw()
		_refresh_tooltip()

var mouse_hovered := false

signal volume_changed(volume : float)

var is_adjusting := false
@export var fine_drag_scale := FineDrag.DEFAULT_SCALE
var _fine_drag := FineDrag.new()
var _tooltip: ValueTooltip = null
var _clip_until_msec := 0
var _clip_timer_armed := false

const HANDLE_HEIGHT := 4.0
const CLIP_LINE_HEIGHT := 2.0


func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	custom_minimum_size.x = min_width
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_EXIT_TREE:
		if not is_visible_in_tree():
			mouse_hovered = false
			is_adjusting = false
			_refresh_tooltip()


func _on_mouse_entered():
	mouse_hovered = true
	queue_redraw()
	_refresh_tooltip()


func _on_mouse_exited():
	mouse_hovered = false
	queue_redraw()
	_refresh_tooltip()


func _db_to_norm(db: float) -> float:
	return clampf((db - db_bottom) / (db_top - db_bottom), 0.0, 1.0)


func _db_to_y(db: float) -> float:
	return (1.0 - _db_to_norm(db)) * size.y


func _handle_y() -> float:
	return (1.0 - _db_to_norm(volume_db)) * (size.y - HANDLE_HEIGHT)


func _draw():
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)

	# dim peak bar behind the solid RMS bar, both colored by level like the mixer meter
	_draw_level(Utils.lin_to_db(_display_peak), peak_bar_alpha)
	_draw_level(Utils.lin_to_db(_display_rms), 1.0)

	if _is_clip_held():
		draw_rect(Rect2(0, 0, size.x, CLIP_LINE_HEIGHT), bar_color_clip, true)

	# volume handle, only while hovered or dragged
	if mouse_hovered or is_adjusting:
		draw_rect(Rect2(0, _handle_y(), size.x, HANDLE_HEIGHT), handle_color, true)


## Fill from the bottom up to `db`: low color below warn_db, high color up to 0 dB, clip color above.
func _draw_level(db: float, alpha: float) -> void:
	if db <= db_bottom:
		return
	var y_top := _db_to_y(db)
	var y_warn := maxf(_db_to_y(warn_db), y_top)
	var y_zero := maxf(_db_to_y(0.0), y_top)
	draw_rect(Rect2(0, y_warn, size.x, size.y - y_warn), Color(bar_color_low, bar_color_low.a * alpha), true)
	if y_warn > y_zero:
		draw_rect(Rect2(0, y_zero, size.x, y_warn - y_zero), Color(bar_color_high, bar_color_high.a * alpha), true)
	if y_zero > y_top:
		draw_rect(Rect2(0, y_top, size.x, y_zero - y_top), Color(bar_color_clip, bar_color_clip.a * alpha), true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.double_click:
				is_adjusting = false
				_start_editing()
				accept_event()
				return
			is_adjusting = true
			_set_volume_from_y(_fine_drag.begin(event.position).y)
			accept_event()
		elif is_adjusting:
			is_adjusting = false
			queue_redraw()
			_refresh_tooltip()
	elif event is InputEventMouseMotion and is_adjusting:
		_fine_drag.scale = fine_drag_scale
		var point := _fine_drag.update(event.position, event.shift_pressed, Rect2(Vector2.ZERO, size))
		_set_volume_from_y(point.y)
		accept_event()


func _set_volume_from_y(y: float) -> void:
	var target_db := lerpf(db_bottom, db_top, clampf(1.0 - y / size.y, 0.0, 1.0))
	if is_equal_approx(target_db, volume_db):
		return
	volume_db = target_db
	volume_changed.emit(volume_db)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	_update_levels(delta)
	if _tooltip and _tooltip.visible:
		_position_tooltip()


## Open a floating LineEdit above the control to type a new volume directly.
func _start_editing() -> void:
	var editor := FloatingValueEditor.new()
	add_child(editor)
	editor.committed.connect(_on_edit_committed)
	var editor_size := Vector2(56.0, 22.0)
	editor.open("%.1f" % volume_db, FloatingValueEditor.position_above(self, editor_size), editor_size)


func _on_edit_committed(text: String) -> void:
	var trimmed := text.strip_edges()
	if trimmed.is_valid_float():
		volume_db = float(trimmed)
		volume_changed.emit(volume_db)


func set_volume_no_signal(new_volume_db: float) -> void:
	"""Set volume (in dB) without emitting volume_changed signal (for feedback loop prevention)."""
	volume_db = new_volume_db


## Set both levels at once (linear).
func set_levels(peak_lin: float, rms_lin: float) -> void:
	peak = peak_lin
	rms = rms_lin


func get_value_text() -> String:
	return "%.1f dB" % volume_db


func _refresh_tooltip() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	if not (mouse_hovered or is_adjusting):
		if _tooltip:
			_tooltip.visible = false
		return
	if _tooltip == null:
		_tooltip = ValueTooltip.attach(self)
	_tooltip.set_text(get_value_text())
	_tooltip.visible = true
	_position_tooltip()
	# _process keeps it glued to the handle while the track list scrolls
	set_process(true)


## Beside the handle, so the tooltip never covers the track header controls' labels above.
func _position_tooltip() -> void:
	var handle_center := Vector2(size.x, _handle_y() + HANDLE_HEIGHT * 0.5)
	_tooltip.place_right_of(get_global_transform() * handle_center)


func _is_clip_held() -> bool:
	return Time.get_ticks_msec() < _clip_until_msec


## Light the clip line for clip_hold_time, extended by every new clip.
func _start_clip_hold() -> void:
	var was_held := _is_clip_held()
	_clip_until_msec = Time.get_ticks_msec() + int(clip_hold_time * 1000.0)
	if not was_held:
		queue_redraw()
	if not _clip_timer_armed and is_inside_tree():
		_arm_clip_timer(clip_hold_time)


## One timer at a time; on timeout it re-arms for any extension, then clears the line.
func _arm_clip_timer(seconds: float) -> void:
	_clip_timer_armed = true
	get_tree().create_timer(seconds).timeout.connect(_on_clip_timer_timeout)


func _on_clip_timer_timeout() -> void:
	_clip_timer_armed = false
	if not is_inside_tree():
		return
	var remaining_msec := _clip_until_msec - Time.get_ticks_msec()
	if remaining_msec > 0:
		_arm_clip_timer(remaining_msec / 1000.0)
	else:
		queue_redraw()


func _update_levels(delta: float) -> void:
	# Peak: instant attack, constant dB/s release
	if peak >= _display_peak:
		_display_peak = peak
	else:
		var db := Utils.lin_to_db(_display_peak) - peak_release_db_per_sec * delta
		_display_peak = peak if db <= db_bottom else maxf(peak, db_to_linear(db))

	# RMS: exponential smoothing with separate attack/release
	var tau := rms_attack_time if rms > _display_rms else rms_release_time
	_display_rms = lerpf(_display_rms, rms, 1.0 - exp(-delta / maxf(tau, 0.001)))
	if absf(_display_rms - rms) < 0.0001:
		_display_rms = rms

	queue_redraw()
	var tooltip_shown := _tooltip != null and _tooltip.visible
	if _display_peak == peak and _display_rms == rms and not tooltip_shown:
		set_process(false)
