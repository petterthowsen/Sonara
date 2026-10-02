# test_preset_browser.gd
# Headless tests for device presets (phase 3): PresetAssetProvider header scan, broken files,
# cache round trip, tag/author/device search, and missing-device flagging.
# Run: godot --headless --path Godot -s tests/test_preset_browser.gd -- --test
#
# Scripts that reference autoloads are loaded with load() instead of named.
extends TestBase

var _asset_script: GDScript
var _search: GDScript
var _provider_script: GDScript
var _library_script: GDScript
var _preset_script: GDScript
var _device_script: GDScript
var _scratch := ""


func suite_name() -> String:
	return "Preset browser"


func run_tests() -> void:
	_asset_script = load("res://browser/Asset.gd")
	_search = load("res://browser/AssetSearch.gd")
	_provider_script = load("res://browser/PresetAssetProvider.gd")
	_library_script = load("res://data/PresetLibrary.gd")
	_preset_script = load("res://data/DevicePreset.gd")
	_device_script = load("res://data/Device.gd")
	_scratch = OS.get_temp_dir().path_join("sonara_preset_browser_%d" % Time.get_ticks_usec())
	_library_script.dir_override = _scratch.path_join("presets")
	_test_scan_headers()
	_test_cache_round_trip()
	_test_search()
	_test_missing_device()
	_cleanup(_scratch)
	_library_script.dir_override = ""


func _write_preset(device_id: String, device_name: String, name: String, author: String, tags: Array, subfolder := "") -> String:
	var preset: Object = _preset_script.new()
	preset.name = name
	preset.author = author
	preset.tags = _preset_script.normalize_tags(tags)
	preset.device_id = device_id
	preset.device_name = device_name
	preset.device = {"device_id": device_id}
	var path: String = _library_script.save(preset)
	if subfolder.is_empty() or path.is_empty():
		return path
	var moved: String = path.get_base_dir().path_join(subfolder).path_join(path.get_file())
	DirAccess.make_dir_recursive_absolute(moved.get_base_dir())
	DirAccess.rename_absolute(path, moved)
	return moved


func _provider() -> Object:
	var p: Object = _provider_script.new()
	p.cache_dir_override = _scratch
	return p


func _by_name(provider: Object, name: String) -> Object:
	for asset in provider.get_assets():
		if asset.name == name:
			return asset
	return null


func _test_scan_headers() -> void:
	var provider := _provider()
	provider.scan()
	_assert(provider.get_assets().is_empty(), "a missing presets folder scans as empty")
	_write_preset("test.synth", "Synth", "Warm Pad", "Peter", ["Pad", "Warm"])
	_write_preset("test.synth", "Synth", "Hard Lead", "Ann", ["lead"], "Leads")
	DirAccess.make_dir_recursive_absolute(_scratch.path_join("presets/Synth"))
	var broken := FileAccess.open(_scratch.path_join("presets/Synth/Broken.sonpreset"), FileAccess.WRITE)
	broken.store_string("{ not json")
	broken.close()
	var other := FileAccess.open(_scratch.path_join("presets/Synth/Other.sonpreset"), FileAccess.WRITE)
	other.store_string('{"format": "something.else"}')
	other.close()
	provider.scan()
	_assert(provider.get_assets().size() == 2, "two good presets listed, broken files skipped (got %d)" % provider.get_assets().size())
	var pad: Object = _by_name(provider, "Warm Pad")
	_assert(pad != null and pad.type == 5, "preset asset has the Preset type")
	if pad == null:
		return
	_assert(pad.device_id == "test.synth" and pad.device_name == "Synth" and pad.author == "Peter", "header fields read")
	_assert(Array(pad.tags) == ["pad", "warm"], "tags come from the header")
	_assert(pad.get_display_name() == "Warm Pad", "display name is the preset name")
	var lead: Object = _by_name(provider, "Hard Lead")
	_assert(lead != null and lead.path.contains("/Leads/"), "presets in user subfolders are found")


func _test_cache_round_trip() -> void:
	var first := _provider()
	first.scan()
	var second := _provider()
	second._load_cache()
	_assert(second.get_assets().size() == 2, "cache restores both presets")
	var pad: Object = _by_name(second, "Warm Pad")
	_assert(pad != null and pad.device_id == "test.synth" and pad.author == "Peter" and Array(pad.tags) == ["pad", "warm"],
			"cache keeps device, author and tags")


func _test_search() -> void:
	var provider := _provider()
	provider.scan()
	var assets: Array = provider.get_assets()
	_assert(_search.rank(assets, "warm").size() >= 1 and _search.rank(assets, "warm")[0].asset.name == "Warm Pad", "tag/name search finds the preset")
	var by_tag: Array = _search.rank(assets, "lead")
	_assert(not by_tag.is_empty() and by_tag[0].asset.name == "Hard Lead", "tag search hit")
	var by_author: Array = _search.rank(assets, "Ann")
	_assert(not by_author.is_empty() and by_author[0].asset.name == "Hard Lead", "author search hit")
	var by_device: Array = _search.rank(assets, "Synth")
	_assert(by_device.size() == 2, "device name search matches every preset of that device (got %d)" % by_device.size())
	_assert(_search.rank(assets, "zzzqqq").is_empty(), "no match for nonsense")


func _test_missing_device() -> void:
	var registry: Object = root.get_node("AssetService").device_registry
	registry._devices["test.present"] = _device_script.new("test.present", "present", 1, 0)
	registry._devices.erase("test.absent")
	_write_preset("test.present", "Present", "Here", "", [])
	_write_preset("test.absent", "Absent", "Gone", "", [])
	var provider := _provider()
	provider.scan()
	var here: Object = _by_name(provider, "Here")
	var gone: Object = _by_name(provider, "Gone")
	_assert(here != null and not here.is_unavailable(), "preset of an installed device is available")
	_assert(gone != null and gone.is_unavailable(), "preset of a missing device is flagged")
	if gone:
		_assert(gone.get_preset_tooltip().contains("Absent") and gone.get_preset_tooltip().contains("not installed"),
				"tooltip names the missing device")
	registry._devices["test.absent"] = _device_script.new("test.absent", "absent", 1, 0)
	_assert(gone != null and not gone.is_unavailable(), "flag clears once the device is registered")
	registry._devices.erase("test.present")
	registry._devices.erase("test.absent")


func _cleanup(path: String) -> void:
	for sub in DirAccess.get_directories_at(path):
		_cleanup(path.path_join(sub))
	for file in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)
