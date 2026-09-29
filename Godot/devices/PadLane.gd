# PadLane.gd
# Device chain of a drum pad's return channel, as the device lane and mixer strip show it:
# [pad chain][return channel devices...]. The pad chain is the Drum Machine's slot chain on the
# pad's note (see SlotChain); it gets the MIDI, and the device lane shows its devices in its open
# slot. It stays first: devices go into it through its slot, not by being dropped before it. The
# rest live on the return channel. Edits are expressed as a target lane and turned into undoable
# device commands. See docs/specs/001-multi-out-devices (REQ-015–019).
class_name PadLane extends RefCounted


## True when `channel` should be shown and edited as a pad lane.
static func is_pad_lane(channel: Channel) -> bool:
	return channel != null and AuxReturnSync.get_pad_drum(channel) != null


## Devices in lane order: the pad chain (if any), then the return channel's own devices.
static func devices(channel: Channel) -> Array[DeviceInstance]:
	var out: Array[DeviceInstance] = []
	var pad := AuxReturnSync.get_pad_device(channel)
	if pad:
		out.append(pad)
	out.append_array(channel.devices)
	return out


## Whether `data` may be dropped at lane index `index` (-1 = end). Dropping a device back where it
## is counts; `changes` tells it apart. Nothing lands before the pad chain or moves it; on an empty
## pad, an asset at the front becomes the pad's first device.
static func can_drop(channel: Channel, data: Variant, index: int) -> bool:
	if not is_pad_lane(channel):
		return false
	var lane := devices(channel)
	var at := _clamp_index(lane, index)
	var has_pad := AuxReturnSync.get_pad_device(channel) != null
	if has_pad and at == 0:
		return false
	if data is DeviceInstance:
		var from := lane.find(data)
		return from >= 0 and not (has_pad and from == 0) and not (not has_pad and at == 0)
	if not data is Asset:
		return false
	var asset := data as Asset
	if at == 0:
		return asset.type == Asset.TYPE.Device or asset.type == Asset.TYPE.SFZ or asset.type == Asset.TYPE.Audio
	return DeviceDropUtil.can_drop_asset_on_channel(channel, asset)


## Whether dropping `data` at lane index `index` (-1 = end) changes anything.
static func changes(channel: Channel, data: Variant, index: int) -> bool:
	if not can_drop(channel, data, index):
		return false
	if not data is DeviceInstance:
		return true
	var lane := devices(channel)
	return _moved(lane, lane.find(data), _clamp_index(lane, index)) != lane


## Add an asset or move a return channel device to lane index `index` (-1 = end), as one undo step.
static func drop(channel: Channel, data: Variant, index: int) -> void:
	if not changes(channel, data, index):
		return
	var lane := devices(channel)
	var at := _clamp_index(lane, index)
	var has_pad := AuxReturnSync.get_pad_device(channel) != null
	if data is DeviceInstance:
		HistoryUtil.execute_many("Move Device", commands(channel, _moved(lane, lane.find(data), at), has_pad))
		return
	var asset := data as Asset
	var drum := AuxReturnSync.get_pad_drum(channel)
	if at == 0:
		# Empty pad: the device goes into a new slot chain on the pad's note, which adopts this return.
		DeviceDropUtil.drop_on_drum_pad(drum.get_channel(), drum, channel.aux_pad_note, asset)
		return
	var inst: DeviceInstance = DeviceDropUtil.instance_for_asset(asset, channel.id)
	if inst == null:
		return
	var target := lane.duplicate()
	target.insert(at, inst)
	HistoryUtil.execute_many("Add Device", commands(channel, target, has_pad))


## Commands that turn the current lane into `target`. When `has_pad`, target[0] is the pad
## device; otherwise every device goes on the return channel.
static func commands(channel: Channel, target: Array[DeviceInstance], has_pad: bool) -> Array[Command]:
	var cmds: Array[Command] = []
	var drum := AuxReturnSync.get_pad_drum(channel)
	if drum == null:
		return cmds
	var drum_channel := drum.get_channel()
	var pad := AuxReturnSync.get_pad_device(channel)
	var new_pad: DeviceInstance = target[0] if has_pad and not target.is_empty() else null
	var new_rest: Array[DeviceInstance] = target.duplicate()
	if new_pad:
		new_rest.remove_at(0)

	# Simulated return-channel chain while the commands are built (move indices depend on it).
	var sim: Array[DeviceInstance] = channel.devices.duplicate()
	if pad and pad != new_pad:
		# Old pad device leaves the Drum Machine first, so its note is free for the new one.
		cmds.append(DeviceTransferCommand.new(pad, channel, null, 0))
		sim.insert(0, pad)
	if new_pad and new_pad != pad:
		if sim.has(new_pad):
			cmds.append(DeviceTransferCommand.new(new_pad, drum_channel, drum, -1, channel.aux_pad_note))
			sim.erase(new_pad)
		else:
			new_pad.slot_note = channel.aux_pad_note
			cmds.append(DeviceAddCommand.new(drum_channel, new_pad, -1, drum))

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
