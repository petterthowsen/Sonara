# DeviceDropUtil.gd
# Shared drop rules for adding/reordering devices on a channel or inside a container.
class_name DeviceDropUtil extends RefCounted


## Whether this asset can be added to the channel (device or SFZ).
static func can_drop_asset_on_channel(channel: Channel, asset: Asset) -> bool:
	if channel == null or asset == null:
		return false
	if asset.type == Asset.TYPE.SFZ:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT
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


## Drop onto a container device itself (append a child).
static func can_drop_on_container(channel: Channel, container: DeviceInstance, data: Variant) -> bool:
	if channel == null or container == null or not container.is_container():
		return false
	if data is DeviceInstance:
		return can_drop_instance_on_host(channel, data, container)
	if data is Asset:
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
