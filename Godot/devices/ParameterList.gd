## Universal parameter list for any DeviceInstance (built-in or plugin).
## Hosts CompactParameterControls for one parameter group (`"param"` or `"cc"`).
## This is not a device custom view and not the planned Immediate UI.
class_name ParameterList extends VBoxContainer

const CompactParameterControlScene = preload("res://devices/compact/CompactParameterControl.tscn")

var _logger := Log.make("ParameterList")

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
	_logger.debug("bind_to_device group=%s device=%s" % [p_group, p_device.get_display_name() if p_device else "null"])
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
		_logger.debug("refresh() bailing early: device_null=%s device.device_null=%s" % [device == null, device.device == null if device else true])
		return
	var found := device.get_parameters_in_group(group)
	var registry_count := device.device.parameters.size()
	_logger.debug("refresh() group=%s instance_params=%d registry_params=%d found=%d device=%s" % [
		group, device.parameters.size(), registry_count, found.size(), device.device.name
	])
	for param in found:
		var control: CompactParameterControl = CompactParameterControlScene.instantiate()
		control.setup(device, param.id)
		add_child(control)


## Remove all parameter controls.
func clear() -> void:
	for child in get_children():
		child.queue_free()


func _listen_for_parameter_updates() -> void:
	if device == null:
		return
	_channel = device.get_channel()
	if _channel and not _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		_channel.device_parameters_updated.connect(_on_device_parameters_updated)


func _on_device_parameters_updated(device_instance: DeviceInstance) -> void:
	if device and device == device_instance:
		refresh()
