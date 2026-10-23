# Virtual Stage model (spec 051 T-015, T-017): room presets, edits marking the preset modified,
# /stage/set arguments, JSON round trip and the project's save, load and engine sync.
#
# Headless the OSC client never becomes ready, so sends queue in AudioEngineOSC._pending_sends.
extends TestBase

var _stage: GDScript
var _ch: GDScript

var _osc: Node
var _project_script: GDScript


func suite_name() -> String:
	return "Stage model"


func run_tests() -> void:
	_stage = load("res://data/Stage.gd")
	_ch = load("res://data/Channel.gd")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_project_script = load("res://data/Project.gd")
	_test_presets_apply()
	_test_edit_marks_modified()
	_test_clamps()
	_test_materials()
	_test_osc_args()
	_test_json_round_trip()
	_test_project_sync_and_save()
	_test_mic_setup()
	_test_source_rectangle_state()


func _test_presets_apply() -> void:
	var ids := StagePresets.preset_ids()
	_assert(ids.size() == 5, "five presets")
	for label in ["Scoring Stage", "Concert Hall", "Church", "Chamber Room", "Studio Room"]:
		var found := false
		for id in ids:
			found = found or StagePresets.preset_label(id) == label
		_assert(found, "preset %s exists" % label)
	var stage = _stage.new()
	for id in ids:
		var def := StagePresets.preset(id)
		stage.apply_preset(id)
		_assert(stage.preset == id and not stage.modified, "%s applied, not modified" % id)
		_assert(stage.width == def["width"] and stage.depth == def["depth"] and stage.height == def["height"],
				"%s dimensions" % id)
		_assert(stage.listener == Vector3(def["listener"][0], def["listener"][1], def["listener"][2]),
				"%s listener" % id)
		_assert(stage.decay_s == def["decay_s"] and stage.tail_db == def["tail_db"], "%s tail settings" % id)
		_assert(stage.materials == Array(def["materials"], TYPE_STRING, "", null), "%s materials" % id)
		_assert(stage.width <= 60.0 and stage.depth <= 40.0 and stage.height <= 25.0, "%s within the engine limits" % id)
		_assert(stage.clamp_point(stage.listener) == stage.listener, "%s listener is inside the room" % id)
	_assert(not stage.apply_preset("nope"), "unknown preset refused")


func _test_edit_marks_modified() -> void:
	var stage = _stage.new()
	stage.apply_preset("church")
	var emitted := [0]
	stage.changed.connect(func(): emitted[0] += 1)
	stage.set_decay_s(3.0)
	_assert(stage.modified and stage.decay_s == 3.0, "editing a value marks the preset modified")
	_assert(stage.preset_label() == "Church (modified)", "label shows modified: %s" % stage.preset_label())
	stage.apply_preset("church")
	_assert(not stage.modified and stage.preset_label() == "Church", "re-applying clears modified")
	stage.set_material("floor", "carpet")
	_assert(stage.modified, "material edit marks modified")
	stage.set_distance_delay(true)
	stage.set_output_mode(_stage.OutputMode.REFLECTIONS_ONLY)
	stage.set_tail_db(-10.0)
	stage.set_listener(Vector3(5, 5, 1))
	_assert(emitted[0] == 7, "each edit and preset emits changed once: %d" % emitted[0])
	stage.apply_preset("studio_room")
	_assert(stage.distance_delay and stage.output_mode == _stage.OutputMode.REFLECTIONS_ONLY,
			"a preset keeps distance delay and output mode")


func _test_clamps() -> void:
	var stage = _stage.new()
	stage.set_room_size(500.0, 500.0, 500.0)
	_assert(stage.width == 60.0 and stage.depth == 40.0 and stage.height == 25.0, "room clamped to 60x40x25")
	stage.set_room_size(1.0, 1.0, 1.0)
	_assert(stage.width == 2.0 and stage.depth == 2.0 and stage.height == 2.0, "room has a minimum")
	_assert(stage.listener.x <= 2.0 and stage.listener.y <= 2.0 and stage.listener.z <= 2.0,
			"shrinking the room keeps the listener inside")
	stage.set_room_size(20.0, 30.0, 10.0)
	stage.set_listener(Vector3(99, -5, 99))
	_assert(stage.listener == Vector3(20, 0, 10), "listener clamped into the room")


