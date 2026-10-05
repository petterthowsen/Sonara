# DeviceDropUtil.gd
# Shared drop rules for adding/reordering devices on a channel or inside a container.
# Drag data may be a DeviceDrag, a DeviceInstance or an Asset; DeviceDrag is unwrapped here.
# Every drop target (device lane, mixer strip, compact list, container slot, drum pad,
# AI tools) goes through these so they accept and do the same thing.
# Drops are synchronous: files for new devices are queued on the instance and loaded by
# Channel.add_device() right after the engine is told to create the device.
class_name DeviceDropUtil extends RefCounted

const SFIZZ_ID := "sonara.builtin.sfizz"
const SAMPLER_ID := "sonara.builtin.sampler"
const DRUM_MACHINE_ID := "sonara.builtin.drum_machine"


## Whether this asset can be added to the channel (device, SFZ, or audio-into-drum).
static func can_drop_asset_on_channel(channel: Channel, asset: Asset) -> bool:
	if channel == null or asset == null:
		return false
	if asset.type == Asset.TYPE.SFZ:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT
	if asset.type == Asset.TYPE.Audio:
		return false
	return device_fits_channel(device_for_asset(asset), channel)


## The Device a Device or Preset asset stands for, or null for other assets and missing devices.
static func device_for_asset(asset: Asset) -> Device:
	if asset == null:
		return null
	match asset.type:
		Asset.TYPE.Device:
			return AssetService.get_device(asset.path)
		Asset.TYPE.Preset:
			return AssetService.get_device(asset.device_id)
	return null


## Instruments only go on instrument channels (master keeps the default INSTRUMENT type, so it is
## excluded by id); effects and containers go anywhere, master included.
static func device_fits_channel(device: Device, channel: Channel) -> bool:
	if device == null or channel == null:
		return false
	if device.category == Device.DeviceCategory.Instrument:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT and not channel.is_master
	return true


## Whether `inst` can be inserted into `host_parent` (null = channel root).
static func can_drop_instance_on_host(
	channel: Channel,
	inst: DeviceInstance,
	host_parent: DeviceInstance
) -> bool:
	if channel == null or inst == null:
		return false
	if Multiband.is_band_chain(inst):
		return false  # band positions are fixed (spec 016 D9)
	if inst.channel_id != channel.id and not can_transfer_to_channel(inst, channel):
		return false
	if host_parent == null:
		return true
	if Multiband.is_multiband(host_parent) and SlotChain.is_chain(inst):
		return false
	if inst == host_parent:
		return false
	if inst.contains_device(host_parent):
		return false
	return true


## Whether `inst` can move from its channel to `channel`. Devices that own aux return channels
## (Drum Machine, multi-out plugins) and drum pads stay put: removing them detaches their returns.
static func can_transfer_to_channel(inst: DeviceInstance, channel: Channel) -> bool:
	if channel == null or not can_leave_channel(inst) or inst.get_channel() == channel:
		return false
	return device_fits_channel(inst.device, channel)


## Whether `inst` may be moved off its channel at all (see can_transfer_to_channel).
static func can_leave_channel(inst: DeviceInstance) -> bool:
	if inst == null or inst.get_channel() == null:
		return false
	if PadLane.is_pad_lane(inst.get_channel()) or AuxReturnSync.is_drum_machine(inst.get_parent_device()):
		return false
	return not _owns_aux_returns(inst)


## True when `inst` or a descendant is a Drum Machine or has plugin return channels.
static func _owns_aux_returns(inst: DeviceInstance) -> bool:
	if AuxReturnSync.is_drum_machine(inst) or not inst.return_channel_ids.is_empty():
		return true
	for child in inst.children:
		if _owns_aux_returns(child):
			return true
	return false


## Add a device or sfizz+SFZ asset into `parent` (null = channel root).
static func drop_asset(
	channel: Channel,
	asset: Asset,
	position: int,
	parent: DeviceInstance
) -> void:
	if channel == null or asset == null:
		return
	if asset.type == Asset.TYPE.Audio and _is_drum_machine(parent):
		drop_on_drum_pad(channel, parent, parent.next_free_drum_note(), asset)
		return
	var device_instance := instance_for_asset(asset, channel.id, position, channel.get_project())
	if device_instance:
		HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, position, parent))


