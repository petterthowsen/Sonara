# test_drum_choke.gd
# Headless tests for Drum Machine choke targets (spec 020, Phase 3; ADR 0015): a pad stores the ids
# of the sibling pads it chokes, "choked by" is derived, and the engine gets a 16-byte note mask
# per pad on `slot/{n}/choke_targets`, re-sent when a note changes or a pad comes or goes. Targets
# round-trip through the project JSON, and a project saved with choke groups migrates to mutual
# targets. No live OSC socket is needed: the AudioEngineOSC autoload queues sends in `_pending_sends`.
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
var _history_util: GDScript
var _osc: Node


func suite_name() -> String:
	return "Drum choke targets"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_history_util = load("res://history/HistoryUtil.gd")
	_osc = root.get_node_or_null("AudioEngineOSC")
	_assert(_osc != null, "setup: AudioEngineOSC autoload present")
	if _osc == null:
		return
	# Slot chains are Chain instances, so the Chain device must be registered.
	_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true)
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_test_set_and_send_mask()
	_test_toggle_is_one_undo_step()
	_test_choked_by_is_derived()
	_test_note_change_resends_masks()
	_test_removed_pad_leaves_masks_and_undo_restores()
	_test_sync_slot_resends()
	_test_project_round_trip()
	_test_legacy_groups_migrate()


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


## A project channel holding a Drum Machine with three pads on notes 36, 38 and 42.
## Returns {"project", "channel", "drum", "pad0", "pad1", "pad2"}.
func _drum_setup() -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum: Object = _device_instance_script.new(_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	return {
		"project": project, "channel": ch, "drum": drum,
		"pad0": _pad(ch, drum, "kick", 36), "pad1": _pad(ch, drum, "snare", 38),
		"pad2": _pad(ch, drum, "hat", 42),
	}


## Add an effect onto a Drum Machine pad. Returns the pad's slot chain (the pad instance).
func _pad(ch: Object, drum: Object, n: String, note: int) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
	inst.slot_note = note
	var cmd: Object = _add_cmd.new(ch, inst, -1, drum)
	cmd.do()
	return cmd.device_instance


## The 16-byte mask with bits `notes` set.
func _mask(notes: Array) -> PackedByteArray:
	var m := PackedByteArray()
	m.resize(16)
	for n in notes:
		m[n >> 3] |= 1 << (n & 7)
	return m


## Masks queued for `slot/{slot}/choke_targets`, oldest first.
func _sent_masks(slot: int) -> Array:
	var suffix := "/slot/%d/choke_targets" % slot
	return _osc._pending_sends \
		.filter(func(item) -> bool: return str(item.address).ends_with(suffix)) \
		.map(func(item): return item.args[0])


## The saved JSON of the first root device on channel `channel_id`.
func _find_device_json(data: Dictionary, channel_id: int) -> Dictionary:
	for ch_data in data.channels:
		if int(ch_data.id) == channel_id:
			return ch_data.devices[0]
	return {}


# --- tests -----------------------------------------------------------------

func _test_set_and_send_mask() -> void:
	var s := _drum_setup()
	var seen := [0]
	s.pad0.choke_targets_changed.connect(func() -> void: seen[0] += 1)
	_osc._pending_sends.clear()
	s.pad0.set_choke_targets(PackedStringArray([s.pad1.id, s.pad0.id, s.pad1.id]))
	_assert(Array(s.pad0.choke_targets) == [s.pad1.id], "own id and duplicates are dropped (%s)" % s.pad0.choke_targets)
	_assert(seen[0] == 1, "the setter emits choke_targets_changed once (%d)" % seen[0])
	var sent := _sent_masks(0)
	_assert(sent.size() == 1 and sent[0] == _mask([38]), "slot/0/choke_targets carries note 38's bit: %s" % [sent])
	_assert(s.drum.choke_mask_for(s.pad0)[4] == 0x40, "note 38 is byte 4, bit 6")
	s.pad0.set_choke_targets(PackedStringArray([s.pad1.id]))
	_assert(seen[0] == 1, "an unchanged set emits nothing")
	_osc._pending_sends.clear()


func _test_toggle_is_one_undo_step() -> void:
	var s := _drum_setup()
	var recorded: Array = []
	_history_util.test_recorder = func(cmd) -> void: recorded.append(cmd)
	s.pad0.toggle_choke_target(s.pad2.id, true)
	s.pad0.toggle_choke_target(s.pad2.id, true)
	_assert(Array(s.pad0.choke_targets) == [s.pad2.id], "toggle on adds the target")
	_assert(recorded.size() == 1, "one command per real change (%d)" % recorded.size())
	s.pad0.toggle_choke_target(s.pad1.id, true)
	s.pad0.toggle_choke_target(s.pad2.id, false)
	_assert(Array(s.pad0.choke_targets) == [s.pad1.id], "toggle off removes only that target")
	recorded[2].undo()
	_assert(Array(s.pad0.choke_targets) == [s.pad2.id, s.pad1.id], "undo restores the target")
	recorded[1].undo()
	recorded[0].undo()
	_assert(s.pad0.choke_targets.is_empty(), "undoing every step leaves no targets")
	_history_util.test_recorder = Callable()
	_osc._pending_sends.clear()


func _test_choked_by_is_derived() -> void:
	var s := _drum_setup()
	s.pad0.set_choke_targets(PackedStringArray([s.pad2.id]))
	s.pad1.set_choke_targets(PackedStringArray([s.pad2.id, s.pad0.id]))
	_assert(s.drum.choked_by(s.pad2) == [s.pad0, s.pad1], "the hat is choked by kick and snare")
	_assert(s.drum.choked_by(s.pad0) == [s.pad1], "the kick is choked by the snare only")
	_assert(s.drum.choked_by(s.pad1).is_empty(), "nothing chokes the snare (directed)")
	_assert(s.drum.choke_target_pads(s.pad1) == [s.pad0, s.pad2], "targets list in pad order")
	_osc._pending_sends.clear()


func _test_note_change_resends_masks() -> void:
	var s := _drum_setup()
	s.pad0.set_choke_targets(PackedStringArray([s.pad1.id]))
	_osc._pending_sends.clear()
	s.pad1.set_slot_note(50)
	var sent := _sent_masks(0)
	_assert(not sent.is_empty() and sent[-1] == _mask([50]), "moving the target re-sends the kick's mask with note 50: %s" % [sent])
	_assert(not _sent_masks(2).is_empty(), "every pad's mask is re-sent")
	_osc._pending_sends.clear()


func _test_removed_pad_leaves_masks_and_undo_restores() -> void:
	var s := _drum_setup()
	s.pad0.set_choke_targets(PackedStringArray([s.pad2.id]))
	_osc._pending_sends.clear()
	s.channel.remove_device(2, s.drum)
	var sent := _sent_masks(0)
	_assert(not sent.is_empty() and sent[-1] == _mask([]), "removing the hat clears it from the kick's mask: %s" % [sent])
	_assert(s.drum.choke_target_pads(s.pad0).is_empty(), "the removed pad is no longer a target")
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.project.to_json()))
	var drum_json := _find_device_json(data, s.channel.id)
	_assert((drum_json.children[0].choke_targets as Array).is_empty(), "a removed pad's id is not saved")
	_osc._pending_sends.clear()
	s.channel.add_device(s.pad2, 2, s.drum)  # what DeviceRemoveCommand.undo does
	sent = _sent_masks(0)
	_assert(not sent.is_empty() and sent[-1] == _mask([42]), "re-adding the hat restores the kick's mask: %s" % [sent])
	_osc._pending_sends.clear()


