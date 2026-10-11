# test_key_change_map.gd
# Headless tests for KeyChangeMap (spec 034 G-001/G-003): lookups, clamping, dedupe, JSON round
# trip with validation, OSC args, and the undo command.
#
# Run: godot --headless --path Godot -s tests/test_key_change_map.gd -- --test
extends TestBase

var _map_script: GDScript
var _project_script: GDScript
var _command_script: GDScript


func suite_name() -> String:
	return "Key change map"


func run_tests() -> void:
	_map_script = load("res://data/KeyChangeMap.gd")
	_project_script = load("res://data/Project.gd")
	_command_script = load("res://history/commands/KeyChangeMapStateCommand.gd")
	_test_add_and_lookup()
	_test_same_tick_edits()
	_test_update_clamps()
	_test_remove()
	_test_json_and_validation()
	_test_osc_args()
	_test_project_round_trip()
	_test_command_undo_redo()


func _test_add_and_lookup() -> void:
	var map = _map_script.new()
	_assert(map.is_empty(), "new map is empty")
	map.add_change(3840, 2, "dorian")
	map.add_change(7680, 9, "minor_pentatonic")
	map.add_change(1920, 0, "none")
	_assert(map.changes[0]["tick"] == 1920 and map.changes[1]["tick"] == 3840, "sorted by tick")
	_assert(map.changes[0]["type_id"] == "none", "none is a valid change (no scale from here)")
	# Before the first change, at a change, between, after the last: base or the change in effect.
	var base = map.scale_at_tick(0, 0, "major")
	_assert(base.root == 0 and base.type_id == "major", "before the first change reads the base key")
	var at = map.scale_at_tick(1920, 0, "major")
	_assert(at.type_id == "none", "a change takes effect exactly on its own tick")
	var between = map.scale_at_tick(3839, 0, "major")
	_assert(between.type_id == "none", "between changes keeps the earlier one")
	var second = map.scale_at_tick(3840, 0, "major")
	_assert(second.root == 2 and second.type_id == "dorian", "at the second change reads it")
	var after = map.scale_at_tick(999999, 0, "major")
	_assert(after.root == 9, "after the last change reads the last one")
	_assert(map.index_at_tick(3840) == 1 and map.index_at_tick(5) == -1, "index_at_tick finds or misses")
	_assert(map.index_of(map.changes[1]["id"]) == 1, "index_of by id")


func _test_same_tick_edits() -> void:
	var map = _map_script.new()
	var first: int = map.add_change(1920, 0, "none")
	var second: int = map.add_change(1920, 5, "lydian")
	_assert(first == second and map.changes.size() == 1, "same tick edits instead of adding")
	_assert(map.changes[0]["root"] == 5 and map.changes[0]["type_id"] == "lydian", "same tick edit applies")


func _test_update_clamps() -> void:
	var map = _map_script.new()
	map.add_change(1920, 0, "none")
	var b: int = map.add_change(3840, 2, "dorian")
	map.add_change(5760, 9, "minor_pentatonic")
	map.update_change(b, 9999, 2, "dorian")
	_assert(map.changes[1]["tick"] == 5759, "moving past the next change stops just before it")
	map.update_change(b, 0, 2, "dorian")
	_assert(map.changes[1]["tick"] == 1921, "moving before the previous change stops just after it")
	map.update_change(b, 1920, 2, "dorian")
	_assert(map.changes[1]["tick"] == 1921, "tick 0 of a later change clamps to previous + 1")
	var fresh = _map_script.new()
	fresh.add_change(0, 2, "dorian")
	_assert(fresh.changes[0]["tick"] == 1, "tick 0 becomes tick 1 (it is the base key)")
	var ghost = _map_script.new()
	ghost.add_change(1920, 2, "dorian")
	var before: Array[Dictionary] = ghost.snapshot()
	ghost.update_change(12345, 7680, 5, "lydian")
	_assert(ghost.snapshot() == before, "updating an unknown id is a no-op")
	# Root wraps into 0..11.
	map.update_change(b, 3840, 14, "dorian")
	_assert(map.changes[1]["root"] == 2, "root 14 wraps to 2")


func _test_remove() -> void:
	var map = _map_script.new()
	var a: int = map.add_change(1920, 0, "none")
	var b: int = map.add_change(3840, 2, "dorian")
	map.remove_change(a)
	_assert(map.changes.size() == 1 and map.changes[0]["id"] == b, "remove drops the right change")
	map.remove_change(a)
	_assert(map.changes.size() == 1, "removing an unknown id is a no-op")


func _test_json_and_validation() -> void:
	var map = _map_script.new()
	map.add_change(1920, 0, "none")
	map.add_change(3840, 2, "dorian")
	var round_trip = _map_script.from_json(JSON.parse_string(JSON.stringify(map.to_json())))
	_assert(round_trip.changes.size() == 2, "JSON round trip keeps valid entries")
	_assert(round_trip.changes[1]["type_id"] == "dorian" and round_trip.changes[1]["tick"] == 3840, "fields survive")
	var data: Array = map.to_json()
	data.append({"tick": 7680, "root": 4, "type_id": "bogus"})
	data.append({"tick": 0, "root": 4, "type_id": "major"})
	data.append({"tick": 9600, "root": 7})
	data.append({"tick": 3840, "root": 4, "type_id": "lydian"})
	var loaded = _map_script.from_json(data)
	_assert(loaded.changes.size() == 2, "unknown type / tick 0 / incomplete entries dropped")
	_assert(loaded.index_at_tick(3840) >= 0 and loaded.changes[1]["type_id"] == "dorian",
		"duplicate-tick entries keep the first valid one")
	var empty = _map_script.from_json([{"nope": 1}])
	_assert(empty.is_empty(), "garbage entries are dropped")


func _test_osc_args() -> void:
	var map = _map_script.new()
	map.add_change(1920, 0, "none")
	map.add_change(3840, 2, "dorian")
	var args: Array = map.to_osc_args()
	_assert(args == [1920, 0, 3840, MusicalScale.make(2, "dorian").mask()], "flat tick/mask args: %s" % [args])
	_assert(args[3] == MusicalScale.make(2, "dorian").mask(), "mask equals MusicalScale.make().mask()")


func _test_project_round_trip() -> void:
	var project = _project_script.new()
	project.set_scale(0, "major")
	project.key_change_map.add_change(1920, 9, "minor_pentatonic")
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var loaded = _project_script.from_json(data)
	_assert(loaded.key_change_map.changes.size() == 1, "project saves its key change map")
	var scale = loaded.get_scale_at_tick(2000)
	_assert(scale.root == 9 and scale.type_id == "minor_pentatonic", "get_scale_at_tick reads the map")
	var base = loaded.get_scale_at_tick(0)
	_assert(base.root == 0 and base.type_id == "major", "get_scale_at_tick before the first change reads the base key")
	data.erase("key_changes")
	var legacy = _project_script.from_json(data)
	_assert(legacy.key_change_map.is_empty(), "a project without key_changes loads an empty map")


func _test_command_undo_redo() -> void:
	var map = _map_script.new()
	var before: Array[Dictionary] = map.snapshot()
	map.add_change(1920, 2, "dorian")
	var after: Array[Dictionary] = map.snapshot()
	var cmd = _command_script.new("Edit Key Change", map, before, after)
	cmd.undo()
	_assert(map.is_empty(), "undo restores the before snapshot")
	cmd.do()
	_assert(map.changes.size() == 1 and map.changes[0]["tick"] == 1920, "redo restores the after snapshot")
