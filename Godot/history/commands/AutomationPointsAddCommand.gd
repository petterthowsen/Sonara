# AutomationPointsAddCommand.gd
# Undoable add of one or more automation points as a single history entry.
#
# AutomationLane.add_point() allocates the point's id from its own counter, so calling it again on
# redo would hand back a NEW id instead of the one removed by undo (the engine keys points by id
# within a lane, so ids must stay stable across an undo/redo cycle). Instead this command creates
# the AutomationPoint objects itself once (on the first do()) and keeps those exact object
# references; every subsequent do()/undo() re-inserts or removes the SAME objects, so the id never
# drifts. Insertion reuses AutomationLane's own sorted-insert + OSC-send helpers (marked with a
# leading underscore by convention, not enforced privacy) rather than duplicating that logic.
class_name AutomationPointsAddCommand extends Command

## Lane the points are added to / removed from.
var lane: Object = null

## Specs for the points to create: [{tick, value, curve, tension}, ...].
var specs: Array = []

## The AutomationPoint objects, created on the first do() and reused for every redo.
var points: Array = []


func _init(p_name: String = "Add Point", p_lane: Object = null, p_specs: Array = []) -> void:
	name = p_name
	lane = p_lane
	specs = p_specs


## Create the points (first call) or re-insert the same objects (redo).
func do() -> void:
	if lane == null:
		return
	if points.is_empty():
		for spec in specs:
			var point: Object = lane.add_point(
				spec.get("tick", 0),
				spec.get("value", 0.0),
				spec.get("curve", AutomationPoint.CurveType.LINEAR),
				spec.get("tension", 0.0)
			)
			points.append(point)
	else:
		for point in points:
			lane._insert_sorted(point)
			lane._send_point("add_point", point)
			lane.point_added.emit(point)


## Remove every point added by this command.
func undo() -> void:
	if lane == null:
		return
	for point in points:
		lane.remove_point(point.id)
