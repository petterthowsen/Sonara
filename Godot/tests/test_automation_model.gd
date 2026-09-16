# test_automation_model.gd
# Headless tests for the automation data model: AutomationTarget string round-tripping
# (T-012) and AutomationLane / Track JSON persistence (T-013).
#
# AutomationLane and Track reference the AudioEngineOSC autoload, which isn't resolvable as a
# bare identifier until scripts are loaded via load() rather than referenced by static class name
# (see test_markers.gd) - autoloads aren't singletons yet at script-compile time.
#
# Run: godot --headless --path Godot -s tests/test_automation_model.gd -- --test
extends TestBase

var _lane_script: GDScript
var _track_script: GDScript


func suite_name() -> String:
	return "Automation model tests"


func run_tests() -> void:
	_lane_script = load("res://data/AutomationLane.gd")
	_track_script = load("res://data/Track.gd")
	_test_target_roundtrip()
	_test_target_rejects_bad_strings()
	_test_lane_json_roundtrip()
	_test_track_missing_lanes_key_loads_zero()
	_test_stub_era_curve_names_load_as_linear()
	_test_bypass_visibility_height_persist()


func _test_target_roundtrip() -> void:
	var cases := [
		["channel/volume", AutomationTarget.channel_volume()],
		["channel/pan", AutomationTarget.channel_pan()],
		["channel/send/2", AutomationTarget.send_amount(2)],
		["device/0/param/7", AutomationTarget.device_param([0], 7)],
		["device/0/1/param/7", AutomationTarget.device_param([0, 1], 7)],
		["device/3/1/2/param/128", AutomationTarget.device_param([3, 1, 2], 128)],
	]
	for case in cases:
		var text: String = case[0]
		var expected: AutomationTarget = case[1]
		var parsed := AutomationTarget.parse(text)
		_assert(parsed != null, "%s should parse" % text)
		_assert(str(parsed) == text, "re-printing %s, got %s" % [text, str(parsed)])
		_assert(str(parsed) == str(expected), "%s round-trips to itself" % text)


func _test_target_rejects_bad_strings() -> void:
	var bad := [
		"", "channel", "channel/gain", "channel/send/x",
		"device/param/7", "device/0/param", "device/0/param/x", "device/0/1/7",
	]
	for text in bad:
		_assert(AutomationTarget.parse(text) == null, "%s should not parse" % text)


func _test_lane_json_roundtrip() -> void:
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_volume())
	lane.add_point(0, 0.2)
	lane.add_point(960, 0.8, AutomationPoint.CurveType.STEP, 0.0)
	lane.bypassed = false

	var data: Dictionary = lane.to_json()
	var loaded: Object = _lane_script.from_json(data)

	_assert(loaded.id == "lane1", "lane id round-trips")
	_assert(str(loaded.target) == "channel/volume", "lane target round-trips")
	_assert(loaded.points.size() == 2, "both points round-trip")
	_assert(loaded.points[0].tick == 0 and absf(loaded.points[0].value - 0.2) < 1e-6, "point 0 round-trips")
	_assert(loaded.points[1].tick == 960 and loaded.points[1].curve == AutomationPoint.CurveType.STEP,
		"point 1 keeps its STEP curve")


func _test_track_missing_lanes_key_loads_zero() -> void:
	var data := {"id": 1, "type": "INSTRUMENT", "name": "T"}
	var track: Object = _track_script.from_json(data)
	_assert(track.automation_lanes.is_empty(), "a track with no automation_lanes key loads zero lanes")


func _test_stub_era_curve_names_load_as_linear() -> void:
	var lane_data := {
		"id": "lane1",
		"target": "channel/volume",
		"points": [
			{"tick": 0, "value": 0.1, "curve_type": "BEZIER"},
			{"tick": 960, "value": 0.9, "curve_type": "EXPONENTIAL"},
		],
	}
	var track_data := {"id": 1, "type": "INSTRUMENT", "name": "T", "automation_lanes": [lane_data]}
	var track: Object = _track_script.from_json(track_data)
	_assert(track.automation_lanes.size() == 1, "one lane loaded")
	var lane: Object = track.automation_lanes[0]
	for point in lane.points:
		_assert(point.curve == AutomationPoint.CurveType.LINEAR,
			"retired curve name loads as LINEAR, got %d" % point.curve)

	# A point without an id is assigned one by index rather than erroring.
	var point_ids: Array = lane.points.map(func(p): return p.id)
	_assert(point_ids.size() == 2, "points without ids get assigned ones: %s" % str(point_ids))


func _test_bypass_visibility_height_persist() -> void:
	var lane: Object = _lane_script.new("lane1", AutomationTarget.channel_pan())
	lane.add_point(0, 0.5)
	lane.bypassed = true
	lane.visible = false
	lane.height = 77

	var data: Dictionary = lane.to_json()
	var loaded: Object = _lane_script.from_json(data)
	_assert(loaded.bypassed == true, "bypassed persists")
	_assert(loaded.visible == false, "visible persists")
	_assert(loaded.height == 77, "height persists")