func _test_materials() -> void:
	for id in StagePresets.material_ids():
		var g := StagePresets.gain(id)
		var d := StagePresets.damping(id)
		_assert(g > 0.0 and g <= 1.0 and d >= 0.0 and d <= 1.0, "%s gain %.2f damping %.2f in range" % [id, g, d])
	_assert(StagePresets.gain("concrete") > StagePresets.gain("acoustic_panel"), "concrete reflects more than panels")
	_assert(StagePresets.damping("carpet") > StagePresets.damping("plaster"), "carpet is duller than plaster")
	var stage = _stage.new()
	stage.set_material("front", "nope")
	_assert(StagePresets.has_material(stage.get_material("front")), "unknown material ignored")


func _test_osc_args() -> void:
	var stage = _stage.new()
	stage.apply_preset("chamber_room")
	stage.set_distance_delay(true)
	stage.set_output_mode(_stage.OutputMode.DIRECT_ONLY)
	var a: Array = stage.osc_args()
	_assert(a.size() == 23, "/stage/set has 23 args: %d" % a.size())
	_assert(a[22] == 0 and typeof(a[22]) == TYPE_INT, "the mic setup is the 23rd argument, an int (Pan by default)")
	_assert(a[0] == 10.0 and a[1] == 14.0 and a[2] == 5.0, "dimensions first")
	_assert(a[3] == 5.0 and a[4] == 8.0 and a[5] == 1.5, "listener x y z")
	_assert(a[6] == 0.9 and a[7] == -9.0, "decay and tail level")
	_assert(a[8] == 1 and a[9] == 2, "distance delay and output mode are ints")
	_assert(is_equal_approx(a[10], StagePresets.gain("wood_panel")) and is_equal_approx(a[11], StagePresets.damping("wood_panel")),
			"front pair is gain, damping")
	_assert(is_equal_approx(a[20], StagePresets.gain("plaster")), "ceiling pair last")


func _test_json_round_trip() -> void:
	var stage = _stage.new()
	stage.apply_preset("concert_hall")
	stage.set_decay_s(2.5)
	stage.set_material("left", "curtain")
	stage.set_distance_delay(true)
	stage.set_output_mode(_stage.OutputMode.REFLECTIONS_ONLY)
	var again = _stage.from_json(JSON.parse_string(JSON.stringify(stage.to_json())))
	_assert(again.to_json() == stage.to_json(), "stage JSON round-trips")
	_assert(again.preset == "concert_hall" and again.modified, "preset and modified restored")
	_assert(again.materials == stage.materials and again.output_mode == stage.output_mode, "materials and output mode restored")
	var restored = _stage.new()
	restored.set_state(stage.get_state())
	_assert(restored.to_json() == stage.to_json(), "get_state / set_state snapshot")
	_assert(_stage.new().is_default() and not stage.is_default(), "is_default")


