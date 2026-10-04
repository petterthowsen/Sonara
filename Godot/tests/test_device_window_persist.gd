# Device windows (the floating popups opened from a device panel's Window
# toggle) are owned by the global DeviceWindowManager, keyed by DeviceInstance.
# The DeviceLane frees and rebuilds its panels on every track switch; an open
# window must survive that and keep living, and a fresh panel for the same
# device must show the window toggle pressed. Removing the device from its
# channel closes the window.
# Run: godot --headless --path Godot -s tests/test_device_window_persist.gd -- --test
extends TestBase

const EQ_ID := "sonara.builtin.eq"

var _device_panel_scene: PackedScene
var _device_script: GDScript
var _device_instance_script: GDScript
var _view_factory: GDScript
var _nodes: Array[Node] = []


func suite_name() -> String:
	return "Device window persistence"


func run_tests() -> void:
	# Lane, panel and manager reference autoloads, so load() instead of names.
	_device_panel_scene = load("res://devices/device_lane/DevicePanel.tscn")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_view_factory = load("res://devices/DeviceViewFactory.gd")

	await _test_window_survives_panel_rebuild()


## An EQ device instance with the built-in views attached (as DeviceRegistry does).
func _make_eq_instance() -> Object:
	var device = _device_script.new(EQ_ID, "EQ", _device_script.DeviceCategory.Effect)
	_view_factory.register_builtin_views(device)
	return _device_instance_script.new(device, 2, 0)


func _make_panel(inst: Object) -> Object:
	var panel = _device_panel_scene.instantiate()
	root.add_child(panel)
	_nodes.append(panel)
	panel.bind_to_device(inst)
	return panel


func _test_window_survives_panel_rebuild() -> void:
	var inst = _make_eq_instance()
	var manager = root.get_node("/root/DeviceWindowManager")
	var panel = _make_panel(inst)
	await process_frame

	_assert(panel.window_button.visible, "window toggle visible for EQ")
	_assert(not panel.window_button.button_pressed, "window toggle starts unpressed")

	# Open the window from the panel's toggle.
	panel.window_button.button_pressed = true
	await process_frame
	await process_frame
	_assert(manager.is_open(inst), "manager reports the window open")
	_assert(panel.window_button.button_pressed, "panel toggle pressed after opening")
	var popup: Window = null
	for child in root.get_children():
		if child is Window and child.name.begins_with("DeviceWindow_"):
			popup = child
	_assert(popup != null, "popup window exists under the root")
	_assert(popup.visible, "popup window visible")

	# Simulate a track switch: the old panel is freed, a new one binds the device.
	panel.queue_free()
	await process_frame
	await process_frame
	_assert(manager.is_open(inst), "window still open after the panel was freed")
	_assert(is_instance_valid(popup) and popup.visible, "popup survived the panel rebuild")

	var panel2 = _make_panel(inst)
	await process_frame
	_assert(panel2.window_button.button_pressed, "new panel's toggle reflects the open window")

	# Close from the new panel.
	panel2.window_button.button_pressed = false
	await process_frame
	await process_frame
	_assert(not manager.is_open(inst), "window closed from the new panel")
	_assert(not panel2.window_button.button_pressed, "toggle unpressed after closing")
	_assert(not is_instance_valid(popup) or not popup.visible, "popup gone after closing")
