# test_range_select_settings.gd
# Headless tests for the range-select behavior settings:
#   selection/range_select_selects_tracks        (Ctrl/Cmd drag also selects the clips' tracks)
#   selection/ruler_range_select_selects_clips   (a ruler range select selects clips)
#   selection/ruler_range_select_snaps_to_clips  (a ruler range select grows to cover those clips)
# Drives ClipSelectionManager's box-select gesture against a Timeline whose clip hit test is
# stubbed, so no lane layout is needed. Settings are read live, so each case flips them first.
#
# Timeline and the data models reference autoloads by bare name, so they are loaded with
# load() inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s tests/test_range_select_settings.gd -- --test
extends TestBase

const KEY_TRACKS := "selection/range_select_selects_tracks"
const KEY_RULER_CLIPS := "selection/ruler_range_select_selects_clips"
const KEY_RULER_SNAP := "selection/ruler_range_select_snaps_to_clips"
const KEY_FOLLOW := "selection/track_follows_clip_selection"

var _settings
var _manager_script: GDScript
var _grid_helper_script: GDScript
var _track_script: GDScript
var _clip_script: GDScript
var _instance_script: GDScript
var _stub_timeline_script: GDScript


func suite_name() -> String:
	return "Range select settings tests"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_manager_script = load("res://arranger/timeline/ClipSelectionManager.gd")
	_grid_helper_script = load("res://components/GridHelper.gd")
	_track_script = load("res://data/Track.gd")
	_clip_script = load("res://data/Clip.gd")
	_instance_script = load("res://data/ClipInstance.gd")
	_stub_timeline_script = GDScript.new()
	_stub_timeline_script.source_code = (
		"extends \"res://arranger/timeline/Timeline.gd\"\n"
		+ "var stub_hits: Array[ClipInstance] = []\n"
		+ "func get_clip_instances_in_rect(_rect: Rect2) -> Array[ClipInstance]:\n"
		+ "\treturn stub_hits.duplicate()\n"
	)
	_stub_timeline_script.reload()

	_test_defaults()
	_test_timeline_range_select_tracks_off()
	_test_timeline_range_select_tracks_on()
	_test_plain_clip_selection_still_selects_tracks()
	_test_ruler_selects_clips_on()
	_test_ruler_selects_clips_off()
	_test_ruler_snaps_to_clips_on()
	_test_timeline_range_still_covers_clips()
	_reset()


func _test_defaults() -> void:
	_assert(_settings.get_setting(KEY_TRACKS) != null, "range_select_selects_tracks is registered")
	_assert(_settings.get_setting(KEY_TRACKS).default == false, "range select selects tracks defaults to off")
	_assert(_settings.get_setting(KEY_RULER_CLIPS).default == true, "ruler range select selects clips defaults to on")
	_assert(_settings.get_setting(KEY_RULER_SNAP).default == false, "ruler range select snap defaults to off")
	for key in [KEY_TRACKS, KEY_RULER_CLIPS, KEY_RULER_SNAP]:
		_assert(_settings.get_setting(key).category == _settings.CATEGORY_BEHAVIOR, "%s is a Behavior setting" % key)


# ---------------------------------------------------------------------------
# Fixture: 64 px per beat (960 ticks). Clip A spans 480..1440, clip B 1680..2640.
# The drag runs from x=64 (tick 960) to x=128 (tick 1920), overlapping both.
# ---------------------------------------------------------------------------

func _fixture() -> Dictionary:
	var track_a: Object = _track_script.new(2)
	var track_b: Object = _track_script.new(3)
	var a: Object = _clip_on(track_a, 480)
	var b: Object = _clip_on(track_b, 1680)
	var timeline: Object = _stub_timeline_script.new()
	timeline.stub_hits = _typed([a, b])
	var gh: Object = _grid_helper_script.new()
	gh.pixels_per_beat = 64.0
	var manager: Object = _manager_script.new()
	manager.set_context(timeline, gh)
	# Record what the Editor would decide for track selection on every clip selection change.
	var log := {"follow": []}
	manager.selection_changed.connect(func(instances):
		if not instances.is_empty():
			log.follow.append(manager.clip_selection_selects_tracks()))
	return {"timeline": timeline, "manager": manager, "a": a, "b": b, "log": log}


