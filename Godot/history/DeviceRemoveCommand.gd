# DeviceRemoveCommand.gd
# Undoable removal of a DeviceInstance from a Channel (keeps instance identity).
class_name DeviceRemoveCommand extends Command

## Channel the device was removed from.
var channel: Channel = null

## Device instance kept for re-add on undo.
var device_instance: DeviceInstance = null

## Position it occupied when removed.
var position: int = -1

## Container parent at removal time, or null at the channel root.
var parent: DeviceInstance = null


## Create a remove-device command. Captures position/parent from the instance if not given.
func _init(
	p_channel: Channel = null,
	p_device: DeviceInstance = null,
	p_position: int = -1,
	p_parent: DeviceInstance = null
) -> void:
	name = "Remove Device"
	channel = p_channel
	device_instance = p_device
	position = p_position
	parent = p_parent
	if device_instance != null:
		if parent == null:
			parent = device_instance.get_parent_device()
		if position < 0:
			if parent:
				position = parent.children.find(device_instance)
			elif channel:
				position = channel.devices.find(device_instance)


## Remove the device from the channel.
func do() -> void:
	if channel == null or device_instance == null:
		return
	parent = device_instance.get_parent_device()
	var host: Array[DeviceInstance] = parent.children if parent else channel.devices
	var idx := host.find(device_instance)
	if idx < 0:
		idx = position
	if idx >= 0:
		position = idx
		channel.remove_device(idx, parent)


## Re-add the same device instance at the stored position.
func undo() -> void:
	if channel == null or device_instance == null:
		return
	channel.add_device(device_instance, position, parent)
