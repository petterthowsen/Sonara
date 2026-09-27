# test_clip_drag.gd
# Headless tests for the arranger clip move drag: clips move onto the hovered track live
# (Timeline._drag_to), skip tracks that would overlap, and stop at neighbours and the last lane.
#
# Timeline and the data models reference autoloads by bare name, so they are loaded with load()
# inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_clip_drag.gd -- --test
extends TestBase

var _timeline_script: GDScript
var _timeline_track_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _clip_ui_script: GDScript
var _transform_cmd_script: GDScript
var _grid_helper_script: GDScript


func suite_name() -> String:
	return "Clip drag tests"


func run_tests() -> void:
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	_timeline_track_script = load("res://arranger/timeline/TimelineTrack.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_clip_ui_script = load("res://arranger/timeline/clip/TimelineClip.gd")
	_transform_cmd_script = load("res://history/commands/ClipInstanceTransformCommand.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_test_moves_to_other_track_live()
	_test_blocked_track_keeps_current_track()
	_test_horizontal_stops_at_neighbour()
	_test_group_moves_through_own_lane()
	_test_clamps_to_last_lane_and_skips_folders()
	_test_clip_ui_follows_undo()


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


## Place a 960-tick clip on lane `index` at `start`.
func _clip_on(timeline: Object, index: int, start: int) -> Object:
	var inst: Object = _instance_script.new()
	inst.clip = _clip_script.new()
	inst.start_ticks = start
	inst.duration_ticks = 960
	_lane_track(timeline, index).add_clip_instance(inst)
	return inst


## Start a drag of `instances` (anchor first) the way _on_clip_drag_begin_requested does. The
## lanes have no clip UIs headless, so the start lane of each instance is passed in `indices`.
func _begin(timeline: Object, instances: Array, indices: Array) -> void:
	timeline._drag_active = true
	timeline._drag_anchor_instance = instances[0]
	timeline._drag_selected_instances.assign(instances)
	for i in range(instances.size()):
		timeline._drag_initial_positions[instances[i]] = instances[i].start_ticks
		timeline._drag_initial_track_indices[instances[i]] = indices[i]


func _free(timeline: Object) -> void:
	for lane in timeline.timeline_tracks:
		lane.free()
	timeline.free()


func _test_moves_to_other_track_live() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var timeline := _timeline([I, I])
	var inst := _clip_on(timeline, 0, 960)
	_begin(timeline, [inst], [0])

	timeline._drag_to(480, 1)
	_assert(inst.track == _lane_track(timeline, 1), "clip moves to the hovered track during the drag")
	_assert(inst.start_ticks == 1440, "clip keeps its horizontal offset while changing track")
	_assert(not _lane_track(timeline, 0).clip_instances.has(inst), "clip leaves its old track")

	timeline._drag_to(480, 0)
	_assert(inst.track == _lane_track(timeline, 0), "dragging back returns the clip to its first track")
	_free(timeline)


func _test_blocked_track_keeps_current_track() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var timeline := _timeline([I, I])
	var inst := _clip_on(timeline, 0, 0)
	var blocker := _clip_on(timeline, 1, 0)
	_begin(timeline, [inst], [0])

	timeline._drag_to(0, 1)
	_assert(inst.track == _lane_track(timeline, 0), "clip stays put when the hovered track is occupied there")
	_assert(blocker.start_ticks == 0, "occupying clip is untouched")

	timeline._drag_to(1920, 1)
	_assert(inst.track == _lane_track(timeline, 1) and inst.start_ticks == 1920,
		"clip enters the track once it is past the occupying clip")
	_free(timeline)


func _test_horizontal_stops_at_neighbour() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var timeline := _timeline([I])
	var inst := _clip_on(timeline, 0, 0)
	_clip_on(timeline, 0, 1920)
	_begin(timeline, [inst], [0])

	timeline._drag_to(1500, 0)
	_assert(inst.start_ticks == 960, "clip stops against the next clip (got %d)" % inst.start_ticks)
	_free(timeline)


func _test_group_moves_through_own_lane() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var timeline := _timeline([I, I, I])
	var top := _clip_on(timeline, 0, 0)
	var middle := _clip_on(timeline, 1, 0)
	_begin(timeline, [top, middle], [0, 1])

	timeline._drag_to(0, 1)
	_assert(top.track == _lane_track(timeline, 1), "top clip moves into the lane its partner leaves")
	_assert(middle.track == _lane_track(timeline, 2), "partner clip moves down one lane")
	_free(timeline)


func _test_clamps_to_last_lane_and_skips_folders() -> void:
	var I: int = _track_script.TrackType.INSTRUMENT
	var F: int = _track_script.TrackType.FOLDER
	var timeline := _timeline([I, I, F])
	var inst := _clip_on(timeline, 0, 0)
	_begin(timeline, [inst], [0])

	timeline._drag_to(0, 2)
	_assert(inst.track == _lane_track(timeline, 1), "a folder lane under the mouse clamps to the nearest clip lane")
	timeline._drag_to(0, 5)
	_assert(inst.track == _lane_track(timeline, 1), "dragging past the last lane stays on the last clip lane")
	_free(timeline)


func _test_clip_ui_follows_undo() -> void:
	var timeline: Object = _timeline_script.new()
	var grid: Object = _grid_helper_script.new()
	grid.pixels_per_beat = 100.0
	timeline.grid_helper = grid
	var inst: Object = _instance_script.new()
	inst.clip = _clip_script.new()
	inst.start_ticks = 960
	inst.duration_ticks = 960
	var clip_ui: Object = _clip_ui_script.new()
	clip_ui.bind_to_clip_instance(inst, timeline)

	var move: Object = _transform_cmd_script.new("Move Clip", inst, 960, 960, 0, 1920, 960, 0)
	move.do()
	_assert(is_equal_approx(clip_ui.position.x, 200.0), "clip UI follows a redone move (x=%s)" % clip_ui.position.x)
	move.undo()
	_assert(is_equal_approx(clip_ui.position.x, 100.0), "clip UI follows an undone move (x=%s)" % clip_ui.position.x)

	var resize: Object = _transform_cmd_script.new("Resize Clip", inst, 960, 960, 0, 960, 1920, 0)
	resize.do()
	_assert(is_equal_approx(clip_ui.size.x, 200.0), "clip UI follows a redone resize (w=%s)" % clip_ui.size.x)
	clip_ui.free()
	timeline.free()
