## The compressor's transfer curve (input dB -> output dB) with the knee drawn, a live dot at
## the current input level and a corner node that sets Threshold and Ratio by dragging.
##
## Dragging the node sideways moves the threshold; dragging it up or down bends the compressed
## line by moving the output level at 0 dBFS (which is the ratio: 0 dBFS out is 1:1, at the
## threshold it is the highest ratio).
##
## Every edit goes through `device.set_parameter_real`, and the curve redraws from
## `parameter_changed`. No autoloads, so tests can drive it headless.
class_name CompressorCurve extends Control

const NODE_RADIUS := 6.0
const HIT_RADIUS := 14.0
const GRID_DB := 12.0

const BG_COLOR := Color(0.067, 0.067, 0.067)
const GRID_COLOR := Color(1, 1, 1, 0.07)
const LABEL_COLOR := Color(1, 1, 1, 0.4)
const UNITY_COLOR := Color(1, 1, 1, 0.22)
const CURVE_COLOR := Color(0.96, 0.96, 0.96, 0.95)
const KNEE_COLOR := Color(0.8, 0.6, 0.2, 0.9)
const LIVE_COLOR := Color(0.35, 0.85, 1.0)

var device: RefCounted = null:
	set = set_device

var threshold_db := -18.0
var ratio := 4.0
var knee_db := 6.0
var range_db := 60.0
## Input level of the live dot, in dBFS (NAN hides it).
var live_input_db := NAN
var dragging := false

var db_grid := DbGrid.new()
var _font: Font


func _init() -> void:
	custom_minimum_size = Vector2(200, 140)
	clip_contents = true


func _ready() -> void:
	_font = ThemeDB.fallback_font


func set_device(value: RefCounted) -> void:
	if device != null and device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.disconnect(_on_parameter_changed)
	device = value
	if device != null:
		device.parameter_changed.connect(_on_parameter_changed)
	refresh()
	queue_redraw()


## Read every value the curve needs from the device.
func refresh() -> void:
	if device != null:
		threshold_db = _real(CompressorData.P_THRESHOLD, threshold_db)
		ratio = _real(CompressorData.P_RATIO, ratio)
		knee_db = _real(CompressorData.P_KNEE, knee_db)
		range_db = _real(CompressorData.P_RANGE, range_db)
	queue_redraw()


func _real(param_id: int, fallback: float) -> float:
	if device == null or device.get_parameter(param_id) == null:
		return fallback
	return device.get_parameter_real(param_id)


func _on_parameter_changed(param_id: int, _value: float) -> void:
	if param_id in [
		CompressorData.P_THRESHOLD,
		CompressorData.P_RATIO,
		CompressorData.P_KNEE,
		CompressorData.P_RANGE,
	]:
		refresh()


# ============================================================================
# GEOMETRY
# ============================================================================

func plot_rect() -> Rect2:
	return Rect2(0, 0, size.x, size.y)


func _update_layout() -> void:
	var plot := plot_rect()
	db_grid.rect = plot
	db_grid.min_db = CompressorData.MIN_DB
	db_grid.max_db = CompressorData.MAX_DB
	db_grid.step = GRID_DB


func input_db_to_x(db: float) -> float:
	var plot := plot_rect()
	var t := clampf((db - CompressorData.MIN_DB) / (0.0 - CompressorData.MIN_DB), 0.0, 1.0)
	return plot.position.x + plot.size.x * t


func x_to_input_db(x: float) -> float:
	var plot := plot_rect()
	var t := clampf((x - plot.position.x) / maxf(plot.size.x, 1.0), 0.0, 1.0)
	return CompressorData.MIN_DB + (0.0 - CompressorData.MIN_DB) * t


func output_db_to_y(db: float) -> float:
	_update_layout()
	return db_grid.db_to_y(db)


func y_to_output_db(y: float) -> float:
	_update_layout()
	return db_grid.y_to_db(y)


## Where the corner node sits: the threshold on both axes (the knee bends around it).
func corner_position() -> Vector2:
	return Vector2(input_db_to_x(threshold_db), output_db_to_y(threshold_db))


func output_at_full_scale() -> float:
	return threshold_db + (0.0 - threshold_db) / maxf(ratio, 1.0)


func corner_at(pos: Vector2) -> bool:
	return corner_position().distance_to(pos) <= HIT_RADIUS


# ============================================================================
# EDITING
# ============================================================================

