# test_device_slots.gd
# Headless tests for container slots: a Chain has one slot, Layer and Drum Machine children are
# slot chains (one slot each, one open at a time); slot colors stay put and slots round-trip
# through the device JSON; projects from before slot chains are wrapped on load, automation paths
# included. In the device lane, an open slot shows its devices beside the container under a
# bracket whose panels line up with the root panels; drops land in the slot (in its color, into
# its chain), beside the container (after its open slots), or onto it (opening the new child's
# slot). An empty Drum Machine pad opens as an empty slot that takes drops onto its note.
# Run: godot --headless --path Godot -s tests/test_device_slots.gd -- --test
#
# The lane, project and drop classes reference autoloads, so they are loaded with load() instead of named.
extends TestBase

const LAYER_ID := "sonara.builtin.layer"
const DRUM_ID := "sonara.builtin.drum_machine"
const CHAIN_ID := "sonara.builtin.chain"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _asset_script: GDScript
var _drop_target: GDScript
var _device_drag: GDScript
var _add_cmd: GDScript
var _drop_util: GDScript
var _pad_lane: GDScript
var _nodes: Array[Node] = []
var _project: Object


func suite_name() -> String:
	return "Device container slots"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_asset_script = load("res://browser/Asset.gd")
	_drop_target = load("res://devices/DeviceDropTarget.gd")
	_device_drag = load("res://devices/DeviceDrag.gd")
	_add_cmd = load("res://history/commands/DeviceAddCommand.gd")
	_drop_util = load("res://devices/DeviceDropUtil.gd")
	_pad_lane = load("res://devices/PadLane.gd")
	# Slot chains are Chain instances, so the Chain device must be registered.
	_device(CHAIN_ID, _device_script.DeviceCategory.Effect, true)
	_test_chain_has_one_slot()
	_test_layer_opens_one_slot_at_a_time()
	_test_slots_round_trip_json()
	_test_move_device_into_layer_makes_slot()
	_test_legacy_children_wrapped_on_load()
	_test_pad_lane_keeps_pad_chain_first()
	await _test_open_slot_shows_beside_container()
	await _test_drops_into_and_beside_slots()
	await _test_drop_onto_container_opens_slot()
	await _test_layer_slot_is_a_chain()
	await _test_empty_drum_pad_slot()


## Registered fake device `device_id`.
func _device(device_id: String, category: int, container := false) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, device_id, category, _device_script.DeviceType.BuiltIn)
		device.is_container = container
		registry._devices[device_id] = device
	return device


func _fx(ch: Object, n: String, parent: Object = null) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
	ch.add_device(inst, -1, parent)
	return inst


func _container(ch: Object, device_id: String) -> Object:
	var category: int = _device_script.DeviceCategory.Instrument if device_id == DRUM_ID else _device_script.DeviceCategory.Effect
	var inst: Object = _device_instance_script.new(_device(device_id, category, true), ch.id, -1)
	ch.add_device(inst)
	return inst


## Add effect `n` into `parent` the way drops do (DeviceAddCommand), so a Layer or Drum Machine
## wraps it in a slot chain. Returns the effect.
func _add_fx(ch: Object, n: String, parent: Object, note: int = -1) -> Object:
	var inst: Object = _device_instance_script.new(_device("test.fx." + n, _device_script.DeviceCategory.Effect), ch.id, -1)
	inst.slot_note = note
	_add_cmd.new(ch, inst, -1, parent).do()
	return inst


func _asset(device_id: String) -> Object:
	var asset: Object = _asset_script.new()
	asset.type = _asset_script.TYPE.Device
	asset.path = device_id
	return asset


func _fresh_project() -> Object:
	for n in _nodes:
		if is_instance_valid(n):
			n.free()
	_nodes.clear()
	_project = _project_script.new()
	return _project.create_instrument_track("Inst").channel


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


func _names(list: Array) -> Array:
	var out: Array = []
	for d in list:
		out.append(d.device.device_id.get_extension())
	return out


