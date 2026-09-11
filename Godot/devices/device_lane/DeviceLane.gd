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


func _notification(what: int) -> void:
	"""Handle drag notifications to show/hide drop zones."""
	if what == NOTIFICATION_DRAG_BEGIN:
		_create_drop_zones()
	elif what == NOTIFICATION_DRAG_END:
		_cleanup_drop_zones()


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
	
	# Clean up drop zones
	_cleanup_drop_zones()
	
	for node in devices.get_children():
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


func find_device_panel(device_instance : DeviceInstance) -> DevicePanel:
	for dp in devices.get_children():
		if dp is DevicePanel:
			if dp.device == device_instance:
				return dp
	
	return null


func _on_channel_device_remmoved(d_position : int, device_id : String):
	var dp : DevicePanel = devices.get_child(d_position)
	if dp is DevicePanel:
		if dp.device.position != d_position:
			logger.error("[DeviceLane] Device panel at position %d is not the same as the device instance %s" % [d_position, device_id])
			return

		devices.remove_child(dp)
		dp.queue_free()
	else:
		logger.error("[DeviceLane] Device panel not found for device instance %s at position %d" % [device_id, d_position])


func _on_channel_device_moved(from_position: int, to_position: int):
	"""Handle device moved signal - reorder DevicePanel nodes."""
	if not channel:
		return
	
	# Find the DevicePanel that was moved by finding the device at the new position
	var moved_device = channel.get_device(to_position)
	if not moved_device:
		logger.error("[DeviceLane] Device not found at position %d after move" % to_position)
		return
	
	var moved_panel = find_device_panel(moved_device)
	if not moved_panel:
		logger.error("[DeviceLane] DevicePanel not found for device at position %d" % to_position)
		return
	
	# Get all DevicePanel children and their positions
	var device_panels: Array[DevicePanel] = []
	for child in devices.get_children():
		if child is DevicePanel:
			device_panels.append(child)
	
	# Sort panels by their device positions to determine correct order
	device_panels.sort_custom(func(a: DevicePanel, b: DevicePanel): return a.device.position < b.device.position)
	
	# Remove all DevicePanels temporarily (keep DropZones if any)
	for panel in device_panels:
		devices.remove_child(panel)
	
	# Re-add panels in correct order
	for panel in device_panels:
		devices.add_child(panel)
	
	logger.info("[DeviceLane] DevicePanel reordered from position %d to %d" % [from_position, to_position])


func _on_channel_name_changed(ch_name : String):
	header_label.text = ch_name


func _on_channel_color_changed(c : Color):
	var sb := _get_header_stylebox()
	sb.bg_color = c


# ============================================================================
# DRAG AND DROP ZONES
# ============================================================================

func _create_drop_zone(d_position: int) -> DropZone:
	var drop_zone = DropZone.new()
	drop_zone.orientation = DropZone.Orientation.VERTICAL
	drop_zone.dropzone_size = 16.0
	drop_zone.always_show = true
	drop_zone.line_position = DropZone.LinePosition.START
	drop_zone.idle_thickness = 16.0
	drop_zone.available_thickness = 16.0
	drop_zone.hover_thickness = 16.0
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
	"""Create DropZone instances between each DevicePanel for reordering."""
	if not channel:
		return
	
	_cleanup_drop_zones()
	
	# Get all DevicePanel children and store them temporarily
	var device_panels: Array[DevicePanel] = []
	
	for child in devices.get_children():
		if child is DevicePanel:
			device_panels.append(child)
			devices.remove_child(child)
	
	# Now rebuild: insert drop zone, then panel, then drop zone, etc.
	var num_panels = device_panels.size()
	for i in range(num_panels):
		# Drop zone before this panel
		var drop_zone = _create_drop_zone(i)
		
		devices.add_child(drop_zone)
		drop_zones.append(drop_zone)
		
		# Add the panel back
		devices.add_child(device_panels[i])
	
	# Add final drop zone after last panel (or as the only drop zone if no panels)
	if num_panels > 0:
		# Add drop zone after last panel
		var drop_zone = _create_drop_zone(num_panels)
		devices.add_child(drop_zone)
		drop_zones.append(drop_zone)


func _cleanup_drop_zones() -> void:
	"""Remove all drop zones."""
	for drop_zone in drop_zones:
		if is_instance_valid(drop_zone):
			drop_zone.queue_free()
	drop_zones.clear()


