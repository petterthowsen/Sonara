# A full device panel, as shown in the DeviceLane
class_name DevicePanel extends PanelContainer

const CompactParameterControlScene = preload("res://components/device/compact/CompactParameterControl.tscn")

@onready var header : PanelContainer = $VBoxContainer/Header
@onready var enabled : LightButton = $VBoxContainer/Header/HBox/Enabled
@onready var name_label : Label = $VBoxContainer/Header/HBox/Name
@onready var tab_buttons : HBoxContainer = $VBoxContainer/Header/HBox/TabButtons
@onready var params_button : Button = $VBoxContainer/Header/HBox/TabButtons/ParamsButton

@onready var parameters : ScrollContainer = $VBoxContainer/Content/Parameters
@onready var parameters_box : VBoxContainer = $VBoxContainer/Content/Parameters/VBox

var device : DeviceInstance


func _unbind_from_device(dev : DeviceInstance):
	_clear_parameter_controls()


func bind_to_device(dev : DeviceInstance):
	if device:
		_unbind_from_device(device)
	device = dev
	
	await ready
	enabled.value = dev.enabled
	name_label.text = dev.get_display_name()
	_create_parameter_controls()


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
