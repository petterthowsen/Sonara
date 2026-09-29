# test_layer_separate_out.gd
# Headless tests for Layer slot separate outputs (docs/specs/006-layer-note-mapping, REQ-006):
# a return channel per separate slot, following the multi-out rules of spec 001 (no timeline
# track, locked to the parent, same channel back on undo), and the engine aux map following
# slot order.
#
# Project, DeviceInstance and the commands reference autoloads by bare name, so they're
# load()ed in run_tests().
# Run: godot --headless --path Godot -s tests/test_layer_separate_out.gd -- --test
extends TestBase

const LAYER_ID := "sonara.builtin.layer"

var _project_script: GDScript
var _device_script: GDScript
var _device_instance_script: GDScript
var _aux: GDScript
var _history_script: GDScript
var _property_command: GDScript
var _device_remove: GDScript


func suite_name() -> String:
	return "Layer separate output tests"


func run_tests() -> void:
	_project_script = load("res://data/Project.gd")
	_device_script = load("res://data/Device.gd")
	_device_instance_script = load("res://data/DeviceInstance.gd")
	_aux = load("res://data/AuxReturnSync.gd")
	_history_script = load("res://history/CommandHistory.gd")
	_property_command = load("res://history/commands/PropertyCommand.gd")
	_device_remove = load("res://history/commands/DeviceRemoveCommand.gd")
	_test_separate_creates_return()
	_test_off_then_undo_restores_same_return()
	_test_slot_remove_undo_restores_return()
	_test_layer_remove_undo_restores_returns()
	_test_aux_map_follows_slot_order()
	_test_nested_layer_gets_no_return()
	_test_load_keeps_returns()
	_test_name_sync()
	_test_color_sync()
	_test_route_is_free()
	_test_lane_shows_slot()
	_test_lane_flattens_slot_chain()


# --- helpers ---------------------------------------------------------------

func _device(ch: Object, device_id: String, title: String) -> Object:
	var registry: Object = root.get_node("AssetService").device_registry
	var device: Object = registry._devices.get(device_id)
	if device == null:
		device = _device_script.new(device_id, title, _device_script.DeviceCategory.Instrument, _device_script.DeviceType.BuiltIn)
		registry._devices[device_id] = device
	return _device_instance_script.new(device, ch.id, 0)


## Instrument channel holding a Layer with slots named `names`. Returns {project, channel, layer, slots}.
func _layer(names: Array) -> Dictionary:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var layer := _device(ch, LAYER_ID, "Layer")
	ch.add_device(layer)
	var slots: Array = []
	for n in names:
		var slot := _device(ch, "sonara.builtin.polysynth", "PolySynth")
		slot.name = n
		ch.add_device(slot, -1, layer)
		slots.append(slot)
	return {"project": project, "channel": ch, "layer": layer, "slots": slots}


func _set_separate(hist: Object, slot: Object, on: bool) -> void:
	hist.execute(_property_command.new("Separate Output", slot, "set_slot_separate_out", slot.slot_separate_out, on))


func _child_names(project: Object, ch: Object) -> Array:
	var out: Array = []
	for child in project.get_channel_children(ch):
		out.append(child.name)
	return out


## {bus_index: target_id} of the /channel/{id}/aux_out sends queued in AudioEngineOSC.
func _sent_aux_map(osc: Node, channel_id: int) -> Dictionary:
	var map := {}
	for item in osc._pending_sends:
		if item.address == "/channel/%d/aux_out" % channel_id:
			map[int(item.args[0])] = int(item.args[1])
	return map


# --- tests -----------------------------------------------------------------

