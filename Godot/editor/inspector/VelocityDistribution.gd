# VelocityDistribution.gd
# Small read-only histogram of a clip's note velocities, with ticks for the median and the mean.
# Sits directly above the velocity range slider and shares its 1-127 scale, so a bar lines up with
# the slider position of the same velocity.
class_name VelocityDistribution extends Control

const BINS := 32

var _bars := PackedInt32Array()
var _median := -1.0
var _mean := -1.0
var _colors := {}


func _init() -> void:
	custom_minimum_size.y = 36.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_refresh_colors()


## Show the distribution of 7-bit `values`.
func set_values(values: Array) -> void:
	var s := VelocityRemap.stats(values)
	_bars = VelocityRemap.histogram(values, BINS)
	_median = s["median"] if values.size() > 0 else -1.0
	_mean = s["mean"] if values.size() > 0 else -1.0
	queue_redraw()


func _refresh_colors() -> void:
	_colors = {
		"bg": UiColors.role(&"well"),
		"bar": UiColors.role(&"accent_primary"),
		"median": UiColors.role(&"text_bright"),
		"mean": UiColors.role(&"accent_secondary"),
	}


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_refresh_colors()
		queue_redraw()


func _draw() -> void:
	if _colors.is_empty():
		_refresh_colors()
	draw_rect(Rect2(Vector2.ZERO, size), _colors["bg"])
	var peak := 0
	for c in _bars:
		peak = maxi(peak, c)
	if peak == 0:
		return
	var bar_w := size.x / BINS
	for i in BINS:
		if _bars[i] == 0:
			continue
		var h := (size.y - 2.0) * float(_bars[i]) / peak
		var bar_color: Color = _colors["bar"]
		draw_rect(Rect2(i * bar_w, size.y - h, maxf(1.0, bar_w - 1.0), h), bar_color)
	_draw_marker(_median, _colors["median"])
	_draw_marker(_mean, _colors["mean"])


func _draw_marker(v7: float, color: Color) -> void:
	if v7 < 0.0:
		return
	var x := (v7 - VelocityRemap.MIN_V) / (VelocityRemap.MAX_V - VelocityRemap.MIN_V) * size.x
	draw_line(Vector2(x, 0), Vector2(x, size.y), color, 1.0)