func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Return drag data (not used for drop zones, but required by set_drag_forwarding)."""
	return null


func _can_drop_data_at_position(_at_position: Vector2, data: Variant, d_position: int = -1) -> bool:
	"""Check if we can drop data at the specified position."""
	if not channel:
		return false
	
	# Allow DeviceInstance for reordering
	if data is DeviceInstance:
		var device_inst = data as DeviceInstance
		# Check if this device belongs to this channel
		if device_inst.channel_id != channel.id:
			return false
		# Don't allow dropping at the same position
		if device_inst.position == d_position:
			return false
		return true
	
	# Allow Asset for adding new devices
	elif data is Asset:
		var asset = data as Asset
		
		# Handle SFZ file drops (can only be dropped on INSTRUMENT channels)
		if asset.type == Asset.TYPE.SFZ:
			return channel.channel_type == Channel.ChannelType.INSTRUMENT
		
		# Handle device drops
		if asset.type != Asset.TYPE.Device:
			return false
		
		# Get the device metadata to check its category
		var device = AssetService.get_device(asset.path)
		if not device:
			return false
		
		# INSTRUMENT devices can only be dropped on INSTRUMENT channels
		if device.category == Device.DeviceCategory.Instrument:
			return channel.channel_type == Channel.ChannelType.INSTRUMENT
		
		# EFFECT devices can be dropped on any channel (not Master if we want to restrict)
		return not channel.is_master
	
	return false


func _drop_data_at_position(_at_position: Vector2, data: Variant, d_position : int = -1) -> void:
	"""Handle dropping data at the specified position."""
	if not channel:
		return
	
	# Handle DeviceInstance (reordering)
	if data is DeviceInstance:
		var device_inst = data as DeviceInstance
		if device_inst.channel_id != channel.id:
			logger.error("Not Yet Implemented: Dropping device from another channel")
			return
		
		var from_position = device_inst.position
		
		# Adjust target position if moving forward (we're removing before inserting)
		var to_position = d_position
		if from_position < to_position:
			to_position -= 1
		
		if from_position != to_position:
			HistoryUtil.execute(DeviceMoveCommand.new(channel, from_position, to_position))
		return
	
	# Handle Asset (adding new device)
	if data is Asset:
		var asset = data as Asset
		
		# Handle SFZ file drops
		if asset.type == Asset.TYPE.SFZ:
			_handle_sfz_drop_at_position(asset, d_position)
			return
		
		# Handle device drops
		if asset.type != Asset.TYPE.Device:
			return
		
		logger.info("Device dropped on channel %d at position %d: %s" % [channel.id, d_position, asset.name])
		
		# Get the device metadata
		var device = AssetService.get_device(asset.path)
		if not device:
			logger.error("Failed to get device: %s" % asset.path)
			return
		
		# Create device instance and add to channel at specified position
		var device_instance = DeviceInstance.new(device, channel.id, d_position)
		HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, d_position))
		logger.info("Device added to channel at position %d: %s" % [d_position, device.device_id])


func _handle_sfz_drop_at_position(asset: Asset, position: int) -> void:
	"""Handle dropping an SFZ file at a specific position."""
	logger.info("SFZ dropped on channel %d at position %d: %s" % [channel.id, position, asset.name])
	
	# Get the sfizz device from AssetService
	var sfizz_device = AssetService.get_device("sonara.builtin.sfizz")
	if not sfizz_device:
		logger.error("Failed to get sfizz device")
		return
	
	# Create sfizz device instance and add to channel at specified position
	var device_instance = DeviceInstance.new(sfizz_device, channel.id, position)
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, position))
	
	# Load the SFZ file into the device
	# Give the engine a moment to create the device before loading the file
	await get_tree().create_timer(0.1).timeout
	device_instance.load_file(asset.path)
	
	logger.info("SFZ loaded into channel at position %d: %s" % [position, asset.name])

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
	if not channel or not data is Asset:
		return false

	# Handle SFZ file drops (can only be dropped on INSTRUMENT channels)
	if data.type == Asset.TYPE.SFZ:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT

	# Handle device drops
	if data.type != Asset.TYPE.Device:
		return false

	# Get the device metadata to check its category
	var device = AssetService.get_device(data.path)
	if not device:
		return false

	# INSTRUMENT devices can only be dropped on INSTRUMENT channels
	if device.category == Device.DeviceCategory.Instrument:
		return channel.channel_type == Channel.ChannelType.INSTRUMENT

	# EFFECT devices can be dropped on any channel (not Master if we want to restrict)
	# Allow effects on regular channels and bus channels
	return not channel.is_master


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Handle dropping a device or SFZ file on this device lane (fallback for non-position drops)."""
	if not data is Asset or not channel:
		return

	var asset = data as Asset
	
	# Handle SFZ file drops
	if asset.type == Asset.TYPE.SFZ:
		_handle_sfz_drop(asset)
		return
	
	# Handle device drops
	if asset.type != Asset.TYPE.Device:
		return

	logger.info("Device dropped on channel %d: %s" % [channel.id, asset.name])

	# Get the device metadata
	var device = AssetService.get_device(asset.path)
	if not device:
		logger.error("Failed to get device: %s" % asset.path)
		return

	# Create device instance and add to channel at end (-1 means append)
	var device_instance = DeviceInstance.new(device, channel.id, channel.get_device_count())
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, -1))
	logger.info("Device added to channel: %s" % device.device_id)


func _handle_sfz_drop(asset: Asset) -> void:
	"""Handle dropping an SFZ file on this device lane (fallback for non-position drops)."""
	logger.info("SFZ dropped on channel %d: %s" % [channel.id, asset.name])
	
	# Get the sfizz device from AssetService
	var sfizz_device = AssetService.get_device("sonara.builtin.sfizz")
	if not sfizz_device:
		logger.error("Failed to get sfizz device")
		return
	
	# Create sfizz device instance and add to channel at end (-1 means append)
	var device_instance = DeviceInstance.new(sfizz_device, channel.id, channel.get_device_count())
	HistoryUtil.execute(DeviceAddCommand.new(channel, device_instance, -1))
	
	# Load the SFZ file into the device
	# Give the engine a moment to create the device before loading the file
	await get_tree().create_timer(0.1).timeout
	device_instance.load_file(asset.path)
	
	logger.info("SFZ loaded into channel: %s" % asset.name)
