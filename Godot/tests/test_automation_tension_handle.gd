# test_automation_tension_handle.gd
# Headless tests for the segment-midpoint tension handle on automation lane rows.
#
# Run: godot --headless --path Godot -s tests/test_automation_tension_handle.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Automation tension handle"


func run_tests() -> void:
	_test_drag_bends_curve_through_cursor()
	_test_near_linear_snaps_to_zero()
	_test_no_handle_on_flat_or_step_segment()
	_test_double_click_resets()
	_test_handle_shows_over_segment()
	_test_alt_drag_bends_both_sides()


func _make_row(curve := AutomationPoint.CurveType.LINEAR, v1 := 1.0) -> Dictionary:
	var timeline: Object = load("res://arranger/timeline/Timeline.gd").new()
	var gh: Object = load("res://components/GridHelper.gd").new()
	gh.pixels_per_beat = 64.0
	timeline.grid_helper = gh
	var track: Object = load("res://data/Track.gd").new(1)
	var lane: Object = load("res://data/AutomationLane.gd").new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	lane.add_point(0, 0.0, curve)
	lane.add_point(1920, v1)
	var row: Control = load("res://arranger/timeline/AutomationLaneRow.gd").new()
	root.add_child(row)
	row.size = Vector2(800, 105)
	row.bind_to_lane(lane, track, timeline)
	return {"row": row, "lane": lane, "timeline": timeline}


func _free(f: Dictionary) -> void:
	f.row.queue_free()
	f.timeline.free()


func _click(row: Control, pos: Vector2, pressed: bool, double := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.double_click = double
	e.position = pos
	row._gui_input(e)


func _motion(row: Control, pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	row._gui_input(e)


func _mid(f: Dictionary) -> Vector2:
	return f.row._handle_centre(f.lane.points[0])


func _test_drag_bends_curve_through_cursor() -> void:
	var f := _make_row()
	var start := _mid(f)
	_assert(not is_nan(start.x), "a linear sloped segment has a handle")
	_click(f.row, start, true)
	var target := Vector2(start.x, f.row.value_to_y(0.25))
	_motion(f.row, target)
	var l: Object = f.lane.points[0]
	var r: Object = f.lane.points[1]
	var mid_value: float = AutomationCurve.evaluate(l, r, 960)
	_assert(absf(mid_value - 0.25) < 0.01, "midpoint follows the cursor (%f)" % mid_value)
	_assert(l.tension > 0.0, "pulling the midpoint down is positive tension (%f)" % l.tension)
	_assert(l.tick == 0 and l.value == 0.0, "bending leaves tick and value alone")
	f.row._tension_before.clear()
	_click(f.row, target, false)
	_assert(f.row._tension_drag_id == -1, "release ends the drag")
	_free(f)


func _test_near_linear_snaps_to_zero() -> void:
	var f := _make_row()
	var start := _mid(f)
	_click(f.row, start, true)
	_motion(f.row, start + Vector2(0, -1))
	_assert(f.lane.points[0].tension == 0.0, "a tiny nudge snaps back to straight")
	f.row._tension_before.clear()
	_click(f.row, start, false)
	_free(f)


func _test_no_handle_on_flat_or_step_segment() -> void:
	var flat := _make_row(AutomationPoint.CurveType.LINEAR, 0.0)
	_assert(is_nan(_mid(flat).x), "flat segment has no handle")
	_free(flat)
	var step := _make_row(AutomationPoint.CurveType.STEP)
	_assert(is_nan(_mid(step).x), "step segment has no handle")
	_free(step)


func _test_double_click_resets() -> void:
	var f := _make_row()
	f.lane.update_point(f.lane.points[0].id, 0, 0.0, -1, 0.6)
	var at := _mid(f)
	_click(f.row, at, true, true)
	_assert(f.lane.points.size() == 2, "double-click on a handle doesn't insert a point")
	_free(f)


func _test_handle_shows_over_segment() -> void:
	var f := _make_row()
	var mid := _mid(f)
	_motion(f.row, Vector2(mid.x - 20.0, 3.0))
	_assert(f.row._hover_handle_id == f.lane.points[0].id, "handle shows with the cursor anywhere over the segment")
	_motion(f.row, Vector2(f.row.tick_to_x(1920) + 40.0, 3.0))
	_assert(f.row._hover_handle_id == -1, "handle hides outside the segment")
	_free(f)


func _alt_click(row: Control, pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.alt_pressed = true
	e.position = pos
	row._gui_input(e)


func _test_alt_drag_bends_both_sides() -> void:
	var f := _make_row()
	f.lane.add_point(3840, 0.0)  # peak in the middle: rises, then falls
	f.row.size = Vector2(1000, 105)
	var peak: Object = f.lane.points[1]
	var at := Vector2(f.row.tick_to_x(peak.tick), f.row.value_to_y(peak.value))
	_alt_click(f.row, at, true)
	_assert(f.row._bend_point_id == peak.id, "alt-press on a point starts a bend")
	_motion(f.row, at + Vector2(0, -20.0))
	var a: Object = f.lane.points[0]
	var b: Object = f.lane.points[1]
	var c: Object = f.lane.points[2]
	var up_a: float = AutomationCurve.evaluate(a, b, 960)
	var up_b: float = AutomationCurve.evaluate(b, c, 2880)
	_assert(up_a > 0.5, "rising segment's middle moves up (%f)" % up_a)
	_assert(up_b > 0.5, "falling segment's middle moves up too (%f)" % up_b)
	_assert(b.value == 1.0 and b.tick == 1920, "bending leaves the point where it is")
	f.row._bend_before.clear()
	_alt_click(f.row, at, false)
	_free(f)
