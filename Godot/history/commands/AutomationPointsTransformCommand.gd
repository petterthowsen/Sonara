# AutomationPointsTransformCommand.gd
# Undoable move/reshape of one or more automation points as a single history entry.
# Used both for a multi-point drag (tick + value change) and a curve/tension change; either way
# `curve`/`tension` are always applied explicitly (never AutomationLane.update_point's -1/NAN
# "keep existing" sentinels), so an undo always restores the exact original shape instead of
# risking a STEP point getting flattened to LINEAR by a later move.
class_name AutomationPointsTransformCommand extends Command

## Lane the points belong to.
var lane: Object = null

## Point ids affected by this gesture, in a stable order.
var point_ids: Array = []

## id -> {tick, value, curve, tension} before the gesture.
var old_states: Dictionary = {}

## id -> {tick, value, curve, tension} after the gesture.
var new_states: Dictionary = {}

## When true, a consecutive transform touching the same points on the same lane merges into this
## one (continuous drag). Leave false for a discrete action like a curve-shape toggle.
var mergeable: bool = false


## `old_states` / `new_states` are keyed by point id: {tick, value, curve, tension}.
func _init(
	p_name: String = "Move Point",
	p_lane: Object = null,
	p_point_ids: Array = [],
	p_old_states: Dictionary = {},
	p_new_states: Dictionary = {}
) -> void:
	name = p_name
	lane = p_lane
	point_ids = p_point_ids.duplicate()
	old_states = p_old_states.duplicate(true)
	new_states = p_new_states.duplicate(true)


## Allow a consecutive transform of the same points to coalesce into one undo step.
func set_mergeable(enabled: bool = true) -> AutomationPointsTransformCommand:
	mergeable = enabled
	return self


## Apply the after-gesture state.
func do() -> void:
	_apply(new_states)


## Restore the before-gesture state.
func undo() -> void:
	_apply(old_states)


func _apply(states: Dictionary) -> void:
	if lane == null:
		return
	for point_id in point_ids:
		var state: Dictionary = states.get(point_id, {})
		if state.is_empty():
			continue
		lane.update_point(point_id, state["tick"], state["value"], state["curve"], state["tension"])


## Merge with another transform of the exact same points on the exact same lane (a continuous
## drag reported as a sequence of record() calls). Mirrors PropertyCommand.can_merge.
func can_merge(other: Command) -> bool:
	if not mergeable:
		return false
	if not other is AutomationPointsTransformCommand:
		return false
	var o := other as AutomationPointsTransformCommand
	if not o.mergeable:
		return false
	if lane != o.lane:
		return false
	if point_ids.size() != o.point_ids.size():
		return false
	for point_id in point_ids:
		if not o.point_ids.has(point_id):
			return false
	return true


## Keep this command's original old_states and take the other's new_states.
func merge_with(other: Command) -> void:
	var o := other as AutomationPointsTransformCommand
	new_states = o.new_states.duplicate(true)
