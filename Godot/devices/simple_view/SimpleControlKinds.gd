## SimpleControlKinds.gd
## Control kind names used in Simple View layouts, and the grid footprint of each.

class_name SimpleControlKinds extends RefCounted

const KNOB := "knob"
const SLIDER := "slider"
const TOGGLE := "toggle"
const SEGMENTED := "segmented"
const DROPDOWN := "dropdown"
const XY := "xy"
const ENVELOPE := "envelope"
const EQ_BAND := "eq_band"

## Footprint in cells (columns × rows) per control kind.
const FOOTPRINT: Dictionary[String, Vector2i] = {
	KNOB: Vector2i(1, 1),
	TOGGLE: Vector2i(1, 1),
	DROPDOWN: Vector2i(1, 1),
	SLIDER: Vector2i(2, 1),
	SEGMENTED: Vector2i(2, 1),
	XY: Vector2i(2, 2),
	ENVELOPE: Vector2i(3, 2),
	EQ_BAND: Vector2i(2, 1),
}

## Number of parameters each compound kind binds, in `params` order.
const PARAM_COUNT: Dictionary[String, int] = {
	XY: 2,
	ENVELOPE: 4,
	EQ_BAND: 3,
}


## True when `kind` is a known control kind.
static func is_valid(kind: String) -> bool:
	return FOOTPRINT.has(kind)


## Footprint for `kind`; unknown kinds take one cell.
static func footprint(kind: String) -> Vector2i:
	return FOOTPRINT.get(kind, Vector2i(1, 1))


## Parameter count a control of `kind` expects (1 for single-parameter kinds).
static func param_count(kind: String) -> int:
	return PARAM_COUNT.get(kind, 1)
