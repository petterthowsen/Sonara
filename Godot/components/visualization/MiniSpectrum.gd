## A small log-frequency spectrum plot: a filled back curve, a front line and vertical marker
## lines. It holds no OSC state; the owner subscribes a device data stream, decodes it
## (`decode_points` reads the engine's `MiniAnalyser` layout) and feeds `set_curves`.
##
## Curves are dB values spread log-spaced from `lo_hz` to `hi_hz` over the full width. The
## control eases toward each new frame, so ~30 Hz data looks smooth. `markers` are frequencies in
## Hz (for example filter cuts); a value of 0 or less hides that marker.
class_name MiniSpectrum extends Control

## Lowest dB value drawn at the bottom edge; the top edge is `db_ceiling`.
@export var db_floor := -90.0
@export var db_ceiling := 0.0
## Back-curve fill and front-line colours.
@export var back_color := Color(0.55, 0.55, 0.58, 0.35)
@export var front_color := Color(1, 1, 1, 0.95)
@export var marker_color := Color(1, 1, 1, 0.5)
@export var grid_minor_color := Color(1, 1, 1, 0.04)
@export var grid_major_color := Color(1, 1, 1, 0.09)
@export var grid_label_color := Color(1, 1, 1, 0.35)
## Speed of the ease toward the latest frame (1 / s); higher is snappier.
@export var ease_rate := 18.0

## Marker frequencies in Hz; ≤ 0 hides one.
var markers: Array[float] = []:
	set(m):
		markers = m
		queue_redraw()

var _axis := FreqAxis.new()
var _back_target := PackedFloat32Array()
var _front_target := PackedFloat32Array()
var _back := PackedFloat32Array()
var _front := PackedFloat32Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = custom_minimum_size.max(Vector2(80, 40))
	set_process(false)


## Read a `MiniAnalyser` block starting at byte `offset` of `blob`: `lo_hz`, `hi_hz`, then
## `points` A values and `points` B values (little-endian f32). Returns `{lo_hz, hi_hz, a, b}`,
## or `{}` when the blob is too short for even one point.
static func decode_points(blob: PackedByteArray, offset: int = 0) -> Dictionary:
	var floats := (blob.size() - offset) / 4
	var points := (floats - 2) / 2
	if offset < 0 or points < 1:
		return {}
	var a := PackedFloat32Array()
	var b := PackedFloat32Array()
	a.resize(points)
	b.resize(points)
	var at := offset + 8
	for i in points:
		a[i] = blob.decode_float(at + i * 4)
		b[i] = blob.decode_float(at + (points + i) * 4)
	return {"lo_hz": blob.decode_float(offset), "hi_hz": blob.decode_float(offset + 4), "a": a, "b": b}


## Show new curves (dB per point): `back` as a filled area, `front` as a line. The axis spans
## `lo_hz` to `hi_hz`. The plot eases toward them, or jumps when the point count changed.
func set_curves(back: PackedFloat32Array, front: PackedFloat32Array, lo_hz: float, hi_hz: float) -> void:
	if lo_hz > 0.0 and hi_hz > lo_hz:
		_axis.min_hz = lo_hz
		_axis.max_hz = hi_hz
	_back_target = back
	_front_target = front
	if _back.size() != back.size() or _front.size() != front.size():
		_back = back.duplicate()
		_front = front.duplicate()
	set_process(true)
	queue_redraw()


## Drop the curves (the stream stopped).
func clear_curves() -> void:
	_back = PackedFloat32Array()
	_front = PackedFloat32Array()
	_back_target = PackedFloat32Array()
	_front_target = PackedFloat32Array()
	queue_redraw()


## X (local) of `hz` on the plot, or -1 when the marker is hidden (`hz` ≤ 0).
func marker_x(hz: float) -> float:
	if hz <= 0.0:
		return -1.0
	_axis.rect = Rect2(Vector2.ZERO, size)
	return _axis.hz_to_x(hz)


func _process(delta: float) -> void:
	var settled := _ease(_back, _back_target, delta)
	settled = _ease(_front, _front_target, delta) and settled
	queue_redraw()
	if settled:
		set_process(false)


## Move `current` toward `target`; true when it has arrived.
func _ease(current: PackedFloat32Array, target: PackedFloat32Array, delta: float) -> bool:
	var k := 1.0 - exp(-ease_rate * delta)
	var settled := true
	for i in mini(current.size(), target.size()):
		var diff := target[i] - current[i]
		if absf(diff) > 0.05:
			settled = false
		current[i] += diff * k
	return settled


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	_axis.rect = rect
	_axis.draw_grid(self, get_theme_default_font(), 9, grid_minor_color, grid_major_color, grid_label_color)
	if _back.size() >= 2:
		var line := _curve_points(_back, rect)
		var fill := PackedVector2Array(line)
		fill.append(Vector2(rect.end.x, rect.end.y))
		fill.append(Vector2(rect.position.x, rect.end.y))
		draw_colored_polygon(fill, back_color)
	if _front.size() >= 2:
		draw_polyline(_curve_points(_front, rect), front_color, 1.5, true)
	for hz in markers:
		var x := marker_x(hz)
		if x >= 0.0:
			draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), marker_color, 1.0)


## dB values as points: log-spaced across the axis range, mapped onto `db_floor`..`db_ceiling`.
func _curve_points(values: PackedFloat32Array, rect: Rect2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := values.size()
	out.resize(n)
	var span := maxf(db_ceiling - db_floor, 1.0)
	for i in n:
		var t := float(i) / float(maxi(n - 1, 1))
		var y := (1.0 - clampf((values[i] - db_floor) / span, 0.0, 1.0)) * rect.size.y
		out[i] = Vector2(rect.position.x + t * rect.size.x, rect.position.y + y)
	return out
