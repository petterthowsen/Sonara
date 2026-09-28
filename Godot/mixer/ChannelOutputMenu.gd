class_name ChannelOutputMenu

## Builds a channel's output-routing popup and label. Shared by the mixer strip's
## output button and the arranger TrackItem's IO button so both list the same targets.


## Fill `popup` with `channel`'s route choices, the current one checked. Master lists the
## running device's output pairs; other channels list Master plus valid BUS/GROUP targets.
## Item ids are the ids `apply()` expects.
static func populate(popup: PopupMenu, channel: Channel, project: Project) -> void:
	popup.clear()
	if channel == null or project == null:
		return

	if channel.is_master:
		_populate_device_outputs(popup, channel)
		return

	popup.add_check_item("Master", 1)
	popup.set_item_checked(popup.item_count - 1, channel.output_channel_id == 1)
	popup.add_separator()
	for ch in project.channels:
		if is_valid_route_target(channel, ch, project):
			popup.add_check_item(ch.name, ch.id)
			popup.set_item_checked(popup.item_count - 1, channel.output_channel_id == ch.id)


## Apply a popup selection from `populate()` to `channel`.
static func apply(channel: Channel, item_id: int) -> void:
	if channel == null or channel.route_locked():
		return
	if channel.is_master:
		channel.set_device_output(item_id)
	else:
		channel.set_route(item_id)


## True when `channel` may route to `target` (BUS or GROUP, no cycles).
static func is_valid_route_target(channel: Channel, target: Channel, project: Project) -> bool:
	if target == null or channel == null or project == null:
		return false
	if target.id == channel.id or target.is_master:
		return false
	if target.channel_type != Channel.ChannelType.BUS and target.channel_type != Channel.ChannelType.GROUP:
		return false
	if project.channel_is_in_subtree(target.id, channel):
		return false
	return true


## Name of `channel`'s current output: a device pair for master, else the target channel.
static func label(channel: Channel, project: Project) -> String:
	if channel == null or project == null:
		return "Output"
	if channel.is_master:
		return AudioConfig.output_label(channel.device_output_id)
	if channel.output_channel_id == 1:
		return "Master"
	var target := project.get_channel_by_id(channel.output_channel_id)
	return target.name if target else "Unknown"


## Master's choices: the stereo output pairs of the running audio device (AudioConfig). A saved
## pair the device lacks stays listed, marked, and plays on 1/2 until a device has it.
static func _populate_device_outputs(popup: PopupMenu, channel: Channel) -> void:
	var pairs := AudioConfig.output_pairs()
	for pair in pairs:
		var output_id := AudioConfig.HARDWARE_OUTPUT_BASE + pair
		popup.add_check_item(AudioConfig.output_label(output_id), output_id)
		if channel.device_output_id == output_id:
			popup.set_item_checked(popup.get_item_count() - 1, true)
	var current := channel.device_output_id
	if current >= AudioConfig.HARDWARE_OUTPUT_BASE + pairs:
		popup.add_check_item("%s (not on this device)" % AudioConfig.output_label(current), current)
		popup.set_item_checked(popup.get_item_count() - 1, true)
