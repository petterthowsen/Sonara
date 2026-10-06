## Multi-out devices: each extra stereo output of a device on a channel's root chain feeds a
## nested "return" channel (see docs/specs/001-multi-out-devices).
##
## - Drum Machine: one return per pad. A pad is a MIDI note with a return channel
##   (`Channel.aux_pad_note`) and optionally a pad device, the Drum Machine child on that note
##   (`DeviceInstance.return_channel_id`). Removing the pad device leaves the pad empty with its
##   return; a device added on that note again adopts the return. Bus index = child order.
## - Layer: one return per slot whose separate output is on (`slot_separate_out`), named after the
##   slot and stored on the slot chain's `return_channel_id`. Bus index = child order; turning the
##   separate output off detaches the return onto the slot for undo (docs/specs/006). The slot and
##   its return share a name and colour both ways, and the return's route is free (REQ-018–020).
## - Any other device: `Device.extra_stereo_bus_count()` outputs named "Out N". The device stores
##   them in `DeviceInstance.return_channel_ids` (index = bus).
##
## Returns are nested under the source's channel with the output locked to it and never get a
## timeline track (the source channel's track plays the device). Removing a root multi-out device
## detaches its returns onto that DeviceInstance, so re-adding it (undo) restores the same Channel
## objects with their settings.
class_name AuxReturnSync

const DRUM_MACHINE_ID := "sonara.builtin.drum_machine"
const LAYER_ID := "sonara.builtin.layer"
const SFZ_ID := "sonara.builtin.sfizz"


# ============================================================================
# CONTRACT
# ============================================================================

## True when `device` is a Drum Machine (its pads are its extra outputs).
static func is_drum_machine(device: DeviceInstance) -> bool:
	return device != null and device.device != null and device.device.device_id == DRUM_MACHINE_ID


## True when `device` is a Layer (its separate-output slots are its extra outputs).
static func is_layer(device: DeviceInstance) -> bool:
	return device != null and device.device != null and device.device.device_id == LAYER_ID


## True when `device` is the built-in SFZ sampler.
static func is_sfz(device: DeviceInstance) -> bool:
	return device != null and device.device != null and device.device.device_id == SFZ_ID


## Number of extra stereo outputs `device` feeds into return channels.
static func extra_out_count(device: DeviceInstance) -> int:
	if device == null or device.device == null:
		return 0
	if is_drum_machine(device) or is_layer(device):
		return device.children.size()
	return device.device.extra_stereo_bus_count()


## Return channel fed by extra output `index` of `device`, or null.
static func get_return_channel(project: Project, device: DeviceInstance, index: int) -> Channel:
	if project == null or device == null or index < 0:
		return null
	if is_drum_machine(device):
		if index >= device.children.size():
			return null
		return project.get_channel_by_id(device.children[index].return_channel_id)
	if is_layer(device):
		if index >= device.children.size() or not device.children[index].slot_separate_out:
			return null
		return project.get_channel_by_id(device.children[index].return_channel_id)
	return project.get_channel_by_id(_plugin_return_id(device, index))


## Source of return channel `ch` as {device, index}: the multi-out device on the parent
## channel's root chain and the extra output that feeds it. Empty when `ch` isn't a return, or is
## an empty pad.
static func get_source(project: Project, ch: Channel) -> Dictionary:
	if project == null or ch == null or ch.parent_channel_id < 0:
		return {}
	var parent := project.get_channel_by_id(ch.parent_channel_id)
	if parent == null:
		return {}
	for device in parent.devices:
		if is_drum_machine(device):
			for i in device.children.size():
				if device.children[i].return_channel_id == ch.id:
					return {"device": device, "index": i}
		elif is_layer(device):
			for i in device.children.size():
				var slot := device.children[i]
				if slot.slot_separate_out and slot.return_channel_id == ch.id:
					return {"device": device, "index": i}
		else:
			var idx := device.return_channel_ids.find(ch.id)
			if idx >= 0 and idx < extra_out_count(device):
				return {"device": device, "index": idx}
	return {}


