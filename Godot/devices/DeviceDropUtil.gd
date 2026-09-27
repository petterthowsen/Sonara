# DeviceDropUtil.gd
# Shared drop rules for adding/reordering devices on a channel or inside a container.
# Drag data may be a DeviceDrag, a DeviceInstance or an Asset; DeviceDrag is unwrapped here.
# Every drop target (device lane, mixer strip, compact list, container folder, drum pad,
# AI tools) goes through these so they accept and do the same thing.
# Drops are synchronous: files for new devices are queued on the instance and loaded by
# Channel.add_device() right after the engine is told to create the device.
class_name DeviceDropUtil extends RefCounted

const SFIZZ_ID := "sonara.builtin.sfizz"
const SAMPLER_ID := "sonara.builtin.sampler"
const DRUM_MACHINE_ID := "sonara.builtin.drum_machine"


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
	return device_fits_channel(AssetService.get_device(asset.path), channel)


## Instruments only go on instrument channels (master keeps the default INSTRUMENT type, so it is
## excluded by id); effects and containers go anywhere, master included.
static func device_fits_channel(device: Device, channel: Channel) -> bool:
	if device == null or channel == null:
		return false
	if device.category == Device.DeviceCategory.Instrument:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT and not channel.is_master
	return true


## Whether `inst` can be inserted into `host_parent` (null = channel root).
static func can_drop_instance_on_host(
	channel: Channel,
	inst: DeviceInstance,
	host_parent: DeviceInstance
) -> bool:
	if channel == null or inst == null:
		return false
	if inst.channel_id != channel.id and not can_transfer_to_channel(inst, channel):
		return false
	if host_parent == null:
		return true
	if inst == host_parent:
		return false
	if inst.contains_device(host_parent):
		return false
	return true


## Whether `inst` can move from its channel to `channel`. Devices that own aux return channels
## (Drum Machine, multi-out plugins) and drum pads stay put: removing them detaches their returns.
static func can_transfer_to_channel(inst: DeviceInstance, channel: Channel) -> bool:
	if channel == null or not can_leave_channel(inst) or inst.get_channel() == channel:
		return false
	return device_fits_channel(inst.device, channel)


## Whether `inst` may be moved off its channel at all (see can_transfer_to_channel).
static func can_leave_channel(inst: DeviceInstance) -> bool:
	if inst == null or inst.get_channel() == null:
		return false
	if PadLane.is_pad_lane(inst.get_channel()) or AuxReturnSync.is_drum_machine(inst.get_parent_device()):
		return false
	return not _owns_aux_returns(inst)


## True when `inst` or a descendant is a Drum Machine or has plugin return channels.
static func _owns_aux_returns(inst: DeviceInstance) -> bool:
	if AuxReturnSync.is_drum_machine(inst) or not inst.return_channel_ids.is_empty():
		return true
	for child in inst.children:
		if _owns_aux_returns(child):
			return true
	return false


## Add a device or sfizz+SFZ asset into `parent` (null = channel root).
static func drop_asset(
	channel: Channel,
	asset: Asset,
	position: int,
	parent: DeviceInstance
) -> void:
	if channel == null or asset == null:
		return
	if asset.type == Asset.TYPE.Audio and _is_drum_machine(parent):
		drop_on_drum_pad(channel, parent, parent.next_free_drum_note(), asset)
		return
	var device_instance := instance_for_asset(asset, channel.id, position)
	if device_instance:
		HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, position, parent))


## New instance for a Device asset, or an sfizz instance with the SFZ queued. Null for other assets.
static func instance_for_asset(asset: Asset, channel_id: int, position: int = -1) -> DeviceInstance:
	if asset == null:
		return null
	var device_id := ""
	match asset.type:
		Asset.TYPE.SFZ:
			device_id = SFIZZ_ID
		Asset.TYPE.Device:
			device_id = asset.path
		_:
			return null
	var device := AssetService.get_device(device_id)
	if device == null:
		push_error("[DeviceDropUtil] Failed to get device: %s" % device_id)
		return null
	var device_instance := DeviceInstance.new(device, channel_id, position)
	if asset.type == Asset.TYPE.SFZ:
		device_instance.queue_file_load(asset.path)
	return device_instance


## Kind of channel a device drop on empty mixer space creates: "instrument" or "audio" track on the
## track side, "bus" on the bus side, or "" when `data` can't start a channel there. Instruments
## and containers (and SFZ files) make instrument tracks; effects make audio tracks or buses.
static func new_channel_kind(data: Variant, bus_side: bool) -> String:
	data = DeviceDrag.unwrap(data)
	var device: Device = null
	if data is DeviceInstance:
		if not can_leave_channel(data):
			return ""
		device = (data as DeviceInstance).device
	elif data is Asset:
		var asset := data as Asset
		if asset.type == Asset.TYPE.SFZ:
			return "" if bus_side else "instrument"
		if asset.type == Asset.TYPE.Device:
			device = AssetService.get_device(asset.path)
	if device == null:
		return ""
	if device.creates_instrument_track():
		return "" if bus_side else "instrument"
	return "bus" if bus_side else "audio"


