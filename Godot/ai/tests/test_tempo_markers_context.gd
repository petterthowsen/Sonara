# test_tempo_markers_context.gd
# Headless tests for set_tempo, list_markers / create_marker, and SelectionContext: which items a
# selection produces, the `<selection_context>` block on the outgoing user message (not in
# get_text()), and conversation storage round-trip.
#
# Project, Editor and the tools reference autoloads (Sonara) by bare name, so — like
# test_clip_placement.gd — they are loaded with load() inside run_tests().
# Run: godot --headless --path Godot -s ai/tests/test_tempo_markers_context.gd -- --test
extends TestBase

const NO_RANGE := {"has": false, "start": 0, "has_end": false, "end": 0}

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _set_tempo_tool: GDScript
var _list_markers_tool: GDScript
var _create_marker_tool: GDScript
var _create_clip_tool: GDScript
var _selection_context: GDScript


func suite_name() -> String:
	return "Tempo, markers and selection context tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_set_tempo_tool = load("res://ai/tools/SetTempoTool.gd")
	_list_markers_tool = load("res://ai/tools/ListMarkersTool.gd")
	_create_marker_tool = load("res://ai/tools/CreateMarkerTool.gd")
	_create_clip_tool = load("res://ai/tools/CreateClipTool.gd")
	_selection_context = load("res://ai/chat/SelectionContext.gd")
	_test_set_tempo()
	_test_set_tempo_validation()
	_test_create_marker_explicit()
	_test_create_marker_from_range()
	_test_create_marker_replaces_overlap()
	_test_create_marker_undo()
	_test_arranger_context_items()
	_test_mixer_context_items()
	_test_context_on_outgoing_message()


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	editor.test_time_range_override = NO_RANGE
	_sonara.editor = editor
	return {"project": project, "editor": editor}


func _tpb(project: Object) -> int:
	return project.ppq * project.time_numerator * 4 / project.time_denominator


func _test_set_tempo() -> void:
	var s := _setup()
	var tool: Object = _set_tempo_tool.new()
	var out: Dictionary = tool.execute({"bpm": 92.5, "time_signature": "6/8"})
	_assert(out.get("ok", false), "set_tempo succeeds: %s" % out.get("error", ""))
	_assert(is_equal_approx(s.project.tempo, 92.5), "tempo applied: %s" % s.project.tempo)
	_assert(s.project.time_numerator == 6 and s.project.time_denominator == 8, "time signature applied")
	_assert(str(out.get("text", "")).contains("6/8"), "result mentions new signature: %s" % out.get("text", ""))
	s.editor.undo()
	_assert(s.project.time_numerator == 4 and s.project.time_denominator == 4, "time signature undone")


func _test_set_tempo_validation() -> void:
	var s := _setup()
	var tool: Object = _set_tempo_tool.new()
	_assert(tool.execute({}).get("ok") == false, "no args fails")
	_assert(tool.execute({"bpm": 5}).get("ok") == false, "bpm below range fails")
	_assert(tool.execute({"time_signature": "4/6"}).get("ok") == false, "non power-of-two denominator fails")
	_assert(tool.execute({"time_signature": "four"}).get("ok") == false, "garbage signature fails")
	_assert(is_equal_approx(s.project.tempo, 120.0), "failed calls leave tempo alone")


func _test_create_marker_explicit() -> void:
	var s := _setup()
	var tpb := _tpb(s.project)
	var tool: Object = _create_marker_tool.new()
	var out: Dictionary = tool.execute({"name": "verse", "start": "5", "end": "13", "color": "#e0a030"})
	_assert(out.get("ok", false), "create_marker succeeds: %s" % out.get("error", ""))
	_assert(s.project.markers.size() == 1, "one marker added")
	var m: Object = s.project.markers[0]
	_assert(m.name == "Verse", "name title-cased: %s" % m.name)
	_assert(m.start_ticks == 4 * tpb and m.duration_ticks == 8 * tpb, "bars 5–13 exclusive: %d+%d" % [m.start_ticks, m.duration_ticks])
	_assert(m.color.to_html(false) == "e0a030", "color applied: %s" % m.color.to_html(false))
	var listed: Dictionary = _list_markers_tool.new().execute({})
	_assert(listed.data.markers[0].bars == 8 and listed.data.markers[0].start == "5.1.000", "list_markers row: %s" % listed.data.markers)
	var bars_out: Dictionary = tool.execute({"name": "Bridge", "start": "1.1.000", "bars": 2})
	_assert(bars_out.get("ok", false) and s.project.markers.size() == 2, "bars length works")