func _test_separate_creates_return() -> void:
	var d := _layer(["Kick", "Snare"])
	var project: Object = d.project
	var ch: Object = d.channel
	_assert(project.get_channel_children(ch).is_empty(), "no returns while every slot mixes into the Layer")
	var track_count: int = project.tracks.size()
	var hist: Object = _history_script.new()
	_set_separate(hist, d.slots[1], true)
	var kids: Array = project.get_channel_children(ch)
	_assert(_child_names(project, ch) == ["Snare"], "REQ-006: one return named after the slot: %s" % str(_child_names(project, ch)))
	_assert(project.tracks.size() == track_count, "REQ-006: no timeline track for the return")
	if kids.size() != 1:
		return
	var ret: Object = kids[0]
	_assert(ret.parent_channel_id == ch.id and ret.output_channel_id == ch.id, "REQ-006: return nested and locked to the Layer channel")
	_assert(ret.aux_bus_index == 1, "bus index = slot index (got %d)" % ret.aux_bus_index)
	_assert(ret.is_plugin_return(), "REQ-006: return can't be deleted on its own (is_plugin_return)")
	_assert(_aux.get_source(project, ret).get("device") == d.layer and _aux.get_source(project, ret).get("index") == 1, "source lookup finds Layer slot 1")
	_assert(_aux.get_return_channel(project, d.layer, 1) == ret, "return lookup finds the Snare return")
	_assert(_aux.get_return_channel(project, d.layer, 0) == null, "non-separate slot has no return")


func _test_off_then_undo_restores_same_return() -> void:
	var d := _layer(["Kick", "Snare"])
	var project: Object = d.project
	var ch: Object = d.channel
	var hist: Object = _history_script.new()
	_set_separate(hist, d.slots[1], true)
	var ret: Object = project.get_channel_children(ch)[0]
	ret.set_volume(-6.0)
	var channel_count: int = project.channels.size()
	_set_separate(hist, d.slots[1], false)
	_assert(project.get_channel_by_id(ret.id) == null, "REQ-006: turning separate output off removes the return")
	hist.undo()
	var back: Object = project.get_channel_by_id(ret.id)
	_assert(back == ret, "REQ-006: undo restores the same return channel (id %d)" % ret.id)
	_assert(back != null and is_equal_approx(back.volume, -6.0), "REQ-006: undo keeps −6 dB")
	_assert(project.channels.size() == channel_count, "undo creates no extra channel")
	# Redo then re-enable by hand: still the same channel, not a new one.
	hist.redo()
	_set_separate(hist, d.slots[1], true)
	_assert(project.get_channel_children(ch).size() == 1 and project.get_channel_children(ch)[0] == ret, "re-enabling reuses the detached return")


func _test_slot_remove_undo_restores_return() -> void:
	var d := _layer(["Kick", "Snare"])
	var project: Object = d.project
	var ch: Object = d.channel
	var hist: Object = _history_script.new()
	_set_separate(hist, d.slots[0], true)
	var ret: Object = project.get_channel_children(ch)[0]
	hist.execute(_device_remove.new(ch, d.slots[0]))
	_assert(project.get_channel_by_id(ret.id) == null, "REQ-006: removing the slot removes its return")
	hist.undo()
	_assert(project.get_channel_by_id(ret.id) == ret, "REQ-006: undoing the slot removal restores the same return")


func _test_layer_remove_undo_restores_returns() -> void:
	var d := _layer(["Kick", "Snare", "Hat"])
	var project: Object = d.project
	var ch: Object = d.channel
	var hist: Object = _history_script.new()
	_set_separate(hist, d.slots[0], true)
	_set_separate(hist, d.slots[2], true)
	var ids: Array = project.get_channel_children(ch).map(func(c): return c.id)
	hist.execute(_device_remove.new(ch, d.layer))
	_assert(project.get_channel_children(ch).is_empty(), "removing the Layer removes its returns")
	hist.undo()
	var back: Array = project.get_channel_children(ch).map(func(c): return c.id)
	_assert(back == ids, "undoing the Layer removal restores both returns in order: %s vs %s" % [str(back), str(ids)])


