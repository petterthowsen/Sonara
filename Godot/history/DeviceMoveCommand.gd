# DeviceMoveCommand.gd
# Undoable reorder of a device within a Channel root list or a container parent.
class_name DeviceMoveCommand extends Command

## Channel whose device chain is reordered.
var channel: Channel = null

## Position before the move.
var from_position: int = -1

## Position after the move.
var to_position: int = -1

## Container parent, or null to reorder at the channel root.
var parent: DeviceInstance = null


## Create a move-device command.
func _init(
	p_channel: Channel = null,
	p_from: int = -1,
	p_to: int = -1,
	p_parent: DeviceInstance = null
) -> void:
	name = "Reorder Device"
	channel = p_channel
	from_position = p_from
	to_position = p_to
	parent = p_parent


## Move device from from_position to to_position.
func do() -> void:
	if channel == null:
		return
	channel.move_device(from_position, to_position, parent)


## Move device back from to_position to from_position.
func undo() -> void:
	if channel == null:
		return
	channel.move_device(to_position, from_position, parent)
