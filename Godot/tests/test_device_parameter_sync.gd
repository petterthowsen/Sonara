# Parameter value sync between a DeviceInstance, its views and engine echoes.
# DeviceInstance references autoloads, so it is loaded with load() inside run_tests().
extends TestBase

var _device_script: GDScript
var _device_instance_script: GDScript


func suite_name() -> String:
	return "Device parameter sync"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_test_local_set_emits()
	_test_matching_echo_does_not_reemit()
	_test_stale_echoes_are_dropped()
	_test_engine_initiated_change_emits()


func _make_instance() -> Object:
	var device: Object = _device_script.new("test.sync", "Sync", _device_script.DeviceCategory.Effect)
	var param := DeviceParameter.new(0, "Amount")
	param.default_value = 0.0
	device.add_parameter(param)
	return _device_instance_script.new(device, 2, 0)


func _record(inst: Object) -> Array:
	var emitted: Array = []
	inst.parameter_changed.connect(func(id, v): emitted.append([id, v]))
	return emitted


func _test_local_set_emits() -> void:
	var inst: Object = _make_instance()
	var emitted := _record(inst)
	inst.set_parameter_normalized(0, 0.4)
	_assert(emitted.size() == 1 and is_equal_approx(emitted[0][1], 0.4),
		"local set emits parameter_changed so other views update (got %s)" % [emitted])


func _test_matching_echo_does_not_reemit() -> void:
	var inst: Object = _make_instance()
	inst.set_parameter_normalized(0, 0.4)
	var emitted := _record(inst)
	inst._on_parameter_value_received([0.4], 0)
	_assert(emitted.is_empty(), "echo of the current value doesn't emit again")


func _test_stale_echoes_are_dropped() -> void:
	var inst: Object = _make_instance()
	inst.set_parameter_normalized(0, 0.1)
	inst.set_parameter_normalized(0, 0.2)
	inst.set_parameter_normalized(0, 0.3)
	var emitted := _record(inst)
	inst._on_parameter_value_received([0.1], 0)
	inst._on_parameter_value_received([0.2], 0)
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.3),
		"stale echoes don't pull the value back mid-drag")
	inst._on_parameter_value_received([0.3], 0)
	_assert(emitted.is_empty(), "no emits for echoes of our own values (got %s)" % [emitted])


func _test_engine_initiated_change_emits() -> void:
	var inst: Object = _make_instance()
	var emitted := _record(inst)
	inst._on_parameter_value_received([0.7], 0)
	_assert(emitted.size() == 1 and is_equal_approx(inst.get_parameter_normalized(0), 0.7),
		"plugin-initiated change updates the value and emits")