func _test_chain_has_one_slot() -> void:
	var ch: Object = _fresh_project()
	var chain := _container(ch, "test.chain")
	var a := _fx(ch, "a", chain)
	var b := _fx(ch, "b", chain)
	_assert(Array(chain.slot_keys()) == [_device_instance_script.CHAIN_SLOT], "a chain has one slot: %s" % str(chain.slot_keys()))
	_assert(chain.slot_devices(_device_instance_script.CHAIN_SLOT) == [a, b], "the chain slot holds every child")
	_assert(chain.slot_key_for(b) == _device_instance_script.CHAIN_SLOT, "a child's slot is the chain slot")
	_assert(chain.slot_title(_device_instance_script.CHAIN_SLOT) == "Chain", "the chain slot is titled Chain")
	_assert(not chain.is_slot_open(_device_instance_script.CHAIN_SLOT), "slots start closed")
	var color: Color = chain.slot_color(_device_instance_script.CHAIN_SLOT)
	_assert(chain.slot_color(_device_instance_script.CHAIN_SLOT) == color, "a slot keeps its color")
	var emitted := [0]
	chain.slots_changed.connect(func() -> void: emitted[0] += 1)
	chain.toggle_slot(_device_instance_script.CHAIN_SLOT)
	_assert(chain.is_slot_open(_device_instance_script.CHAIN_SLOT) and emitted[0] == 1, "toggling opens the slot and signals once")
	chain.set_slot_open(_device_instance_script.CHAIN_SLOT, true)
	_assert(emitted[0] == 1, "opening an open slot changes nothing")
	_assert(_fx(ch, "loose").slot_keys().is_empty(), "a plain device has no slots")


func _test_layer_opens_one_slot_at_a_time() -> void:
	var ch: Object = _fresh_project()
	var layer := _container(ch, LAYER_ID)
	var a := _add_fx(ch, "a", layer)
	var b := _add_fx(ch, "b", layer)
	var chain_a: Object = layer.children[0]
	var chain_b: Object = layer.children[1]
	_assert(chain_a.device.device_id == CHAIN_ID and chain_a.children == [a], "a device added into a layer gets a slot chain")
	_assert(chain_a.name == "test.fx.a" and a.get_parent_device() == chain_a, "the slot chain is named after it and holds it")
	_assert(Array(layer.slot_keys()) == [chain_a.id, chain_b.id], "each slot chain is a slot")
	_assert(layer.slot_devices(chain_b.id) == [b], "a layer slot shows its chain's devices")
	_assert(layer.slot_key_for(b) == chain_b.id and layer.slot_chain(chain_b.id) == chain_b, "a device's slot is its chain's")
	layer.reveal_child(a)
	_assert(Array(layer.open_slot_keys()) == [chain_a.id], "revealing A opens its slot")
	layer.set_slot_open(chain_b.id, true)
	_assert(Array(layer.open_slot_keys()) == [chain_b.id], "opening B closes A")
	_assert(layer.slot_color(chain_a.id) != Color(), "layer slots get colors of their own")
	ch.remove_device_instance(chain_b)
	_assert(layer.open_slot_keys().is_empty(), "a removed slot is no longer open")


func _test_slots_round_trip_json() -> void:
	var ch: Object = _fresh_project()
	var layer := _container(ch, LAYER_ID)
	var a := _add_fx(ch, "a", layer)
	_add_fx(ch, "b", layer)
	var key: String = layer.slot_key_for(a)
	layer.set_slot_color(key, Color("#3a78b0"))
	layer.reveal_child(a)
	var data: Dictionary = JSON.parse_string(JSON.stringify(layer.to_json()))
	var copy: Object = _device_instance_script.from_json(data)
	_assert(copy != null and copy.children.size() == 2 and copy.children[0].children.size() == 1, "the layer loads with its slot chains")
	_assert(copy.migrated_slot_positions.is_empty(), "slot chains need no migration")
	_assert(Array(copy.open_slot_keys()) == [key], "the open slot is saved: %s" % str(copy.open_slot_keys()))
	_assert(copy.slot_color(key).to_html(false) == "3a78b0", "the slot color is saved")
	var old: Dictionary = data.duplicate(true)
	old.erase("slots")
	var legacy: Object = _device_instance_script.from_json(old)
	_assert(legacy != null and legacy.open_slot_keys().is_empty(), "a project without slots loads closed")


