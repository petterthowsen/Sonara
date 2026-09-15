# NestedDeviceList.gd
# Horizontal strip of child DevicePanels plus drop zones, bound to a container DeviceInstance.
# Chain shows every child and sizes the folder to fit them; Layer/Drum Machine show one focused child.
class_name NestedDeviceList extends Control

const DevicePanelScene: PackedScene = preload("res://devices/device_lane/DevicePanel.tscn")

@onready var scroll: ScrollContainer = $ScrollContainer
@onready var devices: HBoxContainer = $ScrollContainer/Devices
@onready var device_context_menu: DeviceContextMenu = $DeviceContextMenu
@onready var empty_hint: Label = $EmptyHint

var channel: Channel = null
var container: DeviceInstance = null
var focus_child: DeviceInstance = null
var _drop_host := DeviceChainDropHost.new(true, 12.0)
var _panels: Dictionary = {}  # instance id -> Control (DevicePanel)


## Wire empty-state, scroll policy, and the child HBox sizing.
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if devices:
		devices.size_flags_horizontal = Control.SIZE_FILL
		devices.add_theme_constant_override("separation", 0)
	if empty_hint:
		empty_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if device_context_menu:
		device_context_menu.hide()
	_apply_scroll_policy()
	_update_empty_hint()


## Size to the visible children so the DeviceLane is the only scroller.
func _get_minimum_size() -> Vector2:
	if devices:
		return devices.get_combined_minimum_size()
	return Vector2(200, 120)


## Bind this list to a container's children.
func bind_to_container(p_container: DeviceInstance) -> void:
	if container == p_container:
		await refresh()
		return
	_unbind()
	container = p_container
	channel = container.get_channel() if container else null
	_drop_host.bind(channel, container)
	_apply_scroll_policy()
	if container == null:
		_clear_panels()
		return
	container.child_added.connect(_on_child_added)
	container.child_removed.connect(_on_child_removed)
	container.child_moved.connect(_on_child_moved)
	await refresh()


## Show only `child` for Layer/Drum Machine, or every child when `child` is null (Chain).
func set_focus_child(child: DeviceInstance) -> void:
	if focus_child == child:
		return
	focus_child = child
	await refresh()


## Rebuild panels from the bound container (honors `focus_child` for Layer/Drum).
func refresh() -> void:
	_clear_panels()
	if container == null:
		return
	if _focuses_one_child():
		if focus_child and container.children.has(focus_child):
			await _add_child_panel(focus_child)
	else:
		for child in container.children:
			await _add_child_panel(child)
	_apply_scroll_policy()
	_update_empty_hint()
	_create_drop_zones()
	_notify_content_size()


## Stop listening to the previous container.
func _unbind() -> void:
	if container:
		if container.child_added.is_connected(_on_child_added):
			container.child_added.disconnect(_on_child_added)
		if container.child_removed.is_connected(_on_child_removed):
			container.child_removed.disconnect(_on_child_removed)
		if container.child_moved.is_connected(_on_child_moved):
			container.child_moved.disconnect(_on_child_moved)
	container = null
	channel = null
	focus_child = null
	_drop_host.bind(null)


## Free every child panel and drop zone immediately so leftover nodes do not inflate min size.
func _clear_panels() -> void:
	_drop_host.clear()
	if devices:
		for child in devices.get_children():
			devices.remove_child(child)
			child.queue_free()
	_panels.clear()
	_update_empty_hint()


## Create a DevicePanel for `device_instance` and keep folder width in sync with it.
func _add_child_panel(device_instance: DeviceInstance) -> void:
	var panel: DevicePanel = DevicePanelScene.instantiate()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.minimum_size_changed.connect(_notify_content_size)
	panel.request_context_menu.connect(_on_device_panel_request_context_menu.bind(device_instance))
	devices.add_child(panel)
	_panels[device_instance.id] = panel
	await panel.bind_to_device(device_instance)


## Rebuild when a child is inserted into the container.
func _on_child_added(_device_instance: DeviceInstance, _position: int) -> void:
	refresh()


## Rebuild when a child is removed; drop focus if that child is gone.
func _on_child_removed(_position: int, _device_id: String) -> void:
	if focus_child and not container.children.has(focus_child):
		focus_child = null
	refresh()


## Rebuild when children are reordered.
func _on_child_moved(_from_position: int, _to_position: int) -> void:
	refresh()


## Popup the device context menu at the cursor.
func _on_device_panel_request_context_menu(device_instance: DeviceInstance) -> void:
	device_context_menu.removes_drum_pad = AuxReturnSync.is_drum_machine(container)
	device_context_menu.bind_to_device(device_instance)
	var c_pos = get_global_mouse_position()
	var c_size = device_context_menu.get_contents_minimum_size()
	device_context_menu.popup(Rect2(c_pos, c_size))
	device_context_menu.show()


## Show a hint when the bound container has no children.
func _update_empty_hint() -> void:
	if empty_hint:
		empty_hint.visible = container != null and _panels.is_empty()


## True when only the focused child should be visible (Layer, Drum Machine).
func _focuses_one_child() -> bool:
	return container != null and container.device != null and container.device.container_focuses_one_child()


## Disable inner scrolling so visible children set the folder width.
func _apply_scroll_policy() -> void:
	if devices:
		devices.size_flags_horizontal = Control.SIZE_FILL
		devices.add_theme_constant_override("separation", 0)
	if scroll == null:
		return
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	update_minimum_size()


## Recalculate min size after child DevicePanels finish binding.
func _notify_content_size() -> void:
	update_minimum_size()


## Keep invisible spacer drop zones interleaved with the current child panels.
func _create_drop_zones() -> void:
	if container == null or devices == null:
		return
	var panel_list: Array[Control] = []
	for child in devices.get_children():
		if child is DropZone:
			continue
		panel_list.append(child)
	_drop_host.rebuild(devices, panel_list, _drop_index_for_panel)


## Map a visible-panel index to the container child index (focus mode uses the real position).
func _drop_index_for_panel(visible_index: int) -> int:
	if _focuses_one_child() and focus_child:
		return focus_child.position if visible_index == 0 else focus_child.position + 1
	return visible_index


## Accept a device or asset dropped on empty list space (append).
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return container != null and _drop_host.can_drop(data)


## Append a device or asset as a child of the bound container.
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if container != null:
		_drop_host.drop(data)
