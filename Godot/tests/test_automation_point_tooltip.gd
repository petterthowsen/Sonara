# test_automation_point_tooltip.gd
# Headless tests for the automation lane row's value tooltip (REQ-013): hovering a point shows
# its value formatted like the target's own control (`-6.0 dB`), a drag keeps the readout visible
# and live, and leaving the point hides it. Drives the real `_gui_input`, like test_envelope_control.
#
# Run: godot --headless --path Godot -s tests/test_automation_point_tooltip.gd -- --test
extends TestBase

var _row_script: GDScript
var _track_script: GDScript
var _lane_script: GDScript
var _timeline_script: GDScript
var _grid_script: GDScript


func suite_name() -> String:
	return "Automation point tooltip"


func run_tests() -> void:
	_row_script = load("res://arranger/timeline/AutomationLaneRow.gd")
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	_grid_script = load("res://components/GridHelper.gd")
	_test_hover_shows_value()
	_test_drag_shows_live_value()
	_test_hover_clears()


## A lane row bound to a `channel/volume` lane with one point at -6.0 dB, on a 40 px row.
func _make_row() -> Dictionary:
	var timeline: Object = _timeline_script.new()
	var gh: Object = _grid_script.new()
	gh.pixels_per_beat = 64.0
	timeline.grid_helper = gh

	var track: Object = _track_script.new(1)
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	lane.add_point(960, AutomationTarget.db_to_normalized(-6.0))

	var row: Control = _row_script.new()
	root.add_child(row)
	row.size = Vector2(800, 40)
	row.bind_to_lane(lane, track, timeline)
	return {"row": row, "lane": lane, "track": track, "timeline": timeline}


func _free(f: Dictionary) -> void:
	f.row.queue_free()
	f.timeline.free()


func _tip(row: Control) -> ValueTooltip:
	return row.get_child(-1, true) as ValueTooltip


func _point_at(row: Control, point: Object) -> Vector2:
	return Vector2(row.tick_to_x(point.tick), row.value_to_y(point.value))


func _motion(row: Control, pos: Vector2, relative := Vector2.ZERO) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.relative = relative
	row._gui_input(e)


func _button(row: Control, pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	row._gui_input(e)


func _test_hover_shows_value() -> void:
	var f := _make_row()
	var point: Object = f.lane.points[0]
	_assert(_tip(f.row) == null, "no readout exists until a point is hovered")

	_motion(f.row, _point_at(f.row, point))
	var tip := _tip(f.row)
	_assert(tip != null and tip.visible, "hovering a point shows the readout")
	_assert(tip._label.text == "-6.0 dB", "readout uses the target's own formatting (%s)" % tip._label.text)
	_free(f)


func _test_drag_shows_live_value() -> void:
	var f := _make_row()
	var point: Object = f.lane.points[0]
	var at := _point_at(f.row, point)
	var target := Vector2(at.x, f.row.value_to_y(0.5))

	_button(f.row, at, true)
	_motion(f.row, target, target - at)
	var tip := _tip(f.row)
	_assert(f.row._drag_active, "moving past the threshold starts the drag")
	_assert(is_equal_approx(f.lane.points[0].value, 0.5), "the drag moves the point to the cursor value")
	_assert(tip.visible and tip._label.text == "-24.0 dB", "readout follows the drag (%s)" % tip._label.text)

	# Skip the history commit: recording needs the live Editor node, which headless has none of.
	f.row._drag_before.clear()
	_button(f.row, target, false)
	_assert(not tip.visible, "readout hides when the drag ends")
	_free(f)


func _test_hover_clears() -> void:
	var f := _make_row()
	var point: Object = f.lane.points[0]
	_motion(f.row, _point_at(f.row, point))
	var tip := _tip(f.row)
	_assert(tip.visible, "readout shown over the point")
	_motion(f.row, _point_at(f.row, point) + Vector2(50.0, 0.0))
	_assert(not tip.visible, "readout hides when the pointer leaves the point")
	_free(f)