## New instance for a Device asset, a Preset asset (the preset's device tree, named after the
## preset) or an sfizz instance with the SFZ queued. Null for other assets. `project` supplies ids for
## a preset's return channels (default: the open project).
static func instance_for_asset(asset: Asset, channel_id: int, position: int = -1, project: Project = null) -> DeviceInstance:
	if asset == null:
		return null
	if asset.type == Asset.TYPE.Preset:
		return _instance_for_preset(asset, channel_id, project)
	var device_id := ""
	match asset.type:
		Asset.TYPE.SFZ:
			device_id = SFIZZ_ID
		Asset.TYPE.Device:
			device_id = asset.path
		_:
			return null
	var device := AssetService.get_device(device_id)
	if device == null:
		push_error("[DeviceDropUtil] Failed to get device: %s" % device_id)
		return null
	var device_instance := DeviceInstance.new(device, channel_id, position)
	if asset.type == Asset.TYPE.SFZ:
		device_instance.queue_file_load(asset.path)
	return device_instance


## Loads the preset file behind `asset` and instantiates it. Missing files and other load warnings
## are shown in one message; null when the file or its device is unusable.
static func _instance_for_preset(asset: Asset, channel_id: int, project: Project) -> DeviceInstance:
	return instance_for_preset_path(asset.path, channel_id, project)


## Same as a Preset asset drop, from the preset file's path.
static func instance_for_preset_path(preset_path: String, channel_id: int, project: Project) -> DeviceInstance:
	var preset := PresetLibrary.load_preset(preset_path)
	if preset == null:
		_show_preset_message("Preset not loaded", "Could not read the preset file:\n%s" % preset_path)
		return null
	if project == null:
		var editor := _editor()
		project = editor.project if editor else null
	var inst := preset.instantiate(channel_id, project)
	var lines := PackedStringArray(preset.warnings)
	if not preset.missing_files.is_empty():
		lines.append("Missing files:")
		for file in preset.missing_files:
			lines.append("  " + file)
	if inst == null:
		lines.insert(0, "Preset '%s' could not be created." % preset.name)
	if not lines.is_empty():
		_show_preset_message("Preset '%s'" % preset.name, "\n".join(lines))
	return inst


static func _show_preset_message(title: String, body: String) -> void:
	push_warning("[DeviceDropUtil] %s: %s" % [title, body])
	var editor := _editor()
	if editor:
		editor.show_error(title, body)


## The Editor node, or null when there is none (headless tests). Sonara.editor errors without one.
static func _editor() -> Editor:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("Editor") as Editor if tree else null


## Kind of channel a device drop on empty mixer space creates: "instrument" or "audio" track on the
## track side, "bus" on the bus side, or "" when `data` can't start a channel there. Instruments
## and containers (and SFZ files) make instrument tracks; effects make audio tracks or buses.
static func new_channel_kind(data: Variant, bus_side: bool) -> String:
	data = DeviceDrag.unwrap(data)
	var device: Device = null
	if data is DeviceInstance:
		if not can_leave_channel(data):
			return ""
		device = (data as DeviceInstance).device
	elif data is Asset:
		var asset := data as Asset
		if asset.type == Asset.TYPE.SFZ:
			return "" if bus_side else "instrument"
		device = device_for_asset(asset)
	if device == null:
		return ""
	if device.creates_instrument_track():
		return "" if bus_side else "instrument"
	return "bus" if bus_side else "audio"


## Create the channel `new_channel_kind` names (track or bus, named after the device) and add the
## asset's device to it, or move the dragged device there. One undo step. Returns the channel.
## `parent_id` >= -1 places the new track under that parent (-1 = root) after `after_sibling`
## (null = first); the default -2 leaves it where the project puts new tracks.
static func create_channel_for(
	project: Project,
	data: Variant,
	bus_side: bool,
	parent_id: int = -2,
	after_sibling: Track = null
) -> Channel:
	var kind := new_channel_kind(data, bus_side)
	if project == null or kind.is_empty():
		return null
	data = DeviceDrag.unwrap(data)
	var channel_name := _channel_name_for(data)
	var create: Command
	if kind == "bus":
		create = BusCreateCommand.new(project, channel_name)
	else:
		create = TrackCreateCommand.new(project, kind, channel_name)
	create.do()
	var channel: Channel = create.get("channel")
	if channel == null:
		push_error("[DeviceDropUtil] Failed to create a %s channel for %s" % [kind, channel_name])
		return null
	var cmds: Array[Command] = [create]
	var track: Track = create.get("track") if kind != "bus" else null
	if track and parent_id >= -1:
		var before := TrackReorderCommand.capture_layout(project)
		if project.place_track(track, parent_id, after_sibling):
			cmds.append(TrackReorderCommand.new(project, before, TrackReorderCommand.capture_layout(project)))
	var place: Command = null
	if data is DeviceInstance:
		place = DeviceTransferCommand.new(data, channel, null, -1)
	else:
		var device_instance := instance_for_asset(data, channel.id, 0, project)
		if device_instance:
			place = DeviceAddCommand.new(channel, device_instance, -1)
	if place:
		place.do()
		cmds.append(place)
	HistoryUtil.record_many(create.name, cmds)
	return channel


