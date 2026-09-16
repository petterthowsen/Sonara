# Vertical volume control and Meter in one.
@tool
class_name Volumeter extends Control

@export var min_width := 8:
	set(mw):
		min_width = mw
		custom_minimum_size.x = min_width

enum HANDLE_TYPE {Circle, Line}

@export var handle_type : HANDLE_TYPE = HANDLE_TYPE.Line
@export var bg_color := Color.DIM_GRAY
@export var handle_color := Color.WHITE
@export var bar_color := Color.LIGHT_GRAY

@export_range(0.0, 1.0) var peak_bar_alpha := 0.45 ## Opacity of the peak bar drawn behind the solid RMS bar

# Ballistics, matching Meter (time-based, so frame-rate independent)
@export var peak_release_db_per_sec := 30.0 ## Peak value falls at this rate (dB/s) after a transient
@export var rms_attack_time := 0.05 ## RMS smoothing time constant when the level is rising (seconds)
@export var rms_release_time := 0.3 ## RMS smoothing time constant when the level is falling (seconds)

## Incoming peak level (linear). Setting it animates the displayed bar.
@export var peak := 0.0:
	set(p):
		peak = p
		set_process(true)

## Incoming RMS level (linear). Setting it animates the displayed bar.
var rms := 0.0:
	set(r):
		rms = r
		set_process(true)

# Smoothed display values (linear)
var _display_peak := 0.0
var _display_rms := 0.0

# Volume in dB (-60 to +12, default -6 dB)
@export var volume_db := -6.0:
	set(v):
		volume_db = clamp(v, -60.0, 6.0)
		queue_redraw()

var mouse_hovered := false

signal volume_changed(volume : float)

var is_adjusting := false
var _last_adjust_mouse_y := 0.0
@export var fine_drag_scale := 0.15

func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	custom_minimum_size.x = min_width
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	set_process(false)

func _on_mouse_entered():
	mouse_hovered = true
	queue_redraw()


func _on_mouse_exited():
	mouse_hovered = false
	queue_redraw()

func _draw():
	const MIN_DB = -60.0
	const MAX_DB = 12.0
	const DB_RANGE = MAX_DB - MIN_DB  # 72 dB

	# draw bg color
	draw_rect(Rect2(0, 0, size.x, size.y), bg_color, true, -1.0, true)

	# dim peak bar behind the solid RMS bar
	var peak_norm = clamp((Utils.lin_to_db(_display_peak) - MIN_DB) / DB_RANGE, 0.0, 1.0)
	draw_rect(Rect2(0, (1.0 - peak_norm) * size.y, size.x, peak_norm * size.y), Color(bar_color, bar_color.a * peak_bar_alpha), true, -1.0, true)
	var rms_norm = clamp((Utils.lin_to_db(_display_rms) - MIN_DB) / DB_RANGE, 0.0, 1.0)
	draw_rect(Rect2(0, (1.0 - rms_norm) * size.y, size.x, rms_norm * size.y), bar_color, true, -1.0, true)

	# draw handle (volume fader - convert dB to normalized position)
	var volume_norm = clamp((volume_db - MIN_DB) / DB_RANGE, 0.0, 1.0)
	var volume_y = (1.0 - volume_norm) * (size.y - 4)
	draw_rect(Rect2(0, volume_y, size.x, 4), handle_color, true, -1.0, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not is_adjusting and event.is_pressed():
			if event.double_click:
				_start_editing()
				return
			is_adjusting = true
			_last_adjust_mouse_y = get_local_mouse_position().y
			accept_event()
			set_process(true)
		elif is_adjusting and event.is_released():
			is_adjusting = false


func _process(delta: float) -> void:
	const MIN_DB = -60.0
	const MAX_DB = 12.0
	const DB_RANGE = MAX_DB - MIN_DB  # 72 dB

	if Engine.is_editor_hint():
		set_process(false)
		return

	_update_levels(delta)

	if is_adjusting:
		var mouse: Vector2 = get_local_mouse_position()
		var target_norm: float

		if Input.is_key_pressed(KEY_SHIFT):
			# Fine adjustment: scale the mouse movement instead of jumping to its position.
			var current_norm: float = clampf((volume_db - MIN_DB) / DB_RANGE, 0.0, 1.0)
			var delta_norm: float = -(mouse.y - _last_adjust_mouse_y) / size.y * fine_drag_scale
			target_norm = clamp(current_norm + delta_norm, 0.0, 1.0)
		else:
			# Convert mouse Y position to normalized (0.0 at bottom, 1.0 at top)
			target_norm = clamp(1.0 - (mouse.y / size.y), 0.0, 1.0)

		# Convert normalized to dB: matches VSlider's remap(normalized, 0, 1, min_value, max_value)
		var target_db = clamp(target_norm * DB_RANGE + MIN_DB, -60.0, 12.0)

		volume_db = target_db
		volume_changed.emit(volume_db)
		_last_adjust_mouse_y = mouse.y


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
	volume_db = clamp(new_volume_db, -60.0, 12.0)
	queue_redraw()


## Set both levels at once (linear).
func set_levels(peak_lin: float, rms_lin: float) -> void:
	peak = peak_lin
	rms = rms_lin


func _update_levels(delta: float) -> void:
	# Peak: instant attack, constant dB/s release
	if peak >= _display_peak:
		_display_peak = peak
	else:
		var db := Utils.lin_to_db(_display_peak) - peak_release_db_per_sec * delta
		_display_peak = peak if db <= -60.0 else maxf(peak, db_to_linear(db))

	# RMS: exponential smoothing with separate attack/release
	var tau := rms_attack_time if rms > _display_rms else rms_release_time
	_display_rms = lerpf(_display_rms, rms, 1.0 - exp(-delta / maxf(tau, 0.001)))
	if absf(_display_rms - rms) < 0.0001:
		_display_rms = rms

	queue_redraw()
	if _display_peak == peak and _display_rms == rms and not is_adjusting:
		set_process(false)
