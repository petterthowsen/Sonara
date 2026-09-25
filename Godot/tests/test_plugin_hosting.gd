# test_plugin_hosting.gd
# Headless tests for PluginHosting (engine-stability-plan Phase 5): the /plugins/hosting
# message carries the global mode as its engine name plus sorted (plugin_id, mode) override
# pairs, and "always host individually" toggles an override. Also checks that a device's
# /host status fills in its host info and tooltip line.
#
# Sonara.save_config() writes the real config file, so the suite points it at a scratch file
# under user:// and restores the in-memory config afterwards.
# Run: godot --headless --path Godot -s tests/test_plugin_hosting.gd -- --test
extends TestBase

var _hosting_script: GDScript
var _sonara: Node
var _saved_config: Dictionary
var _saved_config_path: String


func suite_name() -> String:
	return "Plugin hosting tests"


func run_tests() -> void:
	_hosting_script = load("res://data/PluginHosting.gd")
	_sonara = root.get_node("/root/Sonara")
	_saved_config = _sonara.config.duplicate(true)
	_saved_config_path = _sonara._config_path
	_sonara._config_path = "user://test_plugin_hosting_config.json"

	_test_default_message()
	_test_mode_setting_maps_to_engine_name()
	_test_overrides_are_sent_sorted()
	_test_device_host_status()

	_sonara.config = _saved_config
	_sonara._config_path = _saved_config_path
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_plugin_hosting_config.json"))


func _test_default_message() -> void:
	_sonara.set_config(_hosting_script.SETTING_KEY, "Individually")
	_sonara.set_config(_hosting_script.OVERRIDES_KEY, {})
	var hosting = _hosting_script.new()
	_assert(hosting.build_message() == ["individually"], "default policy is Individually with no overrides")


func _test_mode_setting_maps_to_engine_name() -> void:
	var hosting = _hosting_script.new()
	for label in _hosting_script.MODES:
		_sonara.set_config(_hosting_script.SETTING_KEY, label)
		_assert(hosting.global_mode() == _hosting_script.MODES[label], "'%s' is sent as %s" % [label, _hosting_script.MODES[label]])
	var setting = root.get_node("/root/Settings").get_setting(_hosting_script.SETTING_KEY)
	_assert(setting != null and setting.options == _hosting_script.MODES.keys(), "every setting choice has an engine name")
	_sonara.set_config(_hosting_script.SETTING_KEY, "bogus")
	_assert(hosting.global_mode() == "individually", "an unknown choice falls back to individually")


func _test_overrides_are_sent_sorted() -> void:
	_sonara.set_config(_hosting_script.SETTING_KEY, "Together")
	_sonara.set_config(_hosting_script.OVERRIDES_KEY, {})
	var hosting = _hosting_script.new()
	var changes := [0]
	hosting.overrides_changed.connect(func() -> void: changes[0] += 1)

	hosting.set_hosted_individually("z.synth", true)
	hosting.set_hosted_individually("a.reverb", true)
	hosting.set_hosted_individually("a.reverb", true)  # no change
	_assert(changes[0] == 2, "overrides_changed fires only on a change")
	_assert(hosting.is_hosted_individually("a.reverb"), "override is stored")
	_assert(hosting.build_message() == ["together", "a.reverb", "individually", "z.synth", "individually"],
		"message is the mode then sorted override pairs")

	hosting.set_hosted_individually("z.synth", false)
	_assert(not hosting.is_hosted_individually("z.synth"), "override is cleared")
	_assert(hosting.build_message() == ["together", "a.reverb", "individually"], "cleared override is not sent")


func _test_device_host_status() -> void:
	var device_script: GDScript = load("res://data/Device.gd")
	var instance_script: GDScript = load("res://data/DeviceInstance.gd")
	var device: Object = device_script.new("test.clap", "Test Plugin",
		device_script.DeviceCategory.Effect, device_script.DeviceType.CLAP)
	var dev = instance_script.new(device, 2, 0)
	_assert(dev.host_description() == "", "no host line before the plugin loaded")

	var fired := [0]
	dev.host_changed.connect(func() -> void: fired[0] += 1)
	dev._on_host_received(["by_plugin", "plugin:test.clap", 4321])
	_assert(fired[0] == 1, "host_changed fires")
	_assert(dev.host_mode == "by_plugin" and dev.host_key == "plugin:test.clap" and dev.host_pid == 4321, "host info is stored")
	_assert(dev.host_description() == "Plugin host: By plug-in (pid 4321)", "tooltip line names mode and pid")
