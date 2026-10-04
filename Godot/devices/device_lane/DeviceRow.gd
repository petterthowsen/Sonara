## Left-to-right row of DeviceLaneItems: a channel's chain in the DeviceLane, or the devices of one
## open container slot (DeviceSlotGroup). `sync` keeps the items of devices that are still in the
## row, so a change never rebuilds the panels of untouched devices.
class_name DeviceRow extends HBoxContainer

## Space between devices, and between a container and its open slots, in pixels.
const GAP := 16

## Empty space right of every panel, so drop indicators beside it have room to glow.
const PANEL_MARGIN := 12

## A panel in this row (or in a slot nested in it) asked for its context menu. `in_slot` is true
## for a device inside a container slot.
signal context_menu_requested(device_instance: DeviceInstance, in_slot: bool)
## Selection clicks from any panel in this row (see DeviceLaneItem); the lane owns the selection.
signal selection_requested(panel: DevicePanel, additive: bool, range_select: bool)
signal selection_released(panel: DevicePanel)
## Space above each panel. The root row leaves room for the color strips of the slots in it.
var panel_top_inset := 0

## True for a row inside a container slot.
var in_slot := false


func _init() -> void:
	add_theme_constant_override("separation", GAP)
	size_flags_vertical = Control.SIZE_EXPAND_FILL


## Show `list` in order: reuse the items of devices already shown, create the missing ones and
## free the rest (including any placeholder nodes from the scene).
func sync(list: Array[DeviceInstance]) -> void:
	var existing := {}
	for child in get_children():
		if child is DeviceLaneItem and not child.is_queued_for_deletion() and list.has(child.device):
			existing[child.device] = child
		else:
			remove_child(child)
			child.queue_free()
	for i in list.size():
		var item: DeviceLaneItem = existing.get(list[i])
		if item == null:
			item = DeviceLaneItem.new()
			item.setup(list[i], panel_top_inset, in_slot)
			item.context_menu_requested.connect(context_menu_requested.emit)
			item.selection_requested.connect(selection_requested.emit)
			item.selection_released.connect(selection_released.emit)
			add_child(item)
		move_child(item, i)


func clear() -> void:
	sync([] as Array[DeviceInstance])


## Panel showing `inst` in this row or any slot open inside it.
func find_panel(inst: DeviceInstance) -> DevicePanel:
	for child in get_children():
		if child is DeviceLaneItem and not child.is_queued_for_deletion():
			var panel: DevicePanel = child.find_panel(inst)
			if panel:
				return panel
	return null


## Items in display order.
func items() -> Array[DeviceLaneItem]:
	var out: Array[DeviceLaneItem] = []
	for child in get_children():
		if child is DeviceLaneItem and not child.is_queued_for_deletion():
			out.append(child)
	return out


## Panels in this row and every slot open inside it, in display order.
func collect_panels() -> Array[DevicePanel]:
	var out: Array[DevicePanel] = []
	for child in get_children():
		if child is DeviceLaneItem and not child.is_queued_for_deletion():
			if child.panel:
				out.append(child.panel)
			for group in child.slot_groups():
				out.append_array(group.row.collect_panels())
	return out
