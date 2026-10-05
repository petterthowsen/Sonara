# test_drum_pad_move.gd
# Headless tests for moving Drum Machine pads (spec 020 phase 0): a pad moved onto an empty note,
# or swapped with another pad, keeps its slot color and open state, because slot keys are
# note-based and the container re-keys them when a pad's note changes.
# Run: godot --headless --path Godot -s tests/test_drum_pad_move.gd -- --test
extends TestBase

const DRUM_ID := "sonara.builtin.drum_machine"
const CHAIN_ID := "sonara.builtin.chain"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _add_cmd: GDScript
var _drop_util: GDScript


func suite_name() -> String:
	return "Drum pad move"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true)
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_test_move_to_empty_note()
	_test_swap()


func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _pad(ch: Object, drum: Object, n: String, note: int) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
	inst.slot_note = note
	var cmd: Object = _add_cmd.new(ch, inst, -1, drum)
	cmd.do()
	return cmd.device_instance


func _setup() -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var drum: Object = _device_instance_script.new(_device(DRUM_ID, _device_script.DeviceCategory.Instrument, true), ch.id, -1)
	ch.add_device(drum)
	return {"ch": ch, "drum": drum, "a": _pad(ch, drum, "a", 36), "b": _pad(ch, drum, "b", 38)}


func _test_move_to_empty_note() -> void:
	var s := _setup()
	var drum: Object = s.drum
	var key: String = _device_instance_script.pad_slot_key(36)
	drum.set_slot_color(key, Color.RED)
	drum.set_slot_open(key, true)
	_assert(drum.is_slot_open(key), "setup: pad 36 slot is open")
	_drop_util.drop_on_drum_pad(s.ch, drum, 50, s.a)
	var new_key: String = _device_instance_script.pad_slot_key(50)
	_assert(s.a.slot_note == 50, "pad moved to note 50 (got %d)" % s.a.slot_note)
	_assert(drum.is_slot_open(new_key), "the open slot follows the pad")
	_assert(not drum.open_slot_keys().has(key), "the old slot key is no longer open")
	_assert(drum.slot_color(new_key) == Color.RED, "the slot color follows the pad")


func _test_swap() -> void:
	var s := _setup()
	var drum: Object = s.drum
	var ka: String = _device_instance_script.pad_slot_key(36)
	var kb: String = _device_instance_script.pad_slot_key(38)
	drum.set_slot_color(ka, Color.RED)
	drum.set_slot_color(kb, Color.BLUE)
	drum.set_slot_open(ka, true)
	_drop_util.drop_on_drum_pad(s.ch, drum, 38, s.a)
	_assert(s.a.slot_note == 38 and s.b.slot_note == 36, "pads swapped notes")
	_assert(drum.slot_color(kb) == Color.RED, "pad A's color moved to its new note")
	_assert(drum.slot_color(ka) == Color.BLUE, "pad B's color moved to its new note")
	_assert(drum.is_slot_open(kb), "the open slot follows pad A")
