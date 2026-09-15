# test_clip_placement.gd
# Headless tests for AiTool.resolve_placement and its callers (create_clip / place_clip):
# where a new clip goes with no explicit `start`, and refusing overlaps.
#
# Project, Track, Editor and the clip tools reference autoloads (AudioEngineOSC, Sonara) by
# bare name, so — like test_fuzzy_resolve.gd — they are loaded with load() inside run_tests()
# instead of being named by class. The range and playhead are faked directly on a bare
# Editor instance: `editor.test_time_range_override` and `editor.playhead_ticks`.
# Run: godot --headless --path Godot -s ai/tests/test_clip_placement.gd -- --test
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _create_clip_tool: GDScript
var _place_clip_tool: GDScript
var _clip_text_time: GDScript

const NO_RANGE := {"has": false, "start": 0, "has_end": false, "end": 0}


func suite_name() -> String:
	return "Clip placement tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_create_clip_tool = load("res://ai/tools/CreateClipTool.gd")
	_place_clip_tool = load("res://ai/tools/PlaceClipTool.gd")
	_clip_text_time = load("res://ai/clip_text/ClipTextTime.gd")
	_test_empty_track_ignores_playhead()
	_test_nonempty_track_uses_playhead_bar()
	_test_range_with_end_sets_length()
	_test_overlap_refused()
	_test_explicit_start_used_exactly()
	_test_bad_text_creates_no_clip()


## New project + editor wired together, no arranger (test mode / headless).
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	editor.test_time_range_override = NO_RANGE
	editor.playhead_ticks = 0
	_sonara.editor = editor
	var track_info: Dictionary = project.create_instrument_track("Drums")
	return {"project": project, "editor": editor, "track": track_info.track}


func _tpb(project: Object) -> int:
	return _clip_text_time.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)


func _test_empty_track_ignores_playhead() -> void:
	var s := _setup()
	s.editor.playhead_ticks = 13  # drifted playhead; must not matter on an empty track
	var tool: Object = _create_clip_tool.new()
	var out: Dictionary = tool.execute({"name": "A", "track": s.track.name, "bars": 1})
	_assert(out.get("ok") == false or out.get("ok") == true, "sanity")
	_assert(out.get("ok", false), "create_clip succeeds on an empty track: %s" % out.get("error", ""))
	_assert(out.data.get("placements", [{}])[0].get("start_ticks", -1) == 0, "empty track places at tick 0 despite playhead 13: %s" % out.data)


func _test_nonempty_track_uses_playhead_bar() -> void:
	var s := _setup()
	var tpb := _tpb(s.project)
	# Seed one clip near the start so the track is no longer empty.
	var seed_tool: Object = _create_clip_tool.new()
	var seeded: Dictionary = seed_tool.execute({"name": "Seed", "track": s.track.name, "start": "1.1.000", "bars": 1})
	_assert(seeded.get("ok", false), "seed clip created: %s" % seeded.get("error", ""))
	# Playhead at bar 5 (0-indexed bar 4) + 13 ticks; must round down to bar 5.
	s.editor.playhead_ticks = 4 * tpb + 13
	var tool: Object = _create_clip_tool.new()
	var out: Dictionary = tool.execute({"name": "B", "track": s.track.name, "bars": 1})
	_assert(out.get("ok", false), "create_clip succeeds: %s" % out.get("error", ""))
	var start_ticks: int = out.data.placements[out.data.placements.size() - 1].start_ticks
	_assert(start_ticks == 4 * tpb, "rounds playhead down to bar 5 (tick %d), got %d" % [4 * tpb, start_ticks])


