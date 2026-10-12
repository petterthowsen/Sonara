@tool
## The saturator's transfer curve (input -1…+1 -> output -1…+1) with a live dot at the current
## operating level and a strip of harmonic bars below the plot (odd and even harmonics in
## different colours).
##
## The control is fed, not interactive: `set_record` takes a dictionary from
## `SaturatorData.decode`. Every geometry helper (`curve_polyline`, `dot_position`,
## `bar_rects`) is public so tests can assert the drawing headless.
class_name SaturatorCurve extends Control

## Harmonic bar heights map this dB window onto the strip.
const BAR_MAX_DB := 0.0
## Fraction of the control height the harmonic strip takes.
const BAR_STRIP_FRACTION := 0.3
const BAR_STRIP_MAX := 64.0
const DOT_RADIUS := 4.0
const UNITY_COLOR := Color(1, 1, 1, 0.22)
const GRID_COLOR := Color(1, 1, 1, 0.07)
const LABEL_COLOR := Color(1, 1, 1, 0.4)
const CURVE_COLOR := Color(0.96, 0.96, 0.96, 0.95)

var _bg_color := UiColors.role(&"well")
## Odd harmonics (1st, 3rd, …) take the accent, even ones the secondary accent.
var odd_color := UiColors.role(&"accent_primary")
var even_color := UiColors.role(&"accent_secondary")
var dot_color := Color(0.35, 0.85, 1.0)

## The last decoded record; `curve` empty when nothing valid arrived yet.
var record := {}:
	set(value):
		record = value
		queue_redraw()


func _init() -> void:
	custom_minimum_size = Vector2(200, 120)
	clip_contents = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_bg_color = UiColors.role(&"well")
		odd_color = UiColors.role(&"accent_primary")
		even_color = UiColors.role(&"accent_secondary")
		queue_redraw()
	elif what == NOTIFICATION_RESIZED:
		queue_redraw()


## Feed a decoded `"curve"` record; an invalid one clears the drawing.
func set_record(decoded: Dictionary) -> void:
	record = decoded if decoded.get("valid", false) else {}


func clear() -> void:
	record = {}


func has_record() -> bool:
	return not record.get("curve", PackedFloat32Array()).is_empty()


# ============================================================================
# GEOMETRY
# ============================================================================

## The transfer plot above the harmonic strip.
func plot_rect() -> Rect2:
	var strip := bar_strip_height()
	return Rect2(0.0, 0.0, size.x, maxf(size.y - strip, 1.0))


func bar_strip_height() -> float:
	return minf(size.y * BAR_STRIP_FRACTION, BAR_STRIP_MAX)


func bars_rect() -> Rect2:
	return Rect2(0.0, size.y - bar_strip_height(), size.x, bar_strip_height())


## Input -1…+1 -> x.
func input_to_x(input: float) -> float:
	var plot := plot_rect()
	return plot.position.x + plot.size.x * clampf((input + 1.0) * 0.5, 0.0, 1.0)


## Output -1…+1 -> y (top is +1).
func output_to_y(output: float) -> float:
	var plot := plot_rect()
	return plot.position.y + plot.size.y * (1.0 - clampf((output + 1.0) * 0.5, 0.0, 1.0))


## x -> input -1…+1.
func x_to_input(x: float) -> float:
	var plot := plot_rect()
	var t := clampf((x - plot.position.x) / maxf(plot.size.x, 1.0), 0.0, 1.0)
	return t * 2.0 - 1.0


## The curve as pixel points; empty without a record.
func curve_polyline() -> PackedVector2Array:
	var curve: PackedFloat32Array = record.get("curve", PackedFloat32Array())
	var points := PackedVector2Array()
	if curve.is_empty():
		return points
	points.resize(curve.size())
	for i in curve.size():
		points[i] = Vector2(input_to_x(SaturatorData.curve_input(i)), output_to_y(curve[i]))
	return points


func curve_point_count() -> int:
	return record.get("curve", PackedFloat32Array()).size()


## The curve's output at `input`, interpolating the streamed points (NAN without a record).
func output_at(input: float) -> float:
	var curve: PackedFloat32Array = record.get("curve", PackedFloat32Array())
	if curve.is_empty():
		return NAN
	var t: float = clampf((input + 1.0) * 0.5 * float(curve.size() - 1), 0.0, float(curve.size() - 1))
	var i := int(t)
	var frac := t - float(i)
	var j := mini(i + 1, curve.size() - 1)
	return lerpf(curve[i], curve[j], frac)


