class_name DeviceLane extends HBoxContainer

const DevicePanelScene : PackedScene = preload("res://devices/device_lane/DevicePanel.tscn")

var logger : Log = Log.make("DeviceLane")

@onready var header: Panel = $Header
@onready var header_label: VerticalLabel = $Header/Label

@onready var devices: HBoxContainer = $Content/ScrollContainer/Devices

@onready var device_context_menu: DeviceContextMenu = $DeviceContextMenu

var channel : Channel
var drop_zones: Array[DropZone] = []  # Track drop zones for cleanup
var current_project: Project = null  # Track which project we're listening to

func _ready():
	if devices:
		devices.add_theme_constant_override("separation", 0)
	clear()
	
	# Connect to the Mixer's channel_focused signal via Sonara.editor
	Sonara.editor.channel_focused.connect(_on_channel_focused)
	
	# Connect to project lifecycle to clean up when project closes
	Sonara.editor.project_closed.connect(_on_project_closed)
	
	# Connect to project opened to listen for channel removal
	Sonara.editor.project_opened.connect(_on_project_opened)
	
	# If project already exists, connect to it
	if Sonara.editor.project:
		_connect_to_project(Sonara.editor.project)


func _on_channel_focused(focused_channel: Channel):
	"""Called when a channel is focused in the mixer."""
	if focused_channel:
		bind_to_channel(focused_channel)


func _on_project_opened(project: Project):
	"""Called when a project is opened - connect to channel removal signal."""
	_connect_to_project(project)


func _connect_to_project(project: Project):
	"""Connect to project's channel_removed signal."""
	# Disconnect from previous project if any
	if current_project:
		if current_project.channel_removed.is_connected(_on_channel_removed):
			current_project.channel_removed.disconnect(_on_channel_removed)
	
	# Connect to new project
	current_project = project
	if project:
		project.channel_removed.connect(_on_channel_removed)


func _on_project_closed():
	"""Called when a project is closed - clean up device lane."""
	# Disconnect from project signals
	if current_project:
		if current_project.channel_removed.is_connected(_on_channel_removed):
			current_project.channel_removed.disconnect(_on_channel_removed)
		current_project = null
	
	# Unbind from current channel if any
	if channel:
		unbind()
		channel = null
	
	# Clear all device panels
	clear()


func _on_channel_removed(removed_channel: Channel):
	"""Called when a channel is removed from the project."""
	# If the removed channel is the one we're bound to, clear ourselves
	if channel and channel.id == removed_channel.id:
		logger.info("[DeviceLane] Bound channel removed, clearing device lane")
		unbind()
		channel = null
		clear()

func _get_header_stylebox() -> StyleBoxFlat:
	return header.get_theme_stylebox("panel")


func unbind():
	channel.name_changed.disconnect(_on_channel_name_changed)
	channel.color_changed.disconnect(_on_channel_color_changed)
	channel.device_added.disconnect(_add_device)
	channel.device_removed.disconnect(_on_channel_device_remmoved)
	channel.device_moved.disconnect(_on_channel_device_moved)


func clear():
	header_label.text = "N/A"
	_cleanup_drop_zones()
	for node in devices.get_children():
		devices.remove_child(node)
		node.queue_free()


func bind_to_channel(channel : Channel):
	# already bound to this channel?
	if self.channel == channel:
		return
	
	# unbind to previously shown channel
	if self.channel:
		unbind()
	
	# clear any device controls
	clear()
	
	# bind to new channel
	self.channel = channel
	
	# set heade label and bg color
	header_label.text = channel.name
	var sb := _get_header_stylebox()
	sb.bg_color = channel.color
	
	# set up all devices
	for device_inst : DeviceInstance in channel.devices:
		_add_device(device_inst, 0)
	
	# connect to channel events
	channel.name_changed.connect(_on_channel_name_changed)
	channel.color_changed.connect(_on_channel_color_changed)
	channel.device_added.connect(_add_device)
	channel.device_removed.connect(_on_channel_device_remmoved)
	channel.device_moved.connect(_on_channel_device_moved)


func _add_device(device_instance : DeviceInstance, _position : int):
	var dp:DevicePanel = DevicePanelScene.instantiate()
	dp.bind_to_device(device_instance)
	
	dp.request_context_menu.connect(_on_device_panel_request_context_menu.bind(device_instance))
	
	devices.add_child(dp)
	_create_drop_zones()


