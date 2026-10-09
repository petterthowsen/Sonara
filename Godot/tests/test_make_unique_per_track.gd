# test_make_unique_per_track.gd
# MakeClipUniquePerTrackCommand: one copy per track, shared within it, undoable.
# Run: godot --headless --path Godot -s tests/test_make_unique_per_track.gd -- --test
extends TestBase

var _project_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _cmd_script: GDScript


func suite_name() -> String:
	return "Make Unique Per Track"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_cmd_script = load("res://history/commands/MakeClipUniquePerTrackCommand.gd")

	var project: Object = _project_script.new()
	var clip: Object = project.create_clip("Loop", _clip_script.ClipType.MIDI)
	project.add_clip(clip)
	var track_a: Object = _track_script.new(2)
	var track_b: Object = _track_script.new(3)
	project.tracks.append(track_a)
	project.tracks.append(track_b)
	var a1: Object = _place(track_a, clip, 0)
	var a2: Object = _place(track_a, clip, 960)
	var b1: Object = _place(track_b, clip, 0)

	_assert(_cmd_script.is_shared_across_tracks(project, a1), "clip used on two tracks counts as shared")
	var group = _cmd_script.same_track_instances(a1)
	_assert(group.size() == 2, "same-track group holds both instances on track A")

	var cmd: Object = _cmd_script.new(project, group)
	cmd.do()
	_assert(a1.clip == a2.clip and a1.clip != clip, "track A instances share a new clip")
	_assert(b1.clip == clip, "track B keeps the original clip")
	_assert(not _cmd_script.is_shared_across_tracks(project, a1), "no longer shared across tracks")

	cmd.undo()
	_assert(a1.clip == clip and a2.clip == clip, "undo restores the original clip")
	_assert(not project.clips.has(cmd.unique_clip.id), "undo drops the unused copy")


func _place(track: Object, clip: Object, start: int) -> Object:
	var inst: Object = _instance_script.new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	inst.duration_ticks = 960
	track.add_clip_instance(inst)
	return inst
