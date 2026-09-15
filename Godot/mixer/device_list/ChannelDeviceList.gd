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
var _drop_host := DeviceChainDropHost.new(false, 8.0)
## A drum pad return lists its pad lane (pad device + own devices), rebuilt on every change.
var _pad_lane := PadLaneWatcher.new()


# ============================================================================
# LIFECYCLE
# ============================================================================

## Keep the list empty; compact panels are spawned in `_add_device_panel()`.
func _ready() -> void:
	if vbox:
		vbox.add_theme_constant_override("separation", 0)
	_pad_lane.changed.connect(_on_pad_lane_changed)
	for node in vbox.get_children():
		vbox.remove_child(node)
		node.free()


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
	_drop_host.bind(channel)
	_pad_lane.bind(channel)

	# Connect to device signals
	channel.device_added.connect(_on_device_added)
	channel.device_removed.connect(_on_device_removed)
	channel.device_moved.connect(_on_device_moved)

	# Populate initial devices
	_populate_devices()

	logger.info("Bound to channel %d (%s)" % [channel.id, channel.name])


## Refresh the device list from channel
func _populate_devices() -> void:
	"""Refresh the display to show all current devices on the channel."""
	# Clean up drop zones first
	_drop_host.clear()
	
	# Clear existing panels
	for device_id in device_panels:
		if device_panels[device_id]:
			var panel := device_panels[device_id]
			var parent := panel.get_parent()
			if parent:
				parent.remove_child(panel)
			panel.queue_free()
	device_panels.clear()
	for n in vbox.get_children():
		vbox.remove_child(n)
		n.queue_free() 

	# Add panel for each device
	if not channel:
		return

	var lane: Array[DeviceInstance] = PadLane.devices(channel) if _pad_lane.active() else channel.devices
	for i in lane.size():
		_add_device_panel(lane[i], i)
	_create_drop_zones()


func _on_pad_lane_changed() -> void:
	if _pad_lane.active():
		_populate_devices()


## Add a panel for a device
func _add_device_panel(device_instance: DeviceInstance, position: int) -> void:
	"""Create and add a panel for a device instance.

	Args:
		device_instance: The DeviceInstance to create a panel for
		position: Position in device chain
	"""
	logger.info("_add_device_panel() called for device: %s at position %d" % [device_instance.device.name, position])

	# Instantiate panel
	var panel: CompactDevicePanel
	panel = CompactDevicePanelScene.instantiate()
	logger.info("Panel instantiated")
	
	panel.collapsed = collapsed_by_default
	panel.hide_parameters = hide_parameters
	
	# Setup the panel
	panel.setup(device_instance, position)
	logger.info("Panel setup complete")

	# Add to vbox
	vbox.add_child(panel)
	logger.info("Panel added to vbox. Total panels now: %d" % vbox.get_child_count())
	
	# listen to right-click
	panel.request_context_menu.connect(_on_device_panel_request_context_menu.bind(device_instance))
	
	# Track the panel
	device_panels[device_instance.id] = panel
	_create_drop_zones()


## Remove a panel for a device
func _remove_device_panel_at(position: int) -> void:
	"""Remove the panel for a device instance.

	Args:
		device_id: position
	"""
	for panel:CompactDevicePanel in device_panels.values():
		if panel.device_instance.position == position:
			device_panels.erase(panel.device_instance.id)
			var parent := panel.get_parent()
			if parent:
				parent.remove_child(panel)
			panel.queue_free()
			_create_drop_zones()
			return
	
	logger.error("[ChannelDeviceList] Device panel not found at position %d" % position)
	


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_device_added(device_instance: DeviceInstance, position: int) -> void:
	"""Handle device added to channel."""
	if _pad_lane.active():
		return
	_add_device_panel(device_instance, position)
	logger.info("Device added at position %d" % position)


func _on_device_removed(position: int, _device_id: String) -> void:
	"""Handle device removed from channel."""
	if _pad_lane.active():
		return
	_remove_device_panel_at(position)
	logger.info("Device removed from position %d" % position)


func _on_device_moved(from_position: int, to_position: int):
	"""Handle device moved signal - reorder CompactDevicePanel nodes."""
	_create_drop_zones()
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

## Keep invisible spacer drop zones interleaved with the current compact panels.
func _create_drop_zones() -> void:
	if not channel or vbox == null:
		return
	var panel_list: Array[CompactDevicePanel] = []
	for child in vbox.get_children():
		if child is CompactDevicePanel:
			panel_list.append(child)
	if not _pad_lane.active():
		panel_list.sort_custom(func(a: CompactDevicePanel, b: CompactDevicePanel): return a.device_instance.position < b.device_instance.position)
	_drop_host.rebuild(vbox, panel_list)
