# test_settings_registry.gd
# Headless tests for the Settings registry API (Setting builder helpers,
# sub-categories, category filtering, coercion and the custom control_scene hook).
# Run: godot --headless --path Godot -s tests/test_settings_registry.gd -- --test
extends TestBase

# Settings is an autoload; bare "Settings" doesn't resolve when this script is
# itself the main loop script, so fetch the singleton node instead. SettingRow.gd
# references the Sonara autoload directly in its body, so it must be load()-ed
# lazily too (after TestBase's process_frame await), not referenced by its
# class_name at parse time, or it fails to compile in this standalone context.
var _settings
var _setting_row_script


func suite_name() -> String:
	return "Settings registry tests"


func run_tests() -> void:
	_settings = root.get_node("Settings")
	_setting_row_script = load("res://settings/SettingRow.gd")
	_test_builder_helpers()
	_test_sub_categories()
	_test_categories_hide_empty()
	_test_coerce_clamps()
	_test_coerce_color()
	_test_color_row()
	_test_theme_settings()
	_test_type_enum_parity()
	_test_custom_control_scene()
	_test_search()
	_test_grid_spacing_defaults()
	_test_device_frame_settings()
	_test_available_if()
	_test_unavailable_row_disabled()


## The two grid spacing settings exist with their intended defaults; the MIDI
## editor's key is what its ClipEditor GridHelper instance follows.
func _test_grid_spacing_defaults() -> void:
	var arranger = _settings.get_setting("appearance/grid_min_line_spacing")
	var midi = _settings.get_setting("appearance/midi_editor_min_line_spacing")
	_assert(arranger != null and arranger.default == 10,
		"the arranger grid spacing defaults to 10")
	_assert(midi != null and midi.default == 16,
		"the MIDI editor grid spacing defaults to 16")
	_assert(midi.min_val == arranger.min_val and midi.max_val == arranger.max_val,
		"both share the same pixel range (%d-%d)" % [arranger.min_val, arranger.max_val])


func _test_builder_helpers() -> void:
	var s = _settings.Setting.new("test/builder", "Builder", _settings.Type.INT, 0, _settings.CATEGORY_BEHAVIOR)
	var ret = s.range(1, 10, 2)
	_assert(ret == s, "range() returns the same Setting for chaining")
	_assert(s.min_val == 1 and s.max_val == 10 and s.step == 2, "range() sets min/max/step")

	ret = s.choices(["a", "b"])
	_assert(ret == s, "choices() returns the same Setting for chaining")
	_assert(s.options == ["a", "b"], "choices() sets options")

	ret = s.sub("Sub Name")
	_assert(ret == s, "sub() returns the same Setting for chaining")
	_assert(s.sub_category == "Sub Name", "sub() sets sub_category")


func _test_sub_categories() -> void:
	var subs: Array = _settings.get_sub_categories(_settings.CATEGORY_AI)
	_assert(subs == ["Connection", "Chat", "Audio", "Debug"],
		"AI sub-categories are Connection, Chat, Audio, Debug in registration order (got %s)" % [subs])


func _test_categories_hide_empty() -> void:
	var categories: Array = _settings.get_categories()
	_assert(categories.has("Audio"), "get_categories() shows Audio (plugin hosting is registered there)")
	_assert(categories.has("Shortcuts"), "get_categories() shows Shortcuts (one setting per hotkey action)")


func _test_coerce_clamps() -> void:
	var setting = _settings.get_setting("midi/virtual_keyboard/transpose")
	var coerced = _settings._coerce(setting, 99)
	_assert(coerced == 24, "transpose clamps 99 down to its max of 24")


func _test_coerce_color() -> void:
	var s = _settings.Setting.new("test/color", "Colour", _settings.Type.COLOR, "#2b2b2b", _settings.CATEGORY_APPEARANCE)
	_assert(_settings._coerce(s, Color(1, 0, 0)) == "#ff0000", "a Color is stored as a hex string")
	_assert(_settings._coerce(s, "#abc123") == "#abc123", "a valid hex string is unchanged")
	_assert(_settings._coerce(s, "nope") == "#2b2b2b", "an invalid string falls back to the default")
	_assert(_settings._coerce(s, 42) == "#2b2b2b", "a non-colour value falls back to the default")


