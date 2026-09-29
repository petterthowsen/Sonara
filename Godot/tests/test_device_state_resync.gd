# test_device_state_resync.gd
# Headless tests for recovering device state Godot missed (dropped UDP): a re-advertised
# parameter list keeps the current values, and a "loading" device keeps re-checking its state.
#
# DeviceInstance references autoloads (AudioEngineOSC, Sonara) by bare name, so it is
# loaded with load() inside run_tests() rather than named by class.
# Run: godot --headless --path Godot -s tests/test_device_state_resync.gd -- --test
extends TestBase

var _device_script: GDScript
var _device_instance_script: GDScript


func suite_name() -> String:
	return "Device state resync tests"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_test_readvertised_params_keep_values()
	_test_restored_values_win_over_current()
	_test_loading_schedules_recheck()
	_test_recheck_stops_when_not_loading()


func _make_device_instance():
	var device: Object = _device_script.new(
		"test.resync.device",
		"Resync Test",
		_device_script.DeviceCategory.Instrument,
		_device_script.DeviceType.BuiltIn)
	return _device_instance_script.new(device, 0, 0)


func _advertise(dev, ids: Array) -> void:
	dev._on_param_count_received([ids.size()])
	for id in ids:
		dev._on_param_info_received([id, "P%d" % id, 0.0, 1.0, 0.5, "param", "float"])


func _test_readvertised_params_keep_values() -> void:
	var dev = _make_device_instance()
	_advertise(dev, [0, 1])
	_assert(is_equal_approx(dev.parameter_values[0], 0.5), "first advertisement uses the default")

	dev._on_parameter_value_received([0.8], 0)
	_advertise(dev, [0, 1])
	_assert(dev.parameters.size() == 2, "re-advertised list is rebuilt, not duplicated")
	_assert(is_equal_approx(dev.parameter_values[0], 0.8), "re-advertised list keeps the current value")
	_assert(is_equal_approx(dev.parameter_values[1], 0.5), "untouched parameter stays at default")
	_assert(dev._restored_parameter_values.is_empty(), "kept values are consumed once the list is complete")


func _test_restored_values_win_over_current() -> void:
	var dev = _make_device_instance()
	_advertise(dev, [0])
	dev._restored_parameter_values[0] = 0.25  # From the project file, not yet applied
	dev._on_parameter_value_received([0.9], 0)
	_advertise(dev, [0])
	_assert(is_equal_approx(dev.parameter_values[0], 0.25), "project-restored value beats the current one")


func _test_loading_schedules_recheck() -> void:
	var dev = _make_device_instance()
	var states: Array = []
	dev.loading_state_changed.connect(func(state: String) -> void: states.append(state))
	dev._on_loading_state_received(["loading"])
	_assert(dev.loading_state == "loading", "loading state is stored")
	_assert(dev._loading_recheck_pending, "a loading device schedules a state re-check")
	dev._on_loading_state_received(["ready"])
	_assert(dev.loading_state == "ready", "ready replaces loading")
	_assert(states == ["loading", "ready"], "each transition is signalled once")


func _test_recheck_stops_when_not_loading() -> void:
	var dev = _make_device_instance()
	dev._on_loading_state_received(["loading"])
	dev._on_loading_state_received(["ready"])
	dev._on_loading_recheck()
	_assert(not dev._loading_recheck_pending, "no further re-check once the device is ready")