static func _channel_name_for(data: Variant) -> String:
	if data is DeviceInstance:
		return (data as DeviceInstance).get_display_name()
	return _track_name_for(data)


## Preset name for a preset, device name for a Device asset, file name for an SFZ.
static func _track_name_for(asset: Asset) -> String:
	if asset.type == Asset.TYPE.Preset:
		return asset.get_display_name()
	if asset.type == Asset.TYPE.Device:
		var device := AssetService.get_device(asset.path)
		if device:
			return device.name
	return asset.name


## Reorder within `to_parent`, relocate from another parent on the same channel, or move from
## another channel.
static func drop_instance(
	channel: Channel,
	inst: DeviceInstance,
	to_parent: DeviceInstance,
	to_position: int
) -> void:
	if not can_drop_instance_on_host(channel, inst, to_parent):
		return
	if Multiband.is_multiband(to_parent):
		var band := Multiband.target_chain(to_parent)
		if band == null:
			return
		to_parent = band
		to_position = -1
	if SlotChain.is_slot_parent(to_parent) and inst.get_parent_device() != to_parent and not SlotChain.is_chain(inst):
		HistoryUtil.execute_many("Move Device", _new_slot_commands(channel, inst, to_parent, to_position))
		return
	if inst.get_channel() != channel:
		HistoryUtil.execute(DeviceTransferCommand.new(inst, channel, to_parent, to_position))
		return
	var from_parent := inst.get_parent_device()
	var from_position := inst.position
	if from_parent == to_parent:
		var host: Array[DeviceInstance] = to_parent.children if to_parent else channel.devices
		var dest := to_position
		if dest < 0 or dest > host.size():
			dest = host.size()
		if from_position < dest:
			dest -= 1
		if from_position != dest and dest >= 0:
			HistoryUtil.execute(DeviceMoveCommand.new(channel, from_position, dest, to_parent))
		return
	HistoryUtil.execute(DeviceRelocateCommand.new(channel, inst, to_parent, to_position))

## Move a dragged selection (`DeviceDrag.devices`, in visual order) into `to_parent` at
## `to_position` as one undo step. Only a selection already living in the target host on this
## channel moves as a block; anything else (mixed hosts, slot or band parents, transfers)
## reduces to moving the primary device alone through `drop_instance`. Returns true when a
## move was committed.
static func drop_selection(
	channel: Channel,
	insts: Array,
	to_parent: DeviceInstance,
	to_position: int
) -> bool:
	var list: Array[DeviceInstance] = []
	for d in insts:
		if d is DeviceInstance:
			list.append(d)
	var primary := list[0] if not list.is_empty() else null
	if primary == null:
		return false
	if list.size() == 1 or Multiband.is_multiband(to_parent) or SlotChain.is_slot_parent(to_parent):
		drop_instance(channel, primary, to_parent, to_position)
		return true
	# A selection from another channel transfers as a block, in order, at the drop point.
	if list.all(func(d): return d.get_channel() != channel and can_drop_instance_on_host(channel, d, to_parent)):
		var transfers: Array[Command] = []
		for i in list.size():
			var at := -1 if to_position < 0 else to_position + i
			transfers.append(DeviceTransferCommand.new(list[i], channel, to_parent, at))
		HistoryUtil.execute_many("Move Devices", transfers)
		return true
	var host: Array[DeviceInstance] = to_parent.children if to_parent else channel.devices
	var moving := list.filter(func(d): return host.has(d)) as Array[DeviceInstance]
	if moving.size() != list.size():
		drop_instance(channel, primary, to_parent, to_position)
		return true
	for inst in list:
		if inst.get_channel() != channel or not can_drop_instance_on_host(channel, inst, to_parent):
			drop_instance(channel, primary, to_parent, to_position)
			return true
	# Final order: the host without the moving devices, with them (in their current order)
	# inserted where the drop pointed. Positions past the end, or at a moving device itself,
	# count the non-moving devices before the drop point.
	var rest: Array[DeviceInstance] = []
	var before := 0
	var at: int = clampi(to_position, 0, host.size())
	for i in host.size():
		if moving.has(host[i]):
			continue
		if i < at:
			before += 1
		rest.append(host[i])
	var final: Array[DeviceInstance] = []
	final.append_array(rest.slice(0, before))
	final.append_array(moving)
	final.append_array(rest.slice(before))
	# One move per device that is out of place, applied left to right; each command's from/to is
	# taken against the order the previous ones already produced, so undo in reverse restores it.
	var cmds: Array[Command] = []
	var current: Array[DeviceInstance] = host.duplicate()
	for i in final.size():
		var from := current.find(final[i])
		if from == i:
			continue
		cmds.append(DeviceMoveCommand.new(channel, from, i, to_parent))
		current.remove_at(from)
		current.insert(i, final[i])
	if cmds.is_empty():
		return false
	HistoryUtil.execute_many("Move Devices", cmds)
	return true


