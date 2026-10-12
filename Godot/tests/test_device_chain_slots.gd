# test_device_chain_slots.gd
# Headless tests for device chain slots (spec 040, Godot side): a PolySynth, Delay and Reverb carry
# fixed slot chains from the engine's /builtin/info slot block, in spec order, empty from creation
# and for projects saved before the spec. Slot chains are fixed, open one at a time and use fixed
# role colours. The engine sync never creates them, slot kinds decide which devices a slot takes,
# and the lane and automation picker see devices inside slots.
# Run: godot --headless --path Godot -s tests/test_device_chain_slots.gd -- --test
#
# Classes that reference autoloads are loaded with load() instead of named.
extends TestBase

const CHAIN_ID := "sonara.builtin.chain"
const POLY_ID := "sonara.builtin.polysynth"
const DELAY_ID := "sonara.builtin.delay"
const REVERB_ID := "sonara.builtin.reverb"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _slots: GDScript
var _nodes: Array[Node] = []
var _project: Object


func suite_name() -> String:
	return "Device chain slots"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_slots = load("res://data/DeviceSlots.gd")
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_slotted(POLY_ID, _device_script.DeviceCategory.Instrument, [
		["note_fx", "Note FX", "note"], ["fx", "FX", "audio"]])
	_slotted(DELAY_ID, _device_script.DeviceCategory.Effect, [["fb_fx", "FB FX", "loop"]])
	_slotted(REVERB_ID, _device_script.DeviceCategory.Effect, [
		["tank_fx", "Tank FX", "loop"], ["wet_fx", "Wet FX", "audio"]])
	_test_info_block_is_parsed()
	_test_new_instances_have_slots()
	_test_pre_spec_json_gets_empty_slots()
	_test_slotted_round_trip()
	_test_one_slot_open()
	_test_slot_role_colors()
	_test_slot_accessors()


## Registered fake device `device_id`.
func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


## Registered fake slotted device; `specs` = [[key, name, kind], ...].
func _slotted(device_id: String, category: int, specs: Array) -> Object:
	var device: Object = _device(device_id, category, true)
	for spec in specs:
		device.slots.append({"key": spec[0], "name": spec[1], "kind": spec[2]})
	return device


func _inst(device_id: String, ch: Object = null) -> Object:
	return _device_instance_script.new(root.get_node("AssetService").device_registry._devices[device_id], ch.id if ch else 2, -1)


func _fresh_project() -> Object:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_project = _project_script.new()
	return _project.create_instrument_track("Inst").channel


func _names(list: Array) -> Array:
	var out: Array = []
	for d in list:
		out.append(d.name)
	return out


## Feed the registry a /builtin/info message the way the engine encodes it (no parameters).
func _test_info_block_is_parsed() -> void:
	var registry: Object = root.get_node("AssetService").device_registry
	var args: Array = ["test.slotted", "Slotted", "Instrument", "d", 1, 2, 2, 0, "", 0,  # id..extensions
		0,  # param_count
		1,  # is_container
		1, "lfo", "LFO", 0, 0,  # one default modulator: kind, name, 0 params, 0 routes
		2, "note_fx", "Note FX", "note", "fx", "FX", "audio"]
	registry._on_builtin_info_received(args)
	var device: Object = registry._devices.get("test.slotted")
	_assert(device != null and device.has_device_slots(), "a /builtin/info with a slot block gives the device slots")
	_assert(device.slots == [{"key": "note_fx", "name": "Note FX", "kind": "note"}, {"key": "fx", "name": "FX", "kind": "audio"}],
		"slots parse in order with key, name and kind: %s" % str(device.slots))
	_assert(device.default_modulators.size() == 1, "the default modulators before the slot block still parse")
	args = ["test.plain", "Plain", "Effect", "d", 0, 2, 2, 0, "", 0, 0, 0, 0]
	registry._on_builtin_info_received(args)
	_assert(not registry._devices["test.plain"].has_device_slots(), "a device whose block lists no slots has none")
	args = ["test.old", "Old", "Effect", "d", 0, 2, 2, 0, "", 0, 0, 0]
	registry._on_builtin_info_received(args)
	_assert(not registry._devices["test.old"].has_device_slots(), "an older engine without the blocks gives no slots")


