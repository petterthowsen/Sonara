# test_clip_range_tools.gd
# Headless tests for delete_clips, move_clips and overwrite on place_clip (ClipRangeActions):
# splitting at span edges, refusing occupied destinations, overwrite, and one-step undo.
# Scripts are load()ed inside run_tests() for the same autoload reason as test_clip_placement.gd.
# Run: godot --headless --path Godot -s ai/tests/test_clip_range_tools.gd -- --test
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _create_clip_tool: GDScript
var _place_clip_tool: GDScript
var _move_clips_tool: GDScript
var _delete_clips_tool: GDScript
var _clip_text_time: GDScript

const NO_RANGE := {"has": false, "start": 0, "has_end": false, "end": 0}


func suite_name() -> String:
	return "Clip range tool tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_create_clip_tool = load("res://ai/tools/CreateClipTool.gd")
	_place_clip_tool = load("res://ai/tools/PlaceClipTool.gd")
	_move_clips_tool = load("res://ai/tools/MoveClipsTool.gd")
	_delete_clips_tool = load("res://ai/tools/DeleteClipsTool.gd")
	_clip_text_time = load("res://ai/clip_text/ClipTextTime.gd")
	_test_delete_splits_at_edges()
	_test_delete_by_clip_everywhere()
	_test_delete_uses_selected_range()
	_test_move_whole_clips_across_tracks()
	_test_move_cuts_partial_clip()
	_test_move_refuses_occupied_destination()
	_test_copy_with_overwrite()
	_test_move_track_filter()
	_test_place_clip_overwrite()


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	editor.test_time_range_override = NO_RANGE
	editor.playhead_ticks = 0
	_sonara.editor = editor
	var drums: Object = project.create_instrument_track("Drums").track
	var bass: Object = project.create_instrument_track("Bass").track
	var tpb: int = _clip_text_time.ticks_per_bar(project.ppq, project.time_numerator, project.time_denominator)
	return {"project": project, "editor": editor, "drums": drums, "bass": bass, "tpb": tpb}


func _create(name: String, track: Object, start: String, bars: int) -> void:
	var out: Dictionary = _create_clip_tool.new().execute({"name": name, "track": track.name, "start": start, "bars": bars})
	_assert(out.get("ok", false), "create %s: %s" % [name, out.get("error", "")])


## `[[start, duration, offset], ...]` for a track, by start.
func _layout(track: Object) -> Array:
	var rows: Array = []
	for inst in track.clip_instances:
		rows.append([inst.start_ticks, inst.duration_ticks, inst.clip_offset])
	rows.sort()
	return rows


func _test_delete_splits_at_edges() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("Long", s.drums, "1", 4)
	var before := _layout(s.drums)
	var out: Dictionary = _delete_clips_tool.new().execute({"start": "2", "end": "3"})
	_assert(out.get("ok", false), "delete_clips ok: %s" % out.get("error", ""))
	var want := [[0, tpb, 0], [2 * tpb, 2 * tpb, 2 * tpb]]
	_assert(_layout(s.drums) == want, "bar 2 cut out of a 4-bar clip: %s" % [_layout(s.drums)])
	s.editor.undo()
	_assert(_layout(s.drums) == before, "undo restores the clip in one step: %s" % [_layout(s.drums)])


func _test_delete_by_clip_everywhere() -> void:
	var s := _setup()
	_create("Kick", s.drums, "1", 1)
	_create("Line", s.bass, "1", 1)
	var placed: Dictionary = _place_clip_tool.new().execute({"clip": "Kick", "track": "Drums", "start": "3"})
	_assert(placed.get("ok", false), "second Kick placed: %s" % placed.get("error", ""))
	var out: Dictionary = _delete_clips_tool.new().execute({"clip": "kick"})
	_assert(out.get("ok", false), "delete by clip ok: %s" % out.get("error", ""))
	_assert(s.drums.clip_instances.is_empty(), "every Kick placement removed")
	_assert(s.bass.clip_instances.size() == 1, "other clips untouched")
	var no_span: Dictionary = _delete_clips_tool.new().execute({})
	_assert(no_span.get("ok") == false, "no span, range or clip is refused")


func _test_delete_uses_selected_range() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("A", s.drums, "1", 1)
	_create("B", s.drums, "2", 1)
	s.editor.test_time_range_override = {"has": true, "start": tpb, "has_end": true, "end": 2 * tpb}
	var out: Dictionary = _delete_clips_tool.new().execute({})
	_assert(out.get("ok", false), "delete in selected range ok: %s" % out.get("error", ""))
	_assert(_layout(s.drums) == [[0, tpb, 0]], "only bar 2 removed: %s" % [_layout(s.drums)])


