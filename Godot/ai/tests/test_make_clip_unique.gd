# test_make_clip_unique.gd
# Headless tests for MakeClipUniqueTool: refusing to detach a clip with only one
# placement, disambiguating multiple placements, and the actual detach.
# Run: godot --headless --path Godot -s ai/tests/test_make_clip_unique.gd -- --test
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _create_clip_tool: GDScript
var _place_clip_tool: GDScript
var _make_unique_tool: GDScript

const NO_RANGE := {"has": false, "start": 0, "has_end": false, "end": 0}


func suite_name() -> String:
	return "Make clip unique tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_create_clip_tool = load("res://ai/tools/CreateClipTool.gd")
	_place_clip_tool = load("res://ai/tools/PlaceClipTool.gd")
	_make_unique_tool = load("res://ai/tools/MakeClipUniqueTool.gd")
	_test_single_placement_refused()
	_test_ambiguous_placement_refused()
	_test_no_match_lists_placements()
	_test_detach_by_track()
	_test_detached_clip_is_independent()


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	editor.test_time_range_override = NO_RANGE
	editor.playhead_ticks = 0
	_sonara.editor = editor
	var track_info: Dictionary = project.create_instrument_track("Drums")
	return {"project": project, "editor": editor, "track": track_info.track}


func _test_single_placement_refused() -> void:
	var s := _setup()
	var create_tool: Object = _create_clip_tool.new()
	var created: Dictionary = create_tool.execute({"name": "Loop", "track": s.track.name, "start": "1.1.000", "bars": 1})
	_assert(created.get("ok", false), "clip created: %s" % created.get("error", ""))

	var tool: Object = _make_unique_tool.new()
	var out: Dictionary = tool.execute({"clip": "Loop"})
	_assert(out.get("ok") == false, "a clip with one placement has nothing to detach")
	_assert(str(out.get("error", "")).contains("only one placement"), "error explains why: %s" % out.get("error", ""))


func _test_ambiguous_placement_refused() -> void:
	var s := _setup()
	var create_tool: Object = _create_clip_tool.new()
	var created: Dictionary = create_tool.execute({"name": "Loop", "track": s.track.name, "start": "1.1.000", "bars": 1})
	_assert(created.get("ok", false), "clip created: %s" % created.get("error", ""))
	var place_tool: Object = _place_clip_tool.new()
	var placed: Dictionary = place_tool.execute({"clip": "Loop", "track": s.track.name, "start": "3.1.000"})
	_assert(placed.get("ok", false), "second placement added: %s" % placed.get("error", ""))

	var tool: Object = _make_unique_tool.new()
	var out: Dictionary = tool.execute({"clip": "Loop"})
	_assert(out.get("ok") == false, "ambiguous placements without a track are refused")
	_assert(str(out.get("error", "")).contains("2 matching placements"), "error names how many: %s" % out.get("error", ""))


func _test_no_match_lists_placements() -> void:
	var s := _setup()
	var create_tool: Object = _create_clip_tool.new()
	var created: Dictionary = create_tool.execute({"name": "Loop", "track": s.track.name, "start": "1.1.000", "bars": 1})
	_assert(created.get("ok", false), "clip created: %s" % created.get("error", ""))
	var place_tool: Object = _place_clip_tool.new()
	var placed: Dictionary = place_tool.execute({"clip": "Loop", "track": s.track.name, "start": "3.1.000"})
	_assert(placed.get("ok", false), "second placement added: %s" % placed.get("error", ""))

	var tool: Object = _make_unique_tool.new()
	var out: Dictionary = tool.execute({"clip": "Loop", "start": "5.1.000"})
	_assert(out.get("ok") == false, "a start with no placement is refused")
	var err := str(out.get("error", ""))
	_assert(err.contains("Drums @ 1.1.000") and err.contains("Drums @ 3.1.000"), "error lists the existing placements: %s" % err)


func _test_detach_by_track() -> void:
	var s := _setup()
	var create_tool: Object = _create_clip_tool.new()
	var created: Dictionary = create_tool.execute({"name": "Loop", "track": s.track.name, "start": "1.1.000", "bars": 1})
	_assert(created.get("ok", false), "clip created: %s" % created.get("error", ""))
	var place_tool: Object = _place_clip_tool.new()
	var placed: Dictionary = place_tool.execute({"clip": "Loop", "track": s.track.name, "start": "3.1.000"})
	_assert(placed.get("ok", false), "second placement added: %s" % placed.get("error", ""))
	var before_clip_count: int = s.project.clips.size()

	var tool: Object = _make_unique_tool.new()
	var out: Dictionary = tool.execute({"clip": "Loop", "track": s.track.name, "start": "3.1.000"})
	_assert(out.get("ok", false), "detach succeeds: %s" % out.get("error", ""))
	_assert(s.project.clips.size() == before_clip_count + 1, "a new clip was added to the pool")
	_assert(out.data.get("name", "") != "Loop", "the detached placement points at a differently-named clip: %s" % out.data)

	# The original clip still has exactly one placement left.
	var orig = s.project.clips.values().filter(func(c): return c.name == "Loop")[0]
	var remaining := 0
	for t in s.project.tracks:
		for inst in t.clip_instances:
			if inst.clip_id == orig.id:
				remaining += 1
	_assert(remaining == 1, "original clip keeps its other placement, got %d" % remaining)


func _test_detached_clip_is_independent() -> void:
	var s := _setup()
	var create_tool: Object = _create_clip_tool.new()
	var created: Dictionary = create_tool.execute({
		"name": "Loop", "track": s.track.name, "start": "1.1.000", "bars": 1,
		"format": "pitched", "text": "add 1.1.000 C3 1/4 v90",
	})
	_assert(created.get("ok", false), "clip created: %s" % created.get("error", ""))
	var place_tool: Object = _place_clip_tool.new()
	var placed: Dictionary = place_tool.execute({"clip": "Loop", "track": s.track.name, "start": "3.1.000"})
	_assert(placed.get("ok", false), "second placement added: %s" % placed.get("error", ""))

	var tool: Object = _make_unique_tool.new()
	var out: Dictionary = tool.execute({"clip": "Loop", "track": s.track.name, "start": "3.1.000"})
	_assert(out.get("ok", false), "detach succeeds: %s" % out.get("error", ""))
	var new_clip_name: String = out.data.get("name", "")

	var new_clip = s.project.clips.values().filter(func(c): return c.name == new_clip_name)[0]
	var orig_clip = s.project.clips.values().filter(func(c): return c.name == "Loop")[0]
	_assert(new_clip.midi_notes.size() == 1, "detached clip carried over its notes")
	_assert(new_clip.id != orig_clip.id, "detached clip has its own id")

	# Editing the detached clip's note must not touch the original clip's notes.
	new_clip.midi_notes[0].velocity = 42
	_assert(orig_clip.midi_notes[0].velocity != 42, "editing the detached clip leaves the original clip alone")
