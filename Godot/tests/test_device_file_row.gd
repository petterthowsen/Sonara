# The file row of a device that loads a file (SFZ, sample) sits inside the device view, not on
# a separate File tab; devices without file loading don't show it.
# Scripts are loaded by path (not referenced as types): compiling them at start-up happens
# before the autoloads exist.
extends TestBase

const PANEL_SCENE := "res://devices/device_lane/DevicePanel.tscn"

var _project: Object = null
var _device_script: GDScript
var _device_instance_script: GDScript


func suite_name() -> String:
	return "Device file row tests"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_project = load("res://data/Project.gd").new()
	await _test_file_device_shows_the_row_in_the_view_pane()
	await _test_plain_device_has_no_file_row()


func _panel_for(supports_file: bool) -> Control:
	var device: Object = _device_script.new("test.file_row.%s" % supports_file, "Test",
		_device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	device.supports_file_loading = supports_file
	device.file_type_description = "SFZ"
	device.supported_file_extensions.assign([".sfz"])
	root.get_node("AssetService").device_registry._devices[device.device_id] = device
	var channel: Object = _project.create_instrument_track("T").channel
	var instance: Object = _device_instance_script.new(device, channel.id, 0)
	var panel: Control = load(PANEL_SCENE).instantiate()
	root.add_child(panel)
	panel.position = Vector2(200, 200)
	await panel.bind_to_device(instance)
	for _i in 3:
		await process_frame
	return panel


func _test_file_device_shows_the_row_in_the_view_pane() -> void:
	var panel := await _panel_for(true)
	_assert(panel.file_row.visible, "file row shows for a device that loads files")
	_assert(panel.view_pane.is_ancestor_of(panel.file_row), "file row lives inside the view pane")
	_assert(panel.file_status_label.text == "No File Loaded", "file row starts empty")
	_assert(panel.find_child("File", true, false) == null, "no separate File tab or pane remains")
	panel.queue_free()


func _test_plain_device_has_no_file_row() -> void:
	var panel := await _panel_for(false)
	_assert(not panel.file_row.visible, "file row hidden without file loading")
	panel.queue_free()