## Commands that move `inst` into Layer or Drum Machine `parent` as a new slot at `position` (on
## pad `note` for a Drum Machine, -1 = next free): an empty slot chain, then the device into it.
static func _new_slot_commands(
	channel: Channel,
	inst: DeviceInstance,
	parent: DeviceInstance,
	position: int,
	note: int = -1
) -> Array[Command]:
	var cmds: Array[Command] = []
	var chain := SlotChain.empty(channel.id, inst.get_display_name())
	if chain == null:
		return cmds
	chain.slot_note = note
	cmds.append(DeviceAddCommand.new(channel, chain, position, parent))
	if inst.get_channel() != channel:
		cmds.append(DeviceTransferCommand.new(inst, channel, chain, 0))
	else:
		cmds.append(DeviceRelocateCommand.new(channel, inst, chain, 0))
	return cmds


## True when `path`'s extension is in the device's advertised file-loading list.
static func extension_matches_device(device: Device, path: String) -> bool:
	if device == null or path.is_empty():
		return false
	var ext := "." + path.get_extension().to_lower()
	for e in device.supported_file_extensions:
		if str(e).to_lower() == ext:
			return true
	return false


## True when `asset` can be loaded into `inst` via load_file.
static func can_drop_file_on_device(inst: DeviceInstance, asset: Asset) -> bool:
	if inst == null or asset == null or inst.device == null:
		return false
	if not inst.device.supports_file_loading:
		return false
	if asset.type == Asset.TYPE.SFZ:
		return true
	if asset.type == Asset.TYPE.Audio:
		return extension_matches_device(inst.device, asset.path)
	return false


## Depth-first search for a file-loading device (the instance itself or a descendant).
static func find_file_loading_descendant(inst: DeviceInstance) -> DeviceInstance:
	if inst == null:
		return null
	if inst.device and inst.device.supports_file_loading:
		return inst
	for child in inst.children:
		var found := find_file_loading_descendant(child)
		if found:
			return found
	return null


## Whether `data` can be dropped onto the device panel for `inst`: a child for a container, or a file to load.
static func can_drop_on_device(inst: DeviceInstance, data: Variant) -> bool:
	data = DeviceDrag.unwrap(data)
	if inst == null:
		return false
	if is_preset_for_device(inst, data):
		return true
	if inst.is_container() and can_drop_on_container(inst.get_channel(), inst, data):
		return true
	return data is Asset and can_drop_file_on_device(inst, data)


## Whether `data` is a Preset asset saved from the same device type as `inst` (load in place).
static func is_preset_for_device(inst: DeviceInstance, data: Variant) -> bool:
	data = DeviceDrag.unwrap(data)
	return inst != null and inst.device != null and inst.get_channel() != null \
			and data is Asset and (data as Asset).type == Asset.TYPE.Preset \
			and (data as Asset).device_id == inst.device.id


## Drop `data` onto the device panel for `inst`. Returns true when it was added into the container.
static func drop_on_device(inst: DeviceInstance, data: Variant) -> bool:
	data = DeviceDrag.unwrap(data)
	if inst == null:
		return false
	var channel := inst.get_channel()
	if is_preset_for_device(inst, data):
		load_preset_into(inst, (data as Asset).path)
		return false
	if inst.is_container() and can_drop_on_container(channel, inst, data):
		drop_on_container(channel, inst, data)
		return true
	if data is Asset and can_drop_file_on_device(inst, data):
		inst.load_file((data as Asset).path)
	return false