## Where the operating-point dot sits: x from `env_db`'s amplitude, y on the curve.
## (NAN, NAN) hides the dot — silence, or no record yet.
func dot_position() -> Vector2:
	var curve: PackedFloat32Array = record.get("curve", PackedFloat32Array())
	if curve.is_empty():
		return Vector2(NAN, NAN)
	var env_db: float = record.get("env_db", NAN)
	if is_nan(env_db) or env_db < -60.0:
		return Vector2(NAN, NAN)
	var input := clampf(pow(10.0, env_db / 20.0), -1.0, 1.0)
	return Vector2(input_to_x(input), output_to_y(output_at(input)))


## The dot's input level in -1…+1 (NAN when hidden).
func dot_input() -> float:
	return x_to_input(dot_position().x) if has_record() else NAN


## dB -> bar height inside the strip (clamped).
func _bar_norm(db: float) -> float:
	var t := (clampf(db, SaturatorData.HARMONIC_FLOOR_DB, BAR_MAX_DB) - SaturatorData.HARMONIC_FLOOR_DB) \
			/ (BAR_MAX_DB - SaturatorData.HARMONIC_FLOOR_DB)
	return pow(t, 0.5)


## One rect per harmonic, bottom-up inside the strip; empty without a record.
func bar_rects() -> Array[Rect2]:
	var bars: Array[Rect2] = []
	var harmonics: PackedFloat32Array = record.get("harmonics", PackedFloat32Array())
	if harmonics.is_empty():
		return bars
	var rect := bars_rect()
	var bar_w := rect.size.x / float(harmonics.size())
	for i in harmonics.size():
		var h := rect.size.y * _bar_norm(float(harmonics[i]))
		bars.append(Rect2(
			Vector2(rect.position.x + float(i) * bar_w + 1.0, rect.end.y - h),
			Vector2(maxf(bar_w - 2.0, 1.0), h)))
	return bars


func harmonic_bar_count() -> int:
	return record.get("harmonics", PackedFloat32Array()).size()


# ============================================================================
# DRAWING
# ============================================================================

func _draw() -> void:
	var plot := plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), _bg_color)
	var font := get_theme_default_font()

	# Grid and the unity line y = x.
	for k in 9:
		var t := float(k) / 8.0
		var x := plot.position.x + plot.size.x * t
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), GRID_COLOR, 1.0)
		var y := plot.position.y + plot.size.y * t
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID_COLOR, 1.0)
	draw_line(
		Vector2(input_to_x(-1.0), output_to_y(-1.0)),
		Vector2(input_to_x(1.0), output_to_y(1.0)),
		UNITY_COLOR, 1.0, true)
	# Zero lines.
	draw_line(Vector2(input_to_x(0.0), plot.position.y), Vector2(input_to_x(0.0), plot.end.y), UNITY_COLOR, 1.0)
	draw_line(Vector2(plot.position.x, output_to_y(0.0)), Vector2(plot.end.x, output_to_y(0.0)), UNITY_COLOR, 1.0)

	var points := curve_polyline()
	if not points.is_empty():
		draw_polyline(points, CURVE_COLOR, 2.0, true)
		if font != null:
			var drive_db: float = record.get("effective_drive_db", 0.0)
			draw_string(
				font, plot.position + Vector2(4.0, 12.0),
				"drive %.1f dB" % drive_db,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, LABEL_COLOR)
		_draw_dot()

	_draw_bars(font)


func _draw_dot() -> void:
	var pos := dot_position()
	if is_nan(pos.x):
		return
	draw_circle(pos, DOT_RADIUS + 1.5, Color(0, 0, 0, 0.6))
	draw_circle(pos, DOT_RADIUS, dot_color)


func _draw_bars(font: Font) -> void:
	var harmonics: PackedFloat32Array = record.get("harmonics", PackedFloat32Array())
	if harmonics.is_empty():
		return
	var rects := bar_rects()
	for i in rects.size():
		draw_rect(rects[i], odd_color if i % 2 == 0 else even_color)
	if font != null:
		draw_string(
			font, bars_rect().position + Vector2(4.0, 10.0),
			"harmonics  odd / even",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, LABEL_COLOR)
