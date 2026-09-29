# test_tempo_map.gd
# Headless tests for TempoMap (points, interpolation, persistence, undo snapshots) and the
# arranger's tempo lane toggle.
#
# Run: godot --headless --path Godot -s tests/test_tempo_map.gd -- --test
extends TestBase

const ARRANGER_SCENE := "res://arranger/Arranger.tscn"

var _map_script: GDScript
var _project_script: GDScript
var _command_script: GDScript


func suite_name() -> String:
	return "Tempo map"


func run_tests() -> void:
	_map_script = load("res://data/TempoMap.gd")
	_project_script = load("res://data/Project.gd")
	_command_script = load("res://history/commands/TempoMapStateCommand.gd")
	_test_empty_uses_fallback()
	_test_interpolation()
	_test_update_stays_between_neighbours()
	_test_json_round_trip()
	_test_project_persists_tempo_map()
	_test_command_undo_redo()
	_test_seconds_through_ramp()
	await _test_arranger_toggle()


func _test_empty_uses_fallback() -> void:
	var map = _map_script.new()
	_assert(map.is_empty(), "new map is empty")
	_assert(map.get_bpm_at_tick(500, 133.0) == 133.0, "empty map returns the fallback tempo")


func _test_interpolation() -> void:
	var map = _map_script.new()
	map.add_point(960, 100.0)
	map.add_point(0, 60.0)
	_assert(map.points[0]["tick"] == 0, "points are kept sorted by tick")
	_assert(map.get_bpm_at_tick(0, 120.0) == 60.0, "value at first point")
	_assert(is_equal_approx(map.get_bpm_at_tick(480, 120.0), 80.0), "linear midpoint")
	_assert(map.get_bpm_at_tick(5000, 120.0) == 100.0, "last value held after the last point")
	map.add_point(960, 200.0)
	_assert(map.points.size() == 2 and map.get_bpm_at_tick(960, 0.0) == 200.0,
		"adding on an occupied tick replaces it")
	map.add_point(10, 5000.0)
	_assert(map.points[1]["bpm"] == 999.0, "bpm is clamped to the maximum")


func _test_update_stays_between_neighbours() -> void:
	var map = _map_script.new()
	var a: int = map.add_point(0, 100.0)
	var b: int = map.add_point(960, 120.0)
	map.add_point(1920, 140.0)
	map.update_point(b, 5000, 130.0)
	_assert(map.points[1]["tick"] == 1919, "moving past the next point stops just before it")
	map.update_point(b, -50, 130.0)
	_assert(map.points[1]["tick"] == 1, "moving before the previous point stops just after it")
	map.update_point(a, -50, 90.0)
	_assert(map.points[0]["tick"] == 0, "first point cannot go below tick 0")


func _test_json_round_trip() -> void:
	var map = _map_script.new()
	map.add_point(0, 90.0)
	map.add_point(1920, 150.5)
	var loaded = _map_script.from_json(JSON.parse_string(JSON.stringify(map.to_json())))
	_assert(loaded.points.size() == 2, "points survive a JSON round trip")
	_assert(loaded.points[1]["tick"] == 1920 and loaded.points[1]["bpm"] == 150.5,
		"tick and bpm survive a JSON round trip")


func _test_project_persists_tempo_map() -> void:
	var project = _project_script.new()
	project.tempo_map.add_point(960, 140.0)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var loaded = _project_script.from_json(data)
	_assert(loaded.tempo_map.points.size() == 1, "project saves its tempo map")
	data.erase("tempo_map")
	_assert(_project_script.from_json(data).tempo_map.is_empty(), "legacy project loads an empty tempo map")


func _test_command_undo_redo() -> void:
	var map = _map_script.new()
	var before: Array[Dictionary] = map.snapshot()
	map.add_point(0, 100.0)
	var cmd = _command_script.new("Add Tempo Point", map, before, map.snapshot())
	cmd.undo()
	_assert(map.is_empty(), "undo removes the point")
	cmd.do()
	_assert(map.points.size() == 1 and map.points[0]["bpm"] == 100.0, "redo restores the point")


func _test_seconds_through_ramp() -> void:
	var map = _map_script.new()
	_assert(is_equal_approx(map.seconds_at_tick(1920, 120.0, 960), 1.0), "empty map uses the fallback tempo")
	map.add_point(0, 120.0)
	map.add_point(3840, 60.0)
	_assert(absf(map.seconds_at_tick(3840, 120.0, 960) - 4.0 * log(2.0)) < 1e-6, "3840 -> 4 ln 2 s")
	_assert(absf(map.seconds_at_tick(4800, 120.0, 960) - 3.773) < 1e-3, "4800 -> ~3.773 s")
	for tick in [0, 500, 3840, 4800, 9000]:
		var back: float = map.tick_at_seconds(map.seconds_at_tick(tick, 120.0, 960), 120.0, 960)
		_assert(absf(back - tick) < 1.0, "round trip at tick %d" % tick)
	var late = _map_script.new()
	late.add_point(960, 60.0)
	_assert(absf(late.seconds_at_tick(480, 120.0, 960) - 0.5) < 1e-9, "tempo is held before the first point")


func _test_arranger_toggle() -> void:
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

	_assert(not arranger.tempo_track.visible, "tempo lane starts hidden")
	arranger.tempo_toggle.button_pressed = true
	_assert(arranger.tempo_track.visible, "tempo toggle shows the lane")
	_assert(project.ruler_lanes["tempo"] == true, "tempo lane visibility is stored on the project")
	arranger.tempo_toggle.button_pressed = false
	_assert(not arranger.tempo_track.visible, "tempo toggle hides the lane")

	root.free()
	editor.free()
