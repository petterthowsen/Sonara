# ChannelsBox.gd
# a horizontal list of MixerChannels; reordering happens on drop (see MixerChannelDropTarget.gd)
#
# see Mixer.gd where several ChannelsBox's are used within a HSplit.
class_name ChannelsBox extends HBoxContainer

var logger : Log = Log.make("ChannelsBox")

## When set, sibling order is stored on this parent's `child_channel_ids`.
var nest_parent: Channel = null


func add(mixer_channel: MixerChannel) -> void:
	"""Add a MixerChannel to this box."""
	add_child(mixer_channel)


## Persist mixer display order after a drop reorder.
func sync_channel_order() -> void:
	var nested_ids: Array[int] = []
	for i in get_child_count():
		var child := get_child(i)
		if child is MixerChannel and child.channel:
			child.channel.order = i
			nested_ids.append(child.channel.id)
	if nest_parent:
		nest_parent.child_channel_ids = nested_ids
