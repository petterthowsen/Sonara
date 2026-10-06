# Sampler multisample model and actions (spec 023): zones, groups and the focused zone, the OSC they
# send, JSON persistence, snapshot undo that re-sends only what changed, per-zone waveform routing,
# and the undoable actions (drops, conversions, batch operations). No live engine: the AudioEngineOSC
# autoload queues sends in `_pending_sends`, and HistoryUtil.test_recorder collects the commands.
# Run: godot --headless --path Godot -s tests/test_sampler_multisample.gd -- --test
extends TestBase

const SAMPLER_ID := "sonara.builtin.sampler"
const ENUMS := {"Loop Mode": ["Off", "On", "Ping-Pong"]}

var _project_script: GDScript
var _device_script: GDScript
var _instance_script: GDScript
var _actions: GDScript
var _history_util: GDScript
var _asset_script: GDScript
var _drop_util: GDScript
var _osc: Node
var _recorded: Array = []


func suite_name() -> String:
	return "Sampler multisample"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_instance_script = load("res://data/DeviceInstance.gd")
	_actions = load("res://devices/builtin/sampler/SamplerActions.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_asset_script = load("res://browser/Asset.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	_history_util.test_recorder = func(cmd) -> void: _recorded.append(cmd)
	_test_add_files_and_osc()
	_test_zone_osc_args()
	_test_set_zone_fields()
	_test_groups()
	_test_focus()
	_test_remove_zones()
	_test_json_round_trip()
	_test_old_project_loads_single()
	_test_load_file_delegates()
	_test_loading_state()
	_test_waveform_routing()
	_test_snapshot_restore_diff()
	_test_restore_add_remove()
	_test_drop_single_replaces()
	_test_drop_keeps_old_sample()
	_test_drop_adds_at_key()
	_test_convert_to_multisample()
	_test_convert_to_single()
	_test_batch_is_one_step()
	_test_delete_and_group_undo()
	_test_zone_edit_merging()
	_test_device_drop()
	_history_util.test_recorder = Callable()


# --- helpers ---------------------------------------------------------------

func _make_device() -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(SAMPLER_ID)
	if device != null:
		return device
	device = _device_script.new(SAMPLER_ID, "Sampler", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	device.supports_file_loading = true
	device.supported_file_extensions.assign([".wav", ".flac"])
	var add := func(id: int, name: String, min_v: float, max_v: float, default_v: float, type := "float") -> void:
		var param := DeviceParameter.new(id, name)
		param.min_value = min_v
		param.max_value = max_v
		param.default_value = default_v
		param.param_type = type
		if type == "enum":
			param.enum_values.assign(ENUMS[name])
		device.add_parameter(param)
	add.call(1, "Tune", -24.0, 24.0, 0.0)
	add.call(3, "Root", 0.0, 127.0, 60.0)
	add.call(7, "Start", 0.0, 1.0, 0.0)
	add.call(8, "End", 0.0, 1.0, 1.0)
	add.call(14, "Fine", -100.0, 100.0, 0.0)
	add.call(20, "Reverse", 0.0, 1.0, 0.0, "bool")
	add.call(21, "Loop Mode", 0.0, 2.0, 0.0, "enum")
	add.call(22, "Loop Start", 0.0, 1.0, 0.0)
	add.call(23, "Loop End", 0.0, 1.0, 1.0)
	add.call(24, "Crossfade", 0.0, 100.0, 0.0)
	registry._devices[SAMPLER_ID] = device
	return device


## {"project", "channel", "inst"}: a Sampler on a project channel.
func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Sampler").channel
	var inst: Object = _instance_script.new(_make_device(), ch.id, -1)
	ch.add_device(inst)
	_osc._pending_sends.clear()
	_recorded.clear()
	return {"project": project, "channel": ch, "inst": inst}


## Args of every queued send whose address ends with `suffix`, oldest first.
func _sent(suffix: String) -> Array:
	return _osc._pending_sends \
		.filter(func(item) -> bool: return str(item.address).ends_with(suffix)) \
		.map(func(item): return item.args)


func _addresses() -> Array:
	return _osc._pending_sends.map(func(item) -> String: return str(item.address))


## Sends whose address contains `/zone/` or `/zone_group/` and ends with set/remove (not loads).
func _zone_writes() -> Array:
	return _addresses().filter(func(a: String) -> bool:
		return (a.contains("/zone/") or a.contains("/zone_group/")) and (a.ends_with("/set") or a.ends_with("/remove")))


func _clear() -> void:
	_osc._pending_sends.clear()
	_recorded.clear()


## Three zones on C3, E3 and G3, with the model's signals counted into the returned `seen`.
func _three(s: Dictionary) -> Object:
	var ms: Object = s.inst.ensure_multisample()
	ms.add_files(["/tmp/Piano_C3.wav", "/tmp/Piano_E3.wav", "/tmp/Piano_G3.wav"])
	_clear()
	return ms


func _count(ms: Object, signal_name: String) -> Array:
	var seen := [0]
	ms.connect(signal_name, func(_a = null) -> void: seen[0] += 1)
	return seen


func _undo_all() -> void:
	for i in range(_recorded.size() - 1, -1, -1):
		_recorded[i].undo()


# --- model -----------------------------------------------------------------

func _test_add_files_and_osc() -> void:
	var s := _setup()
	var ms: Object = s.inst.ensure_multisample()
	var zones_seen := _count(ms, "zones_changed")
	var mode_seen := _count(ms, "mode_changed")
	var ids: Array = ms.add_files(["/tmp/Piano_C3.wav", "/tmp/Piano_E3.wav"])
	_assert(ids == [1, 2], "add_files returns the new zone ids (%s)" % [ids])
	_assert(ms.active and mode_seen[0] == 1, "adding files turns multisample mode on once")
	_assert(zones_seen[0] == 1, "adding two files emits zones_changed once")
	_assert(ms.get_zone(1).root == 60 and ms.get_zone(2).root == 64, "roots come from the file names")
	_assert(ms.get_zone(1).key_hi == 62 and ms.get_zone(2).key_lo == 63, "keys are laid out halfway between roots")
	_assert(ms.focused_zone_id == 1, "the first zone added is focused")
	_assert(_sent("/multisample") == [[1]], "multisample 1 is sent")
	var path_args := _sent("/zone/1/load_file")
	_assert(path_args.size() == 1 and path_args[0][0] == "/tmp/Piano_C3.wav" and str(path_args[0][1]).begins_with("zone:"), "zone/1/load_file carries the path and a zone request id (%s)" % [path_args])
	_assert(_sent("/zone/2/set").size() == 1, "zone/2/set is sent once")
	var order := _addresses().filter(func(a: String) -> bool: return a.ends_with("/zone/1/set") or a.ends_with("/zone/1/load_file"))
	_assert(order.size() == 2 and order[0].ends_with("/set"), "a zone is set before its file loads")
	_assert(ms.get_zone(1).loading_state == "loading", "the zone is loading until the engine says ready")


func _test_zone_osc_args() -> void:
	var zone := SamplerZone.new(7, "/tmp/x.wav")
	zone.apply_fields({"key": [10, 20], "vel": [30, 40], "root": 15, "tune": 2.0, "fine": 50.0, "gain": 0.5,
		"start": 0.1, "end": 0.9, "reverse": true, "loop_mode": 2, "loop_start": 0.2, "loop_end": 0.8,
		"crossfade": 0.25, "key_fade": [1, 2], "vel_fade": [3, 4], "group": 5})
	var a: Array = zone.to_osc_args()
	_assert(a.size() == 19, "zone/set has 19 args (%d)" % a.size())
	_assert(a.slice(0, 5) == [10, 20, 30, 40, 15], "args 0-4: key range, velocity range, root (%s)" % [a.slice(0, 5)])
	_assert(is_equal_approx(a[5], 2.5) and is_equal_approx(a[6], 0.5), "tune and fine fold into semitones; gain follows")
	_assert(a.slice(7, 14) == [0.1, 0.9, 1, 2, 0.2, 0.8, 0.25], "args 7-13: points, reverse, loop mode, loop points, crossfade (%s)" % [a.slice(7, 14)])
	_assert(a.slice(14) == [1, 2, 3, 4, 5], "args 14-18: key fades, velocity fades, group (%s)" % [a.slice(14)])
	zone.apply_fields({"key": [90, 20], "vel": [0, 500], "root": 300})
	_assert(zone.key_lo == 20 and zone.key_hi == 90, "ranges are ordered")
	_assert(zone.vel_lo == 1 and zone.vel_hi == 127 and zone.root == 127, "ranges and root are clamped")


func _test_set_zone_fields() -> void:
	var s := _setup()
	var ms := _three(s)
	var seen: Array = []
	ms.zone_changed.connect(func(zid: int) -> void: seen.append(zid))
	ms.set_zone_fields(2, {"gain": 0.5, "root": 66})
	_assert(seen == [2], "set_zone_fields emits zone_changed for that zone")
	var sent := _sent("/zone/2/set")
	_assert(sent.size() == 1 and sent[0][4] == 66 and is_equal_approx(sent[0][6], 0.5), "the whole zone is sent with the new values")
	ms.set_zone_fields(2, {"gain": 0.5})
	_assert(seen == [2] and _sent("/zone/2/set").size() == 1, "an unchanged edit sends and emits nothing")
	ms.set_zone_fields(99, {"gain": 0.5})
	_assert(_sent("/zone/99/set").is_empty(), "an unknown zone is ignored")


func _test_groups() -> void:
	var s := _setup()
	var ms := _three(s)
	var gid: int = ms.add_group("Soft")
	_assert(gid == 1 and ms.groups.size() == 1, "add_group allocates group 1")
	_assert(_sent("/zone_group/1/set") == [[1.0, 0, 0, 0]], "zone_group/1/set sends gain, mute, solo, play mode (%s)" % [_sent("/zone_group/1/set")])
	ms.move_to_group([1, 2], gid)
	_assert(ms.get_zone(1).group_id == 1 and ms.get_zone(2).group_id == 1 and ms.get_zone(3).group_id == 0, "move_to_group moves only the given zones")
	_assert(_sent("/zone/1/set")[0][18] == 1, "the zone's group id is sent")
	ms.move_to_group([3], 42)
	_assert(ms.get_zone(3).group_id == 0, "an unknown group is refused")
	ms.set_group_fields(gid, {"mute": true, "play_mode": 1, "gain": 0.5})
	_assert(_sent("/zone_group/1/set").back() == [0.5, 1, 0, 1], "group fields are sent as one set")
	ms.set_group_fields(0, {"solo": true})
	_assert(ms.ungrouped.solo and _sent("/zone_group/0/set").size() == 1, "Ungrouped has the same controls under id 0")
	_clear()
	ms.remove_group(gid)
	_assert(ms.get_zone(1).group_id == 0 and ms.get_zone(2).group_id == 0, "REQ-025: deleting a group moves its zones to Ungrouped")
	_assert(_sent("/zone_group/1/remove").size() == 1 and _sent("/zone/1/set").size() == 1, "the group is removed and its zones re-sent")
	_assert(ms.groups.is_empty() and ms.zones.size() == 3, "the zones stay")
	ms.rename_group(0, "x")
	_assert(ms.ungrouped.display_name() == "Ungrouped", "Ungrouped can't be renamed")


func _test_focus() -> void:
	var s := _setup()
	var ms := _three(s)
	var seen := _count(ms, "focus_changed")
	ms.set_focus(3)
	_assert(ms.focused_zone_id == 3 and seen[0] == 1 and _sent("/focus_zone") == [[3]], "set_focus emits and tells the engine")
	ms.set_focus(3)
	ms.set_focus(99)
	_assert(seen[0] == 1 and ms.focused_zone_id == 3, "an unchanged or unknown focus does nothing")
	_assert(ms.zones_by_root().map(func(z): return z.id) == [1, 2, 3], "zones_by_root sorts by root key")


func _test_remove_zones() -> void:
	var s := _setup()
	var ms := _three(s)
	ms.set_focus(2)
	ms.remove_zones([2])
	_assert(ms.zones.size() == 2 and _sent("/zone/2/remove").size() == 1, "remove_zones removes and tells the engine")
	_assert(ms.focused_zone_id == 1, "focus moves to the first remaining zone")
	ms.remove_zones([1, 3])
	_assert(ms.focused_zone_id == 0, "no zones, no focus")
	ms.add_files(["/tmp/a_C3.wav"])
	_assert(ms.get_zone(4) != null, "zone ids are never reused (%s)" % [ms.zones.map(func(z): return z.id)])
	ms.set_active(false)
	_assert(ms.zones.is_empty() and not ms.active and _sent("/multisample").back() == [0], "leaving multisample mode clears the zones")


# --- persistence -----------------------------------------------------------

func _test_json_round_trip() -> void:
	var s := _setup()
	var ms := _three(s)
	ms.add_group("Soft")
	ms.move_to_group([2], 1)
	ms.set_group_fields(1, {"play_mode": 1, "mute": true})
	ms.set_zone_fields(3, {"loop_mode": 1, "loop_start": 0.25, "gain": 0.8, "key_fade": [2, 3]})
	ms.set_focus(3)
	var json: Dictionary = ms.to_json()
	var back: Object = load("res://data/SamplerMultisample.gd").from_json(JSON.parse_string(JSON.stringify(json)))
	_assert(back.to_json() == json, "REQ-027: the model survives a JSON round trip")
	_assert(back.focused_zone_id == 3 and back.groups[0].play_mode == 1 and back.groups[0].mute, "focus and groups come back")
	# Through the device instance, as a project or a preset saves it.
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.inst.to_json()))
	_assert(data.has("multisample"), "the instance saves its multisample")
	var inst2: Object = _instance_script.from_json(data)
	_assert(inst2 != null and inst2.multisample != null and inst2.multisample.to_json() == json, "the instance loads it back, identical")
	_assert(inst2.multisample.get_zone(1).loading_state == "idle", "load state is runtime only")
	_osc._pending_sends.clear()
	inst2.channel_id = s.channel.id
	inst2.sync_to_engine()
	_assert(_sent("/multisample") == [[1]] and _sent("/zone/3/set").size() == 1 and _sent("/zone/3/load_file").size() == 1, "sync_to_engine re-sends the mode, zones and files")
	_assert(_sent("/zone_group/1/set").size() == 1 and _sent("/focus_zone") == [[3]], "sync_to_engine re-sends groups and focus")


