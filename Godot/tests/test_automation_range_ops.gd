# test_automation_range_ops.gd
# Headless tests for the range-aware automation cut/copy/paste/duplicate (T-025, REQ-021):
# the operand picked from range vs selection, the clipboard payload and its tick offsets, a
# 1-bar segment pasted at bar 3 landing at shifted ticks with curves intact and overwriting
# what sits under it, undo restoring, and the anchor/tick priority rules.
#
# Undo is exercised through a local CommandHistory driving the same commands
# AutomationActions.paste_segment batches (HistoryUtil has no editor history in test mode).
#
# Run: godot --headless --path Godot -s tests/test_automation_range_ops.gd -- --test
extends TestBase

const BAR: int = 3840  # 4 beats * 960 PPQ

var _track_script: GDScript
var _lane_script: GDScript
var _history_script: GDScript
var _actions_script: GDScript
var _manager_script: GDScript
var _points_add_cmd: GDScript
var _points_remove_cmd: GDScript
var _macro_cmd: GDScript


func suite_name() -> String:
	return "Automation range operations tests"


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_actions_script = load("res://history/AutomationActions.gd")
	_manager_script = load("res://arranger/timeline/AutomationPointSelectionManager.gd")
	_points_add_cmd = load("res://history/commands/AutomationPointsAddCommand.gd")
	_points_remove_cmd = load("res://history/commands/AutomationPointsRemoveCommand.gd")
	_macro_cmd = load("res://history/commands/MacroCommand.gd")
	_test_range_operand_beats_selection()
	_test_selection_operand_uses_bounds()
	_test_copy_holds_offsets_and_curves()
	_test_paste_one_bar_at_bar_three()
	_test_paste_overwrites_inside_span()
	_test_clear_range_half_open()
	_test_paste_and_duplicate_tick_priority()


func _make_lane() -> Object:
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	_track_script.new(1).add_automation_lane(lane)
	return lane


func _point_at(lane: Object, tick: int) -> Object:
	for p in lane.points:
		if p.tick == tick:
			return p
	return null


func _test_range_operand_beats_selection() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.1)
	lane.add_point(480, 0.2)
	lane.add_point(BAR, 0.3)
	var manager: Object = _manager_script.new()
	manager.lane = lane
	manager.select_ids(lane, [lane.points[0].id])
	manager.set_range(0, BAR)
	var operand: Dictionary = manager.get_operand()
	_assert(operand["origin"] == 0, "range origin is the range start")
	_assert(operand["points"].size() == 2, "range operand takes points inside [start, end): %d" % operand["points"].size())


func _test_selection_operand_uses_bounds() -> void:
	var lane := _make_lane()
	lane.add_point(100, 0.1)
	lane.add_point(500, 0.2)
	lane.add_point(900, 0.3)
	var manager: Object = _manager_script.new()
	manager.lane = lane
	manager.select_ids(lane, [lane.points[0].id, lane.points[2].id])
	var operand: Dictionary = manager.get_operand()
	_assert(operand["origin"] == 100, "selection origin is the first selected tick")
	_assert(operand["points"].size() == 2, "selection operand takes only the selected points")
	_assert(operand["length"] == 800, "selection length spans to the last selected tick")


func _test_copy_holds_offsets_and_curves() -> void:
	var lane := _make_lane()
	lane.add_point(960, 0.25, AutomationPoint.CurveType.STEP, 0.4)
	lane.add_point(2880, 0.75, AutomationPoint.CurveType.LINEAR, 0.0)
	var manager: Object = _manager_script.new()
	manager.lane = lane
	manager.set_range(0, BAR)
	_assert(manager.copy(), "copy of a non-empty range succeeds")
	_assert(manager.clipboard_length() == BAR, "clipboard length is the range length")
	var entries: Array = manager.clipboard["points"]
	_assert(entries.size() == 2, "both in-range points copied")
	_assert(int(entries[0]["tick_offset"]) == 960, "first entry offset from the range origin")
	_assert(int(entries[1]["curve"]) == AutomationPoint.CurveType.LINEAR, "curve travels with the copy")
	_assert(is_equal_approx(float(entries[0]["tension"]), 0.4), "tension travels with the copy")


