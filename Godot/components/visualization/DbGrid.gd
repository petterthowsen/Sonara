@tool
## Vertical dB axis for plots: maps dB to y inside `rect` and draws the horizontal grid with
## labels. Used by the EQ curve editor (symmetric, +/-6/12/24) and meant for the Compressor's
## transfer and history views (any min/max). Holds no data and sends nothing.
class_name DbGrid extends RefCounted

## The EQ's switchable ranges (the largest gain shown either side of 0 dB).
const EQ_RANGES: Array[float] = [6.0, 12.0, 24.0]

var rect := Rect2(0, 0, 100, 100)
var min_db := -12.0
var max_db := 12.0
## Distance between grid lines in dB; 0 picks one from the range.
var step := 0.0


## Symmetric range +/-`range_db`.
func set_symmetric(range_db: float) -> void:
	min_db = -range_db
	max_db = range_db


func db_to_y(db: float) -> float:
	var t := (clampf(db, min_db, max_db) - min_db) / maxf(max_db - min_db, 0.001)
	return rect.end.y - rect.size.y * t


func y_to_db(y: float) -> float:
	var t := clampf((rect.end.y - y) / maxf(rect.size.y, 1.0), 0.0, 1.0)
	return min_db + (max_db - min_db) * t


## The grid spacing in use: `step`, or a readable one (+/-6 -> 3, +/-12 -> 6, +/-24 -> 12).
func effective_step() -> float:
	if step > 0.0:
		return step
	return maxf((max_db - min_db) / 4.0, 1.0)


## Horizontal lines at multiples of the step (the 0 dB line brighter), labelled on the left.
func draw_grid(ci: CanvasItem, font: Font, font_size: int, line_color: Color, zero_color: Color, label_color: Color) -> void:
	var s := effective_step()
	var db := ceilf(min_db / s) * s
	while db <= max_db + 0.001:
		var y := db_to_y(db)
		var is_zero := is_zero_approx(db)
		ci.draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), zero_color if is_zero else line_color, 1.0)
		if font != null and y > rect.position.y + font_size and y < rect.end.y:
			ci.draw_string(font, Vector2(rect.position.x + 3.0, y - 2.0), format_db(db),
					HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, label_color)
		db += s


## "+6", "0", "-12".
static func format_db(db: float) -> String:
	if is_zero_approx(db):
		return "0"
	return "%+d" % int(roundf(db))
