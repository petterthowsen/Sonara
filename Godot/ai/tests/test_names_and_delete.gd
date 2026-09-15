# test_names_and_delete.gd
# Headless tests for Phase 5 of the AI names plan: tools resolve tracks/channels/route targets
# by name, legacy `*_id` arguments fail with a replacement hint, unknown names list near
# matches, the `delete` tool, and no tool schema exposes an id other than `device_id`.
#
# Project, Track, Editor and the tools reference autoloads (Sonara) by bare name, so — like
# test_fuzzy_resolve.gd — they are loaded with load() inside run_tests() instead of being
# named by class.
# Run: godot --headless --path Godot -s ai/tests/test_names_and_delete.gd -- --test
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _ai_tool: GDScript
var _tool_registry_script: GDScript
var _create_track_tool: GDScript
var _delete_tool: GDScript
var _set_mixer_tool: GDScript
var _route_channel_tool: GDScript


func suite_name() -> String:
	return "AI names and delete tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_ai_tool = load("res://ai/tools/AiTool.gd")
	_tool_registry_script = load("res://ai/tools/ToolRegistry.gd")
	_create_track_tool = load("res://ai/tools/CreateTrackTool.gd")
	_delete_tool = load("res://ai/tools/DeleteTool.gd")
	_set_mixer_tool = load("res://ai/tools/SetMixerTool.gd")
	_route_channel_tool = load("res://ai/tools/RouteChannelTool.gd")
	_test_unknown_track_lists_near_matches()
	await _test_legacy_track_id_gives_hint()
	_test_delete_linked_pair()
	_test_delete_bus_only()
	_test_delete_folder()
	_test_route_target_resolution()
	_test_no_schema_exposes_ids_except_device_id()


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	_sonara.editor = editor
	return {"project": project, "editor": editor}


func _test_unknown_track_lists_near_matches() -> void:
	var s := _setup()
	s.project.create_instrument_track("Drums")
	var tool: Object = _set_mixer_tool.new()
	var out: Dictionary = tool.execute({"channel": "Drum", "volume_db": -3.0})
	_assert(out.get("ok") == false, "unknown channel name fails")
	_assert(str(out.get("error", "")).contains("Did you mean") and str(out.get("error", "")).contains("Drums"), "near matches listed: %s" % out.get("error", ""))


func _test_legacy_track_id_gives_hint() -> void:
	var s := _setup()
	s.project.create_instrument_track("Drums")
	var reg: Object = _tool_registry_script.create_default()
	var out: Dictionary = await reg.execute("create_clip", {"track_id": 0, "name": "Groove"})
	_assert(out.get("ok") == false, "legacy track_id is refused")
	_assert(str(out.get("error", "")).contains("track_id is gone") and str(out.get("error", "")).contains("track:"), "hint names the replacement: %s" % out.get("error", ""))
	var ch_out: Dictionary = await reg.execute("create_track", {"channel_id": 1, "name": "Bass", "kind": "instrument"})
	_assert(ch_out.get("ok") == false and str(ch_out.get("error", "")).contains("channel_id is gone"), "channel_id is refused too")


func _test_delete_linked_pair() -> void:
	var s := _setup()
	s.project.create_instrument_track("Drums")
	var tool: Object = _delete_tool.new()
	var out: Dictionary = tool.execute({"name": "Drums"})
	_assert(out.get("ok", false), "delete succeeds on a linked pair: %s" % out.get("error", ""))
	_assert(str(out.get("text", "")).contains("track and channel") and str(out.get("text", "")).contains("Drums"), "text mentions track and channel: %s" % out.get("text", ""))
	_assert(s.project.tracks.is_empty(), "track removed")
	_assert(s.project.channels.size() == 1, "only Master left")


func _test_delete_bus_only() -> void:
	var s := _setup()
	s.project.create_bus_channel("FX")
	var tool: Object = _delete_tool.new()
	var out: Dictionary = tool.execute({"name": "FX"})
	_assert(out.get("ok", false), "delete succeeds on a bus-only name: %s" % out.get("error", ""))
	_assert(str(out.get("text", "")).contains("channel") and not str(out.get("text", "")).contains("track"), "text mentions only a channel: %s" % out.get("text", ""))
	_assert(s.project.get_channel_by_id(2) == null, "bus channel removed")


func _test_delete_folder() -> void:
	var s := _setup()
	s.project.create_folder_track("Group Folder", false)
	var tool: Object = _delete_tool.new()
	var out: Dictionary = tool.execute({"name": "Group Folder"})
	_assert(out.get("ok", false), "delete succeeds on a plain folder: %s" % out.get("error", ""))
	_assert(str(out.get("text", "")).contains("track") and not str(out.get("text", "")).contains("channel"), "text mentions only a track: %s" % out.get("text", ""))
	_assert(s.project.tracks.is_empty(), "folder track removed")


func _test_route_target_resolution() -> void:
	var s := _setup()
	var bus: Object = s.project.create_bus_channel("FX")
	_assert(_ai_tool.resolve_route_target(s.project, "Master") == 1, "Master resolves to 1")
	_assert(_ai_tool.resolve_route_target(s.project, "None") == 0, "None resolves to 0")
	_assert(_ai_tool.resolve_route_target(s.project, "Hardware Out") == 1000, "Hardware Out resolves to 1000")
	_assert(_ai_tool.resolve_route_target(s.project, "Hardware Out 2") == 1002, "Hardware Out 2 resolves to 1002")
	_assert(_ai_tool.resolve_route_target(s.project, "FX") == bus.id, "channel name resolves to its id")
	var missing = _ai_tool.resolve_route_target(s.project, "Nope")
	_assert(missing is Dictionary and missing.get("ok") == false, "unknown route target fails")

	# route_channel end to end, by name.
	s.project.create_instrument_track("Drums")
	var route_tool: Object = _route_channel_tool.new()
	var out: Dictionary = route_tool.execute({"channel": "Drums", "output": "FX"})
	_assert(out.get("ok", false), "route_channel resolves names: %s" % out.get("error", ""))
	_assert(out.data.get("output") == "FX", "compact_channel reports the route target by name: %s" % out.data)


func _test_no_schema_exposes_ids_except_device_id() -> void:
	var reg: Object = _tool_registry_script.create_default()
	for tool in reg.get_openrouter_tools():
		var fn: Dictionary = tool.function
		var props: Dictionary = fn.parameters.get("properties", {})
		for key in props.keys():
			var k := str(key)
			if k.ends_with("_id"):
				_assert(k == "device_id", "%s.%s: only device_id may be an *_id schema field" % [fn.name, k])
