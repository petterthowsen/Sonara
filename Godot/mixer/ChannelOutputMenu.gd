class_name ChannelOutputMenu

## Builds a channel's output-routing popup and label. Shared by the mixer strip's
## output button and the arranger TrackItem's IO button so both list the same targets.

## Fill `popup` with `channel`'s route choices, the current one checked. Master and every other
## channel list the running device's output pairs (a straight-to-hardware route skips master's
## effects, e.g. a reference track); other channels additionally list Master plus valid
## BUS/GROUP targets. Item ids are the ids `apply()` expects.
static func populate(popup: PopupMenu, channel: Channel, project: Project) -> void:
	popup.clear()
	if channel == null or project == null:
		return

	if channel.is_master:
		_populate_device_outputs(popup, channel.device_output_id)
		return

	popup.add_check_item("Master", 1)
	popup.set_item_checked(popup.item_count - 1, channel.output_channel_id == 1)
	popup.add_separator()
	for ch in project.channels:
		if is_valid_route_target(channel, ch, project):
			popup.add_check_item(ch.name, ch.id)
			popup.set_item_checked(popup.item_count - 1, channel.output_channel_id == ch.id)
		elif _closes_loop(channel, ch, project):
			# Listed but disabled, so the missing choice explains itself.
			popup.add_check_item(ch.name, ch.id)
			popup.set_item_disabled(popup.item_count - 1, true)
			popup.set_item_tooltip(popup.item_count - 1, LOOP_TOOLTIP % ch.name)
	popup.add_separator()
	_populate_device_outputs(popup, channel.output_channel_id)

static func apply(channel: Channel, item_id: int) -> void:
	if channel == null or channel.route_locked():
		return
	if channel.is_master:
		channel.set_device_output(item_id)
	else:
		channel.set_route(item_id)


## Tooltip for a route or send target whose audio already comes back to the channel.
const LOOP_TOOLTIP := "Would create a feedback loop: %s already feeds this channel"


## True when `channel` may route to `target`: a BUS or GROUP outside its own subtree whose
## routes and sends don't lead back to `channel` (no loops).
static func is_valid_route_target(channel: Channel, target: Channel, project: Project) -> bool:
	return _is_route_candidate(channel, target, project) and not project.feeds_into(target.id, channel.id)


## True when `channel` may start a send to `target`: a BUS other than itself whose routes and
## sends don't lead back to `channel`. An existing send stays editable.
static func is_valid_send_target(channel: Channel, target: Channel, project: Project) -> bool:
	if target == null or channel == null or project == null:
		return false
	if target.id == channel.id or target.channel_type != Channel.ChannelType.BUS:
		return false
	if channel.get_send(target.id) != null:
		return true
	return not project.feeds_into(target.id, channel.id)


## True when `target` would be a valid route but for a loop back to `channel`.
static func _closes_loop(channel: Channel, target: Channel, project: Project) -> bool:
	return _is_route_candidate(channel, target, project) and project.feeds_into(target.id, channel.id)


## Structural route rules: a BUS or GROUP other than `channel`, not master, not in its subtree.
static func _is_route_candidate(channel: Channel, target: Channel, project: Project) -> bool:
	if target == null or channel == null or project == null:
		return false
	if target.id == channel.id or target.is_master:
		return false
	if target.channel_type != Channel.ChannelType.BUS and target.channel_type != Channel.ChannelType.GROUP:
		return false
	return not project.channel_is_in_subtree(target.id, channel)


## Name of `channel`'s current output: a device pair for master and for channels routed straight
## to hardware, else the target channel.
static func label(channel: Channel, project: Project) -> String:
	if channel == null or project == null:
		return "Output"
	if channel.is_master:
		return AudioConfig.output_label(channel.device_output_id)
	if channel.output_channel_id >= AudioConfig.HARDWARE_OUTPUT_BASE:
		return AudioConfig.output_label(channel.output_channel_id)
	if channel.output_channel_id == 1:
		return "Master"
	var target := project.get_channel_by_id(channel.output_channel_id)
	return target.name if target else "Unknown"


## Hardware output choices: the stereo output pairs of the running audio device (AudioConfig).
## A saved pair the device lacks stays listed, marked, and plays on 1/2 until a device has it.
static func _populate_device_outputs(popup: PopupMenu, current: int) -> void:
	var pairs := AudioConfig.output_pairs()
	for pair in pairs:
		var output_id := AudioConfig.HARDWARE_OUTPUT_BASE + pair
		popup.add_check_item(AudioConfig.output_label(output_id), output_id)
		if current == output_id:
			popup.set_item_checked(popup.get_item_count() - 1, true)
	if current >= AudioConfig.HARDWARE_OUTPUT_BASE + pairs:
		popup.add_check_item("%s (not on this device)" % AudioConfig.output_label(current), current)
		popup.set_item_checked(popup.get_item_count() - 1, true)