func _test_aux_map_follows_slot_order() -> void:
	var osc: Node = root.get_node_or_null("AudioEngineOSC")
	_assert(osc != null, "setup: AudioEngineOSC autoload present")
	if osc == null:
		return
	var d := _layer(["Kick", "Snare", "Hat"])
	var project: Object = d.project
	var ch: Object = d.channel
	var hist: Object = _history_script.new()
	_set_separate(hist, d.slots[0], true)
	_set_separate(hist, d.slots[2], true)
	var kick: int = d.slots[0].return_channel_id
	var hat: int = d.slots[2].return_channel_id
	ch._is_connected = true
	osc._pending_sends.clear()
	_aux.sync_aux_map_to_engine(ch)
	_assert(_sent_aux_map(osc, ch.id) == {0: kick, 2: hat}, "aux map: Kick on bus 0, Hat on bus 2: %s" % str(_sent_aux_map(osc, ch.id)))

	osc._pending_sends.clear()
	ch.move_device(2, 0, d.layer)  # Hat, Kick, Snare
	var map := _sent_aux_map(osc, ch.id)
	_assert(map.get(0) == hat and map.get(1) == kick, "aux map follows the move (Hat 0, Kick 1): %s" % str(map))
	_assert(map.get(2, 0) == 0, "bus 2 cleared after the move: %s" % str(map))
	_assert(_child_names(project, ch) == ["Hat", "Kick"], "returns reordered with the slots: %s" % str(_child_names(project, ch)))
	ch._is_connected = false
	osc._pending_sends.clear()


func _test_nested_layer_gets_no_return() -> void:
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Keys").channel
	var chain := _device(ch, "sonara.builtin.chain", "Chain")
	ch.add_device(chain)
	var layer := _device(ch, LAYER_ID, "Layer")
	ch.add_device(layer, -1, chain)
	var slot := _device(ch, "sonara.builtin.polysynth", "PolySynth")
	ch.add_device(slot, -1, layer)
	slot.set_slot_separate_out(true)
	_assert(project.get_channel_children(ch).is_empty(), "REQ-007: a Layer off the root chain gets no return")


func _test_load_keeps_returns() -> void:
	var d := _layer(["Kick", "Snare"])
	var source: Object = d.project
	var hist: Object = _history_script.new()
	_set_separate(hist, d.slots[1], true)
	var ret: Object = source.get_channel_children(d.channel)[0]
	ret.set_volume(-3.0)
	var data: Dictionary = JSON.parse_string(JSON.stringify(source.to_json()))
	var project: Object = _project_script.from_json(data)
	var ch: Object = project.get_channel_by_id(d.channel.id)
	var kids: Array = project.get_channel_children(ch)
	_assert(kids.size() == 1, "REQ-016: exactly one Layer return after load, got %d" % kids.size())
	var slot: Object = ch.devices[0].children[1]
	_assert(slot.slot_separate_out, "REQ-016: separate output flag survives load")
	_assert(kids.size() == 1 and kids[0].id == ret.id and is_equal_approx(kids[0].volume, -3.0), "REQ-016: return keeps id and volume")
	_assert(slot.return_channel_id == ret.id, "slot linked to its saved return")
	var again: Object = _project_script.from_json(project.to_json())
	_assert(again.channels.size() == project.channels.size(), "save → load round trip adds no channels")


