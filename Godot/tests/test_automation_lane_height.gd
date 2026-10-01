# test_automation_lane_height.gd
# An automation lane row is two nodes: `AutomationLaneHeader` (tracklist) and `AutomationLaneRow`
# (timeline), both sized from `AutomationLane.height`. The data object only knows a 20 px minimum,
# but the header's label and buttons need more, so a 20 px height used to leave the timeline row
# shorter than its header. The header must push its content floor into `lane.height`.
#
# Run: godot --headless --path Godot -s tests/test_automation_lane_height.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Automation lane height clamp"


func run_tests() -> void:
	var lane_script: GDScript = load("res://data/AutomationLane.gd")
	var header_script: GDScript = load("res://arranger/tracklist/AutomationLaneHeader.gd")
	var row_script: GDScript = load("res://arranger/timeline/AutomationLaneRow.gd")

	var lane: Object = lane_script.new("l1", null)
	lane.height = 40

	var root := Control.new()
	root.size = Vector2(800, 600)
	get_root().add_child(root)

	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 320
	root.add_child(column)

	var header: Control = header_script.new()
	column.add_child(header)

	var row: Control = row_script.new()
	row.custom_minimum_size.x = 320
	root.add_child(row)

	await process_frame
	header.bind_to_lane(lane, null, null)
	row.bind_to_lane(lane, null, null)
	await process_frame
	await process_frame

	_assert(int(header.size.y) == lane.height, "header fills the lane height (header=%d lane=%d)" % [int(header.size.y), lane.height])
	_assert(int(row.custom_minimum_size.y) == lane.height, "lane row starts at the lane height")

	# `AutomationLane.set_height`'s floor is 20, below what the header's label and buttons need.
	lane.set_height(20)
	await process_frame
	await process_frame

	var floor: int = lane.height
	_assert(floor > 20, "header pushes its content floor into the model (height=%d)" % floor)
	_assert(int(header.size.y) == floor, "header still fills the lane height (header=%d)" % int(header.size.y))
	_assert(int(row.custom_minimum_size.y) == floor, "timeline lane row is as tall as its header (row=%d header=%d)" % [int(row.custom_minimum_size.y), int(header.size.y)])

	root.queue_free()
