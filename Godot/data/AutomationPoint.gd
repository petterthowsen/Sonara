class_name AutomationPoint extends RefCounted

## One automation point. Mirrors `Engine/src/audio/automation.rs::AutomationPoint`: curve shapes
## are reduced to LINEAR / STEP; retired stub-era shapes (BEZIER, EXPONENTIAL) load as LINEAR
## (REQ-023). `value` is always normalized 0.0..1.0.

enum CurveType { LINEAR, STEP }

var id: int = 0
var tick: int = 0        # PPQ position
var value: float = 0.0   # Normalized 0.0..1.0

var curve: CurveType = CurveType.LINEAR
var tension: float = 0.0  # -1.0..1.0; 0.0 is exactly linear


func _init(p_id: int = 0, p_tick: int = 0, p_value: float = 0.0,
		p_curve: CurveType = CurveType.LINEAR, p_tension: float = 0.0) -> void:
	id = p_id
	tick = p_tick
	value = clampf(p_value, 0.0, 1.0)
	curve = p_curve
	tension = clampf(p_tension, -1.0, 1.0)


## Wire spelling, matching `CurveKind::as_str` on the engine side.
func curve_str() -> String:
	return "step" if curve == CurveType.STEP else "linear"


## Parse the wire spelling. Unknown names fall back to LINEAR, matching `CurveKind::parse`.
static func curve_from_str(s: String) -> CurveType:
	if s == "step" or s == "Step" or s == "STEP":
		return CurveType.STEP
	return CurveType.LINEAR


func to_json() -> Dictionary:
	return {
		"id": id,
		"tick": tick,
		"value": value,
		"curve": curve_str(),
		"tension": tension,
	}


## Deserialize from JSON. `id` defaults to `default_id` when the entry predates ids (REQ-023).
## Retired curve names (`BEZIER`, `EXPONENTIAL`) and the old `curve_type` key load as LINEAR.
static func from_json(data: Dictionary, default_id: int = 0) -> AutomationPoint:
	var point := AutomationPoint.new()
	point.id = data.get("id", default_id)
	point.tick = data.get("tick", 0)
	point.value = clampf(data.get("value", 0.0), 0.0, 1.0)

	var curve_raw: String = data.get("curve", data.get("curve_type", "linear"))
	point.curve = curve_from_str(curve_raw)

	point.tension = clampf(data.get("tension", 0.0), -1.0, 1.0)
	return point