## Replace `inst` with the preset at `preset_path` in one undo step. Returns the new instance, or
## null when the preset can't be loaded.
static func load_preset_into(inst: DeviceInstance, preset_path: String) -> DeviceInstance:
	var channel := inst.get_channel() if inst else null
	if channel == null:
		return null
	var fresh := instance_for_preset_path(preset_path, channel.id, channel.get_project())
	if fresh == null:
		return null
	HistoryUtil.execute(DevicePresetLoadCommand.new(channel, inst, fresh))
	return fresh


## Drop onto a container device itself (append a child).
static func can_drop_on_container(channel: Channel, container: DeviceInstance, data: Variant) -> bool:
	data = DeviceDrag.unwrap(data)
	if channel == null or container == null or not container.is_container():
		return false
	if data is DeviceInstance:
		return can_drop_instance_on_host(channel, data, container)
	if data is Asset:
		if data.type == Asset.TYPE.Audio and _is_drum_machine(container):
			return channel.channel_type == Channel.ChannelType.INSTRUMENT
		return can_drop_asset_on_channel(channel, data)
	return false


## Append `data` as a child of `container`.
static func drop_on_container(
	channel: Channel,
	container: DeviceInstance,
	data: Variant
) -> void:
	data = DeviceDrag.unwrap(data)
	if not can_drop_on_container(channel, container, data):
		return
	if data is DeviceInstance:
		drop_instance(channel, data, container, -1)
		return
	if data is Asset:
		drop_asset(channel, data, -1, container)


static func _is_drum_machine(inst: DeviceInstance) -> bool:
	return inst != null and inst.device != null and inst.device.device_id == DRUM_MACHINE_ID


## Whether `data` can land on a drum pad (empty, occupied file-load, or pad-to-pad move/swap).
static func can_drop_on_drum_pad(
	data: Variant,
	occupied: DeviceInstance,
	channel: Channel = null,
	container: DeviceInstance = null,
	note := -1
) -> bool:
	if container != null and note >= 0 and is_group_drag(container, data):
		return not group_move_plan(container, (data as DeviceDrag).devices, note - (data as DeviceDrag).device.slot_note).is_empty()
	data = DeviceDrag.unwrap(data)
	if data is DeviceInstance:
		var inst := data as DeviceInstance
		if inst == occupied:
			return false
		if channel != null and container != null:
			return can_drop_instance_on_host(channel, inst, container)
		return true
	if not data is Asset:
		return false
	var asset := data as Asset
	if occupied:
		# A file loads into the pad's sampler; anything else joins the pad's chain.
		if can_drop_file_on_device(find_file_loading_descendant(occupied), asset):
			return true
		return occupied.is_container() and (asset.type == Asset.TYPE.Audio or asset.type == Asset.TYPE.SFZ or asset.type == Asset.TYPE.Device or asset.type == Asset.TYPE.Preset)
	if asset.type == Asset.TYPE.Audio or asset.type == Asset.TYPE.SFZ or asset.type == Asset.TYPE.Device or asset.type == Asset.TYPE.Preset:
		return true
	return false


## Drop a sample or device onto a drum-machine pad with MIDI `note`.
static func drop_on_drum_pad(
	channel: Channel,
	container: DeviceInstance,
	note: int,
	data: Variant
) -> void:
	if channel == null or container == null:
		return
	if is_group_drag(container, data):
		var drag := data as DeviceDrag
		move_drum_pads(container, drag.devices, note - drag.device.slot_note)
		return
	data = DeviceDrag.unwrap(data)
	var occupied := _child_for_note(container, note)
	if data is DeviceInstance:
		_drop_instance_on_drum_pad(channel, container, note, data, occupied)
		return
	if not data is Asset:
		return
	var asset := data as Asset
	if occupied:
		var target := find_file_loading_descendant(occupied)
		if can_drop_file_on_device(target, asset):
			target.load_file(asset.path)
		elif occupied.is_container():
			var added := _sampler_for(asset, channel.id) if asset.type == Asset.TYPE.Audio else instance_for_asset(asset, channel.id, -1, channel.get_project())
			if added:
				HistoryUtil.execute(DeviceAddCommand.new(channel, added, -1, occupied))
		return
	var device_instance: DeviceInstance = null
	if asset.type == Asset.TYPE.Audio:
		device_instance = _sampler_for(asset, channel.id)
	else:
		device_instance = instance_for_asset(asset, channel.id, -1, channel.get_project())
	if device_instance == null:
		return
	device_instance.slot_note = note
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, -1, container))


