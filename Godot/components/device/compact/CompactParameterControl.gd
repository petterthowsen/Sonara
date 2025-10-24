# CompactParameterControl.gd
#
# Compact parameter slider for a single device parameter.
# Shows parameter name, slider (0-1), and value display.
# For use in CompactDevicePanel.
class_name CompactParameterControl extends VBoxContainer

# ============================================================================
# EXPORTED PROPERTIES
# ============================================================================

## Show parameter value as text (updates value_label_node)
@export var show_value: bool = true


# ============================================================================
# PROPERTIES
# ============================================================================

var device_instance: DeviceInstance = null
var parameter: DeviceParameter = null
var parameter_id: int = -1

## UI nodes (wired in scene or created dynamically)
@onready var label_node: Label = $Header/HBox/Name
@onready var value_label_node: Label = $Header/HBox/ValueLabel
@onready var slider_node: HorSlider = $HorSlider


# ============================================================================
# LIFECYCLE
# ============================================================================
func _ready() -> void:
	"""Setup UI nodes and connect signals."""

	# Connect slider signal
	if slider_node:
		slider_node.value_changed.connect(_on_slider_changed)

	# If already set up with device, update UI now that nodes are ready
	if device_instance and parameter:
		_update_ui()


# ============================================================================
# PUBLIC METHODS
# ============================================================================

## Initialize with a device instance and parameter
func setup(p_device_instance: DeviceInstance, p_parameter_id: int) -> void:
	"""Setup this control with a device instance and parameter ID.

	Args:
		p_device_instance: The DeviceInstance this parameter belongs to
		p_parameter_id: The parameter ID in the device
	"""
	print("[CompactParameterControl] setup() called for param ID %d" % p_parameter_id)

	device_instance = p_device_instance
	parameter_id = p_parameter_id
	parameter = device_instance.device.get_parameter(parameter_id)

	if not parameter:
		push_error("Parameter %d not found in device" % parameter_id)
		return


	# UI will be updated in _ready() when @onready nodes are available
	# Don't call _update_ui() here - nodes aren't ready yet

	# Connect to device parameter changes
	if device_instance.parameter_changed.is_connected(_on_parameter_changed):
		device_instance.parameter_changed.disconnect(_on_parameter_changed)
	device_instance.parameter_changed.connect(_on_parameter_changed)


## Update the displayed value
func _update_ui() -> void:
	"""Update all UI elements based on current parameter state."""
	if not parameter or not device_instance:
		print("[CompactParameterControl] _update_ui() early return - parameter=%s, device_instance=%s" % [parameter != null, device_instance != null])
		return

	# Update label
	if label_node:
		label_node.text = parameter.name
		print("[CompactParameterControl] Updated label to: %s" % parameter.name)
	else:
		print("[CompactParameterControl] label_node is null!")

	# Update slider
	if slider_node:
		# Set slider range (parameters are always normalized 0.0-1.0)
		slider_node.min_value = 0.0
		slider_node.max_value = 1.0

		var normalized_value = device_instance.get_parameter_normalized(parameter_id)
		slider_node.set_value_no_signal(normalized_value)
		print("[CompactParameterControl] Updated slider range [0.0-1.0] and value to: %f" % normalized_value)
	else:
		print("[CompactParameterControl] slider_node is null!")

	# Update value display
	if value_label_node and show_value:
		var real_value = device_instance.get_parameter_real(parameter_id)
		value_label_node.text = parameter.format_value(real_value)
		print("[CompactParameterControl] Updated value label to: %s" % value_label_node.text)
	else:
		if value_label_node == null:
			print("[CompactParameterControl] value_label_node is null!")
		else:
			print("[CompactParameterControl] show_value is false")


# ============================================================================
# PRIVATE METHODS
# ============================================================================


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_slider_changed(value: float) -> void:
	"""Handle slider value change from user."""
	if not device_instance or parameter_id < 0:
		return

	# Update device parameter (this will emit parameter_changed signal)
	device_instance.set_parameter_normalized(parameter_id, value)

	# Update value display
	if value_label_node and show_value:
		var real_value = device_instance.get_parameter_real(parameter_id)
		value_label_node.text = parameter.format_value(real_value)


func _on_parameter_changed(param_id: int, value: float) -> void:
	"""Handle parameter change from device instance."""
	if param_id == parameter_id:
		_update_ui()