## Drum Machine that owns pad return `ch`: the first one on its parent channel's root chain.
static func get_pad_drum(ch: Channel) -> DeviceInstance:
	if ch == null or not ch.is_pad_return():
		return null
	var project := ch.get_project()
	var parent := project.get_channel_by_id(ch.parent_channel_id) if project else null
	if parent == null:
		return null
	for device in parent.devices:
		if is_drum_machine(device):
			return device
	return null


## Layer slot (slot chain) whose separate output feeds return `ch`, or null.
static func get_layer_slot(ch: Channel) -> DeviceInstance:
	if ch == null or ch.aux_pad_note >= 0 or ch.aux_bus_index < 0:
		return null
	var source := get_source(ch.get_project(), ch)
	var layer: DeviceInstance = source.get("device")
	if not is_layer(layer):
		return null
	return layer.children[source.index]


## Device playing pad return `ch` (the Drum Machine child feeding it), or null for an empty pad.
static func get_pad_device(ch: Channel) -> DeviceInstance:
	var drum := get_pad_drum(ch)
	if drum == null:
		return null
	for pad in drum.children:
		if pad.return_channel_id == ch.id:
			return pad
	return null


# ============================================================================
# DEVICE CHAIN HOOKS (called by Channel)
# ============================================================================

## After a device is added: pad device → its pad return; root device → its returns (and pads').
static func on_device_added(
	project: Project,
	channel: Channel,
	device: DeviceInstance,
	parent: DeviceInstance
) -> void:
	if project == null or channel == null or device == null:
		return
	if is_drum_machine(parent) and parent.get_parent_device() == null:
		ensure_pad_return(project, channel, parent, device)
		sync_pad_aux_order(project, channel, parent)
		return
	if is_layer(parent) and parent.get_parent_device() == null:
		if device.slot_separate_out:
			ensure_layer_return(project, channel, parent, device)
		sync_layer_aux_order(project, channel, parent)
		return
	if parent == null:
		_ensure_root(project, channel, device)


## After a device is removed: a pad device leaves its pad empty; a root device detaches its returns.
static func on_device_removed(
	project: Project,
	channel: Channel,
	device: DeviceInstance,
	parent: DeviceInstance
) -> void:
	if project == null or device == null:
		return
	if is_drum_machine(parent):
		_unbind_pad(device)
		if channel:
			sync_pad_aux_order(project, channel, parent)
		return
	if is_layer(parent):
		# Unlike a pad, a removed slot takes its return with it (kept on the slot for undo).
		_detach_layer_slot_return(project, device)
		if channel and parent.get_parent_device() == null:
			sync_layer_aux_order(project, channel, parent)
		return
	if parent != null:
		return
	if is_layer(device):
		for slot in device.children:
			_detach_layer_slot_return(project, slot)
	elif is_drum_machine(device):
		for pad in device.children:
			_unbind_pad(pad)
		if channel:
			for child in project.get_channel_children(channel):
				if child.is_pad_return():
					_detach_return(project, device, child.id)
	else:
		for channel_id in device.return_channel_ids:
			_detach_return(project, device, channel_id)
	if channel:
		sync_aux_map_to_engine(channel)


## Keep pad return bus indices in drum-child order after a move.
static func on_device_moved(project: Project, channel: Channel, parent: DeviceInstance) -> void:
	if project == null or channel == null:
		return
	if is_drum_machine(parent):
		sync_pad_aux_order(project, channel, parent)
	elif is_layer(parent) and parent.get_parent_device() == null:
		sync_layer_aux_order(project, channel, parent)


## After load: link existing returns to their sources and create missing ones.
static func ensure_all(project: Project) -> void:
	if project == null:
		return
	for ch in project.channels.duplicate():
		for device in ch.devices:
			_ensure_root(project, ch, device)


# ============================================================================
# ENSURE
# ============================================================================

