# test_clip_merge.gd
# Headless tests for ClipMergeActions (loaded at runtime: autoloads are not registered at compile time): consolidating one looping clip and merging several
# selected clips per track while leaving unselected clips between them untouched.
#
# Run: godot --headless --path Godot -s tests/test_clip_merge.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Clip merge tests"


var _track_script: GDScript
var _project_script: GDScript
var _merge_script: GDScript


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_project_script = load("res://data/Project.gd")
	_merge_script = load("res://history/ClipMergeActions.gd")
	_test_single_loop_is_baked()
	_test_merge_across_untouched_middle()
	_test_audio_is_not_mergeable()


func _project() -> Object:
	return _project_script.new()


func _midi_clip(project: Object, name: String, notes: Array, length: int) -> Object:
	var clip: Object = project.create_clip(name, 1)  # Clip.ClipType.MIDI
	clip.content_length_ticks = length
	for n in notes:
		var nn: Object = load("res://data/MidiNote.gd").new()
		nn.id = project.allocate_note_id()
		nn.note = n[0]
		nn.start_tick = n[1]
		nn.duration_ticks = n[2]
		nn.velocity = MidiNoteData.from_midi_velocity(100)
		clip.midi_notes.append(nn)
	project.add_clip(clip)
	return clip


func _starts(clip: Object) -> Array:
	var out: Array = clip.midi_notes.map(func(n): return n.start_tick)
	out.sort()
	return out


func _test_single_loop_is_baked() -> void:
	var project: Object = _project()
	var track: Object = _track_script.new(1)
	var clip: Object = _midi_clip(project, "A", [[60, 0, 100], [62, 400, 100]], 960)
	var inst: Object = track.create_clip_instance(clip, 1000, 2400)
	inst.set_loop(true, 0, 960)
	var merged: Array = _merge_script.merge(project, [inst])
	_assert(merged.size() == 1, "one merged instance")
	var m: Object = merged[0]
	_assert(track.clip_instances.size() == 1 and track.clip_instances[0] == m, "source replaced")
	_assert(m.start_ticks == 1000 and m.duration_ticks == 2400, "same span")
	_assert(not m.loop_enabled and m.clip_offset == 0, "loop gone, offset 0")
	_assert(_starts(m.clip) == [0, 400, 960, 1360, 1920, 2320],
		"loop unrolled to length (last pass cut at 2400): %s" % str(_starts(m.clip)))
	_assert(m.clip != clip, "new clip, original untouched")
	_assert(clip.midi_notes.size() == 2, "original notes untouched")


func _test_merge_across_untouched_middle() -> void:
	var project: Object = _project()
	var track: Object = _track_script.new(1)
	var other: Object = _track_script.new(2)
	var a: Object = track.create_clip_instance(_midi_clip(project, "A", [[60, 0, 100]], 960), 0, 960)
	var b: Object = track.create_clip_instance(_midi_clip(project, "B", [[64, 0, 100]], 960), 1000, 960)
	var c: Object = track.create_clip_instance(_midi_clip(project, "C", [[67, 0, 100]], 960), 2000, 960)
	var d: Object = other.create_clip_instance(_midi_clip(project, "D", [[48, 0, 100]], 960), 0, 960)
	var merged: Array = _merge_script.merge(project, [c, a, d])
	_assert(merged.size() == 2, "one per track: %d" % merged.size())
	_assert(track.clip_instances.has(b), "unselected middle clip kept")
	_assert(not track.clip_instances.has(a) and not track.clip_instances.has(c), "selected sources removed")
	_assert(track.clip_instances.size() == 2, "middle + merged")
	var m: Object = merged[0]
	_assert(m.start_ticks == 0 and m.duration_ticks == 2960, "spans first start to last end")
	_assert(_starts(m.clip) == [0, 2000], "notes placed at their song position: %s" % str(_starts(m.clip)))
	_assert(other.clip_instances.size() == 1 and other.clip_instances[0].clip.midi_notes.size() == 1,
		"other track consolidated alone")


func _test_audio_is_not_mergeable() -> void:
	var project: Object = _project()
	var track: Object = _track_script.new(1)
	var clip: Object = project.create_clip("Wav", 0)  # Clip.ClipType.AUDIO
	project.add_clip(clip)
	var inst: Object = track.create_clip_instance(clip, 0, 960)
	_assert(not _merge_script.can_merge([inst]), "audio instances are skipped")
	_assert(_merge_script.merge(project, [inst]).is_empty(), "nothing merged")
