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


# ============================================================================
# "AUTOMATION FOLLOWS CLIPS" (REQ-025)
# ============================================================================
# Moving a clip instance shifts the lane points that sit under it by the same tick delta, so the
# automation travels with the clip. Points just outside the range must not move, so a point is
# created on each range edge that lacks one (value read from the lane at that tick, curve/tension
# inherited from the segment it splits). Those two live edits - create the anchors, then shift
# every point in the inclusive range - are returned as commands so the caller can fold them into
# the same history entry as the clip move.

## Shift every point of `lane` inside the inclusive range `[start_tick, end_tick]` by
## `delta_ticks`, first creating a point on either edge when the lane has none there. Mutates the
## lane live and returns the commands that recreate the gesture (an add for the new anchors plus a
## transform for every moved point), or `[]` when nothing changed.
##
## Returns `[]` for a lane with no point inside the range: there is nothing to follow.
static func shift_points_in_range(
	lane: Object,
	start_tick: int,
	end_tick: int,
	delta_ticks: int,
	label: String = "Move Automation"
) -> Array[Command]:
	if lane == null or delta_ticks == 0 or end_tick < start_tick:
		return []

	# Nothing under the range means the clip carries no automation: leave the lane alone rather
	# than inventing anchors for a segment that does not travel.
	var has_inside := false
	for point in lane.points:
		if point.tick >= start_tick and point.tick <= end_tick:
			has_inside = true
			break
	if not has_inside:
		return []

	var cmds: Array[Command] = []
	var add_cmd: Object = _PointsAddCommand.new(label, lane, [])

	# Anchors so the curve outside the range keeps its shape. A created anchor is pre-seeded into
	# the add command so a redo re-inserts the very same object (stable id), matching the command's
	# own first-do() behaviour.
	for tick: int in [start_tick, end_tick]:
		if _point_at_tick(lane, tick) != null:
			continue
		var spec := _boundary_spec(lane, tick)
		var point: Object = lane.add_point(
			spec["tick"], spec["value"], spec["curve"], spec["tension"]
		)
		add_cmd.points.append(point)

	if not add_cmd.points.is_empty():
		cmds.append(add_cmd)

	# Capture the before-state of everything on the (now anchor-inclusive) range, then shift it.
	var ids: Array = []
	var before: Dictionary = {}
	var after: Dictionary = {}
	for point in lane.points:
		if point.tick < start_tick or point.tick > end_tick:
			continue
		ids.append(point.id)
		before[point.id] = {
			"tick": point.tick,
			"value": point.value,
			"curve": point.curve,
			"tension": point.tension,
		}
		after[point.id] = {
			"tick": maxi(0, point.tick + delta_ticks),
			"value": point.value,
			"curve": point.curve,
			"tension": point.tension,
		}
	if ids.is_empty():
		# Only reachable when delta_ticks == 0, which is rejected above.
		return cmds

	for point_id in ids:
		var state: Dictionary = after[point_id]
		lane.update_point(point_id, state["tick"], state["value"], state["curve"], state["tension"])

	cmds.append(_PointsTransformCommand.new(label, lane, ids, before, after))
	return cmds


## Apply "automation follows clips" for a batch of clip moves that all share `delta_ticks`.
## `moves` is a list of `{track: Track, start: int, end: int}` describing each moved clip's range
## on its own track, before the move. Ranges that touch or overlap on a track are merged first, so
## a point on a shared edge between two clips that both move is shifted exactly once.
##
## Mutates the affected lanes live and returns the commands to record alongside the clip move.
static func shift_track_automation(
	moves: Array,
	delta_ticks: int,
	label: String = "Move Automation"
) -> Array[Command]:
	if moves.is_empty() or delta_ticks == 0:
		return []

	var ranges_by_track: Dictionary = {}
	for move in moves:
		var track: Object = move.get("track")
		if track == null:
			continue
		var ranges: Array = ranges_by_track.get(track, [])
		ranges.append([int(move["start"]), int(move["end"])])
		ranges_by_track[track] = ranges

	var cmds: Array[Command] = []
	for track in ranges_by_track:
		if track.automation_lanes.is_empty():
			continue
		var spans := _merge_ranges(ranges_by_track[track])
		for span in spans:
			for lane in track.automation_lanes:
				cmds.append_array(shift_points_in_range(lane, span[0], span[1], delta_ticks, label))
	return cmds


