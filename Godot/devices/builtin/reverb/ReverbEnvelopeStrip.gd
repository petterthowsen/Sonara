@tool
## The Reverb's live envelope strip (spec 050): two scrolling traces, the reverb's input level and
## its wet output level, in dB (-60 to 0 dBFS), spanning the same time as the decay map.
##
## The strip keeps its own wall clock. `push_records` (from the `"envelope"` stream, see
## `ReverbData.decode_envelope`) fills a ring of the last `MAX_HISTORY_S` seconds at the write
## head; when the head lags "now" by more than `GAP_S` (a sleeping or bypassed reverb sends
## nothing), the gap is filled with floor records so the traces keep scrolling flat. Drawing bins
## the ring into one min/max column per pixel over `span`.
##
## In the editor, without any data, it draws a canned single hit so the scene previews.
class_name ReverbEnvelopeStrip extends Control

const MAX_HISTORY_S := 64.0
const GAP_S := 0.15
const MIN_DB := -60.0
const MAX_DB := 0.0
## What a floor record stores (the engine floors at -160 dB).
const FLOOR_DB := -160.0
const REDRAW_INTERVAL_S := 0.05

const WET_COLOR := Color(0.4, 0.75, 1.0, 0.95)
const IN_COLOR := Color(1, 1, 1, 0.6)
const GRID_COLOR := Color(1, 1, 1, 0.07)
const LABEL_COLOR := Color(1, 1, 1, 0.4)

## Seconds the strip shows (the decay map's span).
@export var span := 3.0:
	set(value):
		span = maxf(value, 0.05)
		queue_redraw()

var _in_ring := PackedFloat32Array()
var _wet_ring := PackedFloat32Array()
var _record_seconds := 0.0
## Records written so far (the ring holds the last `_in_ring.size()`).
var _written := 0
## Wall clock "now" and the time the write head has reached, in seconds.
var _now := 0.0
var _head_t := 0.0
var _since_redraw := 0.0
var _bg_color := Color(0.08, 0.08, 0.08)


func _init() -> void:
	custom_minimum_size = Vector2(300, 36)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_apply_theme_colors()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_apply_theme_colors()
		queue_redraw()
	elif what == NOTIFICATION_RESIZED:
		queue_redraw()


func _apply_theme_colors() -> void:
	var theme := ThemeDB.get_project_theme()
	if theme != null and theme.has_color(&"well", &"Sonara"):
		_bg_color = UiColors.role(&"well")


# ============================================================================
# HISTORY
# ============================================================================

## Forget all history (the view was hidden, or the device changed).
func clear() -> void:
	_in_ring = PackedFloat32Array()
	_wet_ring = PackedFloat32Array()
	_record_seconds = 0.0
	_written = 0
	_head_t = _now
	queue_redraw()


## Start the history if no record has arrived yet, so a reverb that sends nothing (asleep from
## the start, or an engine without the stream) still scrolls silence.
func begin(record_seconds := 256.0 / 48000.0) -> void:
	if _in_ring.is_empty():
		_ensure_ring(record_seconds)


## Append engine records (`in_db` / `wet_db` have one entry per record, each `record_seconds`
## long).
func push_records(in_db: PackedFloat32Array, wet_db: PackedFloat32Array, record_seconds: float) -> void:
	if record_seconds <= 0.0 or in_db.size() != wet_db.size():
		return
	_ensure_ring(record_seconds)
	_fill_gap()
	for i in in_db.size():
		_append(in_db[i], wet_db[i])
	# The display never lags the data: if the engine's clock ran ahead, catch up.
	_now = maxf(_now, _head_t)
	queue_redraw()


## Move the wall clock on by `delta` seconds and fill any silence gap. Called every frame.
func advance(delta: float) -> void:
	_now += delta
	_fill_gap()
	_since_redraw += delta
	if _since_redraw >= REDRAW_INTERVAL_S:
		_since_redraw = 0.0
		queue_redraw()


func _process(delta: float) -> void:
	advance(delta)


func _ensure_ring(record_seconds: float) -> void:
	if _in_ring.is_empty() or not is_equal_approx(record_seconds, _record_seconds):
		var capacity := int(ceil(MAX_HISTORY_S / record_seconds))
		_in_ring = PackedFloat32Array()
		_wet_ring = PackedFloat32Array()
		_in_ring.resize(capacity)
		_wet_ring.resize(capacity)
		_in_ring.fill(FLOOR_DB)
		_wet_ring.fill(FLOOR_DB)
		_record_seconds = record_seconds
		_written = 0
		_head_t = _now


func _append(in_db: float, wet_db: float) -> void:
	var slot := _written % _in_ring.size()
	_in_ring[slot] = in_db
	_wet_ring[slot] = wet_db
	_written += 1
	_head_t += _record_seconds