func find_device_panel(device_instance : DeviceInstance) -> DevicePanel:
	for dp in devices.get_children():
		if dp is DevicePanel:
			if dp.device == device_instance:
				return dp
	
	return null


func _on_channel_device_remmoved(d_position : int, device_id : String):
	var dp: DevicePanel = null
	for child in devices.get_children():
		if child is DevicePanel and child.device and child.device.id == device_id:
			dp = child
			break
	if dp == null:
		logger.error("[DeviceLane] Device panel not found for device instance %s at position %d" % [device_id, d_position])
		return
	devices.remove_child(dp)
	dp.queue_free()
	_create_drop_zones()


func _on_channel_device_moved(from_position: int, to_position: int):
	"""Handle device moved signal - reorder DevicePanel nodes."""
	_create_drop_zones()
	logger.info("[DeviceLane] DevicePanel reordered from position %d to %d" % [from_position, to_position])


func _on_channel_name_changed(ch_name : String):
	header_label.text = ch_name


func _on_channel_color_changed(c : Color):
	var sb := _get_header_stylebox()
	sb.bg_color = c


# ============================================================================
# DRAG AND DROP ZONES
# ============================================================================

## Insert-point spacer between DevicePanels (invisible until a drag starts).
func _create_drop_zone(d_position: int) -> DropZone:
	var drop_zone = DropZone.create_insert_spacer(true, 16.0)
	drop_zone.set_drag_forwarding(
		_get_drag_data.bind(),
		_can_drop_data_at_position.bind(d_position),
		_drop_data_at_position.bind(d_position)
	)
	return drop_zone


## Keep invisible spacer drop zones interleaved with the current DevicePanels.
func _create_drop_zones() -> void:
	if not channel or devices == null:
		return
	var device_panels: Array[DevicePanel] = []
	for child in devices.get_children():
		if child is DevicePanel:
			device_panels.append(child)
	device_panels.sort_custom(func(a: DevicePanel, b: DevicePanel): return a.device.position < b.device.position)
	drop_zones = DropZone.rebuild_insert_layout(devices, device_panels, _create_drop_zone, false)


## Remove spacer drop zones from the device row.
func _cleanup_drop_zones() -> void:
	for drop_zone in drop_zones:
		if is_instance_valid(drop_zone):
			var parent := drop_zone.get_parent()
			if parent:
				parent.remove_child(drop_zone)
			drop_zone.queue_free()
	drop_zones.clear()


func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Return drag data (not used for drop zones, but required by set_drag_forwarding)."""
	return null


func _can_drop_data_at_position(_at_position: Vector2, data: Variant, d_position: int = -1) -> bool:
	"""Check if we can drop data at the specified position."""
	if not channel:
		return false
	if data is DeviceInstance:
		if not DeviceDropUtil.can_drop_instance_on_host(channel, data, null):
			return false
		if data.get_parent_device() == null and data.position == d_position:
			return false
		return true
	if data is Asset:
		return DeviceDropUtil.can_drop_asset_on_channel(channel, data)
	return false


func _drop_data_at_position(_at_position: Vector2, data: Variant, d_position : int = -1) -> void:
	"""Handle dropping data at the specified position."""
	if not channel:
		return
	if data is DeviceInstance:
		DeviceDropUtil.drop_instance(channel, data, null, d_position)
		return
	if data is Asset:
		await DeviceDropUtil.drop_asset(channel, data, d_position, null, get_tree())


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_device_panel_request_context_menu(device_instance : DeviceInstance) -> void:
	device_context_menu.bind_to_device(device_instance)
	var c_pos = get_global_mouse_position()
	var c_size = device_context_menu.get_contents_minimum_size()
	device_context_menu.popup(Rect2(c_pos, c_size))
	device_context_menu.show()


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Check if we can drop a device or SFZ file on this device lane."""
	if not channel:
		return false
	if data is DeviceInstance:
		return DeviceDropUtil.can_drop_instance_on_host(channel, data, null)
	if data is Asset:
		return DeviceDropUtil.can_drop_asset_on_channel(channel, data)
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Handle dropping a device or SFZ file on this device lane (fallback for non-position drops)."""
	if not channel:
		return
	if data is DeviceInstance:
		DeviceDropUtil.drop_instance(channel, data, null, -1)
		return
	if data is Asset:
		await DeviceDropUtil.drop_asset(channel, data, -1, null, get_tree())
