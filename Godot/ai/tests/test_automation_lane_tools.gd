# AI automation lane tools: add_automation_lane, remove_automation_lane, list_automation.
# Run: godot --headless --path Godot -s ai/tests/test_automation_lane_tools.gd -- --test
# Scripts are load()ed at runtime: they reference autoloads, which don't resolve at parse time.
extends TestBase

var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _add_tool: GDScript
var _remove_tool: GDScript
var _list_tool: GDScript
var _list_tracks_tool: GDScript
var _util: GDScript
var _instance_script: GDScript


func suite_name() -> String:
	return "AI automation lane tool tests"


func run_tests() -> void:
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_add_tool = load("res://ai/tools/AddAutomationLaneTool.gd")
	_remove_tool = load("res://ai/tools/RemoveAutomationLaneTool.gd")
	_list_tool = load("res://ai/tools/ListAutomationTool.gd")
	_list_tracks_tool = load("res://ai/tools/ListTracksTool.gd")
	_util = load("res://ai/tools/AutomationToolUtil.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_test_add_each_kind()
	_test_refusals()
	_test_remove_and_undo()
	_test_list_shape()
	_test_unique_ids()


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	_sonara.editor = editor
	var lead = project.create_instrument_track("Lead").track
	var other = project.create_instrument_track("Other").track
	return {"project": project, "lead": lead, "other": other}


## A "Test Filter" device with a safe Cutoff and an unsafe Raw parameter on `channel`.
func _add_filter(project: Object, channel: Object) -> Object:
	var registry: Object = load("res://data/DeviceRegistry.gd").new()
	registry._on_builtin_info_received([
		"test.filter", "Test Filter", "effect", "", 0, 2, 2, 0, "", 0,
		2,
		0, "Cutoff", "Hz", "float", 1, 20.0, 20000.0, 1000.0, 1, 1.0, 0, "", 1, 1,
		1, "Raw", "", "float", 0, 0.0, 1.0, 0.5, 0, 1.0, 0, "", 0, 0,
		0,
		0,
		0,
	])
	var inst: Object = _instance_script.new(registry.get_device("test.filter"), channel.id, 0)
	channel.add_device(inst)
	return inst


func _run(tool_script: GDScript, args: Dictionary) -> Dictionary:
	return tool_script.new().execute(args)


func _test_add_each_kind() -> void:
	var s := _setup()
	var p: Object = s.project
	var lead: Object = s.lead
	var ch: Object = lead.get_linked_channel()
	ch.volume = -6.0
	ch.pan = 0.5
	var bus = p.create_bus_channel("Verb")
	ch.add_send(bus.id, -9.0)
	_add_filter(p, ch)

	var cases := [
		[{"track": "Lead", "param": "Volume"}, "channel/volume", "-6.0 dB"],
		[{"track": "Lead", "param": "Pan"}, "channel/pan", "R50"],
		[{"track": "Lead", "param": "Send Verb"}, "channel/send/0", "-9.0 dB"],
		[{"track": "Lead", "param": "CC 1"}, "channel/cc/1", ""],
		[{"track": "Lead", "param": "cc74"}, "channel/cc/74", ""],
		[{"track": "Lead", "param": "Cutoff", "path": "Lead/Test Filter"}, "device/0/param/0", ""],
	]
	var expected := 0
	for c in cases:
		var out := _run(_add_tool, c[0])
		_assert(out.ok, "%s added: %s" % [c[1], out.get("error", "")])
		if not out.ok:
			continue
		expected += 1
		var lane = lead.automation_lanes[-1]
		_assert(str(lane.target) == c[1], "target %s, got %s" % [c[1], str(lane.target)])
		_assert(lane.points.size() == 1 and lane.points[0].tick == 0, "%s has one seed point at tick 0" % c[1])
		var seed_value: float = lane.target.current_normalized_value(ch)
		_assert(is_equal_approx(lane.points[0].value, seed_value), "%s seed equals current value" % c[1])
		if c[2] != "":
			_assert(out.text.contains(c[2]), "%s text shows %s: %s" % [c[1], c[2], out.text])
	_assert(lead.automation_lanes.size() == expected, "all lanes present")
	_assert(lead.automation_expanded, "track lanes shown")

	# One undo removes the last lane and its seed point together.
	var count: int = lead.automation_lanes.size()
	_sonara.editor.undo()
	_assert(lead.automation_lanes.size() == count - 1, "one undo removes the lane")
	_sonara.editor.redo()
	_assert(lead.automation_lanes.size() == count and lead.automation_lanes[-1].points.size() == 1, "redo restores lane and point")


func _test_refusals() -> void:
	var s := _setup()
	var p: Object = s.project
	var lead: Object = s.lead
	var ch: Object = lead.get_linked_channel()
	var other_ch: Object = s.other.get_linked_channel()
	_add_filter(p, ch)
	_add_filter(p, other_ch)
	p.create_folder_track("Drums")
	var _ok := _run(_add_tool, {"track": "Lead", "param": "Volume"})
	var n: int = lead.automation_lanes.size()

	var out := _run(_add_tool, {"track": "Lead", "param": "volume"})
	_assert(not out.ok and out.error.contains("already has"), "duplicate refused: %s" % out)
	out = _run(_add_tool, {"track": "Lead", "param": "Reverb Mix"})
	_assert(not out.ok, "unknown param refused")
	out = _run(_add_tool, {"track": "Lead", "param": "Send Nowhere"})
	_assert(not out.ok, "send with no such bus refused")
	out = _run(_add_tool, {"track": "Lead", "param": "CC 120"})
	_assert(not out.ok, "CC 120 out of range refused")
	out = _run(_add_tool, {"track": "Lead", "param": "Cutoff", "path": "Other/Test Filter"})
	_assert(not out.ok and out.error.contains("own channel"), "device on another channel refused: %s" % out)
	out = _run(_add_tool, {"track": "Lead", "param": "Raw", "path": "Lead/Test Filter"})
	_assert(not out.ok and out.error.contains("can't be automated"), "unsafe param refused: %s" % out)
	out = _run(_add_tool, {"track": "Lead", "param": "Nope", "path": "Lead/Test Filter"})
	_assert(not out.ok, "unknown device param refused")
	out = _run(_add_tool, {"track": "Drums", "param": "Volume"})
	_assert(not out.ok and out.error.contains("no mixer channel"), "folder track refused: %s" % out)
	out = _run(_add_tool, {"track": "Lea", "param": "Volume"})
	_assert(not out.ok and out.error.contains("Did you mean"), "unknown track suggests: %s" % out)
	_assert(lead.automation_lanes.size() == n, "refusals changed nothing")


func _test_remove_and_undo() -> void:
	var s := _setup()
	var p: Object = s.project
	var lead: Object = s.lead
	_run(_add_tool, {"track": "Lead", "param": "Volume"})
	var lane = lead.automation_lanes[0]
	lane.add_point(960, 0.9)
	lane.add_point(1920, 0.1)
	var ids: Array = []
	for pt in lane.points:
		ids.append(pt.id)
	var out := _run(_remove_tool, {"track": "Lead", "param": "Volume"})
	_assert(out.ok and lead.automation_lanes.is_empty(), "lane removed: %s" % out)
	_sonara.editor.undo()
	_assert(lead.automation_lanes.size() == 1, "undo restores the lane")
	var restored = lead.automation_lanes[0]
	var restored_ids: Array = []
	for pt in restored.points:
		restored_ids.append(pt.id)
	_assert(restored_ids == ids and restored.points.size() == 3, "undo restores every point: %s" % [restored_ids])
	out = _run(_remove_tool, {"track": "Lead", "param": "Pan"})
	_assert(not out.ok and out.error.contains("Volume"), "missing lane lists existing: %s" % out)
	out = _run(_remove_tool, {"track": "Other", "param": "Volume"})
	_assert(not out.ok, "track without lanes refused")
	# Matching by display name: a lane whose device vanished still removes by its label.
	var ch: Object = lead.get_linked_channel()
	var inst := _add_filter(p, ch)
	_run(_add_tool, {"track": "Lead", "param": "Cutoff", "path": "Lead/Test Filter"})
	ch.devices.erase(inst)
	var label: String = lead.automation_lanes[-1].target.display_name(ch)
	_assert(label == "Unresolved", "orphaned lane label: %s" % label)
	out = _run(_remove_tool, {"track": "Lead", "param": label})
	_assert(out.ok, "unresolved lane removed by its label: %s" % out)


func _test_list_shape() -> void:
	var s := _setup()
	var p: Object = s.project
	var lead: Object = s.lead
	_run(_add_tool, {"track": "Lead", "param": "Volume"})
	_run(_add_tool, {"track": "Lead", "param": "Pan"})
	var lane = lead.automation_lanes[0]
	lane.add_point(960 * 4, 1.0)
	var out := _run(_list_tool, {})
	_assert(out.ok and out.data.tracks.size() == 1, "only tracks with lanes: %s" % out)
	var row: Dictionary = out.data.tracks[0]
	_assert(row.track == "Lead" and row.lanes.size() == 2, "lead has two lanes")
	var vol: Dictionary = row.lanes[0]
	_assert(vol.param == "Volume" and vol.points == 2, "volume row: %s" % vol)
	_assert(vol.values[0] == ["1.1.000", "%.1f dB" % lane.target.normalized_to_db(lane.points[0].value)], "values are [bbt, real units]: %s" % [vol.values])
	_assert(vol.values[1][0] == "2.1.000" and vol.values[1][1] == "12.0 dB", "second value: %s" % [vol.values])
	out = _run(_list_tool, {"track": "Other"})
	_assert(out.ok and out.data.tracks.size() == 1 and out.data.tracks[0].lanes.is_empty(), "named track without lanes lists none")
	for i in range(20):
		lane.add_point(960 * (8 + i), 0.5)
	out = _run(_list_tool, {"track": "Lead"})
	var big: Dictionary = out.data.tracks[0].lanes[0]
	_assert(not big.has("values") and big.range.size() == 2, "many points give a range: %s" % big)
	var rows: Array = _list_tracks_tool.new().execute({}).data.tracks
	_assert(rows[0].get("lanes") == 2 and not rows[1].has("lanes"), "list_tracks hints lane count: %s" % [rows])
	# Unresolved lanes are flagged.
	var ch: Object = lead.get_linked_channel()
	var inst := _add_filter(p, ch)
	_run(_add_tool, {"track": "Lead", "param": "Cutoff", "path": "Lead/Test Filter"})
	ch.devices.erase(inst)
	out = _run(_list_tool, {"track": "Lead"})
	var flagged := false
	for l in out.data.tracks[0].lanes:
		flagged = flagged or l.get("unresolved", false)
	_assert(flagged, "unresolved lane marked")


func _test_unique_ids() -> void:
	var s := _setup()
	var lead: Object = s.lead
	_run(_add_tool, {"track": "Lead", "param": "Volume"})
	_run(_add_tool, {"track": "Lead", "param": "Pan"})
	_run(_remove_tool, {"track": "Lead", "param": "Volume"})
	var id: String = _util.unique_lane_id(lead)
	for lane in lead.automation_lanes:
		_assert(lane.id != id, "unique id %s not in use" % id)
	var target = AutomationTarget.channel_volume()
	var lane = _util.new_lane(lead, target)
	_assert(lane.id == id and lane.target == target, "new_lane uses the unique id")