func _test_range_with_end_sets_length() -> void:
	var s := _setup()
	var tpb := _tpb(s.project)
	s.editor.test_time_range_override = {"has": true, "start": 4 * tpb, "has_end": true, "end": 8 * tpb}
	var tool: Object = _create_clip_tool.new()
	var out: Dictionary = tool.execute({"name": "Range Clip", "track": s.track.name})
	_assert(out.get("ok", false), "create_clip succeeds with an active range: %s" % out.get("error", ""))
	var inst: Dictionary = out.data.placements[0]
	_assert(inst.start_ticks == 4 * tpb, "starts at range start (bar 5): %s" % inst)
	_assert(inst.duration_ticks == 4 * tpb, "length comes from the range (4 bars): %s" % inst)


func _test_overlap_refused() -> void:
	var s := _setup()
	var create_tool: Object = _create_clip_tool.new()
	var first: Dictionary = create_tool.execute({"name": "City Pop Groove", "track": s.track.name, "start": "1.1.000", "bars": 2})
	_assert(first.get("ok", false), "first clip created: %s" % first.get("error", ""))
	var before_clip_count: int = s.project.clips.size()

	var second_tool: Object = _create_clip_tool.new()
	var out: Dictionary = second_tool.execute({"name": "Overlapper", "track": s.track.name, "start": "1.1.000", "bars": 2})
	_assert(out.get("ok") == false, "overlapping create_clip is refused")
	_assert(str(out.get("error", "")).contains("City Pop Groove"), "error names the occupying clip: %s" % out.get("error", ""))
	_assert(str(out.get("error", "")).contains("Next free bar: 3"), "error names the next free bar: %s" % out.get("error", ""))
	_assert(s.project.clips.size() == before_clip_count, "no clip left behind by a refused overlap")

	# place_clip must refuse the same way.
	var place_tool: Object = _place_clip_tool.new()
	var place_out: Dictionary = place_tool.execute({"clip": "City Pop Groove", "track": s.track.name, "start": "1.1.000"})
	_assert(place_out.get("ok") == false, "overlapping place_clip is refused")

	# Adjacent placement (touching edges) must be allowed.
	var adjacent_tool: Object = _create_clip_tool.new()
	var adjacent: Dictionary = adjacent_tool.execute({"name": "Adjacent", "track": s.track.name, "start": "3.1.000", "bars": 1})
	_assert(adjacent.get("ok", false), "a clip starting exactly where another ends is allowed: %s" % adjacent.get("error", ""))


func _test_explicit_start_used_exactly() -> void:
	var s := _setup()
	s.editor.playhead_ticks = 999999  # must be ignored; start is explicit
	var tool: Object = _create_clip_tool.new()
	var out: Dictionary = tool.execute({"name": "Exact", "track": s.track.name, "start": "1.1.013", "bars": 1})
	_assert(out.get("ok", false), "create_clip succeeds with explicit start: %s" % out.get("error", ""))
	var start_ticks: int = out.data.placements[0].start_ticks
	_assert(start_ticks == 13, "explicit start 1.1.013 is used exactly, got %d" % start_ticks)


## A create_clip whose text fails must not leave an empty clip behind (city_pop_5 chat).
func _test_bad_text_creates_no_clip() -> void:
	var s := _setup()
	var tool: Object = _create_clip_tool.new()
	var out: Dictionary = tool.execute({"name": "Keys", "track": s.track.name, "bars": 2, "text": "add 1.1.000 C3 4 v80"})
	_assert(not out.get("ok", true), "bare-number duration fails")
	_assert(str(out.get("error", "")).contains("No clip was created"), "error says nothing was created: %s" % out.get("error", ""))
	_assert(s.project.clips.is_empty(), "no clip left in the pool")
	var chords: Dictionary = tool.execute({"name": "Keys", "track": s.track.name, "bars": 2, "format": "pitched", "text": "add 1.1.000 C3,E3,G3 1/2 v90"})
	_assert(chords.get("ok", false), "chord text under format=pitched creates the clip: %s" % chords.get("error", ""))
	_assert(int(chords.data.get("note_count", 0)) == 3, "three chord notes: %s" % chords.data)