## A COLOR row builds a ColorPickerButton without alpha, reads back a hex string and applies one.
func _test_color_row() -> void:
	var scene: PackedScene = load("res://settings/SettingRow.tscn")
	var row = scene.instantiate()
	root.add_child(row)
	var setting = _settings.Setting.new("test/color_row", "Colour", _settings.Type.COLOR, "#2b2b2b", _settings.CATEGORY_APPEARANCE)
	row._settings = null
	row.bind(setting)
	var picker := row.find_children("*", "ColorPickerButton", true, false)
	_assert(picker.size() == 1, "a COLOR row builds one ColorPickerButton")
	if picker.size() == 1:
		_assert(not picker[0].edit_alpha, "the colour picker has no alpha")
		_assert(row.get_current_value() == "#2b2b2b", "the row reads back the default as hex")
		row.set_value_no_signal("#336699")
		_assert(row.get_current_value() == "#336699", "set_value_no_signal applies a hex string")
	row.queue_free()


func _test_theme_settings() -> void:
	var keys := ["main_color", "accent_primary", "accent_secondary", "record_color", "solo_color",
		"mute_color", "corner_radius", "spacing"]
	for k in keys:
		var s = _settings.get_setting("appearance/theme/" + k)
		_assert(s != null and s.category == "Appearance" and s.sub_category == "Theme",
			"theme setting '%s' is registered under Appearance > Theme" % k)
	var radius = _settings.get_setting("appearance/theme/corner_radius")
	var spacing = _settings.get_setting("appearance/theme/spacing")
	_assert(radius.default == 2 and radius.min_val == 0 and radius.max_val == 4, "corner radius defaults to 2, range 0-4")
	_assert(spacing.default == 2 and spacing.min_val == 1 and spacing.max_val == 4, "spacing defaults to 2, range 1-4")
	_assert(_settings.get_setting("appearance/theme/accent_primary").default == "#624d99", "primary accent default is #624d99")
	_assert(_settings.get_setting("appearance/theme/main_color").type == _settings.Type.COLOR, "main colour is a COLOR setting")

	var before := {}
	for k in keys:
		before[k] = _settings.get_value("appearance/theme/" + k)
	_settings.set_value("appearance/theme/main_color", "#101820")
	_settings.set_value("appearance/theme/accent_primary", "#ff0000")
	_settings.set_value("appearance/theme/corner_radius", 4)
	_settings.set_value("appearance/theme/spacing", 3)
	_assert(_settings.get_value("appearance/theme/spacing") == 3, "a theme setting can be changed")
	_settings.reset_theme()
	for k in keys:
		_assert(_settings.get_value("appearance/theme/" + k) == _settings.get_setting("appearance/theme/" + k).default,
			"reset_theme restores '%s'" % k)
	# Leave the user's real config as it was.
	for k in keys:
		_settings.set_value("appearance/theme/" + k, before[k])


func _test_type_enum_parity() -> void:
	_assert(_settings.Type.size() == _setting_row_script.Type.size(),
		"Settings.Type and SettingRow.Type have the same number of entries")
	for key in _settings.Type.keys():
		_assert(_setting_row_script.Type.has(key), "SettingRow.Type has a '%s' entry matching Settings.Type" % key)


func _test_custom_control_scene() -> void:
	var scene: PackedScene = load("res://settings/SettingRow.tscn")
	var row = scene.instantiate()
	root.add_child(row)

	var setting = _settings.Setting.new(
		"test/dummy_scene_setting", "Dummy", _settings.Type.STRING, "default", _settings.CATEGORY_BEHAVIOR
	).scene("res://tests/fixtures/DummySettingControl.tscn")
	row.bind(setting)
	row.set_value_no_signal("from scene")
	_assert(row.get_current_value() == "from scene",
		"get_current_value() reads through the custom control_scene widget")

	row.detach()
	root.remove_child(row)
	row.queue_free()


