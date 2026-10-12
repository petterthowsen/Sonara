# test_engine_perf.gd
# Headless tests for spec 042 performance reporting: EngineStatus parses /status/channel_perf
# (variable device count) and /status/engine_perf, and EnginePanel builds the Channels table
# (heaviest first, containers as one row, stale channels dropped).
# Run: godot --headless --path Godot -s tests/test_engine_perf.gd -- --test
extends TestBase

var _device_script: GDScript
var _instance_script: GDScript
var _panel_script: GDScript
var _status_script: GDScript
var _channel_script: GDScript
# Autoload-dependent scripts are loaded at run time (autoloads don't exist at parse time).
var _ChannelPerf: GDScript
var _EnginePerf: GDScript


func suite_name() -> String:
	return "Engine perf tests"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_panel_script = load("res://editor/EnginePanel.gd")
	_status_script = load("res://data/EngineStatus.gd")
	_channel_script = load("res://data/Channel.gd")
	_ChannelPerf = _status_script.ChannelPerf
	_EnginePerf = _status_script.EnginePerf
	_test_channel_perf_parsing()
	_test_engine_perf_parsing()
	_test_table_order_and_names()
	_test_container_is_one_row()
	_test_stale_dropped()


func _make_instance(id: String, display: String, channel_id: int) -> Object:
	var device: Object = _device_script.new(id, display,
		_device_script.DeviceCategory.Effect, _device_script.DeviceType.CLAP)
	return _instance_script.new(device, channel_id, 0)


func _make_channel(id: int, channel_name: String, devices: Array) -> Object:
	var channel: Object = _channel_script.new(id)
	channel.name = channel_name
	for d in devices:
		channel.devices.append(d)
	return channel


func _entry(perf: Object, age_msec: int = 0) -> Dictionary:
	return {"perf": perf, "msec": Time.get_ticks_msec() - age_msec}


func _test_channel_perf_parsing() -> void:
	var none = _ChannelPerf.from_osc([2, 0.21, 0.4, 512, 0])
	_assert(none != null and none.channel_id == 2 and none.device_count() == 0, "0 devices parses")
	_assert(is_equal_approx(none.load_avg, 0.21) and is_equal_approx(none.load_peak, 0.4)
			and none.out_latency_frames == 512, "channel fields are stored")

	var three = _ChannelPerf.from_osc([3, 0.5, 0.7, 0, 3, 0.1, 0.2, 0.3, 0.4, 0.05, 0.06])
	_assert(three != null and three.device_count() == 3, "3 devices parse")
	_assert(is_equal_approx(three.device_avg[1], 0.3) and is_equal_approx(three.device_peak[2], 0.06),
			"device entries are paired in order")

	_assert(_ChannelPerf.from_osc([3, 0.5, 0.7]) == null, "a short header returns null")
	_assert(_ChannelPerf.from_osc([3, 0.5, 0.7, 0, 3, 0.1, 0.2, 0.3]) == null,
			"a truncated device list returns null")
	_assert(_ChannelPerf.from_osc([3, 0.5, 0.7, 0, -1]) == null, "a negative count returns null")


func _test_engine_perf_parsing() -> void:
	var p = _EnginePerf.from_osc([3, "granted", 256, 1, 48000])
	_assert(p != null and p.processing_threads == 3 and p.threads_realtime == "granted", "threads parse")
	_assert(p.output_latency_frames == 256 and p.over_limit_channels == 1 and p.sample_rate == 48000,
			"engine fields are stored")
	_assert(_EnginePerf.from_osc([3, "granted"]) == null, "a short message returns null")


func _test_table_order_and_names() -> void:
	var synth = _make_instance("synth", "PolySynth", 2)
	var fx = _make_instance("fx", "Reverb", 2)
	var plug = _make_instance("p.clap", "Plug", 3)
	plug._on_stats_received([0.12, 0.2, 10.0, 20.0, 47, 0, 0, 0])
	var channels := [_make_channel(2, "Lead", [synth, fx]), _make_channel(3, "Audio 1", [plug])]
	var entries := {
		3: _entry(_ChannelPerf.from_osc([3, 0.02, 0.03, 0, 1, 0.01, 0.02])),
		2: _entry(_ChannelPerf.from_osc([2, 0.4, 0.6, 0, 2, 0.3, 0.5, 0.05, 0.06])),
		9: _entry(_ChannelPerf.from_osc([9, 0.1, 0.1, 0, 0])),
	}
	var rows: Array[Dictionary] = _panel_script.build_channel_rows(entries, channels)
	var names := rows.map(func(r: Dictionary) -> String: return r.name)
	_assert(names == ["Lead", "PolySynth", "Reverb", "Channel 9", "Audio 1", "Plug"],
			"heaviest channel first, devices follow their channel, unknown channel named by id: %s" % [names])
	_assert(rows[1].is_device and not rows[0].is_device, "device rows are marked")
	_assert(rows[1].host_load < 0.0, "a built-in device has no host load")
	_assert(is_equal_approx(rows[5].host_load, 0.12), "a plugin shows its host load")


func _test_container_is_one_row() -> void:
	var container = _make_instance("rack", "Rack", 2)
	container.children.append(_make_instance("inner", "Inner", 2))
	var channels := [_make_channel(2, "Drums", [container])]
	var entries := {2: _entry(_ChannelPerf.from_osc([2, 0.3, 0.4, 0, 1, 0.2, 0.3]))}
	var rows: Array[Dictionary] = _panel_script.build_channel_rows(entries, channels)
	_assert(rows.size() == 2 and rows[1].name == "Rack", "a container is one row, nothing nested")


func _test_stale_dropped() -> void:
	var entries := {
		2: _entry(_ChannelPerf.from_osc([2, 0.4, 0.6, 0, 0]), 100),
		3: _entry(_ChannelPerf.from_osc([3, 0.9, 0.9, 0, 0]), 1500),
	}
	_panel_script._drop_stale_channel_perf(entries, Time.get_ticks_msec())
	_assert(entries.has(2) and not entries.has(3), "a channel silent for over 1 s is dropped")