func _test_old_project_loads_single() -> void:
	var s := _setup()
	_assert(not s.inst.to_json().has("multisample"), "a Sampler that never used multisample saves no key")
	s.inst.ensure_multisample()
	_assert(not s.inst.to_json().has("multisample"), "an unused inactive multisample is omitted too")
	var inst2: Object = _instance_script.from_json(JSON.parse_string(JSON.stringify(s.inst.to_json())))
	_assert(inst2.multisample == null, "a project without the key loads in single-sample mode")
	_osc._pending_sends.clear()
	inst2.sync_to_engine()
	_assert(_sent("/multisample").is_empty(), "single-sample mode sends no multisample messages")


func _test_load_file_delegates() -> void:
	var s := _setup()
	s.inst.load_file("/tmp/kick.wav")
	_assert(s.inst.loaded_file_path == "/tmp/kick.wav" and s.inst.multisample == null, "single mode: load_file loads the sample as before")
	var ms: Object = s.inst.ensure_multisample()
	ms.set_active(true)
	s.inst.load_file("/tmp/snare.wav")
	_assert(ms.zones.size() == 1 and ms.zones[0].path == "/tmp/snare.wav", "multisample mode: load_file adds a zone")
	_assert(s.inst.loaded_file_path == "/tmp/kick.wav", "loaded_file_path is left alone in multisample mode")


