# DeviceDropUtil.gd
# Shared drop rules for adding/reordering devices on a channel or inside a container.
class_name DeviceDropUtil extends RefCounted


## Whether this asset can be added to the channel (device, SFZ, or audio-into-drum).
static func can_drop_asset_on_channel(channel: Channel, asset: Asset) -> bool:
	if channel == null or asset == null:
		return false
	if asset.type == Asset.TYPE.SFZ:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT
	if asset.type == Asset.TYPE.Audio:
		return false
	if asset.type != Asset.TYPE.Device:
		return false
	var device := AssetService.get_device(asset.path)
	if device == null:
		return false
	if device.category == Device.DeviceCategory.Instrument:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT
	return not channel.is_master


## Whether `inst` can be inserted into `host_parent` (null = channel root).
static func can_drop_instance_on_host(
	channel: Channel,
	inst: DeviceInstance,
	host_parent: DeviceInstance
) -> bool:
	if channel == null or inst == null:
		return false
	if inst.channel_id != channel.id:
		return false
	if host_parent == null:
		return true
	if inst == host_parent:
		return false
	if inst.contains_device(host_parent):
		return false
	return true


## Add a device or sfizz+SFZ asset into `parent` (null = channel root).
static func drop_asset(
	channel: Channel,
	asset: Asset,
	position: int,
	parent: DeviceInstance,
	tree: SceneTree
) -> void:
	if channel == null or asset == null:
		return
	if asset.type == Asset.TYPE.SFZ:
		await _drop_sfz(channel, asset, position, parent, tree)
		return
	if asset.type == Asset.TYPE.Audio and parent and parent.device and parent.device.device_id == "sonara.builtin.drum_machine":
		await drop_on_drum_pad(channel, parent, parent.next_free_drum_note(), asset, tree)
		return
	if asset.type != Asset.TYPE.Device:
		return
	var device := AssetService.get_device(asset.path)
	if device == null:
		push_error("[DeviceDropUtil] Failed to get device: %s" % asset.path)
		return
	var device_instance := DeviceInstance.new(device, channel.id, position)
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, position, parent))


## Reorder within `to_parent`, or relocate from another parent on the same channel.
static func drop_instance(
	channel: Channel,
	inst: DeviceInstance,
	to_parent: DeviceInstance,
	to_position: int
) -> void:
	if not can_drop_instance_on_host(channel, inst, to_parent):
		return
	var from_parent := inst.get_parent_device()
	var from_position := inst.position
	if from_parent == to_parent:
		var host: Array[DeviceInstance] = to_parent.children if to_parent else channel.devices
		var dest := to_position
		if dest < 0 or dest > host.size():
			dest = host.size()
		if from_position < dest:
			dest -= 1
		if from_position != dest and dest >= 0:
			HistoryUtil.execute(DeviceMoveCommand.new(channel, from_position, dest, to_parent))
		return
	HistoryUtil.execute(DeviceRelocateCommand.new(channel, inst, to_parent, to_position))


## True when `path`'s extension is in the device's advertised file-loading list.
static func extension_matches_device(device: Device, path: String) -> bool:
	if device == null or path.is_empty():
		return false
	var ext := "." + path.get_extension().to_lower()
	for e in device.supported_file_extensions:
		if str(e).to_lower() == ext:
			return true
	return false


## True when `asset` can be loaded into `inst` via load_file.
static func can_drop_file_on_device(inst: DeviceInstance, asset: Asset) -> bool:
	if inst == null or asset == null or inst.device == null:
		return false
	if not inst.device.supports_file_loading:
		return false
	if asset.type == Asset.TYPE.SFZ:
		return true
	if asset.type == Asset.TYPE.Audio:
		return extension_matches_device(inst.device, asset.path)
	return false


## Depth-first search for a file-loading device (the instance itself or a descendant).
static func find_file_loading_descendant(inst: DeviceInstance) -> DeviceInstance:
	if inst == null:
		return null
	if inst.device and inst.device.supports_file_loading:
		return inst
	for child in inst.children:
		var found := find_file_loading_descendant(child)
		if found:
			return found
	return null


## Drop onto a container device itself (append a child).
static func can_drop_on_container(channel: Channel, container: DeviceInstance, data: Variant) -> bool:
	if channel == null or container == null or not container.is_container():
		return false
	if data is DeviceInstance:
		return can_drop_instance_on_host(channel, data, container)
	if data is Asset:
		if data.type == Asset.TYPE.Audio and container.device and container.device.device_id == "sonara.builtin.drum_machine":
			return channel.channel_type == Channel.ChannelType.INSTRUMENT
		return can_drop_asset_on_channel(channel, data)
	return false


## Append `data` as a child of `container`.
static func drop_on_container(
	channel: Channel,
	container: DeviceInstance,
	data: Variant,
	tree: SceneTree
) -> void:
	if not can_drop_on_container(channel, container, data):
		return
	if data is DeviceInstance:
		drop_instance(channel, data, container, -1)
		return
	if data is Asset:
		if data.type == Asset.TYPE.Audio and container.device and container.device.device_id == "sonara.builtin.drum_machine":
			await drop_on_drum_pad(channel, container, container.next_free_drum_note(), data, tree)
			return
		await drop_asset(channel, data, -1, container, tree)


