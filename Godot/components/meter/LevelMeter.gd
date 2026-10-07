@tool
## A configurable dB level meter: any number of bars, peak and/or RMS, hold lines, optional scale,
## numeric readout and caption. It draws everything itself from `MeterBallistics`.
##
## Feed it with `push(index, peak_db, rms_db)`; it wakes `_process` for the ballistics and goes
## back to sleep once every bar has settled. Clicking it resets the hold lines and the readout.
## Use `mode = REDUCTION` (with `min_db` 0 and `max_db` the range) for a gain-reduction bar that
## fills from the top: push the reduction as a positive number of dB.
class_name LevelMeter extends Control

enum Mode { LEVEL, REDUCTION }
enum ColorMode { ZONES, SOLID }
enum Display { PEAK, RMS, BOTH }
enum ScaleSide { NONE, LEFT, RIGHT }
enum Readout { NONE, TOP, BOTTOM }

const SCALE_WIDTH := 22.0
const TEXT_HEIGHT := 14.0
const FONT_SIZE := 10

@export var mode := Mode.LEVEL:
	set(v):
		mode = v
		queue_redraw()
@export var bar_count := 1:
	set(v):
		bar_count = maxi(v, 1)
		_rebuild_bars()
@export var min_db := -60.0:
	set(v):
		min_db = v
		_rebuild_bars()
@export var max_db := 6.0:
	set(v):
		max_db = v
		queue_redraw()
@export var scale_marks: Array[float] = []:
	set(v):
		scale_marks = v
		queue_redraw()
@export var scale_side := ScaleSide.NONE:
	set(v):
		scale_side = v
		queue_redraw()
@export var color_mode := ColorMode.ZONES:
	set(v):
		color_mode = v
		queue_redraw()
var _tc := ThemedColors.new(self, &"LevelMeter")
## ZONES: below `warn_db`. SOLID: the only colour
var safe_color: Color:
	get:
		return _tc.get_color(&"safe")
	set(c):
		_tc.set_color(&"safe", c)
var warn_color: Color:
	get:
		return _tc.get_color(&"warn")
	set(c):
		_tc.set_color(&"warn", c)
var clip_color: Color:
	get:
		return _tc.get_color(&"clip")
	set(c):
		_tc.set_color(&"clip", c)
var background_color: Color:
	get:
		return _tc.get_color(&"background")
	set(c):
		_tc.set_color(&"background", c)
var hold_color: Color:
	get:
		return _tc.get_color(&"hold")
	set(c):
		_tc.set_color(&"hold", c)
@export var warn_db := -6.0
@export var clip_db := -0.1
@export var display := Display.PEAK:
	set(v):
		display = v
		queue_redraw()
@export_range(0.0, 1.0) var peak_alpha := 0.45 ## Display.BOTH: the peak bar behind the RMS bar
@export var show_hold := true:
	set(v):
		show_hold = v
		queue_redraw()
@export var hold_time := 1.5:
	set(v):
		hold_time = v
		_apply_ballistics()
@export var release_db_per_sec := 30.0:
	set(v):
		release_db_per_sec = v
		_apply_ballistics()
@export var hold_release_db_per_sec := 15.0:
	set(v):
		hold_release_db_per_sec = v
		_apply_ballistics()
@export var readout := Readout.NONE:
	set(v):
		readout = v
		queue_redraw()
@export var caption := "":
	set(v):
		caption = v
		queue_redraw()
@export var bars_spacing := 2.0
@export var unit := "dB"

var _bars: Array[MeterBallistics] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_rebuild_bars()


## Newest measurement for one bar. `rms_db` (NAN: none) is what the RMS display smooths towards.
func push(index: int, peak_db: float, rms_db := NAN) -> void:
	if index < 0 or index >= _bars.size():
		return
	_bars[index].push(peak_db, rms_db)
	_wake()


## Advance the ballistics by `delta` seconds (`_process` calls this).
func advance(delta: float) -> void:
	for bar in _bars:
		bar.step(delta)
	queue_redraw()
	if _all_settled():
		set_process(false)


## Clear the hold lines and the readout maximum.
func reset_holds() -> void:
	for bar in _bars:
		bar.reset_max()
	queue_redraw()


## Current level of a bar for the active `display` (RMS shows the RMS value).
func level_db(index: int) -> float:
	var b := _bars[index]
	return b.rms_db if display == Display.RMS else b.peak_db


func hold_db(index: int) -> float:
	var b := _bars[index]
	return b.rms_hold_db if display == Display.RMS else b.peak_hold_db


func max_db_held(index: int) -> float:
	var b := _bars[index]
	return b.max_rms_db if display == Display.RMS else b.max_peak_db


## Readout text of one bar: the held maximum of the displayed value.
func readout_text(index: int) -> String:
	var v := max_db_held(index)
	if mode == Mode.REDUCTION:
		return "0.0" if v <= 0.05 else "-%.1f" % v
	return "-inf" if v <= min_db + 0.05 else "%.1f" % v


## Where a bar sits, as a rect in local coordinates.
func bar_rect(index: int) -> Rect2:
	var left := SCALE_WIDTH if scale_side == ScaleSide.LEFT else 0.0
	var right := SCALE_WIDTH if scale_side == ScaleSide.RIGHT else 0.0
	var top := TEXT_HEIGHT if readout == Readout.TOP else 0.0
	var bottom := 0.0
	if readout == Readout.BOTTOM:
		bottom += TEXT_HEIGHT
	if caption != "":
		bottom += TEXT_HEIGHT
	var width := maxf(size.x - left - right, 0.0)
	var bar_w := maxf((width - bars_spacing * (_bars.size() - 1)) / _bars.size(), 0.0)
	return Rect2(left + index * (bar_w + bars_spacing), top, bar_w, maxf(size.y - top - bottom, 0.0))


