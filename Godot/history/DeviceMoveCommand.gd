# DeviceMoveCommand.gd
# Undoable reorder of a device within a Channel's device chain.
class_name DeviceMoveCommand extends Command

## Channel whose device chain is reordered.
var channel: Channel = null

## Position before the move.
var from_position: int = -1

## Position after the move.
var to_position: int = -1


## Create a move-device command.
func _init(
	p_channel: Channel = null,
	p_from: int = -1,
	p_to: int = -1
) -> void:
	name = "Reorder Device"
	channel = p_channel
	from_position = p_from
	to_position = p_to


## Move device from from_position to to_position.
func do() -> void:
	if channel == null:
		return
	channel.move_device(from_position, to_position)


## Move device back from to_position to from_position.
func undo() -> void:
	if channel == null:
		return
	channel.move_device(to_position, from_position)
