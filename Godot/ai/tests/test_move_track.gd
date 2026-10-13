# AI move_track: reorder, nest, un-nest, refusals, hierarchy in list_tracks.
# Run: godot --headless --path Godot -s ai/tests/test_move_track.gd -- --test
# Scripts are load()ed at runtime: they reference autoloads, which don't resolve at parse time.
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _move_tool: GDScript
var _list_tool: GDScript
var _reorder: GDScript
var _channel: GDScript


func suite_name() -> String:
	return "AI move_track tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_move_tool = load("res://ai/tools/MoveTrackTool.gd")
	_list_tool = load("res://ai/tools/ListTracksTool.gd")
	_reorder = load("res://history/commands/TrackReorderCommand.gd")
	_channel = load("res://data/Channel.gd")
	_test_reorder()
	_test_nest_and_unnest()
	_test_refusals()
	_test_channel_branch()
	_test_list_tracks()


func _setup() -> Object:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	_sonara.editor = editor
	return project


func _names(project: Object) -> Array:
	var out: Array = []
	for t in project.get_visual_track_list():
		out.append(t.name)
	return out


func _run(args: Dictionary) -> Dictionary:
	return _move_tool.new().execute(args)


func _test_reorder() -> void:
	var p := _setup()
	p.create_instrument_track("A")
	p.create_instrument_track("B")
	p.create_instrument_track("C")
	var out := _run({"tracks": ["C"], "after": "A"})
	_assert(out.ok and _names(p) == ["A", "C", "B"], "after A: %s %s" % [out, _names(p)])
	out = _run({"tracks": ["B"], "after": "start"})
	_assert(out.ok and _names(p) == ["B", "A", "C"], "start: %s" % [_names(p)])
	out = _run({"tracks": ["B", "A"]})
	_assert(out.ok and _names(p) == ["C", "B", "A"], "block to end keeps order: %s" % [_names(p)])
	_sonara.editor.undo()
	_assert(_names(p) == ["B", "A", "C"], "undo: %s" % [_names(p)])
	_sonara.editor.redo()
	_assert(_names(p) == ["C", "B", "A"], "redo: %s" % [_names(p)])
	out = _run({"tracks": ["C"], "after": "start"})
	_assert(out.ok and out.text == "Already in place", "no-op reports in place: %s" % out)


func _test_nest_and_unnest() -> void:
	var p := _setup()
	var g = p.create_group_track("Band").track
	var a = p.create_instrument_track("A").track
	var b = p.create_instrument_track("B").track
	p.create_instrument_track("C")
	var gch = g.get_linked_channel()
	var out := _run({"tracks": ["B", "A"], "into": "Band"})
	_assert(out.ok, "nest ok: %s" % out)
	_assert(a.parent_track_id == g.id and b.parent_track_id == g.id, "parents set")
	_assert(_names(p) == ["Band", "B", "A", "C"], "order: %s" % [_names(p)])
	_assert(a.get_linked_channel().output_channel_id == gch.id, "A routes to the group")
	_assert(b.get_linked_channel().output_channel_id == gch.id, "B routes to the group")
	_sonara.editor.undo()
	_assert(a.parent_track_id == -1 and b.parent_track_id == -1, "undo restores parents")
	_assert(a.get_linked_channel().output_channel_id == 1, "undo restores routing")
	_assert(_names(p) == ["Band", "A", "B", "C"], "undo order: %s" % [_names(p)])
	_sonara.editor.redo()
	_assert(a.parent_track_id == g.id, "redo re-nests")
	out = _run({"tracks": ["A"], "into": "top", "after": "Band"})
	_assert(out.ok and a.parent_track_id == -1, "un-nest: %s" % out)
	_assert(a.get_linked_channel().output_channel_id == 1, "un-nested routes to master")
	_assert(_names(p) == ["Band", "B", "A", "C"], "un-nest order: %s" % [_names(p)])


func _test_refusals() -> void:
	var p := _setup()
	p.create_group_track("Outer")
	p.create_group_track("Inner")
	p.create_instrument_track("Lead")
	p.create_instrument_track("Pad")
	_run({"tracks": ["Inner"], "into": "Outer"})
	var before := _names(p)
	var layout: Variant = _reorder.capture_layout(p)
	var out := _run({"tracks": ["Outer"], "into": "Inner"})
	_assert(not out.ok and out.error.contains("Nothing was changed"), "group into own child refused: %s" % out)
	out = _run({"tracks": ["Pad"], "into": "Lead"})
	_assert(not out.ok and out.error.contains("not a group or folder"), "into instrument refused: %s" % out)
	out = _run({"tracks": ["Pad"], "into": "Outer", "after": "Lead"})
	_assert(not out.ok and out.error.contains("not inside"), "after under other parent refused: %s" % out)
	out = _run({"tracks": ["Pa"]})
	_assert(not out.ok and out.error.contains("Did you mean: Pad"), "unknown name suggests: %s" % out)
	out = _run({"tracks": ["Pad", "pad"]})
	_assert(not out.ok, "duplicate refused")
	out = _run({"tracks": ["Pad"], "into": "Nope"})
	_assert(not out.ok, "unknown into refused")
	_assert(_names(p) == before, "layout unchanged after refusals")
	_assert(_reorder.layouts_equal(layout, _reorder.capture_layout(p)), "layout snapshot equal")


func _test_channel_branch() -> void:
	var p := _setup()
	p.create_group_track("Band")
	var bus = p.create_bus_channel("Verb")
	var out := _run({"tracks": ["Verb"], "into": "Band"})
	_assert(not out.ok and out.error.contains("Nothing was changed"), "bus nest refused by mixer rules: %s" % out)
	out = _run({"tracks": ["Verb"], "into": "top"})
	_assert(not out.ok, "un-nesting a root bus refused: %s" % out)
	# A track-less audio channel can nest and un-nest through the channel branch.
	var ch = p.create_channel("Free", _channel.ChannelType.AUDIO)
	var grp = p.find_by_name("Band").channel
	out = _run({"tracks": ["Free"], "into": "Band"})
	_assert(out.ok and ch.parent_channel_id == grp.id, "track-less channel nested: %s" % out)
	out = _run({"tracks": ["Free"], "into": "top"})
	_assert(out.ok and ch.parent_channel_id == -1, "track-less channel un-nested: %s" % out)
	out = _run({"tracks": ["Verb", "Band"], "into": "top"})
	_assert(not out.ok and out.error.contains("separate calls"), "mixed refused: %s" % out)
	_assert(bus.parent_channel_id == -1, "bus untouched")


func _test_list_tracks() -> void:
	var p := _setup()
	p.create_group_track("Band")
	p.create_instrument_track("Solo")
	p.create_instrument_track("Keys")
	_run({"tracks": ["Keys"], "into": "Band"})
	var out: Dictionary = _list_tool.new().execute({})
	var rows: Array = out.data.tracks
	var order: Array = []
	for r in rows:
		order.append(r.name)
	_assert(order == ["Band", "Keys", "Solo"], "tree order: %s" % [order])
	_assert(rows[1].get("parent") == "Band" and not rows[0].has("parent"), "parent field: %s" % [rows])
