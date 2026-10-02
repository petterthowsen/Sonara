## One half of the compressor's scrolling scope: a dB envelope of the input over about four
## seconds, newest on the right, growing away from a baseline. `direction` picks the side: UP grows
## from the bottom edge, DOWN from the top edge, so two scopes stacked (UP over DOWN) draw a
## mirrored envelope around a centre line.
##
## Each column is painted in three parts, all measured from the baseline:
## - primary: the input up to the threshold;
## - gray: the input above the threshold;
## - red: the gain reduction, hanging from the threshold line towards the baseline, so its length
##   is the number of dB being cut. It is drawn over the primary part.
##
## The threshold line can be dragged. Records arrive from the `"dynamics"` stream
## (`CompressorData.decode`) and are kept in a rolling window. No autoloads.
class_name CompressorScope extends Control

enum Direction { UP, DOWN }

const THRESHOLD_GRAB := 7.0
const GRID_DB := 12.0
## Width of one drawn column in pixels. Records are folded into columns (max of each) so the
## cost of a redraw follows the control's width, not the number of records held.
const COLUMN_WIDTH := 2.0
## Records kept when the sample rate is unknown.
const DEFAULT_CAPACITY := 4096

const BG_COLOR := Color(0.067, 0.067, 0.067)
const GRID_COLOR := Color(1, 1, 1, 0.07)
const LABEL_COLOR := Color(1, 1, 1, 0.4)
const BEYOND_COLOR := Color(0.58, 0.58, 0.62)
const REDUCTION_COLOR := Color(0.86, 0.2, 0.2)
const THRESHOLD_COLOR := Color(0.95, 0.75, 0.25)

@export var direction := Direction.UP:
	set(v):
		direction = v
		queue_redraw()
@export var min_db := CompressorData.MIN_DB:
	set(v):
		min_db = v
		queue_redraw()
@export var max_db := 0.0:
	set(v):
		max_db = v
		queue_redraw()
@export var input_color := UiColors.PRIMARY
@export var beyond_color := BEYOND_COLOR
@export var reduction_color := REDUCTION_COLOR
@export var show_grid := true:
	set(v):
		show_grid = v
		queue_redraw()
## Label the threshold line with its value.
@export var show_threshold_label := true:
	set(v):
		show_threshold_label = v
		queue_redraw()
## Text in the corner away from the baseline, e.g. "≈4 s".
@export var corner_text := "":
	set(v):
		corner_text = v
		queue_redraw()

var device: RefCounted = null:
	set = set_device

var threshold_db := -18.0
var dragging := false
## Records held: the last `capacity` of the stream.
var capacity := DEFAULT_CAPACITY

var _in := PackedFloat32Array()
var _gr := PackedFloat32Array()
## Seconds of history the window shows, from the sample rate.
var _window_seconds := 4.0
## Pixels the drawing is shifted right of where the records sit. Blobs arrive at about 12 Hz, so
## each one adds its width here and `_process` eases it back to 0 at the scroll speed: the
## scope then scrolls smoothly instead of in steps.
var _scroll_offset := 0.0
## Records dropped from the front so far: record `i` is number `_base + i` of the stream.
var _base := 0


func _init() -> void:
	set_process(false)
	custom_minimum_size = Vector2(120, 40)
	clip_contents = true


func set_device(value: RefCounted) -> void:
	if device != null and device.parameter_changed.is_connected(_on_parameter_changed):
		device.parameter_changed.disconnect(_on_parameter_changed)
	device = value
	if device != null:
		device.parameter_changed.connect(_on_parameter_changed)
	refresh()


func refresh() -> void:
	if device != null and device.get_parameter(CompressorData.P_THRESHOLD) != null:
		threshold_db = device.get_parameter_real(CompressorData.P_THRESHOLD)
	queue_redraw()


func _on_parameter_changed(param_id: int, _value: float) -> void:
	if param_id == CompressorData.P_THRESHOLD:
		refresh()


## How many records a four-second window holds at `sample_rate`.
func set_sample_rate(sample_rate: float) -> void:
	capacity = clampi(int(sample_rate / CompressorData.RECORD_FRAMES * 4.0), 256, 8192)
	_window_seconds = float(capacity) * CompressorData.RECORD_FRAMES / maxf(sample_rate, 1.0)


## Append one decoded `"dynamics"` blob.
func push_records(decoded: Dictionary) -> void:
	var count := int(decoded.get("count", 0))
	if count <= 0:
		return
	_in.append_array(decoded["in_peak_db"])
	_gr.append_array(decoded["gr_db"])
	# Keep more than the window: the drawing is shifted right by the scroll offset, and the
	# oldest, partly filled column must stay off the left edge.
	var retained := retained_count()
	if _in.size() > retained:
		var drop := _in.size() - retained
		_base += drop
		_in = _in.slice(drop)
		_gr = _gr.slice(drop)
	# Cap the lag at a quarter of the window, so a stalled stream can't leave the plot empty.
	_scroll_offset = minf(_scroll_offset + size.x * float(count) / float(capacity), size.x * 0.25)
	set_process(_scroll_offset > 0.0)
	queue_redraw()


## Records kept: the window plus room for the scroll lag and one partly filled column.
func retained_count() -> int:
	return capacity + int(ceilf(capacity * 0.25)) + 64


func _process(delta: float) -> void:
	_scroll_offset = maxf(_scroll_offset - size.x / _window_seconds * delta, 0.0)
	if _scroll_offset <= 0.0:
		set_process(false)
	queue_redraw()


func clear() -> void:
	_scroll_offset = 0.0
	_base = 0
	_in = PackedFloat32Array()
	_gr = PackedFloat32Array()
	queue_redraw()