func _test_loading_state() -> void:
	var s := _setup()
	var ms := _three(s)
	var seen: Array = []
	ms.zone_changed.connect(func(zid: int) -> void: seen.append(zid))
	var base := "/channel/%d/device/%d/zone/%d/loading_state" % [s.channel.id, s.inst.position, 2]
	s.inst._on_zone_loading_state_received(["ready"], base)
	_assert(ms.get_zone(2).loading_state == "ready" and seen == [2], "a ready state reaches only that zone")
	s.inst._on_zone_loading_state_received(["failed:No such file"], base)
	_assert(ms.get_zone(2).is_missing() and ms.get_zone(2).missing_reason() == "No such file", "REQ-028: failed marks the zone missing with the reason")
	_assert(not ms.get_zone(1).is_missing() and not ms.get_zone(3).is_missing(), "the other zones are unaffected")
	s.inst._on_zone_loading_state_received(["ready"], "/channel/2/device/0/zone/abc/loading_state")
	s.inst._on_zone_loading_state_received(["ready"], "/channel/2/device/0/zone/99/loading_state")
	_assert(seen == [2, 2], "unknown or malformed zone addresses are ignored")


func _test_waveform_routing() -> void:
	var s := _setup()
	var ms := _three(s)
	var zone: Object = ms.get_zone(2)
	var req: String = zone.load_req_id
	_assert(s.project._waveform_for_req(req) == zone.source, "the zone's request id resolves to the zone's own source")
	s.project._on_audiofile_decode_ready([req, "key2", 2, 1000, 44100, 0.5])
	_assert(zone.source.audio_frames == 1000 and zone.source.cache_key == "key2", "decode/ready fills that zone's source")
	_assert(ms.get_zone(1).source.audio_frames == 0, "other zones are untouched")
	_assert(s.inst.sample_source == null, "the device's own sample source is untouched")
	_assert(s.project._waveform_for_req("zone:nope") == null, "an unknown request id resolves to nothing")