## The coloured part of a bar at `db` (defaults to the bar's displayed level).
func fill_rect(index: int, db := NAN) -> Rect2:
	var rect := bar_rect(index)
	var f := _fraction(level_db(index) if is_nan(db) else db)
	var h := rect.size.y * f
	if mode == Mode.REDUCTION:
		return Rect2(rect.position.x, rect.position.y, rect.size.x, h)
	return Rect2(rect.position.x, rect.end.y - h, rect.size.x, h)


## Colour of a level in ZONES mode (the SOLID colour otherwise).
func zone_color(db: float) -> Color:
	if color_mode == ColorMode.SOLID:
		return safe_color
	if mode == Mode.REDUCTION:
		return warn_color
	if db >= clip_db:
		return clip_color
	if db >= warn_db:
		return warn_color
	return safe_color


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		set_process(false)
		return
	advance(delta)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		reset_holds()
		accept_event()


func _draw() -> void:
	for i in _bars.size():
		_draw_bar(i)
		if readout != Readout.NONE:
			_draw_text(readout_text(i), bar_rect(i), readout == Readout.TOP, i)
	if caption != "":
		var rect := bar_rect(0)
		var span := Rect2(rect.position.x, size.y - TEXT_HEIGHT, bar_rect(_bars.size() - 1).end.x - rect.position.x, TEXT_HEIGHT)
		_draw_centered(caption, span, Color(1, 1, 1, 0.6))
	_draw_scale()


func _draw_bar(index: int) -> void:
	var rect := bar_rect(index)
	draw_rect(rect, background_color)
	var bar := _bars[index]
	if display == Display.BOTH:
		_draw_fill(index, bar.peak_db, peak_alpha)
		_draw_fill(index, bar.rms_db, 1.0)
	else:
		_draw_fill(index, level_db(index), 1.0)
	if show_hold:
		var hold := hold_db(index)
		if hold > min_db:
			var y := _y_of(rect, hold)
			draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), hold_color, 1.0)


## Fills a bar up to `db`, split into its colour zones.
func _draw_fill(index: int, db: float, alpha: float) -> void:
	var rect := bar_rect(index)
	if _fraction(db) <= 0.0:
		return
	if color_mode == ColorMode.SOLID or mode == Mode.REDUCTION:
		var c := zone_color(db)
		c.a *= alpha
		draw_rect(fill_rect(index, db), c)
		return
	var edges: Array[float] = [min_db, clampf(warn_db, min_db, max_db), clampf(clip_db, min_db, max_db), max_db]
	var colors: Array[Color] = [safe_color, warn_color, clip_color]
	for z in 3:
		var lo: float = edges[z]
		var hi: float = minf(edges[z + 1], db)
		if hi <= lo:
			continue
		var y_hi := _y_of(rect, hi)
		var y_lo := _y_of(rect, lo)
		var c: Color = colors[z]
		c.a *= alpha
		draw_rect(Rect2(rect.position.x, y_hi, rect.size.x, y_lo - y_hi), c)


func _draw_scale() -> void:
	if scale_side == ScaleSide.NONE or scale_marks.is_empty():
		return
	var rect := bar_rect(0)
	var span_end := bar_rect(_bars.size() - 1).end.x
	var font := ThemeDB.fallback_font
	for mark in scale_marks:
		if mark < minf(min_db, max_db) or mark > maxf(min_db, max_db):
			continue
		var y := _y_of(rect, mark)
		var text := str(int(mark))
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
		var x := rect.position.x - w - 3.0 if scale_side == ScaleSide.LEFT else span_end + 3.0
		draw_string(font, Vector2(x, clampf(y + FONT_SIZE * 0.35, FONT_SIZE, size.y)), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(1, 1, 1, 0.5))


func _draw_text(text: String, rect: Rect2, above: bool, index: int) -> void:
	var y := rect.position.y - TEXT_HEIGHT if above else rect.end.y
	var color := Color(1, 1, 1, 0.8)
	if mode == Mode.LEVEL and max_db_held(index) >= clip_db:
		color = clip_color
	_draw_centered(text, Rect2(rect.position.x - 4.0, y, rect.size.x + 8.0, TEXT_HEIGHT), color)


func _draw_centered(text: String, rect: Rect2, color: Color) -> void:
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(rect.position.x, rect.position.y + TEXT_HEIGHT - 3.0), text,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, FONT_SIZE, color)


func _fraction(db: float) -> float:
	return clampf((db - min_db) / maxf(max_db - min_db, 0.001), 0.0, 1.0)


## Y of `db` inside `rect`: up from the bottom for LEVEL, down from the top for REDUCTION.
func _y_of(rect: Rect2, db: float) -> float:
	var f := _fraction(db)
	if mode == Mode.REDUCTION:
		return rect.position.y + rect.size.y * f
	return rect.end.y - rect.size.y * f


func _rebuild_bars() -> void:
	_bars.clear()
	for i in bar_count:
		_bars.append(MeterBallistics.new(min_db))
	_apply_ballistics()
	queue_redraw()


func _apply_ballistics() -> void:
	for bar in _bars:
		bar.hold_time = hold_time
		bar.peak_release_db_per_sec = release_db_per_sec
		bar.hold_release_db_per_sec = hold_release_db_per_sec


func _all_settled() -> bool:
	for bar in _bars:
		if not bar.settled():
			return false
	return true


func _wake() -> void:
	if not is_processing() and is_visible_in_tree():
		set_process(true)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_tc.refresh()
		queue_redraw()
