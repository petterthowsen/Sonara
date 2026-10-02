# test_automation_param_labels.gd
# AutomationTarget.param_label disambiguates repeated parameter names by module (EQ bands).
# Run: godot --headless --path Godot -s tests/test_automation_param_labels.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Automation parameter label tests"


func run_tests() -> void:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	registry._on_builtin_info_received([
		"test.eq", "EQ", "effect", "", 0, 2, 2, 0, "", 0,
		4,
		3, "Gain", "dB", "float", 1, -24.0, 24.0, 0.0, 0, 1.0, 0, "Band 1", 1,
		2, "Freq", "Hz", "float", 1, 20.0, 20000.0, 100.0, 1, 1.0, 0, "Band 1", 1,
		13, "Gain", "dB", "float", 1, -24.0, 24.0, 0.0, 0, 1.0, 0, "Band 2", 1,
		80, "Gain", "dB", "float", 1, -24.0, 24.0, 0.0, 0, 1.0, 0, "", 1,
		0,
		0,
		0,
	])
	var instance = load("res://data/DeviceInstance.gd").new(registry.get_device("test.eq"), 2, 0)
	var params: Array = instance.get_parameters()
	_assert(params[0].module == "Band 1" and params[0].is_automation_safe, "module/automatable parsed")
	_assert(AutomationTarget.param_label(instance, params[0]) == "Band 1 / Gain", "repeated name gets module")
	_assert(AutomationTarget.param_label(instance, params[2]) == "Band 2 / Gain", "second band too")
	_assert(AutomationTarget.param_label(instance, params[1]) == "Freq", "unique name stays bare")
	_assert(AutomationTarget.param_label(instance, params[3]) == "Gain", "no module: name unchanged")
