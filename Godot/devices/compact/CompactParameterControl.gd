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

# Dynamically created based on param_type
var checkbox_node: CheckBox = null
var option_node: OptionButton = null


# ============================================================================
# LIFECYCLE
# ============================================================================
func _ready() -> void:
	"""Setup UI nodes and connect signals."""

	# Configure slider range ONCE (parameters are always normalized 0.0-1.0)
	if slider_node:
		slider_node.min_value = 0.0
		slider_node.max_value = 1.0
		slider_node.value_changed.connect(_on_slider_changed)

	# If already set up with device, update UI now that nodes are ready
	if device_instance and parameter:
		_ensure_control_for_param_type()
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
	device_instance = p_device_instance
	parameter_id = p_parameter_id
	parameter = device_instance.device.get_parameter(parameter_id)

	if not parameter:
		push_error("Parameter %d not found in device" % parameter_id)
		return

	# Prepare control for this parameter type once nodes become ready

	# Connect to device parameter changes
	if device_instance.parameter_changed.is_connected(_on_parameter_changed):
		device_instance.parameter_changed.disconnect(_on_parameter_changed)
	device_instance.parameter_changed.connect(_on_parameter_changed)


## Update the displayed value
func _update_ui() -> void:
	"""Update all UI elements based on current parameter state."""
	if not parameter or not device_instance:
		return

	# Update label
	if label_node:
		label_node.text = parameter.name

	var normalized_value = device_instance.get_parameter_normalized(parameter_id)

	# Show appropriate control for type
	if parameter.param_type == "bool":
		if slider_node:
			slider_node.visible = false
		if option_node:
			option_node.visible = false
		if not checkbox_node:
			_create_checkbox()
		if checkbox_node:
			checkbox_node.visible = true
			var is_on: bool = normalized_value >= 0.5
			checkbox_node.set_pressed_no_signal(is_on)
		if value_label_node and show_value:
			value_label_node.text = parameter.format_value(1.0 if normalized_value >= 0.5 else 0.0)

	elif parameter.param_type == "enum":
		if slider_node:
			slider_node.visible = false
		if checkbox_node:
			checkbox_node.visible = false
		if not option_node:
			_create_option_button()
		if option_node:
			option_node.visible = true
			var n: int = max(1, parameter.enum_values.size())
			var idx: int = int(round(normalized_value * float(n - 1)))
			idx = clamp(idx, 0, n - 1)
			option_node.select(idx)
		if value_label_node and show_value:
			var real_value = parameter.normalized_to_value(normalized_value)
			value_label_node.text = parameter.format_value(real_value)

	else:
		# float
		if checkbox_node:
			checkbox_node.visible = false
		if option_node:
			option_node.visible = false
		if slider_node:
			slider_node.visible = true
			slider_node.set_value_no_signal(normalized_value)
		if value_label_node and show_value:
			var real_value = device_instance.get_parameter_real(parameter_id)
			value_label_node.text = parameter.format_value(real_value)


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
	
	# Only update if value actually changed (avoid feedback loops)
	var current_value = device_instance.get_parameter_normalized(parameter_id)
	if abs(current_value - value) < 0.0001:
		return  # Already at this value, don't send

	# Update device parameter (sends to engine, doesn't emit signal)
	print("[ParamControl] slider param_id=", parameter_id, " normalized=", value)
	var old_value = current_value
	device_instance.set_parameter_normalized(parameter_id, value)
	var cmd := PropertyCommand.new(
		"Set Parameter",
		device_instance,
		"",
		[parameter_id, old_value],
		[parameter_id, value]
	)
	cmd.set_callable(func(args): device_instance.set_parameter_normalized(args[0], args[1])).set_unpack_array(true).set_mergeable(true)
	HistoryUtil.record(cmd)

	# Update value display immediately for responsive feedback
	if value_label_node and show_value:
		var real_value = device_instance.get_parameter_real(parameter_id)
		value_label_node.text = parameter.format_value(real_value)


func _on_parameter_changed(param_id: int, _value: float) -> void:
	"""Handle parameter change from device instance."""
	if param_id == parameter_id:
		_update_ui()

# === Dynamic control creation ===
func _ensure_control_for_param_type() -> void:
	if not parameter:
		return
	if parameter.param_type == "bool" and not checkbox_node:
		_create_checkbox()
	elif parameter.param_type == "enum" and not option_node:
		_create_option_button()

func _create_checkbox() -> void:
	checkbox_node = CheckBox.new()
	checkbox_node.text = ""
	add_child(checkbox_node)
	checkbox_node.toggled.connect(_on_checkbox_toggled)

func _create_option_button() -> void:
	option_node = OptionButton.new()
	# Populate with enum labels
	for i in range(parameter.enum_values.size()):
		option_node.add_item(parameter.enum_values[i], i)
	add_child(option_node)
	option_node.item_selected.connect(_on_option_selected)

func _on_checkbox_toggled(pressed: bool) -> void:
	if not device_instance or parameter_id < 0:
		return
	var normalized := 1.0 if pressed else 0.0
	device_instance.set_parameter_normalized(parameter_id, normalized)

func _on_option_selected(index: int) -> void:
	if not device_instance or parameter_id < 0:
		return
	var n: int = max(1, parameter.enum_values.size())
	var normalized: float = 0.0 if n <= 1 else float(index) / float(n - 1)
	print("[ParamControl] option param_id=", parameter_id, " index=", index, " normalized=", normalized)
	device_instance.set_parameter_normalized(parameter_id, normalized)
