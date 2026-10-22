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
	_assert(a.size() == 22, "/stage/set has 22 args: %d" % a.size())
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
