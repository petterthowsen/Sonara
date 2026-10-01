# test_sync_track_lane_height.gd
# "Sync Track and Automation Lane Height" behavior setting: a track and its lanes share one height.
#
# Run: godot --headless --path Godot -s tests/test_sync_track_lane_height.gd -- --test
extends TestBase

const KEY := "arranger/sync_track_and_lane_height"


func suite_name() -> String:
	return "Sync track and lane height"


func run_tests() -> void:
	var settings := get_root().get_node("/root/Settings")
	var track_script: GDScript = load("res://data/Track.gd")
	var lane_script: GDScript = load("res://data/AutomationLane.gd")
	_assert(settings.get_value(KEY) == true, "defaults to on")

	var track: Object = track_script.new()
	var a: Object = lane_script.new("lane0", null)
	var b: Object = lane_script.new("lane1", null)
	track.add_automation_lane(a)
	track.add_automation_lane(b)

	track.height = 90
	_assert(a.height == 90 and b.height == 90, "track resize resizes lanes")

	a.set_height(60)
	_assert(track.height == 60 and b.height == 60, "lane resize resizes track and sibling lanes")

	var old: Variant = settings.get_value(KEY)
	settings.set_value(KEY, false)
	track.height = 120
	_assert(a.height == 60 and b.height == 60, "off: lanes unchanged by track resize")
	a.set_height(80)
	_assert(track.height == 120, "off: track unchanged by lane resize")
	settings.set_value(KEY, old)
