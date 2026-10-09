# test_automation_value_entry.gd
# Headless tests for typed value entry on automation points (double-click) and Shift precision
# dragging, plus the target's text parsing.
#
# Run: godot --headless --path Godot -s tests/test_automation_value_entry.gd -- --test
extends TestBase

var _row_script: GDScript
var _track_script: GDScript
var _lane_script: GDScript
var _timeline_script: GDScript
var _grid_script: GDScript


func suite_name() -> String:
	return "Automation value entry"


func run_tests() -> void:
	_row_script = load("res://arranger/timeline/AutomationLaneRow.gd")
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	_grid_script = load("res://components/GridHelper.gd")
	_test_target_parsing()
	_test_double_click_opens_editor()
	_test_typed_value_commits()
	_test_bad_text_ignored()
	_test_shift_precision()


func _test_target_parsing() -> void:
	var vol := AutomationTarget.channel_volume()
	_assert(is_equal_approx(vol.parse_edit_text(null, "-6"), AutomationTarget.db_to_normalized(-6.0)), "volume parses dB")
	_assert(is_equal_approx(vol.parse_edit_text(null, "0 dB"), AutomationTarget.db_to_normalized(0.0)), "volume accepts dB suffix")
	_assert(is_nan(vol.parse_edit_text(null, "abc")), "volume rejects junk")
	var pan := AutomationTarget.channel_pan()
	_assert(is_equal_approx(pan.parse_edit_text(null, "L50"), 0.25), "pan parses L50")
	_assert(is_equal_approx(pan.parse_edit_text(null, "C"), 0.5), "pan parses C")
	_assert(is_equal_approx(pan.parse_edit_text(null, "100"), 1.0), "pan parses numeric percent")


func _make_row() -> Dictionary:
	var timeline: Object = _timeline_script.new()
	var gh: Object = _grid_script.new()
	gh.pixels_per_beat = 64.0
	timeline.grid_helper = gh
	var track: Object = _track_script.new(1)
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	lane.add_point(960, 0.5)
	var row: Control = _row_script.new()
	root.add_child(row)
	row.size = Vector2(800, 40)
	row.bind_to_lane(lane, track, timeline)
	return {"row": row, "lane": lane, "timeline": timeline}


func _free(f: Dictionary) -> void:
	f.row.queue_free()
	f.timeline.free()


func _point_pos(f: Dictionary) -> Vector2:
	var p: Object = f.lane.points[0]
	return Vector2(f.row.tick_to_x(p.tick), f.row.value_to_y(p.value))


func _click(row: Control, pos: Vector2, pressed: bool, double := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.double_click = double
	e.position = pos
	row._gui_input(e)


func _motion(row: Control, pos: Vector2, shift := false) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.shift_pressed = shift
	row._gui_input(e)


func _editor(row: Control) -> FloatingValueEditor:
	for c in row.get_children():
		if c is FloatingValueEditor:
			return c
	return null


func _test_double_click_opens_editor() -> void:
	var f := _make_row()
	var at := _point_pos(f)
	_click(f.row, at, true)
	_click(f.row, at, false)
	_click(f.row, at, true, true)
	_assert(f.lane.points.size() == 1, "double-click on a point doesn't add another")
	var ed := _editor(f.row)
	_assert(ed != null, "double-click on a point opens the value editor")
	_assert(ed != null and ed.text == "-24.0", "editor is prefilled with the dB value (%s)" % (ed.text if ed else ""))
	_free(f)


func _test_typed_value_commits() -> void:
	var f := _make_row()
	var id: int = f.lane.points[0].id
	f.row._commit_typed_value(id, "-6")
	_assert(is_equal_approx(f.lane.points[0].value, AutomationTarget.db_to_normalized(-6.0)), "typed -6 dB sets the point value")
	_assert(f.lane.points[0].tick == 960, "typing a value keeps the tick")
	_free(f)


func _test_bad_text_ignored() -> void:
	var f := _make_row()
	f.row._commit_typed_value(f.lane.points[0].id, "nope")
	_assert(is_equal_approx(f.lane.points[0].value, 0.5), "unparsable text leaves the value alone")
	_free(f)


func _test_shift_precision() -> void:
	var f := _make_row()
	var at := _point_pos(f)
	var span: float = f.row._value_span()
	_click(f.row, at, true)
	_motion(f.row, at + Vector2(0, -span * 0.2), true)
	_assert(is_equal_approx(f.lane.points[0].value, 0.5 + 0.2 * f.row.PRECISION_SCALE), "shift-drag moves value at precision scale (%f)" % f.lane.points[0].value)
	_motion(f.row, at + Vector2(0, -span * 0.2 - span * 0.1), false)
	_assert(is_equal_approx(f.lane.points[0].value, 0.5 + 0.02 + 0.1), "releasing shift mid-drag resumes full speed without a jump")
	f.row._drag_before.clear()
	_click(f.row, at, false)
	_free(f)
