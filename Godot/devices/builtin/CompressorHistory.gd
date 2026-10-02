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
## Width of one drawn column in pixels. Records are folded into columns (max of each) so the
## cost of a redraw follows the control's width, not the number of records held.
const COLUMN_WIDTH := 2.0
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
## Seconds of history the window shows, from the sample rate.
var _window_seconds := 4.0
## Pixels the drawing is shifted right of where the records sit. Blobs arrive at about 12 Hz, so
## each one adds its width here and `_process` eases it back to 0 at the scroll speed: the
## history then scrolls smoothly instead of in steps.
var _scroll_offset := 0.0
## Records dropped from the front so far: record `i` is number `_base + i` of the stream.
var _base := 0


func _init() -> void:
	set_process(false)
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
	_window_seconds = float(capacity) * CompressorData.RECORD_FRAMES / maxf(sample_rate, 1.0)


## Append one decoded `"dynamics"` blob.
func push_records(decoded: Dictionary) -> void:
	var count := int(decoded.get("count", 0))
	if count <= 0:
		return
	_in.append_array(decoded["in_peak_db"])
	_out.append_array(decoded["out_peak_db"])
	_gr.append_array(decoded["gr_db"])
	# Keep more than the window: the drawing is shifted right by the scroll offset, and the
	# oldest, partly filled column must stay off the left edge.
	var retained := retained_count()
	if _in.size() > retained:
		var drop := _in.size() - retained
		_base += drop
		_in = _in.slice(drop)
		_out = _out.slice(drop)
		_gr = _gr.slice(drop)
	# Cap the lag at a quarter of the window, so a stalled stream can't leave the plot empty.
	var width := plot_rect().size.x
	_scroll_offset = minf(_scroll_offset + width * float(count) / float(capacity), width * 0.25)
	set_process(_scroll_offset > 0.0)
	queue_redraw()


## Records kept: the window plus room for the scroll lag and one partly filled column.
func retained_count() -> int:
	return capacity + int(ceilf(capacity * 0.25)) + 64


func _process(delta: float) -> void:
	_scroll_offset = maxf(_scroll_offset - plot_rect().size.x / _window_seconds * delta, 0.0)
	if _scroll_offset <= 0.0:
		set_process(false)
	queue_redraw()


func clear() -> void:
	_scroll_offset = 0.0
	_base = 0
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
	var columns := _columns()
	_draw_gr(font, columns)
	_draw_levels(columns)
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


## Records per column: about `COLUMN_WIDTH` pixels each.
func _records_per_column() -> int:
	var per_record := plot_rect().size.x / float(maxi(capacity, 1))
	return maxi(int(roundf(COLUMN_WIDTH / maxf(per_record, 0.001))), 1)


## Fold the records into columns, keeping the max of each series. A column is fixed to absolute
## stream positions (`_base + i`), so data that has scrolled into the past never changes.
## Returns {first, per, in, out, gr}; column `j` is stream column `first + j`.
func _columns() -> Dictionary:
	var per := _records_per_column()
	var first := _base / per
	var last := (_base + _in.size() - 1) / per
	var column_count := maxi(last - first + 1, 0)
	var in_max := PackedFloat32Array()
	var out_max := PackedFloat32Array()
	var gr_max := PackedFloat32Array()
	in_max.resize(column_count)
	out_max.resize(column_count)
	gr_max.resize(column_count)
	in_max.fill(-INF)
	out_max.fill(-INF)
	for i in _in.size():
		var column := (_base + i) / per - first
		in_max[column] = maxf(in_max[column], _in[i])
		out_max[column] = maxf(out_max[column], _out[i])
		gr_max[column] = maxf(gr_max[column], _gr[i])
	return {"first": first, "per": per, "count": column_count, "in": in_max, "out": out_max, "gr": gr_max}


## Left edge of stream column `first + j`. The newest record sits at the right edge, plus the
## scroll offset that eases away.
func _column_x(columns: Dictionary, j: int) -> float:
	var per_record := plot_rect().size.x / float(maxi(capacity, 1))
	var newest := _base + _in.size()
	var start_record: int = (int(columns["first"]) + j) * int(columns["per"])
	return plot_rect().end.x - float(newest - start_record) * per_record + _scroll_offset


func _column_width(columns: Dictionary) -> float:
	return int(columns["per"]) * plot_rect().size.x / float(maxi(capacity, 1))


## The gain reduction hanging from the top of its strip.
func _draw_gr(font: Font, columns: Dictionary) -> void:
	var strip := gr_rect()
	var gr_max: PackedFloat32Array = columns["gr"]
	var width := _column_width(columns)
	for column in columns["count"]:
		var depth := clampf(gr_max[column] / GR_MAX_DB, 0.0, 1.0) * (strip.size.y - 2.0)
		if depth > 0.0:
			draw_rect(Rect2(_column_x(columns, column), strip.position.y, width, depth), GR_COLOR)
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


func _draw_levels(columns: Dictionary) -> void:
	var plot := plot_rect()
	var bottom := plot.end.y
	var in_max: PackedFloat32Array = columns["in"]
	var out_max: PackedFloat32Array = columns["out"]
	var output_line := PackedVector2Array()
	var width := _column_width(columns)
	for column in columns["count"]:
		var x := _column_x(columns, column)
		var top := clampf(db_to_y(in_max[column]), plot.position.y, bottom)
		draw_rect(Rect2(x, top, width, bottom - top), INPUT_FILL)
		output_line.append(Vector2(x + width * 0.5, db_to_y(out_max[column])))
	if output_line.size() >= 2:
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
