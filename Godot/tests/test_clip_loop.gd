# test_clip_loop.gd
# Headless tests for ClipInstance loop maths: wrap_content_tick, get_loop_segments and the
# default loop region. The arranger draws one run per segment and the engine wraps the same way.
#
# Run: godot --headless --path Godot -s tests/test_clip_loop.gd -- --test
extends TestBase

var _InstanceScript: GDScript
var _ClipScript: GDScript


func suite_name() -> String:
	return "Clip loop"


func run_tests() -> void:
	_InstanceScript = load("res://data/ClipInstance.gd")
	_ClipScript = load("res://data/Clip.gd")
	_test_unlooped_is_one_segment()
	_test_segments_repeat_the_loop()
	_test_segments_start_inside_loop_with_offset()
	_test_lead_in_before_loop_start()
	_test_segment_cap()
	_test_default_loop_region()
	_test_editor_played_content()


func _instance(duration: int, offset: int = 0):
	var inst = _InstanceScript.new("i", "c")
	inst.duration_ticks = duration
	inst.clip_offset = offset
	return inst


func _test_unlooped_is_one_segment() -> void:
	var inst = _instance(5000, 100)
	var segs = inst.get_loop_segments()
	_assert(segs.size() == 1, "unlooped clip is a single run")
	_assert(segs[0] == Vector3i(0, 5000, 100), "run covers the whole instance from clip_offset")
	_assert(inst.wrap_content_tick(99999) == 99999, "no wrap without a loop")


func _test_segments_repeat_the_loop() -> void:
	var inst = _instance(2500)
	inst.loop_enabled = true
	inst.loop_start_ticks = 0
	inst.loop_length_ticks = 1000
	var segs = inst.get_loop_segments()
	_assert(segs.size() == 3, "2500 ticks of a 1000 tick loop is three runs, got %d" % segs.size())
	_assert(segs[0] == Vector3i(0, 1000, 0), "first pass")
	_assert(segs[1] == Vector3i(1000, 2000, 0), "second pass restarts at the loop start")
	_assert(segs[2] == Vector3i(2000, 2500, 0), "last pass is cut at the instance end")
	_assert(inst.wrap_content_tick(1000) == 0 and inst.wrap_content_tick(2345) == 345, "wrap matches the runs")


func _test_segments_start_inside_loop_with_offset() -> void:
	var inst = _instance(1500, 400)
	inst.loop_enabled = true
	inst.loop_start_ticks = 0
	inst.loop_length_ticks = 1000
	var segs = inst.get_loop_segments()
	_assert(segs.size() == 2, "trimmed loop gives two runs, got %d" % segs.size())
	_assert(segs[0] == Vector3i(0, 600, 400), "first run is the rest of the loop")
	_assert(segs[1] == Vector3i(600, 1500, 0), "then the loop from its start")


func _test_lead_in_before_loop_start() -> void:
	var inst = _instance(3000, 0)
	inst.loop_enabled = true
	inst.loop_start_ticks = 500
	inst.loop_length_ticks = 1000
	var segs = inst.get_loop_segments()
	_assert(segs[0] == Vector3i(0, 1500, 0), "lead-in plays straight through to the loop end")
	_assert(segs[1] == Vector3i(1500, 2500, 500), "then repeats from the loop start")


func _test_segment_cap() -> void:
	var inst = _instance(1000000)
	inst.loop_enabled = true
	inst.loop_length_ticks = 10
	_assert(inst.get_loop_segments(32).size() == 32, "runs stop at the cap")


func _test_default_loop_region() -> void:
	var inst = _instance(8000, 960)
	var clip = _ClipScript.new("c")
	clip.content_length_ticks = 3840
	inst.clip = clip
	var region = inst.default_loop_region()
	_assert(region == Vector2i(960, 2880), "loop covers the content left after the trim, got %s" % [region])
	inst.duration_ticks = 1000
	_assert(inst.default_loop_region() == Vector2i(960, 1000), "or just what shows when shorter")


func _test_editor_played_content() -> void:
	var inst = _instance(3000, 0)
	inst.start_ticks = 10000
	_assert(inst.first_run_range() == Vector2i(0, 3000), "unlooped first run is the played window")
	_assert(inst.plays_content_tick(2999) and not inst.plays_content_tick(3000), "unlooped window edges")

	inst.loop_enabled = true
	inst.loop_start_ticks = 500
	inst.loop_length_ticks = 1000
	_assert(inst.first_run_range() == Vector2i(0, 1500), "looped first run ends at the loop end")
	_assert(inst.plays_clip_span(1400, 1600) and not inst.plays_clip_span(1500, 1600), "notes past the loop end are not in the first run")
	_assert(inst.plays_content_tick(200) and inst.plays_content_tick(1499), "lead-in and loop region are played")
	_assert(not inst.plays_content_tick(1500), "content past the loop end never plays")

	_assert(inst.song_to_played_content_ticks(11600) == 600, "playhead folds back into the loop region")
	_assert(inst.song_to_played_content_ticks(9000) == -1000, "before the instance nothing folds")
	_assert(inst.song_to_played_content_ticks(13000) == 3000, "after the instance nothing folds")

	inst.duration_ticks = 1200
	_assert(inst.first_run_range() == Vector2i(0, 1200), "an instance shorter than the loop never wraps")
	_assert(inst.plays_content_tick(1100) and not inst.plays_content_tick(1200), "and plays only its window")
