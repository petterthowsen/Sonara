class_name AutomationCurve extends RefCounted

## Shared curve evaluator, kept bit-for-bit in step with
## `Engine/src/audio/automation.rs::evaluate_segment` / `apply_tension`. The two sides must
## change together or the drawn curve stops matching what is heard (REQ-005).

## Exponent range for a point's tension. Shared with the engine: `TENSION_RANGE` there.
const TENSION_RANGE: float = 2.0


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
## halfway through. NO minus sign: `warped = t ** (2.0 ** (tension * TENSION_RANGE))`.
static func apply_tension(t: float, tension: float) -> float:
	if tension == 0.0:
		return t
	var exponent := pow(2.0, clampf(tension, -1.0, 1.0) * TENSION_RANGE)
	return pow(t, exponent)
