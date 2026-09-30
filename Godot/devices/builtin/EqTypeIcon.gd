## A small picture of an EQ band type's response (bell, shelf, cut, ...): the band's own magnitude
## curve from `EqResponse`, scaled to the icon. Drawn in the band's colour.
class_name EqTypeIcon extends Control

const SAMPLES := 24
const SAMPLE_RATE := 48000.0

var type := EqResponse.Type.BELL:
	set(value):
		type = value
		queue_redraw()

var color := Color.WHITE:
	set(value):
		color = value
		queue_redraw()


func _init() -> void:
	custom_minimum_size = Vector2(26, 16)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var gain := 9.0 if EqResponse.type_uses_gain(type) else 0.0
	var filter := EqResponse.band_filter(type, 1000.0, gain, 1.0, 1, SAMPLE_RATE)
	var values := PackedFloat32Array()
	var lo := 0.0
	var hi := 0.0
	for i in SAMPLES:
		var hz := 100.0 * pow(100.0, float(i) / float(SAMPLES - 1))
		var db := EqResponse.filter_db(filter, hz, SAMPLE_RATE)
		# Notches and cuts dive far below the picture: keep the shape readable.
		db = clampf(db, -18.0, 18.0)
		values.append(db)
		lo = minf(lo, db)
		hi = maxf(hi, db)
	var span := maxf(hi - lo, 6.0)
	var inner := Rect2(Vector2(1.5, 2.0), size - Vector2(3.0, 4.0))
	var points := PackedVector2Array()
	for i in SAMPLES:
		var x := inner.position.x + inner.size.x * float(i) / float(SAMPLES - 1)
		var y := inner.end.y - inner.size.y * (values[i] - lo) / span
		points.append(Vector2(x, y))
	draw_polyline(points, color, 1.5, true)
