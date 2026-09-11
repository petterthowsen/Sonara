# ChannelDeviceList.gd
#
# Shows a vertical list of devices on a channel with their parameters as CompactDevicePanel.
# Updates dynamically when devices are added/removed.
# For use in the MixerChannel component.
#
# Designed to show Compact Device components as opposed to full Device (as used in the full device strip)

class_name ChannelDeviceList extends PanelContainer

var logger : Log = Log.make("ChannelDeviceList")

const CompactDevicePanelScene = preload("res://devices/compact/CompactDevicePanel.tscn")

@onready var scroll_container : ScrollContainer = $ScrollContainer
@onready var vbox : VBoxContainer = $ScrollContainer/VBoxContainer
@onready var device_context_menu: DeviceContextMenu = $DeviceContextMenu

# ============================================================================
# PROPERTIES
# ============================================================================
@export var collapsed_by_default := true
@export var hide_parameters := false:
	set(hp):
		hide_parameters = hp
		
		if is_inside_tree():
			for dpanel:CompactDevicePanel in device_panels.values():
				dpanel.hide_parameters = hp

var channel: Channel = null
var device_panels: Dictionary[String, CompactDevicePanel] = {}  # Map of device instance ID -> CompactDevicePanel
var drop_zones: Array[DropZone] = []  # Track drop zones for cleanup


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	"""Setup UI after scene loads."""
	# clear devices (in case of testing in editor)
	for node in vbox.get_children():
		node.free()


func _notification(what: int) -> void:
	"""Handle drag notifications to show/hide drop zones."""
	if what == NOTIFICATION_DRAG_BEGIN:
		_create_drop_zones()
	elif what == NOTIFICATION_DRAG_END:
		_cleanup_drop_zones()


# ============================================================================
# PUBLIC METHODS
# ============================================================================

## Bind this list to a channel
func bind_to_channel(p_channel: Channel) -> void:
	"""Setup this list to show devices from a channel.

	Args:
		p_channel: The Channel to display devices from
	"""
	# Disconnect from previous channel if any
	if channel:
		channel.device_added.disconnect(_on_device_added)
		channel.device_removed.disconnect(_on_device_removed)
		channel.device_moved.disconnect(_on_device_moved)

	channel = p_channel

	# Connect to device signals
	channel.device_added.connect(_on_device_added)
	channel.device_removed.connect(_on_device_removed)
	channel.device_moved.connect(_on_device_moved)

	# Populate initial devices
	_populate_devices()

	print("[ChannelDeviceList] Bound to channel %d (%s)" % [channel.id, channel.name])


## Refresh the device list from channel
func _populate_devices() -> void:
	"""Refresh the display to show all current devices on the channel."""
	# Clean up drop zones first
	_cleanup_drop_zones()
	
	# Clear existing panels
	for device_id in device_panels:
		if device_panels[device_id]:
			device_panels[device_id].queue_free()
	device_panels.clear()
	for n in vbox.get_children():
		n.queue_free() 

	# Add panel for each device
	if not channel:
		return

	for i in range(channel.get_device_count()):
		var device_instance = channel.get_device(i)
		if device_instance:
			_add_device_panel(device_instance, i)


## Add a panel for a device
func _add_device_panel(device_instance: DeviceInstance, position: int) -> void:
	"""Create and add a panel for a device instance.

	Args:
		device_instance: The DeviceInstance to create a panel for
		position: Position in device chain
	"""
	print("[ChannelDeviceList] _add_device_panel() called for device: %s at position %d" % [device_instance.device.name, position])

	# Instantiate panel
	var panel: CompactDevicePanel
	panel = CompactDevicePanelScene.instantiate()
	print("[ChannelDeviceList] Panel instantiated")
	
	panel.collapsed = collapsed_by_default
	panel.hide_parameters = hide_parameters
	
	# Setup the panel
	panel.setup(device_instance, position)
	print("[ChannelDeviceList] Panel setup complete")

	# Add to vbox
	vbox.add_child(panel)
	print("[ChannelDeviceList] Panel added to vbox. Total panels now: %d" % vbox.get_child_count())
	
	# listen to right-click
	panel.request_context_menu.connect(_on_device_panel_request_context_menu.bind(device_instance))
	
	# Track the panel
	device_panels[device_instance.id] = panel


