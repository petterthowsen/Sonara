# ChannelDeviceList.gd
#
# Shows a vertical list of devices on a channel with their parameters as CompactDevicePanel.
# Updates dynamically when devices are added/removed.
# For use in the MixerChannel component.
#
# Designed to show Compact Device components as opposed to full Device (as used in the full device strip)

class_name ChannelDeviceList extends PanelContainer

const CompactDevicePanelScene = preload("res://devices/compact/CompactDevicePanel.tscn")

@onready var scroll_container : ScrollContainer = $ScrollContainer
@onready var vbox : VBoxContainer = $ScrollContainer/VBoxContainer

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


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	"""Setup UI after scene loads."""
	# clear devices (in case of testing in editor)
	for node in vbox.get_children():
		node.free()


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

	channel = p_channel

	# Connect to device signals
	channel.device_added.connect(_on_device_added)
	channel.device_removed.connect(_on_device_removed)

	# Populate initial devices
	_populate_devices()

	print("[ChannelDeviceList] Bound to channel %d (%s)" % [channel.id, channel.name])


## Refresh the device list from channel
func _populate_devices() -> void:
	"""Refresh the display to show all current devices on the channel."""
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

	# Track the panel
	device_panels[device_instance.id] = panel


## Remove a panel for a device
func _remove_device_panel(device_id: String) -> void:
	"""Remove the panel for a device instance.

	Args:
		device_id: The DeviceInstance ID to remove
	"""
	if device_id in device_panels:
		var panel = device_panels[device_id]
		if panel:
			panel.queue_free()
		device_panels.erase(device_id)


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_device_added(device_instance: DeviceInstance, position: int) -> void:
	"""Handle device added to channel."""
	_add_device_panel(device_instance, position)
	print("[ChannelDeviceList] Device added at position %d" % position)


func _on_device_removed(position: int, device_id: String) -> void:
	"""Handle device removed from channel."""
	_remove_device_panel(device_id)
	print("[ChannelDeviceList] Device removed from position %d" % position)
