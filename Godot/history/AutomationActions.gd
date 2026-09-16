# AutomationActions.gd
# Undoable automation lane/point edits shared by the arranger, mirroring ClipActions /
# ClipRangeActions. Every edit here is routed through HistoryUtil so it lands as one history
# entry (REQ-022), even when it covers several points.
#
# The command scripts are referenced through load() rather than by class_name: a brand-new
# class_name script isn't resolvable as a bare identifier until Godot has rebuilt
# .godot/global_script_class_cache.cfg (a full editor/project run), so a fresh headless test that
# only loads this file would otherwise fail to parse it. load() sidesteps that entirely.
class_name AutomationActions extends RefCounted

const _LaneCreateCommand := preload("res://history/commands/AutomationLaneCreateCommand.gd")
const _LaneDeleteCommand := preload("res://history/commands/AutomationLaneDeleteCommand.gd")
const _PointsAddCommand := preload("res://history/commands/AutomationPointsAddCommand.gd")
const _PointsRemoveCommand := preload("res://history/commands/AutomationPointsRemoveCommand.gd")
const _PointsTransformCommand := preload("res://history/commands/AutomationPointsTransformCommand.gd")


## Create `lane` on `track` as one "Create Lane" step. `lane` is not yet attached to the track.
static func create_lane(track: Object, lane: Object) -> void:
	if track == null or lane == null:
		return
	var cmd: Object = _LaneCreateCommand.new("Create Lane", track, lane)
	HistoryUtil.execute(cmd)


## Delete `lane` from `track` as one "Delete Lane" step; undo restores the lane and every point.
static func delete_lane(track: Object, lane: Object) -> void:
	if track == null or lane == null:
		return
	var cmd: Object = _LaneDeleteCommand.new("Delete Lane", track, lane)
	HistoryUtil.execute(cmd)


## Add one point to `lane` as one "Add Point" step. Returns the created point, or null if `lane`
## is null.
static func add_point(
	lane: Object,
	tick: int,
	value: float,
	curve: int = AutomationPoint.CurveType.LINEAR,
	tension: float = 0.0
) -> Object:
	var points: Array = add_points(lane, [{"tick": tick, "value": value, "curve": curve, "tension": tension}])
	return points[0] if not points.is_empty() else null


## Add several points to `lane` as a single "Add Points" step. Returns the created points, in
## the same order as `specs`.
static func add_points(lane: Object, specs: Array) -> Array:
	if lane == null or specs.is_empty():
		return []
	var label := "Add Point" if specs.size() == 1 else "Add Points"
	var cmd: Object = _PointsAddCommand.new(label, lane, specs)
	HistoryUtil.execute(cmd)
	return cmd.points


## Delete `points` (AutomationPoint objects) from `lane` as one "Delete Point(s)" step.
static func delete_points(lane: Object, points: Array) -> void:
	if lane == null or points.is_empty():
		return
	var label := "Delete Point" if points.size() == 1 else "Delete Points"
	var cmd: Object = _PointsRemoveCommand.new(label, lane, points)
	HistoryUtil.execute(cmd)


## Move/reshape `points` (already applied to their new tick/value/curve/tension) as one step.
## `before` is a Dictionary of point id -> {tick, value, curve, tension} captured before the
## gesture started; `points`' CURRENT fields are read as the after-state. Pass `mergeable = true`
## for a continuous drag so consecutive calls with the same point set coalesce into one entry.
##
## IMPORTANT: `AutomationLane.update_point()` never mutates a point in place - each call replaces
## it with a new AutomationPoint object carrying the same id (see AutomationLane.gd). Callers must
## therefore re-fetch each point from `lane.points` by id right before calling `move_points` (or
## `capture_point_states`), never hold onto the object returned by an earlier `update_point` call.
static func move_points(
	lane: Object,
	points: Array,
	before: Dictionary,
	mergeable: bool = true,
	label: String = "Move Point"
) -> void:
	if lane == null or points.is_empty():
		return
	var ids: Array = []
	var after: Dictionary = {}
	for point in points:
		ids.append(point.id)
		after[point.id] = {
			"tick": point.tick,
			"value": point.value,
			"curve": point.curve,
			"tension": point.tension,
		}
	if points.size() > 1 and label == "Move Point":
		label = "Move Points"
	var cmd: Object = _PointsTransformCommand.new(label, lane, ids, before, after)
	cmd.set_mergeable(mergeable)
	# The gesture already mutated `points` in place (e.g. a live drag preview); record it rather
	# than re-applying via do().
	HistoryUtil.record(cmd)


