# SendAddCommand.gd
# Undoable Channel.add_send / remove_send.
class_name SendAddCommand extends Command


var channel: Channel = null
var target_channel_id: int = -1
var amount_db: float = -12.0
var pre_fader: bool = false


## Create an add-send command.
func _init(
	p_channel: Channel = null,
	p_target: int = -1,
	p_amount: float = -12.0,
	p_pre: bool = false
) -> void:
	name = "Add Send"
	channel = p_channel
	target_channel_id = p_target
	amount_db = p_amount
	pre_fader = p_pre


## Add the send if it is not already present.
func do() -> void:
	if channel == null:
		return
	channel.add_send(target_channel_id, amount_db, pre_fader)


## Remove the send.
func undo() -> void:
	if channel == null:
		return
	channel.remove_send(target_channel_id)