# --- snapshot undo ---------------------------------------------------------

func _test_snapshot_restore_diff() -> void:
	var s := _setup()
	var ms := _three(s)
	var before: Dictionary = ms.snapshot()
	ms.set_zone_fields(2, {"root": 65, "gain": 0.5})
	_clear()
	ms.restore(before)
	_assert(ms.to_json() == before, "restore returns the exact JSON")
	_assert(_zone_writes().size() == 1 and _zone_writes()[0].ends_with("/zone/2/set"), "restore sends only the changed zone's set (%s)" % [_zone_writes()])
	_assert(_sent("/zone/2/load_file").is_empty(), "an unchanged path doesn't reload")
	_clear()
	ms.restore(before)
	_assert(_osc._pending_sends.is_empty(), "restoring the current state sends nothing")
	var single: Dictionary = ms.snapshot_zone(1)
	ms.set_zone_fields(1, {"vel": [5, 50]})
	_clear()
	ms.restore_zone(single)
	_assert(ms.get_zone(1).vel_lo == 1 and _zone_writes().size() == 1, "restore_zone puts one zone back and sends only it")
	ms.set_zone_fields(1, {"vel": [5, 50]})
	ms.restore(before)
	ms.set_zone_fields(1, {"name": "renamed"})
	ms.restore(before)
	_assert(ms.get_zone(1).name == "Piano_C3", "a zone's name is part of the snapshot")


