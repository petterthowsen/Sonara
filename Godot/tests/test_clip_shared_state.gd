# test_clip_shared_state.gd
# Project.is_clip_shared: a clip with more than one instance reports as shared, the cached count
# follows add / remove / Make Unique, and a batch edit emits instance_counts_changed once per frame.
# Run: godot --headless --path Godot -s tests/test_clip_shared_state.gd -- --test
extends TestBase

var _project_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _unique_script: GDScript

var _emits: int = 0


func suite_name() -> String:
	return "Clip shared state"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_unique_script = load("res://history/commands/MakeClipUniqueCommand.gd")
	await _test_shared_unique_delete()
	await _test_batch_emits_once()
	await _test_timeline_clips_report_shared()


func _project_with_track() -> Array:
	var project: Object = _project_script.new()
	var track: Object = _track_script.new(2)
	track.set_project_ref(project)
	project.tracks.append(track)
	return [project, track]


func _place(track: Object, clip: Object, start: int) -> Object:
	var inst: Object = _instance_script.new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	inst.duration_ticks = 960
	track.add_clip_instance(inst)
	return inst


func _test_shared_unique_delete() -> void:
	var pt := _project_with_track()
	var project: Object = pt[0]
	var track: Object = pt[1]
	var clip: Object = project.create_clip("Bass", _clip_script.ClipType.MIDI)
	project.add_clip(clip)
	var a: Object = _place(track, clip, 0)
	_assert(not project.is_clip_shared(clip.id), "one instance is not shared")
	var b: Object = _place(track, clip, 3840)
	_assert(project.is_clip_shared(clip.id), "two instances of one clip are shared")
	_assert(project.get_clip_instance_count(clip.id) == 2, "the count follows the cache")

	var cmd: Object = _unique_script.new(project, b)
	cmd.do()
	_assert(not project.is_clip_shared(a.clip.id) and not project.is_clip_shared(b.clip.id),
		"after Make Unique neither instance is shared")
	cmd.undo()
	_assert(project.is_clip_shared(clip.id), "undoing Make Unique shares the clip again")

	track.remove_clip_instance(b)
	_assert(not project.is_clip_shared(clip.id), "after a delete the clip is not shared")
	_assert(project.get_clip_instance_count(clip.id) == 1, "the count drops with the delete")


func _test_batch_emits_once() -> void:
	var pt := _project_with_track()
	var project: Object = pt[0]
	var track: Object = pt[1]
	var clip: Object = project.create_clip("Lead", _clip_script.ClipType.MIDI)
	project.add_clip(clip)
	await process_frame  # let the emit queued by earlier edits go
	_emits = 0
	project.instance_counts_changed.connect(func(): _emits += 1)
	for i in 5:
		_place(track, clip, i * 960)
	_assert(_emits == 0, "nothing is emitted inside the frame of the edits")
	await process_frame
	_assert(_emits == 1, "a batch of five adds emits once on the next frame (got %d)" % _emits)
	await process_frame
	_assert(_emits == 1, "nothing more is emitted afterwards")


class FakeTimeline:
	var grid_helper = null

	func ticks_to_pixels(ticks: int) -> float:
		return float(ticks) * 0.1


## Arranger clips of one clip report shared, and stop reporting it after Make Unique (REQ-030).
func _test_timeline_clips_report_shared() -> void:
	var pt := _project_with_track()
	var project: Object = pt[0]
	var track: Object = pt[1]
	var clip: Object = project.create_clip("Bass", _clip_script.ClipType.MIDI)
	project.add_clip(clip)
	var a: Object = _place(track, clip, 0)
	var b: Object = _place(track, clip, 3840)
	var scene: PackedScene = load("res://arranger/timeline/clip/TimelineClip.tscn")
	var ui_a: Control = scene.instantiate()
	var ui_b: Control = scene.instantiate()
	root.add_child(ui_a)
	root.add_child(ui_b)
	ui_a.bind_to_clip_instance(a, FakeTimeline.new())
	ui_b.bind_to_clip_instance(b, FakeTimeline.new())
	await process_frame
	_assert(ui_a.is_shared() and ui_b.is_shared(), "both arranger clips of a shared clip report shared")
	_unique_script.new(project, b).do()
	_assert(not ui_a.is_shared() and not ui_b.is_shared(), "after Make Unique neither reports shared")
	ui_a.queue_free()
	ui_b.queue_free()
	await process_frame