func _test_sync_slot_resends() -> void:
	var s := _drum_setup()
	s.pad1.set_choke_targets(PackedStringArray([s.pad0.id, s.pad2.id]))
	_osc._pending_sends.clear()
	s.pad1.sync_slot_to_engine()
	var sent := _sent_masks(1)
	_assert(sent.size() == 1 and sent[0] == _mask([36, 42]), "sync_slot_to_engine re-sends the mask: %s" % [sent])
	_osc._pending_sends.clear()


func _test_project_round_trip() -> void:
	var s := _drum_setup()
	s.pad0.set_choke_targets(PackedStringArray([s.pad1.id]))
	s.pad1.set_choke_targets(PackedStringArray([s.pad0.id, s.pad2.id]))
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.project.to_json()))
	var drum_json := _find_device_json(data, s.channel.id)
	_assert(Array(drum_json.children[0].choke_targets) == [s.pad1.id], "targets are saved by id under choke_targets")
	_assert(not drum_json.children[0].has("choke_group"), "choke_group is no longer saved")
	var loaded: Object = _project_script.from_json(data)
	var drum: Object = loaded.get_channel_by_id(s.channel.id).devices[0]
	var c: Array = drum.children
	_assert(drum.choke_target_pads(c[0]) == [c[1]] and drum.choke_target_pads(c[1]) == [c[0], c[2]],
		"save then load preserves the targets")
	_assert(drum.choke_target_pads(c[2]).is_empty(), "a pad without targets loads with none")
	_osc._pending_sends.clear()


func _test_legacy_groups_migrate() -> void:
	var s := _drum_setup()
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.project.to_json()))
	var drum_json := _find_device_json(data, s.channel.id)
	var groups := [1, 0, 1]
	for i in range(3):
		drum_json.children[i].erase("choke_targets")
		drum_json.children[i]["choke_group"] = groups[i]
	var loaded: Object = _project_script.from_json(data)
	var drum: Object = loaded.get_channel_by_id(s.channel.id).devices[0]
	var c: Array = drum.children
	_assert(drum.choke_target_pads(c[0]) == [c[2]] and drum.choke_target_pads(c[2]) == [c[0]],
		"two pads in group 1 load as mutual targets")
	_assert(drum.choke_target_pads(c[1]).is_empty() and drum.choked_by(c[1]).is_empty(),
		"a pad in no group has no targets")
	var resaved: Dictionary = loaded.to_json()
	var resaved_drum := _find_device_json(resaved, s.channel.id)
	_assert(not resaved_drum.children[0].has("choke_group"), "the legacy field is dropped on save")
	_osc._pending_sends.clear()