## A 1-bar segment copied at bar 1 and pasted at bar 3 lands at shifted ticks with curves
## intact; undo (the remove+add batch paste_segment builds) restores the lane exactly.
func _test_paste_one_bar_at_bar_three() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.1, AutomationPoint.CurveType.LINEAR)
	lane.add_point(1920, 0.9, AutomationPoint.CurveType.STEP, 0.5)
	lane.add_point(BAR - 480, 0.4)
	var manager: Object = _manager_script.new()
	manager.lane = lane
	manager.set_range(0, BAR)
	manager.copy()

	var specs: Array = manager.clipboard_specs_at(2 * BAR)
	_assert(specs.size() == 3, "paste plans all three points")
	_assert(int(specs[0]["tick"]) == 2 * BAR, "first point lands on the paste tick")
	_assert(int(specs[1]["tick"]) == 2 * BAR + 1920, "middle point keeps its offset: %d" % int(specs[1]["tick"]))
	_assert(int(specs[2]["tick"]) == 3 * BAR - 480, "last point keeps its offset")

	var hist: Object = _history_script.new()
	var pasted := _paste_through_history(hist, lane, specs, "Paste Points")
	_assert(pasted.size() == 3, "paste creates three points")
	_assert(lane.points.size() == 6, "paste kept the originals: %d" % lane.points.size())
	var moved: Object = _point_at(lane, 2 * BAR + 1920)
	_assert(moved != null, "pasted point exists at the shifted tick")
	_assert(moved.curve == AutomationPoint.CurveType.STEP, "pasted point keeps its STEP curve")
	_assert(is_equal_approx(moved.tension, 0.5), "pasted point keeps its tension")
	_assert(is_equal_approx(moved.value, 0.9), "pasted point keeps its value")

	hist.undo()
	_assert(lane.points.size() == 3, "undo restores the pre-paste lane: %d" % lane.points.size())
	_assert(_point_at(lane, 2 * BAR) == null, "undo removes the pasted points")
	hist.redo()
	_assert(lane.points.size() == 6, "redo reapplies the paste")


## Points already sitting inside the pasted span are replaced, not doubled (REQ-021).
func _test_paste_overwrites_inside_span() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.5)
	var manager: Object = _manager_script.new()
	manager.lane = lane
	manager.set_range(0, BAR)
	manager.copy()

	lane.add_point(2 * BAR, 0.0)  # sits exactly on the paste tick
	var hist: Object = _history_script.new()
	_paste_through_history(hist, lane, manager.clipboard_specs_at(2 * BAR), "Paste Points")
	_assert(lane.points.size() == 2, "paste overwrote the colliding point: %d" % lane.points.size())
	hist.undo()
	_assert(lane.points.size() == 2 and is_equal_approx(_point_at(lane, 2 * BAR).value, 0.0),
		"undo restores the overwritten point")


func _test_clear_range_half_open() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.1)
	lane.add_point(BAR - 1, 0.2)
	lane.add_point(BAR, 0.3)
	var removed: int = _actions_script.clear_range(lane, 0, BAR)
	_assert(removed == 2, "clear removes [start, end): %d" % removed)
	_assert(lane.points.size() == 1 and lane.points[0].tick == BAR, "point on the end tick survives")


func _test_paste_and_duplicate_tick_priority() -> void:
	var lane := _make_lane()
	lane.add_point(100, 0.1)
	lane.add_point(500, 0.9)
	var manager: Object = _manager_script.new()
	manager.lane = lane
	_assert(manager.get_paste_tick(77) == 77, "no anchor pastes at the fallback (playhead)")
	manager.set_anchor(960)
	_assert(manager.get_paste_tick(77) == 960, "clicked tick beats the playhead")
	manager.set_range(BAR, 2 * BAR)
	_assert(manager.get_paste_tick(77) == BAR, "visible range start beats the clicked tick")
	_assert(manager.get_duplicate_tick(0) == 2 * BAR, "duplicate lands after the range")
	manager.hide_range()
	manager.select_ids(lane, [lane.points[0].id, lane.points[1].id])
	_assert(manager.get_duplicate_tick(0) == 500, "duplicate after the range uses the selection end")


## Drive the same remove+add batch `AutomationActions.paste_segment` builds through a real
## history so undo/redo can be exercised headlessly.
func _paste_through_history(hist: Object, lane: Object, specs: Array, label: String) -> Array:
	var start_tick: int = specs[0]["tick"]
	var end_tick: int = start_tick
	for spec in specs:
		start_tick = mini(start_tick, int(spec["tick"]))
		end_tick = maxi(end_tick, int(spec["tick"]))
	var doomed: Array = []
	for point in lane.points:
		if point.tick >= start_tick and point.tick <= end_tick:
			doomed.append(point)
	var add_cmd: Object = _points_add_cmd.new(label, lane, specs)
	var cmds: Array = []
	if not doomed.is_empty():
		cmds.append(_points_remove_cmd.new(label, lane, doomed))
	cmds.append(add_cmd)
	if cmds.size() == 1:
		hist.execute(cmds[0])
	else:
		hist.execute(_macro_cmd.new(label, cmds))
	return add_cmd.points