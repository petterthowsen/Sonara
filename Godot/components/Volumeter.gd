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

@export var peak := 0.0:
	set(p):
		peak = p
		queue_redraw()

# Volume in dB (-60 to +12, default -6 dB)
@export var volume_db := -6.0:
	set(v):
		volume_db = clamp(v, -60.0, 6.0)
		queue_redraw()

var mouse_hovered := false

signal volume_changed(volume : float)

var is_adjusting := false

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

	# draw bar (peak meter - convert linear peak to dB, then to normalized position)
	var peak_db = Utils.lin_to_db(peak)
	var peak_norm = clamp((peak_db - MIN_DB) / DB_RANGE, 0.0, 1.0)
	draw_rect(Rect2(0, (1.0 - peak_norm) * size.y, size.x, peak_norm * size.y), bar_color, true, -1.0, true)

	# draw handle (volume fader - convert dB to normalized position)
	var volume_norm = clamp((volume_db - MIN_DB) / DB_RANGE, 0.0, 1.0)
	var volume_y = (1.0 - volume_norm) * (size.y - 4)
	draw_rect(Rect2(0, volume_y, size.x, 4), handle_color, true, -1.0, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not is_adjusting and event.is_pressed():
			is_adjusting = true
			accept_event()
			set_process(true)
		elif is_adjusting and event.is_released():
			is_adjusting = false
			set_process(false)


func _process(delta: float) -> void:
	const MIN_DB = -60.0
	const MAX_DB = 12.0
	const DB_RANGE = MAX_DB - MIN_DB  # 72 dB

	if is_adjusting:
		var mouse = get_local_mouse_position()

		# Convert mouse Y position to normalized (0.0 at bottom, 1.0 at top)
		var target_norm = clamp(1.0 - (mouse.y / size.y), 0.0, 1.0)

		# Convert normalized to dB: matches VSlider's remap(normalized, 0, 1, min_value, max_value)
		var target_db = clamp(target_norm * DB_RANGE + MIN_DB, -60.0, 12.0)

		volume_db = target_db
		volume_changed.emit(volume_db)


func set_volume_no_signal(new_volume_db: float) -> void:
	"""Set volume (in dB) without emitting volume_changed signal (for feedback loop prevention)."""
	volume_db = clamp(new_volume_db, -60.0, 12.0)
	queue_redraw()
