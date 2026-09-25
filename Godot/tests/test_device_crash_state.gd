# test_device_crash_state.gd
# Headless tests for the DeviceInstance crash path: the `<device>/crashed` callback
# records the reason/stderr, flips loading_state to "crashed:<reason>", and emits
# `crashed` with both values. The error popup is skipped because Utils.is_test_mode()
# is true under --test, so no Editor/engine is needed.
#
# DeviceInstance references autoloads (AudioEngineOSC, Sonara) by bare name, so it is
# loaded with load() inside run_tests() rather than named by class.
# Run: godot --headless --path Godot -s tests/test_device_crash_state.gd -- --test
extends TestBase

var _device_script: GDScript
var _device_instance_script: GDScript


func suite_name() -> String:
	return "Device crash state tests"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_test_crash_received()
	_test_crash_received_without_values()


func _make_device_instance():
	var device: Object = _device_script.new(
		"test.crash.device",
		"Crash Test",
		_device_script.DeviceCategory.Instrument,
		_device_script.DeviceType.BuiltIn)
	return _device_instance_script.new(device, 0, 0)


func _test_crash_received() -> void:
	var dev = _make_device_instance()
	var received: Array = []
	dev.crashed.connect(func(reason: String, stderr: String) -> void:
		received.append({"reason": reason, "stderr": stderr}))

	dev._on_crashed_received(["killed by signal 11 (SIGSEGV)", "boom", 123])

	_assert(dev.loading_state == "crashed:killed by signal 11 (SIGSEGV)", "loading_state is crashed:<reason>")
	_assert(dev.crash_reason == "killed by signal 11 (SIGSEGV)", "crash_reason is stored")
	_assert(dev.crash_stderr == "boom", "crash_stderr is stored")
	_assert(received.size() == 1, "crashed signal fired once")
	_assert(received.size() == 1 and received[0]["reason"] == "killed by signal 11 (SIGSEGV)" and received[0]["stderr"] == "boom",
		"crashed signal carries reason and stderr")


func _test_crash_received_without_values() -> void:
	var dev = _make_device_instance()
	dev._on_crashed_received([])
	_assert(dev.crash_reason == "unknown", "missing reason falls back to unknown")
	_assert(dev.crash_stderr == "", "missing stderr falls back to empty")