## True when `data` drags several pads of `container` together.
static func is_group_drag(container: DeviceInstance, data: Variant) -> bool:
	if not data is DeviceDrag:
		return false
	var drag := data as DeviceDrag
	if drag.devices.size() < 2 or drag.device == null:
		return false
	for d in drag.devices:
		if d.get_parent_device() != container:
			return false
	return true


## Pads of `container` moved together by `delta` notes, in an order that never puts two on one
## note. Empty when the move is refused: no shift, a destination outside 0-127, or a destination
## held by a pad that is not part of the move.
static func group_move_plan(container: DeviceInstance, moving: Array[DeviceInstance], delta: int) -> Array[DeviceInstance]:
	var plan: Array[DeviceInstance] = []
	if container == null or delta == 0 or moving.is_empty():
		return plan
	for pad in moving:
		var target := pad.slot_note + delta
		if target < 0 or target > 127:
			return plan
		var holder := _child_for_note(container, target)
		if holder != null and not moving.has(holder):
			return plan
	plan.append_array(moving)
	# Moving up, the highest pad goes first so its destination is already free; down is the reverse.
	plan.sort_custom(func(a: DeviceInstance, b: DeviceInstance) -> bool:
		return a.slot_note > b.slot_note if delta > 0 else a.slot_note < b.slot_note)
	return plan


## Move `moving` pads by `delta` notes as one undo step (see group_move_plan). False if refused.
static func move_drum_pads(container: DeviceInstance, moving: Array[DeviceInstance], delta: int) -> bool:
	var plan := group_move_plan(container, moving, delta)
	if plan.is_empty():
		return false
	var cmds: Array[Command] = []
	for pad in plan:
		cmds.append(PropertyCommand.new("Move Drum Pad", pad, "set_slot_note", pad.slot_note, pad.slot_note + delta))
	HistoryUtil.execute(MacroCommand.new("Move Drum Pads", cmds))
	return true


## Move `inst` onto `note`. A pad moved onto another pad swaps notes with it; a device joins the
## chain of an occupied pad, or becomes a new slot on an empty one.
static func _drop_instance_on_drum_pad(
	channel: Channel,
	container: DeviceInstance,
	note: int,
	inst: DeviceInstance,
	occupied: DeviceInstance
) -> void:
	if inst == null or inst == occupied:
		return
	if not can_drop_instance_on_host(channel, inst, container):
		return
	var from_parent := inst.get_parent_device()
	if from_parent == container:
		if occupied:
			_swap_drum_notes(container, inst, occupied)
		else:
			HistoryUtil.execute_property("Move Drum Pad", inst, "set_slot_note", inst.slot_note, note)
		return
	if occupied:
		if occupied.is_container():
			drop_instance(channel, inst, occupied, -1)
		return
	if not SlotChain.is_chain(inst):
		HistoryUtil.execute_many("Move Device", _new_slot_commands(channel, inst, container, -1, note))
		return
	inst.slot_note = note
	drop_instance(channel, inst, container, -1)
	inst.set_slot_note(note)


## Swap two drum-machine children's notes via a free temp note (engine notes are unique).
static func _swap_drum_notes(container: DeviceInstance, a: DeviceInstance, b: DeviceInstance) -> void:
	if a == null or b == null or a == b:
		return
	var a_note := a.slot_note
	var b_note := b.slot_note
	if a_note == b_note:
		return
	var temp := container.next_free_drum_note()
	var cmds: Array[Command] = []
	cmds.append(PropertyCommand.new("Move Drum Pad", a, "set_slot_note", a_note, temp))
	cmds.append(PropertyCommand.new("Move Drum Pad", b, "set_slot_note", b_note, a_note))
	cmds.append(PropertyCommand.new("Move Drum Pad", a, "set_slot_note", temp, b_note))
	HistoryUtil.execute(MacroCommand.new("Swap Drum Pads", cmds))


## Find the child assigned to MIDI `note`, or null if the pad is empty.
static func _child_for_note(container: DeviceInstance, note: int) -> DeviceInstance:
	if container == null:
		return null
	for child in container.children:
		if child.slot_note == note:
			return child
	return null


## New sampler instance with the audio `asset` queued for loading.
static func _sampler_for(asset: Asset, channel_id: int) -> DeviceInstance:
	var sampler_device := AssetService.get_device(SAMPLER_ID)
	if sampler_device == null:
		push_error("[DeviceDropUtil] Failed to get sampler device")
		return null
	var device_instance := DeviceInstance.new(sampler_device, channel_id, -1)
	device_instance.queue_file_load(asset.path)
	return device_instance
