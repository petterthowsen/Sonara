# test_audio_config.gd
# Headless tests for the audio output settings (engine-stability-plan Phase 7): AudioConfig
# parses the engine's /audio/device and /audio/config reports, builds /audio/config/set from
# the settings, offers rates and buffer sizes per device, and raises the engine's notice once.
# Also checks the Settings control's options and info lines, master's output-pair setter and
# the mixer labels.
#
# Sonara.save_config() writes the real config file, so the suite points it at a scratch file
# under user:// and restores the in-memory config afterwards.
# Run: godot --headless --path Godot -s tests/test_audio_config.gd -- --test
extends TestBase

var _script: GDScript
var _sonara: Node
var _saved_config: Dictionary
var _saved_config_path: String

const CONFIG_ARGS := ["hw:CARD=USB", 44100, 256, 5.8, 4, 0, "hw:CARD=USB", 44100, 256, 1024, 48000,
	"PipeWire runs a 1024-frame quantum.", ""]


func suite_name() -> String:
	return "Audio config tests"


func run_tests() -> void:
	_script = load("res://data/AudioConfig.gd")
	_sonara = root.get_node("/root/Sonara")
	_saved_config = _sonara.config.duplicate(true)
	_saved_config_path = _sonara._config_path
	_sonara._config_path = "user://test_audio_config_config.json"

	_test_settings_are_registered()
	_test_message_from_settings()
	_test_parse_reports()
	_test_rates_and_buffers_per_device()
	_test_notice_is_raised_once()
	_test_output_labels()
	_test_master_output_setter()
	await _test_settings_control()

	_sonara.config = _saved_config
	_sonara._config_path = _saved_config_path
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_audio_config_config.json"))


## Parse device messages into the typed list AudioConfig.devices holds.
func _devices(messages: Array) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for args in messages:
		list.append(_script.parse_device(args))
	return list


func _new_config() -> Node:
	var config: Node = _script.new()
	return config


func _test_settings_are_registered() -> void:
	var settings := root.get_node("/root/Settings")
	for key in _script.KEYS:
		var setting = settings.get_setting(key)
		_assert(setting != null, "%s is registered" % key)
		_assert(setting != null and setting.control_scene == "res://settings/AudioSettingControl.tscn", "%s uses the audio control" % key)
	_assert(settings.get_value(_script.DEVICE_KEY) == "" or _sonara.get_config(_script.DEVICE_KEY) != null, "device defaults to the system default")
	_assert(settings.get_setting(_script.RATE_KEY).default == 48000, "rate defaults to 48 kHz")
	_assert(settings.get_setting(_script.BUFFER_KEY).default == 1024, "buffer defaults to 1024 frames")


func _test_message_from_settings() -> void:
	_sonara.set_config(_script.DEVICE_KEY, "hw:CARD=USB")
	_sonara.set_config(_script.RATE_KEY, 44100)
	_sonara.set_config(_script.BUFFER_KEY, 256)
	var config := _new_config()
	_assert(config.build_message() == ["hw:CARD=USB", 44100, 256], "message is device, rate, buffer: %s" % [config.build_message()])
	_sonara.set_config(_script.DEVICE_KEY, "")
	_assert(config.build_message()[0] == "", "the system default is sent as \"\"")
	config.free()


func _test_parse_reports() -> void:
	var device: Dictionary = _script.parse_device(["pipewire", 1, 32, 2048, 2, 44100, 48000])
	_assert(device.name == "pipewire" and device.is_default and device.channels == 2, "device fields parse")
	_assert(device.rates == [44100, 48000], "trailing ints are the rates")
	_assert(_script.parse_device(["x", 0, 32]).is_empty(), "short device message is rejected")

	var parsed: Dictionary = _script.parse_config(CONFIG_ARGS)
	_assert(parsed.device == "hw:CARD=USB" and parsed.sample_rate == 44100 and parsed.buffer_size == 256, "running config parses")
	_assert(parsed.output_pairs == 4 and parsed.graph_quantum == 1024 and parsed.graph_rate == 48000, "pairs and graph parse")
	_assert(parsed.mismatch.begins_with("PipeWire"), "mismatch text parses")
	_assert(_script.parse_config(["x", 1]).is_empty(), "short config message is rejected")

	var config := _new_config()
	config._on_device(["pipewire", 1, 32, 2048, 2, 48000])
	config._on_device(["bad"])
	var fired := [0]
	config.devices_changed.connect(func() -> void: fired[0] += 1)
	config._on_devices_complete([1])
	_assert(config.devices.size() == 1 and config.devices_loaded, "complete publishes the collected devices")
	_assert(fired[0] == 1, "devices_changed fires once")
	config.free()


func _test_rates_and_buffers_per_device() -> void:
	var config := _new_config()
	config.devices = _devices([
		["pipewire", 1, 32, 2048, 2, 44100, 48000, 96000],
		["hw:CARD=USB", 0, 128, 1024, 8, 48000],
		["busy", 0, 32, 2048, 0],
	])
	_assert(config.find_device("").name == "pipewire", "\"\" finds the default device")
	_assert(config.rates_for("", 48000) == [44100, 48000, 96000], "default device rates")
	_assert(config.rates_for("hw:CARD=USB", 44100) == [44100, 48000], "the current value stays selectable")
	_assert(config.rates_for("busy", 48000) == _script.FALLBACK_RATES, "an unqueried device offers the common rates")
	_assert(config.buffer_sizes_for("hw:CARD=USB", 256) == [128, 256, 512, 1024], "buffers within the device range")
	_assert(config.buffer_sizes_for("missing", 100) == [32, 64, 100, 128, 256, 512, 1024, 2048], "unknown device offers all sizes plus the current")
	config.free()


