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

var _project: Object = null
var _channel: Object = null


func suite_name() -> String:
	return "Compact device panel tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")

	await _test_setup_on_ready_panel()
	await _test_setup_before_added_to_tree()


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