func _test_name_sync() -> void:
	var d := _layer(["PolySynth", "Kick"])
	var project: Object = d.project
	var hist: Object = _history_script.new()
	var slot: Object = d.slots[0]
	_set_separate(hist, slot, true)
	var ret: Object = project.get_channel_by_id(slot.return_channel_id)
	hist.execute(_property_command.new("Rename Device", slot, "set_name", slot.name, "Snare"))
	_assert(ret.name == "Snare", "REQ-018: renaming the slot renames the return (got '%s')" % ret.name)
	hist.execute(_property_command.new("Rename Channel", ret, "set_name", ret.name, "Rim"))
	_assert(slot.name == "Rim", "REQ-018: renaming the return renames the slot (got '%s')" % slot.name)
	hist.undo()
	_assert(slot.name == "Snare" and ret.name == "Snare", "REQ-018: undoing the return rename moves both back (%s / %s)" % [slot.name, ret.name])
	hist.undo()
	_assert(slot.name == "PolySynth" and ret.name == "PolySynth", "REQ-018: undoing the slot rename moves both back (%s / %s)" % [slot.name, ret.name])
	# A name another channel already has: the channel's suffix carries over to the slot.
	var other: Object = project.create_instrument_track("Taken").channel
	slot.set_name(other.name)
	_assert(ret.name != other.name and slot.name == ret.name, "REQ-018: suffixed channel name carried to the slot (%s / %s)" % [slot.name, ret.name])
	# Off: the link is dropped.
	_set_separate(hist, slot, false)
	slot.set_name("Loose")
	_assert(ret.name != "Loose", "no name sync while separate output is off")


func _test_color_sync() -> void:
	var d := _layer(["Kick"])
	var project: Object = d.project
	var hist: Object = _history_script.new()
	var slot: Object = d.slots[0]
	var layer: Object = d.layer
	var key: String = layer.slot_key_for(slot)
	var slot_color: Color = layer.slot_color(key)
	_set_separate(hist, slot, true)
	var ret: Object = project.get_channel_by_id(slot.return_channel_id)
	_assert(ret.color == slot_color, "REQ-019: return created in the slot colour")
	ret.set_color(Color.RED)
	_assert(layer.slot_color(key) == Color.RED, "REQ-019: recolouring the return recolours the slot")
	layer.set_slot_color(key, Color.BLUE)
	_assert(ret.color == Color.BLUE, "REQ-019: recolouring the slot recolours the return")
	_set_separate(hist, slot, false)
	layer.set_slot_color(key, Color.GREEN)
	_assert(ret.color == Color.BLUE, "no colour sync while separate output is off")
	_set_separate(hist, slot, true)
	_assert(ret.color == Color.GREEN, "re-enabling takes the slot's current colour")


func _test_route_is_free() -> void:
	var d := _layer(["Snare"])
	var project: Object = d.project
	var ch: Object = d.channel
	var hist: Object = _history_script.new()
	var slot: Object = d.slots[0]
	_set_separate(hist, slot, true)
	var ret: Object = project.get_channel_by_id(slot.return_channel_id)
	var bus: Object = project.create_bus_channel("Perc High")
	_assert(ret.is_layer_return() and not ret.route_locked(), "REQ-020: a Layer return's route isn't locked")
	ret.set_route(bus.id)
	_assert(ret.output_channel_id == bus.id and ret.parent_channel_id == ch.id, "REQ-020: routed to the bus, still nested under the Layer channel")
	_set_separate(hist, slot, false)
	hist.undo()
	_assert(ret.output_channel_id == bus.id, "REQ-020: route survives off → undo (got %d)" % ret.output_channel_id)
	var loaded: Object = _project_script.from_json(JSON.parse_string(JSON.stringify(project.to_json())))
	var loaded_ret: Object = loaded.get_channel_by_id(ret.id)
	_assert(loaded_ret != null and loaded_ret.output_channel_id == bus.id and loaded_ret.parent_channel_id == ch.id, "REQ-020: route survives save → load")

	# Drum pad returns stay locked.
	var drum_ch: Object = project.create_instrument_track("Drums").channel
	var drum := _device(drum_ch, _aux.DRUM_MACHINE_ID, "Drum Machine")
	drum_ch.add_device(drum)
	var pad := _device(drum_ch, "sonara.builtin.polysynth", "PolySynth")
	drum_ch.add_device(pad, -1, drum)
	var pad_ret: Object = project.get_channel_by_id(pad.return_channel_id)
	_assert(pad_ret != null and pad_ret.route_locked() and not pad_ret.is_layer_return(), "drum pad returns stay route-locked")


