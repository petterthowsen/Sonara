# test_browser_folder_menu.gd
# Headless tests for the browser's "Open in Containing Folder" context menu:
# the per-asset predicate (file-backed vs built-in vs missing path), file/folder
# derivation, and the menu-builder wiring on Browser. Actual pixel/mouse
# interaction can't be exercised headless.
#
# Asset.gd references the AssetService autoload by bare name, so it is loaded
# via load() after TestBase's startup frame (see test_fuzzy_resolve.gd).
# Run: godot --headless --path Godot -s tests/test_browser_folder_menu.gd -- --test
extends TestBase

# Asset.FolderMenu, mirrored as ints because the script is load()ed.
const FOLDER_HIDDEN := 0
const FOLDER_ENABLED := 1
const FOLDER_DISABLED := 2

# Asset.TYPE indexes: Audio, Midi, Device, SFZ, SoundFont, Preset.
const TYPE_AUDIO := 0
const TYPE_DEVICE := 2
const TYPE_SFZ := 3
const TYPE_PRESET := 5

var _asset_script: GDScript
var _asset_service: Node
var _browser: Object


func suite_name() -> String:
	return "Browser folder context menu"


func run_tests() -> void:
	_asset_script = load("res://browser/Asset.gd")
	_asset_service = root.get_node("AssetService")
	_register_builtin("sonara.builtin.delay", "Delay")
	_register_plugin("com.example.reverb", "Example Reverb", "/abs/plugins/example_reverb.clap")
	_test_file_assets_get_the_entry()
	_test_installed_preset_gets_the_entry()
	_test_unavailable_preset_is_disabled()
	_test_empty_path_is_disabled()
	_test_builtin_device_is_hidden()
	_test_plugin_device_maps_to_plugin_file()
	_test_unknown_device_is_hidden()
	_test_plugin_without_file_is_hidden()
	await _test_browser_menu_wiring()


func _register_builtin(device_id: String, title: String) -> void:
	var device := Device.new(device_id, title, Device.DeviceCategory.Instrument, Device.DeviceType.BuiltIn)
	_asset_service.device_registry._devices[device_id] = device


func _register_plugin(device_id: String, title: String, plugin_path: String) -> void:
	var device := Device.new(device_id, title, Device.DeviceCategory.Effect, Device.DeviceType.CLAP)
	device.plugin_path = plugin_path
	_asset_service.device_registry._devices[device_id] = device