func _test_project_sync_and_save() -> void:
	var project: Object = _project_script.new()
	_assert(not project.to_json().has("stage"), "a project that does not use the stage saves no stage block")
	var ch = project.create_channel("Violins", _ch.ChannelType.INSTRUMENT)
	ch.set_pan_mode(_ch.PanMode.STAGE)
	project.stage.apply_preset("church")
	project.stage.set_decay_s(5.0)
	ch.set_stage_position(Vector3(4, 6, 2))
	ch.set_stage_sum_mode(_ch.StageSumMode.MID)
	ch.set_stage_has_room(true)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	_assert(data.has("stage"), "a project using the stage saves its stage block")

	var loaded: Object = _project_script.from_json(data)
	_assert(loaded.stage.to_json() == project.stage.to_json(), "stage restored on load")
	var lch = loaded.get_channel_by_id(ch.id)
	_assert(lch.pan_mode == _ch.PanMode.STAGE, "pan mode restored")
	_assert(lch.get_stage_state() == ch.get_stage_state(), "channel stage values restored")
	_assert(loaded.get_stage_return() != null and loaded.get_stage_return().is_stage_return, "Stage return restored")
	_assert(loaded.stage_sources().size() == 1, "stage_sources after load")

	# Connecting sends /stage/set and /stage/return, after the channels exist.
	_osc._pending_sends.clear()
	loaded._connection_state = loaded.ConnectionState.CONNECTED
	loaded._sync_stage_to_engine()
	var sent: Array = _osc._pending_sends
	_assert(sent.size() == 2 and sent[0].address == "/stage/set" and sent[1].address == "/stage/return",
			"sync sends /stage/set then /stage/return")
	_assert(sent[0].args == loaded.stage.osc_args(), "/stage/set carries the stage")
	_assert(sent[1].args == [loaded.get_stage_return().id], "/stage/return carries the return id")
	# An edit while connected sends again; while disconnected it does not.
	_osc._pending_sends.clear()
	loaded.stage.set_tail_db(-3.0)
	_assert(_osc._pending_sends.size() == 1 and _osc._pending_sends[0].address == "/stage/set", "edit sends /stage/set")
	loaded._connection_state = loaded.ConnectionState.DISCONNECTED
	_osc._pending_sends.clear()
	loaded.stage.set_tail_db(-4.0)
	_assert(_osc._pending_sends.is_empty(), "no send while disconnected")
	# A project that never used the stage sends nothing on connect.
	var plain: Object = _project_script.new()
	plain._connection_state = plain.ConnectionState.CONNECTED
	_osc._pending_sends.clear()
	plain._sync_stage_to_engine()
	_assert(_osc._pending_sends.is_empty(), "unused stage is not sent")


func _test_mic_setup() -> void:
	_assert(_stage.MIC_IDS.size() == 7 and _stage.MIC_LABELS.size() == 7, "seven mic setups with ids and labels")
	_assert(_stage.MicSetup.DECCA == 6 and _stage.MicSetup.MID_SIDE == 3 and _stage.MicSetup.ORTF == 5, "enum values are the OSC values")
	var stage = _stage.new()
	_assert(stage.mic_setup == _stage.MicSetup.PAN and stage.to_json()["mic"] == "pan", "the default is Pan")
	stage.apply_preset("church")
	var emitted := [0]
	stage.changed.connect(func(): emitted[0] += 1)
	stage.set_mic_setup(_stage.MicSetup.DECCA)
	_assert(emitted[0] == 1, "the setter emits changed once")
	_assert(stage.osc_args()[22] == 6, "osc_args carries the Decca value")
	_assert(stage.to_json()["mic"] == "decca", "to_json holds the id")
	_assert(stage.preset_label().ends_with("(modified)"), "a mic edit marks the preset modified: %s" % stage.preset_label())
	stage.set_mic_setup(99)
	_assert(stage.mic_setup == _stage.MicSetup.DECCA, "an out-of-range value clamps to the last setup")
	stage.set_mic_setup(-3)
	_assert(stage.mic_setup == _stage.MicSetup.PAN, "and to the first")
	stage.set_mic_setup(_stage.MicSetup.BLUMLEIN)
	stage.apply_preset("studio_room")
	_assert(stage.mic_setup == _stage.MicSetup.BLUMLEIN, "a preset keeps the mic setup")
	var again = _stage.from_json(JSON.parse_string(JSON.stringify(stage.to_json())))
	_assert(again.mic_setup == _stage.MicSetup.BLUMLEIN, "the mic setup round-trips through JSON")
	var legacy: Dictionary = stage.to_json()
	legacy.erase("mic")
	_assert(_stage.from_json(legacy).mic_setup == _stage.MicSetup.PAN, "a project without `mic` loads as Pan")
	legacy["mic"] = "theremin"
	_assert(_stage.from_json(legacy).mic_setup == _stage.MicSetup.PAN, "an unknown id loads as Pan")
	for i in _stage.MIC_IDS.size():
		var each = _stage.new()
		each.set_mic_setup(i)
		_assert(_stage.from_json(each.to_json()).mic_setup == i, "%s round-trips" % _stage.MIC_IDS[i])
	var restored = _stage.new()
	restored.set_state(stage.get_state())
	_assert(restored.mic_setup == stage.mic_setup, "get_state / set_state (undo) restore the mic setup")
	_assert(_stage.new().is_default() and not stage.is_default(), "is_default notices a mic change")


