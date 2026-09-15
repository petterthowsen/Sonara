## Creates nested mixer returns for drum pads and multi-out plugin extras.
class_name AuxReturnSync

const DRUM_MACHINE_ID := "sonara.builtin.drum_machine"


## After a device is added: pad → return channel, or CLAP extra outs → return channels.
static func on_device_added(
	project: Project,
	channel: Channel,
	device: DeviceInstance,
	parent: DeviceInstance
) -> void:
	if project == null or channel == null or device == null:
		return
	if parent and parent.device and parent.device.device_id == DRUM_MACHINE_ID:
		ensure_pad_return(project, channel, parent, device)
		return
	if parent == null:
		ensure_plugin_returns(project, channel, device)


## After a device is removed: drop its return channel(s).
static func on_device_removed(
	project: Project,
	channel: Channel,
	device: DeviceInstance,
	parent: DeviceInstance
) -> void:
	if project == null or device == null:
		return
	if parent and parent.device and parent.device.device_id == DRUM_MACHINE_ID:
		remove_pad_return(project, device)
		if channel:
			sync_aux_map_to_engine(channel)
		return
	if parent == null and device.device and device.device.device_id == DRUM_MACHINE_ID:
		for pad in device.children:
			remove_pad_return(project, pad)
		if channel:
			sync_aux_map_to_engine(channel)
		return
	if parent == null:
		remove_plugin_returns(project, device)
		if channel:
			sync_aux_map_to_engine(channel)


## Keep pad return bus indices in drum-child order after a move.
static func on_device_moved(project: Project, channel: Channel, parent: DeviceInstance) -> void:
	if project == null or channel == null or parent == null:
		return
	if parent.device == null or parent.device.device_id != DRUM_MACHINE_ID:
		return
	sync_pad_aux_order(project, channel, parent)


## After load: create missing pad/plugin returns for old projects.
static func ensure_all(project: Project) -> void:
	if project == null:
		return
	for ch in project.channels:
		for device in ch.devices:
			_ensure_tree(project, ch, device, null)


## Nested mixer strip for one drum-machine pad; output locked to the drum channel.
static func ensure_pad_return(
	project: Project,
	channel: Channel,
	drum: DeviceInstance,
	pad: DeviceInstance
) -> Channel:
	if project == null or channel == null or pad == null:
		return null
	var bus_index: int = pad.position
	if bus_index < 0:
		bus_index = drum.children.find(pad)
	var existing: Channel = project.get_channel_by_id(pad.return_channel_id)
	if existing == null:
		existing = _find_aux_child(project, channel, bus_index)
	if existing:
		pad.return_channel_id = existing.id
		existing.aux_bus_index = bus_index
		if existing.parent_channel_id != channel.id:
			var after := _pad_after_sibling(project, drum, pad)
			project.nest_channel(existing, channel, after)
		_bind_pad_name(project, pad)
		sync_aux_map_to_engine(channel)
		return existing

	var after := _pad_after_sibling(project, drum, pad)
	var ch := _create_return_channel(project, channel, pad.get_display_name(), after, bus_index)
	pad.return_channel_id = ch.id
	_bind_pad_name(project, pad)
	sync_aux_map_to_engine(channel)
	return ch


## Extra stereo outs on a CLAP (or other) device, skipping the main pair.
static func ensure_plugin_returns(project: Project, channel: Channel, device: DeviceInstance) -> void:
	if project == null or channel == null or device == null or device.device == null:
		return
	var extra: int = device.device.extra_stereo_bus_count()
	if extra <= 0:
		return
	var after: Channel = null
	for i in extra:
		var existing := project.get_channel_by_id(_plugin_return_id(device, i))
		if existing == null:
			existing = _find_aux_child(project, channel, i)
		if existing:
			_set_plugin_return_id(device, i, existing.id)
			existing.aux_bus_index = i
			after = existing
			continue
		var ch := _create_return_channel(project, channel, "Out %d" % (i + 2), after, i)
		_set_plugin_return_id(device, i, ch.id)
		after = ch
	sync_aux_map_to_engine(channel)


## Tell the engine which extra buses feed which child channels.
static func sync_aux_map_to_engine(channel: Channel) -> void:
	if channel == null or not channel.is_engine_connected():
		return
	var project := channel.get_project()
	if project == null:
		return
	for child_id in channel.child_channel_ids:
		var child := project.get_channel_by_id(child_id)
		if child == null or child.aux_bus_index < 0:
			continue
		AudioEngineOSC.send("/channel/%d/aux_out" % channel.id, [child.aux_bus_index, child.id])


## Remove the mixer return (and paired track) for a pad.
static func remove_pad_return(project: Project, pad: DeviceInstance) -> void:
	if project == null or pad == null:
		return
	_unbind_pad_name(pad)
	_remove_return_channel(project, pad.return_channel_id)
	pad.return_channel_id = -1


