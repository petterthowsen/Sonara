## Universal parameter list for any DeviceInstance (built-in or plugin).
## Hosts CompactParameterControls for one parameter group (`"param"` or `"cc"`).
## This is not a device custom view and not the planned Immediate UI.
class_name ParameterList extends VBoxContainer

const CompactParameterControlScene = preload("res://devices/compact/CompactParameterControl.tscn")

## Parameter group to render (`"param"` or `"cc"`).
@export var group: String = "param"

var device: DeviceInstance = null
var _channel: Channel = null


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	custom_minimum_size.x = 100


## Bind to `p_device` and rebuild controls for `p_group`.
func bind_to_device(p_device: DeviceInstance, p_group: String = "param") -> void:
	unbind()
	device = p_device
	group = p_group
	_listen_for_parameter_updates()
	refresh()


## Disconnect listeners and clear controls.
func unbind() -> void:
	if _channel and _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		_channel.device_parameters_updated.disconnect(_on_device_parameters_updated)
	_channel = null
	device = null
	clear()


## Rebuild controls from the bound device's current parameter metadata.
func refresh() -> void:
	clear()
	if device == null or device.device == null:
		return
	for param in device.get_parameters_in_group(group):
		var control: CompactParameterControl = CompactParameterControlScene.instantiate()
		control.setup(device, param.id)
		add_child(control)


## Remove all parameter controls.
func clear() -> void:
	for child in get_children():
		child.queue_free()


func _listen_for_parameter_updates() -> void:
	if device == null or Sonara.editor == null or Sonara.editor.project == null:
		return
	_channel = Sonara.editor.project.get_channel_by_id(device.channel_id)
	if _channel and not _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		_channel.device_parameters_updated.connect(_on_device_parameters_updated)


func _on_device_parameters_updated(device_instance: DeviceInstance) -> void:
	if device and device == device_instance:
		refresh()
