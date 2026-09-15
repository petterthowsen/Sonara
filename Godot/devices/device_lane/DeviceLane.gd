class_name DeviceLane extends HBoxContainer

const DevicePanelScene : PackedScene = preload("res://devices/device_lane/DevicePanel.tscn")

var logger : Log = Log.make("DeviceLane")

@onready var header: Panel = $Header
@onready var header_label: VerticalLabel = $Header/Label

@onready var devices: HBoxContainer = $Content/ScrollContainer/Devices

@onready var device_context_menu: DeviceContextMenu = $DeviceContextMenu

var channel : Channel
## Mixer parent of the bound channel, shown as a clickable header left of the channel header.
var _parent_channel: Channel = null
var _parent_header: Panel = null
var _parent_header_label: VerticalLabel = null
var _drop_host := DeviceChainDropHost.new(true, 16.0, false)
## A drum pad return shows its pad lane (pad device + own devices), rebuilt on every change.
var _pad_lane := PadLaneWatcher.new()
var current_project: Project = null  # Track which project we're listening to

func _ready():
	if devices:
		devices.add_theme_constant_override("separation", 0)
	_create_parent_header()
	_pad_lane.changed.connect(_on_pad_lane_changed)
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
	_bind_parent_header(null)
	channel.hierarchy_changed.disconnect(_refresh_parent_header)
	channel.name_changed.disconnect(_on_channel_name_changed)
	channel.color_changed.disconnect(_on_channel_color_changed)
	channel.device_added.disconnect(_add_device)
	channel.device_removed.disconnect(_on_channel_device_remmoved)
	channel.device_moved.disconnect(_on_channel_device_moved)
	_drop_host.bind(null)
	_pad_lane.bind(null)


func clear():
	header_label.text = "N/A"
	_bind_parent_header(null)
	_clear_devices()


func _clear_devices() -> void:
	_drop_host.clear()
	for node in devices.get_children():
		devices.remove_child(node)
		node.queue_free()


## Recreate every panel in lane order (pad lanes only; plain channels update incrementally).
func _rebuild_devices() -> void:
	if channel == null:
		return
	_clear_devices()
	var lane: Array[DeviceInstance] = PadLane.devices(channel) if _pad_lane.active() else channel.devices
	for device_inst in lane:
		_add_device_panel(device_inst)
	_create_drop_zones()


func _on_pad_lane_changed() -> void:
	if _pad_lane.active():
		_rebuild_devices()


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
	_pad_lane.bind(channel)
	
	# set heade label and bg color
	header_label.text = channel.name
	var sb := _get_header_stylebox()
	sb.bg_color = channel.color
	
	# set up all devices
	_rebuild_devices()
	
	# connect to channel events
	channel.hierarchy_changed.connect(_refresh_parent_header)
	_refresh_parent_header()
	channel.name_changed.connect(_on_channel_name_changed)
	channel.color_changed.connect(_on_channel_color_changed)
	channel.device_added.connect(_add_device)
	channel.device_removed.connect(_on_channel_device_remmoved)
	channel.device_moved.connect(_on_channel_device_moved)


func _add_device(device_instance : DeviceInstance, _position : int):
	if _pad_lane.active():
		return
	_add_device_panel(device_instance)
	_create_drop_zones()


func _add_device_panel(device_instance: DeviceInstance) -> void:
	var dp:DevicePanel = DevicePanelScene.instantiate()
	dp.bind_to_device(device_instance)
	
	dp.request_context_menu.connect(_on_device_panel_request_context_menu.bind(device_instance))
	
	devices.add_child(dp)


func find_device_panel(device_instance : DeviceInstance) -> DevicePanel:
	for dp in devices.get_children():
		if dp is DevicePanel:
			if dp.device == device_instance:
				return dp
	
	return null


func _on_channel_device_remmoved(d_position : int, device_id : String):
	if _pad_lane.active():
		return
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
# PARENT HEADER
# ============================================================================

## Build the parent header as a copy of the channel header, placed to its left.
func _create_parent_header() -> void:
	_parent_header = header.duplicate() as Panel
	_parent_header.name = "ParentHeader"
	_parent_header.custom_minimum_size.x = 32
	_parent_header.add_theme_stylebox_override("panel", _get_header_stylebox().duplicate())
	_parent_header.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_parent_header_label = _parent_header.get_node("Label") as VerticalLabel
	_parent_header_label.font_size = 16
	_parent_header_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_parent_header.gui_input.connect(_on_parent_header_gui_input)
	_parent_header.visible = false
	add_child(_parent_header)
	move_child(_parent_header, header.get_index())


## Show the bound channel's mixer parent, or hide the header for a top-level channel.
func _refresh_parent_header() -> void:
	var parent: Channel = null
	if channel and channel.parent_channel_id >= 0:
		var project := channel.get_project()
		if project:
			parent = project.get_channel_by_id(channel.parent_channel_id)
	_bind_parent_header(parent)


## Point the parent header at `parent` (null hides it) and follow its name and color.
func _bind_parent_header(parent: Channel) -> void:
	if _parent_header == null or parent == _parent_channel:
		return
	if _parent_channel:
		_parent_channel.name_changed.disconnect(_on_parent_name_changed)
		_parent_channel.color_changed.disconnect(_on_parent_color_changed)
	_parent_channel = parent
	_parent_header.visible = parent != null
	if parent == null:
		return
	parent.name_changed.connect(_on_parent_name_changed)
	parent.color_changed.connect(_on_parent_color_changed)
	_on_parent_name_changed(parent.name)
	_on_parent_color_changed(parent.color)


func _on_parent_name_changed(ch_name: String) -> void:
	_parent_header_label.text = ch_name
	_parent_header.tooltip_text = "Go to %s" % ch_name


func _on_parent_color_changed(c: Color) -> void:
	(_parent_header.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = c


## Clicking the parent header selects the parent the same way a mixer click does.
func _on_parent_header_gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or _parent_channel == null:
		return
	accept_event()
	Sonara.editor.mixer.select_channel(_parent_channel)


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
	# Pad lane panels are already in lane order; plain chains follow device position.
	if not _pad_lane.active():
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