## Remove a panel for a device
func _remove_device_panel_at(position: int) -> void:
	"""Remove the panel for a device instance.

	Args:
		device_id: position
	"""
	for panel:CompactDevicePanel in device_panels.values():
		if panel.device_instance.position == position:
			device_panels.erase(panel.device_instance.id)
			panel.queue_free()
			return
	
	logger.error("[ChannelDeviceList] Device panel not found at position %d" % position)
	


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_device_added(device_instance: DeviceInstance, position: int) -> void:
	"""Handle device added to channel."""
	_add_device_panel(device_instance, position)
	print("[ChannelDeviceList] Device added at position %d" % position)


func _on_device_removed(position: int, _device_id: String) -> void:
	"""Handle device removed from channel."""
	_remove_device_panel_at(position)
	print("[ChannelDeviceList] Device removed from position %d" % position)


func _on_device_moved(from_position: int, to_position: int):
	"""Handle device moved signal - reorder CompactDevicePanel nodes."""
	if not channel:
		return
	
	# Get all CompactDevicePanel children and sort by device position
	var device_panel_list: Array[CompactDevicePanel] = []
	for child in vbox.get_children():
		if child is CompactDevicePanel:
			device_panel_list.append(child)
	
	# Sort panels by their device positions to determine correct order
	device_panel_list.sort_custom(func(a: CompactDevicePanel, b: CompactDevicePanel): return a.device_instance.position < b.device_instance.position)
	
	# Remove all CompactDevicePanels temporarily (keep DropZones if any)
	for panel in device_panel_list:
		vbox.remove_child(panel)
	
	# Re-add panels in correct order
	for panel in device_panel_list:
		vbox.add_child(panel)
	
	logger.info("[ChannelDeviceList] DevicePanel reordered from position %d to %d" % [from_position, to_position])


func _on_device_panel_request_context_menu(device_instance: DeviceInstance) -> void:
	device_context_menu.bind_to_device(device_instance)
	var c_pos = get_global_mouse_position()
	var c_size = device_context_menu.get_contents_minimum_size()
	device_context_menu.popup(Rect2(c_pos, c_size))
	device_context_menu.show()


# ============================================================================
# DRAG AND DROP ZONES
# ============================================================================

func _create_drop_zone(d_position: int) -> DropZone:
	var drop_zone = DropZone.new()
	drop_zone.orientation = DropZone.Orientation.HORIZONTAL
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
	"""Create DropZone instances between each CompactDevicePanel for reordering."""
	if not channel:
		return
	
	_cleanup_drop_zones()
	
	# Get all CompactDevicePanel children
	var panel_list: Array[CompactDevicePanel] = []
	
	for child in vbox.get_children():
		if child is CompactDevicePanel:
			panel_list.append(child)
			vbox.remove_child(child)
	
	# Now rebuild: insert drop zone, then panel, then drop zone, etc.
	var num_panels = panel_list.size()
	for i in range(num_panels):
		# Drop zone before this panel
		var drop_zone = _create_drop_zone(i)
		
		vbox.add_child(drop_zone)
		drop_zones.append(drop_zone)
		
		# Add the panel back
		vbox.add_child(panel_list[i])
	
	# Add final drop zone after last panel (or as the only drop zone if no panels)
	if num_panels == 0:
		# No panels - create a single drop zone at position 0
		var drop_zone = _create_drop_zone(0)
		vbox.add_child(drop_zone)
		drop_zones.append(drop_zone)
	else:
		# Add drop zone after last panel
		var drop_zone = _create_drop_zone(num_panels)
		vbox.add_child(drop_zone)
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


func _drop_data_at_position(_at_position: Vector2, data: Variant, d_position: int = -1) -> void:
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