## Returns for a root device: its extra outs, or one per pad for a Drum Machine.
static func _ensure_root(project: Project, channel: Channel, device: DeviceInstance) -> void:
	if is_drum_machine(device):
		# Re-attach every pad return detached with this drum (empty pads included), in order.
		var after: Channel = null
		for channel_id in device.detached_returns:
			var ch: Channel = device.detached_returns[channel_id]
			if project.get_channel_by_id(channel_id) == null:
				_attach(project, channel, ch, after)
				after = ch
		device.detached_returns.clear()
		for pad in device.children:
			ensure_pad_return(project, channel, device, pad)
		sync_pad_aux_order(project, channel, device)
	elif is_layer(device):
		for slot in device.children:
			if slot.slot_separate_out:
				ensure_layer_return(project, channel, device, slot)
		sync_layer_aux_order(project, channel, device)
	else:
		ensure_plugin_returns(project, channel, device)


## Pad return for Drum Machine child `pad`; output locked to the drum channel.
static func ensure_pad_return(
	project: Project,
	channel: Channel,
	drum: DeviceInstance,
	pad: DeviceInstance
) -> Channel:
	if project == null or channel == null or pad == null:
		return null
	var bus_index: int = drum.children.find(pad)
	var ch: Channel = project.get_channel_by_id(pad.return_channel_id)
	if ch != null and (ch.parent_channel_id != channel.id or _claimed_by_other(channel, pad, ch.id)):
		# Stale id (copied device, or a return that now belongs to another pad).
		ch = null
	if ch == null:
		# An empty pad on this note keeps its return for the next device.
		ch = _find_child(project, channel, func(c: Channel) -> bool:
			return c.aux_pad_note == pad.slot_note and not _claimed_by_other(channel, pad, c.id))
	if ch == null:
		# Saves from before `aux_pad_note`: match by bus index.
		ch = _find_child(project, channel, func(c: Channel) -> bool:
			return c.aux_pad_note < 0 and c.aux_bus_index == bus_index and not _claimed_by_other(channel, pad, c.id))
	if ch == null:
		ch = _create_return_channel(project, channel, pad.get_display_name(), _pad_after_sibling(project, drum, pad), bus_index)
	ch.aux_pad_note = pad.slot_note
	ch.aux_bus_index = bus_index
	pad.return_channel_id = ch.id
	_bind_pad(project, pad)
	_bind_pad_return(project, drum, pad, ch)
	return ch


## Return for a separate-output Layer slot: the saved/detached one when there is one, else new.
static func ensure_layer_return(
	project: Project,
	channel: Channel,
	layer: DeviceInstance,
	slot: DeviceInstance
) -> Channel:
	if project == null or channel == null or slot == null:
		return null
	var bus_index: int = layer.children.find(slot)
	var ch: Channel = project.get_channel_by_id(slot.return_channel_id)
	if ch != null and (ch.parent_channel_id != channel.id or _claimed_by_other(channel, slot, ch.id)):
		ch = null  # Stale id (copied slot, or a return that belongs to someone else).
	if ch == null and slot.detached_returns.has(slot.return_channel_id):
		ch = slot.detached_returns[slot.return_channel_id]
		if project.get_channel_by_id(ch.id) == null:
			# Nesting routes to the parent; a Layer return keeps its own route (REQ-020).
			var route := ch.output_channel_id
			_attach(project, channel, ch, _layer_after_sibling(project, layer, slot))
			if route != ch.output_channel_id and (route == 1 or project.get_channel_by_id(route) != null):
				ch.set_route(route)
		else:
			ch = null
	slot.detached_returns.clear()
	if ch == null:
		ch = _create_return_channel(project, channel, slot.get_display_name(), _layer_after_sibling(project, layer, slot), bus_index)
	ch.aux_bus_index = bus_index
	slot.return_channel_id = ch.id
	_bind_pad(project, slot)
	_bind_layer_return(project, layer, slot, ch)
	# Views built while the channel was being added couldn't see its slot yet (PadLaneWatcher).
	ch.notify_hierarchy_changed()
	return ch


## A Layer slot's separate output was switched: create/restore or detach its return.
static func on_layer_slot_separate_changed(
	project: Project,
	channel: Channel,
	layer: DeviceInstance,
	slot: DeviceInstance
) -> void:
	# Only a Layer on the root chain is a multi-out source.
	if project == null or channel == null or layer == null or layer.get_parent_device() != null:
		return
	if slot.slot_separate_out:
		ensure_layer_return(project, channel, layer, slot)
	else:
		_detach_layer_slot_return(project, slot)
	sync_layer_aux_order(project, channel, layer)


