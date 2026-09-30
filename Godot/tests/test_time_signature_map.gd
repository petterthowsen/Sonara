# test_time_signature_map.gd
# Headless tests for TimeSignatureMap (parser, segments, bbt, edits, persistence, undo), the grid
# following it, and the arranger's time signature lane.
#
# Run: godot --headless --path Godot -s tests/test_time_signature_map.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"

var _project_script: GDScript
var _map_script: GDScript
var _command_script: GDScript
var _grid_script: GDScript


func suite_name() -> String:
	return "Time signature map"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_map_script = load("res://data/TimeSignatureMap.gd")
	_command_script = load("res://history/commands/TimeSignatureMapStateCommand.gd")
	_grid_script = load("res://components/GridHelper.gd")
	_test_parser()
	_test_segments_and_bbt()
	_test_update_stays_between_neighbours()
	_test_base_edit_keeps_bars()
	_test_json_and_legacy_project()
	_test_command_undo_redo()
	_test_grid_lines_and_snapping()
	_test_grid_empty_map_matches_base()
	await _test_arranger_lane()


func _map_with_7_8_at_bar_3():
	var map = _map_script.new()
	map.add_change(3, 7, 8)
	return map


func _test_parser() -> void:
	_assert(_map_script.parse("7/8") == Vector2i(7, 8), "7/8 parses")
	_assert(_map_script.parse(" 3 / 4 ") == Vector2i(3, 4), "whitespace is trimmed")
	for bad in ["0/4", "4/3", "4", "a/b", "33/4", "", "4/4/4", "4.5/4"]:
		_assert(_map_script.parse(bad) == Vector2i.ZERO, "'%s' is invalid" % bad)


func _test_segments_and_bbt() -> void:
	var map = _map_with_7_8_at_bar_3()
	_assert(map.tick_of_bar(3, 4, 4, 960) == 7680, "bar 3 starts at 7680")
	_assert(map.tick_of_bar(4, 4, 4, 960) == 11040, "bar 4 starts at 11040 (a 7/8 bar is 3360)")
	_assert(map.bar_at_tick(7679, 4, 4, 960) == 2, "tick 7679 is in bar 2")
	_assert(map.bar_at_tick(11040, 4, 4, 960) == 4, "tick 11040 is in bar 4")
	_assert(map.signature_at_tick(7680, 4, 4, 960) == Vector2i(7, 8), "7/8 from bar 3")
	var bbt = map.bbt_at_tick(7680 + 480, 4, 4, 960)
	_assert(bbt["bar"] == 3 and bbt["beat"] == 2, "7680 + 480 is bar 3 beat 2")
	_assert(_map_script.new().tick_of_bar(3, 4, 4, 960) == 7680, "empty map: base signature")
	_assert(_map_script.new().bbt_at_tick(1920, 4, 4, 960) == _grid_script.bbt_of(1920, 960, 4, 4),
		"empty map bbt equals the static one")


func _test_update_stays_between_neighbours() -> void:
	var map = _map_script.new()
	map.add_change(3, 3, 4)
	var b: int = map.add_change(5, 7, 8)
	map.add_change(8, 5, 4)
	map.update_change(b, 20, 7, 8)
	_assert(map.changes[1]["bar"] == 7, "moving past the next change stops just before it")
	map.update_change(b, 1, 7, 8)
	_assert(map.changes[1]["bar"] == 4, "moving before the previous change stops just after it")
	var fresh = _map_script.new()
	fresh.add_change(1, 2, 4)
	_assert(fresh.changes[0]["bar"] == 2, "bar 1 becomes bar 2")


func _test_base_edit_keeps_bars() -> void:
	var map = _map_with_7_8_at_bar_3()
	_assert(map.tick_of_bar(3, 3, 4, 960) == 5760, "base 3/4 puts bar 3 at 5760")
	_assert(map.changes[0]["bar"] == 3, "the change keeps its bar")


func _test_json_and_legacy_project() -> void:
	var project = _project_script.new()
	project.time_signature_map.add_change(3, 7, 8)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var loaded = _project_script.from_json(data)
	_assert(loaded.time_signature_map.changes.size() == 1, "project saves its time signature map")
	_assert(loaded.time_signature_map.changes[0]["denominator"] == 8, "signature survives a round trip")
	data.erase("time_signature_map")
	_assert(_project_script.from_json(data).time_signature_map.is_empty(),
		"legacy project loads an empty map")


func _test_command_undo_redo() -> void:
	var map = _map_script.new()
	var before = map.snapshot()
	map.add_change(3, 7, 8)
	var cmd = _command_script.new("Add", map, before, map.snapshot())
	cmd.undo()
	_assert(map.is_empty(), "undo removes the change")
	cmd.do()
	_assert(map.changes.size() == 1 and map.changes[0]["numerator"] == 7, "redo restores the change")


func _grid(map):
	var grid = _grid_script.new()
	grid.min_line_spacing = 10.0
	grid.pixels_per_beat = 100.0
	grid.time_signature_map = map
	return grid


