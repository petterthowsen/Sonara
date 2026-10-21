## TimeFormat.gd
## The one place that turns a time value into text and back. Below one second a time shows in
## milliseconds ("250 ms"), from one second up in seconds ("1.20 s"), whichever unit the value
## is stored in. Used by the envelope control, knobs, sliders and parameter display.

class_name TimeFormat extends RefCounted


## True for the units this class handles: "ms" and "s".
static func is_time_unit(unit: String) -> bool:
	return unit == "ms" or unit == "s"


## `seconds` as "0.5 ms", "250 ms" or "1.20 s".
static func format_seconds(seconds: float) -> String:
	if is_nan(seconds):
		return "-"
	if is_inf(seconds):
		return ("-inf" if seconds < 0.0 else "inf") + " s"
	var magnitude := absf(seconds)
	if magnitude < 0.01:
		return "%.1f ms" % (seconds * 1000.0)
	if magnitude < 1.0:
		return "%d ms" % roundi(seconds * 1000.0)
	return "%.2f s" % seconds


## `ms` milliseconds as text, see `format_seconds`.
static func format_ms(ms: float) -> String:
	return format_seconds(ms / 1000.0)


## `value` in `unit` ("ms" or "s") as text. Other units return "" (use `is_time_unit` first).
static func format(value: float, unit: String) -> String:
	match unit:
		"ms":
			return format_ms(value)
		"s":
			return format_seconds(value)
	return ""


## Parse typed text into a value in `unit` ("ms" or "s"). A trailing "ms" or "s" in the text
## converts to `unit`; a bare number is already in `unit`. Returns NAN when it isn't a number.
static func parse(text: String, unit: String) -> float:
	var t := text.strip_edges().to_lower()
	var factor := 1.0 # multiplier into `unit`
	if t.ends_with("ms"):
		t = t.trim_suffix("ms")
		factor = 1.0 if unit == "ms" else 0.001
	elif t.ends_with("s"):
		t = t.trim_suffix("s")
		factor = 1000.0 if unit == "ms" else 1.0
	t = t.strip_edges()
	return float(t) * factor if t.is_valid_float() else NAN
