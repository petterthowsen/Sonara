@tool
## Shared pieces of the modulation contract that RotaryKnob, HorSlider, VolumeSlider and
## Volumeter each implement (GDScript has no traits, so the common maths lives here).
##
## A control shows the routes into its value as `mod_ranges` (`{amount, color, source, bipolar}`),
## from the base value to base + amount (both ways for a bipolar source). While
## `mod_assign_active` is set, dragging edits the amount of the active source's route instead of
## the value and the control emits `mod_amount_changed`. Amounts are in normalized parameter
## units (-1..1), so one full drag across the control moves the amount by 1.0.
class_name ModDisplay extends RefCounted

## Colors of the modulation sources, by their index in the device's source list. No yellows or
## oranges: those are the knob value ring's colors and would hide the bound modulation amount.
const SOURCE_COLORS: Array[Color] = [
	Color("#ef6f9a"),
	Color("#4cc9f0"),
	Color("#b5e35a"),
	Color("#a78bfa"),
	Color("#4fd1b0"),
	Color("#f06a6a"),
	Color("#5b8def"),
	Color("#d58cf0"),
]

## Alpha of the live-value markers while playing (Phase 6 feeds them).
const LIVE_MARKER_COLOR := Color(1, 1, 1, 0.9)


## Alpha of the body overlay, shared by assign targets and a hovered modulator's bound controls.
const FILL_ALPHA := 0.28


## Overlay on a control's main part (a knob uses `draw_fill_circle`).
static func draw_fill(item: CanvasItem, rect: Rect2, color: Color) -> void:
	item.draw_rect(rect, Color(color, FILL_ALPHA), true)


static func draw_fill_circle(item: CanvasItem, center: Vector2, radius: float, color: Color) -> void:
	item.draw_circle(center, radius, Color(color, FILL_ALPHA))


## Centered amount readout ("+35 %") over a control's body.
static func draw_hint_text(item: CanvasItem, rect: Rect2, text: String) -> void:
	if text.is_empty():
		return
	var font := ThemeDB.fallback_font
	var font_size := clampi(int(minf(rect.size.x, rect.size.y) * 0.32), 8, 12)
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var pos := Vector2(rect.get_center().x - width * 0.5,
		rect.get_center().y + font.get_ascent(font_size) * 0.5 - font.get_descent(font_size) * 0.5)
	item.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color(0, 0, 0, 0.85))
	item.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


static func source_color(index: int) -> Color:
	return SOURCE_COLORS[posmod(index, SOURCE_COLORS.size())]


## Normalized span `(low, high)` a route covers around `base` (0..1), clamped to the range.
static func span(base: float, amount: float, bipolar: bool) -> Vector2:
	var reach := absf(amount) if bipolar else amount
	var other := base - absf(amount) if bipolar else base
	var lo := minf(other, base + reach)
	var hi := maxf(other, base + reach)
	return Vector2(clampf(lo, 0.0, 1.0), clampf(hi, 0.0, 1.0))


## `current` moved by `delta` (normalized units), kept in -1..1.
static func step_amount(current: float, delta: float) -> float:
	return clampf(current + delta, -1.0, 1.0)


## Tooltip text for an amount when the owner gives no callback: "+35 %".
static func default_amount_text(amount: float) -> String:
	return "%+d %%" % roundi(amount * 100.0)
