# test_context_menu_name_width.gd
# A long name widens the mixer channel menu and the track menu instead of running under the
# colour picker button.
# Run: godot --headless --path Godot -s tests/test_context_menu_name_width.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Context menu name width tests"


func run_tests() -> void:
	await _test_menu("res://mixer/ChannelContextMenu.tscn", "color_picker", "label")
	await _test_menu("res://arranger/tracklist/TrackItemContextMenu.tscn", "color_picker_button", "name_label")
	await _test_device_menu()


func _test_menu(path: String, button_prop: String, name_prop: String) -> void:
	var menu: PopupPanel = (load(path) as PackedScene).instantiate()
	root.add_child(menu)
	menu.hide()
	await process_frame
	var button: Control = menu.get(button_prop)
	var name_edit: SmartLineEdit = menu.get(name_prop)
	var base_w := menu.get_contents_minimum_size().x

	name_edit.set_value("A very long channel name that must not run under the colour button at all")
	await process_frame
	var need: float = name_edit.label.get_minimum_size().x + button.get_combined_minimum_size().x
	var min_w: float = menu.get_contents_minimum_size().x
	_assert(name_edit.get_combined_minimum_size().x >= name_edit.label.get_minimum_size().x, "%s: name counts toward its minimum" % path)
	_assert(min_w >= need, "%s: menu min width %s >= name + button %s" % [path, min_w, need])
	_assert(min_w > base_w, "%s: menu grew (%s -> %s)" % [path, base_w, min_w])

	menu.popup(Rect2i(0, 0, 10, 10))
	await process_frame
	_assert(menu.size.x >= need, "%s: popup width %s fits the name" % [path, menu.size.x])
	menu.hide()
	menu.queue_free()



## The device menu has no colour button: its name field alone must widen the popup.
func _test_device_menu() -> void:
	var menu: PopupPanel = (load("res://devices/DeviceContextMenu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	menu.hide()
	await process_frame
	var base_w := menu.get_contents_minimum_size().x
	(menu.get("label") as SmartLineEdit).set_value("A very long device name that must not be clipped by the device context menu")
	await process_frame
	var need: float = (menu.get("label") as SmartLineEdit).label.get_minimum_size().x
	var min_w: float = menu.get_contents_minimum_size().x
	_assert(min_w >= need, "device menu: min width %s >= name %s" % [min_w, need])
	_assert(min_w > base_w, "device menu: grew (%s -> %s)" % [base_w, min_w])
	menu.popup(Rect2i(0, 0, 10, 10))
	await process_frame
	_assert(menu.size.x >= need, "device menu: popup width %s fits the name" % menu.size.x)
	menu.hide()
	menu.queue_free()