## Detach a Layer slot's return onto the slot (kept for undo / re-enabling). The id stays on the
## slot so ensure_layer_return finds it in `detached_returns`.
static func _detach_layer_slot_return(project: Project, slot: DeviceInstance) -> void:
	if slot == null:
		return
	_unbind_pad(slot)
	_unbind_layer_return(project, slot)
	if slot.return_channel_id >= 0:
		_detach_return(project, slot, slot.return_channel_id)


## Extra stereo outs on a CLAP (or other) device, skipping the main pair.
static func ensure_plugin_returns(project: Project, channel: Channel, device: DeviceInstance) -> void:
	if project == null or channel == null or device == null or device.device == null:
		return
	var extra := extra_out_count(device)
	if extra <= 0:
		return
	var after: Channel = null
	for i in extra:
		var channel_id := _plugin_return_id(device, i)
		var ch: Channel = project.get_channel_by_id(channel_id)
		if ch == null and device.detached_returns.has(channel_id):
			ch = device.detached_returns[channel_id]
			_attach(project, channel, ch, after)
		elif ch != null and (ch.parent_channel_id != channel.id or _claimed_by_other(channel, device, ch.id)):
			ch = null
		if ch == null:
			# Saves without return ids: adopt an unclaimed plugin return on this bus.
			ch = _find_child(project, channel, func(c: Channel) -> bool:
				return not c.is_pad_return() and c.aux_bus_index == i and not _claimed_by_other(channel, device, c.id))
		if ch == null:
			ch = _create_return_channel(project, channel, "Out %d" % (i + 2), after, i)
		ch.aux_bus_index = i
		_set_plugin_return_id(device, i, ch.id)
		after = ch
	device.detached_returns.clear()
	sync_aux_map_to_engine(channel)


## Re-add detached return `ch` nested under `channel` after `after` (null = first).
static func _attach(project: Project, channel: Channel, ch: Channel, after: Channel) -> void:
	# Set before add so the mixer treats the strip as a fold-out child.
	ch.parent_channel_id = channel.id
	project.add_channel(ch)
	project.nest_channel(ch, channel, after)


## Create a nested INSTRUMENT return under `parent`. No timeline track: the source channel's
## track plays the device.
static func _create_return_channel(
	project: Project,
	parent: Channel,
	return_name: String,
	after: Channel,
	bus_index: int
) -> Channel:
	var ch := Channel.new(project.next_channel_id)
	project.next_channel_id += 1
	# A second drum machine's KICK return becomes "KICK 2" (names are project-unique).
	ch.name = project.unique_name(return_name, null, null, "Return")
	ch.channel_type = Channel.ChannelType.INSTRUMENT
	ch.output_channel_id = parent.id
	ch.color = parent.color
	ch.volume = 0.0
	ch.aux_bus_index = bus_index
	ch.parent_channel_id = parent.id
	project.add_channel(ch)
	project.nest_channel(ch, parent, after)
	return ch


# ============================================================================
# DETACH
# ============================================================================

## Remove return `channel_id` from the project and keep it on `owner` for a later re-add.
## A legacy paired timeline track (older CLAP returns had one) is removed for good.
static func _detach_return(project: Project, owner: DeviceInstance, channel_id: int) -> void:
	if project == null or owner == null or channel_id < 0:
		return
	var ch := project.get_channel_by_id(channel_id)
	if ch == null:
		return
	var track := project.get_channel_paired_track(ch)
	if track:
		project.remove_track(track.id)
	project.remove_channel(channel_id)
	owner.detached_returns[channel_id] = ch


# ============================================================================
# ENGINE MAP
# ============================================================================

