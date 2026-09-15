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