func record_count() -> int:
	return _in.size()


# ============================================================================
# GEOMETRY
# ============================================================================

## Distance of `db` from the baseline, in pixels.
func db_to_extent(db: float) -> float:
	var t := (clampf(db, min_db, max_db) - min_db) / maxf(max_db - min_db, 0.001)
	return size.y * t


## Local y of `db`: up from the bottom edge for UP, down from the top edge for DOWN.
func db_to_y(db: float) -> float:
	var extent := db_to_extent(db)
	return size.y - extent if direction == Direction.UP else extent


func y_to_db(y: float) -> float:
	var extent := size.y - y if direction == Direction.UP else y
	var t := clampf(extent / maxf(size.y, 1.0), 0.0, 1.0)
	return min_db + (max_db - min_db) * t


func threshold_y() -> float:
	return db_to_y(threshold_db)


func threshold_at(pos: Vector2) -> bool:
	return absf(pos.y - threshold_y()) <= THRESHOLD_GRAB


## The three parts of one column, as pixel lengths measured from the baseline:
## `primary` (0 to the input or the threshold), `beyond` (threshold to the input, 0 when the
## input is below it) and `reduction` (from the threshold towards the baseline, capped at the
## threshold's own distance from it).
func column_segments(input_db: float, reduction_db: float) -> Dictionary:
	var threshold_extent := db_to_extent(threshold_db)
	var input_extent := db_to_extent(input_db)
	var depth := minf(reduction_db / maxf(max_db - min_db, 0.001) * size.y, threshold_extent)
	return {
		"primary": minf(input_extent, threshold_extent),
		"beyond": maxf(input_extent - threshold_extent, 0.0),
		"reduction": maxf(depth, 0.0),
	}


## A rect `extent` pixels tall starting `from` pixels off the baseline, in local coordinates.
func _span(x: float, width: float, from: float, extent: float) -> Rect2:
	if direction == Direction.UP:
		return Rect2(x, size.y - from - extent, width, extent)
	return Rect2(x, from, width, extent)


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
	draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
	if show_grid:
		_draw_grid()
	_draw_columns(_columns())
	_draw_threshold()
	if corner_text != "":
		var corner_y := 12.0 if direction == Direction.UP else size.y - 4.0
		draw_string(ThemeDB.fallback_font, Vector2(4.0, corner_y), corner_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, LABEL_COLOR)


func _draw_grid() -> void:
	var db := ceilf(min_db / GRID_DB) * GRID_DB
	while db <= max_db + 0.001:
		var y := db_to_y(db)
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(1, 1, 1, 0.18) if is_zero_approx(db) else GRID_COLOR, 1.0)
		db += GRID_DB


## Records per column: about `COLUMN_WIDTH` pixels each.
func _records_per_column() -> int:
	var per_record := size.x / float(maxi(capacity, 1))
	return maxi(int(roundf(COLUMN_WIDTH / maxf(per_record, 0.001))), 1)


## Fold the records into columns, keeping the max of each series. A column is fixed to absolute
## stream positions (`_base + i`), so data that has scrolled into the past never changes.
## Returns {first, per, count, in, gr}; column `j` is stream column `first + j`.
func _columns() -> Dictionary:
	var per := _records_per_column()
	var first := _base / per
	var last := (_base + _in.size() - 1) / per
	var column_count := maxi(last - first + 1, 0)
	var in_max := PackedFloat32Array()
	var gr_max := PackedFloat32Array()
	in_max.resize(column_count)
	gr_max.resize(column_count)
	in_max.fill(-INF)
	for i in _in.size():
		var column := (_base + i) / per - first
		in_max[column] = maxf(in_max[column], _in[i])
		gr_max[column] = maxf(gr_max[column], _gr[i])
	return {"first": first, "per": per, "count": column_count, "in": in_max, "gr": gr_max}


## Left edge of stream column `first + j`. The newest record sits at the right edge, plus the
## scroll offset that eases away.
func _column_x(columns: Dictionary, j: int) -> float:
	var per_record := size.x / float(maxi(capacity, 1))
	var newest := _base + _in.size()
	var start_record: int = (int(columns["first"]) + j) * int(columns["per"])
	return size.x - float(newest - start_record) * per_record + _scroll_offset


func _column_width(columns: Dictionary) -> float:
	return int(columns["per"]) * size.x / float(maxi(capacity, 1))


func _draw_columns(columns: Dictionary) -> void:
	var in_max: PackedFloat32Array = columns["in"]
	var gr_max: PackedFloat32Array = columns["gr"]
	var width := _column_width(columns)
	var threshold_extent := db_to_extent(threshold_db)
	for column in int(columns["count"]):
		var x := _column_x(columns, column)
		var parts := column_segments(in_max[column], gr_max[column])
		if parts["primary"] > 0.0:
			draw_rect(_span(x, width, 0.0, parts["primary"]), input_color)
		if parts["beyond"] > 0.0:
			draw_rect(_span(x, width, threshold_extent, parts["beyond"]), beyond_color)
		if parts["reduction"] > 0.0:
			draw_rect(_span(x, width, threshold_extent - parts["reduction"], parts["reduction"]), reduction_color)


func _draw_threshold() -> void:
	var y := threshold_y()
	draw_line(Vector2(0, y), Vector2(size.x, y), THRESHOLD_COLOR, 1.5 if not dragging else 2.5)
	if show_threshold_label:
		var label_y := y - 3.0 if direction == Direction.UP else y + 11.0
		draw_string(ThemeDB.fallback_font, Vector2(size.x - 52.0, label_y), "%.1f dB" % threshold_db,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, THRESHOLD_COLOR)
