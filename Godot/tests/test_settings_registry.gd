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
	_test_type_enum_parity()
	_test_custom_control_scene()
	_test_search()


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
	_assert(not categories.has("Shortcuts"), "get_categories() hides Shortcuts (no registered settings)")


func _test_coerce_clamps() -> void:
	var setting = _settings.get_setting("midi/virtual_keyboard/transpose")
	var coerced = _settings._coerce(setting, 99)
	_assert(coerced == 24, "transpose clamps 99 down to its max of 24")


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
