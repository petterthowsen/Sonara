# test_vst3_devices.gd
# Headless tests for VST3 devices in the Godot UI: /plugin/info with and without the format arg,
# the plugin cache round-trip, the add_device type string, sibling detection for plugins that
# ship as both CLAP and VST3, and format search.
# Run: godot --headless --path Godot -s tests/test_vst3_devices.gd -- --test
extends TestBase

var _device_script: GDScript
var _registry_script: GDScript


func suite_name() -> String:
	return "VST3 device tests"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_registry_script = load("res://data/DeviceRegistry.gd")
	_test_device_type()
	_test_plugin_info()
	_test_cache_round_trip()
	_test_siblings()
	_test_search()


func _info(id: String, fmt: String = "") -> Array:
	var args := [id, "Surge XT", "Surge Synth Team", "1.3", "instrument", "", "/p/" + id, "synth,vst3"]
	if fmt != "":
		args.append(fmt)
	return args


func _test_device_type() -> void:
	var d: Object = _device_script.new("x", "X", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.VST3)
	_assert(d.is_plugin() and d.has_gui(), "VST3 is a plugin with a GUI")
	_assert(d.get_device_type_string() == "VST3" and d.format_tag() == "VST3", "VST3 type string")
	_assert(_device_script.DeviceType.CLAP == 2 and _device_script.DeviceType.VST3 == 3, "existing enum ints unchanged")
	var b: Object = _device_script.new("b", "B", _device_script.DeviceCategory.Effect)
	_assert(not b.is_plugin() and b.format_tag() == "", "built-ins are not plugins")
	var channel_script: GDScript = load("res://data/Channel.gd")
	var ch: Object = channel_script.new()
	_assert(ch._get_device_type_string(_device_script.DeviceType.VST3) == "vst3", "add_device type string")


func _test_plugin_info() -> void:
	var reg: Object = _registry_script.new()
	reg._on_plugin_info_received(_info("A"))
	reg._on_plugin_info_received(_info("B", "vst3"))
	reg._on_plugin_info_received(_info("C", "clap"))
	_assert(reg.get_device("A").device_type == _device_script.DeviceType.CLAP, "no arg 8 defaults to CLAP")
	_assert(reg.get_device("B").device_type == _device_script.DeviceType.VST3, "arg 8 vst3")
	_assert(reg.get_device("B").description == "VST3 Plugin", "VST3 default description")
	_assert(reg.get_device("C").description == "CLAP Plugin", "CLAP default description")


func _test_cache_round_trip() -> void:
	var reg: Object = _registry_script.new()
	reg._on_plugin_info_received(_info("B", "vst3"))
	var data: Dictionary = _registry_script._device_to_cache_data(reg.get_device("B"))
	var back: Object = _registry_script._device_from_cache_data(JSON.parse_string(JSON.stringify(data)))
	_assert(back.device_type == _device_script.DeviceType.VST3, "VST3 survives the cache")
	var old: Object = _registry_script._device_from_cache_data({"device_id": "o", "name": "Old", "device_type": "CLAP"})
	_assert(old.device_type == _device_script.DeviceType.CLAP, "pre-VST3 cache entries still load")


func _test_siblings() -> void:
	var reg: Object = _registry_script.new()
	reg._on_plugin_info_received(_info("A", "clap"))
	reg._on_plugin_info_received(_info("B", "vst3"))
	var solo := _info("S", "vst3")
	solo[1] = "Solo Synth"
	reg._on_plugin_info_received(solo)
	_assert(reg.has_other_format(reg.get_device("A")) and reg.has_other_format(reg.get_device("B")), "same plugin in both formats")
	_assert(not reg.has_other_format(reg.get_device("S")), "single-format plugin has no tag")
	var shouty := _info("D", "vst3")
	shouty[2] = "surge synth team"
	shouty[1] = "SURGE xt"
	reg._on_plugin_info_received(shouty)
	_assert(reg.has_other_format(reg.get_device("D")), "vendor and name match is normalized")


func _test_search() -> void:
	var asset_script: GDScript = load("res://browser/Asset.gd")
	var search: GDScript = load("res://browser/AssetSearch.gd")
	var service: Node = root.get_node("/root/AssetService")
	var reg: Object = service.device_registry
	reg._on_plugin_info_received(_info("search.vst3", "vst3"))
	var a: Object = asset_script.new()
	a.type = asset_script.TYPE.Device
	a.name = "Surge XT"
	a.path = "search.vst3"
	_assert(search.score(a, "vst3") > search.MATCH_THRESHOLD, "typing the format finds the plugin")
	_assert(search.score(a, "clap") <= search.MATCH_THRESHOLD, "other format does not match")
