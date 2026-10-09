# DeviceActions.gd
# Undoable device edits shared by the device lane, compact panels, context menu and AI tools.
class_name DeviceActions extends RefCounted


## Rename `device` as one "Rename Device" step. Blank input or an unchanged name is ignored.
## Returns the name the device ends up with (possibly suffixed, e.g. `Delay 2`).
static func rename(device: DeviceInstance, desired: String) -> String:
	if device == null:
		return ""
	var trimmed := desired.strip_edges()
	if trimmed.is_empty():
		return device.get_display_name()
	var final_name := device.unique_name_for(trimmed)
	if final_name != device.name:
		HistoryUtil.execute_property("Rename Device", device, "set_name", device.name, final_name)
	return device.get_display_name()


## Serialized copies of the last copied devices (see `copy`), each with its original host's `parent` null-free.
static var clipboard: Array[Dictionary] = []


## The devices of `selection` that share the first one's host, in host order (mixed hosts reduce
## to the primary device's, as drag-and-drop does).
static func same_host(selection: Array) -> Array[DeviceInstance]:
	var out: Array[DeviceInstance] = []
	if selection.is_empty() or selection[0] == null:
		return out
	var host_parent: DeviceInstance = selection[0].get_parent_device()
	for inst in selection:
		if inst != null and inst.get_parent_device() == host_parent:
			out.append(inst)
	var host: Array[DeviceInstance] = host_parent.children if host_parent else (selection[0].get_channel().devices if selection[0].get_channel() else out)
	out.sort_custom(func(a, b): return host.find(a) < host.find(b))
	return out


## Remember `selection` for `paste`. Returns how many devices were copied.
static func copy(selection: Array) -> int:
	var list := same_host(selection)
	if list.is_empty():
		return 0
	clipboard.clear()
	for inst in list:
		clipboard.append(inst.to_json())
	return list.size()


static func can_paste() -> bool:
	return not clipboard.is_empty()


## Insert fresh copies of `entries` (serialized devices) into `host_parent` (null = channel root)
## at `position` (-1 = end) as one "Paste Devices" step. Devices that don't fit are skipped.
## Returns the new instances.
static func paste(channel: Channel, host_parent: DeviceInstance, position: int, entries: Array[Dictionary] = clipboard) -> Array[DeviceInstance]:
	var added: Array[DeviceInstance] = []
	if channel == null:
		return added
	var cmds: Array[Command] = []
	var at := position
	for entry in entries:
		var data := entry.duplicate(true)
		DeviceInstance.refresh_ids_in_json(data, channel.id)
		data["position"] = -1
		var inst := DeviceInstance.from_json(data)
		if inst == null or not DeviceDropUtil.can_drop_instance_on_host(channel, inst, host_parent) \
				or not DeviceDropUtil.device_fits_channel(inst.device, channel):
			continue
		cmds.append(DeviceAddCommand.new(channel, inst, at, host_parent))
		added.append(inst)
		if at >= 0:
			at += 1
	HistoryUtil.execute_many("Paste Devices", cmds)
	return added


## Copy `selection` right after its last device, as one undo step.
static func duplicate_devices(selection: Array) -> Array[DeviceInstance]:
	var list := same_host(selection)
	if list.is_empty():
		return []
	var host_parent := list[0].get_parent_device()
	var host: Array[DeviceInstance] = host_parent.children if host_parent else list[0].get_channel().devices
	var entries: Array[Dictionary] = []
	for inst in list:
		entries.append(inst.to_json())
	return paste(list[0].get_channel(), host_parent, host.find(list[-1]) + 1, entries)