func _test_create_marker_from_range() -> void:
	var s := _setup()
	var tpb := _tpb(s.project)
	var tool: Object = _create_marker_tool.new()
	_assert(tool.execute({"name": "Intro"}).get("ok") == false, "no start and no range fails")
	s.editor.test_time_range_override = {"has": true, "start": 2 * tpb, "has_end": true, "end": 6 * tpb}
	var out: Dictionary = tool.execute({"name": "Intro"})
	_assert(out.get("ok", false), "range marker succeeds: %s" % out.get("error", ""))
	var m: Object = s.project.markers[0]
	_assert(m.start_ticks == 2 * tpb and m.get_end_ticks() == 6 * tpb, "uses range: %d–%d" % [m.start_ticks, m.get_end_ticks()])


func _test_create_marker_replaces_overlap() -> void:
	var s := _setup()
	var tool: Object = _create_marker_tool.new()
	tool.execute({"name": "Verse", "start": 1, "end": 9})
	var out: Dictionary = tool.execute({"name": "Verse", "start": 1, "end": 5})
	_assert(out.get("ok", false), "overlapping create succeeds")
	var names: Array = _list_markers_tool.new().execute({}).data.markers.map(func(r): return "%s@%s" % [r.name, r.start])
	_assert(names == ["Verse 2@1.1.000", "Verse@5.1.000"], "old marker trimmed and keeps its name: %s" % [names])
	var cover: Dictionary = tool.execute({"name": "Verse", "start": 1, "end": 9})
	names = _list_markers_tool.new().execute({}).data.markers.map(func(r): return r.name)
	_assert(names == ["Verse"], "fully replaced markers free their name: %s" % [names])
	_assert(str(cover.get("text", "")).contains("markers now"), "result reports adjusted markers: %s" % cover.get("text", ""))


func _test_create_marker_undo() -> void:
	var s := _setup()
	_create_marker_tool.new().execute({"name": "Chorus", "start": 1, "bars": 4})
	_assert(s.project.markers.size() == 1, "marker created")
	s.editor.undo()
	_assert(s.project.markers.is_empty(), "undo removes marker")


func _test_arranger_context_items() -> void:
	var s := _setup()
	var tpb := _tpb(s.project)
	var track: Object = s.project.create_instrument_track("Drums").track
	var out: Dictionary = _create_clip_tool.new().execute({"name": "Beat", "track": "Drums", "start": 1, "bars": 2})
	_assert(out.get("ok", false), "seed clip: %s" % out.get("error", ""))
	var sel := {
		"tracks": [track],
		"active_track": track,
		"range": {"has": true, "start": 4 * tpb, "has_end": true, "end": 8 * tpb},
		"clips": track.clip_instances,
	}
	var items: Array = _selection_context.build(s.project, sel)
	var kinds: Array = items.map(func(i): return i.kind)
	_assert(kinds == ["track", "range", "clips"], "arranger kinds: %s" % [kinds])
	_assert(str(items[0].text).contains("\"Drums\""), "track text: %s" % items[0].text)
	_assert(str(items[1].text).contains("5.1.000–9.1.000") and str(items[1].text).contains("4 bars"), "range text: %s" % items[1].text)
	_assert(str(items[2].text).contains("\"Beat\" on \"Drums\" at 1.1.000–3.1.000"), "clip text: %s" % items[2].text)
	_assert(items[1].label == "5.1–9.1", "range label: %s" % items[1].label)
	_assert(_selection_context.build(s.project, {"range": NO_RANGE}).is_empty(), "empty selection gives no items")


func _test_mixer_context_items() -> void:
	var s := _setup()
	s.project.create_instrument_track("Bass")
	var ch: Object = s.project.find_by_name("Bass").get("channel")
	var items: Array = _selection_context.build(s.project, {"channels": [ch]})
	_assert(items.size() == 1 and items[0].kind == "channel", "one channel item")
	_assert(str(items[0].text).contains("Mixer channel: \"Bass\"") and str(items[0].text).contains("output Master"), "channel text: %s" % items[0].text)


func _test_context_on_outgoing_message() -> void:
	var s := _setup()
	s.project.create_instrument_track("Keys")
	var track: Object = s.project.find_by_name("Keys").get("track")
	var items: Array = _selection_context.build(s.project, {"tracks": [track], "active_track": track})
	var msg := ChatTypes.ORChatMessage.user_text("make this louder")
	msg.context = _selection_context.to_storage(items)
	var wire: Dictionary = msg.to_openrouter()
	_assert(str(wire.content).begins_with("<selection_context>"), "context block leads the content: %s" % wire.content)
	_assert(str(wire.content).ends_with("make this louder"), "user text follows the block")
	_assert(msg.get_text() == "make this louder", "get_text excludes context")
	var restored := ChatTypes.ORChatMessage.from_storage(msg.to_storage())
	_assert(restored.context.size() == 1 and restored.to_openrouter().content == wire.content, "context survives storage round-trip")
	var bare := ChatTypes.ORChatMessage.user_text("hi")
	_assert(bare.to_openrouter().content == "hi", "no context -> unchanged content")