## Move the corner to `pos`: the x sets Threshold, the y bends the compressed line (Ratio).
func drag_corner_to(pos: Vector2) -> void:
	if device == null:
		return
	var threshold := clampf(x_to_input_db(pos.x), CompressorData.MIN_DB, 0.0)
	var top := clampf(y_to_output_db(pos.y), CompressorData.MIN_DB, 0.0)
	# Above the threshold the curve is `T + (in - T) / ratio`, so the level at 0 dBFS is
	# `T * (1 - 1/ratio)`; inverting that gives the ratio the pointer is asking for.
	var new_ratio := CompressorData.RATIO_MAX
	if threshold < -0.5 and top < threshold - 0.05 {
		new_ratio = threshold / (threshold - top)
	} else if top >= threshold - 0.05 {
		new_ratio = 1.0
	}
	new_ratio = clampf(new_ratio, 1.0, CompressorData.RATIO_MAX)
	device.set_parameter_real(CompressorData.P_THRESHOLD, threshold)
	device.set_parameter_real(CompressorData.P_RATIO, new_ratio)
	threshold_db = threshold
	ratio = new_ratio
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			dragging = corner_at(mb.position)
			if dragging:
				accept_event()
			queue_redraw()
		else:
			dragging = false
			queue_redraw()
	elif event is InputEventMouseMotion and dragging:
		drag_corner_to((event as InputEventMouseMotion).position)
		accept_event()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			queue_redraw()
		NOTIFICATION_VISIBILITY_CHANGED:
			if not is_visible_in_tree():
				dragging = false


# ============================================================================
# DRAWING
# ============================================================================

func _draw() -> void:
	_update_layout()
	var plot := plot_rect()
	draw_rect(plot, BG_COLOR)
	var font := _font if _font != null else ThemeDB.fallback_font
	_draw_input_grid(font)
	db_grid.draw_grid(self, font, 10, GRID_COLOR, UNITY_COLOR, LABEL_COLOR)

	# The uncompressed 1:1 line.
	var unity := PackedVector2Array([
		Vector2(input_db_to_x(CompressorData.MIN_DB), output_db_to_y(CompressorData.MIN_DB)),
		Vector2(input_db_to_x(0.0), output_db_to_y(0.0)),
	])
	draw_polyline(unity, UNITY_COLOR, 1.0, true)

	# The static curve.
	var points := PackedVector2Array()
	var steps := maxi(int(plot.size.x / 2.0), 32)
	for i in steps + 1:
		var db := CompressorData.MIN_DB + (0.0 - CompressorData.MIN_DB) * float(i) / float(steps)
		var out_db := CompressorData.static_curve_db(db, threshold_db, ratio, knee_db, range_db)
		points.append(Vector2(input_db_to_x(db), output_db_to_y(out_db)))
	draw_polyline(points, CURVE_COLOR, 2.0, true)

	_draw_knee(font)
	_draw_corner()
	_draw_live_dot()


func _draw_input_grid(font: Font) -> void:
	var plot := plot_rect()
	var db := CompressorData.MIN_DB
	while db <= 0.001:
		var x := input_db_to_x(db)
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), GRID_COLOR, 1.0)
		if db > CompressorData.MIN_DB and db < 0.0 and font != null:
			draw_string(
				font,
				Vector2(x + 3.0, plot.end.y - 3.0),
				"%d" % int(db),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				LABEL_COLOR
			)
		db += GRID_DB


## The knee region highlighted between the two break points.
func _draw_knee(font: Font) -> void:
	if knee_db <= 0.0:
		return
	var low := threshold_db - knee_db * 0.5
	var high := threshold_db + knee_db * 0.5
	var rect := Rect2(
		Vector2(input_db_to_x(low), plot_rect().position.y),
		Vector2(maxf(input_db_to_x(high) - input_db_to_x(low), 1.0), plot_rect().size.y)
	)
	draw_rect(rect, Color(KNEE_COLOR, 0.08))
	var text := "knee %.1f dB" % knee_db
	if font != null:
		draw_string(font, rect.position + Vector2(3.0, 11.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(KNEE_COLOR, 0.8))


func _draw_corner() -> void:
	var pos := corner_position()
	var top := output_db_to_y(output_at_full_scale())
	# A guide from the corner to the level at 0 dBFS shows the ratio the drag is asking for.
	draw_line(Vector2(pos.x, pos.y), Vector2(input_db_to_x(0.0), top), Color(1, 1, 1, 0.25), 1.0)
	draw_circle(pos, NODE_RADIUS + 1.5, Color(0, 0, 0, 0.6))
	draw_circle(pos, NODE_RADIUS, Color(0.95, 0.75, 0.25))
	if dragging:
		draw_arc(pos, NODE_RADIUS + 2.0, 0.0, TAU, 24, Color.WHITE, 1.5, true)
	var font := _font if _font != null else ThemeDB.fallback_font
	if font != null:
		var text := "%.1f dB  %s" % [threshold_db, CompressorData.format_ratio(ratio)]
		draw_string(
			font,
			pos + Vector2(10.0, -10.0),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			Color(0.92, 0.92, 0.95)
		)


## Where the signal is right now: input level on x, the curve's output on y.
func _draw_live_dot() -> void:
	if is_nan(live_input_db):
		return
	var out_db := CompressorData.static_curve_db(live_input_db, threshold_db, ratio, knee_db, range_db)
	var pos := Vector2(input_db_to_x(live_input_db), output_db_to_y(out_db))
	draw_circle(pos, 4.5, Color(LIVE_COLOR, 0.35))
	draw_circle(pos, 2.5, LIVE_COLOR)