## Floor records until the head is within `GAP_S` of "now".
func _fill_gap() -> void:
	if _in_ring.is_empty():
		return
	var lag := _now - _head_t
	if lag <= GAP_S:
		return
	var count := mini(int((lag - GAP_S) / _record_seconds), _in_ring.size())
	for i in count:
		_append(FLOOR_DB, FLOOR_DB)
	if _now - _head_t > MAX_HISTORY_S:
		_head_t = _now - GAP_S


## Seconds of history held (up to `MAX_HISTORY_S`).
func history_seconds() -> float:
	return minf(float(_written), float(_in_ring.size())) * _record_seconds


## How far the write head trails "now" (s).
func head_lag() -> float:
	return _now - _head_t


## The records the ring holds, newest last: `[in_db, wet_db]` PackedFloat32Arrays.
func recent(seconds: float) -> Array[PackedFloat32Array]:
	var in_out := PackedFloat32Array()
	var wet_out := PackedFloat32Array()
	if not _in_ring.is_empty():
		var count := mini(mini(int(seconds / _record_seconds), _written), _in_ring.size())
		for n in range(_written - count, _written):
			in_out.append(_in_ring[n % _in_ring.size()])
			wet_out.append(_wet_ring[n % _in_ring.size()])
	return [in_out, wet_out]


# ============================================================================
# DRAWING
# ============================================================================

func _y_of_db(db: float) -> float:
	return size.y - clampf((db - MIN_DB) / (MAX_DB - MIN_DB), 0.0, 1.0) * size.y


## Per pixel column over `span`: min and max dB of the records inside it, for the trace chosen
## by `wet`. Columns without data hold NAN.
func columns(wet: bool, count: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	out.resize(count)
	out.fill(Vector2(NAN, NAN))
	if _in_ring.is_empty() or count <= 0:
		return out
	var ring := _wet_ring if wet else _in_ring
	var capacity := _in_ring.size()
	var oldest := maxi(_written - capacity, 0)
	var column_s := span / count
	for c in count:
		var t0 := _now - span + c * column_s
		var first := int(floor((t0 - _head_t) / _record_seconds)) + _written
		var last := int(floor((t0 + column_s - _head_t) / _record_seconds)) + _written
		first = maxi(first, oldest)
		last = mini(last, _written - 1)
		if last < first:
			continue
		var lo := INF
		var hi := -INF
		for n in range(first, last + 1):
			var v := ring[n % capacity]
			lo = minf(lo, v)
			hi = maxf(hi, v)
		out[c] = Vector2(lo, hi)
	return out


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _bg_color)
	for db in [-48.0, -36.0, -24.0, -12.0]:
		var y := _y_of_db(db)
		draw_line(Vector2(0, y), Vector2(size.x, y), GRID_COLOR)
	var count := maxi(int(size.x), 1)
	if _in_ring.is_empty() and Engine.is_editor_hint():
		_draw_canned(count)
	else:
		_draw_trace(columns(false, count), IN_COLOR)
		_draw_trace(columns(true, count), WET_COLOR)
	var font := get_theme_default_font()
	draw_string(font, Vector2(3, 10), "WET", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, WET_COLOR)
	draw_string(font, Vector2(30, 10), "IN", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, IN_COLOR)
	draw_string(font, Vector2(size.x - 26, size.y - 3), "-60", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, LABEL_COLOR)
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.12), false, 1.0)


func _draw_trace(cols: Array[Vector2], color: Color) -> void:
	var bottom := _y_of_db(MIN_DB)
	for c in cols.size():
		var extent := cols[c]
		if is_nan(extent.x):
			continue
		var y_hi := _y_of_db(extent.y)
		var y_lo := minf(_y_of_db(extent.x), bottom)
		if y_hi >= bottom - 0.5 and y_lo >= bottom - 0.5:
			continue
		draw_line(Vector2(c + 0.5, y_hi), Vector2(c + 0.5, maxf(y_lo, y_hi + 1.0)), color, 1.0)


## A single hit and its decay, so the scene previews in the editor.
func _draw_canned(count: int) -> void:
	var hit_t := span * 0.2
	var in_cols: Array[Vector2] = []
	var wet_cols: Array[Vector2] = []
	for c in count:
		var t := float(c) / count * span
		var since := t - hit_t
		var in_db := -6.0 if absf(since) < span / count * 2.0 else FLOOR_DB
		var wet_db := FLOOR_DB if since < 0.0 else -14.0 - 60.0 * since / (span * 0.6)
		in_cols.append(Vector2(in_db, in_db))
		wet_cols.append(Vector2(wet_db, wet_db))
	_draw_trace(in_cols, IN_COLOR)
	_draw_trace(wet_cols, WET_COLOR)
