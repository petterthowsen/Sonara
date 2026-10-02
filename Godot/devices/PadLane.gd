# PadLane.gd
# Device chain of a drum pad's (or Layer slot's) return channel, as the device lane and mixer strip
# show it: [source devices...][return channel devices...].
#
# The *source* is what feeds the return: the Drum Machine's slot chain on the pad's note, or the
# Layer slot chain whose separate output feeds it (see SlotChain). The Chain itself isn't shown,
# only its devices; they get the MIDI. The lane keeps two parts:
# - the source's devices, reordered among themselves, and an asset dropped among them goes into
#   the slot chain (on an empty pad, a drop at the front creates the pad);
# - the return channel's own devices, reordered among themselves.
# Nothing moves between the parts. Edits become undoable device commands. See
# docs/specs/001-multi-out-devices (REQ-015–019, REQ-017 revised by spec 006) and
# docs/specs/006-layer-note-mapping (REQ-023).
class_name PadLane extends RefCounted


## True when `channel` should be shown and edited as a pad lane.
static func is_pad_lane(channel: Channel) -> bool:
	return channel != null and (AuxReturnSync.get_pad_drum(channel) != null or AuxReturnSync.get_layer_slot(channel) != null)


## What feeds the return: the Layer slot chain, the pad chain, or null (empty pad).
static func front_device(channel: Channel) -> DeviceInstance:
	var slot := AuxReturnSync.get_layer_slot(channel)
	return slot if slot else AuxReturnSync.get_pad_device(channel)


## Devices shown before the return's own: the source chain's devices (the source itself when it
## isn't a Chain). Empty for an empty pad or slot.
static func front_devices(channel: Channel) -> Array[DeviceInstance]:
	var out: Array[DeviceInstance] = []
	var src := front_device(channel)
	if src == null:
		return out
	if SlotChain.is_chain(src):
		out.append_array(src.children)
	else:
		out.append(src)
	return out


## Devices in lane order: the source's devices, then the return channel's own devices.
static func devices(channel: Channel) -> Array[DeviceInstance]:
	var out := front_devices(channel)
	out.append_array(channel.devices)
	return out


## Whether `data` may be dropped at lane index `index` (-1 = end). Dropping a device back where it
## is counts; `changes` tells it apart.
static func can_drop(channel: Channel, data: Variant, index: int) -> bool:
	if not is_pad_lane(channel):
		return false
	var lane := devices(channel)
	var at := _clamp_index(lane, index)
	var src := front_device(channel)
	var front_size := front_devices(channel).size()
	if data is DeviceInstance:
		var from := lane.find(data)
		if from < 0:
			return false
		if from < front_size:
			# Reorder inside the source chain (at == front_size = its end).
			return SlotChain.is_chain(src) and at <= front_size
		return at >= front_size
	if not data is Asset:
		return false
	var asset := data as Asset
	if _goes_to_source(src, front_size, at):
		return asset.type == Asset.TYPE.Device or asset.type == Asset.TYPE.Preset or asset.type == Asset.TYPE.SFZ or asset.type == Asset.TYPE.Audio
	if at < front_size:
		return false  # Among the devices of a source that isn't a Chain.
	return DeviceDropUtil.can_drop_asset_on_channel(channel, asset)


## Whether dropping `data` at lane index `index` (-1 = end) changes anything.
static func changes(channel: Channel, data: Variant, index: int) -> bool:
	if not can_drop(channel, data, index):
		return false
	if not data is DeviceInstance:
		return true
	var lane := devices(channel)
	return _moved(lane, lane.find(data), _clamp_index(lane, index)) != lane


## Add an asset or move a device to lane index `index` (-1 = end), as one undo step.
static func drop(channel: Channel, data: Variant, index: int) -> void:
	if not changes(channel, data, index):
		return
	var lane := devices(channel)
	var at := _clamp_index(lane, index)
	var src := front_device(channel)
	var front_size := front_devices(channel).size()
	if data is DeviceInstance:
		var from := lane.find(data)
		if from < front_size:
			var to := at - 1 if from < at else at
			HistoryUtil.execute(DeviceMoveCommand.new(src.get_channel(), from, to, src))
		else:
			HistoryUtil.execute_many("Move Device", commands(channel, _moved(lane, from, at)))
		return
	var asset := data as Asset
	if src == null:
		# Empty pad: the device goes into a new slot chain on the pad's note, which adopts this return.
		var drum := AuxReturnSync.get_pad_drum(channel)
		DeviceDropUtil.drop_on_drum_pad(drum.get_channel(), drum, channel.aux_pad_note, asset)
		return
	if _goes_to_source(src, front_size, at):
		var src_channel := src.get_channel()
		var added: DeviceInstance = DeviceDropUtil.instance_for_asset(asset, src_channel.id)
		if added:
			HistoryUtil.execute(DeviceAddCommand.new(src_channel, added, clampi(at, 0, src.children.size()), src))
		return
	var inst: DeviceInstance = DeviceDropUtil.instance_for_asset(asset, channel.id)
	if inst == null:
		return
	var target := lane.duplicate()
	target.insert(at, inst)
	HistoryUtil.execute_many("Add Device", commands(channel, target))


## Commands that turn the current lane into `target`. The source's devices must stay as they are
## at the front (they're edited through the source chain); only the return channel's part
## changes. Returns no commands when `target` touches the source's part.
static func commands(channel: Channel, target: Array[DeviceInstance], _has_pad := true) -> Array[Command]:
	var cmds: Array[Command] = []
	if not is_pad_lane(channel):
		return cmds
	var front := front_devices(channel)
	if target.slice(0, front.size()) != front:
		return cmds
	var new_rest: Array[DeviceInstance] = target.slice(front.size())
	var sim: Array[DeviceInstance] = channel.devices.duplicate()
	# Reorder what is already on the return channel, then insert any new device.
	var existing: Array[DeviceInstance] = []
	for d in new_rest:
		if sim.has(d):
			existing.append(d)
	for i in existing.size():
		var j := sim.find(existing[i])
		if j != i:
			cmds.append(DeviceMoveCommand.new(channel, j, i))
			sim.remove_at(j)
			sim.insert(i, existing[i])
	for i in new_rest.size():
		if not sim.has(new_rest[i]):
			cmds.append(DeviceAddCommand.new(channel, new_rest[i], i))
			sim.insert(i, new_rest[i])
	return cmds


## True when an asset dropped at lane index `at` goes into the source chain: among its devices, or
## at the front of an empty one.
static func _goes_to_source(src: DeviceInstance, front_size: int, at: int) -> bool:
	if src == null or not SlotChain.is_chain(src):
		return src == null and at == 0  # Empty pad: the front creates it.
	return at < front_size or (front_size == 0 and at == 0)


## `lane` with the device at `from` moved to insert index `at` (an index into the original lane).
static func _moved(lane: Array[DeviceInstance], from: int, at: int) -> Array[DeviceInstance]:
	var out := lane.duplicate()
	var d: DeviceInstance = out[from]
	out.remove_at(from)
	out.insert(at - 1 if from < at else at, d)
	return out


## Insert index for `index` (-1 = end).
static func _clamp_index(lane: Array[DeviceInstance], index: int) -> int:
	return lane.size() if index < 0 or index > lane.size() else index