func _test_open_slot_shows_beside_container() -> void:
	var ch: Object = _fresh_project()
	var chain := _container(ch, "test.chain")
	var a := _fx(ch, "a", chain)
	var b := _fx(ch, "b", chain)
	var after := _fx(ch, "after")
	var lane := await _lane(ch)
	var chain_panel: Control = lane.find_device_panel(chain)
	_assert(chain_panel != null and lane.find_device_panel(a) == null, "a closed slot shows no children")

	chain.set_slot_open(_device_instance_script.CHAIN_SLOT, true)
	await _settle()
	var pa: Control = lane.find_device_panel(a)
	var pb: Control = lane.find_device_panel(b)
	var pafter: Control = lane.find_device_panel(after)
	_assert(pa != null and pb != null, "an open slot shows its children")
	if pa == null or pb == null:
		return
	var chain_rect := chain_panel.get_global_rect()
	_assert(pa.get_global_rect().position.x > chain_rect.end.x, "children sit right of the container")
	_assert(pb.get_global_rect().position.x > pa.get_global_rect().end.x, "children keep their order")
	_assert(pafter.get_global_rect().position.x > pb.get_global_rect().end.x, "the next root device follows the slot")
	_assert(absf(pa.get_global_rect().position.y - chain_rect.position.y) < 0.5, "slot panels line up with root panels: %s vs %s" % [pa.get_global_rect(), chain_rect])
	_assert(absf(pa.get_global_rect().end.y - chain_rect.end.y) < 0.5, "slot panels keep the full height")
	_assert(lane.devices.items().size() == 2, "the root row holds the chain and the device after it")

	chain.set_slot_open(_device_instance_script.CHAIN_SLOT, false)
	await _settle()
	_assert(lane.find_device_panel(a) == null, "closing the slot hides its children")
	_assert(lane.find_device_panel(chain) == chain_panel, "the container's panel is kept")


func _test_drops_into_and_beside_slots() -> void:
	var ch: Object = _fresh_project()
	var chain := _container(ch, "test.chain")
	var a := _fx(ch, "a", chain)
	var b := _fx(ch, "b", chain)
	var loose := _fx(ch, "loose")
	chain.set_slot_open(_device_instance_script.CHAIN_SLOT, true)
	var lane := await _lane(ch)
	var ra: Rect2 = lane.find_device_panel(a).get_global_rect()
	var rb: Rect2 = lane.find_device_panel(b).get_global_rect()
	var drag: Object = _device_drag.new(lane.find_device_panel(loose), loose, null)

	# Between A and B inside the slot.
	var gap := Vector2((ra.end.x + rb.position.x) * 0.5, ra.get_center().y)
	var into: Object = _drop_target.resolve(lane, drag, gap)
	_assert(into.kind == _drop_target.Kind.INSERT and into.host.parent == chain and into.position == 1, "the slot gap inserts into the chain: %d at %d" % [into.kind, into.position])
	_assert(into.color == chain.slot_color(_device_instance_script.CHAIN_SLOT), "the indicator takes the slot color")
	_assert(_names(chain.children) == ["a", "b"], "resolving moves nothing")

	# Right end of the container's panel: beside it, after its open slot.
	var chain_rect: Rect2 = lane.find_device_panel(chain).get_global_rect()
	var beside: Object = _drop_target.resolve(lane, drag, Vector2(chain_rect.end.x - 2, chain_rect.get_center().y))
	_assert(beside.kind == _drop_target.Kind.INSERT and beside.host.parent == null and beside.position == 1, "the container's edge inserts at the root: %d at %d" % [beside.kind, beside.position])
	_assert(beside.color == ch.color, "a root drop takes the channel color")
	_assert(beside.indicator_rect.position.x > rb.end.x, "the line sits after the open slot")

	_assert(into.commit(drag), "commit moves the device into the slot")
	_assert(_names(chain.children) == ["a", "loose", "b"], "loose sits between A and B: %s" % str(_names(chain.children)))
	await _settle()
	var pl: Control = lane.find_device_panel(loose)
	_assert(pl != null and pl.get_global_rect().position.x > ra.end.x, "the slot shows the moved device")
	_assert(lane.devices.items().size() == 1, "the root row lost the moved device")


func _test_drop_onto_container_opens_slot() -> void:
	var ch: Object = _fresh_project()
	var chain := _container(ch, "test.chain")
	var lane := await _lane(ch)
	var panel: Control = lane.find_device_panel(chain)
	var header: Rect2 = panel.header.get_global_rect()
	var fx: Object = _device("test.fx.new", _device_script.DeviceCategory.Effect)
	var target: Object = _drop_target.resolve(lane, _asset(fx.device_id), header.get_center())
	_assert(target.kind == _drop_target.Kind.ONTO and target.device == chain, "the header takes the drop")
	_assert(target.commit(_asset(fx.device_id)), "commit adds the device")
	_assert(chain.children.size() == 1 and chain.is_slot_open(_device_instance_script.CHAIN_SLOT), "dropping into a container opens its slot")
	await _settle()
	_assert(lane.find_device_panel(chain.children[0]) != null, "the new child shows in the lane")

	# An open slot with no devices is a drop target of its own.
	ch.remove_device_instance(chain.children[0])
	await _settle()
	var groups: Array = lane.devices.items()[0].slot_groups()
	_assert(groups.size() == 1, "the empty slot stays open")
	if groups.is_empty():
		return
	var empty: Object = _drop_target.resolve(lane, _asset(fx.device_id), groups[0].get_global_rect().get_center())
	_assert(empty.kind == _drop_target.Kind.INSERT and empty.host.parent == chain and empty.outline, "an empty slot outlines itself: %d" % empty.kind)


