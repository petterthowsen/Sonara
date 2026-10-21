# test_step_sequencer_view.gd
# Spec 039 (REQ-002, REQ-003, REQ-012..014, REQ-016..018): the Step Sequencer panel view.
# Run: godot --headless --path Godot -s tests/test_step_sequencer_view.gd -- --test
extends TestBase

const VIEW_SCRIPT := "res://devices/builtin/StepSequencerDefaultView.gd"
const DEVICE_ID := "sonara.builtin.step_sequencer"

var _device_script: GDScript
var _instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript
var _factory: GDScript


func suite_name() -> String:
	return "Step Sequencer view"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_project_script = load("res://data/Project.gd")
	_param_script = load("res://data/DeviceParameter.gd")
	_factory = load("res://devices/DeviceViewFactory.gd")
	var device := _make_device()
	var instance := _make_instance(device)
	_test_factory(instance)
	_test_layout_and_sync(instance)
	_test_live(instance)
	_test_pitch_range(instance)


func _param(id: int, name: String, type := "float", lo := 0.0, hi := 1.0, default_v := 0.0, values: Array = []) -> Object:
	var p: Object = _param_script.new(id, name)
	p.param_type = type
	p.min_value = lo
	p.max_value = hi
	p.default_value = default_v
	p.enum_values.assign(values)
	return p


func _make_device() -> Object:
	var device: Object = _device_script.new(DEVICE_ID, "Step Sequencer",
		_device_script.DeviceCategory.NoteEffect, _device_script.DeviceType.BuiltIn)
	device.add_parameter(_param(0, "Length", "float", 1, 16, 4))
	device.add_parameter(_param(1, "Mode", "enum", 0, 1, 0, ["Chord", "Mono"]))
	device.add_parameter(_param(2, "Velocity Source", "enum", 0, 1, 0, ["In x Step", "Step"]))
	device.add_parameter(_param(10, "Rate", "enum", 0, 4, 0, ["1/4", "1/8", "1/16", "1/32"]))
	device.add_parameter(_param(11, "Gate", "float", 10, 200, 100))
	device.add_parameter(_param(12, "Swing", "float", 0, 75, 0))
	for k in 16:
		device.add_parameter(_param(100 + 10 * k, "On", "bool", 0, 1, 1))
		device.add_parameter(_param(101 + 10 * k, "Pitch", "float", -24, 24, 0))
		device.add_parameter(_param(102 + 10 * k, "Velocity", "float", 0, 100, 100))
		device.add_parameter(_param(103 + 10 * k, "Chance", "float", 0, 100, 100))
	_factory.register_builtin_views(device)
	root.get_node("AssetService").device_registry._devices[device.device_id] = device
	return device


func _make_instance(device: Object) -> Object:
	var project: Object = _project_script.new()
	var channel: Object = project.create_instrument_track("Seq").channel
	return _instance_script.new(device, channel.id, 0)


func _test_factory(instance: Object) -> void:
	_assert(instance.device.has_panel_view(), "the Step Sequencer has its own panel view")
	var sonara := root.get_node("Sonara")
	var key := "devices/simple_view/%s" % DEVICE_ID
	var was: Variant = sonara.get_config(key, false)
	sonara.set_config(key, false)
	var view: Node = _factory.create(instance, _device_script.ViewType.Panel)
	_assert(view != null and view.get_script().resource_path == VIEW_SCRIPT, "Simple off: the factory returns the step view")
	if view:
		view.free()
	sonara.set_config(key, true)
	view = _factory.create(instance, _device_script.ViewType.Panel)
	_assert(view != null and view.get_script().resource_path == "res://devices/simple_view/SimpleView.gd",
			"Simple on: the factory returns the SimpleView")
	if view:
		view.free()
	sonara.set_config(key, was)


func _bound_view(instance: Object) -> Object:
	var view: Control = load("res://devices/builtin/StepSequencerDefaultView.tscn").instantiate()
	root.add_child(view)
	view.bind_to_device(instance)
	return view