func _drag(fx: Dictionary, from_ruler: bool) -> void:
	var m: Object = fx.manager
	if from_ruler:
		m.start_box_selection(Vector2(64.0, 0.0), true, true)
	else:
		m.start_box_selection(Vector2(64.0, 0.0))
	m.update_box_selection(Vector2(128.0, 0.0))
	m.end_box_selection()


func _free(fx: Dictionary) -> void:
	fx.timeline.free()


func _test_timeline_range_select_tracks_off() -> void:
	_reset()
	var fx := _fixture()
	_drag(fx, false)
	var follow: Array = fx.log.follow
	_assert(fx.manager.get_selected_instances().size() == 2, "timeline range select selects both clips")
	_assert(not follow.is_empty() and not follow.has(true), "setting off: timeline range select leaves track selection alone (%s)" % [follow])
	_free(fx)


func _test_timeline_range_select_tracks_on() -> void:
	_reset()
	_settings.set_value(KEY_TRACKS, true)
	var fx := _fixture()
	_drag(fx, false)
	var follow: Array = fx.log.follow
	_assert(not follow.is_empty() and not follow.has(false), "setting on: timeline range select selects tracks (%s)" % [follow])
	_free(fx)


func _test_plain_clip_selection_still_selects_tracks() -> void:
	_reset()
	var fx := _fixture()
	fx.manager.select_only(fx.a)
	_assert(fx.log.follow == [true], "a plain clip click still selects its track with the range setting off")
	_settings.set_value(KEY_FOLLOW, false)
	_assert(not fx.manager.clip_selection_selects_tracks(), "track_follows_clip_selection off still wins")
	_free(fx)


func _test_ruler_selects_clips_on() -> void:
	_reset()
	var fx := _fixture()
	_drag(fx, true)
	var m: Object = fx.manager
	_assert(m.get_selected_instances().size() == 2, "ruler selects clips on: both clips selected")
	_assert(m.get_full_range() == Vector2i(960, 1920), "snap off: range stays at the dragged span (%s)" % [m.get_full_range()])
	_assert(not fx.log.follow.has(true), "ruler range select leaves track selection alone by default")
	_free(fx)


func _test_ruler_selects_clips_off() -> void:
	_reset()
	_settings.set_value(KEY_RULER_CLIPS, false)
	_settings.set_value(KEY_RULER_SNAP, true)  # ignored while clip selection is off
	var fx := _fixture()
	var m: Object = fx.manager
	m.select_only(fx.a)
	_drag(fx, true)
	_assert(m.get_selected_instances().is_empty(), "ruler selects clips off: no clips selected, prior selection dropped")
	_assert(m.get_full_range() == Vector2i(960, 1920), "ruler selects clips off: range is the dragged span (%s)" % [m.get_full_range()])
	_free(fx)


func _test_ruler_snaps_to_clips_on() -> void:
	_reset()
	_settings.set_value(KEY_RULER_SNAP, true)
	var fx := _fixture()
	_drag(fx, true)
	var m: Object = fx.manager
	_assert(m.get_selected_instances().size() == 2, "snap on: both clips selected")
	_assert(m.get_full_range() == Vector2i(480, 2640), "snap on: range covers clip boundaries (%s)" % [m.get_full_range()])
	_free(fx)


## Timeline Ctrl+drag keeps its existing behavior: the range grows to cover selected clips.
func _test_timeline_range_still_covers_clips() -> void:
	_reset()
	var fx := _fixture()
	_drag(fx, false)
	_assert(fx.manager.get_full_range() == Vector2i(480, 2640), "timeline range select still covers clip boundaries (%s)" % [fx.manager.get_full_range()])
	_free(fx)


func _reset() -> void:
	for key in [KEY_TRACKS, KEY_RULER_CLIPS, KEY_RULER_SNAP, KEY_FOLLOW]:
		_settings.set_value(key, _settings.get_setting(key).default)


func _clip_on(track: Object, start: int) -> Object:
	var inst: Object = _instance_script.new()
	inst.clip = _clip_script.new()
	inst.start_ticks = start
	inst.duration_ticks = 960
	track.add_clip_instance(inst)
	return inst


func _typed(instances: Array) -> Array:
	var typed := Array([], TYPE_OBJECT, &"RefCounted", _instance_script)
	typed.assign(instances)
	return typed
