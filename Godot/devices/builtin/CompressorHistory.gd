## The compressor's scrolling history: the input level as a fill, the output level as a line and
## the gain reduction hanging from the top, over about four seconds. A threshold line sits on it
## and can be dragged.
##
## Records arrive from the `"dynamics"` data stream (`CompressorData.decode`) and are kept in a
## rolling window; the control draws what it has, newest on the right. No autoloads.
class_name CompressorHistory extends Control

const GR_STRIP_HEIGHT := 22.0
const GR_MAX_DB := 24.0
const THRESHOLD_GRAB := 7.0
const GRID_DB := 12.0
## Records kept when the sample rate is unknown.
const DEFAULT_CAPACITY := 4096

const BG_COLOR := Color(0.067, 0.067, 0.067)
const GRID_COLOR := Color(1, 1, 1, 0.07)
const LABEL_COLOR := Color(1, 1, 1, 0.4)
const INPUT_FILL := Color(0.3, 0.55, 1.0, 0.28)
const OUTPUT_LINE := Color(0.55, 0.85, 1.0, 0.95)
const GR_COLOR := Color(0.8, 0.416, 0.08, 0.85)
const THRESHOLD_COLOR := Color(0.95, 0.75, 0.25)

var device: RefCounted = null:
	set = set_device

var threshold_db := -18.0
var dragging := false
## Records held: the last `capacity` of the stream.
var capacity := DEFAULT_CAPACITY

var db_grid := DbGrid.new()
var _in := PackedFloat32Array()
var _out := PackedFloat32Array()
var _gr := PackedFloat32Array()
var _font: Font


func _init() -> void:
	custom_minimum_size = Vector2(200, 120)
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


func refresh() -> void:
	if device != null:
		threshold_db = _real(CompressorData.P_THRESHOLD, threshold_db)
	queue_redraw()


func _real(param_id: int, fallback: float) -> float:
	if device == null or device.get_parameter(param_id) == null:
		return fallback
	return device.get_parameter_real(param_id)


func _on_parameter_changed(param_id: int, _value: float) -> void:
	if param_id == CompressorData.P_THRESHOLD:
		refresh()


## How many records a four-second window holds at `sample_rate`.
func set_sample_rate(sample_rate: float) -> void:
	capacity = clampi(int(sample_rate / CompressorData.RECORD_FRAMES * 4.0), 256, 8192)


## Append one decoded `"dynamics"` blob.
func push_records(decoded: Dictionary) -> void:
	var count := int(decoded.get("count", 0))
	if count <= 0:
		return
	_in.append_array(decoded["in_peak_db"])
	_out.append_array(decoded["out_peak_db"])
	_gr.append_array(decoded["gr_db"])
	if _in.size() > capacity:
		var drop := _in.size() - capacity
		_in = _in.slice(drop)
		_out = _out.slice(drop)
		_gr = _gr.slice(drop)
	queue_redraw()


func clear() -> void:
	_in = PackedFloat32Array()
	_out = PackedFloat32Array()
	_gr = PackedFloat32Array()
	queue_redraw()


func record_count() -> int:
	return _in.size()


# ============================================================================
# GEOMETRY
# ============================================================================

func gr_rect() -> Rect2:
	return Rect2(0, 0, size.x, GR_STRIP_HEIGHT)


func plot_rect() -> Rect2:
	return Rect2(0, GR_STRIP_HEIGHT, size.x, maxf(size.y - GR_STRIP_HEIGHT, 1.0))


func _update_layout() -> void:
	db_grid.rect = plot_rect()
	db_grid.min_db = CompressorData.MIN_DB
	db_grid.max_db = 6.0
	db_grid.step = GRID_DB


func db_to_y(db: float) -> float:
	_update_layout()
	return db_grid.db_to_y(db)


func y_to_db(y: float) -> float:
	_update_layout()
	return db_grid.y_to_db(y)


