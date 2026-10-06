# test_timeline_erase_drag.gd
# Headless tests for the arranger right-drag erase gesture's arming rule: because Node._input()
# runs before Control._gui_input(), an automation lane row cannot block the erase press by
# consuming it in _gui_input, so Timeline must exclude lane rows when arming. Regression: a
# right-click on an automation lane point used to arm an erase drag.
#
# Timeline references autoloads by bare name, so it is loaded with instantiate() inside
# run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_timeline_erase_drag.gd -- --test
extends TestBase

const ERASE_SETTING := "arranger/right_drag_erase"

var _timeline_scene: PackedScene
var _track_script: GDScript
var _lane_script: GDScript
var _grid_script: GDScript


func suite_name() -> String:
	return "Timeline erase drag tests"


func run_tests() -> void:
	_timeline_scene = load("res://arranger/timeline/Timeline.tscn")
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_grid_script = load("res://components/GridHelper.gd")

	var sonara: Node = root.get_node("/root/Sonara")
	var previous = sonara.get_config(ERASE_SETTING, false)
	sonara.set_config(ERASE_SETTING, true)
	await _test_lane_rows_do_not_arm()
	await _test_empty_timeline_arms()
	sonara.set_config(ERASE_SETTING, previous)


## A timeline in the tree with one `channel/volume` lane row, returning the row's global rect
## and the global position of its single point.
func _make_timeline_with_lane() -> Dictionary:
	var timeline: Control = _timeline_scene.instantiate()
	var gh: Object = _grid_script.new()
	gh.pixels_per_beat = 64.0
	timeline.grid_helper = gh
	root.add_child(timeline)
	timeline.size = Vector2(800, 400)

	var track: Object = _track_script.new(1)
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	lane.height = 60
	lane.add_point(960, 0.5)
	var row: Control = timeline._ensure_lane_row(track, lane)
	# Let the VBox place the row before reading its rect.
	await process_frame
	await process_frame

	var point: Object = lane.points[0]
	var point_global: Vector2 = row.get_global_transform() * Vector2(
		row.tick_to_x(point.tick), row.value_to_y(point.value))
	return {"timeline": timeline, "row": row, "rect": row.get_global_rect(), "point": point_global}


func _right_press(timeline: Object, global_pos: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_RIGHT
	e.pressed = true
	e.position = global_pos
	e.global_position = global_pos
	timeline._input(e)


func _test_lane_rows_do_not_arm() -> void:
	var f := await _make_timeline_with_lane()
	var timeline: Object = f.timeline
	var rect: Rect2 = f.rect

	_right_press(timeline, f.point)
	_assert(not timeline._erase_pressed,
		"right-press on an automation lane point does not arm the erase drag")
	_assert(rect.has_point(f.point), "the point really is inside the lane row")

	# Empty lane space is the lane's own gesture too (it clears the point selection).
	var empty := Vector2(rect.position.x + 4.0, rect.position.y + 4.0)
	_right_press(timeline, empty)
	_assert(not timeline._erase_pressed,
		"right-press on empty lane space does not arm the erase drag")

	timeline.free()


func _test_empty_timeline_arms() -> void:
	var f := await _make_timeline_with_lane()
	var timeline: Object = f.timeline
	var rect: Rect2 = f.rect

	# Below the lane row, still inside the timeline: the erase gesture must still start.
	var below := Vector2(rect.position.x + 4.0, rect.end.y + 40.0)
	_assert(timeline.get_global_rect().has_point(below), "the probe point is inside the timeline")
	# The gesture only arms while the pointer hovers the timeline; headless has no hover.
	timeline.pointer_over_override = true
	_right_press(timeline, below)
	_assert(timeline._erase_pressed,
		"right-press outside every lane row still arms the erase drag")

	timeline.free()