func _test_move_device_into_layer_makes_slot() -> void:
	var ch: Object = _fresh_project()
	var layer := _container(ch, LAYER_ID)
	_add_fx(ch, "a", layer)
	var loose := _fx(ch, "loose")
	var macro: Object = load("res://history/commands/MacroCommand.gd").new("Move", _drop_util._new_slot_commands(ch, loose, layer, -1))
	macro.do()
	_assert(layer.children.size() == 2 and layer.children[1].children == [loose], "the moved device gets a slot chain of its own")
	_assert(not ch.devices.has(loose) and layer.children[1].name == "test.fx.loose", "it left the root, and names its slot")
	macro.undo()
	_assert(layer.children.size() == 1 and ch.devices.has(loose), "undo puts it back and drops the slot")

	# A drop onto the layer goes the same way (as one history step).
	_drop_util.drop_on_container(ch, layer, _device_drag.new(null, loose, null))
	_assert(layer.children.size() == 2 and layer.children[1].children == [loose], "a drop onto the layer makes a slot")


func _test_legacy_children_wrapped_on_load() -> void:
	var ch: Object = _fresh_project()
	var track: Object = _project.tracks[0]
	var layer := _container(ch, LAYER_ID)
	var old := _fx(ch, "old", layer)  # added straight into the layer, as projects before slot chains did
	_assert(layer.children == [old], "a legacy layer holds its device directly")
	layer.set_slot_color(old.id, Color("#aa3300"))
	layer.reveal_child(old)
	track.add_automation_lane(load("res://data/AutomationLane.gd").new("lane", load("res://data/AutomationTarget.gd").parse("device/0/0/param/3")))
	var saved: Dictionary = JSON.parse_string(JSON.stringify(_project.to_json()))
	var loaded: Object = _project_script.from_json(saved)
	var lch: Object = loaded.get_channel_by_id(ch.id)
	var llayer: Object = lch.devices[0]
	var slot: Object = llayer.children[0]
	_assert(slot.device.device_id == CHAIN_ID and slot.children.size() == 1 and slot.children[0].id == old.id, "the device is wrapped in a slot chain, keeping its id")
	_assert(Array(llayer.open_slot_keys()) == [slot.id] and llayer.slot_color(slot.id).to_html(false) == "aa3300", "its slot keeps color and open state")
	var lane: Object = loaded.tracks[0].automation_lanes[0]
	_assert(str(lane.target) == "device/0/0/0/param/3", "automation follows it into the slot chain: %s" % str(lane.target))
	_assert(lch.migrated_slot_paths.is_empty(), "migration bookkeeping is cleared")


## The pad lane shows the pad chain's devices, not the Chain (spec 006 revision of 001 REQ-017).
func _test_pad_lane_keeps_pad_chain_first() -> void:
	var ch: Object = _fresh_project()
	var drum := _container(ch, DRUM_ID)
	_add_fx(ch, "kick", drum, 36)
	var pad: Object = drum.children[0]
	var kick: Object = pad.children[0]
	var ret: Object = _project.get_channel_by_id(pad.return_channel_id)
	_assert(ret != null and _pad_lane.is_pad_lane(ret), "the pad has a return lane")
	_assert(_pad_lane.devices(ret) == [kick], "the lane starts with the pad's devices, not its chain")
	var fx: Object = _device("test.fx.ret", _device_script.DeviceCategory.Effect)
	_assert(_pad_lane.can_drop(ret, _asset(fx.device_id), 0), "a drop among the pad's devices is allowed")
	_assert(_pad_lane.can_drop(ret, _asset(fx.device_id), 1), "devices go after them, on the return")
	_assert(not _pad_lane.changes(ret, kick, 1), "the pad's device doesn't move onto the return (index 1 is its own spot)")
	_pad_lane.drop(ret, _asset(fx.device_id), 1)
	_assert(not _pad_lane.can_drop(ret, kick, 2), "…nor past the return's devices")
	_assert(ret.devices.size() == 1 and pad.children.size() == 1, "the new device went on the return channel")
	_pad_lane.drop(ret, _asset(fx.device_id), 0)
	_assert(pad.children.size() == 2 and ret.devices.size() == 1, "a drop at the front went into the pad chain")
	_assert(not _pad_lane.can_drop(ret, ret.devices[0], 0), "a return device can't move into the pad")
	_assert(_pad_lane.devices(ret).size() == 3 and _pad_lane.devices(ret)[1] == kick, "the lane lists both pad devices, then the return's")