func _test_restore_add_remove() -> void:
	var s := _setup()
	var ms := _three(s)
	var before: Dictionary = ms.snapshot()
	ms.add_files(["/tmp/Piano_B3.wav"])
	var added: Dictionary = ms.snapshot()
	_clear()
	ms.restore(before)
	_assert(ms.zones.size() == 3 and _zone_writes() == [_zone_writes()[0]] and _zone_writes()[0].ends_with("/zone/4/remove"), "undoing an add removes just that zone (%s)" % [_zone_writes()])
	_clear()
	ms.restore(added)
	_assert(ms.zones.size() == 4 and _sent("/zone/4/set").size() == 1 and _sent("/zone/4/load_file").size() == 1, "redoing it sets and loads the zone again")
	_assert(ms.to_json() == added, "the redone state is identical")
	var changed_path: Dictionary = ms.snapshot()
	changed_path["zones"][0]["path"] = "/tmp/other.wav"
	_clear()
	ms.restore(changed_path)
	_assert(_sent("/zone/1/load_file").size() == 1 and ms.get_zone(1).name == "Piano_C3", "a re-pathed zone reloads")
	ms.restore(before)
	ms.add_group("G")
	var with_group: Dictionary = ms.snapshot()
	ms.restore(before)
	_assert(ms.groups.is_empty(), "restore removes a group that wasn't there")
	_clear()
	ms.restore(with_group)
	_assert(_sent("/zone_group/1/set").size() == 1, "restore re-sends a group that came back")
	var off := {"active": false, "zones": [], "groups": [], "next_zone_id": 1, "next_group_id": 1}
	_clear()
	ms.restore(off)
	_assert(not ms.active and ms.zones.is_empty() and _sent("/multisample") == [[0]], "restoring an inactive snapshot leaves multisample mode")


