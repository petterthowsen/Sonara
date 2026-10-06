# test_shortcut_control.gd
# Headless tests for the Settings > Shortcuts row control: key capture, Escape, clearing,
# conflict warnings, double-tap lines and chord search.
# Run: godot --headless --path Godot -s tests/test_shortcut_control.gd -- --test
extends TestBase

var _settings
var _hotkeys


func suite_name() -> String:
	return "Shortcut control tests"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_hotkeys = root.get_node("Hotkeys")
	await _test_capture()
	await _test_escape_and_clear()
	await _test_conflict_warning()
	await _test_double_tap_line()
	_test_chord_search()
	_test_reset_shortcuts()
	_settings.reset_shortcuts()


func _make_row(action_id: String):
	var row = load("res://settings/SettingRow.tscn").instantiate()
	root.add_child(row)
	row.bind(_settings.get_setting("shortcuts/" + action_id))
	await process_frame
	return row


func _free_row(row) -> void:
	row.detach()
	root.remove_child(row)
	row.queue_free()


func _key(keycode: Key, ctrl := false, shift := false, pressed := true) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	ev.pressed = pressed
	return ev


func _test_capture() -> void:
	_settings.reset_shortcuts()
	var row = await _make_row("edit_duplicate")
	var control = row._editor_widget
	control._buttons[0].pressed.emit()
	_assert(_hotkeys.capturing, "clicking a binding starts capture")
	control._input(_key(KEY_CTRL, true))
	_assert(control._buttons[0].text == "Ctrl+…", "a modifier-only press updates the label live")
	_assert(row.get_current_value() == ["Ctrl+D"], "modifier-only press doesn't change the value")
	control._input(_key(KEY_D, true, true))
	_assert(row.get_current_value() == ["Ctrl+Shift+D"], "capture stores Ctrl+Shift+D (got %s)" % [row.get_current_value()])
	_assert(not _hotkeys.capturing, "capture ends after the chord")
	_assert(_settings.get_value("shortcuts/edit_duplicate") == ["Ctrl+Shift+D"], "the chord is written to Settings")
	control._buttons[1].pressed.emit()
	control._input(_key(KEY_F5))
	_assert(row.get_current_value() == ["Ctrl+Shift+D", "F5"], "the secondary slot takes a second chord")
	_free_row(row)


func _test_escape_and_clear() -> void:
	_settings.reset_shortcuts()
	var row = await _make_row("edit_duplicate")
	var control = row._editor_widget
	control._buttons[0].pressed.emit()
	control._input(_key(KEY_ESCAPE))
	_assert(row.get_current_value() == ["Ctrl+D"], "Escape during capture leaves the value unchanged")
	_assert(not _hotkeys.capturing, "Escape ends capture")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	control._on_button_gui_input(click, 0)
	_assert(row.get_current_value() == [], "right-click clears the slot")
	_assert(_settings.get_value("shortcuts/edit_duplicate") == [], "an empty binding is stored, not the default")
	control._buttons[0].pressed.emit()
	_free_row(row)
	_assert(not _hotkeys.capturing, "freeing the control mid-capture resets capturing")


func _test_conflict_warning() -> void:
	_settings.reset_shortcuts()
	var row = await _make_row("edit_duplicate")
	var control = row._editor_widget
	_assert(control._warnings.get_child_count() == 0, "no warning for the default binding")
	control._buttons[0].pressed.emit()
	control._input(_key(KEY_D))
	_assert(control._warnings.get_child_count() == 1, "rebinding Duplicate to D shows one warning")
	var text: String = control._warnings.get_child(0).get_child(0).text
	_assert(text.contains("Show device lane"), "the warning names Show device lane (got '%s')" % text)
	control._unbind_other("toggle_device_lane")
	_assert(_settings.get_value("shortcuts/toggle_device_lane") == [], "Unbind there clears the other action")
	_assert(control._warnings.get_child_count() == 0, "the warning disappears after unbinding")
	_free_row(row)


func _test_double_tap_line() -> void:
	_settings.reset_shortcuts()
	var row = await _make_row("edit_select_all")
	var control = row._editor_widget
	_assert(control._double_taps.get_child_count() == 1
			and control._double_taps.get_child(0).text.begins_with("Ctrl+A ×2"),
		"select all lists its double tap")
	_settings.set_value("shortcuts/edit_select_all", ["Ctrl+L"])
	_assert(control._double_taps.get_child(0).text.begins_with("Ctrl+L ×2"),
		"the double-tap line follows the parent's binding")
	_free_row(row)


func _test_chord_search() -> void:
	_settings.reset_shortcuts()
	var keys: Array = []
	for s in _settings.search("ctrl+d"):
		keys.append(s.key)
	_assert(keys.has("shortcuts/edit_duplicate"), "searching 'ctrl+d' finds Duplicate")


func _test_reset_shortcuts() -> void:
	_settings.set_value("shortcuts/edit_undo", ["F9"])
	_settings.reset_shortcuts()
	_assert(_settings.get_value("shortcuts/edit_undo") == ["Ctrl+Z"], "reset_shortcuts restores defaults")