## Tell the engine which extra buses feed which child channels, clearing slots no longer used.
static func sync_aux_map_to_engine(channel: Channel) -> void:
	if channel == null or not channel.is_engine_connected():
		return
	var project := channel.get_project()
	if project == null:
		return
	var count := 0
	for child_id in channel.child_channel_ids:
		var child := project.get_channel_by_id(child_id)
		if child == null or child.aux_bus_index < 0:
			continue
		AudioEngineOSC.send("/channel/%d/aux_out" % channel.id, [child.aux_bus_index, child.id])
		count = maxi(count, child.aux_bus_index + 1)
	# Target 0 clears a slot, so a removed pad's bus stops feeding a channel.
	for i in range(count, channel.aux_out_sent_count):
		AudioEngineOSC.send("/channel/%d/aux_out" % channel.id, [i, 0])
	channel.aux_out_sent_count = count


## Align pad return bus indices and child_channel_ids with drum child order. Empty pads get no bus.
static func sync_pad_aux_order(project: Project, channel: Channel, drum: DeviceInstance) -> void:
	if project == null or channel == null or drum == null:
		return
	var ordered: Array[int] = []
	for i in drum.children.size():
		var pad: DeviceInstance = drum.children[i]
		var ch := project.get_channel_by_id(pad.return_channel_id)
		if ch == null or ch.parent_channel_id != channel.id:
			continue
		ch.aux_bus_index = i
		ordered.append(ch.id)
	for child in project.get_channel_children(channel):
		if child.is_pad_return() and not ordered.has(child.id):
			child.aux_bus_index = -1
	# Occupied pad returns take their slots in pad order; everything else keeps its place.
	var result: Array[int] = []
	var next := 0
	for child_id in channel.child_channel_ids:
		if ordered.has(child_id):
			result.append(ordered[next])
			next += 1
		else:
			result.append(child_id)
	for i in range(next, ordered.size()):
		if not result.has(ordered[i]):
			result.append(ordered[i])
	if result != channel.child_channel_ids:
		channel.child_channel_ids = result
		channel.notify_hierarchy_changed()
	sync_aux_map_to_engine(channel)


## Align Layer return bus indices with slot order (bus = slot index) and keep the returns in
## slot order among the channel's children, then resend the aux map.
static func sync_layer_aux_order(project: Project, channel: Channel, layer: DeviceInstance) -> void:
	if project == null or channel == null or layer == null:
		return
	var ordered: Array[int] = []
	for i in layer.children.size():
		var slot: DeviceInstance = layer.children[i]
		if not slot.slot_separate_out:
			continue
		var ch := project.get_channel_by_id(slot.return_channel_id)
		if ch == null or ch.parent_channel_id != channel.id:
			continue
		ch.aux_bus_index = i
		ordered.append(ch.id)
	var result: Array[int] = []
	var next := 0
	for child_id in channel.child_channel_ids:
		if ordered.has(child_id):
			result.append(ordered[next])
			next += 1
		else:
			result.append(child_id)
	for i in range(next, ordered.size()):
		if not result.has(ordered[i]):
			result.append(ordered[i])
	if result != channel.child_channel_ids:
		channel.child_channel_ids = result
		channel.notify_hierarchy_changed()
	sync_aux_map_to_engine(channel)


# ============================================================================
# HELPERS
# ============================================================================

## True when return `channel_id` belongs to a source on `channel` other than `owner`.
static func _claimed_by_other(channel: Channel, owner: DeviceInstance, channel_id: int) -> bool:
	for device in channel.devices:
		if is_drum_machine(device) or is_layer(device):
			for pad in device.children:
				if pad != owner and pad.return_channel_id == channel_id:
					return true
		elif device != owner and device.return_channel_ids.has(channel_id):
			return true
	return false


## First mixer child of `parent` matching `pred`.
static func _find_child(project: Project, parent: Channel, pred: Callable) -> Channel:
	for child in project.get_channel_children(parent):
		if pred.call(child):
			return child
	return null


## Previous pad's return channel, or null to insert first.
static func _pad_after_sibling(project: Project, drum: DeviceInstance, pad: DeviceInstance) -> Channel:
	var idx := drum.children.find(pad)
	for i in range(idx - 1, -1, -1):
		var prev := project.get_channel_by_id(drum.children[i].return_channel_id)
		if prev:
			return prev
	return null