## Create the channel `new_channel_kind` names (track or bus, named after the device) and add the
## asset's device to it, or move the dragged device there. One undo step. Returns the channel.
## `parent_id` >= -1 places the new track under that parent (-1 = root) after `after_sibling`
## (null = first); the default -2 leaves it where the project puts new tracks.
static func create_channel_for(
	project: Project,
	data: Variant,
	bus_side: bool,
	parent_id: int = -2,
	after_sibling: Track = null
) -> Channel:
	var kind := new_channel_kind(data, bus_side)
	if project == null or kind.is_empty():
		return null
	data = DeviceDrag.unwrap(data)
	var channel_name := _channel_name_for(data)
	var create: Command
	if kind == "bus":
		create = BusCreateCommand.new(project, channel_name)
	else:
		create = TrackCreateCommand.new(project, kind, channel_name)
	create.do()
	var channel: Channel = create.get("channel")
	if channel == null:
		push_error("[DeviceDropUtil] Failed to create a %s channel for %s" % [kind, channel_name])
		return null
	var cmds: Array[Command] = [create]
	var track: Track = create.get("track") if kind != "bus" else null
	if track and parent_id >= -1:
		var before := TrackReorderCommand.capture_layout(project)
		if project.place_track(track, parent_id, after_sibling):
			cmds.append(TrackReorderCommand.new(project, before, TrackReorderCommand.capture_layout(project)))
	var place: Command = null
	if data is DeviceInstance:
		place = DeviceTransferCommand.new(data, channel, null, -1)
	else:
		var device_instance := instance_for_asset(data, channel.id, 0)
		if device_instance:
			place = DeviceAddCommand.new(channel, device_instance, -1)
	if place:
		place.do()
		cmds.append(place)
	HistoryUtil.record_many(create.name, cmds)
	return channel


static func _channel_name_for(data: Variant) -> String:
	if data is DeviceInstance:
		return (data as DeviceInstance).get_display_name()
	return _track_name_for(data)


## Device name for a Device asset, file name for an SFZ.
static func _track_name_for(asset: Asset) -> String:
	if asset.type == Asset.TYPE.Device:
		var device := AssetService.get_device(asset.path)
		if device:
			return device.name
	return asset.name


## Reorder within `to_parent`, relocate from another parent on the same channel, or move from
## another channel.
static func drop_instance(
	channel: Channel,
	inst: DeviceInstance,
	to_parent: DeviceInstance,
	to_position: int
) -> void:
	if not can_drop_instance_on_host(channel, inst, to_parent):
		return
	if inst.get_channel() != channel:
		HistoryUtil.execute(DeviceTransferCommand.new(inst, channel, to_parent, to_position))
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


## Whether `data` can be dropped onto the device panel for `inst`: a child for a container, or a file to load.
static func can_drop_on_device(inst: DeviceInstance, data: Variant) -> bool:
	data = DeviceDrag.unwrap(data)
	if inst == null:
		return false
	if inst.is_container() and can_drop_on_container(inst.get_channel(), inst, data):
		return true
	return data is Asset and can_drop_file_on_device(inst, data)


## Drop `data` onto the device panel for `inst`. Returns true when it was added into the container.
static func drop_on_device(inst: DeviceInstance, data: Variant) -> bool:
	data = DeviceDrag.unwrap(data)
	if inst == null:
		return false
	var channel := inst.get_channel()
	if inst.is_container() and can_drop_on_container(channel, inst, data):
		drop_on_container(channel, inst, data)
		return true
	if data is Asset and can_drop_file_on_device(inst, data):
		inst.load_file((data as Asset).path)
	return false


## Drop onto a container device itself (append a child).
static func can_drop_on_container(channel: Channel, container: DeviceInstance, data: Variant) -> bool:
	data = DeviceDrag.unwrap(data)
	if channel == null or container == null or not container.is_container():
		return false
	if data is DeviceInstance:
		return can_drop_instance_on_host(channel, data, container)
	if data is Asset:
		if data.type == Asset.TYPE.Audio and _is_drum_machine(container):
			return channel.channel_type == Channel.ChannelType.INSTRUMENT
		return can_drop_asset_on_channel(channel, data)
	return false


## Append `data` as a child of `container`.
static func drop_on_container(
	channel: Channel,
	container: DeviceInstance,
	data: Variant
) -> void:
	data = DeviceDrag.unwrap(data)
	if not can_drop_on_container(channel, container, data):
		return
	if data is DeviceInstance:
		drop_instance(channel, data, container, -1)
		return
	if data is Asset:
		drop_asset(channel, data, -1, container)


static func _is_drum_machine(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.device_id == DRUM_MACHINE_ID


## Whether `data` can land on a drum pad (empty, occupied file-load, or pad-to-pad move/swap).
static func can_drop_on_drum_pad(
	data: Variant,
	occupied: DeviceInstance,
	channel: Channel = null,
	container: DeviceInstance = null
) -> bool:
	data = DeviceDrag.unwrap(data)
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
	data: Variant
) -> void:
	if channel == null or container == null:
		return
	data = DeviceDrag.unwrap(data)
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
	var device_instance: DeviceInstance = null
	if asset.type == Asset.TYPE.Audio:
		device_instance = _sampler_for(asset, channel.id)
	else:
		device_instance = instance_for_asset(asset, channel.id)
	if device_instance == null:
		return
	device_instance.slot_note = note
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, -1, container))


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


## New sampler instance with the audio `asset` queued for loading.
static func _sampler_for(asset: Asset, channel_id: int) -> DeviceInstance:
	var sampler_device := AssetService.get_device(SAMPLER_ID)
	if sampler_device == null:
		push_error("[DeviceDropUtil] Failed to get sampler device")
		return null
	var device_instance := DeviceInstance.new(sampler_device, channel_id, -1)
	device_instance.queue_file_load(asset.path)
	return device_instance
