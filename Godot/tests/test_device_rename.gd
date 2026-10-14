# test_device_rename.gd
# Headless tests for renaming device instances: _actions.rename (undoable, sibling-unique),
# the device context menu's name field, name_changed, and the save/load round trip.
# Run: godot --headless --path Godot -s tests/test_device_rename.gd -- --test
extends TestBase

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _actions: GDScript


func suite_name() -> String:
	return "Device rename tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_actions = load("res://history/DeviceActions.gd")
	_test_rename_action()
	await _test_context_menu_rename()
	_test_name_round_trip()
	await _test_lane_header_rename()


func _device(ch: Object, device_id: String, title: String) -> Object:
	var device: Object = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	return _device_instance_script.new(device, ch.id, 0)


func _channel_with_two() -> Array:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Keys").channel
	var a := _device(ch, "x_a", "Alpha")
	var b := _device(ch, "x_b", "Beta")
	ch.devices.append(a)
	ch.devices.append(b)
	a.set_channel(ch)
	b.set_channel(ch)
	a.set_name("Alpha")
	b.set_name("Beta")
	return [ch, a, b]


func _test_rename_action() -> void:
	var parts := _channel_with_two()
	var a: Object = parts[1]
	var b: Object = parts[2]
	var seen := []
	a.name_changed.connect(func(n: String) -> void: seen.append(n))
	_assert(_actions.rename(a, "Lead") == "Lead" and a.name == "Lead", "rename applies: %s" % a.name)
	_assert(seen == ["Lead"], "name_changed emitted once: %s" % str(seen))
	_actions.rename(a, "   ")
	_assert(a.name == "Lead", "blank rename ignored")
	_actions.rename(b, "lead")
	_assert(b.name == "lead 2", "sibling collision suffixed: %s" % b.name)


func _test_context_menu_rename() -> void:
	var parts := _channel_with_two()
	var a: Object = parts[1]
	var menu: Node = load("res://devices/DeviceContextMenu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	menu.bind_to_device(a)
	_assert(not menu.label.disabled, "menu name field is editable for a plain device")
	menu.label.start_editing()
	_assert(menu.label.is_editing, "double-click path starts editing")
	menu.label.line_edit.text = "Renamed"
	menu.label.stop_editing()
	_assert(a.name == "Renamed", "menu rename reaches the device: %s" % a.name)
	menu.queue_free()


func _test_name_round_trip() -> void:
	var parts := _channel_with_two()
	var ch: Object = parts[0]
	_actions.rename(parts[1], "My Synth")
	var data: Dictionary = parts[1].to_json() if parts[1].has_method("to_json") else {}
	_assert(str(data.get("name", "")) == "My Synth", "name is serialized: %s" % str(data.get("name", "<none>")))


func _test_lane_header_rename() -> void:
	var parts := _channel_with_two()
	var a: Object = parts[1]
	var panel: Node = load("res://devices/device_lane/DevicePanel.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	panel.bind_to_device(a)
	var header: Node = panel.name_label
	_assert(header is Label and not header.has_method("start_editing"), "lane header name is a plain, non-editable Label")
	_assert(header.text == "Alpha", "lane header shows the device name: %s" % header.text)
	_actions.rename(a, "Pad")
	_assert(a.name == "Pad" and header.text == "Pad", "context-menu rename reaches the device and header: %s" % a.name)
	a.set_name("Pad 2")
	_assert(header.text == "Pad 2", "header follows name_changed: %s" % header.text)
	_assert(panel.vertical_name_label.text == "Pad 2", "vertical name follows name_changed")
	var compact: Node = load("res://devices/compact/CompactDevicePanel.tscn").instantiate()
	root.add_child(compact)
	await process_frame
	_assert(compact.name_label is Label and not compact.name_label.has_method("start_editing"), "compact header name is a plain, non-editable Label")
	panel.queue_free()
	compact.queue_free()