func _test_source_rectangle_state() -> void:
	_assert(_stage.DEFAULT_SOURCE_DEPTH == 2.0 and _stage.PLAYER_FOOTPRINT == Vector2(1.0, 1.2), "rectangle constants")
	_assert(_stage.MIN_PLAYERS == 1 and _stage.MAX_PLAYERS == 64 and _stage.DEFAULT_PLAYERS == 8, "player limits")
	var project: Object = _project_script.new()
	var ch = project.create_channel("Violins", _ch.ChannelType.INSTRUMENT)
	_assert(ch.stage_depth == 2.0 and ch.stage_display == _ch.StageDisplay.BLOCK and ch.stage_players == 8, "defaults: 2 m, Block, 8 players")
	ch.set_pan_mode(_ch.PanMode.STAGE)
	_assert(ch.stage_depth == 2.0, "a channel first entering Stage has depth 2 m")
	var state: Dictionary = ch.get_stage_state()
	_assert(state.depth == 2.0 and state.display == 0 and state.players == 8, "the state snapshot carries depth, display, players")
	# Depth is visual only: the OSC args do not change (REQ-014).
	var osc: Node = root.get_node("AudioEngineOSC")
	ch._is_connected = true
	osc._pending_sends.clear()
	ch.set_stage_state(state)
	var before: Array = osc._pending_sends.back().args if not osc._pending_sends.is_empty() else []
	var deeper := state.duplicate()
	deeper["depth"] = 7.0
	deeper["display"] = 1
	deeper["players"] = 20
	osc._pending_sends.clear()
	ch.set_stage_state(deeper)
	var after: Array = osc._pending_sends.back().args if not osc._pending_sends.is_empty() else []
	ch._is_connected = false
	_assert(not before.is_empty() and before == after, "/channel/{id}/stage args are identical for sources differing in depth, display and players")
	_assert(ch.stage_depth == 7.0 and ch.stage_display == _ch.StageDisplay.SECTION and ch.stage_players == 20, "the new values apply")
	# Clamping.
	ch.set_stage_state({"depth": -4.0, "players": 500})
	_assert(ch.stage_depth == 0.0 and ch.stage_players == 64, "depth >= 0 and players <= 64")
	ch.set_stage_state({"players": 0, "display": 9})
	_assert(ch.stage_players == 1 and ch.stage_display == _ch.StageDisplay.SECTION, "players >= 1, display clamps")
	# Save and load: strings in the file, round trip, undo snapshot.
	ch.set_stage_state(deeper)
	var data: Dictionary = JSON.parse_string(JSON.stringify(project.to_json()))
	var saved: Dictionary = {}
	for c: Dictionary in data["channels"]:
		if c.get("id") == ch.id:
			saved = c["stage"]
	_assert(saved.get("depth") == 7.0 and saved.get("display") == "section" and saved.get("players") == 20, "saved as depth, \"section\", players")
	var loaded: Object = _project_script.from_json(data)
	var lch = loaded.get_channel_by_id(ch.id)
	_assert(lch.stage_depth == 7.0 and lch.stage_display == _ch.StageDisplay.SECTION and lch.stage_players == 20, "depth, display and players restored on load")
	_assert(lch.get_stage_state() == ch.get_stage_state(), "the whole stage state round-trips")
	# A project saved before spec 052 has none of the keys: 2 m, Block, 8.
	var old: Dictionary = saved.duplicate()
	for key in ["depth", "display", "players"]:
		old.erase(key)
	var legacy = _ch.new(77)
	legacy.set_stage_state(old)
	_assert(legacy.stage_depth == 2.0 and legacy.stage_display == _ch.StageDisplay.BLOCK and legacy.stage_players == 8, "an old stage block loads as 2 m, Block, 8 players")
	# Undo restores the previous values (the snapshot is what a PropertyCommand holds).
	var snapshot: Dictionary = ch.get_stage_state()
	ch.set_stage_state({"depth": 3.0, "display": 0, "players": 4})
	ch.set_stage_state(snapshot)
	_assert(ch.stage_depth == 7.0 and ch.stage_display == _ch.StageDisplay.SECTION and ch.stage_players == 20, "set_stage_state(snapshot) undoes depth, display and players")
