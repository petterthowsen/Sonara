class_name DawUnits extends RefCounted

## Unit conversions between Sonara and DAWproject (ADR-0005: parameters stay normalized inside
## Sonara and are converted here, at the file boundary only), plus the curve resampler.

const PPQ: int = 960
const DB_MIN: float = -60.0
const DB_MAX: float = 12.0


static func db_to_linear(db: float) -> float:
	return pow(10.0, db / 20.0)


## Linear gain to dB. Zero (and anything at or below -60 dB) gives -60 dB, the bottom of the
## volume range; the top clamps to +12 dB.
static func linear_to_db(gain: float) -> float:
	if gain <= 0.0:
		return DB_MIN
	return clampf(20.0 * log(gain) / log(10.0), DB_MIN, DB_MAX)


## True when `gain` is above the +12 dB ceiling (the importer reports the clamp).
static func linear_exceeds_max(gain: float) -> bool:
	return gain > db_to_linear(DB_MAX) + 1e-6


## Sonara volume/send dB to the `linear` gain DAWproject stores. -60 dB and below is silence.
static func volume_db_to_linear(db: float) -> float:
	if db <= DB_MIN:
		return 0.0
	return db_to_linear(db)


static func pan_to_normalized(pan: float) -> float:
	return (clampf(pan, -1.0, 1.0) + 1.0) * 0.5


static func normalized_to_pan(n: float) -> float:
	return clampf(n, 0.0, 1.0) * 2.0 - 1.0


static func ticks_to_beats(ticks: int) -> float:
	return float(ticks) / float(PPQ)


static func beats_to_ticks(beats: float) -> int:
	return roundi(beats * float(PPQ))


## Device parameter normalized (0..1) to the real value written to the file. `param` is a
## `DeviceParameter` (or null: then linear over `fallback_min`..`fallback_max`).
static func param_to_real(param: Object, normalized: float, fallback_min: float = 0.0, fallback_max: float = 1.0) -> float:
	if param != null:
		return param.normalized_to_value(normalized)
	return fallback_min + clampf(normalized, 0.0, 1.0) * (fallback_max - fallback_min)


static func real_to_param(param: Object, real: float, fallback_min: float = 0.0, fallback_max: float = 1.0) -> float:
	if param != null:
		return clampf(param.value_to_normalized(real), 0.0, 1.0)
	if fallback_max == fallback_min:
		return 0.0
	return clampf((real - fallback_min) / (fallback_max - fallback_min), 0.0, 1.0)


## Source points for `resample`: `{tick: int, value: float, step: bool, tension: float}`.
static func points_from_lane(lane: Object) -> Array:
	var out: Array = []
	for p in lane.points:
		out.append({
			"tick": p.tick,
			"value": p.value,
			"step": p.curve == AutomationPoint.CurveType.STEP,
			"tension": p.tension,
		})
	return out


## Convert a lane from one value domain to another. `points` are source points (see
## `points_from_lane`; the importer passes tension 0). `map_fn(value) -> float` maps a source
## value into the target domain. Each linear/curved segment is evaluated in the source domain,
## mapped, and bisected until straight-line interpolation between emitted points is within
## `tolerance` (absolute, in target units) - so a straight segment through a linear map emits no
## extra point. Returns `{tick: int, value: float, step: bool}` where `step` means "hold this
## value until the next point".
static func resample(points: Array, map_fn: Callable, tolerance: float) -> Array:
	var out: Array = []
	for i in points.size():
		var p: Dictionary = points[i]
		var is_last: bool = i == points.size() - 1
		var hold: bool = p.step and not is_last
		out.append({"tick": p.tick, "value": map_fn.call(p.value), "step": hold})
		if is_last or hold:
			continue
		var next: Dictionary = points[i + 1]
		_bisect(out, p, next, p.tick, next.tick, tolerance, map_fn, 0)
	return out


static func _source_at(left: Dictionary, right: Dictionary, tick: int) -> float:
	var span := float(right.tick - left.tick)
	if span <= 0.0:
		return right.value
	var t := float(tick - left.tick) / span
	return left.value + (right.value - left.value) * AutomationCurve.apply_tension(t, left.tension)


static func _bisect(out: Array, left: Dictionary, right: Dictionary, a: int, b: int, tolerance: float, map_fn: Callable, depth: int) -> void:
	if b - a <= 1 or depth > 16:
		return
	var va: float = map_fn.call(_source_at(left, right, a))
	var vb: float = map_fn.call(_source_at(left, right, b))
	var needs_split := false
	for q in [0.25, 0.5, 0.75]:
		var tick: int = a + roundi(float(b - a) * q)
		if tick <= a or tick >= b:
			continue
		var actual: float = map_fn.call(_source_at(left, right, tick))
		var linear: float = va + (vb - va) * float(tick - a) / float(b - a)
		if absf(actual - linear) > tolerance:
			needs_split = true
			break
	if not needs_split:
		return
	var mid: int = (a + b) / 2
	_bisect(out, left, right, a, mid, tolerance, map_fn, depth + 1)
	out.append({"tick": mid, "value": map_fn.call(_source_at(left, right, mid)), "step": false})
	_bisect(out, left, right, mid, b, tolerance, map_fn, depth + 1)
