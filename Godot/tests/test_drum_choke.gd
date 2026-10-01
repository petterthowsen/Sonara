# test_drum_choke.gd
# Headless tests for Drum Machine choke groups (spec 013-drum-synths, decision 8): the pad setter
# clamps to 0-8, sends `slot/{n}/choke` and signals; the group round-trips through the project
# JSON under the `choke_group` key, and old data without it loads as 0. No live OSC socket is
# needed: the AudioEngineOSC autoload queues sends in `_pending_sends`.
#
# Project and DeviceInstance reference autoloads by bare name, so they are load()ed in run_tests().
# Run: godot --headless --path Godot -s tests/test_drum_choke.gd -- --test
extends TestBase

const DRUM_ID := "sonara.builtin.drum_machine"
const CHAIN_ID := "sonara.builtin.chain"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _add_cmd: GDScript


func suite_name() -> String:
	return "Drum choke groups"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	# Slot chains are Chain instances, so the Chain device must be registered.
	_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true)
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_test_setter_clamps_and_sends()
	_test_sync_to_engine_resends()
	_test_project_round_trip()
	_test_legacy_json_defaults_zero()


# --- helpers ---------------------------------------------------------------

## Register a fake device `device_id` in the asset registry.
func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


## A project channel holding a Drum Machine with two pads on notes 36 and 38.
## Returns {"project", "channel", "drum", "pad0", "pad1"}.
func _drum_setup() -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum: Object = _device_instance_script.new(_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	return {
		"project": project, "channel": ch, "drum": drum,
		"pad0": _pad(ch, drum, "kick", 36), "pad1": _pad(ch, drum, "snare", 38),
	}


## Add an effect onto a Drum Machine pad. Returns the pad's slot chain (the pad instance).
func _pad(ch: Object, drum: Object, n: String, note: int) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
	inst.slot_note = note
	var cmd: Object = _add_cmd.new(ch, inst, -1, drum)
	cmd.do()
	return cmd.device_instance


## The saved JSON of the first root device on channel `channel_id`.
func _find_device_json(data: Dictionary, channel_id: int) -> Dictionary:
	for ch_data in data.channels:
		if int(ch_data.id) == channel_id:
			return ch_data.devices[0]
	return {}


## Erase `choke_group` from every device (and child) in a project JSON, as an old save has none.
func _erase_choke(node) -> void:
	if node is Dictionary:
		node.erase("choke_group")
		for key in node:
			_erase_choke(node[key])
	elif node is Array:
		for item in node:
			_erase_choke(item)


# --- tests -----------------------------------------------------------------

func _test_setter_clamps_and_sends() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	_assert(osc != null, "setup: AudioEngineOSC autoload present")
	if osc == null:
		return
	var s := _drum_setup()
	var pad0: Object = s.pad0
	var pad1: Object = s.pad1
	var seen: Array = []
	pad0.choke_group_changed.connect(func(g: int) -> void: seen.append(g))
	osc._pending_sends.clear()
	pad0.set_choke_group(1)
	pad1.set_choke_group(9)
	_assert(pad0.choke_group == 1, "the setter stores the group")
	_assert(pad1.choke_group == 8, "groups above 8 clamp to 8 (got %d)" % pad1.choke_group)
	pad1.set_choke_group(-3)
	_assert(pad1.choke_group == 0, "groups below 0 clamp to 0 (got %d)" % pad1.choke_group)
	_assert(seen == [1], "the setter emits choke_group_changed: %s" % str(seen))
	var sent: Array = osc._pending_sends.filter(func(item) -> bool: return str(item.address).ends_with("/slot/0/choke"))
	_assert(sent.size() == 1 and int(sent[0].args[0]) == 1, "the setter sends slot/0/choke with the group: %s" % str(sent))
	osc._pending_sends.clear()


func _test_sync_to_engine_resends() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	if osc == null:
		return
	var s := _drum_setup()
	var pad0: Object = s.pad0
	pad0.set_choke_group(5)
	osc._pending_sends.clear()
	pad0.sync_to_engine()
	var sent: Array = osc._pending_sends.filter(func(item) -> bool: return str(item.address).ends_with("/slot/0/choke"))
	_assert(sent.size() == 1 and int(sent[0].args[0]) == 5, "sync_to_engine re-sends the choke group (got %s)" % str(sent))
	osc._pending_sends.clear()


func _test_project_round_trip() -> void:
	var s := _drum_setup()
	s.pad0.set_choke_group(3)
	s.pad1.set_choke_group(7)
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.project.to_json()))
	var drum_json: Dictionary = _find_device_json(data, s.channel.id)
	_assert(int(drum_json.children[0].choke_group) == 3 and int(drum_json.children[1].choke_group) == 7, "the group is saved under the choke_group key")
	var loaded: Object = _project_script.from_json(data)
	var drum: Object = loaded.get_channel_by_id(s.channel.id).devices[0]
	_assert(drum.children[0].choke_group == 3 and drum.children[1].choke_group == 7, "save then load preserves the choke groups (got %d, %d)" % [drum.children[0].choke_group, drum.children[1].choke_group])


func _test_legacy_json_defaults_zero() -> void:
	var s := _drum_setup()
	s.pad0.set_choke_group(4)
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.project.to_json()))
	_erase_choke(data)
	var loaded: Object = _project_script.from_json(data)
	var drum: Object = loaded.get_channel_by_id(s.channel.id).devices[0]
	_assert(drum.children[0].choke_group == 0, "old data without the field loads as group 0 (got %d)" % drum.children[0].choke_group)
