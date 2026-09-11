# DeviceRemoveCommand.gd
# Undoable removal of a DeviceInstance from a Channel (keeps instance identity).
class_name DeviceRemoveCommand extends Command

## Channel the device was removed from.
var channel: Channel = null

## Device instance kept for re-add on undo.
var device_instance: DeviceInstance = null

## Position it occupied when removed.
var position: int = -1


## Create a remove-device command. Captures position from the instance if not given.
func _init(
	p_channel: Channel = null,
	p_device: DeviceInstance = null,
	p_position: int = -1
) -> void:
	name = "Remove Device"
	channel = p_channel
	device_instance = p_device
	position = p_position
	if position < 0 and channel != null and device_instance != null:
		position = channel.devices.find(device_instance)


## Remove the device from the channel.
func do() -> void:
	if channel == null or device_instance == null:
		return
	var idx := channel.devices.find(device_instance)
	if idx < 0:
		idx = position
	if idx >= 0:
		position = idx
		channel.remove_device(idx)


## Re-add the same device instance at the stored position.
func undo() -> void:
	if channel == null or device_instance == null:
		return
	channel.add_device(device_instance, position)
