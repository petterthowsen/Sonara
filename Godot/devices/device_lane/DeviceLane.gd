class_name DeviceLane extends HBoxContainer

const DevicePanelScene : PackedScene = preload("res://devices/device_lane/DevicePanel.tscn")

var logger : Log = Log.make("DeviceLane")

@onready var header: Panel = $Header
@onready var header_label: VerticalLabel = $Header/Label

@onready var devices: HBoxContainer = $Content/ScrollContainer/Devices

@onready var device_context_menu: DeviceContextMenu = $DeviceContextMenu

var channel : Channel
var _drop_host := DeviceChainDropHost.new(true, 16.0, false)
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
	_drop_host.bind(null)


func clear():
	header_label.text = "N/A"
	_drop_host.clear()
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
	_drop_host.bind(channel)
	
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

## Keep invisible spacer drop zones interleaved with the current DevicePanels.
func _create_drop_zones() -> void:
	if not channel or devices == null:
		return
	var device_panels: Array[DevicePanel] = []
	for child in devices.get_children():
		if child is DevicePanel:
			device_panels.append(child)
	device_panels.sort_custom(func(a: DevicePanel, b: DevicePanel): return a.device.position < b.device.position)
	_drop_host.rebuild(devices, device_panels)


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

## Drops on the lane outside a spacer append to the channel.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return _drop_host.can_drop(data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_drop_host.drop(data)
