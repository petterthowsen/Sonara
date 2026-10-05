## Pure maths behind the value lane gestures. No nodes, no input, so it tests headless.
## Values are normalized floats, clamped to the descriptor's range.
class_name ValueLaneEdits extends RefCounted


## Value for a pointer at `y` in a lane `height` px tall. The top is the maximum.
static func value_at_y(y: float, height: float, d: NoteValueDescriptor) -> float:
	if height <= 0.0:
		return d.default_value
	var t := 1.0 - clampf(y / height, 0.0, 1.0)
	return d.clamp_value(lerpf(d.min_value, d.max_value, t))


## Every value moved by `delta`, clamped.
static func offset(values: Array, delta: float, d: NoteValueDescriptor) -> Array[float]:
	var out: Array[float] = []
	for v in values:
		out.append(d.clamp_value(float(v) + delta))
	return out


## Every value multiplied by `factor` (scaled toward 0), clamped.
static func scale(values: Array, factor: float, d: NoteValueDescriptor) -> Array[float]:
	var out: Array[float] = []
	for v in values:
		out.append(d.clamp_value(float(v) * maxf(factor, 0.0)))
	return out


## Value on the line from p0 to p1 (x, value) at `x`. A vertical line gives p1's value.
static func line_value(p0: Vector2, p1: Vector2, x: float, d: NoteValueDescriptor) -> float:
	if is_equal_approx(p0.x, p1.x):
		return d.clamp_value(p1.y)
	var t := (x - p0.x) / (p1.x - p0.x)
	return d.clamp_value(lerpf(p0.y, p1.y, clampf(t, 0.0, 1.0)))


## Indices of the entries in `xs` (stem x positions) within `tolerance` px of `x`.
static func stems_at_x(xs: Array, x: float, tolerance: float) -> Array[int]:
	var out: Array[int] = []
	for i in xs.size():
		if absf(float(xs[i]) - x) <= tolerance:
			out.append(i)
	return out
