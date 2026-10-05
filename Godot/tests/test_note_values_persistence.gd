# Run: godot --headless --path Godot -s tests/test_note_values_persistence.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Note values: persistence and sync"


func run_tests() -> void:
	_test_json_keys()
	_test_json_float_round_trip()
	_test_migration()
	_test_osc_payload()
	_test_project_format_version()


func _test_json_keys() -> void:
	var n := MidiNoteData.new()
	n.id = 3
	var j := n.to_json()
	_assert(j.has("vel") and not j.has("velocity"), "saves vel, not velocity")
	_assert(not j.has("rel"), "a default release is omitted")
	n.release = 0.9
	_assert(n.to_json().get("rel") == 0.9, "a non-default release is saved")


func _test_json_float_round_trip() -> void:
	var n := MidiNoteData.new()
	n.velocity = 0.5039
	n.release = 0.25
	var text := JSON.stringify(n.to_json())
	var back := MidiNoteData.from_json(JSON.parse_string(text))
	_assert(is_equal_approx(back.velocity, 0.5039) and is_equal_approx(back.release, 0.25), "vel/rel survive a JSON round trip")


func _test_migration() -> void:
	var old := MidiNoteData.from_json({"id": 1, "note": 60, "velocity": 100, "start_tick": 0, "duration_ticks": 480})
	_assert(is_equal_approx(old.velocity, 100.0 / 127.0) and old.release == 0.5, "velocity 100 migrates to 100/127, release 0.5")
	var one := MidiNoteData.from_json({"id": 2, "velocity": 1})
	_assert(is_equal_approx(one.velocity, 1.0 / 127.0), "an old integer velocity of 1 is 1/127, not full scale")
	var both := MidiNoteData.from_json({"id": 3, "vel": 0.3, "velocity": 100})
	_assert(is_equal_approx(both.velocity, 0.3), "vel wins over velocity")
	var none := MidiNoteData.from_json({"id": 4})
	_assert(is_equal_approx(none.velocity, 100.0 / 127.0), "no velocity key gives the default")


func _test_osc_payload() -> void:
	var clip = load("res://data/Clip.gd").new()
	clip.mark_synced_to_engine()
	_osc()._pending_sends.clear()
	var n = clip.add_midi_note(5, 60, 0.5039, 0, 480, 0.25)
	var sends: Array = _osc()._pending_sends.filter(func(s): return str(s).contains("add_note"))
	_assert(sends.size() == 1, "add_note sent once")
	if sends.size() == 1:
		var args: Array = _args_of(sends[0])
		_assert(args.size() == 6, "add_note carries 6 args (got %d)" % args.size())
		if args.size() == 6:
			_assert(typeof(args[4]) == TYPE_FLOAT and typeof(args[5]) == TYPE_FLOAT, "vel and rel go out as floats")
			_assert(is_equal_approx(args[4], 0.5039) and is_equal_approx(args[5], 0.25), "vel/rel values")
	_osc()._pending_sends.clear()
	n.velocity = 0.2
	clip.update_midi_note(n)
	sends = _osc()._pending_sends.filter(func(s): return str(s).contains("update_note"))
	_assert(sends.size() == 1, "update_note sent once")
	if sends.size() == 1:
		var args: Array = _args_of(sends[0])
		_assert(args.size() == 6 and typeof(args[4]) == TYPE_FLOAT and typeof(args[5]) == TYPE_FLOAT, "update_note carries float vel and rel")
	_osc()._pending_sends.clear()


func _osc() -> Node:
	return root.get_node("AudioEngineOSC")


func _args_of(entry: Variant) -> Array:
	if entry is Dictionary:
		return entry.get("args", [])
	if entry is Array and entry.size() >= 2 and entry[1] is Array:
		return entry[1]
	return []


func _test_project_format_version() -> void:
	var p = load("res://data/Project.gd").new()
	var j: Dictionary = p.to_json()
	_assert(j.get("format_version") == 2, "projects save format_version 2")
	_assert(load("res://data/Project.gd").from_json(j).format_version == 2, "version 2 reads back")
	j.erase("format_version")
	_assert(load("res://data/Project.gd").from_json(j).format_version == 1, "a missing format_version is 1")