# --- actions ---------------------------------------------------------------

func _test_drop_single_replaces() -> void:
	var s := _setup()
	s.inst.load_file("/tmp/snare.wav")
	_clear()
	_actions.drop_files(s.inst, ["/tmp/kick.wav"])
	_assert(s.inst.loaded_file_path == "/tmp/kick.wav", "REQ-011: one file replaces the sample")
	_assert(s.inst.multisample == null or not s.inst.multisample.active, "REQ-011: and stays in single-sample mode")
	_assert(_recorded.size() == 1, "REQ-011: one undo step")
	_recorded[0].undo()
	_assert(s.inst.loaded_file_path == "/tmp/snare.wav", "undo brings back the old sample")


func _test_drop_keeps_old_sample() -> void:
	var s := _setup()
	s.inst.load_file("/tmp/old_sound.wav")
	s.inst.set_parameter_real_by_name("Root", 62)
	s.inst.set_parameter_real_by_name("Loop Mode", 1)
	s.inst.set_parameter_real_by_name("Loop Start", 0.3)
	s.inst.set_parameter_real_by_name("Crossfade", 20)
	_clear()
	var before: Dictionary = _actions.capture_state(s.inst)
	_actions.drop_files(s.inst, ["/tmp/Piano_C3.wav", "/tmp/Piano_E3.wav", "/tmp/Piano_G3.wav"])
	var ms: Object = s.inst.multisample
	_assert(ms.active and ms.zones.size() == 4, "REQ-012: three files on a Sampler holding one make four zones (%d)" % ms.zones.size())
	var old: Object = ms.zones[0]
	_assert(old.path == "/tmp/old_sound.wav" and old.root == 62, "REQ-012: the old sample is kept, with its Root parameter as root")
	_assert(old.loop_mode == 1 and is_equal_approx(old.loop_start, 0.3) and is_equal_approx(old.crossfade, 0.2), "REQ-012: it keeps its loop points and crossfade")
	_assert(s.inst.loaded_file_path == "", "the single-mode file is cleared")
	var c3: Object = ms.zones[1]
	_assert(c3.root == 60 and c3.key_lo == 0, "the new zones are laid out together with it")
	_assert(_recorded.size() == 1, "one undo step for the whole drop")
	var after: Dictionary = _actions.capture_state(s.inst)
	_recorded[0].undo()
	_assert(not s.inst.multisample.active and s.inst.loaded_file_path == "/tmp/old_sound.wav", "undo returns to single-sample mode with the old file")
	_assert(_actions.capture_state(s.inst) == before, "undo restores the exact state")
	_recorded[0].do()
	_assert(_actions.capture_state(s.inst) == after, "redo restores the exact multisample state")


func _test_drop_adds_at_key() -> void:
	var s := _setup()
	var ms := _three(s)
	_actions.drop_files(s.inst, ["/tmp/a.wav", "/tmp/b.wav"], 65)
	_assert(ms.zones.size() == 5, "REQ-015: the existing zones stay and two are added")
	_assert(ms.zones[3].key_lo == 65 and ms.zones[4].key_lo == 66, "REQ-015: unnamed files land on consecutive keys from the pointer (%d, %d)" % [ms.zones[3].key_lo, ms.zones[4].key_lo])
	_assert(_recorded.size() == 1, "REQ-015: one undo step")
	_recorded[0].undo()
	_assert(ms.zones.size() == 3, "undo removes both")


