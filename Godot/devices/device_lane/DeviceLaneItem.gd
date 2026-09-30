## One device in a DeviceRow: its DevicePanel, then one DeviceSlotGroup per open slot when the
## device is a container. The children sit beside the container instead of inside its panel, so
## every panel keeps the same fixed height (DevicePanel.HEIGHT).
class_name DeviceLaneItem extends HBoxContainer

const DevicePanelScene: PackedScene = preload("res://devices/device_lane/DevicePanel.tscn")

signal context_menu_requested(device_instance: DeviceInstance, in_slot: bool)

var device: DeviceInstance = null
var panel: DevicePanel = null

## The panel's header: drops there go onto the device (see DeviceDropTarget).
var header: Control:
	get:
		return panel.header if panel else null

var _in_slot := false
var _groups := {}  # slot key -> DeviceSlotGroup


func _init() -> void:
	add_theme_constant_override("separation", 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL


## Build the panel for `inst`, `top_inset` pixels below the row's top, and its open slots.
func setup(inst: DeviceInstance, top_inset: int, in_slot: bool) -> void:
	device = inst
	_in_slot = in_slot
	var margin := MarginContainer.new()
	margin.name = "PanelMargin"
	margin.add_theme_constant_override("margin_top", top_inset)
	margin.add_theme_constant_override("margin_right", DeviceRow.PANEL_MARGIN)
	add_child(margin)
	panel = DevicePanelScene.instantiate()
	# Fixed height (DevicePanel.HEIGHT), whatever the lane's height.
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	panel.request_context_menu.connect(_on_panel_context_menu)
	panel.request_child_context_menu.connect(_on_child_context_menu)
	margin.add_child(panel)
	panel.bind_to_device(inst)
	if not inst.is_container():
		return
	inst.slots_changed.connect(_sync_groups)
	inst.child_added.connect(_on_children_changed)
	inst.child_removed.connect(_on_children_changed)
	inst.child_moved.connect(_on_children_changed)
	_sync_groups()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or device == null or not device.is_container():
		return
	for sig in [device.slots_changed, device.child_added, device.child_removed, device.child_moved]:
		for method in [_sync_groups, _on_children_changed]:
			if sig.is_connected(method):
				sig.disconnect(method)


## Panel showing `inst`: this item's own, or one inside an open slot.
func find_panel(inst: DeviceInstance) -> DevicePanel:
	if device == inst:
		return panel
	for group in _groups.values():
		var found: DevicePanel = group.row.find_panel(inst)
		if found:
			return found
	return null


## Open slot groups in display order.
func slot_groups() -> Array[DeviceSlotGroup]:
	var out: Array[DeviceSlotGroup] = []
	for key in device.open_slot_keys() if device else PackedStringArray():
		if _groups.has(key):
			out.append(_groups[key])
	return out


func _on_panel_context_menu() -> void:
	context_menu_requested.emit(device, _in_slot)


## A slot chain's menu: Remove takes the whole layer, or the whole pad and its return.
func _on_child_context_menu(child: DeviceInstance) -> void:
	context_menu_requested.emit(child, true)


func _on_children_changed(_a = null, _b = null) -> void:
	_sync_groups()


## One group per open slot, in slot order, right after the panel.
func _sync_groups() -> void:
	var keys := device.open_slot_keys()
	for key in _groups.keys():
		if not keys.has(key):
			var gone: DeviceSlotGroup = _groups[key]
			_groups.erase(key)
			remove_child(gone)
			gone.queue_free()
	for i in keys.size():
		var group: DeviceSlotGroup = _groups.get(keys[i])
		if group == null:
			group = DeviceSlotGroup.new()
			group.setup(device, keys[i])
			group.context_menu_requested.connect(context_menu_requested.emit)
			add_child(group)
			_groups[keys[i]] = group
		move_child(group, i + 1)
