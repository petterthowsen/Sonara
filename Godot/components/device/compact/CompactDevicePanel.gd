# CompactDevicePanel.gd
#
# Foldable panel showing all parameters of a device instance.
# Creates CompactParameterControl for each parameter.
# For use in ChannelDeviceList.

class_name CompactDevicePanel extends VBoxContainer

const CompactParameterControlScene = preload("res://components/device/compact/CompactParameterControl.tscn")

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
			collapse_button.visible = not hp
			
			if hide_parameters and parameters.visible:
				parameters.visible = false

var device_instance: DeviceInstance = null
var parameter_controls: Array[CompactParameterControl] = []


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
	print("[CompactDevicePanel] setup() called for device: %s at position %d" % [p_device_instance.device.name, position])
	device_instance = p_device_instance
	
	await ready

	# Set panel title to device name and position
	name_label.text = device_instance.device.get_short_name()
	name_label.tooltip_text = device_instance.device.name
	
	device_light.bind_to_device_instance(device_instance)
	
	tooltip_text = device_instance.device.name
	
	# Clear existing parameter controls
	_clear_parameter_controls()

	_create_parameter_controls()


## Create all parameter control UI elements (called after _ready)
func _create_parameter_controls() -> void:
	"""Create parameter controls for all device parameters."""
	if not device_instance:
		return

	var parameters = device_instance.device.get_parameters()
	print("[CompactDevicePanel] Creating %d parameter controls for device: %s" % [parameters.size(), device_instance.device.name])
	for param in parameters:
		_create_parameter_control_for_param(param)


## Clear all parameter controls
func _clear_parameter_controls() -> void:
	"""Remove all parameter control UI elements."""
	# Clear tracked controls
	for control in parameter_controls:
		if control and is_instance_valid(control):
			control.queue_free()
	parameter_controls.clear()

	# Also clear any existing children from parameters_box (in case scene had pre-made controls)
	if parameters_box:
		for child in parameters_box.get_children():
			child.queue_free()


## Create and add a parameter control UI for a specific parameter
func _create_parameter_control_for_param(param: DeviceParameter) -> void:
	"""Create and add a parameter control UI for a device parameter.

	Args:
		param: The DeviceParameter to create a control for
	"""
	print("[CompactDevicePanel] Creating parameter control for param ID %d: %s" % [param.id, param.name])

	# Instantiate parameter control
	var control: CompactParameterControl
	if CompactParameterControlScene:
		control = CompactParameterControlScene.instantiate()
	else:
		# Fallback: create control dynamically
		control = CompactParameterControl.new()

	# Setup the control with device instance and parameter ID
	control.setup(device_instance, param.id)

	# Fallback: add directly to root
	parameters_box.add_child(control)
	print("[CompactDevicePanel] Added parameter control to parameters_box. Total controls now: %d" % parameters_box.get_child_count())

	parameter_controls.append(control)


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
	"""Return drag data (not used for this panel)."""
	return null


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	"""Check if we can drop an SFZ file on this device."""
	if not device_instance or not data is Asset:
		return false
	
	# Only accept SFZ files
	if data.type != Asset.TYPE.SFZ:
		return false
	
	# Only allow drops on devices that support file loading (sfizz)
	return device_instance.device.supports_file_loading


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	"""Handle dropping an SFZ file on this device."""
	if not data is Asset or not device_instance:
		return
	
	var asset = data as Asset
	if asset.type != Asset.TYPE.SFZ:
		return
	
	print("[CompactDevicePanel] SFZ dropped on device: %s" % asset.name)
	
	# Load the SFZ file into the device
	device_instance.load_file(asset.path)
	
	print("[CompactDevicePanel] SFZ loaded: %s" % asset.name)
