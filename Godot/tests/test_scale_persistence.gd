# test_scale_persistence.gd
# Project scale and clip_editor_view: JSON round trip, legacy defaults, validation, and that
# changing the scale leaves notes alone (REQ-003, 011, 013, 020).
# Run: godot --headless --path Godot -s tests/test_scale_persistence.gd -- --test
extends TestBase

var _project_script: GDScript


func suite_name() -> String:
	return "Scale persistence"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_test_defaults()
	_test_round_trip()
	_test_legacy_project()
	_test_set_scale_validates()
	_test_flags()
	_test_scale_change_keeps_notes()


func _test_defaults() -> void:
	var project = _project_script.new()
	_assert(project.scale_root == 0 and project.scale_type == "none", "new project has no scale, root C")
	_assert(project.clip_editor_view == {"fold_to_scale": false, "scale_snap": false}, "both toggles off")


func _test_round_trip() -> void:
	var project = _project_script.new()
	project.set_scale(4, "lydian")
	project.set_clip_editor_view("fold_to_scale", true)
	project.set_clip_editor_view("scale_snap", true)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var loaded = _project_script.from_json(data)
	_assert(loaded.scale_root == 4 and loaded.scale_type == "lydian", "E Lydian survives reload")
	_assert(loaded.get_scale().display_name() == "E Lydian", "get_scale reads E Lydian")
	_assert(loaded.get_clip_editor_view("fold_to_scale") and loaded.get_clip_editor_view("scale_snap"),
		"both toggles survive reload")


func _test_legacy_project() -> void:
	var data: Dictionary = _project_script.new().to_json()
	data.erase("scale")
	data.erase("clip_editor_view")
	var loaded = _project_script.from_json(data)
	_assert(loaded.scale_type == "none" and loaded.scale_root == 0, "missing scale loads as none")
	_assert(not loaded.get_clip_editor_view("fold_to_scale") and not loaded.get_clip_editor_view("scale_snap"),
		"missing clip_editor_view loads with both flags off")
	data["scale"] = {"root": 30, "type": "bogus"}
	loaded = _project_script.from_json(data)
	_assert(loaded.scale_type == "none" and loaded.scale_root == 6, "bad saved scale is sanitised")


func _test_set_scale_validates() -> void:
	var project = _project_script.new()
	var seen: Array = []
	project.scale_changed.connect(func(r, t): seen.append([r, t]))
	project.set_scale(14, "dorian")
	_assert(project.scale_root == 2 and project.scale_type == "dorian", "root wraps, type kept")
	project.set_scale(2, "dorian")
	_assert(seen.size() == 1 and seen[0] == [2, "dorian"], "signal fires once, not for a no-op")
	project.set_scale(2, "bogus")
	_assert(project.scale_type == "none", "unknown type becomes none")


func _test_flags() -> void:
	var project = _project_script.new()
	var seen: Array = []
	project.clip_editor_view_changed.connect(func(k, v): seen.append([k, v]))
	project.set_clip_editor_view("scale_snap", true)
	project.set_clip_editor_view("scale_snap", true)
	_assert(seen == [["scale_snap", true]], "flag signal fires once")
	_assert(not project.get_clip_editor_view("unknown"), "unknown flag reads off")


func _test_scale_change_keeps_notes() -> void:
	var project = _project_script.new()
	var notes: Array[MidiNoteData] = []
	for p in [61, 63, 66]:
		var n := MidiNoteData.new()
		n.note = p
		notes.append(n)
	project.set_scale(0, "major")
	project.set_clip_editor_view("scale_snap", true)
	project.set_scale(7, "blues")
	_assert(notes.map(func(n): return n.note) == [61, 63, 66], "changing scale / snap leaves note pitches alone")
