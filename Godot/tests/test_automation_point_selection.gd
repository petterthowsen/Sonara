# test_automation_point_selection.gd
# Headless tests for AutomationPointSelectionManager's selection rules (REQ-020, REQ-021): the
# shift-box toggle set, direct selection edits dropping the time range, lane focus surviving a
# cleared selection so paste still has a target, and `release()` handing the shortcuts back to
# the clips.
#
# Run: godot --headless --path Godot -s tests/test_automation_point_selection.gd -- --test
extends TestBase

const BAR: int = 3840  # 4 beats * 960 PPQ

var _track_script: GDScript
var _lane_script: GDScript
var _manager_script: GDScript


func suite_name() -> String:
	return "Automation point selection tests"


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_manager_script = load("res://arranger/timeline/AutomationPointSelectionManager.gd")
	_test_select_toggled_flips_ids()
	_test_selection_edits_drop_range()
	_test_focus_survives_clear()
	_test_release_drops_everything()
	_test_forget_lane_drops_focus()


func _make_lane() -> Object:
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	_track_script.new(1).add_automation_lane(lane)
	lane.add_point(0, 0.1)
	lane.add_point(480, 0.2)
	lane.add_point(BAR, 0.3)
	return lane


func _ids(lane: Object) -> Array:
	var ids: Array = []
	for p in lane.points:
		ids.append(p.id)
	return ids


func _test_select_toggled_flips_ids() -> void:
	var lane := _make_lane()
	var ids := _ids(lane)
	var manager: Object = _manager_script.new()
	manager.select_toggled(lane, [ids[0], ids[1]], [ids[1], ids[2]])
	var selected: Array = manager.get_selected_ids()
	_assert(selected == [ids[0], ids[2]], "shift-box keeps the base, drops covered selected, adds covered unselected")
	manager.select_toggled(lane, [ids[0]], [])
	_assert(manager.get_selected_ids() == [ids[0]], "an empty shift-box leaves the base selection")


func _test_selection_edits_drop_range() -> void:
	var lane := _make_lane()
	var ids := _ids(lane)
	var manager: Object = _manager_script.new()

	manager.select_ids(lane, [ids[0], ids[1]])
	manager.set_range(0, BAR)
	manager.select_only(lane, ids[2])
	_assert(manager.get_full_range() == Vector2i.ZERO, "select_only drops the range")
	_assert(manager.get_operand()["points"].size() == 1, "operand is the clicked point, not the old range")

	manager.select_ids(lane, [ids[0]])
	manager.set_range(0, BAR)
	manager.toggle(lane, ids[2])
	_assert(manager.get_full_range() == Vector2i.ZERO, "toggle drops the range")

	manager.select_ids(lane, [])
	manager.set_range(0, BAR)
	_assert(manager.get_full_range() == Vector2i(0, BAR), "set_range after select_ids keeps the range")
	_assert(manager.lane == lane, "an empty range selection still scopes the lane")


func _test_focus_survives_clear() -> void:
	var lane := _make_lane()
	var manager: Object = _manager_script.new()
	manager.select_only(lane, _ids(lane)[0])
	manager.clear_selection()
	_assert(manager.lane == null, "clear drops the selection lane")
	_assert(manager.get_target_lane() == lane, "paste still targets the last focused lane")

	var fresh: Object = _manager_script.new()
	fresh.focus(lane)
	_assert(fresh.get_target_lane() == lane, "a press on empty space focuses the lane")


func _test_release_drops_everything() -> void:
	var lane := _make_lane()
	var manager: Object = _manager_script.new()
	manager.select_ids(lane, _ids(lane))
	manager.set_range(0, BAR)
	manager.release()
	_assert(not manager.has_selection(), "release clears the selection")
	_assert(manager.get_full_range() == Vector2i.ZERO, "release clears the range")
	_assert(manager.get_target_lane() == null, "release drops the lane focus")
	_assert(manager.anchor_tick == -1, "release drops the anchor")


func _test_forget_lane_drops_focus() -> void:
	var lane := _make_lane()
	var manager: Object = _manager_script.new()
	manager.focus(lane)
	manager.forget_lane(lane)
	_assert(manager.get_target_lane() == null, "a deleted lane is no longer a paste target")
