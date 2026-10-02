@tool
## Tick and label layout for a scale drawn beside a control (Fader, HorSlider). The mapping from a
## value to 0..1 is the control's own, so marks sit exactly where the fill does.
class_name ScaleMarks extends RefCounted

## `marks` is an Array of `{value: float, label: String}` (label optional: the value, rounded).
## `to_norm` is a Callable(value) -> 0..1. A mark lands at `origin + norm * length`; pass a
## negative `length` from the bottom end of a vertical track. Marks outside 0..1 are dropped.
## Returns Array of `{pos: float, label: String, value: float}`.
static func layout(marks: Array, to_norm: Callable, origin: float, length: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for mark in marks:
		var value := float(mark["value"])
		var norm := float(to_norm.call(value))
		if norm < -0.0001 or norm > 1.0001:
			continue
		var label: String = str(mark["label"]) if mark.has("label") else str(roundi(value))
		out.append({"pos": origin + clampf(norm, 0.0, 1.0) * length, "label": label, "value": value})
	return out


## Draws `items` (from `layout`) as short ticks and labels along a vertical track edge at `edge_x`.
## `left` puts the labels on the left of the edge. Labels are kept inside 0..`height`.
static func draw_vertical(ci: CanvasItem, items: Array[Dictionary], edge_x: float, left: bool,
		height: float, font_size := 10, color := Color(1, 1, 1, 0.5)) -> void:
	var font := ThemeDB.fallback_font
	for item in items:
		var y: float = item["pos"]
		var text: String = item["label"]
		var tick := 3.0
		ci.draw_line(Vector2(edge_x, y), Vector2(edge_x + (-tick if left else tick), y), color, 1.0)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var x := edge_x - tick - 2.0 - w if left else edge_x + tick + 2.0
		var baseline := clampf(y + font_size * 0.35, font_size, maxf(height, font_size))
		ci.draw_string(font, Vector2(x, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## Draws `items` (from `layout` with a positive `length`) as ticks rising from the bottom edge of a
## horizontal track, with labels just above them. Labels are kept inside 0..`width`.
static func draw_horizontal(ci: CanvasItem, items: Array[Dictionary], bottom_y: float, width: float,
		font_size := 9, color := Color(1, 1, 1, 0.4)) -> void:
	var font := ThemeDB.fallback_font
	for item in items:
		var x: float = item["pos"]
		var text: String = item["label"]
		ci.draw_line(Vector2(x, bottom_y), Vector2(x, bottom_y - 3.0), color, 1.0)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var left := clampf(x - w * 0.5, 0.0, maxf(width - w, 0.0))
		ci.draw_string(font, Vector2(left, bottom_y - 5.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
