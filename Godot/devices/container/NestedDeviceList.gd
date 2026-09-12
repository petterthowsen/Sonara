# NestedDeviceList.gd
# Horizontal strip of child DevicePanels plus drop zones, bound to a container DeviceInstance.
class_name NestedDeviceList extends Control

const DevicePanelScene: PackedScene = preload("res://devices/device_lane/DevicePanel.tscn")

@onready var devices: HBoxContainer = $ScrollContainer/Devices
@onready var device_context_menu: DeviceContextMenu = $DeviceContextMenu
@onready var empty_hint: Label = $EmptyHint

var channel: Channel = null
var container: DeviceInstance = null
var focus_child: DeviceInstance = null
var drop_zones: Array[DropZone] = []
var _panels: Dictionary = {}  # instance id -> Control (DevicePanel)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if empty_hint:
		empty_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if device_context_menu:
		device_context_menu.hide()
	_update_empty_hint()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		_create_drop_zones()
	elif what == NOTIFICATION_DRAG_END:
		_cleanup_drop_zones()


## Bind this list to a container's children.
func bind_to_container(p_container: DeviceInstance) -> void:
	if container == p_container:
		refresh()
		return
	_unbind()
	container = p_container
	channel = _channel_for(container)
	if container == null:
		_clear_panels()
		return
	container.child_added.connect(_on_child_added)
	container.child_removed.connect(_on_child_removed)
	container.child_moved.connect(_on_child_moved)
	refresh()


## Show only `child`, or every child when `child` is null.
func set_focus_child(child: DeviceInstance) -> void:
	if focus_child == child:
		return
	focus_child = child
	refresh()


## Rebuild panels from the bound container (honors `focus_child`).
func refresh() -> void:
	_clear_panels()
	if container == null:
		return
	if focus_child:
		if container.children.has(focus_child):
			_add_child_panel(focus_child)
	else:
		for child in container.children:
			_add_child_panel(child)
	_update_empty_hint()


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


func _clear_panels() -> void:
	_cleanup_drop_zones()
	if devices:
		for child in devices.get_children():
			child.queue_free()
	_panels.clear()
	_update_empty_hint()


func _add_child_panel(device_instance: DeviceInstance) -> void:
	var panel: DevicePanel = DevicePanelScene.instantiate()
	panel.bind_to_device(device_instance)
	panel.request_context_menu.connect(_on_device_panel_request_context_menu.bind(device_instance))
	devices.add_child(panel)
	_panels[device_instance.id] = panel


func _on_child_added(_device_instance: DeviceInstance, _position: int) -> void:
	refresh()


func _on_child_removed(_position: int, _device_id: String) -> void:
	if focus_child and not container.children.has(focus_child):
		focus_child = null
	refresh()


func _on_child_moved(_from_position: int, _to_position: int) -> void:
	refresh()


func _on_device_panel_request_context_menu(device_instance: DeviceInstance) -> void:
	device_context_menu.bind_to_device(device_instance)
	var c_pos = get_global_mouse_position()
	var c_size = device_context_menu.get_contents_minimum_size()
	device_context_menu.popup(Rect2(c_pos, c_size))
	device_context_menu.show()


func _update_empty_hint() -> void:
	if empty_hint:
		empty_hint.visible = container != null and _panels.is_empty()


func _channel_for(inst: DeviceInstance) -> Channel:
	if inst == null or Sonara.editor == null or Sonara.editor.project == null:
		return null
	return Sonara.editor.project.get_channel_by_id(inst.channel_id)


func _create_drop_zone(d_position: int) -> DropZone:
	var drop_zone = DropZone.new()
	drop_zone.orientation = DropZone.Orientation.VERTICAL
	drop_zone.dropzone_size = 12.0
	drop_zone.always_show = true
	drop_zone.line_position = DropZone.LinePosition.START
	drop_zone.idle_thickness = 12.0
	drop_zone.available_thickness = 12.0
	drop_zone.hover_thickness = 12.0
	drop_zone.idle_color = Color(0.4, 0.4, 0.4, 0.5)
	drop_zone.available_color = Color(0.7, 0.7, 0.7, 0.5)
	drop_zone.hover_color = Color(0.7, 0.7, 0.7, 0.7)
	drop_zone.set_drag_forwarding(
		_get_drag_data.bind(),
		_can_drop_data_at_position.bind(d_position),
		_drop_data_at_position.bind(d_position)
	)
	return drop_zone


func _create_drop_zones() -> void:
	if container == null or devices == null:
		return
	_cleanup_drop_zones()
	var panel_list: Array[Control] = []
	for child in devices.get_children():
		if child is DropZone:
			continue
		panel_list.append(child)
		devices.remove_child(child)
	var num_panels = panel_list.size()
	for i in range(num_panels):
		var drop_zone = _create_drop_zone(_drop_index_for_panel(i))
		devices.add_child(drop_zone)
		drop_zones.append(drop_zone)
		devices.add_child(panel_list[i])
	var end_zone = _create_drop_zone(_drop_index_for_panel(num_panels))
	devices.add_child(end_zone)
	drop_zones.append(end_zone)


## Map a visible-panel index to the container child index (focus mode uses the real position).
func _drop_index_for_panel(visible_index: int) -> int:
	if focus_child:
		return focus_child.position if visible_index == 0 else focus_child.position + 1
	return visible_index


func _cleanup_drop_zones() -> void:
	for drop_zone in drop_zones:
		if is_instance_valid(drop_zone):
			drop_zone.queue_free()
	drop_zones.clear()


func _get_drag_data(_at_position: Vector2) -> Variant:
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if channel == null or container == null:
		return false
	if data is DeviceInstance:
		return DeviceDropUtil.can_drop_instance_on_host(channel, data, container)
	if data is Asset:
		return DeviceDropUtil.can_drop_asset_on_channel(channel, data)
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if channel == null or container == null:
		return
	if data is DeviceInstance:
		DeviceDropUtil.drop_instance(channel, data, container, -1)
		return
	if data is Asset:
		await DeviceDropUtil.drop_asset(channel, data, -1, container, get_tree())


func _can_drop_data_at_position(_at_position: Vector2, data: Variant, d_position: int = -1) -> bool:
	if channel == null or container == null:
		return false
	if data is DeviceInstance:
		if not DeviceDropUtil.can_drop_instance_on_host(channel, data, container):
			return false
		if data.get_parent_device() == container and data.position == d_position:
			return false
		return true
	if data is Asset:
		return DeviceDropUtil.can_drop_asset_on_channel(channel, data)
	return false


func _drop_data_at_position(_at_position: Vector2, data: Variant, d_position: int = -1) -> void:
	if channel == null or container == null:
		return
	if data is DeviceInstance:
		DeviceDropUtil.drop_instance(channel, data, container, d_position)
		return
	if data is Asset:
		await DeviceDropUtil.drop_asset(channel, data, d_position, container, get_tree())
