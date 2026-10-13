# AI create_track placement: `into` and an `output` naming a group or folder bus nest the new track.
# Run: godot --headless --path Godot -s ai/tests/test_create_track_into.gd -- --test
# Scripts are load()ed at runtime: they reference autoloads, which don't resolve at parse time.
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _create_tool: GDScript


func suite_name() -> String:
	return "AI create_track into tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_create_tool = load("res://ai/tools/CreateTrackTool.gd")
	await _test_output_group_nests()
	await _test_into_group()
	await _test_into_folder_keeps_output()
	await _test_output_plain_bus_routes_only()
	await _test_bad_into_creates_nothing()


func _setup() -> Object:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	_sonara.editor = editor
	return project


func _run(args: Dictionary) -> Dictionary:
	return await _create_tool.new().execute(args)


func _names(project: Object) -> Array:
	var out: Array = []
	for t in project.get_visual_track_list():
		out.append(t.name)
	return out


func _test_output_group_nests() -> void:
	var p := _setup()
	await _run({"kind": "group", "name": "Strings"})
	await _run({"kind": "instrument", "name": "Violins", "output": "Strings"})
	var out := await _run({"kind": "instrument", "name": "Cellos", "output": "Strings"})
	var group: Object = p.find_by_name("Strings").get("track")
	var violins: Object = p.find_by_name("Violins").get("track")
	var cellos: Object = p.find_by_name("Cellos").get("track")
	_assert(out.ok, "create ok: %s" % out)
	_assert(violins.parent_track_id == group.id and cellos.parent_track_id == group.id, "both inside the group")
	_assert(_names(p) == ["Strings", "Violins", "Cellos"], "added last, in order: %s" % [_names(p)])
	var group_ch: Object = group.get_linked_channel()
	_assert(cellos.get_linked_channel().output_channel_id == group_ch.id, "routes to the group channel")
	_assert(cellos.get_linked_channel().parent_channel_id == group_ch.id, "channel nested in the group")
	_assert(str(out.get("text", "")).contains("inside \"Strings\""), "text says inside: %s" % out)


func _test_into_group() -> void:
	var p := _setup()
	await _run({"kind": "group", "name": "Brass"})
	var out := await _run({"kind": "instrument", "name": "Horns", "into": "Brass", "output": "Master"})
	var group: Object = p.find_by_name("Brass").get("track")
	var horns: Object = p.find_by_name("Horns").get("track")
	_assert(horns.parent_track_id == group.id, "into places inside the group")
	_assert(horns.get_linked_channel().output_channel_id == group.get_linked_channel().id, "output stays on the group")
	_assert(str(out.get("text", "")).contains("output ignored"), "warns that output was ignored: %s" % out)


func _test_into_folder_keeps_output() -> void:
	var p := _setup()
	await _run({"kind": "folder", "name": "Sketches"})
	await _run({"kind": "instrument", "name": "Verb Bus"})
	await _run({"kind": "instrument", "name": "Pad", "into": "Sketches", "output": "Verb Bus"})
	var folder: Object = p.find_by_name("Sketches").get("track")
	var pad: Object = p.find_by_name("Pad").get("track")
	var bus: Object = p.find_by_name("Verb Bus").get("channel")
	_assert(pad.parent_track_id == folder.id, "inside the plain folder")
	_assert(pad.get_linked_channel().output_channel_id == bus.id, "plain folder keeps the requested output")


func _test_output_plain_bus_routes_only() -> void:
	var p := _setup()
	await _run({"kind": "instrument", "name": "Target"})
	await _run({"kind": "instrument", "name": "Source", "output": "Target"})
	var src: Object = p.find_by_name("Source").get("track")
	_assert(src.parent_track_id == -1, "plain channel output does not nest")
	_assert(src.get_linked_channel().output_channel_id == p.find_by_name("Target").get("channel").id, "routed")


func _test_bad_into_creates_nothing() -> void:
	var p := _setup()
	await _run({"kind": "instrument", "name": "Lead"})
	var count: int = p.tracks.size()
	var out := await _run({"kind": "instrument", "name": "X", "into": "Lead"})
	_assert(not out.ok, "into a non-container fails")
	out = await _run({"kind": "instrument", "name": "Y", "into": "Nowhere"})
	_assert(not out.ok, "unknown into fails")
	_assert(p.tracks.size() == count, "nothing created")