func _test_convert_to_multisample() -> void:
	var s := _setup()
	s.inst.load_file("/tmp/pad.wav")
	s.inst.set_parameter_real_by_name("Root", 62)
	s.inst.set_parameter_real_by_name("Loop Mode", 1)
	s.inst.set_parameter_real_by_name("Loop Start", 0.4)
	s.inst.set_parameter_real_by_name("Loop End", 0.7)
	s.inst.set_parameter_real_by_name("Reverse", 1)
	_clear()
	var before: Dictionary = _actions.capture_state(s.inst)
	_actions.convert_to_multisample(s.inst)
	var ms: Object = s.inst.multisample
	var z: Object = ms.zones[0]
	_assert(ms.active and ms.zones.size() == 1, "REQ-013: one zone")
	_assert(z.root == 62 and z.loop_mode == 1 and is_equal_approx(z.loop_start, 0.4) and is_equal_approx(z.loop_end, 0.7) and z.reverse, "REQ-013: the zone takes the parameter values")
	_assert(z.key_lo == 0 and z.key_hi == 127 and z.vel_lo == 1 and z.vel_hi == 127, "REQ-013: it covers all keys and velocities")
	_assert(_recorded.size() == 1, "REQ-013: one undo step")
	_recorded[0].undo()
	_assert(_actions.capture_state(s.inst) == before and not ms.active, "undo restores single-sample mode and its file")
	_clear()
	var empty := _setup()
	_actions.convert_to_multisample(empty.inst)
	_assert(empty.inst.multisample.active and empty.inst.multisample.zones.is_empty(), "REQ-010: Create Multisample on an empty Sampler gives an empty multisample")


func _test_convert_to_single() -> void:
	var s := _setup()
	var ms := _three(s)
	ms.set_zone_fields(2, {"loop_mode": 2, "tune": 3.0, "reverse": true, "crossfade": 0.5})
	ms.set_focus(2)
	_clear()
	var before: Dictionary = _actions.capture_state(s.inst)
	_actions.convert_to_single(s.inst)
	_assert(not ms.active and ms.zones.is_empty(), "REQ-014: back in single-sample mode")
	_assert(s.inst.loaded_file_path == "/tmp/Piano_E3.wav", "REQ-014: the focused zone's file is the sample")
	_assert(is_equal_approx(s.inst.get_parameter_real_by_name("Root"), 64.0), "REQ-014: Root takes the zone's root")
	_assert(int(round(s.inst.get_parameter_real_by_name("Loop Mode"))) == 2 and is_equal_approx(s.inst.get_parameter_real_by_name("Tune"), 3.0), "REQ-014: loop mode and tune are copied")
	_assert(s.inst.get_parameter_real_by_name("Reverse") >= 0.5 and is_equal_approx(s.inst.get_parameter_real_by_name("Crossfade"), 50.0), "REQ-014: reverse and crossfade are copied (crossfade in percent)")
	_assert(_recorded.size() == 1, "REQ-014: one undo step")
	_recorded[0].undo()
	_assert(ms.active and ms.zones.size() == 3 and s.inst.loaded_file_path == "", "undo restores the multisample")
	_assert(_actions.capture_state(s.inst) == before, "undo restores the exact state, parameters included")


func _test_batch_is_one_step() -> void:
	var s := _setup()
	var ms: Object = s.inst.ensure_multisample()
	ms.add_files(["/tmp/a.wav", "/tmp/b.wav", "/tmp/c.wav", "/tmp/d.wav"])
	_clear()
	var before: Dictionary = ms.snapshot()
	_actions.apply_batch(s.inst, "distribute_velocity", [1, 2, 3, 4], {"lo": 1, "hi": 127})
	var got: Array = ms.zones.map(func(z): return [z.vel_lo, z.vel_hi])
	_assert(got == [[1, 32], [33, 64], [65, 96], [97, 127]], "REQ-047: distribute on velocity (%s)" % [got])
	_assert(_recorded.size() == 1, "REQ-047: one undo step")
	_recorded[0].undo()
	_assert(ms.to_json() == before, "undo restores every velocity range")
	_clear()
	_actions.apply_batch(s.inst, "assign_note", [1, 2], {"lo": 60, "hi": 72})
	_assert(ms.zones[0].key_lo == 60 and ms.zones[1].key_hi == 72 and ms.zones[2].key_lo != 60, "assign_note changes only the selected zones")
	_assert(_recorded.size() == 1, "assign is one step")
	_clear()
	_actions.apply_batch(s.inst, "assign_note", [1, 2], {"lo": 60, "hi": 72})
	_assert(_recorded.is_empty(), "a batch that changes nothing records nothing")
	_actions.apply_batch(s.inst, "bogus", [1], {})
	_actions.apply_batch(s.inst, "assign_note", [99], {})
	_assert(_recorded.is_empty(), "unknown operations and zones are ignored")