func _test_layer_slot_is_a_chain() -> void:
	var ch: Object = _fresh_project()
	var layer := _container(ch, LAYER_ID)
	var a := _add_fx(ch, "a", layer)
	layer.reveal_child(a)
	var lane := await _lane(ch)
	var pa: Control = lane.find_device_panel(a)
	_assert(pa != null, "the open layer slot shows its device")
	if pa == null:
		return
	var ra := pa.get_global_rect()
	var fx: Object = _device("test.fx.next", _device_script.DeviceCategory.Effect)
	var beside: Object = _drop_target.resolve(lane, _asset(fx.device_id), Vector2(ra.end.x - 2, ra.get_center().y))
	_assert(beside.kind == _drop_target.Kind.INSERT and beside.host.parent == layer.children[0] and beside.position == 1, "beside a layer's device inserts into its slot chain: %d at %d" % [beside.kind, beside.position])
	_assert(beside.commit(_asset(fx.device_id)), "commit adds the device")
	_assert(layer.children.size() == 1 and layer.children[0].children.size() == 2, "the layer still has one slot, now with two devices")
	await _settle()
	var added: Object = layer.children[0].children[1]
	var pn: Control = lane.find_device_panel(added)
	_assert(pn != null and pn.get_global_rect().position.x > ra.end.x, "the slot shows the new device after A")
	if pn == null:
		return
	# Panels keep a margin on their right, and insert lines center on the visible gap.
	var gap := pn.get_global_rect().position.x - ra.end.x
	_assert(absf(gap - (lane.devices.GAP + lane.devices.PANEL_MARGIN)) < 0.5, "panels are GAP + PANEL_MARGIN apart: %s" % gap)
	var between: Object = _drop_target.resolve(lane, _asset(fx.device_id), Vector2(ra.end.x + gap * 0.5, ra.get_center().y))
	_assert(absf(between.indicator_rect.get_center().x - (ra.end.x + gap * 0.5)) < 1.0, "the insert line sits mid-gap")


func _test_empty_drum_pad_slot() -> void:
	var ch: Object = _fresh_project()
	var drum := _container(ch, DRUM_ID)
	var key: String = _device_instance_script.pad_slot_key(40)
	_assert(drum.has_slot(key) and drum.slot_chain(key) == null, "an empty pad has a slot without a chain")
	_assert(drum.slot_title(key) == "E1", "an empty pad's slot is titled by its note: %s" % drum.slot_title(key))
	drum.set_slot_open(key, true)
	var lane := await _lane(ch)
	var groups: Array = lane.devices.items()[0].slot_groups()
	_assert(groups.size() == 1, "the empty pad's slot opens")
	if groups.is_empty():
		return
	var group: Control = groups[0]
	var zone: Rect2 = group.get_global_rect()
	_assert(zone.size.x >= load("res://devices/device_lane/DeviceSlotGroup.gd").EMPTY_WIDTH, "an empty slot keeps a drop zone: %s" % zone)
	var fx: Object = _device("test.fx.snare", _device_script.DeviceCategory.Effect)
	var target: Object = _drop_target.resolve(lane, _asset(fx.device_id), zone.get_center())
	_assert(target.kind == _drop_target.Kind.INSERT and target.host.pad_note == 40 and target.outline, "the empty slot takes the drop onto its pad: %d" % target.kind)
	_assert(target.color == drum.slot_color(key), "in the pad slot's color")
	_assert(target.commit(_asset(fx.device_id)), "commit fills the pad")
	var pad: Object = drum.slot_chain(key)
	_assert(pad != null and pad.slot_note == 40 and pad.children.size() == 1, "the pad got a slot chain on note 40 holding the device")
	_assert(drum.is_slot_open(key), "the pad's slot stays open")
	await _settle()
	_assert(lane.find_device_panel(pad.children[0]) != null, "and shows the new device")
	# Devices dropped on an occupied pad join its chain.
	_drop_util.drop_on_drum_pad(ch, drum, 40, _asset(fx.device_id))
	_assert(drum.children.size() == 1 and pad.children.size() == 2, "a drop on an occupied pad adds to its chain")
