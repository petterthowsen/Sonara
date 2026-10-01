# test_automation_lane_color.gd
# The automation lane row draws its curve and points in the owning track's color, and follows a
# track recolor. Regression guard: the color is read live from `track.color`, never captured when
# the lane is created (a snapshot left a recolored track's automation on its old color).
#
# Run: godot --headless --path Godot -s tests/test_automation_lane_color.gd -- --test
extends TestBase

var _row_script: GDScript
var _track_script: GDScript
var _lane_script: GDScript

const COLOR_A := Color(0.2, 0.4, 0.9)
const COLOR_B := Color(0.9, 0.3, 0.1)


func suite_name() -> String:
	return "Automation lane color"


func run_tests() -> void:
	_row_script = load("res://arranger/timeline/AutomationLaneRow.gd")
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_test_curve_uses_track_color()
	_test_curve_follows_recolor()
	_test_no_track_falls_back()


func _make_row(track_color: Color) -> Dictionary:
	var track: Object = _track_script.new(1)
	track.color_by_channel = false
	track.set_color(track_color)
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	lane.add_point(0, 0.5)

	var row: Control = _row_script.new()
	root.add_child(row)
	row.size = Vector2(400, 40)
	row.bind_to_lane(lane, track, null)
	return {"row": row, "lane": lane, "track": track}


func _test_curve_uses_track_color() -> void:
	var f := _make_row(COLOR_A)
	_assert(f.row.get_curve_color() == Utils.display_color(COLOR_A),
		"curve color is the track color, got %s" % f.row.get_curve_color())
	f.row.queue_free()


func _test_curve_follows_recolor() -> void:
	var f := _make_row(COLOR_A)
	f.track.set_color(COLOR_B)
	_assert(f.row.get_curve_color() == Utils.display_color(COLOR_B),
		"recoloring the track recolors the curve, got %s" % f.row.get_curve_color())
	_assert(f.row.get_curve_color() != Utils.display_color(COLOR_A), "curve no longer uses the old color")
	f.row.queue_free()


func _test_no_track_falls_back() -> void:
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	var row: Control = _row_script.new()
	root.add_child(row)
	row.bind_to_lane(lane, null, null)
	_assert(row.get_curve_color() == row.DEFAULT_CURVE_COLOR,
		"a row with no track uses the neutral fallback, got %s" % row.get_curve_color())
	row.queue_free()
