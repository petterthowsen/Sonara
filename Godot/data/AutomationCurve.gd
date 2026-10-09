class_name AutomationCurve extends RefCounted

## Shared curve evaluator, kept bit-for-bit in step with
## `Engine/src/audio/automation.rs::evaluate_segment` / `apply_tension`. The two sides must
## change together or the drawn curve stops matching what is heard (REQ-005).

## Curvature range for a point's tension. Shared with the engine: `TENSION_RANGE` there.
const TENSION_RANGE: float = 8.0


## Value of the segment between `left` and `right` at `tick`. `right == null` holds `left`'s
## value (after the last point).
static func evaluate(left: AutomationPoint, right: AutomationPoint, tick: int) -> float:
	if tick <= left.tick:
		return left.value
	if right == null:
		return left.value
	if tick >= right.tick:
		return right.value

	if left.curve == AutomationPoint.CurveType.STEP:
		return left.value

	var span := float(right.tick - left.tick)
	var t := float(tick - left.tick) / span
	var warped := apply_tension(t, left.tension)
	return left.value + (right.value - left.value) * warped


## Warp a `0.0..1.0` ramp position by `tension`. Tension `0.0` returns `t` unchanged (exact
## early return, matching the engine), so a linear segment evaluates to exactly its midpoint
## halfway through. `warped = (e^(k*t) - 1) / (e^k - 1)` with `k = tension * TENSION_RANGE`:
## opposite tensions mirror each other and the slope stays finite at both ends.
static func apply_tension(t: float, tension: float) -> float:
	if tension == 0.0:
		return t
	var k := clampf(tension, -1.0, 1.0) * TENSION_RANGE
	if absf(k) < 1e-4:
		return t
	return (exp(k * t) - 1.0) / (exp(k) - 1.0)


## The tension whose warp passes through `w` at the segment's midpoint: inverts
## `apply_tension(0.5, tension) == 1 / (e^(k/2) + 1)`. Clamped to `-1.0..1.0`.
static func tension_for_midpoint(w: float) -> float:
	w = clampf(w, 1e-6, 1.0 - 1e-6)
	return clampf(2.0 * log(1.0 / w - 1.0) / TENSION_RANGE, -1.0, 1.0)
