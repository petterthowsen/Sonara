# test_plugin_stats.gd
# Headless tests for per-plugin processing stats (engine-stability-plan Phase 6): a device's
# <device addr>/stats status fills in DeviceInstance.plugin_stats and its tooltip text, a crash
# drops the stats and keeps the host log path, and EnginePanel ranks plugins worst first.
# Run: godot --headless --path Godot -s tests/test_plugin_stats.gd -- --test
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript
var _panel_script: GDScript


func suite_name() -> String:
	return "Plugin stats tests"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_panel_script = load("res://editor/EnginePanel.gd")

	_test_stats_status()
	_test_crash_drops_stats_and_keeps_log_path()
	_test_ranking()


func _make_instance(id: String, display: String, channel_id: int) -> Object:
	var device: Object = _device_script.new(id, display,
		_device_script.DeviceCategory.Effect, _device_script.DeviceType.CLAP)
	return _instance_script.new(device, channel_id, 0)


## [load_avg, load_peak, avg_us, max_us, blocks, misses, total_misses, struggling]
func _stats(load_peak: float, misses: int, struggling: int = 0) -> Array:
	return [load_peak / 2.0, load_peak, 40.0, 120.0, 47, misses, misses * 3, struggling]


func _test_stats_status() -> void:
	var dev = _make_instance("test.clap", "Test Plugin", 2)
	_assert(dev.plugin_stats == null, "no stats before the engine reports any")

	var fired := [0]
	dev.stats_changed.connect(func() -> void: fired[0] += 1)
	dev._on_stats_received([0.05])
	_assert(fired[0] == 0 and dev.plugin_stats == null, "a short message is ignored")

	dev._on_stats_received([0.031, 0.125, 42.0, 170.0, 47, 2, 9, 1])
	_assert(fired[0] == 1, "stats_changed fires")
	var s = dev.plugin_stats
	_assert(is_equal_approx(s.load_avg, 0.031) and is_equal_approx(s.load_peak, 0.125), "loads are stored")
	_assert(s.blocks == 47 and s.deadline_misses == 2 and s.total_misses == 9, "counters are stored")
	_assert(s.struggling and dev.is_struggling(), "struggling flag is stored")
	var text: String = s.describe()
	_assert(text.contains("3.1% avg") and text.contains("12.5% peak"), "tooltip shows the loads: %s" % text)
	_assert(text.contains("2 in the last second") and text.contains("9 since loaded"), "tooltip shows dropouts")
	_assert(text.contains("drops out"), "tooltip warns about a struggling plugin")

	dev._on_stats_received([0.01, 0.02, 10.0, 20.0, 47, 0, 9, 0])
	_assert(not dev.is_struggling(), "a clean report clears the flag")
	dev.plugin_stats.received_msec -= _instance_script.PluginStats.FRESH_MSEC + 1
	_assert(not dev.plugin_stats.is_fresh(Time.get_ticks_msec()), "old stats go stale")


func _test_crash_drops_stats_and_keeps_log_path() -> void:
	var dev = _make_instance("test.clap", "Test Plugin", 2)
	dev._on_stats_received(_stats(0.2, 0))
	var fired := [0]
	dev.stats_changed.connect(func() -> void: fired[0] += 1)
	dev._on_crashed_received(["killed by signal 11 (SIGSEGV)", "", 1234, "/tmp/logs/plugins/instance-3-1234.log"])
	_assert(dev.plugin_stats == null and fired[0] == 1, "a crash drops the stats")
	_assert(dev.crash_log_path == "/tmp/logs/plugins/instance-3-1234.log", "the host log path is kept")
	dev._on_crashed_received(["exited", "", 99])
	_assert(dev.crash_log_path == "", "an older engine without the path clears it")


func _test_ranking() -> void:
	var calm = _make_instance("a.clap", "Calm", 2)
	var heavy = _make_instance("b.clap", "Heavy", 3)
	var dropping = _make_instance("c.clap", "Dropping", 4)
	var idle = _make_instance("d.clap", "Idle", 5)
	var stale = _make_instance("e.clap", "Stale", 6)
	var unreported = _make_instance("f.clap", "Unreported", 7)
	calm._on_stats_received(_stats(0.05, 0))
	heavy._on_stats_received(_stats(0.6, 0))
	dropping._on_stats_received(_stats(0.3, 4))
	idle._on_stats_received([0.0, 0.0, 0.0, 0.0, 0, 0, 0, 0])
	stale._on_stats_received(_stats(0.9, 0))
	stale.plugin_stats.received_msec -= _instance_script.PluginStats.FRESH_MSEC + 1

	# Typed like EnginePanel's parameter, without naming DeviceInstance at parse time (it needs
	# autoloads, which exist only once the test runs).
	var devices := Array([calm, heavy, dropping, idle, stale, unreported], TYPE_OBJECT, &"RefCounted", _instance_script)
	var ranked: Array = _panel_script.rank_plugins(devices, Time.get_ticks_msec(), 10)
	var names := ranked.map(func(d) -> String: return d.device.name)
	_assert(names == ["Dropping", "Heavy", "Calm"],
		"dropouts first, then by peak; idle, stale and unreported are left out: %s" % [names])
	var top: Array = _panel_script.rank_plugins(devices, Time.get_ticks_msec(), 1)
	_assert(top.size() == 1 and top[0] == dropping, "the limit applies")

	# Nested devices are found too.
	var container = _make_instance("chain", "Chain", 2)
	container.children.append(heavy)
	var channel := {"devices": [container, calm]}
	var all: Array = _panel_script.collect_devices([channel])
	_assert(all.size() == 3 and all.has(heavy), "collect_devices walks into containers")
