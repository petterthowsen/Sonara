# test_split_devices.gd
# Headless tests for the Mid/Side Split and L/R Split devices (spec 043, Godot side): a new
# instance carries its two audio slot chains in spec order, and the audio slots take effects but
# refuse instruments.
# Run: godot --headless --path Godot -s tests/test_split_devices.gd -- --test
extends TestBase

const MS_ID := "sonara.builtin.ms_split"
const LR_ID := "sonara.builtin.lr_split"

var _device_script: GDScript
var _device_instance_script: GDScript
var _slots: GDScript


func suite_name() -> String:
	return "Split devices"


func run_tests() -> void:
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_slots = load("res://data/DeviceSlots.gd")
	var chain_dev: Object = _device_script.new("sonara.builtin.chain", "Chain", _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	chain_dev.is_container = true
	root.get_node("AssetService").device_registry._devices["sonara.builtin.chain"] = chain_dev
	_slotted(MS_ID, [["mid", "Mid", "audio"], ["side", "Side", "audio"]])
	_slotted(LR_ID, [["left", "Left", "audio"], ["right", "Right", "audio"]])
	var cases := {MS_ID: ["Mid", "Side"], LR_ID: ["Left", "Right"]}
	for id in cases:
		var inst: Object = _device_instance_script.new(_device(id), 2, -1)
		_assert(_slots.is_slotted(inst), "%s is a slotted device" % id)
		var names: Array = []
		for chain in inst.children:
			names.append(chain.name)
		_assert(names == cases[id], "%s has its slot chains in spec order: %s" % [id, str(names)])
		var keys: Array = []
		for spec in _slots.specs(inst):
			keys.append(spec["key"])
		_assert(keys.size() == 2 and _slots.kind_for_host(inst.children[0]) == "audio",
			"%s has two audio slots" % id)
	var instrument: Object = _device_script.new("test.synth", "Synth", _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
	var effect: Object = _device_script.new("test.fx", "Fx", _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	_assert(not _slots.accepts("audio", instrument), "an audio slot refuses an instrument")
	_assert(_slots.accepts("audio", effect), "an audio slot accepts an effect")


func _device(device_id: String) -> Object:
	return root.get_node("AssetService").device_registry._devices[device_id]


func _slotted(device_id: String, specs: Array) -> void:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = _device_script.new(device_id, device_id, _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn)
	device.is_container = true
	for spec in specs:
		device.slots.append({"key": spec[0], "name": spec[1], "kind": spec[2]})
	registry._devices[device_id] = device
