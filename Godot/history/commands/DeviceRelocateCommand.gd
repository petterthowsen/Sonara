# DeviceRelocateCommand.gd
# Undoable move of a DeviceInstance into or out of a container on the same channel.
class_name DeviceRelocateCommand extends Command

## Channel that owns the device.
var channel: Channel = null

## Device being relocated (identity preserved).
var device_instance: DeviceInstance = null

## Parent before the move (null = channel root).
var from_parent: DeviceInstance = null

## Index in from_parent (or root) before the move.
var from_position: int = -1

## Parent after the move (null = channel root).
var to_parent: DeviceInstance = null

## Index in to_parent (or root) after the move (-1 = append).
var to_position: int = -1


## Create a relocate-device command.
func _init(
	p_channel: Channel = null,
	p_device: DeviceInstance = null,
	p_to_parent: DeviceInstance = null,
	p_to_position: int = -1
) -> void:
	name = "Move Device"
	channel = p_channel
	device_instance = p_device
	to_parent = p_to_parent
	to_position = p_to_position
	if device_instance != null:
		from_parent = device_instance.get_parent_device()
		from_position = device_instance.position


## Remove from the current parent and insert under the destination parent.
func do() -> void:
	if channel == null or device_instance == null:
		return
	from_parent = device_instance.get_parent_device()
	from_position = device_instance.position
	channel.remove_device_instance(device_instance)
	channel.add_device(device_instance, to_position, to_parent)


## Restore the device under its original parent.
func undo() -> void:
	if channel == null or device_instance == null:
		return
	channel.remove_device_instance(device_instance)
	channel.add_device(device_instance, from_position, from_parent)
