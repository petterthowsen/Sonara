# test_sampler_tools.gd
# Headless tests for the assistant's Sampler multisample tools (spec 023): create_track and
# add_device making multisample Samplers from audio files, edit_sampler ops (zones, groups,
# layout, mode) as one undo step that changes nothing when an op fails, and get_device listing.
# No engine: the AudioEngineOSC autoload queues sends, AssetService is seeded with audio assets.
#
# The tools reference autoloads by bare name, so — like test_fuzzy_resolve.gd — scripts are loaded
# with load() inside run_tests() instead of being named by class.
# Run: godot --headless --path Godot -s ai/tests/test_sampler_tools.gd -- --test
extends TestBase

const SAMPLER_ID := "sonara.builtin.sampler"
const DRUM_ID := "sonara.builtin.drum_machine"

var _asset_service: Node
var _sonara: Node
var _project_script: GDScript
var _editor_script: GDScript
var _device_script: GDScript
var _instance_script: GDScript
var _asset_script: GDScript
var _util: GDScript
var _create_track_tool: GDScript
var _add_device_tool: GDScript
var _edit_tool: GDScript
var _get_device_tool: GDScript
var _load_file_tool: GDScript


func suite_name() -> String:
	return "AI Sampler multisample tools"


func run_tests() -> void:
	_asset_service = root.get_node("AssetService")
	_sonara = root.get_node("Sonara")
	_project_script = load("res://data/Project.gd")
	_editor_script = load("res://editor/Editor.gd")
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_asset_script = load("res://browser/Asset.gd")
	_util = load("res://ai/tools/SamplerToolUtil.gd")
	_create_track_tool = load("res://ai/tools/CreateTrackTool.gd")
	_add_device_tool = load("res://ai/tools/AddDeviceTool.gd")
	_edit_tool = load("res://ai/tools/EditSamplerTool.gd")
	_get_device_tool = load("res://ai/tools/GetDeviceTool.gd")
	_load_file_tool = load("res://ai/tools/LoadDeviceFileTool.gd")
	_register_sampler()
	_register_drum_machine()
	_register_chain()
	for n in ["Piano_C3", "Piano_E3", "Piano_G3"]:
		_audio("/lib/Piano Soft/%s.wav" % n)
	for n in ["Piano_C3_hard", "Piano_E3_hard", "Piano_G3_hard"]:
		_audio("/lib/Piano Hard/%s.wav" % n)
	for n in ["Snare_1", "Snare_2"]:
		_audio("/lib/Drums/%s.wav" % n)
	for n in ["10-Kick", "1-Kick", "2-Kick"]:
		_audio("/lib/Kit/Kick/%s.wav" % n)
	for n in ["1-Snare", "2-Snare"]:
		_audio("/lib/Kit/Snare/%s.wav" % n)
	_test_parse_note_and_ranges()
	_test_create_track_with_samples()
	_test_add_device_single_and_multi()
	_test_velocity_layers_one_undo_step()
	_test_failed_op_changes_nothing()
	_test_unknown_keys_and_single_mode()
	_test_layout_and_remove()
	_test_mode_switches()
	_test_get_device_lists_zones()
	_test_load_file_adds_zone()
	_test_drum_pad_multisample()
	_test_full_ranges_and_default_zones()
	_test_add_samples_spreads()
	_test_kit_from_folders()
	_test_device_pad_note_and_taken_note()
	_test_set_params_reports_unchanged()


# --- setup -----------------------------------------------------------------

