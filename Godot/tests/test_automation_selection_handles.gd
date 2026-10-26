# test_automation_selection_handles.gd
# Headless tests for the tilt-left / tilt-right / compress selection handles on AutomationLaneRow
# (spec 055 REQ-015, REQ-018, REQ-019). The maths is covered by test_value_lane_edits.gd.
#
# Run: godot --headless --path Godot -s tests/test_automation_selection_handles.gd -- --test
extends TestBase

# AutomationLaneRow.SelectionHandle values; the row's class_name can't be named here because the
# script would then compile before the autoloads exist.
const HANDLE_NONE := 0
const TILT_LEFT := 1
const TILT_RIGHT := 2
const COMPRESS := 3

var _recorded: Array = []


func suite_name() -> String:
	return "Automation selection handles"


func run_tests() -> void:
	_test_rects_need_two_points()
	_test_tilt_then_undo()
	_test_compress_commits_once()
	_test_point_wins_over_handle()


func _util() -> GDScript:
	return load("res://history/HistoryUtil.gd")


func _make_row(values: Array) -> Dictionary:
	var timeline: Object = load("res://arranger/timeline/Timeline.gd").new()
	var gh: Object = load("res://components/GridHelper.gd").new()
	gh.pixels_per_beat = 64.0
	timeline.grid_helper = gh
	var track: Object = load("res://data/Track.gd").new(1)
	var lane: Object = load("res://data/AutomationLane.gd").new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	for i in values.size():
		lane.add_point((i + 1) * 960, values[i])
	var row: Control = load("res://arranger/timeline/AutomationLaneRow.gd").new()
	root.add_child(row)
	row.size = Vector2(800, 105)
	row.bind_to_lane(lane, track, timeline)
	return {"row": row, "lane": lane, "timeline": timeline}


func _free(f: Dictionary) -> void:
	f.row.queue_free()
	f.timeline.free()


func _select_all(f: Dictionary) -> void:
	var ids: Array = []
	for p in f.lane.points:
		ids.append(p.id)
	f.row.selection_manager.select_ids(f.lane, ids)


func _click(row: Control, pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	row._gui_input(e)


func _motion(row: Control, pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	row._gui_input(e)


func _values(lane: Object) -> Array:
	var out: Array = []
	for p in lane.points:
		out.append(p.value)
	return out


func _test_rects_need_two_points() -> void:
	var f := _make_row([0.3, 0.5, 0.7])
	var row: Control = f.row
	row.selection_manager.select_only(f.lane, f.lane.points[0].id)
	_assert(row._selection_handle_rects().is_empty(), "1 selected point shows no handles")
	_select_all(f)
	var rects: Dictionary = row._selection_handle_rects()
	_assert(rects.size() == 3, "2+ selected points show 3 handles")
	var left: Rect2 = rects[TILT_LEFT]
	var right: Rect2 = rects[TILT_RIGHT]
	_assert(left.get_center().x < row.tick_to_x(960) + 0.5, "tilt left sits at the selection's left edge")
	_assert(right.get_center().x > row.tick_to_x(1920 + 960) - 0.5, "tilt right sits at the selection's right edge")
	_free(f)


func _test_tilt_then_undo() -> void:
	var f := _make_row([0.3, 0.3, 0.3])
	var row: Control = f.row
	_select_all(f)
	_recorded.clear()
	_util().test_recorder = func(cmd: Object) -> void: _recorded.append(cmd)
	var rect: Rect2 = row._selection_handle_rects()[TILT_RIGHT]
	var start := rect.get_center()
	_click(row, start, true)
	_motion(row, start + Vector2(0, -20))
	_motion(row, start + Vector2(0, -40))
	var v := _values(f.lane)
	_assert(is_equal_approx(v[0], 0.3), "the far end does not move")
	_assert(v[1] > 0.3 and v[2] > v[1], "points ramp towards the dragged end (%s)" % [v])
	_click(row, start + Vector2(0, -40), false)
	_assert(_recorded.size() == 1, "one history entry for the drag (%d)" % _recorded.size())
	if _recorded.size() == 1:
		_recorded[0].undo()
		v = _values(f.lane)
		_assert(is_equal_approx(v[0], 0.3) and is_equal_approx(v[1], 0.3) and is_equal_approx(v[2], 0.3),
				"undo restores all values")
	_util().test_recorder = Callable()
	_free(f)


func _test_compress_commits_once() -> void:
	var f := _make_row([0.2, 0.8])
	var row: Control = f.row
	_select_all(f)
	_recorded.clear()
	_util().test_recorder = func(cmd: Object) -> void: _recorded.append(cmd)
	var start: Vector2 = (row._selection_handle_rects()[COMPRESS] as Rect2).get_center()
	_click(row, start, true)
	_motion(row, start + Vector2(0, 26))
	var v := _values(f.lane)
	_assert(v[1] - v[0] < 0.6 - 0.01, "dragging down compresses (%s)" % [v])
	_click(row, start + Vector2(0, 26), false)
	_assert(_recorded.size() == 1, "one history entry for compress")
	# A press that never moves records nothing.
	_recorded.clear()
	start = (row._selection_handle_rects()[COMPRESS] as Rect2).get_center()
	_click(row, start, true)
	_click(row, start, false)
	_assert(_recorded.is_empty(), "an unmoved handle press records nothing")
	_util().test_recorder = Callable()
	_free(f)


func _test_point_wins_over_handle() -> void:
	# Points at the top of the lane push the tilt handles against the lane's edge, so the
	# tilt-left rect overlaps the first point's hit circle.
	var f := _make_row([1.0, 1.0])
	var row: Control = f.row
	_select_all(f)
	var rect: Rect2 = row._selection_handle_rects()[TILT_LEFT]
	var press := Vector2(row.tick_to_x(960) - 5.0, row.value_to_y(1.0))
	_assert(rect.grow(2.0).has_point(press), "the press lies inside the handle rect")
	_assert(row._point_at(press) != null, "the press also lies on the point")
	_click(row, press, true)
	_assert(row._sel_handle == HANDLE_NONE, "a press on a point does not start a handle")
	_assert(row._drag_pending, "a press on a selected point starts a point drag")
	_click(row, press, false)
	_free(f)
