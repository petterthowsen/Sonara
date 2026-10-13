# test_device_usage.gd
# Headless tests for per-device load and RAM in the header tooltip: /status/channel_perf feeds
# each top-level device's load, <device addr>/memory fills the RAM figure, the tooltip text reads
# "Load 3.2% (peak 7.1%) · RAM 412 MB (shared by 2)", figures go stale, and the Engine panel's
# RAM line sums engine and plugin hosts.
# Run: godot --headless --path Godot -s tests/test_device_usage.gd -- --test
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript
var _panel_script: GDScript
var _status_script: GDScript
var _Usage: GDScript


func suite_name() -> String:
	return "Device usage tests"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_panel_script = load("res://editor/EnginePanel.gd")
	_status_script = load("res://data/EngineStatus.gd")
	_Usage = _instance_script.Usage
	_test_format_bytes()
	_test_describe()
	_test_memory_status()
	_test_staleness()
	_test_channel_perf_feeds_devices()
	_test_engine_memory()


func _make_instance(id: String, display: String, channel_id: int) -> Object:
	var device: Object = _device_script.new(id, display,
		_device_script.DeviceCategory.Effect, _device_script.DeviceType.CLAP)
	return _instance_script.new(device, channel_id, 0)


func _test_format_bytes() -> void:
	_assert(_Usage.format_bytes(96 * 1024) == "96 KB", "small sizes are KB: %s" % _Usage.format_bytes(96 * 1024))
	_assert(_Usage.format_bytes(3 * 1048576 + 524288) == "3.5 MB", "1-10 MB keeps a decimal")
	_assert(_Usage.format_bytes(412 * 1048576) == "412 MB", "10 MB and up are whole MB")
	_assert(_Usage.format_bytes(1280 * 1048576) == "1.25 GB", "1 GB and up are GB")


func _test_describe() -> void:
	var u = _Usage.new()
	var now := 100000
	_assert(u.describe(now) == "", "nothing reported reads empty")

	u.load_avg = 0.032
	u.load_peak = 0.071
	u.load_msec = now
	u.memory_bytes = 412 * 1048576
	u.memory_shared_by = 2
	u.memory_msec = now
	_assert(u.describe(now) == "Load 3.2% (peak 7.1%) · RAM 412 MB (shared by 2)",
			"full text: %s" % u.describe(now))

	u.memory_shared_by = 1
	u.memory_approximate = true
	_assert(u.describe(now) == "Load 3.2% (peak 7.1%) · RAM ~412 MB",
			"approximate RAM has a tilde and no sharing: %s" % u.describe(now))

	var load_only = _Usage.new()
	load_only.load_msec = now
	_assert(load_only.describe(now) == "Load 0.0% (peak 0.0%)", "a built-in without RAM shows load only")


func _test_memory_status() -> void:
	var dev = _make_instance("test.clap", "Test Plugin", 2)
	var fired := [0]
	dev.usage_changed.connect(func() -> void: fired[0] += 1)
	dev._on_memory_received([1024])
	_assert(fired[0] == 0 and dev.usage.memory_bytes == -1, "a short message is ignored")

	dev._on_memory_received([412 * 1024, 2, 1])
	_assert(fired[0] == 1, "usage_changed fires")
	_assert(dev.usage.memory_bytes == 412 * 1048576, "KiB become bytes")
	_assert(dev.usage.memory_shared_by == 2 and dev.usage.memory_approximate, "sharing and approximation are stored")
	var text: String = dev.usage.describe(Time.get_ticks_msec())
	_assert(text == "RAM ~412 MB (shared by 2)", "text without load: %s" % text)


func _test_staleness() -> void:
	var u = _Usage.new()
	u.load_msec = 1000
	u.memory_bytes = 1048576
	u.memory_msec = 1000
	_assert(u.has_load(1000 + _Usage.FRESH_MSEC) and u.has_memory(1000 + _Usage.FRESH_MSEC), "fresh at the limit")
	_assert(not u.has_load(1001 + _Usage.FRESH_MSEC) and not u.has_memory(1001 + _Usage.FRESH_MSEC),
			"stale after the limit")
	_assert(u.describe(1001 + _Usage.FRESH_MSEC) == "", "stale figures are left out")


func _test_channel_perf_feeds_devices() -> void:
	var a = _make_instance("a", "A", 2)
	var b = _make_instance("b", "B", 2)
	var perf = _status_script.ChannelPerf.from_osc([2, 0.4, 0.6, 0, 2, 0.3, 0.5, 0.05, 0.06])
	# A third device the report doesn't cover stays untouched.
	var c = _make_instance("c", "C", 2)
	_panel_script.apply_device_loads(perf, [a, b, c])
	var now := Time.get_ticks_msec()
	_assert(is_equal_approx(a.usage.load_avg, 0.3) and is_equal_approx(a.usage.load_peak, 0.5),
			"first device gets the first pair")
	_assert(is_equal_approx(b.usage.load_avg, 0.05) and is_equal_approx(b.usage.load_peak, 0.06),
			"second device gets the second pair")
	_assert(not c.usage.has_load(now), "a device past the report has no load")
	_assert(a.usage.describe(now).begins_with("Load 30.0% (peak 50.0%)"), "tooltip text: %s" % a.usage.describe(now))

	# A short chain ignores the extra entries instead of failing.
	_panel_script.apply_device_loads(perf, [a])
	_assert(true, "more entries than devices is fine")


func _test_engine_memory() -> void:
	var memory = _status_script.EngineMemory.from_osc([300 * 1024, 1200 * 1024, 3])
	_assert(memory != null and memory.engine_bytes == 300 * 1048576 and memory.plugin_hosts == 3,
			"engine memory parses")
	_assert(memory.total_bytes() == 1500 * 1048576, "total is engine plus plugins")
	_assert(_status_script.EngineMemory.from_osc([1, 2]) == null, "a short message returns null")
	var text: String = _panel_script.memory_header(memory)
	_assert(text == "RAM: engine 300 MB · plugins 1.17 GB (3 hosts) · total 1.46 GB", "panel line: %s" % text)
	var alone = _status_script.EngineMemory.from_osc([300 * 1024, 0, 0])
	_assert(_panel_script.memory_header(alone) == "RAM: engine 300 MB · total 300 MB",
			"no hosts: %s" % _panel_script.memory_header(alone))
	_assert(_panel_script.memory_header(null) == "", "no report, no line")
