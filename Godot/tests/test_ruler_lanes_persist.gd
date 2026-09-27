# test_ruler_lanes_persist.gd
# Headless tests for arranger ruler lane visibility (beats / time / markers) saved with the
# project: JSON round-trip, and projects saved before the field existed loading all-visible.
#
# Project references autoloads by bare name, so it is loaded with load() inside run_tests().
# Run: godot --headless --path Godot -s tests/test_ruler_lanes_persist.gd -- --test
extends TestBase

var _project_script: GDScript


func suite_name() -> String:
	return "Ruler lane persistence tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_test_defaults_visible()
	_test_round_trip()
	_test_legacy_project_loads_visible()


func _test_defaults_visible() -> void:
	var project = _project_script.new()
	_assert(project.ruler_lanes == {"beats": true, "time": true, "markers": true},
		"new project shows all ruler lanes")


func _test_round_trip() -> void:
	var project = _project_script.new()
	project.ruler_lanes["time"] = false
	project.ruler_lanes["markers"] = false
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var loaded = _project_script.from_json(data)
	_assert(loaded.ruler_lanes["beats"] == true, "beats lane stays visible after reload")
	_assert(loaded.ruler_lanes["time"] == false, "hidden time lane stays hidden after reload")
	_assert(loaded.ruler_lanes["markers"] == false, "hidden marker lane stays hidden after reload")


func _test_legacy_project_loads_visible() -> void:
	var data: Dictionary = _project_script.new().to_json()
	data.erase("ruler_lanes")
	var loaded = _project_script.from_json(data)
	_assert(loaded.ruler_lanes == {"beats": true, "time": true, "markers": true},
		"project without ruler_lanes loads with all lanes visible")
