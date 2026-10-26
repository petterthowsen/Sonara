# test_track_clip_editor_lanes.gd
# Track.clip_editor_lanes: the MIDI editor's open automation lanes (spec 055, REQ-008..010).
#
# Track references the AudioEngineOSC autoload, so it is loaded with load() (see test_automation_model.gd).
# ValueLane is loaded the same way: a static reference pulls in UI scripts that need autoloads.
#
# Run: godot --headless --path Godot -s tests/test_track_clip_editor_lanes.gd -- --test
extends TestBase

var _track_script: GDScript
var _lane_script: GDScript


func suite_name() -> String:
	return "Track clip editor lanes"


func run_tests() -> void:
	_track_script = load("res://data/Track.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_test_setter_filters_and_clamps()
	_test_signal_only_on_change()
	_test_json_roundtrip()
	_test_missing_key()
	_test_remove_lane_drops_entry()
	_test_height_leaves_lane_height()
	_test_views_apply_shown()
	_test_views_capture_restore()
	_test_clip_view_keeps_heights()


func _track_with_lanes(ids: Array) -> Object:
	var track: Object = _track_script.new(1)
	for id in ids:
		track.add_automation_lane(_lane_script.new(id, AutomationTarget.channel_volume()))
	return track


func _entries(list: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in list:
		out.append(e)
	return out


func _test_setter_filters_and_clamps() -> void:
	var track := _track_with_lanes(["a", "b"])
	track.set_clip_editor_lanes(_entries([
		{"id": "b", "height": 5.0}, {"id": "ghost", "height": 100.0}, {"id": "a", "height": 9999.0},
	]))
	var limits: GDScript = load("res://clip_editor/value_lanes/ValueLane.gd")
	var got: Array = track.clip_editor_lanes
	_assert(got.size() == 2, "unknown id dropped")
	_assert(got[0]["id"] == "b" and got[1]["id"] == "a", "pane order kept")
	_assert(is_equal_approx(got[0]["height"], limits.MIN_HEIGHT), "height clamped up to the minimum")
	_assert(is_equal_approx(got[1]["height"], limits.MAX_HEIGHT), "height clamped down to the maximum")


func _test_signal_only_on_change() -> void:
	var track := _track_with_lanes(["a"])
	var count := [0]
	track.clip_editor_lanes_changed.connect(func(): count[0] += 1)
	track.set_clip_editor_lanes(_entries([{"id": "a", "height": 100.0}]))
	track.set_clip_editor_lanes(_entries([{"id": "a", "height": 100.0}]))
	_assert(count[0] == 1, "an identical set emits nothing")
	track.set_clip_editor_lanes(_entries([{"id": "a", "height": 120.0}]))
	_assert(count[0] == 2, "a changed height emits")


func _test_json_roundtrip() -> void:
	var track := _track_with_lanes(["a", "b"])
	track.set_clip_editor_lanes(_entries([{"id": "b", "height": 150.0}, {"id": "a", "height": 80.0}]))
	var data: Dictionary = JSON.parse_string(JSON.stringify(track.to_json()))
	var loaded: Object = _track_script.from_json(data)
	_assert(loaded.clip_editor_lanes.size() == 2, "both entries reload")
	_assert(loaded.clip_editor_lanes[0]["id"] == "b" and is_equal_approx(loaded.clip_editor_lanes[0]["height"], 150.0), "first entry round-trips")
	_assert(loaded.clip_editor_lanes[1]["id"] == "a" and is_equal_approx(loaded.clip_editor_lanes[1]["height"], 80.0), "second entry round-trips")
	# An entry whose lane no longer exists in the saved data is dropped on load.
	data["clip_editor_lanes"].append({"id": "gone", "height": 100.0})
	_assert(_track_script.from_json(data).clip_editor_lanes.size() == 2, "unknown id dropped on load")


func _test_missing_key() -> void:
	var track: Object = _track_script.from_json({"id": 1, "type": "INSTRUMENT", "name": "T"})
	_assert(track.clip_editor_lanes.is_empty(), "a missing key loads as no open lanes")


func _test_remove_lane_drops_entry() -> void:
	var track := _track_with_lanes(["a", "b"])
	track.set_clip_editor_lanes(_entries([{"id": "a", "height": 96.0}, {"id": "b", "height": 96.0}]))
	var count := [0]
	track.clip_editor_lanes_changed.connect(func(): count[0] += 1)
	track.remove_automation_lane(track.automation_lanes[0])
	_assert(track.clip_editor_lanes.size() == 1 and track.clip_editor_lanes[0]["id"] == "b", "removing a lane drops its entry")
	_assert(count[0] == 1, "the drop emits clip_editor_lanes_changed")


func _test_height_leaves_lane_height() -> void:
	var track := _track_with_lanes(["a"])
	var lane = track.automation_lanes[0]
	var before: int = lane.height
	track.set_clip_editor_lanes(_entries([{"id": "a", "height": 120.0}]))
	_assert(lane.height == before, "an entry height doesn't change the Arranger lane height")


func _view(kind: String) -> Object:
	if kind == "arranger":
		return load("res://arranger/tracklist/ArrangerLaneView.gd").new()
	return load("res://clip_editor/automation/ClipEditorLaneView.gd").new()


func _ids(lanes: Array) -> Array:
	return lanes.map(func(l): return l.id)


## A track with lanes [vol, cc1, cc11] where [vol, cc1] are shown in `view`.
func _track_showing_two(view: Object) -> Object:
	var track := _track_with_lanes(["vol", "cc1", "cc11"])
	view.set_shown(track, track.automation_lanes[0], true)
	view.set_shown(track, track.automation_lanes[1], true)
	view.set_shown(track, track.automation_lanes[2], false)
	return track


func _test_views_apply_shown() -> void:
	for kind in ["arranger", "clip"]:
		var view := _view(kind)
		var track := _track_showing_two(view)
		_assert(_ids(view.shown_lanes(track)) == ["vol", "cc1"], "%s: starts showing [vol, cc1]" % kind)
		view.apply_shown(track, [track.automation_lanes[1], track.automation_lanes[2]])
		_assert(_ids(view.shown_lanes(track)) == ["cc1", "cc11"],
				"%s: apply_shown leaves exactly [cc1, cc11] (%s)" % [kind, _ids(view.shown_lanes(track))])
		_assert(not view.is_shown(track, track.automation_lanes[0]), "%s: vol is hidden" % kind)
		_assert(view.is_shown(track, track.automation_lanes[2]), "%s: cc11 is shown" % kind)
	# Opening a lane in the MIDI editor never touches the Arranger flag, and the reverse.
	var clip := _view("clip")
	var track := _track_with_lanes(["a"])
	clip.on_lane_created(track, track.automation_lanes[0])
	_assert(clip.is_shown(track, track.automation_lanes[0]), "on_lane_created opens the lane in the MIDI editor")
	_assert(track.automation_lanes[0].visible, "the Arranger flag is untouched")
	var arranger := _view("arranger")
	arranger.apply_shown(track, [track.automation_lanes[0]])
	_assert(track.automation_expanded, "the Arranger view expands the track's lanes")
	# Default height for a newly opened lane.
	var limits: GDScript = load("res://clip_editor/value_lanes/ValueLane.gd")
	_assert(is_equal_approx(track.clip_editor_lanes[0]["height"], limits.DEFAULT_HEIGHT), "a new open lane gets the default height")


func _test_views_capture_restore() -> void:
	for kind in ["arranger", "clip"]:
		var view := _view(kind)
		var track := _track_showing_two(view)
		var state: Variant = view.capture(track)
		view.apply_shown(track, [track.automation_lanes[2]])
		_assert(_ids(view.shown_lanes(track)) == ["cc11"], "%s: changed to [cc11]" % kind)
		view.restore(track, state)
		_assert(_ids(view.shown_lanes(track)) == ["vol", "cc1"], "%s: restore(capture()) round-trips" % kind)


func _test_clip_view_keeps_heights() -> void:
	var view := _view("clip")
	var track := _track_with_lanes(["a", "b", "c"])
	track.set_clip_editor_lanes(_entries([{"id": "a", "height": 150.0}, {"id": "b", "height": 70.0}]))
	view.apply_shown(track, [track.automation_lanes[1], track.automation_lanes[2]])
	_assert(is_equal_approx(track.clip_editor_lanes[0]["height"], 70.0), "a lane that stays open keeps its height")
	_assert(track.clip_editor_lanes[1]["id"] == "c", "the new lane follows")
