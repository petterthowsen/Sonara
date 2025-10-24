# A full device panel, as shown in the DeviceLane
class_name DevicePanel extends PanelContainer

const CompactParameterControlScene = preload("res://components/device/compact/CompactParameterControl.tscn")

@onready var header : PanelContainer = $VBoxContainer/Header

# light button toggles inactive/active and enabled/disabled
@onready var device_light: DeviceLightButton = $VBoxContainer/Header/HBox/DeviceLight
@onready var name_label : Label = $VBoxContainer/Header/HBox/Name
@onready var tab_buttons : HBoxContainer = $VBoxContainer/Header/HBox/TabButtons
@onready var params_button : Button = $VBoxContainer/Header/HBox/TabButtons/ParamsButton

@onready var parameters : ScrollContainer = $VBoxContainer/Content/Parameters
@onready var parameters_box : VBoxContainer = $VBoxContainer/Content/Parameters/VBox

var device : DeviceInstance


## This should not really happen.
## unless we pool device panels, but that's a lot of work for little gain.
func _unbind_from_device(_dev : DeviceInstance):
	_clear_parameter_controls()


func bind_to_device(dev : DeviceInstance):
	if device:
		_unbind_from_device(device)
	device = dev
	
	await ready
	device_light.bind_to_device_instance(dev)
	name_label.text = dev.get_display_name()
	_create_parameter_controls()
	
	# Listen for parameter list updates (when plugins load params asynchronously)
	# Individual CompactParameterControls already listen to parameter value changes
	var channel = Sonara.editor.project.get_channel_by_id(dev.channel_id)
	if channel:
		if not channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
			channel.device_parameters_updated.connect(_on_device_parameters_updated)


func _create_parameter_controls() -> void:
	if not device:
		return

	for param in device.device.get_parameters():
		_create_parameter_control_for_param(param)


## Clear all parameter controls
func _clear_parameter_controls() -> void:
	if parameters_box:
		for child in parameters_box.get_children():
			child.queue_free()


## Create and add a parameter control UI for a specific parameter
func _create_parameter_control_for_param(param: DeviceParameter) -> void:
	# Instantiate parameter control
	var control: CompactParameterControl
	if CompactParameterControlScene:
		control = CompactParameterControlScene.instantiate()
	else:
		# Fallback: create control dynamically
		control = CompactParameterControl.new()

	# Setup the control with device instance and parameter ID
	control.setup(device, param.id)
	parameters_box.add_child(control)


## Handle device parameters updated (for plugins that load parameters asynchronously)
func _on_device_parameters_updated(device_pos: int) -> void:
	if not device:
		return
	
	# Check if this update is for our device
	if device.position == device_pos:
		_clear_parameter_controls()
		_create_parameter_controls()