## x of record `index` in the window, newest on the right.
func record_x(index: int) -> float:
	var plot := plot_rect()
	var visible := maxi(capacity, 1)
	return plot.end.x - plot.size.x * float(visible - 1 - index) / float(visible - 1)


func threshold_y() -> float:
	return db_to_y(threshold_db)


func threshold_at(pos: Vector2) -> bool:
	return absf(pos.y - threshold_y()) <= THRESHOLD_GRAB


# ============================================================================
# EDITING
# ============================================================================

## The threshold the pointer at `y` asks for.
func drag_threshold_to(y: float) -> void:
	if device == null:
		return
	var threshold := clampf(y_to_db(y), CompressorData.MIN_DB, 0.0)
	device.set_parameter_real(CompressorData.P_THRESHOLD, threshold)
	threshold_db = threshold
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			dragging = threshold_at(mb.position)
			if dragging:
				accept_event()
			queue_redraw()
		else:
			dragging = false
			queue_redraw()
	elif event is InputEventMouseMotion and dragging:
		drag_threshold_to((event as InputEventMouseMotion).position.y)
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
	var font := _font if _font != null else ThemeDB.fallback_font
	draw_rect(gr_rect(), Color(0.05, 0.05, 0.05))
	draw_rect(plot_rect(), BG_COLOR)
	db_grid.draw_grid(self, font, 9, GRID_COLOR, Color(1, 1, 1, 0.18), LABEL_COLOR)
	_draw_gr(font)
	_draw_levels()
	_draw_threshold()
	if font != null:
		draw_string(
			font,
			plot_rect().position + Vector2(4.0, 12.0),
			"≈4 s",
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			9,
			LABEL_COLOR
		)


## The gain reduction hanging from the top of its strip.
func _draw_gr(font: Font) -> void:
	var strip := gr_rect()
	var count := _gr.size()
	if count < 2:
		return
	# Filled as a band between the top edge and the reduction depth.
	var fill := PackedVector2Array()
	for i in count:
		fill.append(Vector2(record_x(i), strip.position.y))
	for i in range(count - 1, -1, -1):
		var depth := clampf(_gr[i] / GR_MAX_DB, 0.0, 1.0) * (strip.size.y - 2.0)
		fill.append(Vector2(record_x(i), strip.position.y + depth))
	if fill.size() > 2:
		draw_colored_polygon(fill, GR_COLOR)
	if font != null:
		draw_string(
			font,
			Vector2(4.0, strip.size.y - 4.0),
			"GR  0–%d dB" % int(GR_MAX_DB),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			9,
			Color(1, 1, 1, 0.55)
		)


func _draw_levels() -> void:
	var count := _in.size()
	if count < 2:
		return
	var bottom := plot_rect().end.y
	var input_fill := PackedVector2Array()
	var output_line := PackedVector2Array()
	for i in count:
		var x := record_x(i)
		input_fill.append(Vector2(x, db_to_y(_in[i])))
		output_line.append(Vector2(x, db_to_y(_out[i])))
	# Close the input fill down to the floor so it reads as a level.
	var closed := input_fill.duplicate()
	closed.append(Vector2(input_fill[input_fill.size() - 1].x, bottom))
	closed.append(Vector2(input_fill[0].x, bottom))
	draw_colored_polygon(closed, INPUT_FILL)
	draw_polyline(input_fill, Color(0.45, 0.68, 1.0, 0.8), 1.0, true)
	draw_polyline(output_line, OUTPUT_LINE, 1.5, true)


func _draw_threshold() -> void:
	var y := threshold_y()
	var plot := plot_rect()
	draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), THRESHOLD_COLOR, 1.5)
	var font := _font if _font != null else ThemeDB.fallback_font
	if font != null:
		draw_string(
			font,
			Vector2(plot.position.x + 4.0, y - 3.0),
			"%.1f dB" % threshold_db,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			9,
			THRESHOLD_COLOR
		)
