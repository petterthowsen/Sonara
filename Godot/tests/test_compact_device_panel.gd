# test_compact_device_panel.gd
# CompactDevicePanel.setup() must work both when the panel is added to the tree
# before setup (ChannelDeviceList does this) and when it is set up while still
# outside the tree. The old unconditional `await ready` never resumed for an
# already-ready panel, so the second call silently stopped configuring it.
# Run: godot --headless --path Godot -s tests/test_compact_device_panel.gd -- --test
extends TestBase

const PANEL_SCENE := "res://devices/compact/CompactDevicePanel.tscn"

var _device_script: GDScript
var _device_instance_script: GDScript
var _project_script: GDScript
var _param_script: GDScript

var _project: Object = null
var _channel: Object = null


func suite_name() -> String:
	return "Compact device panel tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_param_script = load("res://data/DeviceParameter.gd")

	await _test_setup_on_ready_panel()
	await _test_setup_before_added_to_tree()
	await _test_chevron_needs_parameters_and_hover()
	await _test_value_hides_when_narrow()
	await _test_enum_does_not_widen()
	await _test_bool_is_one_row()


## A device instance for a built-in fake device, registered so nothing else trips over it.
func _device(device_id: String, title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title,
			_device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return _device_instance_script.new(device, _channel.id, 0)


func _new_channel(name: String) -> void:
	if _project == null:
		_project = _project_script.new()
		_channel = _project.create_instrument_track(name).channel
	else:
		_channel = _project.create_instrument_track(name).channel


func _test_setup_on_ready_panel() -> void:
	_new_channel("Ready Panel")
	var instance: Object = _device("sonara.builtin.fake_eq", "Fake EQ")

	var panel = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	await process_frame
	_assert(panel.is_node_ready(), "the panel is already ready before setup()")

	panel.setup(instance, 0)
	for _i in 3:
		await process_frame

	_assert(panel.name_label.get_value() == instance.get_display_name(),
		"setup() on a ready panel sets the name label (got '%s')" % panel.name_label.get_value())
	_assert(panel._param_list != null and panel._param_list.device == instance,
		"setup() on a ready panel binds the parameter list")
	_assert(panel.device_instance == instance, "setup() on a ready panel keeps the bound instance")

	panel.queue_free()


func _test_setup_before_added_to_tree() -> void:
	_new_channel("Late Panel")
	var instance: Object = _device("sonara.builtin.fake_reverb", "Fake Reverb")

	# The order ChannelDeviceList uses: instantiate, setup() (outside the tree), then add_child.
	var panel = load(PANEL_SCENE).instantiate()
	_assert(not panel.is_node_ready(), "a fresh panel is not ready yet")
	panel.setup(instance, 0)
	root.add_child(panel)
	for _i in 3:
		await process_frame

	_assert(panel.name_label.get_value() == instance.get_display_name(),
		"setup() before add_child still sets the name label (got '%s')" % panel.name_label.get_value())
	_assert(panel._param_list != null and panel._param_list.device == instance,
		"setup() before add_child still binds the parameter list")

	panel.queue_free()


## A device instance whose fake device has the given parameters.
func _device_with_params(device_id: String, params: Array) -> Object:
	var instance: Object = _device(device_id, device_id)
	if instance.device.parameters.is_empty():
		for param in params:
			instance.device.add_parameter(param)
	return instance


func _float_param(id: int, name: String) -> Object:
	var p: Object = _param_script.new(id, name)
	p.default_value = 0.5
	return p


## A ready panel at `width`, placed away from the headless pointer at (0, 0).
func _panel_for(instance: Object, width: float) -> Control:
	var panel = load(PANEL_SCENE).instantiate()
	panel.collapsed = false
	panel.hide_parameters = false
	root.add_child(panel)
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(200, 200)
	panel.size = Vector2(width, 0)
	panel.setup(instance, 0)
	for _i in 3:
		await process_frame
	return panel


func _param_controls(panel: Control) -> Array:
	return panel._param_list.get_children().filter(func(c): return not c.is_queued_for_deletion())


func _test_chevron_needs_parameters_and_hover() -> void:
	_new_channel("Chevron")
	var bare: Object = _device("sonara.builtin.fake_bare", "Fake Bare")
	var panel: Control = await _panel_for(bare, 160)
	_assert(not panel.collapse_button.visible, "no chevron for a device without parameters")
	_assert(not panel.parameters.visible, "no parameters panel for a device without parameters")
	panel.queue_free()

	var instance: Object = _device_with_params("sonara.builtin.fake_chevron", [_float_param(0, "Gain")])
	panel = await _panel_for(instance, 160)
	_assert(not panel.collapse_button.visible, "the chevron is hidden (and takes no space) at rest")
	panel.mouse_entered.emit()
	_assert(panel.collapse_button.visible, "the chevron shows on hover")
	panel.mouse_exited.emit()
	_assert(not panel.collapse_button.visible, "the chevron hides again after hover")
	_assert(panel.parameters.mouse_filter != Control.MOUSE_FILTER_STOP,
		"the parameters panel doesn't cut the device panel out of the hover chain")
	panel.queue_free()


func _test_value_hides_when_narrow() -> void:
	_new_channel("Value")
	var instance: Object = _device_with_params("sonara.builtin.fake_value",
		[_float_param(0, "Dynamics Compression Amount")])
	var panel: Control = await _panel_for(instance, 120)
	var control: Object = _param_controls(panel)[0]
	var min_width := panel.get_combined_minimum_size().x
	_assert(not control.value_label_node.visible, "the value hides when name and value don't fit")
	control.slider_node.mouse_entered.emit()
	_assert(control.value_label_node.visible, "hovering the slider shows the value")
	_assert(panel.get_combined_minimum_size().x <= min_width,
		"showing the value never widens the panel (min %.1f, was %.1f)" % [panel.get_combined_minimum_size().x, min_width])
	control.slider_node.mouse_exited.emit()
	control.slider_node.drag_started.emit()
	_assert(control.value_label_node.visible, "dragging the slider shows the value")
	control.slider_node.drag_ended.emit()
	_assert(not control.value_label_node.visible, "the value hides again after the drag")
	panel.queue_free()

	var short: Object = _device_with_params("sonara.builtin.fake_short", [_float_param(0, "Mix")])
	panel = await _panel_for(short, 200)
	control = _param_controls(panel)[0]
	_assert(control.value_label_node.visible, "the value shows at rest when it fits")
	panel.queue_free()


func _test_enum_does_not_widen() -> void:
	_new_channel("Enum")
	var p: Object = _param_script.new(0, "Articulation")
	p.param_type = "enum"
	p.enum_values.assign(["Sustain", "A Very Long Articulation Name That Would Widen The Strip"])
	p.max_value = 1.0
	var instance: Object = _device_with_params("sonara.builtin.fake_enum", [p])
	var panel: Control = await _panel_for(instance, 120)
	var control: Object = _param_controls(panel)[0]
	_assert(control.option_node != null and control.option_node.visible, "enums use a dropdown")
	_assert(not control.value_label_node.visible, "enums show no separate value")
	control.option_node.select(1)
	await process_frame
	_assert(panel.get_combined_minimum_size().x <= 120.0,
		"a long enum item doesn't widen the panel (min %.1f)" % panel.get_combined_minimum_size().x)
	panel.queue_free()


func _test_bool_is_one_row() -> void:
	_new_channel("Bool")
	var p: Object = _param_script.new(0, "Bypass Filter")
	p.param_type = "bool"
	var instance: Object = _device_with_params("sonara.builtin.fake_bool", [p])
	var panel: Control = await _panel_for(instance, 160)
	var control: Object = _param_controls(panel)[0]
	_assert(control.checkbox_node is CheckButton, "bools use a CheckButton")
	_assert(control.checkbox_node.get_parent() == control.label_node.get_parent(),
		"the toggle shares the name's row")
	_assert(not control.slider_node.visible and not control.value_label_node.visible,
		"bools show no slider and no value text")
	panel.queue_free()
