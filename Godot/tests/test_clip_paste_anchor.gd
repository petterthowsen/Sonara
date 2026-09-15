# test_clip_paste_anchor.gd
# Headless tests for arranger paste targeting: the last clicked tick/track anchor and how
# Timeline._plan_placement maps clipboard clips onto lanes (topmost source lane -> anchor track).
#
# Timeline and the data models reference autoloads by bare name, so they are loaded with load()
# inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_clip_paste_anchor.gd -- --test
extends TestBase

var _timeline_script: GDScript
var _timeline_track_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _selection_manager_script: GDScript
var _selection_script: GDScript
var _instance_script: GDScript


func suite_name() -> String:
	return "Clip paste anchor tests"


func run_tests() -> void:
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	_timeline_track_script = load("res://arranger/timeline/TimelineTrack.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_selection_manager_script = load("res://arranger/timeline/ClipSelectionManager.gd")
	_selection_script = load("res://data/ClipSelection.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_test_paste_tick_priority()
	_test_anchor_keeps_unset_parts()
	_test_single_clip_to_other_track()
	_test_multi_track_keeps_spacing_and_skips_folders()
	_test_past_last_lane_is_empty()
	_test_no_anchor_keeps_source_tracks()
	_test_overlap_on_anchor_track_blocks()


## Timeline with one lane per entry in `types` (Track.TrackType values), in visual order.
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


## Place a 960-tick clip on `track` at `start`.
func _clip_on(track: Object, start: int) -> Object:
	var inst: Object = _instance_script.new()
	inst.clip = _clip_script.new()
	inst.start_ticks = start
	inst.duration_ticks = 960
	track.add_clip_instance(inst)
	return inst


func _selection(instances: Array) -> Object:
	var selection: Object = _selection_script.new()
	# Built at runtime: naming ClipInstance here would compile it before autoloads exist.
	var typed := Array([], TYPE_OBJECT, &"RefCounted", _instance_script)
	typed.assign(instances)
	selection.set_from(typed)
	return selection


func _free(timeline: Object) -> void:
	for lane in timeline.timeline_tracks:
		lane.free()
	timeline.free()


func _test_paste_tick_priority() -> void:
	var manager: Object = _selection_manager_script.new()
	_assert(manager.get_paste_tick(123) == 123, "no anchor pastes at fallback (playhead)")
	manager.set_anchor(null, 480)
	_assert(manager.get_paste_tick(123) == 480, "bare click tick beats playhead")
	manager.set_range_start(1920)
	_assert(manager.get_paste_tick(123) == 1920, "visible range start beats clicked tick")
	manager.hide_range()
	_assert(manager.get_paste_tick(123) == 1920, "range start also became the clicked tick")


func _test_anchor_keeps_unset_parts() -> void:
	var manager: Object = _selection_manager_script.new()
	var track: Object = _track_script.new(5)
	manager.set_anchor(track, 960)
	manager.set_anchor(null, 1920)
	_assert(manager.anchor_track == track, "null track keeps the anchor track")
	var other: Object = _track_script.new(6)
	manager.set_anchor(other)
	_assert(manager.anchor_track == other and manager.anchor_tick == 1920, "track-only anchor keeps the tick")


func _test_single_clip_to_other_track() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var timeline := _timeline([I, I, I])
	var keys: Object = _lane_track(timeline, 0)
	var strings: Object = _lane_track(timeline, 2)
	var inst: Object = _clip_on(keys, 960)
	var plan: Array = timeline._plan_placement(_selection([inst]), 3840, strings)
	_assert(plan.size() == 1, "one clip planned")
	_assert(plan[0].track == strings, "clip lands on the anchor track")
	_assert(plan[0].start == 3840, "clip lands at the target tick")
	_free(timeline)


func _test_multi_track_keeps_spacing_and_skips_folders() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var F: int = _track_script.TrackType.FOLDER
	# Lanes: 0 I, 1 I, 2 F, 3 I, 4 I  -> clip-capable order: 0, 1, 3, 4
	var timeline := _timeline([I, I, F, I, I])
	var a: Object = _clip_on(_lane_track(timeline, 0), 0)
	var b: Object = _clip_on(_lane_track(timeline, 1), 960)
	var plan: Array = timeline._plan_placement(_selection([a, b]), 1920, _lane_track(timeline, 1))
	_assert(plan.size() == 2, "both clips planned")
	for placement in plan:
		if placement.instance == a:
			_assert(placement.track == _lane_track(timeline, 1), "topmost clip on anchor track")
			_assert(placement.start == 1920, "topmost clip at target tick")
		else:
			_assert(placement.track == _lane_track(timeline, 3), "second clip skips the folder lane")
			_assert(placement.start == 2880, "second clip keeps its time offset")
	_free(timeline)


func _test_past_last_lane_is_empty() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var timeline := _timeline([I, I, I])
	var a: Object = _clip_on(_lane_track(timeline, 0), 0)
	var b: Object = _clip_on(_lane_track(timeline, 1), 0)
	var plan: Array = timeline._plan_placement(_selection([a, b]), 0, _lane_track(timeline, 2))
	_assert(plan.is_empty(), "layout running past the last lane plans nothing")
	_free(timeline)


func _test_no_anchor_keeps_source_tracks() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var F: int = _track_script.TrackType.FOLDER
	var timeline := _timeline([I, F])
	var source: Object = _lane_track(timeline, 0)
	var inst: Object = _clip_on(source, 0)
	var plan: Array = timeline._plan_placement(_selection([inst]), 960, null)
	_assert(plan.size() == 1 and plan[0].track == source, "null anchor keeps the source track")
	plan = timeline._plan_placement(_selection([inst]), 960, _lane_track(timeline, 1))
	_assert(plan.size() == 1 and plan[0].track == source, "folder anchor keeps the source track")
	_free(timeline)


func _test_overlap_on_anchor_track_blocks() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var timeline := _timeline([I, I])
	var inst: Object = _clip_on(_lane_track(timeline, 0), 0)
	_clip_on(_lane_track(timeline, 1), 960)
	var selection := _selection([inst])
	_assert(timeline._clipboard_placement_blocked(selection, 960, _lane_track(timeline, 1)), "overlap on anchor track blocks paste")
	_assert(not timeline._clipboard_placement_blocked(selection, 1920, _lane_track(timeline, 1)), "free space on anchor track allows paste")
	_free(timeline)