func _test_layout_and_sync(instance: Object) -> void:
	var view: Object = _bound_view(instance)
	# REQ-002: six shared controls, 16 columns per lane, fits the panel.
	for control in [view.length_slider, view.rate_option, view.gate_slider, view.swing_slider,
			view.mode_control, view.velocity_source_control]:
		_assert(control != null, "a shared control exists")
	for lane in [view.on_lane, view.pitch_lane, view.lower_lane]:
		_assert(lane.step_count == 16, "each lane has 16 columns")
	_assert(view.get_combined_minimum_size().y <= 350.0 - 40.0, "minimum height fits the panel (%s)" % view.get_combined_minimum_size())
	_assert(view.rate_option.item_count == 4, "Rate lists the enum values")

	# REQ-003: Velocity by default; Chance redraws and edits Chance.
	instance.set_parameter_real(102 + 10 * 6, 40.0)
	instance.set_parameter_real(103 + 10 * 6, 25.0)
	_assert(is_equal_approx(view.lower_lane.get_value_at(6), 40.0), "REQ-014: step 7 Velocity 40 % redraws")
	view.lower_switch.selected_changed.emit(1)
	_assert(is_equal_approx(view.lower_lane.get_value_at(6), 25.0), "REQ-003: Chance redraws the lane")
	view.lower_lane.value_edited.emit(2, 55.0)
	_assert(is_equal_approx(instance.get_parameter_real(103 + 20), 55.0), "a drag in Chance edits Chance")
	_assert(is_equal_approx(instance.get_parameter_real(102 + 20), 100.0), "Velocity is untouched")
	instance.set_parameter_real(102 + 10 * 6, 10.0)
	_assert(is_equal_approx(view.lower_lane.get_value_at(6), 25.0), "a Velocity change doesn't redraw the Chance lane")
	view.lower_switch.selected_changed.emit(0)
	_assert(is_equal_approx(view.lower_lane.get_value_at(6), 10.0), "back to Velocity")

	# Pitch edit goes through the device.
	view.pitch_lane.value_edited.emit(3, -9.0)
	_assert(is_equal_approx(instance.get_parameter_real(101 + 30), -9.0), "a Pitch edit writes the step parameter")

	# REQ-013: Length.
	instance.set_parameter_real(0, 6.0)
	for lane in [view.on_lane, view.pitch_lane, view.lower_lane]:
		_assert(lane.length == 6 and lane.is_beyond_length(6) and not lane.is_beyond_length(5), "Length 6 sets the lane length")

	# REQ-012: On edit updates off_mask but not other values.
	view.on_lane.value_edited.emit(2, 0.0)
	_assert(is_equal_approx(instance.get_parameter_real(100 + 20), 0.0), "the On row writes 0")
	_assert(view.pitch_lane.off_mask == 1 << 2 and view.lower_lane.off_mask == 1 << 2, "an On edit updates off_mask")
	view.pitch_lane.value_edited.emit(2, 7.0)
	_assert(instance.get_parameter_real(100 + 20) < 0.5, "drawing a bar leaves the step Off")
	view.on_lane.value_edited.emit(2, 1.0)
	_assert(view.pitch_lane.off_mask == 0, "On again clears the mask")

	# Left column.
	view.rate_option.item_selected.emit(2)
	_assert(is_equal_approx(instance.get_parameter_real(10), 2.0), "Rate selection writes the parameter")
	instance.set_parameter_real(11, 150.0)
	_assert(is_equal_approx(view.gate_slider.value, 150.0), "Gate follows the device")
	view.queue_free()


func _test_pitch_range(instance: Object) -> void:
	var store := {}
	var view: Control = load("res://devices/builtin/StepSequencerDefaultView.tscn").instantiate()
	view.load_config = func(key: String) -> Variant: return store.get(key, 24)
	view.save_config = func(key: String, value: Variant) -> void: store[key] = value
	root.add_child(view)
	view.bind_to_device(instance)
	_assert(view.pitch_lane.max_value == 24.0 and view.pitch_lane.min_value == -24.0, "the Pitch lane defaults to +-24")
	view.range_control.selected_changed.emit(1)
	_assert(view.pitch_lane.max_value == 12.0 and view.pitch_lane.min_value == -12.0, "the toggle narrows the lane to +-12")
	_assert(store.get(view.RANGE_CONFIG_KEY) == 12, "the choice is saved to the app config")
	_assert(is_equal_approx(instance.get_parameter(101).min_value, -24.0), "the parameter range is untouched")
	view.queue_free()
	var again: Control = load("res://devices/builtin/StepSequencerDefaultView.tscn").instantiate()
	again.load_config = func(key: String) -> Variant: return store.get(key, 24)
	again.save_config = func(_k: String, _v: Variant) -> void: pass
	root.add_child(again)
	again.bind_to_device(instance)
	_assert(again.pitch_lane.max_value == 12.0 and again.range_control.selected == 1, "a new view restores +-12")
	again.queue_free()
	_assert(view.lower_lane.custom_minimum_size.y <= 36.0 and StepLane.MIN_COLUMN_WIDTH == 24.0, "lower lanes are shorter and steps wider")


func _test_live(instance: Object) -> void:
	var view: Object = _bound_view(instance)
	var clock := [1000.0]
	view.now_ms_provider = func() -> float: return clock[0]
	view.latency_provider = func() -> float: return 0.0
	view.show_view()
	var path: String = instance.osc_path()
	_assert(view._subscribed_path == path, "REQ-018: shown view subscribes to its path")
	var osc := root.get_node("AudioEngineOSC")
	_assert(osc.device_data_received.is_connected(view._on_data), "the data signal is connected while shown")

	# step 2 (0-based), fired 3rd step (bit 2): blob = prefix + reached, fired, timing.
	var blob := _blob(2, 1 << 2, 10, 100)
	view._on_data(path, "note_state", blob)
	_assert(view.on_lane.playhead == 2 and view.number_row.playhead == 2, "the playhead lands on step 2")
	_assert(view.pitch_lane._flash[2] > 0.0, "a fired step flashes")
	_assert(view.pitch_lane._flash[1] == 0.0, "other steps don't")
	clock[0] += 200.0
	view._tick(clock[0])
	_assert(view.pitch_lane._flash[2] == 0.0, "the flash decays away")

	view._on_data("/channel/999/device/9", "note_state", _blob(5, 0, 10, 100))
	_assert(view.on_lane.playhead != 5, "a blob for another device is ignored")

	view.hide_view()
	_assert(view._subscribed_path == "" and not osc.device_data_received.is_connected(view._on_data), "hiding unsubscribes")
	_assert(view.on_lane.playhead == -1 and view.number_row.playhead == -1, "hiding clears the playhead")
	_assert(not view.is_processing(), "hiding stops _process")
	view.queue_free()


func _blob(step: int, fired: int, elapsed: int, next_in: int) -> PackedByteArray:
	var b := PackedByteArray([step, 60, 0xFF, 1, 60])
	for v in [fired, fired, elapsed, next_in, 125, 125]:
		b.append(v & 0xFF)
		b.append((v >> 8) & 0xFF)
	return b
