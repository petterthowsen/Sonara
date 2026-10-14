# Undo/redo of user parameter edits (ParameterActions + ParameterChangeCommand).
# DeviceInstance references autoloads, so it is loaded with load() inside run_tests().
extends TestBase

var _device_script: GDScript
var _device_instance_script: GDScript
var _history: Object
var _actions: GDScript
var _util: GDScript


func suite_name() -> String:
	return "Parameter undo"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_history = load("res://history/CommandHistory.gd").new()
	_actions = load("res://history/ParameterActions.gd")
	_util = load("res://history/HistoryUtil.gd")
	_util.test_recorder = func(cmd): _history.record(cmd)
	_test_edit_records_one_step()
	_test_unchanged_value_records_nothing()
	_test_drag_is_one_step()
	_test_two_drags_are_two_steps()
	_test_multi_param_gesture_is_one_step()
	_test_undo_redo_go_through_model_setter()
	_test_engine_echo_records_nothing()
	_test_real_values_and_reset()
	_test_plugin_edit_and_drag()
	_test_plugin_undo_redo_use_normal_path()
	_test_plugin_echoes_record_nothing()
	_test_plugin_shares_history_with_builtin()
	_util.test_recorder = Callable()


func _make_instance() -> Object:
	var device: Object = _device_script.new("test.undo", "Undo", _device_script.DeviceCategory.Effect)
	for i in 2:
		var param = DeviceParameter.new(i, "P%d" % i)
		param.default_value = 0.0
		param.min_value = 0.0
		param.max_value = 10.0
		device.add_parameter(param)
	return _device_instance_script.new(device, 2, 0)


func _fresh() -> Object:
	_history.clear()
	return _make_instance()


func _test_edit_records_one_step() -> void:
	var inst: Object = _fresh()
	_actions.set_normalized(inst, 0, 0.4)
	_assert(_history.undo_count() == 1, "a discrete edit records one step")
	_assert(_history.undo_name() == "Set Parameter", "step has a label")
	_actions.set_normalized(inst, 0, 0.6)
	_assert(_history.undo_count() == 2, "discrete edits never merge")


func _test_unchanged_value_records_nothing() -> void:
	var inst: Object = _fresh()
	_actions.set_normalized(inst, 0, 0.0)
	_assert(_history.undo_count() == 0, "setting the current value records nothing")


func _test_drag_is_one_step() -> void:
	var inst: Object = _fresh()
	_actions.begin_gesture()
	for v in [0.1, 0.2, 0.3, 0.45]:
		_actions.set_normalized(inst, 0, v)
	_actions.end_gesture()
	_assert(_history.undo_count() == 1, "a drag gesture is one step (got %d)" % _history.undo_count())
	_history.undo()
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.0), "undo restores the value before the drag")
	_history.redo()
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.45), "redo reapplies the end of the drag")


func _test_two_drags_are_two_steps() -> void:
	var inst: Object = _fresh()
	for end in [0.3, 0.8]:
		_actions.begin_gesture()
		_actions.set_normalized(inst, 0, end / 2.0)
		_actions.set_normalized(inst, 0, end)
		_actions.end_gesture()
	_assert(_history.undo_count() == 2, "two drags on one parameter are two steps")
	_history.undo()
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.3), "undo goes back to the first drag's end")


func _test_multi_param_gesture_is_one_step() -> void:
	var inst: Object = _fresh()
	_actions.begin_gesture()
	_actions.set_normalized(inst, 0, 0.2)
	_actions.set_normalized(inst, 1, 0.7)
	_actions.set_normalized(inst, 0, 0.3)
	_actions.end_gesture()
	_assert(_history.undo_count() == 1, "a gesture moving two parameters is one step")
	_history.undo()
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.0) and is_equal_approx(inst.get_parameter_normalized(1), 0.0),
		"undo restores both parameters")
	_history.redo()
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.3) and is_equal_approx(inst.get_parameter_normalized(1), 0.7),
		"redo reapplies both parameters")


func _test_undo_redo_go_through_model_setter() -> void:
	var inst: Object = _fresh()
	_actions.set_normalized(inst, 0, 0.5)
	var emitted: Array = []
	inst.parameter_changed.connect(func(id, v): emitted.append([id, v]))
	_history.undo()
	_assert(emitted.size() == 1 and is_equal_approx(emitted[0][1], 0.0),
		"undo emits parameter_changed through set_parameter_normalized (so views and engine sync)")
	_history.redo()
	_assert(emitted.size() == 2 and is_equal_approx(emitted[1][1], 0.5), "redo does the same")
	_assert(_history.undo_count() == 1 and _history.redo_count() == 0, "undo/redo don't add steps")


func _test_engine_echo_records_nothing() -> void:
	var inst: Object = _fresh()
	_actions.set_normalized(inst, 0, 0.4)
	var before: int = _history.undo_count()
	inst._on_parameter_value_received([0.4], 0)
	inst._on_parameter_value_received([0.9], 0)  # plugin- or modulation-initiated change
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.9), "engine value reached the model")
	_assert(_history.undo_count() == before, "engine echoes and engine-side changes record no step")
	inst.set_parameter_normalized(1, 0.5)
	_assert(_history.undo_count() == before, "the plain model setter records no step")


func _test_real_values_and_reset() -> void:
	var inst: Object = _fresh()
	_actions.set_real(inst, 0, 5.0)
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.5), "set_real converts to normalized")
	_assert(_actions.reset(inst, 0), "reset changes a non-default value")
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.0) and _history.undo_name() == "Reset Parameter", "reset goes to default as its own step")
	_history.undo()
	_assert(is_equal_approx(inst.get_parameter_normalized(0), 0.5), "undo of reset restores the value")