## Capture the current tick/value/curve/tension of `points`, keyed by id. Pass the result as
## `before` to `move_points` once the gesture is finished.
static func capture_point_states(points: Array) -> Dictionary:
	var states: Dictionary = {}
	for point in points:
		states[point.id] = {
			"tick": point.tick,
			"value": point.value,
			"curve": point.curve,
			"tension": point.tension,
		}
	return states


## Set the curve shape (and optionally tension) of `points` as one non-mergeable step.
static func set_curve(lane: Object, points: Array, curve: int, tension: float = NAN) -> void:
	if lane == null or points.is_empty():
		return
	var ids: Array = []
	var before: Dictionary = {}
	var after: Dictionary = {}
	for point in points:
		ids.append(point.id)
		var old_tension: float = point.tension
		var new_tension: float = old_tension if is_nan(tension) else tension
		before[point.id] = {
			"tick": point.tick,
			"value": point.value,
			"curve": point.curve,
			"tension": old_tension,
		}
		after[point.id] = {
			"tick": point.tick,
			"value": point.value,
			"curve": curve,
			"tension": new_tension,
		}
	var label := "Set Curve" if points.size() == 1 else "Set Curves"
	var cmd: Object = _PointsTransformCommand.new(label, lane, ids, before, after)
	HistoryUtil.execute(cmd)


# ============================================================================
# RANGE OPERATIONS (REQ-021)
# ============================================================================
# The range/selection conventions mirror ClipRangeActions: a paste lands its first point on the
# target tick, and cut/clear removes everything inside the half-open range [start, end).

## Remove every point of `lane` inside the half-open tick range as one "Clear Range" step.
## Returns how many points were removed.
static func clear_range(lane: Object, start_tick: int, end_tick: int, label: String = "Clear Range") -> int:
	if lane == null or end_tick <= start_tick:
		return 0
	var doomed: Array = []
	for point in lane.points:
		if point.tick >= start_tick and point.tick < end_tick:
			doomed.append(point)
	if doomed.is_empty():
		return 0
	var cmd: Object = _PointsRemoveCommand.new(label, lane, doomed)
	HistoryUtil.execute(cmd)
	return doomed.size()


## Paste `specs` (from `AutomationPointSelectionManager.clipboard_specs_at`) into `lane` as one
## step, first clearing whatever already sits in the span they cover so a paste overwrites rather
## than interleaving - the same thing pasting a clip over another does.
##
## Returns the created points.
static func paste_segment(lane: Object, specs: Array, label: String = "Paste Points") -> Array:
	if lane == null or specs.is_empty():
		return []

	var start_tick: int = specs[0]["tick"]
	var end_tick: int = start_tick
	for spec in specs:
		start_tick = mini(start_tick, int(spec["tick"]))
		end_tick = maxi(end_tick, int(spec["tick"]))

	# One undo step for the whole paste: the overwrite and the insert go into one MacroCommand.
	# end_tick + 1 so a point sitting exactly on the last pasted tick is replaced, not doubled.
	var doomed: Array = []
	for point in lane.points:
		if point.tick >= start_tick and point.tick <= end_tick:
			doomed.append(point)

	var add_cmd: Object = _PointsAddCommand.new(label, lane, specs)
	var cmds: Array[Command] = []
	if not doomed.is_empty():
		cmds.append(_PointsRemoveCommand.new(label, lane, doomed))
	cmds.append(add_cmd)
	HistoryUtil.execute_many(label, cmds)
	return add_cmd.points
