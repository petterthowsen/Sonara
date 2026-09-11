# DeviceAddCommand.gd
# Undoable addition of a DeviceInstance to a Channel (keeps instance identity).
class_name DeviceAddCommand extends Command

## Channel that receives the device.
var channel: Channel = null

## Device instance being added.
var device_instance: DeviceInstance = null

## Insertion position (-1 = append).
var position: int = -1


## Create an add-device command.
func _init(
	p_channel: Channel = null,
	p_device: DeviceInstance = null,
	p_position: int = -1
) -> void:
	name = "Add Device"
	channel = p_channel
	device_instance = p_device
	position = p_position


## Add the device at the stored position.
func do() -> void:
	if channel == null or device_instance == null:
		return
	channel.add_device(device_instance, position)


## Remove the device by its current position in the chain.
func undo() -> void:
	if channel == null or device_instance == null:
		return
	var idx := channel.devices.find(device_instance)
	if idx >= 0:
		channel.remove_device(idx)
