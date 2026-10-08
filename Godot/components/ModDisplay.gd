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


const _MOD_PULSE := preload("res://components/ModPulse.gd")

## Alpha of the body overlay on assign targets that the focused modulator isn't bound to yet.
const FILL_ALPHA := 0.28
## Alpha range and rate of the pulsing overlay on controls the focused modulator is bound to.
const PULSE_ALPHA_MIN := 0.2
const PULSE_ALPHA_MAX := 0.65
const PULSE_HZ := 2.0


## Overlay on a control's main part (a knob uses `draw_fill_circle`).
static func draw_fill(item: CanvasItem, rect: Rect2, color: Color, alpha := FILL_ALPHA) -> void:
	item.draw_rect(rect, Color(color, alpha), true)


static func draw_fill_circle(item: CanvasItem, center: Vector2, radius: float, color: Color, alpha := FILL_ALPHA) -> void:
	item.draw_circle(center, radius, Color(color, alpha), true, -1.0, true)


## Current alpha of the bound-control overlay: a sine at `PULSE_HZ`, shared clock so every bound
## control pulses in step.
static func pulse_alpha() -> float:
	var phase := Time.get_ticks_msec() / 1000.0 * PULSE_HZ * TAU
	return lerpf(PULSE_ALPHA_MIN, PULSE_ALPHA_MAX, 0.5 + 0.5 * sin(phase))


## Start or stop redrawing `control` every frame for the pulsing overlay.
static func set_pulsing(control: Control, on: bool) -> void:
	# get_meta with a null default still errors on a missing key, so check first.
	var pulse: Node = control.get_meta(&"_mod_pulse") if control.has_meta(&"_mod_pulse") else null
	if on and pulse == null:
		pulse = _MOD_PULSE.new()
		control.add_child(pulse, false, Node.INTERNAL_MODE_BACK)
		control.set_meta(&"_mod_pulse", pulse)
	elif not on and pulse != null:
		control.remove_meta(&"_mod_pulse")
		pulse.queue_free()


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
