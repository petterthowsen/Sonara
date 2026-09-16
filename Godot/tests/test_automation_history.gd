# test_automation_history.gd
# Headless tests for the automation undo/redo commands (T-016, T-017): lane create/delete,
# point add/remove with id stability across undo/redo, and a multi-point transform that merges a
# continuous drag into one undo step. Modeled on test_command_history.gd and test_markers.gd.
#
# AutomationLane / Track reference the AudioEngineOSC autoload, which isn't resolvable as a bare
# identifier until scripts are loaded via load() rather than referenced by static class name (see
# test_markers.gd / test_automation_model.gd) - autoloads aren't singletons yet at compile time.
#
# Run: godot --headless --path Godot -s tests/test_automation_history.gd -- --test
extends TestBase

var _lane_script: GDScript
var _track_script: GDScript
var _history_script: GDScript
var _actions_script: GDScript
var _lane_create_cmd: GDScript
var _lane_delete_cmd: GDScript
var _points_add_cmd: GDScript
var _points_remove_cmd: GDScript
var _points_transform_cmd: GDScript


func suite_name() -> String:
	return "Automation history tests"


func run_tests() -> void:
	_lane_script = load("res://data/AutomationLane.gd")
	_track_script = load("res://data/Track.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_actions_script = load("res://history/AutomationActions.gd")
	_lane_create_cmd = load("res://history/commands/AutomationLaneCreateCommand.gd")
	_lane_delete_cmd = load("res://history/commands/AutomationLaneDeleteCommand.gd")
	_points_add_cmd = load("res://history/commands/AutomationPointsAddCommand.gd")
	_points_remove_cmd = load("res://history/commands/AutomationPointsRemoveCommand.gd")
	_points_transform_cmd = load("res://history/commands/AutomationPointsTransformCommand.gd")
	_test_lane_create_undo_redo()
	_test_lane_delete_restores_points_on_undo()
	_test_lane_create_then_delete_undo_twice()
	_test_add_points_id_stable_across_redo()
	_test_remove_points_id_stable_across_undo()
	_test_transform_merges_continuous_drag()
	_test_transform_restores_curve_and_tension()


func _make_track() -> Object:
	return _track_script.new(1)


func _make_lane(_track: Object, id: String = "lane1") -> Object:
	var lane: Object = _lane_script.new(id, AutomationTarget.channel_volume())
	return lane


func _test_lane_create_undo_redo() -> void:
	var track := _make_track()
	var lane := _make_lane(track)
	var hist: Object = _history_script.new()
	var cmd: Object = _lane_create_cmd.new("Create Lane", track, lane)
	hist.execute(cmd)
	_assert(track.automation_lanes.has(lane), "create attaches lane")
	_assert(lane.track == track, "create sets lane.track")
	hist.undo()
	_assert(not track.automation_lanes.has(lane), "undo detaches lane")
	_assert(lane.track == null, "undo clears lane.track")
	hist.redo()
	_assert(track.automation_lanes.has(lane), "redo re-attaches lane")


func _test_lane_delete_restores_points_on_undo() -> void:
	var track := _make_track()
	var lane := _make_lane(track)
	lane.add_point(0, 0.2)
	lane.add_point(960, 0.8)
	track.add_automation_lane(lane)
	var hist: Object = _history_script.new()
	var cmd: Object = _lane_delete_cmd.new("Delete Lane", track, lane)
	hist.execute(cmd)
	_assert(not track.automation_lanes.has(lane), "delete detaches lane")
	hist.undo()
	_assert(track.automation_lanes.has(lane), "undo re-attaches lane")
	_assert(lane.points.size() == 2, "undo keeps every point: %d" % lane.points.size())
	_assert(lane.points[0].tick == 0 and lane.points[1].tick == 960, "undo keeps point ticks")


func _test_lane_create_then_delete_undo_twice() -> void:
	var track := _make_track()
	var lane := _make_lane(track)
	lane.add_point(0, 0.1)
	lane.add_point(480, 0.5)
	var hist: Object = _history_script.new()
	hist.execute(_lane_create_cmd.new("Create Lane", track, lane))
	_assert(track.automation_lanes.has(lane), "lane created")
	hist.execute(_lane_delete_cmd.new("Delete Lane", track, lane))
	_assert(not track.automation_lanes.has(lane), "lane deleted")
	hist.undo()  # undoes the delete
	_assert(track.automation_lanes.has(lane), "undo #1 restores lane")
	_assert(lane.points.size() == 2, "undo #1 restores points")
	hist.undo()  # undoes the create
	_assert(not track.automation_lanes.has(lane), "undo #2 removes lane again")


func _test_add_points_id_stable_across_redo() -> void:
	var track := _make_track()
	var lane := _make_lane(track)
	track.add_automation_lane(lane)
	var hist: Object = _history_script.new()
	var specs := [
		{"tick": 0, "value": 0.1, "curve": AutomationPoint.CurveType.LINEAR, "tension": 0.0},
		{"tick": 480, "value": 0.9, "curve": AutomationPoint.CurveType.STEP, "tension": 0.0},
	]
	var cmd: Object = _points_add_cmd.new("Add Points", lane, specs)
	hist.execute(cmd)
	_assert(lane.points.size() == 2, "add creates both points")
	var first_id: int = cmd.points[0].id
	var second_id: int = cmd.points[1].id
	_assert(first_id != second_id, "points get distinct ids")
	hist.undo()
	_assert(lane.points.is_empty(), "undo removes both points")
	hist.redo()
	_assert(lane.points.size() == 2, "redo re-adds both points")
	_assert(lane.points[0].id == first_id, "redo keeps the first point's id: %d vs %d" % [lane.points[0].id, first_id])
	_assert(lane.points[1].id == second_id, "redo keeps the second point's id: %d vs %d" % [lane.points[1].id, second_id])
	_assert(lane.points[1].curve == AutomationPoint.CurveType.STEP, "redo keeps STEP curve")


func _test_remove_points_id_stable_across_undo() -> void:
	var track := _make_track()
	var lane := _make_lane(track)
	var p1: Object = lane.add_point(0, 0.2)
	var p2: Object = lane.add_point(480, 0.6, AutomationPoint.CurveType.STEP)
	track.add_automation_lane(lane)
	var id1: int = p1.id
	var id2: int = p2.id
	var hist: Object = _history_script.new()
	var cmd: Object = _points_remove_cmd.new("Delete Points", lane, [p1, p2])
	hist.execute(cmd)
	_assert(lane.points.is_empty(), "remove empties the lane")
	hist.undo()
	_assert(lane.points.size() == 2, "undo restores both points")
	_assert(lane.points[0].id == id1 and lane.points[1].id == id2, "undo keeps original ids")
	_assert(lane.points[1].curve == AutomationPoint.CurveType.STEP, "undo keeps STEP curve")
	hist.redo()
	_assert(lane.points.is_empty(), "redo removes them again")


## AutomationLane.update_point() never mutates a point in place - it removes the old object and
## inserts a brand-new AutomationPoint with the same id (see AutomationLane.gd). Any code driving
## a multi-step gesture (like a drag) must therefore re-fetch each point from `lane.points` by id
## after every update rather than holding onto the object it started with.
func _point_by_id(lane: Object, point_id: int) -> Object:
	for p in lane.points:
		if p.id == point_id:
			return p
	return null


func _test_transform_merges_continuous_drag() -> void:
	var track := _make_track()
	var lane := _make_lane(track)
	var ids: Array = []
	for i in range(5):
		ids.append(lane.add_point(i * 100, 0.1 * i).id)
	track.add_automation_lane(lane)

	var start_points: Array = ids.map(func(id): return _point_by_id(lane, id))
	var before: Dictionary = _actions_script.capture_point_states(start_points)
	var hist: Object = _history_script.new()

	# Simulate a drag: three incremental steps, each shifting every point +50 ticks / +0.05
	# value, recorded as separate gestures the way a per-frame drag callback would.
	for step in range(3):
		for id in ids:
			var p: Object = _point_by_id(lane, id)
			lane.update_point(id, p.tick + 50, p.value + 0.05)
		var after: Dictionary = {}
		for id in ids:
			var p: Object = _point_by_id(lane, id)
			after[id] = {"tick": p.tick, "value": p.value, "curve": p.curve, "tension": p.tension}
		var cmd: Object = _points_transform_cmd.new("Move Points", lane, ids, before, after)
		cmd.set_mergeable(true)
		hist.record(cmd)

	_assert(hist.undo_count() == 1, "continuous drag coalesces into one undo entry: %d" % hist.undo_count())

	var expected_ticks: Array = []
	var expected_values: Array = []
	for i in range(5):
		expected_ticks.append(i * 100)
		expected_values.append(0.1 * i)

	hist.undo()
	for i in range(5):
		var p: Object = _point_by_id(lane, ids[i])
		_assert(p.tick == expected_ticks[i], "undo restores original tick %d: got %d" % [expected_ticks[i], p.tick])
		_assert(is_equal_approx(p.value, expected_values[i]), "undo restores original value %f: got %f" % [expected_values[i], p.value])

	hist.redo()
	for i in range(5):
		var p: Object = _point_by_id(lane, ids[i])
		_assert(p.tick == expected_ticks[i] + 150, "redo reapplies final tick: got %d" % p.tick)


func _test_transform_restores_curve_and_tension() -> void:
	var track := _make_track()
	var lane := _make_lane(track)
	var point_id: int = lane.add_point(0, 0.5, AutomationPoint.CurveType.STEP, 0.3).id
	track.add_automation_lane(lane)

	var start: Object = _point_by_id(lane, point_id)
	var before := {point_id: {"tick": start.tick, "value": start.value, "curve": start.curve, "tension": start.tension}}
	# Move only tick/value (as a plain drag would), but the command must still carry the
	# original curve/tension explicitly so update_point never falls back to its sentinels.
	lane.update_point(point_id, 200, 0.7, start.curve, start.tension)
	var moved: Object = _point_by_id(lane, point_id)
	var after := {point_id: {"tick": moved.tick, "value": moved.value, "curve": moved.curve, "tension": moved.tension}}
	var cmd: Object = _points_transform_cmd.new("Move Point", lane, [point_id], before, after)
	var hist: Object = _history_script.new()
	hist.record(cmd)

	_assert(_point_by_id(lane, point_id).curve == AutomationPoint.CurveType.STEP, "move keeps STEP curve")
	_assert(_point_by_id(lane, point_id).tick == 200, "move applies new tick")
	hist.undo()
	_assert(_point_by_id(lane, point_id).tick == 0, "undo restores tick")
	_assert(_point_by_id(lane, point_id).curve == AutomationPoint.CurveType.STEP, "undo restores STEP curve explicitly")
	_assert(is_equal_approx(_point_by_id(lane, point_id).tension, 0.3), "undo restores tension explicitly")
	hist.redo()
	_assert(_point_by_id(lane, point_id).tick == 200, "redo reapplies moved tick")
