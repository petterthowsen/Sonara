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
		# Linear scaling
		return clamp((value - min_value) / (max_value - min_value), 0.0, 1.0)


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
		# Linear scaling
		return min_value + clamped * (max_value - min_value)


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

	if unit.is_empty():
		return "%.2f" % value
	else:
		return "%.2f %s" % [value, unit]


## Get the full parameter label (name + unit)
func get_label() -> String:
	if unit.is_empty():
		return name
	else:
		return "%s (%s)" % [name, unit]
