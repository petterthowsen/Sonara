# CompactDevicePanel.gd
#
# Foldable panel showing a device instance via the universal ParameterList.
# For use in ChannelDeviceList.

class_name CompactDevicePanel extends VBoxContainer

# ============================================================================
# NODE REFS
# ============================================================================
@onready var parameters : PanelContainer = $Parameters
@onready var parameters_box : VBoxContainer = $Parameters/VBox
@onready var header : PanelContainer = $Header
@onready var device_light: DeviceLightButton = $Header/HBoxContainer/DeviceLight
@onready var name_label : Label = $Header/HBoxContainer/Name
@onready var collapse_button : Button = $Header/HBoxContainer/CollapseToggle

# ============================================================================
# PROPERTIES
# ============================================================================

@export var collapsed := false
@export var hide_parameters := false:
	set(hp):
		hide_parameters = hp
		if is_inside_tree():
			_update_ui_visibility()

var device_instance: DeviceInstance = null
var _param_list: ParameterList = null

# ============================================================================
# SIGNALS
# ============================================================================
signal request_context_menu()


# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	collapse_button.toggled.connect(_on_collapse_button_toggled)

	# Apply initial state
	_update_ui_visibility()
	
	# Enable drag and drop for SFZ files (if device supports file loading)
	set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)


func _gui_input(event: InputEvent) -> void:
	"""Handle GUI input - specifically double-click to open device in DeviceLane."""
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.double_click:
			_on_double_clicked()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			request_context_menu.emit()


# ============================================================================
# PUBLIC METHODS
# ============================================================================

## Setup this panel with a device instance
func setup(p_device_instance: DeviceInstance, position: int) -> void:
	"""Setup this panel to show parameters for a device instance.

	Args:
		p_device_instance: The DeviceInstance to display
		position: Position in device chain (for display)
	"""
	print("[CompactDevicePanel] setup() called for device: %s at position %d" % [p_device_instance.get_display_name(), position])
	if device_instance and device_instance.name_changed.is_connected(_on_device_name_changed):
		device_instance.name_changed.disconnect(_on_device_name_changed)
	device_instance = p_device_instance
	
	await ready

	# Set panel title to instance name
	_refresh_name_label()
	if not device_instance.name_changed.is_connected(_on_device_name_changed):
		device_instance.name_changed.connect(_on_device_name_changed)
	
	device_light.bind_to_device_instance(device_instance)
	
	tooltip_text = device_instance.device.name
	
	_ensure_param_list()
	_param_list.bind_to_device(device_instance, "param")


## Show the instance name in the compact header.
func _refresh_name_label() -> void:
	if device_instance == null or name_label == null:
		return
	name_label.text = device_instance.get_display_name()
	var type_name := device_instance.device.name if device_instance.device else ""
	name_label.tooltip_text = type_name
	tooltip_text = type_name


## Keep the compact header in sync with instance renames.
func _on_device_name_changed(_new_name: String) -> void:
	_refresh_name_label()


## Create the shared ParameterList once and host it in the compact panel.
func _ensure_param_list() -> void:
	if _param_list:
		return
	if parameters_box:
		for child in parameters_box.get_children():
			child.queue_free()
	_param_list = ParameterList.new()
	parameters_box.add_child(_param_list)


## Update UI visibility based on collapsed and hide_parameters states
func _update_ui_visibility() -> void:
	"""Update visibility of parameters panel and collapse button based on state."""
	# Hide collapse button and parameters panel if hide_parameters is true
	if hide_parameters:
		collapse_button.visible = false
		parameters.visible = false
	else:
		# Show collapse button
		collapse_button.visible = true

		# Show/hide parameters panel based on collapsed state
		parameters.visible = not collapsed


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_collapse_button_toggled(button_pressed: bool) -> void:
	"""Handle collapse button toggle."""
	collapsed = not button_pressed
	
	# Update parameters panel visibility
	parameters.visible = not collapsed
	print("[CompactDevicePanel] Collapsed state changed to: %s" % collapsed)


func _on_double_clicked() -> void:
	"""Handle double-click - for devices with native GUI, open it; otherwise open DeviceLane."""
	if not device_instance:	
		return
	
	# If device has a native GUI, open it
	if device_instance.device.has_gui():
		device_instance.open_gui()
		return
	
	# For built-in devices: get the channel and open DeviceLane
	var channel: Channel = Sonara.editor.project.get_channel_by_id(device_instance.channel_id)
	if not channel:
		push_warning("[CompactDevicePanel] Cannot find channel with ID %d" % device_instance.channel_id)
		return
	
	# For built-in devices: Select the channel in the mixer (this will emit channel_focused)
	Sonara.editor.mixer.select_channel(channel)
	
	# Show DeviceLane if hidden
	if not Sonara.editor.device_lane.visible:
		Sonara.editor.seconday_panel.show()
		Sonara.editor.device_lane.show()
		# DeviceLane will auto-bind to the focused channel via channel_focused signal
	
	# Wait a frame for the DeviceLane to update with the new channel
	await get_tree().process_frame
	
	# Find the corresponding DevicePanel in the DeviceLane and grab focus
	var device_panel: DevicePanel = Sonara.editor.device_lane.find_device_panel(device_instance)
	if device_panel:
		device_panel.grab_focus()
		print("[CompactDevicePanel] Grabbed focus on DevicePanel for device: %s" % device_instance.device.name)
	else:
		push_warning("[CompactDevicePanel] Could not find DevicePanel for device: %s" % device_instance.device.name)


# ============================================================================
# DRAG AND DROP
# ============================================================================

func _get_drag_data(_at_position: Vector2) -> Variant:
	"""Return drag data for reordering - returns DeviceInstance."""
	if device_instance:
		return device_instance
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Accept sample files, or devices dropped onto a container."""
	if not device_instance:
		return false
	var channel := _channel_for_device()
	if device_instance.is_container() and DeviceDropUtil.can_drop_on_container(channel, device_instance, data):
		return true
	if not data is Asset:
		return false
	return DeviceDropUtil.can_drop_file_on_device(device_instance, data)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Handle dropping a device onto a container, or a sample file onto this device."""
	if not device_instance:
		return
	var channel := _channel_for_device()
	if device_instance.is_container() and DeviceDropUtil.can_drop_on_container(channel, device_instance, data):
		await DeviceDropUtil.drop_on_container(channel, device_instance, data, get_tree())
		return
	if not data is Asset:
		return
	var asset = data as Asset
	if not DeviceDropUtil.can_drop_file_on_device(device_instance, asset):
		return
	print("[CompactDevicePanel] File dropped on device: %s" % asset.name)
	device_instance.load_file(asset.path)
	print("[CompactDevicePanel] File loaded: %s" % asset.name)


func _channel_for_device() -> Channel:
	if device_instance == null or Sonara.editor == null or Sonara.editor.project == null:
		return null
	return Sonara.editor.project.get_channel_by_id(device_instance.channel_id)