## Commands that copy the lane automation under clip ranges onto the same track at an offset, for
## duplicating clips with "automation follows clips" on. `copies` is a list of
## `{track: Track, start: int, end: int, delta: int}` (source range on its track, tick offset of
## the copy). Nothing is applied: the caller executes the returned commands in the same history
## entry as the clip creation. A range with no points under it carries no automation and is skipped.
static func copy_track_automation_commands(copies: Array, label: String = "Duplicate Automation") -> Array[Command]:
	var cmds: Array[Command] = []
	var groups: Dictionary = {}  # track -> {delta -> [[start, end], ...]}
	for copy in copies:
		var track: Object = copy.get("track")
		if track == null or track.automation_lanes.is_empty() or int(copy["delta"]) == 0:
			continue
		var by_delta: Dictionary = groups.get(track, {})
		var ranges: Array = by_delta.get(int(copy["delta"]), [])
		ranges.append([int(copy["start"]), int(copy["end"])])
		by_delta[int(copy["delta"])] = ranges
		groups[track] = by_delta

	for track in groups:
		for delta in groups[track]:
			for span in _merge_ranges(groups[track][delta]):
				for lane in track.automation_lanes:
					cmds.append_array(_copy_range_commands(lane, span[0], span[1], delta, label))
	return cmds


static func _copy_range_commands(lane: Object, start_tick: int, end_tick: int, delta: int, label: String) -> Array[Command]:
	var cmds: Array[Command] = []
	var has_inside := false
	for point in lane.points:
		if point.tick >= start_tick and point.tick <= end_tick:
			has_inside = true
			break
	if not has_inside:
		return cmds

	# Edge anchors (read from the lane, not added to it) keep the copy's shape at the clip bounds.
	var specs: Array = []
	for tick: int in [start_tick, end_tick]:
		if _point_at_tick(lane, tick) == null:
			specs.append(_boundary_spec(lane, tick))
	for point in lane.points:
		if point.tick >= start_tick and point.tick <= end_tick:
			specs.append({"tick": point.tick, "value": point.value, "curve": point.curve, "tension": point.tension})
	var dest_start := maxi(0, start_tick + delta)
	var dest_end := maxi(0, end_tick + delta)
	for spec in specs:
		spec["tick"] = maxi(0, int(spec["tick"]) + delta)

	var doomed: Array = []
	for point in lane.points:
		if point.tick >= dest_start and point.tick <= dest_end:
			doomed.append(point)
	if not doomed.is_empty():
		cmds.append(_PointsRemoveCommand.new(label, lane, doomed))
	cmds.append(_PointsAddCommand.new(label, lane, specs))
	return cmds


## The point of `lane` sitting exactly on `tick`, or null.
static func _point_at_tick(lane: Object, tick: int) -> Object:
	for point in lane.points:
		if point.tick == tick:
			return point
	return null


## Spec for a point created on a range edge: the lane's value there, with the curve and tension of
## the segment that edge splits (so a STEP segment stays a step and a tensioned ramp keeps its
## bend as closely as one extra point allows).
static func _boundary_spec(lane: Object, tick: int) -> Dictionary:
	var value: float = lane.get_value_at_tick(tick)
	if is_nan(value):
		value = 0.0
	var curve: int = AutomationPoint.CurveType.LINEAR
	var tension: float = 0.0
	for point in lane.points:
		if point.tick > tick:
			break
		curve = point.curve
		tension = point.tension
	return {"tick": tick, "value": value, "curve": curve, "tension": tension}


## Sort `[start, end]` ranges and merge the ones that touch or overlap.
static func _merge_ranges(ranges: Array) -> Array:
	var sorted_ranges := ranges.duplicate()
	sorted_ranges.sort_custom(func(a, b): return a[0] < b[0])
	var spans: Array = []
	for r in sorted_ranges:
		if spans.is_empty() or r[0] > spans[-1][1]:
			spans.append([r[0], r[1]])
		else:
			spans[-1][1] = maxi(spans[-1][1], r[1])
	return spans
