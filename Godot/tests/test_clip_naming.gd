# test_clip_naming.gd
# Headless tests for automatic clip names: per-track numbering, renaming when a clip moves to
# another track or is made unique per track, and leaving manually typed names alone.
#
# Run: godot --headless --path Godot -s tests/test_clip_naming.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Clip naming tests"


var _track_script: GDScript
var _project_script: GDScript
var _actions: GDScript
var _move_script: GDScript
var _rename_script: GDScript
var _unique_script: GDScript
var _clip_script: GDScript


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_project_script = load("res://data/Project.gd")
	_actions = load("res://history/ClipActions.gd")
	_move_script = load("res://history/commands/ClipInstanceMoveTrackCommand.gd")
	_rename_script = load("res://history/commands/ClipRenameCommand.gd")
	_unique_script = load("res://history/commands/MakeClipUniquePerTrackCommand.gd")
	_clip_script = load("res://data/Clip.gd")
	_test_numbering_is_per_track()
	_test_move_renames_auto_name()
	_test_move_keeps_custom_name()
	_test_move_of_shared_clip_does_not_rename()
	_test_make_unique_per_track_swaps_track_name()
	_test_name_survives_json()


func _setup(names: Array) -> Array:
	var project: Object = _project_script.new()
	var out: Array = [project]
	for n in names:
		var t: Object = _track_script.new(project.tracks.size() + 1)
		t.name = n
		t.set_project_ref(project)
		project.tracks.append(t)
		out.append(t)
	return out


func _new_clip(project: Object, track: Object, start: int) -> Object:
	var inst: Object = _actions.create_clip(project, track, start, 960, "")
	return inst


func _test_numbering_is_per_track() -> void:
	var s := _setup(["Bass", "Lead"])
	var project: Object = s[0]
	var a1: Object = _new_clip(project, s[1], 0)
	var a2: Object = _new_clip(project, s[1], 960)
	var b1: Object = _new_clip(project, s[2], 0)
	_assert(a1.clip.name == "Bass 1" and a2.clip.name == "Bass 2", "bass numbered 1,2: %s %s" % [a1.clip.name, a2.clip.name])
	_assert(b1.clip.name == "Lead 1", "lead counts its own clips: %s" % b1.clip.name)
	_assert(a1.clip.auto_name_track == "Bass", "auto track remembered")


func _move(inst: Object, from: Object, to: Object) -> Object:
	var cmd : Object = _move_script.new(inst, from, to, inst.start_ticks, inst.start_ticks)
	cmd.do()
	return cmd


func _test_move_renames_auto_name() -> void:
	var s := _setup(["Bass", "Lead"])
	var project: Object = s[0]
	var inst: Object = _new_clip(project, s[1], 0)
	var cmd: Object = _move(inst, s[1], s[2])
	_assert(inst.clip.name == "Lead 1", "renamed to new track: %s" % inst.clip.name)
	_assert(inst.clip.auto_name_track == "Lead", "auto track follows")
	cmd.undo()
	_assert(inst.clip.name == "Bass 1" and inst.clip.auto_name_track == "Bass", "undo restores name: %s" % inst.clip.name)


func _test_move_keeps_custom_name() -> void:
	var s := _setup(["Bass", "Lead"])
	var project: Object = s[0]
	var inst: Object = _new_clip(project, s[1], 0)
	var rename : Object = _rename_script.new(inst.clip, "Bass riff")
	rename.do()
	_move(inst, s[1], s[2])
	_assert(inst.clip.name == "Bass riff", "custom name kept: %s" % inst.clip.name)
	rename.undo()
	_assert(inst.clip.name == "Bass 1" and inst.clip.auto_name_track == "Bass", "undo of rename makes it automatic again")


func _test_move_of_shared_clip_does_not_rename() -> void:
	var s := _setup(["Bass", "Lead"])
	var project: Object = s[0]
	var inst: Object = _new_clip(project, s[1], 0)
	var twin: Object = s[1].create_clip_instance(inst.clip, 960, 960)
	_move(inst, s[1], s[2])
	_assert(inst.clip.name == "Bass 1", "clip still on two tracks keeps its name: %s" % inst.clip.name)
	_move(twin, s[1], s[2])
	_assert(inst.clip.name == "Lead 1", "renamed once only Lead uses it: %s" % inst.clip.name)


func _test_make_unique_per_track_swaps_track_name() -> void:
	var s := _setup(["Bass", "Lead"])
	var project: Object = s[0]
	var inst: Object = _new_clip(project, s[1], 0)
	var other: Object = s[2].create_clip_instance(inst.clip, 0, 960)
	var cmd : Object = _unique_script.new(project, Array([other], TYPE_OBJECT, &"RefCounted", load("res://data/ClipInstance.gd")))
	cmd.do()
	_assert(other.clip != inst.clip, "copy made")
	_assert(other.clip.name == "Lead 1", "copy named for its track: %s" % other.clip.name)
	_assert(other.clip.auto_name_track == "Lead", "copy stays automatic")
	_assert(inst.clip.name == "Bass 1", "original untouched")


func _test_name_survives_json() -> void:
	var clip: Object = _clip_script.new()
	clip.set_naming("Bass 1", "Bass")
	var back: Object = _clip_script.from_json(clip.to_json())
	_assert(back.auto_name_track == "Bass", "auto track round-trips")
	var legacy: Object = _clip_script.from_json({"name": "Old"})
	_assert(legacy.auto_name_track.is_empty(), "legacy clip counts as custom")