func _test_move_whole_clips_across_tracks() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("Kick", s.drums, "1", 2)
	_create("Line", s.bass, "1", 2)
	var out: Dictionary = _move_clips_tool.new().execute({"start": "1", "end": "3", "to": "5"})
	_assert(out.get("ok", false), "move_clips ok: %s" % out.get("error", ""))
	_assert(_layout(s.drums) == [[4 * tpb, 2 * tpb, 0]], "drums moved to bar 5: %s" % [_layout(s.drums)])
	_assert(_layout(s.bass) == [[4 * tpb, 2 * tpb, 0]], "bass moved to bar 5: %s" % [_layout(s.bass)])
	_assert(str(out.get("text", "")).contains("Kick"), "result names the clips: %s" % out.get("text", ""))
	s.editor.undo()
	_assert(_layout(s.drums) == [[0, 2 * tpb, 0]] and _layout(s.bass) == [[0, 2 * tpb, 0]], "undo restores both tracks")


func _test_move_cuts_partial_clip() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("Long", s.drums, "1", 4)
	var out: Dictionary = _move_clips_tool.new().execute({"start": "3", "end": "5", "to": "9"})
	_assert(out.get("ok", false), "move tail ok: %s" % out.get("error", ""))
	var want := [[0, 2 * tpb, 0], [8 * tpb, 2 * tpb, 2 * tpb]]
	_assert(_layout(s.drums) == want, "bars 3-4 moved to bar 9 with offset: %s" % [_layout(s.drums)])


func _test_move_refuses_occupied_destination() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("A", s.drums, "1", 1)
	_create("B", s.drums, "3", 1)
	var before := _layout(s.drums)
	var out: Dictionary = _move_clips_tool.new().execute({"start": "1", "end": "2", "to": "3"})
	_assert(out.get("ok") == false, "moving onto B is refused")
	_assert(str(out.get("error", "")).contains("\"B\""), "error names B: %s" % out.get("error", ""))
	_assert(_layout(s.drums) == before, "refused move changes nothing: %s" % [_layout(s.drums)])
	var over: Dictionary = _move_clips_tool.new().execute({"start": "1", "end": "2", "to": "3", "overwrite": true})
	_assert(over.get("ok", false), "overwrite move ok: %s" % over.get("error", ""))
	_assert(_layout(s.drums) == [[2 * tpb, tpb, 0]], "A replaced B: %s" % [_layout(s.drums)])
	_assert(s.drums.clip_instances[0].clip.name == "A", "the remaining clip is A")


func _test_copy_with_overwrite() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("Long", s.drums, "1", 2)
	# Copy bars 1-2 one bar later: overlaps the original, so only overwrite allows it.
	var refused: Dictionary = _move_clips_tool.new().execute({"start": "1", "end": "3", "to": "2", "copy": true})
	_assert(refused.get("ok") == false, "overlapping copy refused")
	var out: Dictionary = _move_clips_tool.new().execute({"start": "1", "end": "3", "to": "2", "copy": true, "overwrite": true})
	_assert(out.get("ok", false), "overlapping copy with overwrite ok: %s" % out.get("error", ""))
	_assert(_layout(s.drums) == [[0, tpb, 0], [tpb, 2 * tpb, 0]], "original trimmed, copy at bar 2: %s" % [_layout(s.drums)])


func _test_move_track_filter() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("Kick", s.drums, "1", 1)
	_create("Line", s.bass, "1", 1)
	var out: Dictionary = _move_clips_tool.new().execute({"start": "1", "end": "2", "to": "2", "tracks": ["bass"]})
	_assert(out.get("ok", false), "filtered move ok: %s" % out.get("error", ""))
	_assert(_layout(s.drums) == [[0, tpb, 0]], "drums untouched")
	_assert(_layout(s.bass) == [[tpb, tpb, 0]], "bass moved")
	var bad: Dictionary = _move_clips_tool.new().execute({"start": "1", "end": "2", "to": "2", "tracks": ["Nope"]})
	_assert(bad.get("ok") == false, "unknown track refused")
	var empty: Dictionary = _move_clips_tool.new().execute({"start": "20", "end": "21", "to": "30"})
	_assert(empty.get("ok") == false and str(empty.get("error")).contains("No clips"), "empty span reported: %s" % empty.get("error", ""))


func _test_place_clip_overwrite() -> void:
	var s := _setup()
	var tpb: int = s.tpb
	_create("Long", s.drums, "1", 4)
	_create("Fill", s.bass, "1", 1)
	var out: Dictionary = _place_clip_tool.new().execute({"clip": "Fill", "track": "Drums", "start": "2", "overwrite": true})
	# Fill is on an instrument track like Drums, so this is legal.
	_assert(out.get("ok", false), "place_clip overwrite ok: %s" % out.get("error", ""))
	var want := [[0, tpb, 0], [tpb, tpb, 0], [2 * tpb, 2 * tpb, 2 * tpb]]
	_assert(_layout(s.drums) == want, "Fill punched into bar 2: %s" % [_layout(s.drums)])
