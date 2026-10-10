# test_automation_point_insert.gd
# Headless tests for the double-click insert (the new point lands on the lane's own value at the
# click position - interpolated between the surrounding points, or the flat hold value - so the
# insert never changes what the lane plays; it only starts following the cursor once the held
# drag passes DRAG_THRESHOLD) and for the point context menu's "Set to Previous/Next Point
# Value" entries and their undo.
#
# The synthetic events here cover the gesture logic; the real cursor feel (where the threshold
# ends, popup placement, keyboard focus) still needs a manual check in the editor.
#
# Run: godot --headless --path Godot -s tests/test_automation_point_insert.gd -- --test
extends TestBase

var _row_script: GDScript
var _track_script: GDScript
var _lane_script: GDScript
var _timeline_script: GDScript
var _grid_script: GDScript
var _actions_script: GDScript
var _history_script: GDScript
var _menu_script: GDScript
var _history_util_script: GDScript


func suite_name() -> String:
	return "Automation point insert and neighbor-value tests"


func run_tests() -> void:
	_row_script = load("res://arranger/timeline/AutomationLaneRow.gd")
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	_grid_script = load("res://components/GridHelper.gd")
	_actions_script = load("res://history/AutomationActions.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_menu_script = load("res://arranger/timeline/AutomationPointContextMenu.gd")
	_history_util_script = load("res://history/HistoryUtil.gd")
	_test_insert_value_helpers()
	_test_double_click_insert_keeps_value_until_threshold()
	_test_insert_before_first_and_after_last()
	_test_insert_into_empty_lane_falls_back_to_cursor()
	_test_menu_entries_and_availability()
	_test_set_prev_value_applies_and_undoes()
	_test_set_prev_multi_selection_no_cascade()
	_test_set_next_and_missing_neighbour()


func _make_lane() -> Object:
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	_track_script.new(1).add_automation_lane(lane)
	return lane


func _make_row() -> Dictionary:
	var timeline: Object = _timeline_script.new()
	var gh: Object = _grid_script.new()
	gh.pixels_per_beat = 64.0
	timeline.grid_helper = gh
	var track: Object = _track_script.new(1)
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	var row: Control = _row_script.new()
	root.add_child(row)
	row.size = Vector2(800, 40)
	row.bind_to_lane(lane, track, timeline)
	return {"row": row, "lane": lane, "timeline": timeline}


func _free_row(f: Dictionary) -> void:
	f.row.queue_free()
	f.timeline.free()


func _double_click(row: Control, pos: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.double_click = true
	e.position = pos
	row._gui_input(e)


func _release(row: Control, pos: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = false
	e.position = pos
	row._gui_input(e)


func _motion(row: Control, pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	row._gui_input(e)


## x pixel for `tick` on a row built by _make_row (64 px per beat at 960 PPQ).
func _x(tick: int) -> float:
	return float(tick) / 960.0 * 64.0


func _point_by_id(lane: Object, point_id: int) -> Object:
	for p in lane.points:
		if p.id == point_id:
			return p
	return null


# ---------------------------------------------------------------------------
# insert value
# ---------------------------------------------------------------------------

func _test_insert_value_helpers() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.2)
	lane.add_point(960, 0.8)
	_assert(is_equal_approx(_actions_script.insert_value_at(lane, 480), 0.5),
		"insert between two points takes the interpolated value")
	_assert(is_equal_approx(_actions_script.insert_value_at(lane, 0), 0.2),
		"insert on the first point takes its value")
	_assert(is_equal_approx(_actions_script.insert_value_at(lane, 960), 0.8),
		"insert on the last point takes its value")
	_assert(is_equal_approx(_actions_script.insert_value_at(lane, 4800), 0.8),
		"insert after the last point takes the flat hold value")
	_assert(is_equal_approx(_actions_script.insert_value_at(lane, -50), 0.2),
		"insert before the first point takes the flat hold value")

	var step_lane := _make_lane()
	step_lane.add_point(0, 0.2, AutomationPoint.CurveType.STEP)
	step_lane.add_point(960, 0.8)
	_assert(is_equal_approx(_actions_script.insert_value_at(step_lane, 480), 0.2),
		"insert into a STEP segment takes the held left value")

	var empty := _make_lane()
	_assert(is_nan(_actions_script.insert_value_at(empty, 480)),
		"an empty lane has no insert value")


func _test_double_click_insert_keeps_value_until_threshold() -> void:
	var f := _make_row()
	var lane: Object = f.lane
	lane.add_point(0, 0.2)
	lane.add_point(960, 0.8)

	var recorded: Array = []
	_history_util_script.test_recorder = func(cmd) -> void: recorded.append(cmd)

	# Halfway between the points (tick 480 -> x 128); far below the curve's value there (0.5),
	# so the old insert-at-cursor behaviour would show up as a value change.
	var pos := Vector2(_x(480), 35.0)
	_double_click(f.row, pos)
	_assert(lane.points.size() == 3, "double-click on empty space inserts a point")
	var inserted: Object = lane.points[1]
	_assert(inserted.tick == 480, "insert lands on the snapped tick: %d" % inserted.tick)
	_assert(is_equal_approx(inserted.value, 0.5), "insert takes the lane's value there, not the cursor's: %f" % inserted.value)

	_motion(f.row, pos + Vector2(1.0, 0.0))
	_assert(is_equal_approx(_point_by_id(lane, inserted.id).value, 0.5),
		"moving under the drag threshold leaves the value alone")

	_motion(f.row, Vector2(_x(480) + 12.0, 10.0))
	var live := _point_by_id(lane, inserted.id)
	_assert(is_equal_approx(live.value, f.row.y_to_value(10.0)),
		"past the threshold the point follows the cursor: %f vs %f" % [live.value, f.row.y_to_value(10.0)])

	_release(f.row, Vector2(_x(480) + 12.0, 10.0))
	live = _point_by_id(lane, inserted.id)
	_assert(is_equal_approx(live.value, f.row.y_to_value(10.0)), "release keeps the dragged value")

	# Undo through the same commands the gesture pushed: first the drag, then the insert.
	var hist: Object = _history_script.new()
	for cmd in recorded:
		hist.record(cmd)
	_assert(hist.undo_count() == 2, "insert + drag is two history entries: %d" % hist.undo_count())
	hist.undo()
	live = _point_by_id(lane, inserted.id)
	_assert(live != null and is_equal_approx(live.value, 0.5) and live.tick == 480,
		"undoing the drag restores the inaudible insert value")
	hist.undo()
	_assert(lane.points.size() == 2, "undoing again removes the inserted point")

	_history_util_script.test_recorder = Callable()
	_free_row(f)


func _test_insert_before_first_and_after_last() -> void:
	var f := _make_row()
	var lane: Object = f.lane
	lane.add_point(960, 0.5)

	_double_click(f.row, Vector2(_x(480), 35.0))
	_assert(lane.points.size() == 2 and is_equal_approx(lane.points[0].value, 0.5),
		"insert before the first point takes the flat hold value")
	_release(f.row, Vector2(_x(480), 35.0))

	_double_click(f.row, Vector2(_x(1920), 35.0))
	_assert(lane.points.size() == 3 and is_equal_approx(lane.points[2].value, 0.5),
		"insert after the last point takes the flat hold value")
	_release(f.row, Vector2(_x(1920), 35.0))
	_free_row(f)


func _test_insert_into_empty_lane_falls_back_to_cursor() -> void:
	var f := _make_row()
	var pos := Vector2(_x(480), 35.0)
	_double_click(f.row, pos)
	_assert(f.lane.points.size() == 1, "insert into an empty lane adds the point")
	_assert(is_equal_approx(f.lane.points[0].value, f.row.y_to_value(pos.y)),
		"an empty lane has no value to take, so the cursor's is used")
	_release(f.row, pos)
	_free_row(f)


# ---------------------------------------------------------------------------
# point context menu: set to previous/next point value
# ---------------------------------------------------------------------------

func _make_menu() -> Object:
	var menu: Object = _menu_script.new()
	root.add_child(menu)
	return menu


func _item(menu: Object, id: int) -> int:
	return menu.get_item_index(id)


func _texts(menu: Object) -> Array:
	var out: Array = []
	for i in range(menu.get_item_count()):
		out.append(menu.get_item_text(i))
	return out


func _test_menu_entries_and_availability() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.2)
	lane.add_point(480, 0.5)
	lane.add_point(960, 0.8)
	var a: Object = lane.points[0]
	var b: Object = lane.points[1]
	var c: Object = lane.points[2]

	_assert(_actions_script.neighbor_value_available(lane, [b], false), "a middle point has a previous")
	_assert(_actions_script.neighbor_value_available(lane, [b], true), "a middle point has a next")
	_assert(not _actions_script.neighbor_value_available(lane, [a], false), "the first point has no previous")
	_assert(not _actions_script.neighbor_value_available(lane, [c], true), "the last point has no next")
	_assert(_actions_script.neighbor_value_available(lane, [a], true), "the first point has a next")

	var menu := _make_menu()
	menu.open_for([b], Vector2.ZERO,
		_actions_script.neighbor_value_available(lane, [b], false),
		_actions_script.neighbor_value_available(lane, [b], true))
	var texts := _texts(menu)
	_assert("Set to Previous Point Value" in texts and "Set to Next Point Value" in texts,
		"the menu offers both neighbour-value entries: %s" % str(texts))
	_assert(not menu.is_item_disabled(_item(menu, menu.ID_SET_PREV)), "prev entry enabled for a middle point")
	_assert(not menu.is_item_disabled(_item(menu, menu.ID_SET_NEXT)), "next entry enabled for a middle point")

	menu.open_for([a], Vector2.ZERO,
		_actions_script.neighbor_value_available(lane, [a], false),
		_actions_script.neighbor_value_available(lane, [a], true))
	_assert(menu.is_item_disabled(_item(menu, menu.ID_SET_PREV)), "prev entry disabled for the first point")
	_assert(not menu.is_item_disabled(_item(menu, menu.ID_SET_NEXT)), "next entry enabled for the first point")

	var seen: Array = []
	menu.neighbor_value_requested.connect(func(points: Array, next: bool) -> void: seen.append([points, next]))
	menu._on_id_pressed(menu.ID_SET_PREV)
	_assert(seen.size() == 1 and seen[0][1] == false and seen[0][0] == [a],
		"picking the prev entry reports the bound points")
	menu._on_id_pressed(menu.ID_SET_NEXT)
	_assert(seen.size() == 2 and seen[1][1] == true, "picking the next entry reports next=true")
	menu.free()


func _test_set_prev_value_applies_and_undoes() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.2)
	lane.add_point(480, 0.5)
	lane.add_point(960, 0.8)
	var b: Object = lane.points[1]

	var recorded: Array = []
	_history_util_script.test_recorder = func(cmd) -> void: recorded.append(cmd)

	_actions_script.set_points_to_neighbor_value(lane, [b], false)
	var after: Object = _point_by_id(lane, b.id)
	_assert(after != null and is_equal_approx(after.value, 0.2), "set-to-previous copies the previous value")
	_assert(after.tick == 480 and after.curve == b.curve, "only the value changes")

	var hist: Object = _history_script.new()
	for cmd in recorded:
		hist.record(cmd)
	hist.undo()
	after = _point_by_id(lane, b.id)
	_assert(after != null and is_equal_approx(after.value, 0.5), "undo restores the point's value")
	hist.redo()
	after = _point_by_id(lane, b.id)
	_assert(after != null and is_equal_approx(after.value, 0.2), "redo re-applies the neighbour value")

	_history_util_script.test_recorder = Callable()


func _test_set_prev_multi_selection_no_cascade() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.2)
	lane.add_point(480, 0.5)
	lane.add_point(960, 0.8)
	var b: Object = lane.points[1]
	var c: Object = lane.points[2]

	var recorded: Array = []
	_history_util_script.test_recorder = func(cmd) -> void: recorded.append(cmd)

	# b and c selected: c's neighbour is b, whose own value is also being retargeted - the
	# neighbour values are read before anything is written, so c takes b's ORIGINAL value.
	_actions_script.set_points_to_neighbor_value(lane, [b, c], false)
	_assert(is_equal_approx(_point_by_id(lane, b.id).value, 0.2), "selected point takes its previous value")
	_assert(is_equal_approx(_point_by_id(lane, c.id).value, 0.5),
		"the neighbour value is read before the writes, so no cascade")

	var hist: Object = _history_script.new()
	for cmd in recorded:
		hist.record(cmd)
	_assert(hist.undo_count() == 1, "a multi-point neighbour set is one undo entry: %d" % hist.undo_count())
	hist.undo()
	_assert(is_equal_approx(_point_by_id(lane, b.id).value, 0.5)
		and is_equal_approx(_point_by_id(lane, c.id).value, 0.8), "undo restores both points")

	_history_util_script.test_recorder = Callable()


func _test_set_next_and_missing_neighbour() -> void:
	var lane := _make_lane()
	lane.add_point(0, 0.2)
	lane.add_point(960, 0.8)
	var a: Object = lane.points[0]

	var recorded: Array = []
	_history_util_script.test_recorder = func(cmd) -> void: recorded.append(cmd)

	_actions_script.set_points_to_neighbor_value(lane, [a], true)
	_assert(is_equal_approx(_point_by_id(lane, a.id).value, 0.8), "set-to-next copies the next value")
	_actions_script.set_points_to_neighbor_value(lane, [lane.points[1]], true)
	_assert(recorded.size() == 1, "a point with no next is a no-op, no history entry")
	_actions_script.set_points_to_neighbor_value(lane, [], false)
	_assert(recorded.size() == 1, "an empty selection is a no-op")

	var hist: Object = _history_script.new()
	for cmd in recorded:
		hist.record(cmd)
	hist.undo()
	_assert(is_equal_approx(_point_by_id(lane, a.id).value, 0.2), "undo restores the set-to-next")

	_history_util_script.test_recorder = Callable()
