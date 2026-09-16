# AutomationPointsRemoveCommand.gd
# Undoable removal of one or more automation points as a single history entry. Keeps the exact
# AutomationPoint objects (with their original ids) so undo re-inserts the very same points -
# see AutomationPointsAddCommand for why id stability matters.
class_name AutomationPointsRemoveCommand extends Command

## Lane the points are removed from / restored to.
var lane: Object = null

## The AutomationPoint objects being removed, captured before the first do().
var points: Array = []


func _init(p_name: String = "Delete Point", p_lane: Object = null, p_points: Array = []) -> void:
	name = p_name
	lane = p_lane
	# Snapshot the array (not the points themselves - we want the same objects back on undo).
	points = p_points.duplicate()


## Remove every captured point.
func do() -> void:
	if lane == null:
		return
	for point in points:
		lane.remove_point(point.id)


## Re-insert every captured point at its original sorted position, preserving its id.
func undo() -> void:
	if lane == null:
		return
	for point in points:
		lane._insert_sorted(point)
		lane._send_point("add_point", point)
		lane.point_added.emit(point)