func _test_grid_lines_and_snapping() -> void:
	var grid = _grid(_map_with_7_8_at_bar_3())
	var end_x = grid.ticks_to_pixels(12000)
	var bars := {}
	var beats_in_bar3: Array[int] = []
	for line in grid.get_visible_grid_lines(0.0, end_x):
		var tick = grid.pixels_to_ticks(line.x)
		if line.type == _grid_script.GridLineType.BAR:
			bars[line.bar_number] = tick
		elif line.type == _grid_script.GridLineType.BEAT and tick > 7680 and tick < 11040:
			beats_in_bar3.append(tick)
	_assert(bars.get(1) == 0 and bars.get(2) == 3840 and bars.get(3) == 7680 and bars.get(4) == 11040,
		"bar lines and numbers follow the change: %s" % str(bars))
	beats_in_bar3.sort()
	_assert(beats_in_bar3.size() == 6 and beats_in_bar3[1] - beats_in_bar3[0] == 480,
		"7/8 beat lines are 480 ticks apart")
	for tick in [7000, 7500, 7679]:
		_assert(grid.snap_ticks(tick) <= 7680, "snap of %d never passes bar 3" % tick)
	_assert(grid.snap_ticks(7680 + 490) == 7680 + 480, "snap after the change uses the 7/8 grid")
	_assert(grid.get_ticks_per_bar_at(8000) == 3360 and grid.get_ticks_per_bar_at(100) == 3840,
		"bar length is tick aware")
	_assert(grid.get_ticks_per_bar() == 3840, "base getter is unchanged")
	_assert(grid.ticks_to_bbt(11040)["bar"] == 4, "readout follows the map")


func _test_grid_empty_map_matches_base() -> void:
	var a = _grid(_map_script.new())
	var b = _grid(null)
	var end_x = a.ticks_to_pixels(10000)
	var la = a.get_visible_grid_lines(0.0, end_x)
	var lb = b.get_visible_grid_lines(0.0, end_x)
	_assert(la.size() == lb.size() and la.size() > 0, "grids agree on line count")
	var same := true
	for i in la.size():
		same = same and la[i].x == lb[i].x and la[i].type == lb[i].type and la[i].bar_number == lb[i].bar_number
	_assert(same, "empty map gives the same lines as no map")
	_assert(a.get_visible_grid_lines(0.0, end_x)[1].bar_number == 2 or a.get_visible_grid_lines(0.0, end_x)[0].bar_number == 1,
		"bar numbering starts at 1")
	_assert(a.snap_ticks(1000) == b.snap_ticks(1000), "snap unchanged with an empty map")


func _test_arranger_lane() -> void:
	var root := Control.new()
	root.size = Vector2(1200, 600)
	get_root().add_child(root)
	var arranger: Control = load(ARRANGER_SCENE).instantiate()
	var editor: Node = load("res://editor/Editor.gd").new()
	editor.arranger = arranger
	get_root().get_node("Sonara").editor = editor
	root.add_child(arranger)
	arranger.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	var project = _project_script.new()
	editor.project = project
	editor.project_activated.emit(project)
	await process_frame

	var lane = arranger.time_signature_track
	var header = lane.get_parent()
	_assert(header.get_child(lane.get_index() - 1).name == "Ruler" and header.get_child(lane.get_index() + 1).name == "TempoTrack",
		"lane sits between Ruler and TempoTrack")
	_assert(not lane.visible, "lane starts hidden")
	arranger.time_signature_toggle.button_pressed = true
	_assert(lane.visible and project.ruler_lanes["time_signature"] == true, "toggle shows the lane and is stored")
	arranger.time_signature_toggle.button_pressed = false
	_assert(not lane.visible, "toggle hides the lane")

	var id = lane.add_change_at_bar(5)
	await process_frame
	_assert(project.time_signature_map.changes[0]["bar"] == 5 and project.time_signature_map.changes[0]["numerator"] == 4,
		"add at bar 5 while 4/4 gives (5, 4, 4)")
	_assert(lane.items().size() == 1, "lane holds one item per change")
	_assert(arranger.grid_helper.ticks_to_bbt(3840 * 4)["bar"] == 5, "grid is bound to the project map")
	var item = lane.items()[0]
	var x0 = item.position.x
	arranger.grid_helper.scroll_position = 100
	_assert(is_equal_approx(item.position.x, x0 - 100.0), "item follows scroll")
	arranger.grid_helper.scroll_position = 0

	_assert(lane.apply_edit(id, "7/8") and project.time_signature_map.changes[0]["denominator"] == 8, "edit to 7/8")
	_assert(not lane.apply_edit(id, "7/3") and project.time_signature_map.changes[0]["denominator"] == 8,
		"invalid text keeps the value")
	lane.move_change(id, 3)
	_assert(project.time_signature_map.changes[0]["bar"] == 3, "move to bar 3")
	lane.delete_change(id)
	_assert(project.time_signature_map.is_empty(), "delete removes the change")
	await process_frame
	await process_frame
	_assert(lane.items().is_empty(), "item is gone after delete")

	root.free()
	editor.free()
