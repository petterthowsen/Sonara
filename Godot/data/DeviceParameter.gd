## DeviceParameter.gd
## Metadata about a device parameter (knob, slider, etc.)

class_name DeviceParameter extends RefCounted

## ============================================================================
## PROPERTIES
## ============================================================================

## Parameter ID (0-255, device-specific)
var id: int = 0

## Human-readable name (e.g., "Delay Time", "Amplitude")
var name: String = ""

## Unit string (e.g., "ms", "dB", "Hz", or empty string)
var unit: String = ""

## Minimum value (real range, not normalized)
var min_value: float = 0.0

## Maximum value (real range, not normalized)
var max_value: float = 1.0

## Default value (real range, not normalized)
var default_value: float = 0.5

## Whether this parameter is logarithmic (e.g., delay time, frequency)
var is_logarithmic: bool = false

## Power curve for non-log float parameters: `real = min + (max - min) * n ^ skew`. 1.0 is linear.
## Ignored when `is_logarithmic`. Engine built-ins advertise it (envelope times, glide).
var skew: float = 1.0

## Parameter description/documentation
var description: String = ""

## Whether this parameter is automation-safe
var is_automation_safe: bool = true

## UI grouping: `"param"` (P tab) or `"cc"` (C tab). Empty is treated as `"param"`.
var group: String = "param"

# Typed parameter support
# "float" | "bool" | "enum"
var param_type: String = "float"

# Whether this parameter should sync to engine via OSC
var syncable: bool = true

# Enum labels for param_type == "enum"
var enum_values: Array[String] = []

## Whether the device marks this parameter as hidden
var is_hidden: bool = false

## Whether the device marks this parameter as read-only
var is_read_only: bool = false

## Whether this is the device's bypass parameter
var is_bypass: bool = false

## Whether a modulator can drive this parameter (engine built-ins advertise it).
var is_modulatable: bool = false

## CLAP module path, e.g. "Early/Size"; empty if none
var module: String = ""

## Display values (in `unit`) sampled evenly over `min_value..max_value`, parsed by the engine from
## a CLAP plugin's own value text: a ZeroEQ frequency that runs 0–1 shows as 20 Hz … 20 kHz. NaN
## where the plugin's text didn't parse. Empty when the real value is shown as is.
var display_curve := PackedFloat32Array()


## ============================================================================
## INITIALIZATION
## ============================================================================

func _init(p_id: int, p_name: String, p_unit: String = "") -> void:
	id = p_id
	name = p_name
	unit = p_unit


## ============================================================================
## CONVERSION METHODS
## ============================================================================

## Convert real value to normalized 0.0-1.0
func value_to_normalized(value: float) -> float:
	if param_type == "bool":
		return 1.0 if value >= 0.5 else 0.0

	if param_type == "enum":
		var n := enum_values.size()
		if n <= 1:
			return 0.0
		# value is treated as index for enums
		var idx := int(round(clamp(value, 0.0, float(n - 1))))
		return float(idx) / float(n - 1)

	if is_logarithmic:
		# Logarithmic scaling: log(value / min) / log(max / min)
		if value <= min_value:
			return 0.0
		if value >= max_value:
			return 1.0
		return log(value / min_value) / log(max_value / min_value)
	else:
		# Linear scaling, with an optional power curve (`skew`)
		if max_value <= min_value:
			return 0.0
		var linear: float = clamp((value - min_value) / (max_value - min_value), 0.0, 1.0)
		return pow(linear, 1.0 / skew) if skew != 1.0 else linear


## Convert normalized 0.0-1.0 to real value
func normalized_to_value(normalized: float) -> float:
	var clamped = clamp(normalized, 0.0, 1.0)

	if param_type == "bool":
		return 1.0 if clamped >= 0.5 else 0.0

	if param_type == "enum":
		var n := enum_values.size()
		if n <= 1:
			return 0.0
		# Return the enum index as a float (for display mapping)
		return float(int(round(clamped * float(n - 1))))

	if is_logarithmic:
		# Inverse logarithmic scaling: min * (max/min)^normalized
		if max_value <= min_value:
			return min_value
		return min_value * pow(max_value / min_value, clamped)
	else:
		# Linear scaling, with an optional power curve (`skew`)
		var curved: float = pow(clamped, skew) if skew != 1.0 else clamped
		return min_value + curved * (max_value - min_value)


## Convert a tool value to normalized 0–1. `{ok:true, normalized}` or `{ok:false, error}`.
func parse_tool_value(value: Variant) -> Dictionary:
	if param_type == "bool":
		var on := false
		if value is bool:
			on = value
		elif value is float or value is int:
			on = float(value) >= 0.5
		else:
			var s := str(value).strip_edges().to_lower()
			if s in ["1", "true", "on", "yes"]:
				on = true
			elif s in ["0", "false", "off", "no"]:
				on = false
			else:
				return {"ok": false, "error": "Parameter '%s' expects a boolean" % name}
		return {"ok": true, "normalized": 1.0 if on else 0.0}
	if param_type == "enum":
		var n: int = enum_values.size()
		if n <= 0:
			return {"ok": false, "error": "Parameter '%s' has no enum values" % name}
		var idx := -1
		if value is float or value is int:
			idx = int(round(float(value)))
		else:
			var label := str(value).strip_edges().to_lower()
			for i in range(n):
				if str(enum_values[i]).strip_edges().to_lower() == label:
					idx = i
					break
			if idx < 0 and label.is_valid_int():
				idx = label.to_int()
		if idx < 0 or idx >= n:
			return {"ok": false, "error": "Parameter '%s' expected one of: %s" % [name, ", ".join(enum_values)]}
		var normalized := 0.0 if n <= 1 else float(idx) / float(n - 1)
		return {"ok": true, "normalized": normalized}
	var num := 0.0
	if value is float or value is int:
		num = float(value)
	else:
		var s2 := str(value).strip_edges()
		if not s2.is_valid_float():
			return {"ok": false, "error": "Parameter '%s' expects a number" % name}
		num = s2.to_float()
	return {"ok": true, "normalized": value_to_normalized(num)}


