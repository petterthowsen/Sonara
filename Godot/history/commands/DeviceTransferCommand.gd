# DeviceTransferCommand.gd
# Undoable move of a DeviceInstance to another channel and/or parent (keeps instance identity).
# Used by drum pad lanes, where the pad device lives in the Drum Machine on the parent channel
# and the rest of the lane on the return channel.
class_name DeviceTransferCommand extends Command

## Device being moved.
var device_instance: DeviceInstance = null

## Destination channel.
var to_channel: Channel = null

## Destination container (null = channel root).
var to_parent: DeviceInstance = null

## Index under the destination (-1 = append).
var to_position: int = -1

## Drum Machine note to assign at the destination (-1 = keep).
var to_note: int = -1

var _from_channel: Channel = null
var _from_parent: DeviceInstance = null
var _from_position: int = -1
var _from_note: int = -1


## Create a transfer-device command.
func _init(
	p_device: DeviceInstance = null,
	p_to_channel: Channel = null,
	p_to_parent: DeviceInstance = null,
	p_to_position: int = -1,
	p_to_note: int = -1
) -> void:
	name = "Move Device"
	device_instance = p_device
	to_channel = p_to_channel
	to_parent = p_to_parent
	to_position = p_to_position
	to_note = p_to_note


## Remove from the current channel/parent and add at the destination.
func do() -> void:
	if device_instance == null or to_channel == null:
		return
	_from_channel = device_instance.get_channel()
	_from_parent = device_instance.get_parent_device()
	_from_position = device_instance.position
	_from_note = device_instance.slot_note
	if _from_channel:
		_from_channel.remove_device_instance(device_instance)
	if to_note >= 0:
		device_instance.slot_note = to_note
	to_channel.add_device(device_instance, to_position, to_parent)


## Put the device back where it was.
func undo() -> void:
	if device_instance == null or to_channel == null or _from_channel == null:
		return
	to_channel.remove_device_instance(device_instance)
	device_instance.slot_note = _from_note
	_from_channel.add_device(device_instance, _from_position, _from_parent)