func _test_new_instances_have_slots() -> void:
	var cases := {POLY_ID: ["Note FX", "FX"], DELAY_ID: ["FB FX"], REVERB_ID: ["Tank FX", "Wet FX"]}
	for id in cases:
		var inst := _inst(id)
		_assert(_slots.is_slotted(inst), "%s is a slotted device" % id)
		_assert(_names(inst.children) == cases[id], "%s has its slot chains in spec order: %s" % [id, str(_names(inst.children))])
		var all_empty := true
		for chain in inst.children:
			all_empty = all_empty and chain.children.is_empty() and chain.device.device_id == CHAIN_ID \
				and chain.get_parent_device() == inst and _slots.is_slot_chain(chain)
		_assert(all_empty, "%s slots are empty chains parented to the device" % id)
	var poly := _inst(POLY_ID)
	var knob: Object = load("res://data/DeviceParameter.gd").new(1, "Cutoff")
	poly.device.add_parameter(knob)
	_assert(_slots.spec_of(poly.children[1]).get("key") == "fx", "spec_of names the chain's slot")
	_assert(not _slots.is_slot_chain(poly), "the slotted device itself is not a slot chain")
	_assert(not _slots.is_slotted(_inst(CHAIN_ID)), "a Chain is not slotted")
	_assert(_inst(CHAIN_ID).children.is_empty(), "a plain Chain starts with no children")
	_assert(poly.device.uses_simple_view(), "a slotted device is not excluded from the Simple View as a container")
	_assert(not _device_script.new("x", "x", _device_script.DeviceCategory.Effect, _device_script.DeviceType.BuiltIn).has_device_slots(), "a fresh device has no slots")
	_assert(not _inst(DELAY_ID).device.creates_instrument_track(), "a slotted effect does not create an instrument track")
	_assert(_inst(POLY_ID).device.creates_instrument_track(), "a PolySynth still creates an instrument track")


func _test_pre_spec_json_gets_empty_slots() -> void:
	var poly := _inst(POLY_ID)
	var data: Dictionary = JSON.parse_string(JSON.stringify(poly.to_json()))
	data.erase("children")
	data["parameter_values"] = {"1": 0.25}
	var loaded: Object = _device_instance_script.from_json(data)
	_assert(loaded != null and loaded.children.size() == 2, "a pre-spec PolySynth gets two slot chains")
	_assert(_names(loaded.children) == ["Note FX", "FX"] and loaded.children[0].children.is_empty() and loaded.children[1].children.is_empty(),
		"the missing slots are named and empty")
	_assert(loaded.children[0].get_parent_device() == loaded, "the new slot chains are parented")
	data["children"] = []
	_assert(_device_instance_script.from_json(data).children.size() == 2, "an empty children list also gets its slots")


func _test_slotted_round_trip() -> void:
	var poly := _inst(POLY_ID)
	var fx := _inst(DELAY_ID)
	fx.children[0].name = "FB FX"
	poly.children[1].children.append(fx)
	fx.set_parent_device(poly.children[1])
	var data: Dictionary = JSON.parse_string(JSON.stringify(poly.to_json()))
	var loaded: Object = _device_instance_script.from_json(data)
	_assert(_names(loaded.children) == ["Note FX", "FX"], "a saved slotted device loads exactly its two slots, not four")
	_assert(loaded.children[1].children.size() == 1 and loaded.children[1].children[0].device.device_id == DELAY_ID, "the device in FX is saved")
	_assert(loaded.children[0].children.is_empty(), "Note FX stays empty")
	_assert(loaded.children[1].children[0].children.size() == 1, "the nested Delay keeps its own slot")
	# Adoption by position when a saved chain carries another name.
	data["children"][0]["name"] = "Renamed"
	var adopted: Object = _device_instance_script.from_json(data)
	_assert(_names(adopted.children) == ["Note FX", "FX"] and adopted.children[1].children.size() == 1, "chains are adopted by name, then position, and renamed")


