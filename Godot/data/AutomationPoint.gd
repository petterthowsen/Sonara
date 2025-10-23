class_name AutomationPoint extends RefCounted

enum CurveType { LINEAR, BEZIER, STEP, EXPONENTIAL }

# Position and value
var tick: int = 0        # PPQ position
var value: float = 0.0   # Parameter value

# Curve shape (for future interpolation modes)
var curve_type: CurveType = CurveType.LINEAR
var tension: float = 0.0  # For bezier curves (-1.0 to 1.0)

# Serialize to JSON
func to_json() -> Dictionary:
	return {
		"tick": tick,
		"value": value,
		"curve_type": CurveType.keys()[curve_type],
		"tension": tension
	}

# Deserialize from JSON
static func from_json(data: Dictionary) -> AutomationPoint:
	var point = AutomationPoint.new()
	point.tick = data.get("tick", 0)
	point.value = data.get("value", 0.0)
	
	# Parse curve type
	var curve_str = data.get("curve_type", "LINEAR")
	point.curve_type = CurveType.get(curve_str) if CurveType.has(curve_str) else CurveType.LINEAR
	
	point.tension = data.get("tension", 0.0)
	
	return point