func _register_sampler() -> void:
	var device: Object = _device_script.new(SAMPLER_ID, "Sampler", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	device.supports_file_loading = true
	device.supported_file_extensions.assign([".wav", ".flac"])
	var specs := [
		[1, "Tune", -24.0, 24.0, 0.0, "float"], [3, "Root", 0.0, 127.0, 60.0, "float"],
		[7, "Start", 0.0, 1.0, 0.0, "float"], [8, "End", 0.0, 1.0, 1.0, "float"],
		[14, "Fine", -100.0, 100.0, 0.0, "float"], [20, "Reverse", 0.0, 1.0, 0.0, "bool"],
		[21, "Loop Mode", 0.0, 2.0, 0.0, "enum"], [22, "Loop Start", 0.0, 1.0, 0.0, "float"],
		[23, "Loop End", 0.0, 1.0, 1.0, "float"], [24, "Crossfade", 0.0, 100.0, 0.0, "float"],
		[30, "Key Track", 0.0, 1.0, 0.0, "bool"],
	]
	for s in specs:
		var param := DeviceParameter.new(s[0], s[1])
		param.min_value = s[2]
		param.max_value = s[3]
		param.default_value = s[4]
		param.param_type = s[5]
		if s[5] == "enum":
			param.enum_values.assign(["Off", "On", "Ping-Pong"])
		device.add_parameter(param)
	_asset_service.device_registry._devices[SAMPLER_ID] = device


func _register_drum_machine() -> void:
	var device: Object = _device_script.new(DRUM_ID, "Drum Machine", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	device.is_container = true
	_asset_service.device_registry._devices[DRUM_ID] = device


## Drum pads are slot chains holding the Sampler, as in the app.
func _register_chain() -> void:
	var device: Object = _device_script.new("sonara.builtin.chain", "Chain", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	device.is_container = true
	_asset_service.device_registry._devices["sonara.builtin.chain"] = device


func _audio(path: String) -> void:
	var asset: Object = _asset_script.new()
	asset.type = _asset_script.TYPE.Audio
	asset.path = path
	asset.name = path.get_file().get_basename()
	_asset_service._assets_by_path[path] = asset


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var editor: Object = _editor_script.new()
	editor.project = project
	_sonara.editor = editor
	return {"project": project, "editor": editor}


## A project with a "Piano" track holding a multisample Sampler of the three soft samples.
func _piano() -> Dictionary:
	var s := _setup()
	var out: Dictionary = await _create_track_tool.new().execute({
		"name": "Piano", "kind": "instrument",
		"asset_paths": ["/lib/Piano Soft/Piano_C3.wav", "/lib/Piano Soft/Piano_E3.wav", "/lib/Piano Soft/Piano_G3.wav"],
	})
	s["result"] = out
	s["channel"] = s.project.channels.filter(func(c) -> bool: return c.name == "Piano")[0]
	s["sampler"] = s.channel.devices[0] if not s.channel.devices.is_empty() else null
	return s


func _edit(ops: Array, path := "Piano/Sampler") -> Dictionary:
	return _edit_tool.new().execute({"path": path, "ops": ops})


func _zone(sampler: Object, zone_name: String) -> Object:
	for z in sampler.multisample.zones:
		if z.name == zone_name:
			return z
	return null


# --- tests -----------------------------------------------------------------

func _test_parse_note_and_ranges() -> void:
	_assert(_util.parse_note("C3") == 60 and _util.parse_note("c-2") == 0 and _util.parse_note("G8") == 127, "note names: C3 = 60, C-2 = 0, G8 = 127")
	_assert(_util.parse_note("F#2") == 54 and _util.parse_note("Bb-1") == 22, "sharps and flats")
	_assert(_util.parse_note(60) == 60 and _util.parse_note("72") == 72, "numbers")
	_assert(_util.parse_note("H3") == -1 and _util.parse_note(128) == -1 and _util.parse_note(60.5) == -1, "bad notes are -1")
	var r: Dictionary = _util.parse_range(["C2", "B2"], true, "key")
	_assert(r.get("lo") == 48 and r.get("hi") == 59, "key range from note names")
	r = _util.parse_range([1, 64], false, "vel")
	_assert(r.get("lo") == 1 and r.get("hi") == 64, "velocity range")
	_assert(_util.parse_range([0, 64], false, "vel").has("error"), "velocity 0 is refused")
	_assert(_util.parse_range(["B2", "C2"], true, "key").has("error"), "a reversed range is refused")
	_assert(_util.parse_range("C3", true, "key").get("hi") == 60, "one value is a one-key range")
	r = _util.parse_range(["all"], true, "key")
	_assert(r.get("lo") == 0 and r.get("hi") == 127, "[\"all\"] is every key")
	_assert(_util.parse_range("full", false, "vel").get("lo") == 1, "\"full\" is velocity 1-127")
	_assert(str(_util.parse_range(["C-1", "G9"], true, "key").get("error", "")).contains("C-2 (0) to G8 (127)"), "a bad note names the key span")


func _test_create_track_with_samples() -> void:
	var s: Dictionary = await _piano()
	_assert(s.result.get("ok"), "create_track with asset_paths succeeds: %s" % s.result.get("error", ""))
	var sampler: Object = s.sampler
	_assert(sampler != null and sampler.is_sampler(), "the track gets a Sampler")
	_assert(sampler.multisample != null and sampler.multisample.active and sampler.multisample.zones.size() == 3, "in multisample mode with three zones")
	var text := str(s.result.get("text", ""))
	_assert(text.contains("Multisample: 3 zones") and text.contains("Piano_E3: keys"), "the result lists the zones: %s" % text)
	_assert(text.contains("Key Track is off"), "and warns that Key Track is off")
	_assert(str(s.result.data.device.get("mode", "")) == "multisample" and int(s.result.data.device.zone_count) == 3, "the device row says multisample and the zone count")


func _test_add_device_single_and_multi() -> void:
	var s := _setup()
	var ch: Object = s.project.create_instrument_track("Keys").channel
	var tool: Object = _add_device_tool.new()
	var out: Dictionary = await tool.execute({"channel": "Keys", "asset_path": "/lib/Piano Soft/Piano_C3.wav"})
	_assert(out.get("ok"), "one audio file on a channel makes a Sampler: %s" % out.get("error", ""))
	_assert(ch.devices.size() == 1 and ch.devices[0].is_sampler(), "a Sampler was added")
	_assert(ch.devices[0].loaded_file_path.ends_with("Piano_C3.wav") and ch.devices[0].multisample == null, "in single-sample mode")
	out = await tool.execute({"channel": "Keys", "asset_paths": ["/lib/Piano Hard/Piano_C3_hard.wav", "/lib/Piano Hard/Piano_E3_hard.wav"]})
	_assert(out.get("ok") and ch.devices.size() == 2, "several audio files make one more Sampler: %s" % out.get("error", ""))
	_assert(ch.devices[1].multisample.zones.size() == 2, "a multisample with a zone per file")
	var audio_ch: Object = s.project.create_audio_track("Vox").channel
	out = await tool.execute({"channel": "Vox", "asset_path": "/lib/Piano Soft/Piano_C3.wav"})
	_assert(out.get("ok") == false and audio_ch.devices.is_empty(), "an audio channel refuses a Sampler")


func _test_velocity_layers_one_undo_step() -> void:
	var s: Dictionary = await _piano()
	var history: Object = s.editor.history
	var before: int = history.undo_count()
	var out := _edit([
		{"op": "set", "zones": ["all"], "vel": [1, 80], "to_group": "soft"},
		{"op": "add_samples", "folder": "/lib/Piano Hard", "to_group": "Hard"},
		{"op": "set", "in_group": "Hard", "vel": [81, 127]},
		{"op": "layout", "in_group": "Hard", "how": "set_root_from_name"},
		{"op": "set_group", "group": "Hard", "play_mode": "round_robin", "gain_db": -3},
		{"op": "add_group", "name": "Release", "mute": true},
	])
	_assert(out.get("ok"), "a velocity-layer setup in one call: %s" % out.get("error", ""))
	var ms: Object = s.sampler.multisample
	_assert(ms.zones.size() == 6, "three hard zones were added (%d)" % ms.zones.size())
	_assert(ms.groups.map(func(g): return g.name) == ["Soft", "Hard", "Release"], "groups Soft, Hard and Release, names title-cased: %s" % [ms.groups.map(func(g): return g.name)])
	var soft: Object = _zone(s.sampler, "Piano_E3")
	var hard: Object = _zone(s.sampler, "Piano_E3_hard")
	_assert(soft.vel_lo == 1 and soft.vel_hi == 80 and ms.get_group(soft.group_id).name == "Soft", "soft zones: velocity 1-80 in Soft")
	_assert(hard.vel_lo == 81 and hard.vel_hi == 127 and ms.get_group(hard.group_id).name == "Hard", "hard zones: velocity 81-127 in Hard")
	_assert(hard.root == 64, "the hard zones' roots come from their names")
	var hard_group: Object = ms.get_group(hard.group_id)
	_assert(hard_group.play_mode == 1 and is_equal_approx(linear_to_db(hard_group.gain), -3.0), "Hard plays round robin at -3 dB")
	_assert(ms.groups[2].mute, "Release is muted")
	var text := str(out.get("text", ""))
	_assert(text.contains("Created group Soft") and text.contains("Added 3 zones") and text.contains("Hard (3 zones, gain -3.0 dB, round_robin)"), "the result says what changed: %s" % text)
	_assert(history.undo_count() == before + 1, "the whole call is one undo step (%d -> %d)" % [before, history.undo_count()])
	history.undo()
	_assert(ms.zones.size() == 3 and ms.groups.is_empty(), "undo puts the three ungrouped zones back")
	_assert(_zone(s.sampler, "Piano_E3").vel_lo == 1 and _zone(s.sampler, "Piano_E3").vel_hi == 127, "with their full velocity range")


func _test_failed_op_changes_nothing() -> void:
	var s: Dictionary = await _piano()
	var before: int = s.editor.history.undo_count()
	var out := _edit([
		{"op": "set", "zones": ["Piano C3"], "gain_db": -6},
		{"op": "add_group", "name": "Layer"},
		{"op": "set", "zones": ["Piano_A3"], "tune": 1},
	])
	_assert(out.get("ok") == false, "an unknown zone fails the call")
	var err := str(out.get("error", ""))
	_assert(err.contains("ops[2]") and err.contains("Piano_A3") and err.contains("Nothing was changed"), "the error names the op and the zone: %s" % err)
	_assert(err.contains("Did you mean") or err.contains("Zones include"), "and suggests zone names: %s" % err)
	_assert(is_equal_approx(_zone(s.sampler, "Piano_C3").gain, 1.0) and s.sampler.multisample.groups.is_empty(), "earlier ops were rolled back")
	_assert(s.editor.history.undo_count() == before, "no undo step is recorded")
	out = _edit([{"op": "add_samples", "asset_paths": ["/lib/Nowhere/Missing_C9.wav"]}])
	_assert(out.get("ok") == false and s.sampler.multisample.zones.size() == 3, "an unknown file fails before anything changes")
	out = _edit([{"op": "set", "zones": ["all"], "tune": 60}])
	_assert(out.get("ok") == false and str(out.error).contains("tune must be between"), "out-of-range values are refused, not clamped: %s" % out.get("error", ""))


func _test_unknown_keys_and_single_mode() -> void:
	var s: Dictionary = await _piano()
	var out := _edit([{"op": "set", "zones": ["all"], "velocity": [1, 64]}])
	_assert(out.get("ok") == false and str(out.error).contains("does not take velocity") and str(out.error).contains("vel"), "a misspelled key lists the valid ones: %s" % out.get("error", ""))
	out = _edit([{"op": "shuffle"}])
	_assert(out.get("ok") == false and str(out.error).contains("unknown op"), "an unknown op fails")
	var ch: Object = s.project.create_instrument_track("Lead").channel
	await _add_device_tool.new().execute({"channel": "Lead", "asset_path": "/lib/Piano Soft/Piano_C3.wav"})
	out = _edit([{"op": "set", "zones": ["all"], "gain_db": -1}], "Lead/Sampler")
	_assert(out.get("ok") == false and str(out.error).contains("single-sample mode"), "zone edits on a single-mode Sampler say to switch first")
	out = _edit([{"op": "add_samples", "asset_paths": ["/lib/Piano Soft/Piano_G3.wav"]}], "Lead/Sampler")
	_assert(out.get("ok"), "add_samples on a single-mode Sampler: %s" % out.get("error", ""))
	var sampler: Object = ch.devices[0]
	_assert(sampler.multisample.active and sampler.multisample.zones.size() == 2, "switches it to multisample, keeping its sample as a zone")
	_assert(str(out.text).contains("Piano_C3 is a zone now too"), "and says so")


func _test_layout_and_remove() -> void:
	var s: Dictionary = await _piano()
	var out := _edit([{"op": "layout", "zones": ["Piano_G3", "Piano_C3", "Piano_E3"], "how": "distribute_velocity", "range": ["1", "120"]}])
	_assert(out.get("ok"), "distribute_velocity: %s" % out.get("error", ""))
	var g: Object = _zone(s.sampler, "Piano_G3")
	var e: Object = _zone(s.sampler, "Piano_E3")
	_assert(g.vel_lo == 1 and e.vel_hi == 120 and g.vel_hi < e.vel_lo, "velocity slices follow the order the zones were named")
	out = _edit([{"op": "layout", "zones": ["all"], "how": "assign_note", "range": ["C2", "C4"]}])
	_assert(out.get("ok") and g.key_lo == 48 and g.key_hi == 72, "assign_note takes note names: %s" % out.get("error", ""))
	out = _edit([{"op": "layout", "zones": ["all"], "how": "distribute_notes"}])
	_assert(out.get("ok") == false and str(out.error).contains("range"), "distribute without range fails")
	out = _edit([{"op": "set", "zones": ["Piano_C3"], "root": "D3", "loop_mode": "ping-pong", "loop_start": 0.2, "loop_end": 0.8, "key": ["A1", "D3"]}])
	var c: Object = _zone(s.sampler, "Piano_C3")
	_assert(out.get("ok") and c.root == 62 and c.loop_mode == 2 and c.key_lo == 45 and c.key_hi == 62, "set root, loop and keys: %s" % out.get("error", ""))
	_assert(str(out.text).contains("loop ping_pong 0.200-0.800"), "the zone line shows the loop")
	out = _edit([{"op": "remove", "zones": ["Piano_C3"]}])
	_assert(out.get("ok") and s.sampler.multisample.zones.size() == 2 and _zone(s.sampler, "Piano_C3") == null, "remove deletes the zone")


func _test_mode_switches() -> void:
	var s: Dictionary = await _piano()
	var out := _edit([{"op": "mode", "mode": "single"}])
	_assert(out.get("ok"), "mode single: %s" % out.get("error", ""))
	_assert(not s.sampler.multisample.active and s.sampler.loaded_file_path.ends_with("Piano_C3.wav"), "keeps the focused zone's file")
	_assert(str(out.text).contains("2 other zones were removed"), "and says what was dropped: %s" % out.text)
	s.editor.history.undo()
	_assert(s.sampler.multisample.active and s.sampler.multisample.zones.size() == 3, "undo restores the multisample")
	var empty := _setup()
	var ch: Object = empty.project.create_instrument_track("Pad").channel
	var inst: Object = _instance_script.new(_asset_service.device_registry._devices[SAMPLER_ID], ch.id, -1)
	ch.add_device(inst)
	out = _edit([{"op": "mode", "mode": "multisample"}, {"op": "add_samples", "asset_paths": ["/lib/Piano Soft/Piano_E3.wav"], "at_key": "C1"}], "Pad/Sampler")
	_assert(out.get("ok") and inst.multisample.zones.size() == 1 and inst.multisample.zones[0].key_lo == 36, "an empty Sampler goes multisample; at_key places the zone: %s" % out.get("error", ""))


func _test_get_device_lists_zones() -> void:
	var s: Dictionary = await _piano()
	var out: Dictionary = _get_device_tool.new().execute({"path": "Piano/Sampler", "limit": 1})
	_assert(out.get("ok"), "get_device on a multisample Sampler")
	var lines: Array = Array(out.data.get("multisample", []))
	_assert(not lines.is_empty() and str(lines[0]).begins_with("Multisample: 3 zones"), "lists the multisample: %s" % [lines])
	_assert(lines.any(func(l): return str(l).begins_with("- Piano_G3: keys")), "with a line per zone")
	_assert(out.data.get("mode") == "multisample", "and marks the row")


func _test_load_file_adds_zone() -> void:
	var s: Dictionary = await _piano()
	var before: int = s.editor.history.undo_count()
	var out: Dictionary = await _load_file_tool.new().execute({"path": "Piano/Sampler", "asset_path": "/lib/Piano Hard/Piano_G3_hard.wav"})
	_assert(out.get("ok") and s.sampler.multisample.zones.size() == 4, "load_device_file on a multisample Sampler adds a zone: %s" % out.get("error", ""))
	_assert(str(out.text).begins_with("Added a zone"), "and says so")
	_assert(s.editor.history.undo_count() == before + 1, "as one undo step")
	s.editor.history.undo()
	_assert(s.sampler.multisample.zones.size() == 3, "that undo removes the zone")


func _test_drum_pad_multisample() -> void:
	var s := _setup()
	var ch: Object = s.project.create_instrument_track("Drums").channel
	var drum: Object = _instance_script.new(_asset_service.device_registry._devices[DRUM_ID], ch.id, -1)
	ch.add_device(drum)
	var out: Dictionary = await _add_device_tool.new().execute({
		"channel": "Drums", "parent": "Drums/Drum Machine", "multisample": true,
		"asset_paths": ["/lib/Drums/Snare_1.wav", "/lib/Drums/Snare_2.wav"],
	})
	_assert(out.get("ok"), "multisample pad: %s" % out.get("error", ""))
	_assert(drum.children.size() == 1, "one pad")
	var pad: Object = drum.children[0]
	var pad_sampler: Object = _util.find_sampler(pad)
	_assert(pad_sampler != null and pad_sampler.multisample.zones.size() == 2, "holding both samples as zones")
	_assert(pad.slot_note == 38, "on the snare note (%d)" % pad.slot_note)
	_assert(str(out.text).contains("Multisample: 2 zones"), "the result lists the pad's zones")
	var z1: Object = _zone(pad_sampler, "Snare_1")
	var z2: Object = _zone(pad_sampler, "Snare_2")
	_assert(z1.key_lo == 0 and z1.key_hi == 127 and z2.key_lo == 0 and z2.key_hi == 127, "a pad's samples span every key, so its own note plays them")
	_assert(z1.vel_lo == 1 and z1.vel_hi == 64 and z2.vel_lo == 65 and z2.vel_hi == 127, "as velocity layers in name order (%d-%d, %d-%d)" % [z1.vel_lo, z1.vel_hi, z2.vel_lo, z2.vel_hi])
	_assert(str(out.text).contains("velocity layers"), "and the result says so: %s" % out.text)
	var pad_path: String = pad.address_path(s.project)
	out = _edit([{"op": "add_group", "name": "Hits", "play_mode": "round_robin"}, {"op": "set", "zones": ["all"], "to_group": "Hits", "key": ["0", "127"]}], pad_path)
	_assert(out.get("ok") and pad_sampler.multisample.groups[0].play_mode == 1, "edit_sampler works on the pad's path (%s): %s" % [pad_path, out.get("error", "")])


func _drum_machine(s: Dictionary) -> Object:
	var ch: Object = s.project.create_instrument_track("Drums").channel
	var drum: Object = _instance_script.new(_asset_service.device_registry._devices[DRUM_ID], ch.id, -1)
	ch.add_device(drum)
	return drum


func _test_full_ranges_and_default_zones() -> void:
	var s: Dictionary = await _piano()
	var out := _edit([{"op": "set", "key": ["all"]}, {"op": "layout", "how": "distribute_velocity", "range": ["all"]}])
	_assert(out.get("ok"), "set and layout without zones act on every zone: %s" % out.get("error", ""))
	var c: Object = _zone(s.sampler, "Piano_C3")
	var g: Object = _zone(s.sampler, "Piano_G3")
	_assert(c.key_lo == 0 and c.key_hi == 127 and g.vel_hi == 127 and c.vel_lo == 1 and c.vel_hi < g.vel_lo, "every key, velocity split over all zones")
	out = _edit([{"op": "remove"}])
	_assert(out.get("ok") == false and s.sampler.multisample.zones.size() == 3, "remove still needs zones named")
	out = _edit([{"op": "set", "zones": ["all"]}])
	_assert(str(out.get("error", "")).contains("set_device_params"), "an empty set points device parameters at set_device_params: %s" % out.get("error", ""))


func _test_add_samples_spreads() -> void:
	var s: Dictionary = await _piano()
	var ops := [{"op": "add_samples", "folder": "/lib/Kit/Kick", "as": "velocity_layers", "to_group": "Kick"}]
	var out := _edit(ops)
	_assert(out.get("ok"), "add_samples as velocity_layers: %s" % out.get("error", ""))
	_assert(not ops[0].has("_paths"), "the caller's ops are not modified")
	var k1: Object = _zone(s.sampler, "1-Kick")
	var k2: Object = _zone(s.sampler, "2-Kick")
	var k10: Object = _zone(s.sampler, "10-Kick")
	_assert(k1.key_lo == 0 and k1.key_hi == 127 and k10.key_lo == 0, "every take spans every key, ignoring the numbers in the names")
	_assert(k1.vel_lo == 1 and k1.vel_hi < k2.vel_lo and k2.vel_hi < k10.vel_lo and k10.vel_hi == 127, "velocity goes up in natural name order: 1, 2, 10")
	out = _edit([{"op": "add_samples", "folder": "/lib/Kit/Snare", "as": "round_robin"}])
	var sn: Object = _zone(s.sampler, "1-Snare")
	var group: Object = s.sampler.multisample.get_group(sn.group_id)
	_assert(out.get("ok") and group.name == "Round Robin" and group.play_mode == 1 and sn.vel_lo == 1 and sn.vel_hi == 127, "round_robin: full ranges in a round-robin group")
	var lead := _setup()
	lead.project.create_instrument_track("Lead")
	await _add_device_tool.new().execute({"channel": "Lead", "asset_path": "/lib/Piano Soft/Piano_C3.wav"})
	out = _edit([{"op": "add_samples", "folder": "/lib/Kit/Snare"}], "Lead/Sampler")
	_assert(out.get("ok") and str(out.text).contains("as: velocity_layers"), "keys from numbered names come with a hint: %s" % out.get("text", out.get("error", "")))


func _test_kit_from_folders() -> void:
	var s := _setup()
	var drum := _drum_machine(s)
	var before: int = s.editor.history.undo_count()
	var out: Dictionary = await _add_device_tool.new().execute({
		"channel": "Drums", "parent": "Drums/Drum Machine",
		"samples": [{"folder": "/lib/Kit/Kick", "name": "Kick L", "note": 35}, {"folder": "/lib/Kit/Snare", "note": 38}],
	})
	_assert(out.get("ok"), "a kit from folders in one call: %s" % out.get("error", ""))
	_assert(drum.children.size() == 2, "one pad per folder")
	var kick_pad: Object = drum.children.filter(func(c) -> bool: return c.slot_note == 35)[0]
	var kick: Object = _util.find_sampler(kick_pad)
	_assert(kick_pad.get_display_name() == "Kick L" and kick.multisample.zones.size() == 3, "the kick pad on note 35 holds the folder's three files")
	_assert(_zone(kick, "1-Kick").vel_lo == 1 and _zone(kick, "10-Kick").vel_hi == 127 and _zone(kick, "2-Kick").key_lo == 0, "laid out as velocity layers")
	_assert(str(out.text).contains("Kick L") and str(out.text).contains("note 38"), "the result lists the pads: %s" % out.text)
	_assert(s.editor.history.undo_count() > before, "undoable")
	out = await _add_device_tool.new().execute({"channel": "Drums", "parent": "Drums/Drum Machine", "samples": [{"folder": "/lib/Nowhere"}]})
	_assert(out.get("ok") == false and drum.children.size() == 2, "an unknown folder adds nothing")


func _test_device_pad_note_and_taken_note() -> void:
	var s := _setup()
	var drum := _drum_machine(s)
	var tool: Object = _add_device_tool.new()
	var out: Dictionary = await tool.execute({"channel": "Drums", "parent": "Drums/Drum Machine", "device_id": SAMPLER_ID, "name": "Kick L", "note": 35})
	_assert(out.get("ok") and drum.children.size() == 1 and drum.children[0].slot_note == 35, "a device_id pad goes on the asked note: %s" % out.get("text", out.get("error", "")))
	out = await tool.execute({"channel": "Drums", "parent": "Drums/Drum Machine", "device_id": SAMPLER_ID, "name": "Kick R", "note": 35})
	_assert(out.get("ok") == false and str(out.error).contains("taken by Kick L") and drum.children.size() == 1, "a taken note fails instead of moving: %s" % out.get("error", ""))


func _test_set_params_reports_unchanged() -> void:
	var s: Dictionary = await _piano()
	var tool: Object = load("res://ai/tools/SetDeviceParamsTool.gd").new()
	var out: Dictionary = tool.execute({"path": "Piano/Sampler", "params": {"Key_Track": false}})
	_assert(out.get("ok"), "set_device_params: %s" % out.get("error", ""))
	var unchanged: Array = out.data.get("unchanged", [])
	_assert(unchanged.size() == 1 and unchanged[0].name == "Key Track", "a value already set is reported as unchanged: %s" % [out.data])
	out = tool.execute({"path": "Piano/Sampler", "params": {"Key Track": true, "Tune": 0}})
	_assert(out.data.get("changed", []).size() == 1 and out.data.get("unchanged", []).size() == 1, "changed and unchanged side by side")