# ---- Plugin (CLAP/VST3) devices, #124 ----

func _make_plugin(type: int = 1) -> Object:
	# DeviceType.CLAP or VST3; plugin ids are arbitrary, not 0-based.
	var device: Object = _device_script.new("test.plugin", "Plugin", _device_script.DeviceCategory.Effect, type)
	for id in [7, 4096]:
		var param = DeviceParameter.new(id, "PP%d" % id)
		param.default_value = 0.0
		param.min_value = 0.0
		param.max_value = 10.0
		device.add_parameter(param)
	return _device_instance_script.new(device, 2, 0)


## OSC messages to a parameter address queued by the (not yet ready) OSC autoload.
func _sent_values(param_id: int) -> Array:
	var out: Array = []
	for item in root.get_node("/root/AudioEngineOSC")._pending_sends:
		if String(item["address"]).ends_with("/param/%d" % param_id):
			out.append(item["args"][0])
	return out


func _test_plugin_edit_and_drag() -> void:
	for type in [_device_script.DeviceType.CLAP, _device_script.DeviceType.VST3]:
		_history.clear()
		var inst: Object = _make_plugin(type)
		_assert(inst.device.is_plugin(), "test device is a plugin")
		_actions.set_normalized(inst, 7, 0.4)
		_assert(_history.undo_count() == 1, "a plugin parameter edit is one step")
		_actions.begin_gesture()
		for v in [0.5, 0.6, 0.7]:
			_actions.set_normalized(inst, 4096, v)
		_actions.end_gesture()
		_assert(_history.undo_count() == 2, "a plugin drag is one step (got %d)" % _history.undo_count())
		_history.undo()
		_assert(is_equal_approx(inst.get_parameter_normalized(4096), 0.0), "undo restores the value before the plugin drag")
		_history.redo()
		_assert(is_equal_approx(inst.get_parameter_normalized(4096), 0.7), "redo reapplies the end of the plugin drag")
		_actions.set_real(inst, 7, 10.0)
		_assert(is_equal_approx(inst.get_parameter_normalized(7), 1.0), "set_real works on plugin parameters")


func _test_plugin_undo_redo_use_normal_path() -> void:
	_history.clear()
	var inst: Object = _make_plugin()
	_actions.set_normalized(inst, 7, 0.5)
	var before: int = _sent_values(7).size()
	var emitted: Array = []
	inst.parameter_changed.connect(func(id, v): emitted.append([id, v]))
	_history.undo()
	var sent: Array = _sent_values(7)
	_assert(sent.size() == before + 1 and is_equal_approx(float(sent[-1]), 0.0), "undo sends the old value to the engine/plugin over OSC")
	_assert(emitted.size() == 1 and emitted[0][0] == 7, "undo emits parameter_changed so views follow")
	_history.redo()
	sent = _sent_values(7)
	_assert(sent.size() == before + 2 and is_equal_approx(float(sent[-1]), 0.5), "redo sends the new value over OSC")
	_assert(_history.undo_count() == 1 and _history.redo_count() == 0, "undo/redo of a plugin edit add no steps")


func _test_plugin_echoes_record_nothing() -> void:
	_history.clear()
	var inst: Object = _make_plugin()
	_actions.set_normalized(inst, 7, 0.4)
	var before: int = _history.undo_count()
	inst._on_parameter_value_received([0.4], 7)  # echo of our edit
	inst._on_parameter_value_received([0.8], 7)  # change made in the plugin's own GUI or automation
	inst._on_parameter_value_received([0.3], 4096)
	_assert(is_equal_approx(inst.get_parameter_normalized(7), 0.8), "plugin-originated value reached the model")
	_assert(_history.undo_count() == before and _history.redo_count() == 0, "plugin echoes and plugin-side changes record no step")
	_history.undo()
	_assert(is_equal_approx(inst.get_parameter_normalized(7), 0.0), "undo still returns to the value before our edit")


func _test_plugin_shares_history_with_builtin() -> void:
	_history.clear()
	var plugin: Object = _make_plugin()
	var builtin: Object = _make_instance()
	_actions.set_normalized(builtin, 0, 0.3)
	_actions.set_normalized(plugin, 7, 0.6)
	_actions.set_normalized(builtin, 1, 0.9)
	_assert(_history.undo_count() == 3, "built-in and plugin edits share one history")
	_history.undo()
	_assert(is_equal_approx(builtin.get_parameter_normalized(1), 0.0) and is_equal_approx(plugin.get_parameter_normalized(7), 0.6), "undo reverts the newest (built-in) edit first")
	_history.undo()
	_assert(is_equal_approx(plugin.get_parameter_normalized(7), 0.0) and is_equal_approx(builtin.get_parameter_normalized(0), 0.3), "next undo reverts the plugin edit")
	_history.redo()
	_assert(is_equal_approx(plugin.get_parameter_normalized(7), 0.6), "redo reapplies the plugin edit")
	# A gesture on one device never merges into another's step.
	_history.clear()
	_actions.begin_gesture()
	_actions.set_normalized(builtin, 0, 0.2)
	_actions.set_normalized(plugin, 7, 0.2)
	_actions.end_gesture()
	_assert(_history.undo_count() == 2, "one gesture touching two devices keeps a step per device")
