## Universal parameter list for any DeviceInstance (built-in or plugin).
## Hosts CompactParameterControls for one parameter group (`"param"` or `"cc"`).
## This is not a device custom view and not the planned Immediate UI.
class_name ParameterList extends VBoxContainer

const CompactParameterControlScene = preload("res://devices/compact/CompactParameterControl.tscn")

var _logger := Log.make("ParameterList")

## Emitted after the controls are rebuilt or cleared.
signal controls_changed(count: int)

## Parameter group to render (`"param"` or `"cc"`).
@export var group: String = "param"

var device: DeviceInstance = null
var _channel: Channel = null
var _control_count := 0
## Controls are built the first time the list is visible (about 0.4 ms each): a closed
## Parameters tab, a collapsed compact panel or a hidden lane row costs nothing.
var _built := false


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	custom_minimum_size.x = 100


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_ENTER_TREE:
		_build_if_shown()


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


## Rebuild controls from the bound device's current parameter metadata (once the list is shown).
## The control count is known right away.
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
	_control_count = found.size()
	_build_if_shown()
	controls_changed.emit(_control_count)


func _build_if_shown() -> void:
	if _built or device == null or device.device == null or not is_inside_tree() or not is_visible_in_tree():
		return
	_built = true
	for param in device.get_parameters_in_group(group):
		var control: CompactParameterControl = CompactParameterControlScene.instantiate()
		control.setup(device, param.id)
		add_child(control)


## Number of parameter controls shown. Children freed by `clear()` linger until the
## end of the frame, so don't count children.
func get_control_count() -> int:
	return _control_count


## Remove all parameter controls.
func clear() -> void:
	_built = false
	for child in get_children():
		child.queue_free()
	if _control_count != 0:
		_control_count = 0
		controls_changed.emit(0)


func _listen_for_parameter_updates() -> void:
	if device == null:
		return
	_channel = device.get_channel()
	if _channel and not _channel.device_parameters_updated.is_connected(_on_device_parameters_updated):
		_channel.device_parameters_updated.connect(_on_device_parameters_updated)


func _on_device_parameters_updated(device_instance: DeviceInstance) -> void:
	if device and device == device_instance:
		refresh()