func _asset(type: int, path: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = type
	asset.path = path
	asset.name = path.get_file().trim_suffix("." + path.get_extension())
	return asset


func _preset(path: String, device_id: String) -> Object:
	var asset: Object = _asset(TYPE_PRESET, path)
	asset.device_id = device_id
	asset.device_name = device_id
	return asset


func _test_file_assets_get_the_entry() -> void:
	for type in [TYPE_AUDIO, TYPE_SFZ]:
		var asset: Object = _asset(type, "/abs/lib/sound.%s" % ("wav" if type == TYPE_AUDIO else "sfz"))
		_assert(asset.get_folder_menu_state() == FOLDER_ENABLED, "a file-backed asset gets the entry")
		_assert(asset.get_file_path() == asset.path, "the entry targets the asset's own file")
		_assert(asset.containing_folder() == "/abs/lib", "the containing folder is derived from the file")
	var midi: Object = _asset(1, "/abs/lib/song.mid")
	_assert(midi.get_folder_menu_state() == FOLDER_ENABLED, "a MIDI file gets the entry")


func _test_installed_preset_gets_the_entry() -> void:
	var asset: Object = _preset("/abs/presets/warm.sonpreset", "sonara.builtin.delay")
	_assert(not asset.is_unavailable(), "a preset with an installed device is available")
	_assert(asset.get_folder_menu_state() == FOLDER_ENABLED, "an installed preset gets the entry")
	_assert(asset.containing_folder() == "/abs/presets", "a preset's folder is derived from its file")


func _test_unavailable_preset_is_disabled() -> void:
	var asset: Object = _preset("/abs/presets/ghost.sonpreset", "com.missing.ghost")
	_assert(asset.is_unavailable(), "a preset with an uninstalled device is unavailable")
	_assert(asset.get_folder_menu_state() == FOLDER_DISABLED, "an unavailable preset greys the entry")
	_assert(asset.containing_folder() == "/abs/presets", "the preset's file still resolves while greyed")


func _test_empty_path_is_disabled() -> void:
	var asset: Object = _preset("", "sonara.builtin.delay")
	_assert(asset.get_folder_menu_state() == FOLDER_DISABLED, "an empty path greys the entry")
	_assert(asset.get_file_path().is_empty(), "an empty path has no file")
	_assert(asset.containing_folder().is_empty(), "an empty path has no folder")


func _test_builtin_device_is_hidden() -> void:
	var asset: Object = _asset(TYPE_DEVICE, "sonara.builtin.delay")
	_assert(not asset.is_unavailable(), "device assets are never 'unavailable'")
	_assert(asset.get_folder_menu_state() == FOLDER_HIDDEN, "a built-in device gets no entry")
	_assert(asset.get_file_path().is_empty(), "a built-in device has no file")
	_assert(asset.containing_folder().is_empty(), "a built-in device has no folder")


func _test_plugin_device_maps_to_plugin_file() -> void:
	var asset: Object = _asset(TYPE_DEVICE, "com.example.reverb")
	_assert(asset.get_folder_menu_state() == FOLDER_ENABLED, "a plugin device gets the entry")
	_assert(asset.get_file_path() == "/abs/plugins/example_reverb.clap", "the entry targets the plugin file")
	_assert(asset.containing_folder() == "/abs/plugins", "the plugin's folder comes from its file")


func _test_unknown_device_is_hidden() -> void:
	var asset: Object = _asset(TYPE_DEVICE, "com.unknown.widget")
	_assert(asset.get_folder_menu_state() == FOLDER_HIDDEN, "an unregistered device id gets no entry")


func _test_plugin_without_file_is_hidden() -> void:
	var device := Device.new("com.no.file", "No File", Device.DeviceCategory.Effect, Device.DeviceType.CLAP)
	_asset_service.device_registry._devices["com.no.file"] = device
	var asset: Object = _asset(TYPE_DEVICE, "com.no.file")
	_assert(asset.get_folder_menu_state() == FOLDER_HIDDEN, "a plugin with no file gets no entry")
	_asset_service.device_registry._devices.erase("com.no.file")


## Instantiate the real Browser scene and drive the menu builder directly.
## `popup()` itself (and the signal connections that lead there) can't be
## exercised headless — that wiring is verified by code read.
func _test_browser_menu_wiring() -> void:
	_browser = (load("res://browser/Browser.tscn") as PackedScene).instantiate()
	root.add_child(_browser)
	await process_frame

	var audio: Object = _asset(TYPE_AUDIO, "/abs/samples/kick.wav")
	var plugin: Object = _asset(TYPE_DEVICE, "com.example.reverb")
	var unavailable: Object = _preset("/abs/presets/ghost.sonpreset", "com.missing.ghost")
	var builtin: Object = _asset(TYPE_DEVICE, "sonara.builtin.delay")

	_assert(_browser._prepare_asset_context_menu(audio), "a file-backed asset opens the menu")
	_assert(_browser._context_menu.get_item_text(0) == "Open in Containing Folder", "the menu offers 'Open in Containing Folder'")
	_assert(not _browser._context_menu.is_item_disabled(0), "the entry is enabled for a file")
	_assert(_browser._context_menu_asset == audio, "the menu targets the clicked asset")

	_assert(_browser._prepare_asset_context_menu(plugin), "a plugin device opens the menu")
	_assert(not _browser._context_menu.is_item_disabled(0), "the entry is enabled for a plugin")

	_assert(_browser._prepare_asset_context_menu(unavailable), "an unavailable preset still gets a menu")
	_assert(_browser._context_menu.is_item_disabled(0), "the entry is greyed for an unavailable preset")

	_assert(not _browser._prepare_asset_context_menu(builtin), "a built-in device gets no menu")
	_assert(not _browser._prepare_asset_context_menu(null), "a row without an Asset (e.g. a section header) gets no menu")

	_browser.queue_free()
	await process_frame