## Previous separate Layer slot's return channel, or null to insert first.
static func _layer_after_sibling(project: Project, layer: DeviceInstance, slot: DeviceInstance) -> Channel:
	var idx := layer.children.find(slot)
	for i in range(idx - 1, -1, -1):
		var prev_slot: DeviceInstance = layer.children[i]
		if not prev_slot.slot_separate_out:
			continue
		var prev := project.get_channel_by_id(prev_slot.return_channel_id)
		if prev:
			return prev
	return null


## Keep a separate Layer slot and its return in step: same name and colour, whichever changes
## (REQ-018, REQ-019). The slot's current name and colour win when binding.
static func _bind_layer_return(project: Project, layer: DeviceInstance, slot: DeviceInstance, ch: Channel) -> void:
	_unbind_layer_return(project, slot)
	var key := layer.slot_key_for(slot)
	if ch.color != layer.slot_color(key):
		ch.set_color(layer.slot_color(key))
	if ch.name != ch.unique_name_for(slot.get_display_name()):
		ch.set_name(slot.get_display_name())
	var links: Array = [
		[ch.name_changed, _on_layer_return_renamed.bind(slot)],
		[ch.color_changed, _on_layer_return_recolored.bind(layer, slot)],
	]
	for link in links:
		(link[0] as Signal).connect(link[1])
	_layer_links[slot.get_instance_id()] = links
	# One follower per Layer: Godot treats bind()s of the same method as one connection, so a
	# per-slot bind would collide. It recolours every separate slot's return.
	var follower := _on_layer_slots_changed.bind(project, layer)
	if not layer.slots_changed.is_connected(follower):
		layer.slots_changed.connect(follower)


## Return-channel connections made by _bind_layer_return, by slot instance id:
## [[Signal, Callable], ...]. Each return channel is its own object, so these never collide.
static var _layer_links: Dictionary = {}


## Drop the name/colour links between `slot` and its return (and its Layer).
static func _unbind_layer_return(_project: Project, slot: DeviceInstance) -> void:
	if slot == null:
		return
	var links: Array = _layer_links.get(slot.get_instance_id(), [])
	for link in links:
		var sig: Signal = link[0]
		if not sig.is_null() and sig.is_connected(link[1]):
			sig.disconnect(link[1])
	_layer_links.erase(slot.get_instance_id())


## The return was renamed (mixer, undo): the slot takes the name.
static func _on_layer_return_renamed(new_name: String, slot: DeviceInstance) -> void:
	if slot and slot.slot_separate_out and slot.name != new_name:
		slot.set_name(new_name)


## The return was recoloured: the slot takes the colour.
static func _on_layer_return_recolored(color: Color, layer: DeviceInstance, slot: DeviceInstance) -> void:
	if layer == null or slot == null or not slot.slot_separate_out:
		return
	var key := layer.slot_key_for(slot)
	if layer.slot_color(key) != color:
		layer.set_slot_color(key, color)


## Slot colours changed on the Layer: each separate slot's return takes its slot's colour.
static func _on_layer_slots_changed(project: Project, layer: DeviceInstance) -> void:
	if project == null or layer == null:
		return
	for slot in layer.children:
		if not slot.slot_separate_out:
			continue
		var ch := project.get_channel_by_id(slot.return_channel_id)
		var color := layer.slot_color(layer.slot_key_for(slot))
		if ch and ch.color != color:
			ch.set_color(color)


## Follow pad device renames and note changes. Binding alone doesn't rename: a device that adopts
## an empty pad (or moves to the front of its lane) leaves the return's name alone.
static func _bind_pad(project: Project, pad: DeviceInstance) -> void:
	if pad == null:
		return
	_unbind_pad(pad)
	pad.name_changed.connect(_on_pad_name_changed.bind(project, pad))
	pad.slot_changed.connect(_on_pad_slot_changed.bind(project, pad))


## Drop the pad listeners (the pad left its Drum Machine).
static func _unbind_pad(pad: DeviceInstance) -> void:
	if pad == null:
		return
	_unbind_pad_return(pad)
	for sig in [pad.name_changed, pad.slot_changed]:
		for conn in (sig as Signal).get_connections():
			var cb: Callable = conn.get("callable")
			if cb.is_valid() and cb.get_method() in ["_on_pad_name_changed", "_on_pad_slot_changed"]:
				(sig as Signal).disconnect(cb)


