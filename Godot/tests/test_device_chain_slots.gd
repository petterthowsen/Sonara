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
var _asset_script: GDScript
var _drop_util: GDScript
var _add_cmd: GDScript
var _nodes: Array[Node] = []
var _project: Object


func suite_name() -> String:
	return "Device chain slots"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_slots = load("res://data/DeviceSlots.gd")
	_asset_script = load("res://browser/Asset.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_device("sonara.builtin.transpose", _device_script.DeviceCategory.NoteEffect)
	_device("sonara.builtin.saturator", _device_script.DeviceCategory.Effect)
	var clap: Object = _device("test.clap.fx", _device_script.DeviceCategory.Effect)
	clap.device_type = _device_script.DeviceType.CLAP
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
	_test_sync_skips_slot_chains()
	_test_note_slot_takes_note_effects_only()
	_test_audio_slot_rejects_instruments_and_note_fx()
	_test_loop_slot_rejects_plugins()
	_test_slot_chain_cannot_move_or_be_removed()
	_test_drop_on_slotted_panel_is_not_a_container_drop()
	await _test_open_slot_shows_slot_group()
	_test_add_reveals_slot()
	_test_automation_lists_slot_devices()


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


## Addresses of the `add_device` / `remove_device` / `move_device` messages queued so far.
func _structure_sends(osc: Object) -> Array:
	var out: Array = []
	for item in osc._pending_sends:
		var address := String(item.address)
		if address.ends_with("/add_device") or address.ends_with("/remove_device") or address.ends_with("/move_device"):
			out.append(address)
	return out


func _test_sync_skips_slot_chains() -> void:
	var osc: Object = root.get_node("AudioEngineOSC")
	var ch: Object = _fresh_project()
	ch._is_connected = true  # headless sends queue in _pending_sends
	osc._pending_sends.clear()
	var poly := _inst(POLY_ID, ch)
	ch.add_device(poly)
	var base := "/channel/%d/device/0" % ch.id
	var sends := _structure_sends(osc)
	_assert(sends == ["/channel/%d/add_device" % ch.id], "adding a PolySynth sends one add_device, none for its slots: %s" % str(sends))
	osc._pending_sends.clear()
	var delay := _inst(DELAY_ID, ch)
	ch.add_device(delay, -1, poly.children[1])
	sends = _structure_sends(osc)
	_assert(sends == [base + "/child/1/add_device"], "a Delay added to FX goes to the slot's path: %s" % str(sends))
	_assert(delay.osc_path() == base + "/child/1/child/0", "the device inside FX is addressed through the slot chain")
	# Full re-sync (reconnect or project load) sends the slot contents but not the chains.
	osc._pending_sends.clear()
	ch._sync_device_tree_to_engine(poly)
	sends = _structure_sends(osc)
	_assert(sends == [base + "/child/1/add_device"], "a full sync sends no add_device for the chains: %s" % str(sends))
	# Slots are fixed: Channel refuses to remove or move them and to add straight into the device.
	osc._pending_sends.clear()
	ch.remove_device(0, poly)
	ch.move_device(0, 1, poly)
	ch.add_device(_inst(DELAY_ID, ch), -1, poly)
	_assert(_structure_sends(osc).is_empty() and poly.children.size() == 2 and _names(poly.children) == ["Note FX", "FX"],
		"removing, moving or adding straight into a slotted device does nothing")
	ch.remove_device(0, poly.children[1])
	_assert(_structure_sends(osc) == [base + "/child/1/remove_device"] and poly.children[1].children.is_empty(), "a device in a slot can be removed")
	ch._is_connected = false
	osc._pending_sends.clear()


func _asset(device_id: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = _asset_script.TYPE.Device
	asset.path = device_id
	return asset


## A slotted device `device_id` on `ch`.
func _slotted_on(ch: Object, device_id: String) -> Object:
	var inst := _inst(device_id, ch)
	ch.add_device(inst)
	return inst


## True when `device_id` may go into `host`: as a browser asset and as a dragged instance.
func _fits(ch: Object, host: Object, device_id: String) -> bool:
	var as_asset: bool = _drop_util.can_drop_on_container(ch, host, _asset(device_id))
	var as_instance: bool = _drop_util.can_drop_instance_on_host(ch, _inst(device_id, ch), host)
	_assert(as_asset == as_instance, "%s: asset and instance agree on %s (%s / %s)" % [host.name, device_id, as_asset, as_instance])
	return as_asset and as_instance


func _test_note_slot_takes_note_effects_only() -> void:
	var ch: Object = _fresh_project()
	var poly := _slotted_on(ch, POLY_ID)
	var note_fx: Object = poly.children[0]
	_assert(_fits(ch, note_fx, "sonara.builtin.transpose"), "a Transpose is accepted on the Note FX slot")
	_assert(not _fits(ch, note_fx, DELAY_ID), "a Delay is refused on the Note FX slot")
	_assert(not _fits(ch, note_fx, POLY_ID), "an instrument is refused on the Note FX slot")
	var cmd = _add_cmd.new(ch, _inst(DELAY_ID, ch), -1, note_fx)
	_assert(cmd.device_instance == null, "DeviceAddCommand adds nothing a note slot refuses")
	cmd.do()
	_assert(note_fx.children.is_empty(), "so the slot stays empty")
	var transpose := _inst("sonara.builtin.transpose", ch)
	_add_cmd.new(ch, transpose, -1, note_fx).do()
	_assert(note_fx.children == [transpose], "an accepted Transpose lands in the slot")


func _test_audio_slot_rejects_instruments_and_note_fx() -> void:
	var ch: Object = _fresh_project()
	var poly := _slotted_on(ch, POLY_ID)
	var fx: Object = poly.children[1]
	_assert(not _fits(ch, fx, POLY_ID), "a PolySynth is refused on the FX slot")
	_assert(not _fits(ch, fx, "sonara.builtin.transpose"), "a Transpose is refused on the FX slot")
	_assert(_fits(ch, fx, DELAY_ID), "a Delay is accepted on the FX slot")
	var chain := _inst(CHAIN_ID, ch)
	ch.add_device(chain, -1, fx)
	_assert(_fits(ch, fx, CHAIN_ID), "a Chain of effects is accepted on the FX slot")
	var holder := _inst(CHAIN_ID, ch)
	var inner := _inst("sonara.builtin.transpose", ch)
	holder.children.append(inner)
	inner.set_parent_device(holder)
	_assert(not _drop_util.can_drop_instance_on_host(ch, holder, fx), "a Chain holding a Transpose is refused on the FX slot")
	_assert(not _drop_util.can_drop_instance_on_host(ch, holder, chain), "and inside a Chain in the FX slot, whose kind still governs")
	_assert(_drop_util.can_drop_instance_on_host(ch, _inst(DELAY_ID, ch), chain), "a Delay goes inside that Chain")
	_assert(not _drop_util.copy_fits_host(holder, fx) and _drop_util.copy_fits_host(_inst(DELAY_ID, ch), fx), "copies follow the same kinds")
	_assert(_slots.kind_for_host(chain) == "audio", "a Chain in FX is still under the audio slot")


func _test_loop_slot_rejects_plugins() -> void:
	var ch: Object = _fresh_project()
	var delay := _slotted_on(ch, DELAY_ID)
	var reverb := _slotted_on(ch, REVERB_ID)
	_assert(not _fits(ch, delay.children[0], "test.clap.fx"), "a CLAP effect is refused on the Delay's FB FX slot")
	_assert(_fits(ch, delay.children[0], "sonara.builtin.saturator"), "a built-in effect is accepted on FB FX")
	_assert(not _fits(ch, reverb.children[0], "test.clap.fx"), "a CLAP effect is refused on Tank FX")
	_assert(_fits(ch, reverb.children[1], "test.clap.fx"), "a CLAP effect is accepted on the Reverb's Wet FX slot")
	_assert(not _fits(ch, delay.children[0], POLY_ID), "an instrument is refused on a loop slot")
	var holder := _inst(CHAIN_ID, ch)
	var plugin := _inst("test.clap.fx", ch)
	holder.children.append(plugin)
	plugin.set_parent_device(holder)
	_assert(not _drop_util.can_drop_instance_on_host(ch, holder, delay.children[0]), "a Chain holding a plugin is refused on a loop slot")


func _test_slot_chain_cannot_move_or_be_removed() -> void:
	var ch: Object = _fresh_project()
	var poly := _slotted_on(ch, POLY_ID)
	var fx: Object = poly.children[1]
	_assert(not _drop_util.can_drop_instance_on_host(ch, fx, null), "a slot chain can't be dragged to the channel root")
	_assert(not _drop_util.can_drop_instance_on_host(ch, fx, poly.children[0]), "nor into another slot")
	_assert(not _drop_util.can_drop_instance_on_host(ch, fx, poly.children[1]), "nor onto itself")
	_assert(not _drop_util.can_drop_instance_on_host(ch, poly.children[0], null, true), "nor copied out")
	var removal: Object = load("res://history/commands/DeviceRemoveCommand.gd").new(ch, fx)
	removal.do()
	_assert(poly.children.size() == 2 and poly.children[1] == fx, "removing a slot chain does nothing")
	ch.move_device(0, 1, poly)
	_assert(poly.children[0].name == "Note FX", "moving a slot chain does nothing")
	_assert(_slots.clear_command(fx) == null, "an empty slot has nothing to clear")
	var delay := _inst(DELAY_ID, ch)
	_add_cmd.new(ch, delay, -1, fx).do()
	var clear: Object = _slots.clear_command(fx)
	_assert(clear != null, "a slot with a device can be cleared")
	clear.do()
	_assert(fx.children.is_empty() and poly.children.size() == 2, "Clear Slot empties the slot and keeps the chain")
	clear.undo()
	_assert(fx.children == [delay], "undo brings the device back")


func _test_drop_on_slotted_panel_is_not_a_container_drop() -> void:
	var ch: Object = _fresh_project()
	var poly := _slotted_on(ch, POLY_ID)
	var reverb := _slotted_on(ch, REVERB_ID)
	_assert(not _drop_util.can_drop_on_container(ch, poly, _asset(DELAY_ID)), "a slotted device is no container for asset drops")
	_assert(not _drop_util.can_drop_on_device(poly, _asset(DELAY_ID)), "dropping a Delay on the PolySynth panel is not a drop")
	_assert(not _drop_util.can_drop_instance_on_host(ch, _inst(DELAY_ID, ch), poly), "nor is an instance drop onto it")
	# DeviceAddCommand (used by tools and paste) still finds a slot: the open one first.
	var transpose := _inst("sonara.builtin.transpose", ch)
	_add_cmd.new(ch, transpose, -1, poly).do()
	_assert(poly.children[0].children == [transpose], "a Transpose added to the device goes to Note FX")
	var delay := _inst(DELAY_ID, ch)
	var cmd = _add_cmd.new(ch, delay, -1, poly)
	cmd.do()
	_assert(poly.children[1].children == [delay] and cmd.device_instance == delay, "a Delay added to the device goes to FX")
	var saturator := _inst("sonara.builtin.saturator", ch)
	reverb.set_slot_open("wet_fx", true)
	_add_cmd.new(ch, saturator, -1, reverb).do()
	_assert(reverb.children[1].children == [saturator] and reverb.children[0].children.is_empty(), "the open slot wins when it accepts")
	_assert(_add_cmd.new(ch, _inst(POLY_ID, ch), -1, reverb).device_instance == null, "a device no slot takes is not added")
	cmd.undo()
	_assert(poly.children[1].children.is_empty(), "undo removes it again")
	var before_root: int = ch.devices.size()
	_add_cmd.new(ch, _inst(POLY_ID, ch), -1, poly).do()
	_assert(ch.devices.size() == before_root, "a refused add doesn't fall back to the channel root")


## Device lane bound to `ch` (headless there is no editor to bind it on channel focus).
func _lane(ch: Object) -> Control:
	var lane: Control = (load("res://devices/device_lane/DeviceLane.tscn") as PackedScene).instantiate()
	lane.size = Vector2(1600, 400)
	root.add_child(lane)
	_nodes.append(lane)
	lane.bind_to_channel(ch)
	await _settle()
	return lane


func _settle() -> void:
	await process_frame
	await process_frame


func _test_open_slot_shows_slot_group() -> void:
	var ch: Object = _fresh_project()
	var poly := _slotted_on(ch, POLY_ID)
	var delay := _inst(DELAY_ID, ch)
	_add_cmd.new(ch, delay, -1, poly.children[1]).do()
	poly.set_slot_open("fx", false)  # adding revealed it; start from a closed slot
	var lane := await _lane(ch)
	var poly_panel: Control = lane.find_device_panel(poly)
	_assert(poly_panel != null and lane.find_device_panel(delay) == null, "a closed device slot shows nothing")
	poly.set_slot_open("fx", true)
	await _settle()
	var item: Object = poly_panel.get_parent() if poly_panel else null
	var groups: Array = []
	for node in lane.find_children("*", "DeviceSlotGroup", true, false):
		groups.append(node)
	_assert(groups.size() == 1 and groups[0].key == "fx" and groups[0].container == poly, "opening FX adds one slot group for it")
	var delay_panel: Control = lane.find_device_panel(delay)
	_assert(delay_panel != null and delay_panel.get_global_rect().position.x > poly_panel.get_global_rect().end.x,
		"the device in FX sits right of the PolySynth")
	_assert(groups[0].slot_color() == _slots.role_color("audio"), "the FX bracket uses the audio role colour")
	poly.set_slot_open("note_fx", true)
	await _settle()
	groups = lane.find_children("*", "DeviceSlotGroup", true, false)
	_assert(groups.size() == 1 and groups[0].key == "note_fx" and lane.find_device_panel(delay) == null,
		"opening Note FX replaces the FX group, and it shows the empty drop zone")
	_assert(groups[0]._empty_hint.visible and groups[0].slot_color() == _slots.role_color("note"), "an empty note slot shows its drop zone in the note colour")
	poly.set_slot_open("note_fx", false)
	await _settle()
	_assert(lane.find_children("*", "DeviceSlotGroup", true, false).is_empty(), "closing the slot removes its group")


func _test_add_reveals_slot() -> void:
	var ch: Object = _fresh_project()
	var poly := _slotted_on(ch, POLY_ID)
	_assert(poly.open_slot_keys().is_empty(), "slots start closed")
	var transpose := _inst("sonara.builtin.transpose", ch)
	_add_cmd.new(ch, transpose, -1, poly.children[0]).do()
	_assert(Array(poly.open_slot_keys()) == ["note_fx"], "adding a Transpose into Note FX opens it")
	var delay := _inst(DELAY_ID, ch)
	_add_cmd.new(ch, delay, -1, poly.children[1]).do()
	_assert(Array(poly.open_slot_keys()) == ["fx"], "adding a Delay into FX opens FX and closes Note FX")
	# A device nested in a slot's Chain reveals the slot too.
	poly.set_slot_open("fx", false)
	var chain := _inst(CHAIN_ID, ch)
	_add_cmd.new(ch, chain, -1, poly.children[1]).do()
	poly.set_slot_open("fx", false)
	_add_cmd.new(ch, _inst(DELAY_ID, ch), -1, chain).do()
	_assert(poly.open_slot_keys().is_empty(), "adding into a nested Chain leaves the slot as it was")


func _texts_of_paths(picker: Object) -> Dictionary:
	var out := {}
	for submenu in picker._submenu_paths:
		var texts: Array = []
		for i in range(submenu.get_item_count()):
			texts.append(submenu.get_item_text(i))
		out[str(picker._submenu_paths[submenu])] = texts
	return out


func _test_automation_lists_slot_devices() -> void:
	var made: Dictionary = _project_script.new().create_instrument_track("Auto")
	var ch: Object = made.channel
	var delay_device: Object = _inst(DELAY_ID, ch).device
	if delay_device.parameters.is_empty():
		delay_device.add_parameter(load("res://data/DeviceParameter.gd").new(7, "Mix"))
	var poly := _slotted_on(ch, POLY_ID)
	poly.device.parameters.clear()
	poly.device.add_parameter(load("res://data/DeviceParameter.gd").new(1, "Cutoff"))
	var delay := _inst(DELAY_ID, ch)
	_add_cmd.new(ch, delay, -1, poly.children[1]).do()
	var picker: Object = load("res://arranger/tracklist/AutomationParameterPicker.gd").new()
	picker.track = made.track
	picker.channel = ch
	picker._rebuild()
	var by_path := _texts_of_paths(picker)
	_assert(by_path.has("[0]") and by_path.has("[0, 1, 0]"), "the picker has submenus for the PolySynth and the Delay in its FX slot: %s" % str(by_path.keys()))
	_assert(by_path.get("[0, 1, 0]", []).has("Mix"), "the slot device lists its parameters")
	_assert(not by_path.has("[0, 1]"), "an empty-parameter slot chain adds no entry")
	var target := AutomationTarget.device_param([0, 1, 0], 7)
	_assert(target != null, "an automation target can address a device in a slot")
	picker.free()