func _test_notice_is_raised_once() -> void:
	var config := _new_config()
	var notices: Array[String] = []
	config.notice_raised.connect(func(text: String) -> void: notices.append(text))
	var args := CONFIG_ARGS.duplicate()
	args[12] = "Couldn't use hw:CARD=USB: output device 'hw:CARD=USB' not found."
	config.apply_config(_script.parse_config(args))
	config.apply_config(_script.parse_config(args))
	_assert(notices.size() == 1, "the same notice is raised once")
	args[12] = ""
	config.apply_config(_script.parse_config(args))
	_assert(notices.size() == 1, "no notice for an empty text")
	_assert(config.has_config() and config.output_pairs() == 4, "running config is exposed")
	config.free()


func _test_output_labels() -> void:
	_assert(_script.output_label(1000) == "Outputs 1/2", "1000 is outputs 1/2")
	_assert(_script.output_label(1003) == "Outputs 7/8", "1003 is outputs 7/8")


func _test_master_output_setter() -> void:
	var channel_script: GDScript = load("res://data/Channel.gd")
	var master = channel_script.new(1)
	var routed: Array[int] = []
	master.route_changed.connect(func(output_id: int) -> void: routed.append(output_id))
	master.set_device_output(1002)
	_assert(master.device_output_id == 1002 and routed == [1002], "master routes to outputs 5/6")
	master.set_device_output(1002)
	_assert(routed.size() == 1, "no signal without a change")
	master.set_device_output(5)
	_assert(master.device_output_id == 1002, "a non-hardware ID is rejected")


func _test_settings_control() -> void:
	var autoload: Node = root.get_node("/root/AudioConfig")
	var saved_devices: Array[Dictionary] = autoload.devices
	var saved_loaded: bool = autoload.devices_loaded
	var saved_config: Dictionary = autoload.config
	autoload.devices = _devices([
		["pipewire", 1, 32, 2048, 2, 44100, 48000],
		["hw:CARD=USB", 0, 128, 1024, 8, 48000],
	])
	autoload.devices_loaded = true
	autoload.config = _script.parse_config(CONFIG_ARGS)
	_sonara.set_config(_script.DEVICE_KEY, "hw:CARD=Gone")
	_sonara.set_config(_script.RATE_KEY, 48000)

	var settings := root.get_node("/root/Settings")
	var scene: PackedScene = load("res://settings/AudioSettingControl.tscn")

	var device_control = scene.instantiate()
	root.add_child(device_control)
	device_control.setup(settings.get_setting(_script.DEVICE_KEY), "hw:CARD=Gone")
	var labels: Array[String] = []
	for i in device_control._option.item_count:
		labels.append(device_control._option.get_item_text(i))
	_assert(labels == ["System default (pipewire)", "pipewire", "hw:CARD=USB — 8 channels", "hw:CARD=Gone (not found)"],
		"device options: default, listed devices, the missing saved one: %s" % [labels])
	_assert(device_control._option.selected == 3, "the saved device stays selected")
	_assert(device_control._info.text.begins_with("Running: hw:CARD=USB, 44100 Hz, 256 frames"), "info shows the running config: %s" % device_control._info.text)
	var edited: Array = []
	device_control.value_edited.connect(func(value) -> void: edited.append(value))
	device_control._option.select(2)
	device_control._on_item_selected(2)
	_assert(edited == ["hw:CARD=USB"] and device_control.get_value() == "hw:CARD=USB", "choosing a device edits the value")

	_sonara.set_config(_script.DEVICE_KEY, "hw:CARD=USB")
	var buffer_control = scene.instantiate()
	root.add_child(buffer_control)
	buffer_control.setup(settings.get_setting(_script.BUFFER_KEY), 256)
	_assert(buffer_control._option.get_item_text(0) == "128 frames (2.7 ms)", "buffer labels show latency at the set rate: %s" % buffer_control._option.get_item_text(0))
	_assert(buffer_control._info.text.contains("PipeWire quantum: 1024 frames at 48000 Hz"), "buffer info shows the graph: %s" % buffer_control._info.text)
	_assert(buffer_control._warning.visible and buffer_control._warning.text.begins_with("PipeWire"), "buffer warning shows the mismatch")

	var rate_control = scene.instantiate()
	root.add_child(rate_control)
	rate_control.setup(settings.get_setting(_script.RATE_KEY), 48000)
	_assert(rate_control._info.text == "Running at 44100 Hz.", "rate info says when the engine runs another rate: %s" % rate_control._info.text)

	for control in [device_control, buffer_control, rate_control]:
		control.queue_free()
	await process_frame
	autoload.devices = saved_devices
	autoload.devices_loaded = saved_loaded
	autoload.config = saved_config
