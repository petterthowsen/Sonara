# test_device_tools.gd
# Headless tests for device names, paths, and parameter paging.
# Run: godot --headless --path Godot -s ai/tests/test_device_tools.gd
extends SceneTree


var _failures: int = 0


## Stub host item for path walking (avoids DeviceInstance / autoloads).
class StubDev extends RefCounted:
	var name: String = ""
	var children: Array = []

	func _init(p_name: String) -> void:
		name = p_name


func _init() -> void:
	print("=== Device tool tests ===")
	_test_sanitize_and_unique()
	_test_split_path()
	_test_walk_named()
	_test_param_page()
	_test_parse_param_value()
	_test_pad_specs()
	if _failures == 0:
		print("=== ALL PASSED ===")
	else:
		print("=== FAILED: %d ===" % _failures)
	quit(_failures)


func _assert(cond: bool, msg: String) -> void:
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)
		print("FAIL: ", msg)
	else:
		print("ok: ", msg)


func _test_sanitize_and_unique() -> void:
	_assert(DeviceNaming.sanitize("  Delay / Wet  ") == "Delay Wet", "sanitize strips slashes")
	_assert(DeviceNaming.sanitize("   ", "Device") == "Device", "sanitize fallback")
	var existing: PackedStringArray = PackedStringArray(["Delay", "EQ"])
	_assert(DeviceNaming.unique_in(existing, "Delay") == "Delay 2", "second Delay is Delay 2")
	_assert(DeviceNaming.unique_in(existing, "delay") == "delay 2", "case-insensitive conflict")
	existing.append("Delay 2")
	_assert(DeviceNaming.unique_in(existing, "Delay") == "Delay 3", "third Delay is Delay 3")
	_assert(DeviceNaming.unique_in(existing, "Compressor") == "Compressor", "free name kept")


func _test_split_path() -> void:
	var segs := DeviceNaming.split_path("Kick/Chain/Delay 2")
	_assert(segs.size() == 3, "three path segments")
	_assert(segs[0] == "Kick" and segs[2] == "Delay 2", "path segments preserved")
	_assert(DeviceNaming.split_path(" /Kick/ ").size() == 1, "empty parts dropped")
	var rest := DeviceNaming.skip_first(segs)
	_assert(rest.size() == 2 and rest[0] == "Chain", "skip_first drops channel")


func _test_walk_named() -> void:
	var delay_a := StubDev.new("Delay")
	var delay_b := StubDev.new("Delay 2")
	var chain := StubDev.new("Chain")
	var nested := StubDev.new("Delay")
	chain.children.append(nested)
	var host: Array = [delay_a, delay_b, chain]
	var found = DeviceNaming.walk_named(host, PackedStringArray(["Delay 2"]))
	_assert(found is StubDev and found.name == "Delay 2", "walk Delay 2")
	found = DeviceNaming.walk_named(host, PackedStringArray(["Chain", "Delay"]))
	_assert(found is StubDev and found == nested, "walk nested Chain/Delay")
	var miss = DeviceNaming.walk_named(host, PackedStringArray(["Reverb"]))
	_assert(miss is Dictionary and miss.get("ok") == false, "missing name fails")
	host.append(StubDev.new("Delay"))
	var amb = DeviceNaming.walk_named(host, PackedStringArray(["Delay"]))
	_assert(amb is Dictionary and str(amb.get("error", "")).contains("instance_id"), "ambiguous Delay")


func _test_param_page() -> void:
	var items: Array = []
	for i in range(40):
		items.append(i)
	var page := DeviceNaming.page_items(items, 0, 32)
	_assert(page.total == 40 and page.items.size() == 32 and page.next_offset == 32, "first page")
	page = DeviceNaming.page_items(items, 32, 32)
	_assert(page.items.size() == 8 and int(page.next_offset) == -1, "last page")
	page = DeviceNaming.page_items(items, 100, 32)
	_assert(page.items.is_empty() and page.total == 40, "offset past end")


func _test_parse_param_value() -> void:
	var flt := DeviceParameter.new(0, "Delay Time", "ms")
	flt.min_value = 1.0
	flt.max_value = 5000.0
	flt.default_value = 250.0
	var parsed := flt.parse_tool_value(250)
	_assert(parsed.ok, "float parse ok")
	var n := float(parsed.normalized)
	_assert(n > 0.0 and n < 1.0, "250ms is in range")
	var en := DeviceParameter.new(1, "Waveform A")
	en.param_type = "enum"
	en.enum_values.append("Sine")
	en.enum_values.append("Square")
	en.enum_values.append("Saw")
	en.enum_values.append("Triangle")
	parsed = en.parse_tool_value("Saw")
	_assert(parsed.ok, "enum label ok")
	var saw_n := float(parsed.normalized)
	_assert(abs(saw_n - (2.0 / 3.0)) < 0.001, "Saw is index 2 of 0-3")
	parsed = en.parse_tool_value("nope")
	_assert(not parsed.ok, "bad enum fails")
	var bo := DeviceParameter.new(2, "Key Track")
	bo.param_type = "bool"
	parsed = bo.parse_tool_value(true)
	_assert(parsed.ok and float(parsed.normalized) == 1.0, "bool true")
	parsed = bo.parse_tool_value("off")
	_assert(parsed.ok and float(parsed.normalized) == 0.0, "bool off")


func _test_pad_specs() -> void:
	var specs: Array = DeviceToolUtil.collect_pad_specs({
		"asset_path": "/tmp/kick.wav",
		"name": "Kick",
		"note": 36,
	})
	_assert(specs.size() == 1 and specs[0].name == "Kick" and int(specs[0].note) == 36, "single asset_path spec")
	specs = DeviceToolUtil.collect_pad_specs({
		"asset_paths": ["/tmp/a.wav", "/tmp/b.wav"],
	})
	_assert(specs.size() == 2 and specs[1].asset_path.ends_with("b.wav"), "asset_paths list")
	specs = DeviceToolUtil.collect_pad_specs({
		"samples": [
			{"asset_path": "/tmp/snare.wav", "name": "Snare"},
			"/tmp/hat.wav",
		],
	})
	_assert(specs.size() == 2 and specs[0].name == "Snare" and specs[1].name == "", "mixed samples array")
	var ident := DeviceToolUtil.resolve_pad_identity({"name": "", "note": -1}, "kick_kick_drum_01", {})
	_assert(int(ident.note) == 36 and str(ident.name) == "KICK", "infer kick pad")
	ident = DeviceToolUtil.resolve_pad_identity({"name": "Snare", "note": -1}, "x.wav", {36: true})
	_assert(int(ident.note) == 38 and str(ident.name) == "Snare", "infer snare from name")
	ident = DeviceToolUtil.resolve_pad_identity({"name": "", "note": -1}, "kick_kick_drum_02", {36: true})
	_assert(int(ident.note) == -1, "occupied kick note skipped")
