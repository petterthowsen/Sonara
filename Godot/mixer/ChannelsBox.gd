# ChannelsBox.gd
# a horizontal list of MixerChannels that can be freely reordered
#
# see Mixer.gd where several ChannelsBox's are used within a HSplit.
class_name ChannelsBox extends HBoxContainer

## When set, sibling order is stored on this parent's `child_channel_ids`.
var nest_parent: Channel = null


func add(mixer_channel: MixerChannel) -> void:
	"""Add a MixerChannel to this box and connect its move signal."""
	add_child(mixer_channel)
	mixer_channel.request_move.connect(_on_channel_request_move.bind(mixer_channel))


func _on_channel_request_move(new_index: int, channel_item: MixerChannel) -> void:
	"""Handle drag-to-move request from a MixerChannel.
	All channels within a ChannelsBox can be freely reordered."""

	# Get the current position in the container
	var current_child_index = channel_item.get_index()

	# Clamp to valid range (all children are MixerChannels, so simple bounds check)
	var max_index = get_child_count() - 1
	var clamped_index = clampi(new_index, 0, max_index)

	# Don't move if the index hasn't changed
	if clamped_index == current_child_index:
		return

	# Move the child to the new position
	move_child(channel_item, clamped_index)
	_sync_channel_order()
	print("[ChannelsBox] Moved channel from position ", current_child_index, " to ", clamped_index)


## Persist mixer display order after a live reorder.
func _sync_channel_order() -> void:
	var nested_ids: Array[int] = []
	for i in get_child_count():
		var child := get_child(i)
		if child is MixerChannel and child.channel:
			child.channel.order = i
			nested_ids.append(child.channel.id)
	if nest_parent:
		nest_parent.child_channel_ids = nested_ids
