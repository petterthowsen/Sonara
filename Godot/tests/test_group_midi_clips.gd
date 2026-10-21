# test_group_midi_clips.gd
# Headless tests for MIDI clips on group tracks (spec 049, REQ-001, REQ-016): a group holds MIDI
# clips (create, move between lanes, paste placement), refuses audio clips and audio asset drops,
# connects to the engine like a clip track (a folder still doesn't), and saves its clip
# instances through the project JSON.
#
# Timeline and the data models reference autoloads by bare name, so they are load()ed in run_tests().
# Run: godot --headless --path Godot -s tests/test_group_midi_clips.gd -- --test
extends TestBase

var _project_script: GDScript
var _timeline_script: GDScript
var _timeline_track_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _selection_script: GDScript
var _asset_script: GDScript


func suite_name() -> String:
	return "Group MIDI clips"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	_timeline_track_script = load("res://arranger/timeline/TimelineTrack.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_selection_script = load("res://data/ClipSelection.gd")
	_asset_script = load("res://browser/Asset.gd")
	_test_track_capabilities()
	_test_create_clip_on_group()
	_test_move_between_lanes()
	_test_paste_placement()
	_test_audio_drop_refused()
	_test_save_load_round_trip()


## Timeline with one lane per Track.TrackType in `types`.
func _timeline(types: Array) -> Object:
	var timeline: Object = _timeline_script.new()
	for i in range(types.size()):
		var track: Object = _track_script.new(i + 2)
		track.type = types[i]
		var lane: Object = _timeline_track_script.new()
		lane.track = track
		timeline.timeline_tracks.append(lane)
	return timeline


func _lane_track(timeline: Object, index: int) -> Object:
	return timeline.timeline_tracks[index].track


func _free(timeline: Object) -> void:
	for lane in timeline.timeline_tracks:
		lane.free()
	timeline.free()


## A 960-tick instance of a new clip of `clip_type` on `track` at `start`.
func _clip_on(track: Object, start: int, clip_type: int) -> Object:
	var inst: Object = _instance_script.new()
	inst.clip = _clip_script.new()
	inst.clip.type = clip_type
	inst.start_ticks = start
	inst.duration_ticks = 960
	track.add_clip_instance(inst)
	return inst


## A MIDI clip in the project pool plus an instance of it on `track` (ClipActions needs an Editor).
func _pool_instance(project: Object, track: Object, start: int, length: int) -> Object:
	var clip: Object = project.create_clip("Chord", _clip_script.ClipType.MIDI)
	clip.content_length_ticks = length
	var inst: Object = _instance_script.new("", clip.id)
	inst.clip = clip
	inst.start_ticks = start
	inst.duration_ticks = length
	track.add_clip_instance(inst)
	return inst


## Array[ClipInstance], built at runtime: naming the class here would compile before autoloads exist.
func _typed(instances: Array) -> Array:
	var typed := Array([], TYPE_OBJECT, &"RefCounted", _instance_script)
	typed.assign(instances)
	return typed


func _selection(instances: Array) -> Object:
	var selection: Object = _selection_script.new()
	selection.set_from(_typed(instances))
	return selection


func _test_track_capabilities() -> void:
	var T: Object = _track_script
	var group: Object = T.new(1)
	group.type = T.TrackType.GROUP
	var folder: Object = T.new(2)
	folder.type = T.TrackType.FOLDER
	var instrument: Object = T.new(3)
	var audio: Object = T.new(4)
	audio.type = T.TrackType.AUDIO
	_assert(group.has_clips(), "a group holds clips")
	_assert(not group.accepts_audio_clips(), "a group refuses audio clips")
	_assert(not folder.has_clips() and not folder.accepts_audio_clips(), "a folder still holds no clips")
	_assert(instrument.has_clips() and instrument.accepts_audio_clips(), "an instrument track is unchanged")
	_assert(audio.has_clips() and audio.accepts_audio_clips(), "an audio track is unchanged")
	_assert(group.default_clip_type() == _clip_script.ClipType.MIDI, "a new clip on a group is MIDI")
	_assert(audio.default_clip_type() == _clip_script.ClipType.AUDIO, "a new clip on an audio track is audio")


func _test_create_clip_on_group() -> void:
	var project: Object = _project_script.new()
	var group: Object = project.create_group_track("Choir").track
	var inst: Object = _pool_instance(project, group, 0, 3840)
	_assert(group.clip_instances.has(inst) and inst.track == group, "an instance can be added to the group")
	_assert(inst.clip.type == _clip_script.ClipType.MIDI, "the clip is MIDI")
	_assert(group.is_group(), "the track stays a group")


func _test_move_between_lanes() -> void:
	var G: int = _track_script.TrackType.GROUP
	var I: int = _track_script.TrackType.INSTRUMENT
	var A: int = _track_script.TrackType.AUDIO
	var timeline := _timeline([G, I, A])
	var midi: Object = _clip_on(_lane_track(timeline, 1), 0, _clip_script.ClipType.MIDI)
	var audio: Object = _clip_on(_lane_track(timeline, 2), 0, _clip_script.ClipType.AUDIO)
	var indices_midi := {midi: 1}
	var indices_audio := {audio: 2}
	var midi_list := _typed([midi])
	var audio_list := _typed([audio])
	_assert(timeline._compute_allowed_track_delta(midi_list, indices_midi, -1) == -1, "a MIDI clip may move up onto the group")
	_assert(timeline._compute_allowed_track_delta(audio_list, indices_audio, -2) == -1, "an audio clip stops below the group")
	_free(timeline)


func _test_paste_placement() -> void:
	var G: int = _track_script.TrackType.GROUP
	var I: int = _track_script.TrackType.INSTRUMENT
	var A: int = _track_script.TrackType.AUDIO
	var timeline := _timeline([G, I, A])
	var group: Object = _lane_track(timeline, 0)
	var midi: Object = _clip_on(_lane_track(timeline, 1), 960, _clip_script.ClipType.MIDI)
	var plan: Array = timeline._plan_placement(_selection([midi]), 1920, group)
	_assert(plan.size() == 1 and plan[0].track == group and plan[0].start == 1920, "a MIDI clip pastes onto the group")
	var audio: Object = _clip_on(_lane_track(timeline, 2), 0, _clip_script.ClipType.AUDIO)
	plan = timeline._plan_placement(_selection([audio]), 1920, group)
	_assert(plan.is_empty() or plan[0].track != group, "an audio clip is not planned onto the group")
	plan = timeline._plan_placement(_selection([audio]), 1920, null)
	_assert(plan.size() == 1 and plan[0].track == _lane_track(timeline, 2), "an audio clip keeps its own lane")
	_free(timeline)


func _test_audio_drop_refused() -> void:
	var lane: Object = _timeline_track_script.new()
	var group: Object = _track_script.new(7)
	group.type = _track_script.TrackType.GROUP
	lane.track = group
	var audio_asset: Object = _asset_script.new()
	audio_asset.type = _asset_script.TYPE.Audio
	var midi_asset: Object = _asset_script.new()
	midi_asset.type = _asset_script.TYPE.Midi
	_assert(not lane._can_drop_data(Vector2.ZERO, audio_asset), "an audio asset can't be dropped on a group (no instance)")
	_assert(lane._can_drop_data(Vector2.ZERO, midi_asset), "a MIDI asset can be dropped on a group")
	_assert(group.clip_instances.is_empty(), "a refused audio drop leaves no instance")
	var folder: Object = _track_script.new(8)
	folder.type = _track_script.TrackType.FOLDER
	lane.track = folder
	_assert(not lane._can_drop_data(Vector2.ZERO, midi_asset), "a folder still refuses drops")
	lane.free()


func _test_save_load_round_trip() -> void:
	var project: Object = _project_script.new()
	var group: Object = project.create_group_track("Choir").track
	var inst: Object = _pool_instance(project, group, 960, 1920)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var loaded: Object = _project_script.from_json(data)
	var loaded_group: Object = loaded.get_track_by_id(group.id)
	_assert(loaded_group != null and loaded_group.is_group(), "the group loads")
	_assert(loaded_group.clip_instances.size() == 1, "the group's clip instance is saved and loaded")
	if loaded_group.clip_instances.size() == 1:
		var li: Object = loaded_group.clip_instances[0]
		_assert(li.start_ticks == 960 and li.duration_ticks == 1920, "start and length survive the round trip")
		_assert(li.clip_id == inst.clip.id, "the instance keeps its clip id")
