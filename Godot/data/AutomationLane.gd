class_name AutomationLane extends RefCounted

# Target parameter (e.g., "channel.volume", "channel.pan", "fx.0.wet")
var parameter_path: String = ""
var parameter_name: String = ""  # Display name

# Automation points
var points: Array = []  # Array of AutomationPoint objects

# Visual state
var visible: bool = true
var height: int = 40  # Lane height in pixels
var color: Color = Color.from_string("#FFA500", Color.ORANGE)

# Serialize to JSON
func to_json() -> Dictionary:
	return {
		"parameter_path": parameter_path,
		"parameter_name": parameter_name,
		"points": points.map(func(p): return p.to_json()) if not points.is_empty() else [],
		"visible": visible,
		"height": height,
		"color": color.to_html()
	}

# Deserialize from JSON
static func from_json(data: Dictionary) -> AutomationLane:
	var lane = AutomationLane.new()
	lane.parameter_path = data.get("parameter_path", "")
	lane.parameter_name = data.get("parameter_name", "")
	lane.visible = data.get("visible", true)
	lane.height = data.get("height", 40)
	lane.color = Color.from_string(data.get("color", "#FFA500"), Color.ORANGE)
	
	# Load automation points
	for point_data in data.get("points", []):
		lane.points.append(AutomationPoint.from_json(point_data))
	
	return lane

# Get interpolated value at a given tick position
func get_value_at_tick(tick: int) -> float:
	if points.is_empty():
		return 0.0
	
	# Find surrounding points
	var before_point = null
	var after_point = null
	
	for point in points:
		if point.tick <= tick:
			if before_point == null or point.tick > before_point.tick:
				before_point = point
		if point.tick >= tick:
			if after_point == null or point.tick < after_point.tick:
				after_point = point
	
	# If only one point or at exact point
	if before_point == null:
		return after_point.value if after_point else 0.0
	if after_point == null:
		return before_point.value
	if before_point.tick == after_point.tick:
		return before_point.value
	
	# Linear interpolation (TODO: Add curve types)
	var t = float(tick - before_point.tick) / float(after_point.tick - before_point.tick)
	return lerp(before_point.value, after_point.value, t)
