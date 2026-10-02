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

## Colors of the modulation sources, by their index in the device's source list.
const SOURCE_COLORS: Array[Color] = [
	Color("#f2a33a"),
	Color("#4cc9f0"),
	Color("#b5e35a"),
	Color("#ef6f9a"),
	Color("#a78bfa"),
	Color("#f5d547"),
	Color("#4fd1b0"),
	Color("#f08a5d"),
]

## Alpha of the live-value markers while playing (Phase 6 feeds them).
const LIVE_MARKER_COLOR := Color(1, 1, 1, 0.9)


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