func _test_delete_and_group_undo() -> void:
	var s := _setup()
	var ms := _three(s)
	var before: Dictionary = ms.snapshot()
	_actions.delete_zones(s.inst, [1, 3])
	_assert(ms.zones.size() == 1 and _recorded.size() == 1, "delete removes both zones in one step")
	_recorded[0].undo()
	_assert(ms.to_json() == before, "undo restores both zones exactly")
	_clear()
	_actions.add_group(s.inst, "Soft")
	_actions.move_to_group(s.inst, [1, 2], 1)
	_assert(_recorded.size() == 2 and ms.get_zone(1).group_id == 1, "add group and move are one step each")
	_undo_all()
	_assert(ms.groups.is_empty() and ms.get_zone(1).group_id == 0, "undoing both leaves no group")
	_assert(ms.to_json() == before or ms.next_group_id == 2, "only the id counter may differ after undoing an add")


func _test_zone_edit_merging() -> void:
	var s := _setup()
	var ms := _three(s)
	_actions.set_zone_fields(s.inst, 1, {"gain": 0.9})
	_actions.set_zone_fields(s.inst, 1, {"gain": 0.8})
	_actions.set_zone_fields(s.inst, 2, {"gain": 0.7})
	_assert(_recorded.size() == 3, "three edits record three commands")
	_assert(_recorded[1].can_merge(_recorded[0]) or _recorded[0].can_merge(_recorded[1]), "two edits of one zone can merge into one undo step")
	_assert(not _recorded[0].can_merge(_recorded[2]), "edits of different zones never merge")
	_recorded[0].merge_with(_recorded[1])
	_recorded[0].undo()
	_assert(is_equal_approx(ms.get_zone(1).gain, 1.0), "the merged step restores the value from before the first edit")
	_recorded[0].do()
	_assert(is_equal_approx(ms.get_zone(1).gain, 0.8), "and redoes to the last value")
	_clear()
	_actions.set_zone_fields(s.inst, 1, {"gain": 0.8})
	_assert(_recorded.is_empty(), "an edit that changes nothing records nothing")


func _test_device_drop() -> void:
	var s := _setup()
	var assets: Array = []
	for p in ["/tmp/Piano_C3.wav", "/tmp/Piano_E3.wav"]:
		var a: Object = _asset_script.new()
		a.type = _asset_script.TYPE.Audio
		a.path = p
		assets.append(a)
	_assert(_drop_util.can_drop_on_device(s.inst, assets), "a multi-selection of audio files can drop on a Sampler")
	var midi: Object = _asset_script.new()
	midi.type = _asset_script.TYPE.Midi
	midi.path = "/tmp/x.mid"
	var mixed: Array = [assets[0], midi]
	_assert(not _drop_util.can_drop_on_device(s.inst, mixed), "a selection with a non-audio file is refused")
	_assert(not _drop_util.can_drop_on_device(s.inst, []), "an empty selection is refused")
	var mp3: Object = _asset_script.new()
	mp3.type = _asset_script.TYPE.Audio
	mp3.path = "/tmp/x.mp3"
	_assert(not _drop_util.can_drop_on_device(s.inst, [mp3]), "files the Sampler can't load are refused")
	_drop_util.drop_on_device(s.inst, assets)
	_assert(s.inst.multisample.active and s.inst.multisample.zones.size() == 2, "dropping two files makes two zones")
	_assert(_recorded.size() == 1, "the drop is one undo step")
	_clear()
	var one: Object = _asset_script.new()
	one.type = _asset_script.TYPE.Audio
	one.path = "/tmp/Piano_G3.wav"
	_drop_util.drop_on_device(s.inst, one)
	_assert(s.inst.multisample.zones.size() == 3 and _recorded.size() == 1, "a single file on a multisample Sampler also adds a zone")
