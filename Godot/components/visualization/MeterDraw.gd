## Static helpers that draw level meters on any CanvasItem, in the mixer strip's colours
## (`godot-ui-components.md`, principle 5). The EQ shows an output level with it; the Compressor
## view reuses it for input, output and gain-reduction meters.
class_name MeterDraw extends RefCounted

const COLOR_LOW := Color(0.728, 0.8, 0.08)
const COLOR_HIGH := Color(0.8, 0.416, 0.08)
const COLOR_CLIP := Color(0.8, 0.08, 0.08)
const COLOR_BACKGROUND := Color(0.07, 0.07, 0.07)
const COLOR_HOLD := Color(0.96, 0.96, 0.96)

## Where the meter turns from low to high colour, and to clip, as a fraction of its range.
const HIGH_AT := 0.75
const CLIP_AT := 0.97


## 0..1 position of `db` in `min_db`..`max_db`.
static func fraction(db: float, min_db: float, max_db: float) -> float:
	return clampf((db - min_db) / maxf(max_db - min_db, 0.001), 0.0, 1.0)


## Colour at `fraction` of a level meter's travel.
static func level_color(fraction_of_range: float) -> Color:
	if fraction_of_range >= CLIP_AT:
		return COLOR_CLIP
	if fraction_of_range >= HIGH_AT:
		return COLOR_HIGH
	return COLOR_LOW


## A vertical level bar in `rect` filling from the bottom up to `level_db`. `hold_db` (NAN for none)
## draws a peak-hold line.
static func draw_level(ci: CanvasItem, rect: Rect2, level_db: float, min_db: float, max_db: float, hold_db := NAN) -> void:
	ci.draw_rect(rect, COLOR_BACKGROUND)
	var f := fraction(level_db, min_db, max_db)
	if f > 0.0:
		var height := rect.size.y * f
		ci.draw_rect(Rect2(rect.position.x, rect.end.y - height, rect.size.x, height), level_color(f))
	if not is_nan(hold_db):
		var y := rect.end.y - rect.size.y * fraction(hold_db, min_db, max_db)
		ci.draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), COLOR_HOLD, 1.0)


## A gain-reduction bar: fills from the top down to `reduction_db` (a positive number of dB of
## reduction), always in the high colour so it never reads as a level.
static func draw_reduction(ci: CanvasItem, rect: Rect2, reduction_db: float, max_reduction_db: float) -> void:
	ci.draw_rect(rect, COLOR_BACKGROUND)
	var f := fraction(reduction_db, 0.0, max_reduction_db)
	if f > 0.0:
		ci.draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x, rect.size.y * f), COLOR_HIGH)


## A horizontal variant of `draw_level`, filling from the left.
static func draw_level_horizontal(ci: CanvasItem, rect: Rect2, level_db: float, min_db: float, max_db: float) -> void:
	ci.draw_rect(rect, COLOR_BACKGROUND)
	var f := fraction(level_db, min_db, max_db)
	if f > 0.0:
		ci.draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x * f, rect.size.y), level_color(f))