## Keep a Drum Machine pad and its return in step: same name and colour, whichever changes (the
## pad slot and its child channel are one thing). The pad's current name and colour win when
## binding. The pad's rename → return direction is `_on_pad_name_changed` (see `_bind_pad`).
static func _bind_pad_return(project: Project, drum: DeviceInstance, pad: DeviceInstance, ch: Channel) -> void:
	var key := DeviceInstance.pad_slot_key(pad.slot_note)
	if ch.color != drum.slot_color(key):
		ch.set_color(drum.slot_color(key))
	var links: Array = [
		[ch.name_changed, _on_pad_return_renamed.bind(pad)],
		[ch.color_changed, _on_pad_return_recolored.bind(drum, pad)],
	]
	for link in links:
		(link[0] as Signal).connect(link[1])
	_pad_links[pad.get_instance_id()] = links
	# One follower per Drum Machine (bind()s of the same method count as one connection).
	var follower := _on_drum_slots_changed.bind(project, drum)
	if not drum.slots_changed.is_connected(follower):
		drum.slots_changed.connect(follower)


## Return-channel connections made by _bind_pad_return, by pad instance id.
static var _pad_links: Dictionary = {}


static func _unbind_pad_return(pad: DeviceInstance) -> void:
	var links: Array = _pad_links.get(pad.get_instance_id(), [])
	for link in links:
		var sig: Signal = link[0]
		if not sig.is_null() and sig.is_connected(link[1]):
			sig.disconnect(link[1])
	_pad_links.erase(pad.get_instance_id())


## The pad's return was renamed (mixer, undo): the pad takes the name.
static func _on_pad_return_renamed(new_name: String, pad: DeviceInstance) -> void:
	if pad and pad.name != new_name:
		pad.set_name(new_name)


## The pad's return was recoloured: the pad slot takes the colour.
static func _on_pad_return_recolored(color: Color, drum: DeviceInstance, pad: DeviceInstance) -> void:
	if drum == null or pad == null:
		return
	var key := DeviceInstance.pad_slot_key(pad.slot_note)
	if drum.slot_color(key) != color:
		drum.set_slot_color(key, color)


## Pad colours changed on the Drum Machine: each pad's return takes its pad's colour.
static func _on_drum_slots_changed(project: Project, drum: DeviceInstance) -> void:
	if project == null or drum == null:
		return
	for pad in drum.children:
		var ch := project.get_channel_by_id(pad.return_channel_id)
		var color := drum.slot_color(DeviceInstance.pad_slot_key(pad.slot_note))
		if ch and ch.is_pad_return() and ch.color != color:
			ch.set_color(color)


## Rename the pad return when the pad device is renamed.
## The return may end up suffixed (`KICK 2`); nothing renames the pad back, so this can't loop,
## and re-running it (ensure_all, re-binding) settles on the same name.
static func _on_pad_name_changed(new_name: String, project: Project, pad: DeviceInstance) -> void:
	if project == null or pad == null:
		return
	var ch := project.get_channel_by_id(pad.return_channel_id)
	if ch and ch.name != ch.unique_name_for(new_name):
		ch.set_name(new_name)


## The pad return follows its device to a new note.
static func _on_pad_slot_changed(project: Project, pad: DeviceInstance) -> void:
	if project == null or pad == null:
		return
	var ch := project.get_channel_by_id(pad.return_channel_id)
	if ch and ch.is_pad_return():
		ch.aux_pad_note = pad.slot_note


## Return channel id stored on a multi-out device for extra bus `index`.
static func _plugin_return_id(device: DeviceInstance, index: int) -> int:
	if index < 0 or index >= device.return_channel_ids.size():
		return -1
	return device.return_channel_ids[index]


## Remember extra-out return `channel_id` on the plugin device.
static func _set_plugin_return_id(device: DeviceInstance, index: int, channel_id: int) -> void:
	while device.return_channel_ids.size() <= index:
		device.return_channel_ids.append(-1)
	device.return_channel_ids[index] = channel_id
