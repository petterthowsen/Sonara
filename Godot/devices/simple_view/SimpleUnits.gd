## SimpleUnits.gd
## Formats a parameter's value for display in the Simple View, honoring a control's unit
## override (REQ-013). A unit only changes how the value is *shown*; the value sent to the
## engine is always the normalized 0–1 the control itself works in.

class_name SimpleUnits extends RefCounted

## Real value stays under this to count as "looks like seconds" for an empty/unset unit.
const UNITLESS_SECONDS_MAX := 10.0


## Display text for `param` at `normalized` (0–1), using `unit_override` when non-empty, else
## the parameter's own unit via `DeviceParameter.format_value`.
static func format(param: DeviceParameter, normalized: float, unit_override: String) -> String:
	if param == null:
		return ""
	if unit_override.is_empty():
		return param.format_value(param.normalized_to_value(normalized))
	var real := param.normalized_to_value(normalized)
	match unit_override:
		"%":
			return "%d%%" % roundi(normalized * 100.0)
		"dB":
			return "%.1f dB" % real
		"ms":
			return "%.1f ms" % _to_ms(param, real)
		"s":
			return "%.2f s" % real
		"Hz":
			return _format_hz(real)
		_:
			return "%.2f %s" % [real, unit_override]


## `real` in milliseconds: converted from seconds when the parameter's own unit says so or is
## unset with a range that looks like seconds, otherwise treated as already being in `ms`.
static func _to_ms(param: DeviceParameter, real: float) -> float:
	if param.unit == "s" or (param.unit.is_empty() and param.max_value <= UNITLESS_SECONDS_MAX):
		return real * 1000.0
	return real


## `real` in Hz, switching to kHz above 1000.
static func _format_hz(real: float) -> String:
	if real > 1000.0:
		return "%.2f kHz" % (real / 1000.0)
	return "%.0f Hz" % real
