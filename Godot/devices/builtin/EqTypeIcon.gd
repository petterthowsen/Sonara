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
	var inner := Rect2(Vector2(1.5, 2.0), size - Vector2(3.0, 4.0))
	draw_polyline(_curve_points(type, inner), color, 1.5, true)


## Dropdown item icon: the same magnitude curve as `_draw`, rasterised into an
## ImageTexture at a fixed small size. Coloured on a transparent background.
static func texture(type: int, color: Color) -> ImageTexture:
	var key := type * 0x100000000 | (color.to_rgba32() as int)
	if _texture_cache.has(key):
		return _texture_cache[key]
	var img := Image.create(ICON_SIZE.x, ICON_SIZE.y, false, Image.FORMAT_RGBA8)
	var inner := Rect2(Vector2(1.5, 2.0), Vector2(ICON_SIZE) - Vector2(3.0, 4.0))
	_stroke(img, _curve_points(type, inner), color)
	var tex := ImageTexture.create_from_image(img)
	_texture_cache[key] = tex
	return tex


const ICON_SIZE := Vector2i(16, 16)
static var _texture_cache: Dictionary = {}


## The polyline `_draw` renders, parameterised by the drawing rect so the
## control and the texture variant share one geometry.
static func _curve_points(type: int, rect: Rect2) -> PackedVector2Array:
	var gain := 9.0 if EqResponse.type_uses_gain(type) else 0.0
	var filter := EqResponse.band_filter(type, 1000.0, gain, 1.0, 1, SAMPLE_RATE)
	var values := PackedFloat32Array()
	values.resize(SAMPLES)
	var lo := 0.0
	var hi := 0.0
	for i in SAMPLES:
		var hz := 100.0 * pow(100.0, float(i) / float(SAMPLES - 1))
		var db := EqResponse.filter_db(filter, hz, SAMPLE_RATE)
		# Notches and cuts dive far below the picture: keep the shape readable.
		db = clampf(db, -18.0, 18.0)
		values[i] = db
		lo = minf(lo, db)
		hi = maxf(hi, db)
	var span := maxf(hi - lo, 6.0)
	var points := PackedVector2Array()
	points.resize(SAMPLES)
	for i in SAMPLES:
		var x := rect.position.x + rect.size.x * float(i) / float(SAMPLES - 1)
		var y := rect.end.y - rect.size.y * (values[i] - lo) / span
		points[i] = Vector2(x, y)
	return points


## Anti-aliased polyline stroke into an RGBA image: the pen is a small disc
## stamped along each segment, so a 16 px icon keeps the 1.5 px curve weight.
static func _stroke(img: Image, points: PackedVector2Array, color: Color) -> void:
	const RADIUS := 0.75
	for i in points.size() - 1:
		var from := points[i]
		var to := points[i + 1]
		var steps := maxi(ceili(from.distance_to(to) * 2.0), 1)
		for s in steps + 1:
			_plot(img, from.lerp(to, float(s) / float(steps)), RADIUS, color)


static func _plot(img: Image, centre: Vector2, radius: float, color: Color) -> void:
	var x0 := maxi(int(floor(centre.x - radius)), 0)
	var x1 := mini(int(ceil(centre.x + radius)), img.get_width() - 1)
	var y0 := maxi(int(floor(centre.y - radius)), 0)
	var y1 := mini(int(ceil(centre.y + radius)), img.get_height() - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var coverage := clampf(radius + 0.5 - Vector2(x + 0.5, y + 0.5).distance_to(centre), 0.0, 1.0)
			if coverage <= 0.0:
				continue
			var dst := img.get_pixel(x, y)
			var out_a := maxf(dst.a, coverage)
			var rgb := color
			if dst.a > 0.0:
				rgb = (color * coverage + dst * dst.a * (1.0 - coverage)) / out_a
			img.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, out_a))