func _test_lane_shows_slot() -> void:
	var d := _layer(["Kick", "Snare"])
	var project: Object = d.project
	var hist: Object = _history_script.new()
	var slot: Object = d.slots[1]
	_set_separate(hist, slot, true)
	var ret: Object = project.get_channel_by_id(slot.return_channel_id)
	var pad_lane: GDScript = load("res://devices/PadLane.gd")
	_assert(_aux.get_layer_slot(ret) == slot, "return resolves to its Layer slot")
	_assert(pad_lane.is_pad_lane(ret), "a Layer return is shown as a pad lane")
	var fx := _device(ret, "sonara.builtin.delay", "Delay")
	ret.add_device(fx)
	_assert(pad_lane.devices(ret) == [slot, fx], "lane is [slot chain][return devices] (got %s)" % [pad_lane.devices(ret).map(func(x): return x.name)])
	_assert(not pad_lane.can_drop(ret, fx, 0), "nothing goes in front of the slot chain")
	_assert(not pad_lane.can_drop(ret, slot, 2), "the slot chain can't be moved behind the return's devices")
	var fx2 := _device(ret, "sonara.builtin.delay", "Delay")
	ret.add_device(fx2)
	var target := Array([slot, fx2, fx], TYPE_OBJECT, &"RefCounted", _device_instance_script)
	var cmds: Array = pad_lane.commands(ret, target, true)
	_assert(cmds.size() == 1, "reordering the return's devices is one move (got %d)" % cmds.size())
	_set_separate(hist, slot, false)
	_assert(not pad_lane.is_pad_lane(ret), "OUT off: no longer a Layer lane")


func _test_lane_flattens_slot_chain() -> void:
	# A real Layer slot is a slot chain; the return's lane shows its devices, not the Chain.
	var project: Object = _project_script.new()
	var ch: Object = project.create_instrument_track("Drums").channel
	var layer := _device(ch, LAYER_ID, "Layer")
	ch.add_device(layer)
	var chain := _device(ch, "sonara.builtin.chain", "Snare")
	chain.name = "Snare"
	ch.add_device(chain, -1, layer)
	var sfz := _device(ch, "sonara.builtin.sfizz", "SFZ")
	ch.add_device(sfz, -1, chain)
	var hist: Object = _history_script.new()
	_set_separate(hist, chain, true)
	var ret: Object = project.get_channel_by_id(chain.return_channel_id)
	var pad_lane: GDScript = load("res://devices/PadLane.gd")
	var fx := _device(ret, "sonara.builtin.delay", "Delay")
	ret.add_device(fx)
	_assert(pad_lane.devices(ret) == [sfz, fx], "lane is [slot chain devices][return devices], no Chain (got %s)" % [pad_lane.devices(ret).map(func(x): return x.name)])
	_assert(not pad_lane.can_drop(ret, fx, 0), "a return device can't move into the slot's part")
	_assert(not pad_lane.can_drop(ret, sfz, 2), "a slot device can't move into the return's part")
	var eq := _device(ch, "sonara.builtin.delay", "EQ")
	ch.add_device(eq, -1, chain)
	_assert(pad_lane.devices(ret) == [sfz, eq, fx], "devices added to the slot chain show up in front (got %s)" % [pad_lane.devices(ret).map(func(x): return x.name)])
	var fx2 := _device(ret, "sonara.builtin.delay", "Delay 2")
	ret.add_device(fx2)
	var target := Array([sfz, eq, fx2, fx], TYPE_OBJECT, &"RefCounted", _device_instance_script)
	var cmds: Array = pad_lane.commands(ret, target, true)
	_assert(cmds.size() == 1, "reordering the return's devices behind the slot's is one move (got %d)" % cmds.size())
	var bad := Array([eq, sfz, fx, fx2], TYPE_OBJECT, &"RefCounted", _device_instance_script)
	_assert(pad_lane.commands(ret, bad, true).is_empty(), "the slot's devices can't be reordered from the return lane")