func _test_search() -> void:
	_assert(_settings.search("").is_empty(), "search(\"\") returns no results")

	var velocity_results: Array = _settings.search("velocity")
	_assert(not velocity_results.is_empty() and velocity_results[0].key == "midi/virtual_keyboard/velocity",
		"search('velocity') puts midi/virtual_keyboard/velocity first (got %s)" %
		[velocity_results[0].key if not velocity_results.is_empty() else "<empty>"])

	var openrouter_results: Array = _settings.search("openrouter")
	var openrouter_keys: Array = []
	for s in openrouter_results:
		openrouter_keys.append(s.key)
	_assert(openrouter_keys.has("ai/openrouter/api_key") and openrouter_keys.has("ai/openrouter/base_url")
		and openrouter_keys.has("ai/openrouter/model"),
		"search('openrouter') includes the AI connection settings (got %s)" % [openrouter_keys])

	_assert(_settings.search("qqqzzz").is_empty(), "search('qqqzzz') returns no results")

	var first_call: Array = _settings.search("a")
	var second_call: Array = _settings.search("a")
	var first_keys: Array = []
	var second_keys: Array = []
	for s in first_call:
		first_keys.append(s.key)
	for s in second_call:
		second_keys.append(s.key)
	_assert(first_keys == second_keys, "search results are stable across two calls")


## Spec 022: the window grouping and plugin embedding settings, and the frame toggle shortcut.
func _test_device_frame_settings() -> void:
	var grouping = _settings.get_setting("devices/window_grouping")
	_assert(grouping != null and grouping.type == _settings.Type.CHOICE and grouping.default == "Per channel"
		and grouping.options == ["Per channel", "Per device"] and grouping.category == _settings.CATEGORY_BEHAVIOR,
		"devices/window_grouping is a Behavior choice defaulting to Per channel")
	var embed = _settings.get_setting("plugins/embed_gui")
	_assert(embed != null and embed.type == _settings.Type.BOOL and embed.default == false
		and embed.category == _settings.CATEGORY_AUDIO and embed.sub_category == "Plugins",
		"plugins/embed_gui is an Audio > Plugins bool, off by default")
	_assert(_settings.is_available("plugins/embed_gui") == (DisplayServer.get_name() == "X11"),
		"plugins/embed_gui is available only on X11 (display server: %s)" % DisplayServer.get_name())
	_assert(_settings.is_available("devices/window_grouping"), "a setting without available_if is available")
	_assert(InputMap.has_action("toggle_device_frame"), "the toggle_device_frame action exists")


func _test_available_if() -> void:
	var s = _settings.Setting.new("test/avail", "Avail", _settings.Type.BOOL, false, _settings.CATEGORY_BEHAVIOR)
	_assert(s.is_available(), "a setting is available by default")
	var on := [true]
	var ret = s.available_if(func() -> bool: return on[0], "Needs a thing.")
	_assert(ret == s, "available_if() returns the same Setting for chaining")
	_assert(s.is_available() and s.unavailable_reason == "Needs a thing.", "available while the check passes")
	on[0] = false
	_assert(not s.is_available(), "unavailable once the check fails")


func _test_unavailable_row_disabled() -> void:
	var scene: PackedScene = load("res://settings/SettingRow.tscn")
	var row = scene.instantiate()
	root.add_child(row)
	# Registered for the duration, so the row can read a value for them
	var setting = _settings._register(_settings.Setting.new(
		"test/unavailable_setting", "Unavailable", _settings.Type.BOOL, false, _settings.CATEGORY_BEHAVIOR, "Some help."
	)).available_if(func() -> bool: return false, "Needs X11.")
	var available = _settings._register(_settings.Setting.new(
		"test/available_setting", "Available", _settings.Type.BOOL, false, _settings.CATEGORY_BEHAVIOR))
	row.bind(setting)
	_assert(row._editor_widget is CheckBox and row._editor_widget.disabled, "an unavailable setting's checkbox is disabled")
	_assert(row.help_label.visible and row.help_label.text.contains("Needs X11.") and row.help_label.text.contains("Some help."),
		"the row shows the reason under the help text (got '%s')" % row.help_label.text)

	row.bind(available)
	_assert(not row._editor_widget.disabled, "an available setting's checkbox is enabled")
	_settings._settings.erase(setting.key)
	_settings._settings.erase(available.key)
	row.detach()
	root.remove_child(row)
	row.queue_free()
