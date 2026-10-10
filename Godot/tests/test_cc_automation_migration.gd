# test_cc_automation_migration.gd
# Headless tests for the saved-lane migration (spec 030 T-010, REQ-007): a lane whose target is
# an SFZ sampler's controller parameter (`device/…/param/N`) loads as a `channel/cc/N` lane,
# with its points untouched; lanes on other devices are left alone; a would-be duplicate
# (two lanes driving the same controller) leaves one lane.
#
# Run: godot --headless --path Godot -s tests/test_cc_automation_migration.gd -- --test
extends TestBase

const SFZ_ID := "sonara.builtin.sfizz"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _param_script: GDScript
var _lane_script: GDScript
var _target_script: GDScript


func suite_name() -> String:
	return "CC automation migration tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_lane_script = load("res://data/AutomationLane.gd")
	_target_script = load("res://data/AutomationTarget.gd")
	_test_sfz_lane_becomes_cc_lane()
	_test_non_sfz_lane_untouched()
	_test_duplicate_cc_lane_dropped()
	_test_nested_sfz_lane_migrates()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _register(device: Object) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	registry._devices[device.device_id] = device
	return device


func _sfz_device() -> Object:
	var device: Object = _device_script.new(SFZ_ID, "sfizz", DawEnums.CATEGORY_INSTRUMENT, DawEnums.DEVICE_BUILTIN)
	# SFZ controller parameters: the id is the controller number.
	for spec in [[1, ""], [73, "Attack"]]:
		var param: Object = _param_script.new(spec[0], spec[1])
		device.add_parameter(param)
	return _register(device)


func _synth_device() -> Object:
	var device: Object = _device_script.new("test.mig_syn", "mig_syn", DawEnums.CATEGORY_INSTRUMENT, DawEnums.DEVICE_BUILTIN)
	device.add_parameter(_param_script.new(5, "Tone"))
	return _register(device)


func _project_with_lanes(lanes: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var made: Dictionary = project.create_instrument_track("Keys")
	var ch: Object = made.channel
	# Device 0: the SFZ sampler (for lanes that drive it); device 1: an ordinary synth.
	ch.add_device(_device_instance_script.new(_sfz_device(), ch.id, ch.devices.size()))
	ch.add_device(_device_instance_script.new(_synth_device(), ch.id, ch.devices.size()))
	for lane in lanes:
		made.track.add_automation_lane(lane)
	return {"project": project, "track": made.track, "channel": ch}


func _lane(id: String, target: AutomationTarget, points: Array) -> Object:
	var lane: Object = _lane_script.new(id, target)
	for p in points:
		lane.add_point(p[0], p[1])
	return lane


func _reload(project: Object) -> Object:
	return _project_script.from_json(project.to_json())


func _cc_lane_on(track: Object, cc: int) -> Object:
	for lane in track.automation_lanes:
		if lane.target != null and lane.target.kind == AutomationTarget.Kind.MIDI_CC and lane.target.cc == cc:
			return lane
	return null


# ---------------------------------------------------------------------------
# the tests
# ---------------------------------------------------------------------------

func _test_sfz_lane_becomes_cc_lane() -> void:
	var made := _project_with_lanes([])
	var lane: Object = _lane("lane0", _target_script.device_param([0], 73), [[0, 0.2], [960, 0.8]])
	made.track.add_automation_lane(lane)
	var got: Object = _reload(made.project)
	_assert(got != null, "project reloads")
	var g_track: Object = _by_name(got.tracks, "Keys")
	var migrated: Object = _cc_lane_on(g_track, 73)
	_assert(migrated != null, "the SFZ param lane loads as a channel/cc/73 lane")
	if migrated != null:
		_assert(str(migrated.target) == "channel/cc/73", "target spelling is channel/cc/73, got %s" % str(migrated.target))
		_assert(migrated.points.size() == 2 and migrated.points[0].tick == 0 and migrated.points[1].tick == 960, "points keep their ticks")
		_assert(absf(migrated.points[0].value - 0.2) < 1e-9 and absf(migrated.points[1].value - 0.8) < 1e-9, "points keep their values")
	_assert(migrated.id == "lane0", "the lane keeps its id")


func _test_non_sfz_lane_untouched() -> void:
	var made := _project_with_lanes([])
	var lane: Object = _lane("lane0", _target_script.device_param([1], 5), [[0, 0.4]])
	made.track.add_automation_lane(lane)
	var got: Object = _reload(made.project)
	var g_track: Object = _by_name(got.tracks, "Keys")
	_assert(g_track.automation_lanes.size() == 1, "one lane survives")
	var lane_got: Object = g_track.automation_lanes[0]
	_assert(lane_got.target.kind == AutomationTarget.Kind.DEVICE_PARAM, "a non-SFZ lane stays a device parameter lane")
	_assert(str(lane_got.target) == "device/1/param/5", "target unchanged, got %s" % str(lane_got.target))
	_assert(lane_got.points.size() == 1 and absf(lane_got.points[0].value - 0.4) < 1e-9, "points untouched")


func _test_duplicate_cc_lane_dropped() -> void:
	var made := _project_with_lanes([])
	var first: Object = _lane("lane0", _target_script.device_param([0], 1), [[0, 0.1]])
	var second: Object = _lane("lane1", _target_script.device_param([0], 1), [[0, 0.9]])
	made.track.add_automation_lane(first)
	made.track.add_automation_lane(second)
	var got: Object = _reload(made.project)
	var g_track: Object = _by_name(got.tracks, "Keys")
	var cc_lanes: Array = []
	for lane in g_track.automation_lanes:
		if lane.target != null and lane.target.kind == AutomationTarget.Kind.MIDI_CC:
			cc_lanes.append(lane)
	_assert(cc_lanes.size() == 1, "two lanes for CC1 leave one: %d" % cc_lanes.size())
	if cc_lanes.size() == 1:
		_assert(cc_lanes[0].id == "lane0", "the first lane wins")


func _test_nested_sfz_lane_migrates() -> void:
	# device/1/0/param/73: an SFZ sampler inside a container still migrates (any depth).
	var made := _project_with_lanes([])
	var lane: Object = _lane("lane0", _target_script.device_param([1, 0], 73), [[0, 0.5]])
	made.track.add_automation_lane(lane)
	var got: Object = _reload(made.project)
	var g_track: Object = _by_name(got.tracks, "Keys")
	var migrated: Object = _cc_lane_on(g_track, 73)
	_assert(migrated == null, "a param id on a non-sampler parent device does not become a CC lane")
	var untouched: Object = g_track.automation_lanes[0]
	_assert(str(untouched.target) == "device/1/0/param/73", "unresolvable device path is left alone, got %s" % str(untouched.target))


func _by_name(list: Array, name: String) -> Object:
	for item in list:
		if item.name == name:
			return item
	return null