func _test_one_slot_open() -> void:
	var poly := _inst(POLY_ID)
	var emitted := [0]
	poly.slots_changed.connect(func() -> void: emitted[0] += 1)
	_assert(poly.open_slot_keys().is_empty(), "slots start closed")
	poly.set_slot_open("note_fx", true)
	_assert(Array(poly.open_slot_keys()) == ["note_fx"] and emitted[0] == 1, "opening Note FX opens it and signals")
	poly.set_slot_open("fx", true)
	_assert(Array(poly.open_slot_keys()) == ["fx"] and not poly.is_slot_open("note_fx"), "opening FX closes Note FX")
	poly.toggle_slot("fx")
	_assert(poly.open_slot_keys().is_empty(), "toggling the open slot closes it")
	poly.set_slot_open("bogus", true)
	_assert(poly.open_slot_keys().is_empty(), "an unknown slot key does not open")
	poly.reveal_child(poly.children[1])
	_assert(Array(poly.open_slot_keys()) == ["fx"], "revealing a slot chain opens it")
	var data: Dictionary = JSON.parse_string(JSON.stringify(poly.to_json()))
	var loaded: Object = _device_instance_script.from_json(data)
	_assert(Array(loaded.open_slot_keys()) == ["fx"], "the open slot is saved and loaded")


func _test_slot_role_colors() -> void:
	var poly := _inst(POLY_ID)
	var secondary: Color = UiColors.role(&"accent_secondary")
	var primary: Color = UiColors.role(&"accent_primary")
	_assert(poly.slot_color("note_fx") == secondary, "the Note FX slot uses the secondary accent")
	_assert(poly.slot_color("fx") == primary, "the FX slot uses the primary accent")
	_assert(_inst(DELAY_ID).slot_color("fb_fx") == primary, "a loop slot uses the primary accent")
	poly.set_slot_color("fx", Color.RED)
	_assert(poly.slot_color("fx") == primary, "device slot colours cannot be changed")
	_assert(_slots.role_color("note") == secondary and _slots.role_color("audio") == primary and _slots.role_color("loop") == primary,
		"role_color maps kinds to accents")
	_assert(not poly._slots_to_json()["colors"].has("fx"), "device slot colours are not saved")


func _test_slot_accessors() -> void:
	var poly := _inst(POLY_ID)
	var reverb := _inst(REVERB_ID)
	_assert(Array(poly.slot_keys()) == ["note_fx", "fx"] and Array(reverb.slot_keys()) == ["tank_fx", "wet_fx"], "slot_keys follow the specs")
	_assert(poly.has_slot("fx") and not poly.has_slot("tank_fx"), "has_slot knows its own keys only")
	_assert(poly.slot_chain("fx") == poly.children[1] and poly.slot_chain("zzz") == null, "slot_chain returns the mirrored chain")
	_assert(poly.slot_title("note_fx") == "Note FX" and reverb.slot_title("wet_fx") == "Wet FX", "slot_title is the spec name")
	_assert(poly.slot_kind("note_fx") == "note" and poly.slot_kind("fx") == "audio", "slot_kind reads the spec")
	var delay := _inst(DELAY_ID)
	poly.children[1].children.append(delay)
	delay.set_parent_device(poly.children[1])
	_assert(poly.slot_key_for(delay) == "fx", "slot_key_for finds the slot of a nested device")
	_assert(poly.slot_devices("fx") == [delay] and poly.slot_devices("note_fx").is_empty(), "slot_devices lists the chain's devices")
	_assert(_slots.kind_for_host(poly.children[1]) == "audio" and _slots.kind_for_host(delay.children[0]) == "loop" and _slots.kind_for_host(poly) == "",
		"kind_for_host is the innermost slot kind above the host (the Delay's own loop slot wins inside it)")
