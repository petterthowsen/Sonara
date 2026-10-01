# test_automation_follows_clips.gd
# Headless tests for the "automation follows clips" gesture (REQ-025): shifting the lane points
# under a moved clip, creating the boundary anchors that keep the automation outside the range
# put, merging touching clip ranges so a shared edge shifts once, and undo/redo through a real
# CommandHistory.
#
# The shift helpers mutate a lane live and return the commands that recreate the gesture, exactly
# as the clip move records them (HistoryUtil.record_many). The local CommandHistory drives those
# same commands here, since HistoryUtil has no editor history in test mode.
#
# Run: godot --headless --path Godot -s tests/test_automation_follows_clips.gd -- --test
extends TestBase

var _track_script: GDScript
var _lane_script: GDScript
var _history_script: GDScript
var _actions_script: GDScript
var _macro_cmd: GDScript
var _timeline_script: GDScript
var _timeline_track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _project_script: GDScript


func suite_name() -> String:
	return "Automation follows clips tests"


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_actions_script = load("res://history/AutomationActions.gd")
	_macro_cmd = load("res://history/commands/MacroCommand.gd")
	_timeline_script = load("res://arranger/timeline/Timeline.gd")
	_timeline_track_script = load("res://arranger/timeline/TimelineTrack.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_project_script = load("res://data/Project.gd")
	_test_shift_moves_inside_and_creates_boundaries()
	_test_outside_points_untouched()
	_test_empty_range_is_noop()
	_test_undo_redo()
	_test_adjacent_ranges_shift_once()
	_test_curve_inherited_on_created_anchor()
	_test_timeline_nudge_moves_automation()
	_test_timeline_nudge_off_leaves_automation()
	_test_timeline_drag_finish_moves_automation()


func _make_lane() -> Object:
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	_track_script.new(1).add_automation_lane(lane)
	return lane


func _point_at(lane: Object, tick: int) -> Object:
	for p in lane.points:
		if p.tick == tick:
			return p
	return null


func _ticks(lane: Object) -> Array:
	return lane.points.map(func(p): return p.tick)


## A range with no point on either edge gains one on each, and every point inside shifts.
func _test_shift_moves_inside_and_creates_boundaries() -> void:
	var lane := _make_lane()
	lane.add_point(100, 0.2)
	lane.add_point(900, 0.8)
	var cmds: Array = _actions_script.shift_points_in_range(lane, 0, 1000, 500)
	_assert(cmds.size() == 2, "an add plus a transform are returned: %d" % cmds.size())
	_assert(str(_ticks(lane)) == str([500, 600, 1400, 1500]),
		"inside points and both anchors shifted: %s" % str(_ticks(lane)))
	_assert(_point_at(lane, 500) != null and is_equal_approx(_point_at(lane, 500).value, 0.2),
		"start anchor holds the lead-in value")
	_assert(_point_at(lane, 1500) != null and is_equal_approx(_point_at(lane, 1500).value, 0.8),
		"end anchor holds the trailing value")


## A point beyond the moved range keeps its tick and value.
func _test_outside_points_untouched() -> void:
	var lane := _make_lane()
	lane.add_point(100, 0.2)
	lane.add_point(900, 0.8)
	lane.add_point(2000, 0.5)
	_actions_script.shift_points_in_range(lane, 0, 1000, 500)
	var outside := _point_at(lane, 2000)
	_assert(outside != null and is_equal_approx(outside.value, 0.5),
		"the point after the range does not move")


## A lane with nothing under the range is left alone - no anchors are invented.
func _test_empty_range_is_noop() -> void:
	var lane := _make_lane()
	lane.add_point(2000, 0.2)
	lane.add_point(3000, 0.8)
	var cmds: Array = _actions_script.shift_points_in_range(lane, 0, 1000, 500)
	_assert(cmds.is_empty(), "no points under the range -> no commands")
	_assert(str(_ticks(lane)) == str([2000, 3000]), "lane unchanged: %s" % str(_ticks(lane)))


## Undo restores the exact original lane (anchors removed); redo re-applies the shift.
func _test_undo_redo() -> void:
	var lane := _make_lane()
	lane.add_point(100, 0.2)
	lane.add_point(900, 0.8)
	var cmds: Array = _actions_script.shift_points_in_range(lane, 0, 1000, 500)
	var hist: Object = _history_script.new()
	_drive(hist, cmds)
	_assert(str(_ticks(lane)) == str([500, 600, 1400, 1500]), "shifted before undo")

	hist.undo()
	_assert(str(_ticks(lane)) == str([100, 900]),
		"undo restores the two original points and drops the anchors: %s" % str(_ticks(lane)))

	hist.redo()
	_assert(str(_ticks(lane)) == str([500, 600, 1400, 1500]),
		"redo re-applies the shift: %s" % str(_ticks(lane)))


## Two clips that touch and move together share one span: the seam point shifts once and only the
## outer edges gain anchors.
func _test_adjacent_ranges_shift_once() -> void:
	var track: Object = _track_script.new(1)
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	lane.add_point(500, 0.3)
	lane.add_point(1000, 0.6)  # seam between the two clips
	lane.add_point(1500, 0.9)
	var moves := [
		{"track": track, "start": 0, "end": 1000},
		{"track": track, "start": 1000, "end": 2000},
	]
	var cmds: Array = _actions_script.shift_track_automation(moves, 500)
	_assert(not cmds.is_empty(), "the batch produced commands")
	_assert(str(_ticks(lane)) == str([500, 1000, 1500, 2000, 2500]),
		"merged span shifts once with only outer anchors: %s" % str(_ticks(lane)))
	var seam_count := 0
	for tick in _ticks(lane):
		if tick == 1500:
			seam_count += 1
	_assert(seam_count == 1, "the seam point moved once, not duplicated")


## A created anchor inherits the curve of the segment it splits, so a STEP segment stays a step.
func _test_curve_inherited_on_created_anchor() -> void:
	var lane := _make_lane()
	lane.add_point(500, 0.25, AutomationPoint.CurveType.STEP, 0.0)
	lane.add_point(1600, 0.75, AutomationPoint.CurveType.LINEAR, 0.0)
	_actions_script.shift_points_in_range(lane, 0, 1000, 500)
	var anchor := _point_at(lane, 1500)  # created at 1000, then shifted by 500
	_assert(anchor != null, "the end anchor exists after the shift")
	_assert(anchor.curve == AutomationPoint.CurveType.STEP, "the anchor inherits the STEP curve")


## A headless Timeline with one instrument track (one lane, points under a 1000-tick clip).
func _timeline_fixture(follows: bool) -> Dictionary:
	var timeline: Object = _timeline_script.new()
	var project: Object = _project_script.new()
	project.set_arranger_view("automation_follows_clips", follows)
	timeline.project = project
	var track: Object = _track_script.new(2)
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	track.add_automation_lane(lane)
	lane.add_point(100, 0.2)
	lane.add_point(900, 0.8)
	var lane_ui: Object = _timeline_track_script.new()
	lane_ui.track = track
	timeline.timeline_tracks.append(lane_ui)
	var inst: Object = _instance_script.new()
	inst.clip = _clip_script.new()
	inst.start_ticks = 0
	inst.duration_ticks = 1000
	track.add_clip_instance(inst)
	# `clip_instances` is Array[ClipInstance], which `select_instances` requires (REQ-020).
	timeline.clip_selection_manager.select_instances(track.clip_instances)
	return {"timeline": timeline, "lane": lane, "inst": inst, "lane_ui": lane_ui}


func _free_timeline(f: Dictionary) -> void:
	f.lane_ui.free()
	f.timeline.free()


## The real Timeline nudge path (`move_selection_by_ticks`) drags the lane points with the clip.
func _test_timeline_nudge_moves_automation() -> void:
	var f := _timeline_fixture(true)
	f.timeline.move_selection_by_ticks(480)
	_assert(f.inst.start_ticks == 480, "clip nudged by the delta (got %d)" % f.inst.start_ticks)
	_assert(str(_ticks(f.lane)) == str([480, 580, 1380, 1480]),
		"the lane followed the nudge: %s" % str(_ticks(f.lane)))
	_free_timeline(f)


## The real drag path (`_drag_to` then `_finish_drag`) drags the lane points with the clip too.
func _test_timeline_drag_finish_moves_automation() -> void:
	var f := _timeline_fixture(true)
	var timeline: Object = f.timeline
	timeline._drag_active = true
	timeline._drag_anchor_instance = f.inst
	timeline._drag_selected_instances.assign([f.inst])
	timeline._drag_initial_positions[f.inst] = f.inst.start_ticks
	timeline._drag_initial_track_indices[f.inst] = 0
	timeline._drag_to(480, 0)
	timeline._finish_drag()
	_assert(f.inst.start_ticks == 480, "clip dragged to 480 (got %d)" % f.inst.start_ticks)
	_assert(str(_ticks(f.lane)) == str([480, 580, 1380, 1480]),
		"the lane followed the drag: %s" % str(_ticks(f.lane)))
	_free_timeline(f)


## With the toggle off the same nudge leaves the lane alone.
func _test_timeline_nudge_off_leaves_automation() -> void:
	var f := _timeline_fixture(false)
	f.timeline.move_selection_by_ticks(480)
	_assert(f.inst.start_ticks == 480, "clip still nudged")
	_assert(str(_ticks(f.lane)) == str([100, 900]), "lane untouched: %s" % str(_ticks(f.lane)))
	_free_timeline(f)


## Record already-applied commands through a real history, wrapped in a macro when there are
## several (mirrors HistoryUtil.record_many).
func _drive(hist: Object, cmds: Array) -> void:
	if cmds.size() == 1:
		hist.record(cmds[0])
	else:
		hist.record(_macro_cmd.new("Move Automation", cmds))