## Walk a loaded device tree and ensure returns exist.
static func _ensure_tree(
	project: Project,
	channel: Channel,
	device: DeviceInstance,
	parent: DeviceInstance
) -> void:
	if parent and parent.device and parent.device.device_id == DRUM_MACHINE_ID:
		ensure_pad_return(project, channel, parent, device)
	elif parent == null:
		ensure_plugin_returns(project, channel, device)
	for child in device.children:
		_ensure_tree(project, channel, child, device)


## Create a nested INSTRUMENT return under `parent`, with optional timeline track.
static func _create_return_channel(
	project: Project,
	parent: Channel,
	return_name: String,
	after: Channel,
	bus_index: int
) -> Channel:
	var ch := Channel.new(project.next_channel_id)
	project.next_channel_id += 1
	ch.name = return_name
	ch.channel_type = Channel.ChannelType.INSTRUMENT
	ch.output_channel_id = parent.id
	ch.color = parent.color
	ch.volume = 0.0
	ch.aux_bus_index = bus_index
	ch.parent_channel_id = parent.id
	project.add_channel(ch)
	project.nest_channel(ch, parent, after)
	var parent_track := project.get_channel_paired_track(parent)
	if parent_track:
		var track := Track.new(project.next_track_id)
		project.next_track_id += 1
		track.type = Track.TrackType.INSTRUMENT
		track.set_project_ref(project)
		track.pair_mixer_channel(ch)
		track.name = return_name
		project.add_track(track)
		var after_track := project.get_channel_paired_track(after) if after else null
		project.place_track(track, parent_track.id, after_track)
	return ch


## Drop a return channel and its paired timeline track.
static func _remove_return_channel(project: Project, channel_id: int) -> void:
	if channel_id < 0:
		return
	var ch := project.get_channel_by_id(channel_id)
	if ch == null:
		return
	var track := project.get_channel_paired_track(ch)
	if track:
		project.remove_track(track.id)
	project.remove_channel(channel_id)


## Align child_channel_ids and aux_bus_index with drum pad order.
static func sync_pad_aux_order(project: Project, channel: Channel, drum: DeviceInstance) -> void:
	var ordered: Array[int] = []
	for i in drum.children.size():
		var pad: DeviceInstance = drum.children[i]
		var ch := project.get_channel_by_id(pad.return_channel_id)
		if ch == null:
			continue
		ch.aux_bus_index = i
		ordered.append(ch.id)
	for child_id in channel.child_channel_ids:
		if not ordered.has(child_id):
			ordered.append(child_id)
	channel.child_channel_ids = ordered
	channel.notify_hierarchy_changed()
	sync_aux_map_to_engine(channel)


## Previous pad's return channel, or null to insert first.
static func _pad_after_sibling(project: Project, drum: DeviceInstance, pad: DeviceInstance) -> Channel:
	var idx := drum.children.find(pad)
	if idx <= 0:
		return null
	var prev: DeviceInstance = drum.children[idx - 1]
	return project.get_channel_by_id(prev.return_channel_id)


## Child of `parent` already tagged as extra bus `bus_index`.
static func _find_aux_child(project: Project, parent: Channel, bus_index: int) -> Channel:
	for child_id in parent.child_channel_ids:
		var child := project.get_channel_by_id(child_id)
		if child and child.aux_bus_index == bus_index:
			return child
	return null


## Keep the pad return named after the pad device.
static func _bind_pad_name(project: Project, pad: DeviceInstance) -> void:
	if pad == null:
		return
	_unbind_pad_name(pad)
	pad.name_changed.connect(_on_pad_name_changed.bind(project, pad))
	_on_pad_name_changed(pad.get_display_name(), project, pad)


## Drop the pad-name listener before removing the return.
static func _unbind_pad_name(pad: DeviceInstance) -> void:
	if pad == null:
		return
	for conn in pad.name_changed.get_connections():
		var cb: Callable = conn.get("callable")
		if cb.is_valid() and cb.get_method() == "_on_pad_name_changed":
			pad.name_changed.disconnect(cb)


## Rename the pad return when the pad device is renamed.
static func _on_pad_name_changed(new_name: String, project: Project, pad: DeviceInstance) -> void:
	if project == null or pad == null:
		return
	var ch := project.get_channel_by_id(pad.return_channel_id)
	if ch:
		ch.set_name(new_name)


## Return channel id stored on a multi-out device for extra bus `index`.
static func _plugin_return_id(device: DeviceInstance, index: int) -> int:
	if index < 0 or index >= device.return_channel_ids.size():
		return -1
	return device.return_channel_ids[index]


## Remember extra-out return `channel_id` on the plugin device.
static func _set_plugin_return_id(device: DeviceInstance, index: int, channel_id: int) -> void:
	while device.return_channel_ids.size() <= index:
		device.return_channel_ids.append(-1)
	device.return_channel_ids[index] = channel_id


## Remove extra-out returns owned by a multi-out device.
static func remove_plugin_returns(project: Project, device: DeviceInstance) -> void:
	if project == null or device == null:
		return
	for channel_id in device.return_channel_ids:
		_remove_return_channel(project, channel_id)
	device.return_channel_ids.clear()