## ============================================================================
## DISPLAY HELPERS
## ============================================================================

## Get formatted display text for a value
func format_value(value: float) -> String:
	if param_type == "bool":
		return "On" if value >= 0.5 else "Off"

	if param_type == "enum":
		var n := enum_values.size()
		if n == 0:
			return ""
		var idx := int(clamp(round(value), 0.0, float(n - 1)))
		return enum_values[idx]

	if not display_curve.is_empty():
		return format_display(display_value(value), unit)
	if is_whole_number():
		var whole := roundi(value)
		match unit:
			"key":
				return Midi.midi_to_note_name(whole)
			"%":
				return "%d%%" % whole
			_:
				return "%d %s" % [whole, unit]
	if unit.is_empty():
		return "%.2f" % value
	else:
		return "%.2f %s" % [value, unit]


## Units of built-in parameters that only make sense in whole steps (semitones, octaves, whole
## percent, MIDI keys). Plugin parameters never match: they either carry a display curve or use
## other units.
const WHOLE_NUMBER_UNITS := ["st", "oct", "%", "key"]


## True for a linear float in `WHOLE_NUMBER_UNITS` with whole-number bounds: shown as integers and
## snapped to whole steps by the Simple View.
func is_whole_number() -> bool:
	if param_type != "float" or is_logarithmic or skew != 1.0 or not display_curve.is_empty():
		return false
	if not unit in WHOLE_NUMBER_UNITS or max_value - min_value < 1.0:
		return false
	return is_equal_approx(min_value, roundf(min_value)) and is_equal_approx(max_value, roundf(max_value))


## Text for typing `value` into a knob: the real number, without unit decoration.
func edit_text(value: float) -> String:
	if is_whole_number():
		return "%d" % roundi(value)
	return "%.2f" % value


## Parse text typed into a knob (a real number, optionally with a trailing unit, or a note name for
## "key" parameters) into a real value. Returns NAN when it isn't a value.
func parse_edit_text(text: String) -> float:
	var trimmed := text.strip_edges()
	if unit == "key" and not trimmed.is_empty() and not trimmed[0] in "-0123456789.":
		var note := Midi.note_name_to_midi(trimmed)
		return float(note) if note >= 0 else NAN
	if not unit.is_empty() and trimmed.to_lower().ends_with(unit.to_lower()):
		trimmed = trimmed.substr(0, trimmed.length() - unit.length()).strip_edges()
	return float(trimmed) if trimmed.is_valid_float() else NAN


## The value to show for real `value`: read off `display_curve` when there is one, else `value`.
## Neighbouring samples of one sign are interpolated geometrically (exact for exponential curves
## such as frequencies), others linearly; next to a NaN or infinite sample the nearer one is used.
func display_value(value: float) -> float:
	var n := display_curve.size()
	if n == 0:
		return value
	if n == 1 or max_value <= min_value:
		return display_curve[0]
	var pos := clampf((value - min_value) / (max_value - min_value), 0.0, 1.0) * float(n - 1)
	var i := mini(int(pos), n - 2)
	var t := pos - float(i)
	var a := display_curve[i]
	var b := display_curve[i + 1]
	if not (is_finite(a) and is_finite(b)):
		return a if t < 0.5 else b
	if a * b > 0.0:
		return a * pow(b / a, t)
	return lerpf(a, b, t)


## `value` in `unit` with precision to suit its size: "1.25 kHz", "440 Hz", "-6.0 dB", "12.5 ms".
static func format_display(value: float, unit: String) -> String:
	if is_nan(value):
		return "-"
	if is_inf(value):
		return ("-inf" if value < 0.0 else "inf") + ("" if unit.is_empty() else " " + unit)
	var shown := value
	var shown_unit := unit
	if unit == "Hz" and absf(value) >= 1000.0:
		shown = value / 1000.0
		shown_unit = "kHz"
	elif unit == "ms" and absf(value) >= 1000.0:
		shown = value / 1000.0
		shown_unit = "s"
	var size := absf(shown)
	var text: String
	if shown_unit == "dB":
		text = "%.1f" % shown
	elif size >= 100.0:
		text = "%.0f" % shown
	elif size >= 10.0:
		text = "%.1f" % shown
	else:
		text = "%.2f" % shown
	if shown_unit.is_empty():
		return text
	return text + ("%" if shown_unit == "%" else " " + shown_unit)


## Get the full parameter label (name + unit)
func get_label() -> String:
	if unit.is_empty():
		return name
	else:
		return "%s (%s)" % [name, unit]