static func _drop_sfz(
	channel: Channel,
	asset: Asset,
	position: int,
	parent: DeviceInstance,
	tree: SceneTree
) -> void:
	var sfizz_device := AssetService.get_device("sonara.builtin.sfizz")
	if sfizz_device == null:
		push_error("[DeviceDropUtil] Failed to get sfizz device")
		return
	var device_instance := DeviceInstance.new(sfizz_device, channel.id, position)
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, position, parent))
	if tree:
		await tree.create_timer(0.1).timeout
		device_instance.load_file(asset.path)
	else:
		device_instance.load_file(asset.path)


## Whether `data` can land on a drum pad (empty, occupied file-load, or pad-to-pad move/swap).
static func can_drop_on_drum_pad(
	data: Variant,
	occupied: DeviceInstance,
	channel: Channel = null,
	container: DeviceInstance = null
) -> bool:
	if data is DeviceInstance:
		var inst := data as DeviceInstance
		if inst == occupied:
			return false
		if channel != null and container != null:
			return can_drop_instance_on_host(channel, inst, container)
		return true
	if not data is Asset:
		return false
	var asset := data as Asset
	if occupied:
		var target := find_file_loading_descendant(occupied)
		return can_drop_file_on_device(target, asset)
	if asset.type == Asset.TYPE.Audio or asset.type == Asset.TYPE.SFZ or asset.type == Asset.TYPE.Device:
		return true
	return false


## Drop a sample or device onto a drum-machine pad with MIDI `note`.
static func drop_on_drum_pad(
	channel: Channel,
	container: DeviceInstance,
	note: int,
	data: Variant,
	tree: SceneTree
) -> void:
	if channel == null or container == null:
		return
	var occupied := _child_for_note(container, note)
	if data is DeviceInstance:
		_drop_instance_on_drum_pad(channel, container, note, data, occupied)
		return
	if not data is Asset:
		return
	var asset := data as Asset
	if occupied:
		var target := find_file_loading_descendant(occupied)
		if can_drop_file_on_device(target, asset):
			target.load_file(asset.path)
		return
	if asset.type == Asset.TYPE.Audio:
		await _drop_sampler_on_pad(channel, container, note, asset, tree)
		return
	await drop_asset(channel, asset, -1, container, tree)
	var added := _child_for_note(container, note)
	if added == null and not container.children.is_empty():
		added = container.children[container.children.size() - 1]
	if added:
		added.set_slot_note(note)


## Move `inst` onto `note`, swapping with `occupied` when that pad already has a child.
static func _drop_instance_on_drum_pad(
	channel: Channel,
	container: DeviceInstance,
	note: int,
	inst: DeviceInstance,
	occupied: DeviceInstance
) -> void:
	if inst == null or inst == occupied:
		return
	if not can_drop_instance_on_host(channel, inst, container):
		return
	var from_parent := inst.get_parent_device()
	if from_parent == container:
		if occupied:
			_swap_drum_notes(container, inst, occupied)
		else:
			HistoryUtil.execute_property("Move Drum Pad", inst, "set_slot_note", inst.slot_note, note)
		return
	if occupied:
		return
	inst.slot_note = note
	drop_instance(channel, inst, container, -1)
	inst.set_slot_note(note)


## Swap two drum-machine children's notes via a free temp note (engine notes are unique).
static func _swap_drum_notes(container: DeviceInstance, a: DeviceInstance, b: DeviceInstance) -> void:
	if a == null or b == null or a == b:
		return
	var a_note := a.slot_note
	var b_note := b.slot_note
	if a_note == b_note:
		return
	var temp := container.next_free_drum_note()
	var cmds: Array[Command] = []
	cmds.append(PropertyCommand.new("Move Drum Pad", a, "set_slot_note", a_note, temp))
	cmds.append(PropertyCommand.new("Move Drum Pad", b, "set_slot_note", b_note, a_note))
	cmds.append(PropertyCommand.new("Move Drum Pad", a, "set_slot_note", temp, b_note))
	HistoryUtil.execute(MacroCommand.new("Swap Drum Pads", cmds))


## Find the child assigned to MIDI `note`, or null if the pad is empty.
static func _child_for_note(container: DeviceInstance, note: int) -> DeviceInstance:
	if container == null:
		return null
	for child in container.children:
		if child.slot_note == note:
			return child
	return null


## Add a sampler on `note` and load `asset` into it.
static func _drop_sampler_on_pad(
	channel: Channel,
	container: DeviceInstance,
	note: int,
	asset: Asset,
	tree: SceneTree
) -> void:
	var sampler_device := AssetService.get_device("sonara.builtin.sampler")
	if sampler_device == null:
		push_error("[DeviceDropUtil] Failed to get sampler device")
		return
	var device_instance := DeviceInstance.new(sampler_device, channel.id, -1)
	device_instance.slot_note = note
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, -1, container))
	if tree:
		await tree.create_timer(0.1).timeout
	device_instance.load_file(asset.path)
