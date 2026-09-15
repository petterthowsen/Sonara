# test_fuzzy_resolve.gd
# Headless tests for DeviceToolUtil.resolve_asset_fuzzy and the create_track caller.
# Seeds AssetService/device_registry directly (no scan, no engine) since test mode skips
# provider init.
#
# DeviceToolUtil.gd, Asset.gd, Project.gd and Editor.gd all reference autoloads
# (AssetService, Settings) by bare name. Those identifiers only resolve once the engine has
# processed a frame, so — like test_tool_results.gd and test_asset_search.gd — this suite
# loads them dynamically via load() after TestBase's startup wait, instead of referencing
# their class names, which the compiler would otherwise try to resolve while parsing this
# file, before any frame has run. The `Sonara` and `AssetService` autoload nodes themselves
# are fetched with get_node() for the same reason.
# Run: godot --headless --path Godot -s ai/tests/test_fuzzy_resolve.gd -- --test
extends TestBase

var _asset_service: Node
var _sonara: Node
var _device_tool_util: GDScript
var _asset_script: GDScript
var _project_script: GDScript
var _editor_script: GDScript
var _create_track_tool: GDScript


func suite_name() -> String:
	return "Fuzzy device/asset lookup tests"


func run_tests() -> void:
	_asset_service = root.get_node("AssetService")
	_sonara = root.get_node("Sonara")
	_device_tool_util = load("res://ai/tools/DeviceToolUtil.gd")
	_asset_script = load("res://browser/Asset.gd")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_create_track_tool = load("res://ai/tools/CreateTrackTool.gd")
	_register_device("sonara.builtin.drum_machine", "Drum Machine")
	_register_device("sonara.builtin.delay", "Delay")
	_register_device("sonara.builtin.tape_delay", "Tape Delay")
	_register_device("sonara.builtin.room_reverb", "Room Reverb")
	_register_device("sonara.builtin.hall_reverb", "Hall Reverb")
	_test_resolve_device_id_typo()
	_test_ambiguous_query_suggests_both()
	_test_exact_name_wins_over_other_matches()
	_test_unknown_id_fails_without_side_effects()


## Register a fake built-in Device with `AssetService.device_registry` and a matching Asset,
## the same way a real `/builtin/info` payload would end up in both places.
func _register_device(device_id: String, title: String) -> void:
	var device := Device.new(device_id, title, Device.DeviceCategory.Instrument, Device.DeviceType.BuiltIn)
	device.title = title
	_asset_service.device_registry._devices[device_id] = device
	var asset: Object = _asset_script.new()
	asset.type = 2  # Asset.TYPE.Device
	asset.path = device_id
	asset.name = title
	_asset_service._assets_by_path[device_id] = asset


func _test_resolve_device_id_typo() -> void:
	var result: Dictionary = _device_tool_util.resolve_asset_fuzzy({"device_id": "drum_machine"})
	_assert(result.get("ok", true), "drum_machine resolves")
	var asset: Object = result.asset
	_assert(asset.path == "sonara.builtin.drum_machine", "resolves to the real builtin id")
	_assert(str(result.note).contains("drum_machine") and str(result.note).contains("Drum Machine"), "note explains the resolution: %s" % result.note)


func _test_ambiguous_query_suggests_both() -> void:
	# "reverb" matches both Room Reverb and Hall Reverb, and neither is an exact name match,
	# so the tool must ask "did you mean" instead of guessing.
	var result: Dictionary = _device_tool_util.resolve_asset_fuzzy({"device_id": "reverb"})
	_assert(result.get("ok") == false, "'reverb' matches more than one device")
	_assert(str(result.error).contains("Did you mean"), "ambiguous fail mentions 'Did you mean': %s" % result.error)
	_assert(str(result.error).contains("Room Reverb") and str(result.error).contains("Hall Reverb"), "both candidates listed: %s" % result.error)


func _test_exact_name_wins_over_other_matches() -> void:
	var result: Dictionary = _device_tool_util.resolve_asset_fuzzy({"device_id": "delay"})
	_assert(result.get("ok", true), "'delay' resolves despite 'Tape Delay' also matching")
	var asset: Object = result.asset
	_assert(asset.path == "sonara.builtin.delay", "exact name match picks plain Delay, got %s" % asset.path)


func _test_unknown_id_fails_without_side_effects() -> void:
	var result: Dictionary = _device_tool_util.resolve_asset_fuzzy({"device_id": "nonexistent_widget_xyz"})
	_assert(result.get("ok") == false, "unknown device id fails")
	_assert(str(result.error).contains("nonexistent_widget_xyz"), "error names the bad id: %s" % result.error)

	# create_track must not leave a track behind when the device can't be resolved.
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	_sonara.editor = editor
	var tool: Object = _create_track_tool.new()
	var before: int = project.tracks.size()
	var out: Dictionary = tool.execute({"name": "Bad Track", "kind": "instrument", "device_id": "nonexistent_widget_xyz"})
	_assert(out.get("ok") == false, "create_track fails when the device can't be resolved")
	_assert(project.tracks.size() == before, "no track was created on a failed resolve")
